import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash } from "node:crypto";
import { AvatarNormalizer, normalizedAvatarManifest, normalizedAvatarUpload, normalizedAvatarPayloadHash } from "../src/avatar-normalizer.mjs";
import { inspectAvatarJPEG } from "../src/avatar-jpeg.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { avatarCodecs, avatarImage, withAvatarMetadata, markerOffset, invalidAvatarHuffman } from "./support/avatar-image-fixture.mjs";
import { publicCode } from "./support/public-record-fixture.mjs";
const owner = "64000000-0000-4000-8000-000000000001", version = "64000000-0000-4000-8000-000000000002";
const request = "64000000-0000-4000-8000-000000000003", other = "64000000-0000-4000-8000-000000000004";
const authorize = () => ({ accountID: owner });
const input = (bytes, changes = {}) => ({ bytes, versionID: version, requestID: request, authorize, ...changes });
const context = (changes = {}) => ({ ...recordIdentity(owner, "avatar", version), requestID: request, ...changes });
async function normalizer(changes = {}) { return new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => true, ...changes }); }
const hash = bytes => createHash("sha256").update(bytes).digest("hex");

test("actual Wasm decodes and reencodes full image and derives a consistent thumbnail", async () => {
  const n = await normalizer(), bytes = await avatarImage({ width: 512, height: 256 });
  const handle = await n.prepare(input(bytes));
  for (const [kind, width, height] of [["image", 512, 256], ["thumbnail", 128, 64]]) {
    const manifest = normalizedAvatarManifest(handle, kind), part = normalizedAvatarUpload(handle, context(), kind);
    const decodedHeader = inspectAvatarJPEG(part.bytes);
    assert.deepEqual(Object.keys(manifest).sort(), ["schemaVersion", "ownerID", "versionID", "variant", "byteCount", "width", "height", "sha256"].sort());
    assert.equal(decodedHeader.width, width); assert.equal(decodedHeader.height, height);
    assert.equal(manifest.byteCount, part.bytes.length); assert.equal(manifest.sha256, hash(part.bytes));
    assert.equal(manifest.ownerID, owner); assert.equal(manifest.versionID, version);
  }
  assert.notEqual(normalizedAvatarManifest(handle, "image").sha256, hash(bytes));
  assert.match(normalizedAvatarPayloadHash(handle), /^[a-f0-9]{64}$/);
});

test("metadata is discarded before the native decoder and never survives the server reencode", async () => {
  const bytes = withAvatarMetadata(await avatarImage()), clean = inspectAvatarJPEG(bytes);
  assert.ok(clean.removedMetadata >= 3);
  assert.equal(Buffer.from(clean.bytes).includes(Buffer.from("SYNTHETIC")), false);
  const handle = await (await normalizer()).prepare(input(bytes));
  for (const kind of ["image", "thumbnail"]) assert.equal(Buffer.from(normalizedAvatarUpload(handle, context(), kind).bytes).includes(Buffer.from("SYNTHETIC")), false);
});

test("one pixel, odd sizes and portrait dimensions preserve aspect and bounded thumbnail edges", async () => {
  const n = await normalizer();
  for (const [width, height, expectedWidth, expectedHeight] of [[1, 1, 1, 1], [17, 13, 17, 13], [129, 511, 32, 128]]) {
    const handle = await n.prepare(input(await avatarImage({ width, height })));
    const thumb = normalizedAvatarManifest(handle, "thumbnail");
    assert.equal(thumb.width, expectedWidth); assert.equal(thumb.height, expectedHeight);
  }
});

test("worst-size noise is bounded after real codec work rather than trusted client metadata", async () => {
  const handle = await (await normalizer()).prepare(input(await avatarImage({ width: 512, height: 512, noise: true })));
  assert.ok(normalizedAvatarManifest(handle, "image").byteCount <= 256000);
  assert.ok(normalizedAvatarManifest(handle, "thumbnail").byteCount <= 32000);
});

test("opaque normalized handles cannot be forged, serialized, swapped across owner/version/request or mutate retained bytes", async () => {
  const handle = await (await normalizer()).prepare(input(await avatarImage()));
  assert.equal(JSON.stringify(handle), '"<normalized-avatar>"'); assert.deepEqual(Object.keys(handle), []);
  for (const value of [null, {}, JSON.parse(JSON.stringify(handle))]) assert.throws(() => normalizedAvatarManifest(value, "image"), publicCode("PUBLIC_SCOPE"));
  for (const changes of [{ accountID: other }, { requestID: other }, { recordName: recordIdentity(owner, "avatar", other).recordName }, { kind: "profile" }]) {
    assert.throws(() => normalizedAvatarUpload(handle, context(changes), "image"), publicCode("PUBLIC_SCOPE"));
  }
  assert.throws(() => normalizedAvatarManifest(handle, "raw"), publicCode("PUBLIC_INPUT"));
  const first = normalizedAvatarUpload(handle, context(), "image"), original = hash(first.bytes); first.bytes.fill(0);
  assert.equal(hash(normalizedAvatarUpload(handle, context(), "image").bytes), original);
});

test("a reused input buffer cannot change a frame after the first asynchronous codec boundary", async () => {
  const bytes = await avatarImage(); let checks = 0;
  const handle = await (await normalizer()).prepare(input(bytes, { authorize() { if (++checks === 2) bytes.fill(0); return { accountID: owner }; } }));
  assert.equal(normalizedAvatarManifest(handle, "image").width, 256);
});

test("malformed, non-JPEG, oversized, shared or trailing data fails before image acceptance", async () => {
  const n = await normalizer(), bytes = await avatarImage();
  for (const bad of [new Uint8Array(), new Uint8Array(256001), new TextEncoder().encode("not jpeg"),
    new Uint8Array(new SharedArrayBuffer(bytes.length)), bytes.subarray(0, bytes.length - 1), new Uint8Array([...bytes, 0])]) {
    await assert.rejects(() => n.prepare(input(bad)), publicCode("PUBLIC_INPUT"));
  }
});

test("frame dimensions, component count, precision and progressive scans are checked before codec allocation", async () => {
  const n = await normalizer(), bytes = await avatarImage(), at = markerOffset(bytes, 0xc0);
  for (const [offset, value] of [[at + 1, 0xc2], [at + 4, 12], [at + 5, 255], [at + 7, 255], [at + 9, 4]]) {
    const invalid = bytes.slice(); invalid[offset] = value;
    await assert.rejects(() => n.prepare(input(invalid)), publicCode("PUBLIC_INPUT"));
  }
});

test("bad segment lengths, duplicate frames, marker floods and Adobe transforms are rejected", async () => {
  const bytes = await avatarImage(), n = await normalizer(), frame = markerOffset(bytes, 0xc0), length = (bytes[frame + 2] << 8) | bytes[frame + 3];
  const invalidLength = bytes.slice(); invalidLength[4] = 255; invalidLength[5] = 255;
  const duplicate = new Uint8Array([...bytes.subarray(0, frame), ...bytes.subarray(frame, frame + length + 2), ...bytes.subarray(frame)]);
  const adobe = new Uint8Array([255, 216, 255, 238, 0, 2, ...bytes.subarray(2)]);
  const flood = new Uint8Array([255, 216, ...Array.from({ length: 65 }, () => [255, 254, 0, 2]).flat(), ...bytes.subarray(2)]);
  for (const invalid of [invalidLength, duplicate, adobe, flood]) await assert.rejects(() => n.prepare(input(invalid)), publicCode("PUBLIC_INPUT"));
});

test("actual decoder warnings or errors reject truncated entropy and do not poison the next request", async () => {
  const n = await normalizer(), bytes = await avatarImage({ width: 256, height: 256, noise: true });
  const scan = markerOffset(bytes, 0xda), end = scan + 2 + ((bytes[scan + 2] << 8) | bytes[scan + 3]);
  const cut = new Uint8Array([...bytes.subarray(0, end + 1), 255, 217]);
  assert.equal(inspectAvatarJPEG(cut).width, 256); // Header alone cannot validate entropy.
  for (const invalid of [cut, invalidAvatarHuffman(bytes)]) await assert.rejects(() => n.prepare(input(invalid)), publicCode("PUBLIC_INPUT"));
  assert.equal(normalizedAvatarManifest(await n.prepare(input(bytes)), "image").width, 256);
});

test("one isolate accepts one codec operation and rejects a concurrent decoded-image backlog", async () => {
  const n = await normalizer(), bytes = await avatarImage();
  const results = await Promise.allSettled([n.prepare(input(bytes)), n.prepare(input(bytes))]);
  assert.equal(results.filter(r => r.status === "fulfilled").length, 1);
  assert.equal(results.find(r => r.status === "rejected").reason.code, "PUBLIC_LIMIT");
});

test("missing activation, asynchronous authorization, changed owner and cancellation cannot release an image", async () => {
  const bytes = await avatarImage(), n = await normalizer();
  assert.throws(() => new AvatarNormalizer({ isEnabled: () => true }), publicCode("PUBLIC_INPUT"));
  await assert.rejects(() => normalizer({ isEnabled: () => false }).then(n => n.prepare(input(bytes))), publicCode("PUBLIC_UNAVAILABLE"));
  await assert.rejects(() => n.prepare(input(bytes, { authorize: async () => ({ accountID: owner }) })), publicCode("PUBLIC_SCOPE"));
  let checks = 0;
  await assert.rejects(() => n.prepare(input(bytes, { authorize: () => ({ accountID: ++checks > 1 ? other : owner }) })), publicCode("PUBLIC_SCOPE"));
  const controller = new AbortController(); controller.abort();
  await assert.rejects(() => n.prepare(input(bytes, { signal: controller.signal })), publicCode("PUBLIC_UNAVAILABLE"));
});

test("client-defined settings, IDs or a missing auth source are not part of normalization", async () => {
  const n = await normalizer(), bytes = await avatarImage();
  for (const changes of [{ versionID: "../outside" }, { requestID: undefined }, { versionID: 7 }, { authorize: undefined },
    { quality: 100 }, { exif: "CLIENT-METADATA" }, { authorize: () => ({ accountID: "invalid" }) }]) {
    await assert.rejects(() => n.prepare(input(bytes, changes)), error => ["PUBLIC_INPUT", "PUBLIC_SCOPE"].includes(error.code));
  }
});

test("a real normalized handle feeds durable scoped asset upload with the exact server digest and bytes", async () => {
  const { publicFixture, syntheticPublicKeyConfiguration, syntheticAvatarReceiptVault } = await import("./support/public-record-fixture.mjs");
  const { CloudKitAvatarAssets } = await import("../src/cloudkit-avatar-assets.mjs");
  const f = await publicFixture();
  try {
    const signedIn = await f.session(), authorize = () => f.state.authorize(signedIn.sessionToken);
    const handle = await (await normalizer()).prepare(input(await avatarImage(), { authorize }));
    const c = await f.registry.reserve({ accountID: signedIn.accountID, kind: "avatar", logicalID: version,
      requestID: request, payloadHash: normalizedAvatarPayloadHash(handle) });
    const part = normalizedAvatarUpload(handle, c, "image"), manifest = normalizedAvatarManifest(handle, "image");
    const key = syntheticPublicKeyConfiguration(); let calls = 0;
    const assets = new CloudKitAvatarAssets({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: key.CLOUDKIT_KEY_ID,
      privateKeyPEM: key.CLOUDKIT_PRIVATE_KEY, receiptVault: syntheticAvatarReceiptVault(), registry: f.registry, checkpoint: f.checkpoint, clock: f.clock, isEnabled: () => true,
      verifiedUploadHosts: ["synthetic-asset.icloud-content.com"], fetchImplementation: async req => {
        calls++;
        assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
        if (calls === 1) return Response.json({ tokens: [{ recordName: c.recordName, fieldName: "image", url: "https://synthetic-asset.icloud-content.com/upload" }] });
        const data = new Uint8Array(await req.arrayBuffer());
        assert.equal(hash(data), manifest.sha256); assert.equal(data.length, manifest.byteCount);
        return Response.json({ singleFile: { receipt: "SYNTHETIC-RECEIPT", fileChecksum: "SYNTHETIC-PROVIDER-CHECKSUM", size: data.length } });
      } });
    const receipt = await assets.upload({ context: c, variant: "image", ...part, authorizeMutation: authorize });
    assert.equal(calls, 2); assert.equal(assets.recordField(receipt, { context: c, variant: "image", authorizeMutation: authorize }).value.size, manifest.byteCount);
    assert.equal(f.db.prepare("SELECT content_sha256 FROM avatar_asset_transfers_v1").get().content_sha256, manifest.sha256);
    assert.equal(f.model.records.size, 0);
  } finally { f.close(); }
});
