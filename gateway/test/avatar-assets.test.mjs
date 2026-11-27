import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { CloudKitAvatarAssets } from "../src/cloudkit-avatar-assets.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { normalizePublicInput, recordIdentity } from "../src/public-record-schema.mjs";
import { publicFixture, publicCode, syntheticAvatarReceiptVault } from "./support/public-record-fixture.mjs";
import { gzipJSONServer } from "./support/gzip-json-server.mjs";

const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const host = "synthetic-asset.icloud-content.com";
const url = `https://${host}/opaque/upload?token=SYNTHETIC-URL-TOKEN`;
const sha = value => createHash("sha256").update(value).digest("hex");
const bytes = new Uint8Array([0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9]);
const file = size => ({ size, fileChecksum: "SYNTHETIC-CHECKSUM", receipt: "SYNTHETIC-PRIVATE-RECEIPT" });

// These bytes/receipts model the upload protocol; they are explicitly NOT an image validation test.
async function fixture(options = {}) {
  const f = await publicFixture(options), session = await f.session(), versionID = randomUUID(), requestID = randomUUID();
  const context = await f.registry.reserve({ accountID: session.accountID, kind: "avatar", logicalID: versionID,
    requestID, payloadHash: sha("synthetic normalized image + thumbnail metadata") });
  const calls = [], authorizeMutation = () => f.state.authorize(session.sessionToken);
  let fetchHook, enabled = true;
  const configuration = { container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-asset-key",
    privateKeyPEM: pem, receiptVault: syntheticAvatarReceiptVault(), registry: f.registry, checkpoint: f.checkpoint, isEnabled: () => enabled, clock: f.clock,
    verifiedUploadHosts: [host], fetchImplementation: async (request, options) => {
      const call = { request, signal: options.signal }; calls.push(call);
      const override = await fetchHook?.(call); if (override) return override;
      if (request.url.startsWith("https://api.apple-cloudkit.com/")) {
        assert.equal(request.redirect, "manual");
        assert.equal(new URL(request.url).pathname, "/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload");
        const body = await request.text(), stamp = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date");
        assert.equal(verify("sha256", Buffer.from(`${stamp}:${createHash("sha256").update(body).digest("base64")}:${new URL(request.url).pathname}`),
          pair.publicKey, Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64")), true);
        const { tokens } = JSON.parse(body);
        assert.deepEqual(tokens, [{ recordName: context.recordName, recordType: "EchoesAvatarV1", fieldName: "image" }]);
        return Response.json({ tokens: [{ recordName: context.recordName, fieldName: "image", url }] });
      }
      assert.equal(request.url, url); assert.equal(request.method, "POST"); assert.equal(request.redirect, "manual");
      assert.equal(request.credentials, "omit");
      assert.deepEqual([...request.headers.keys()].sort(), ["cache-control", "content-type"]);
      assert.deepEqual(new Uint8Array(await request.arrayBuffer()), bytes);
      return Response.json({ singleFile: file(bytes.length) });
    } };
  return { ...f, signedIn: session, versionID, context, calls, configuration, authorizeMutation,
    hook(value) { fetchHook = value; }, disable() { enabled = false; },
    client(changes = {}) { return new CloudKitAvatarAssets({ ...configuration, ...changes }); },
    fieldOptions(changes = {}) { return { context, variant: "image", authorizeMutation, ...changes }; },
    input(changes = {}) { return { context, variant: "image", bytes, sha256: sha(bytes), authorizeMutation, ...changes }; } };
}

test("avatar upload signs exact grant, durably reserves first, isolates headers and returns a redacted handle", async () => {
  const f = await fixture();
  try {
    f.hook(() => {
      const row = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").get(); assert.equal(row.phase, "claimed");
      const point = JSON.parse(f.db.prepare("SELECT confirmed_value FROM public_registry_checkpoint_v1").get().confirmed_value);
      assert.equal(point.registeredCount, 1);
    });
    const client = f.client(), handle = await client.upload(f.input());
    assert.equal(f.calls.length, 2); assert.equal(JSON.stringify(handle), '"<uploaded-avatar-asset>"');
    assert.deepEqual(Object.keys(handle), []);
    assert.deepEqual(client.recordField(handle, f.fieldOptions()), { type: "ASSET", value: file(bytes.length) });
    const row = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").get();
    assert.equal(row.phase, "acknowledged"); assert.equal(row.content_sha256, sha(bytes));
    for (const secret of ["SYNTHETIC-PRIVATE-RECEIPT", "SYNTHETIC-URL-TOKEN", pem]) assert.equal(JSON.stringify(row).includes(secret), false);
    assert.equal(f.model.records.size, 0); // Receiving an asset is not record creation/publication.
  } finally { f.close(); }
});

test("an upload permit cannot be serialized into another client, forged, or used after expiry", async () => {
  const f = await fixture();
  try {
    const client = f.client(), handle = await client.upload(f.input());
    assert.throws(() => f.client().recordField(handle, f.fieldOptions()), publicCode("PUBLIC_SCOPE"));
    for (const value of [{}, JSON.parse(JSON.stringify(handle)), null]) assert.throws(() => client.recordField(value, f.fieldOptions()), publicCode("PUBLIC_SCOPE"));
    assert.throws(() => client.recordField(handle), publicCode("PUBLIC_SCOPE"));
    assert.throws(() => client.recordField(handle, f.fieldOptions({ variant: "thumbnail" })), publicCode("PUBLIC_SCOPE"));
    assert.throws(() => client.recordField(handle, f.fieldOptions({ context: { ...f.context, recordName: recordIdentity(f.signedIn.accountID, "avatar", randomUUID()).recordName } })), publicCode("PUBLIC_SCOPE"));
    f.advance(120000); assert.throws(() => client.recordField(handle, f.fieldOptions()), publicCode("PUBLIC_SCOPE"));
  } finally { f.close(); }
});

test("unverified hosts, non-Development and bad configuration fail before a transfer", async () => {
  const f = await fixture();
  try {
    for (const changes of [{ verifiedUploadHosts: [] }, { verifiedUploadHosts: ["*.icloud-content.com"] },
      { verifiedUploadHosts: ["localhost"] }, { verifiedUploadHosts: ["127.0.0.1"] }, { verifiedUploadHosts: ["icloud-content.com.evil.invalid"] },
      { verifiedUploadHosts: [host, host] }, { verifiedUploadHosts: ["SYNTHETIC.icloud-content.com"] },
      { environment: "production" }, { container: "iCloud.other" }, { timeoutMilliseconds: 8001 }]) assert.throws(() => f.client(changes), publicCode("PUBLIC_INPUT"));
    assert.equal(f.calls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 0);
  } finally { f.close(); }
});

test("bounds and fingerprints are checked before SQL or network, including mutable/shared buffers", async () => {
  const f = await fixture();
  try {
    const client = f.client();
    for (const changes of [{ bytes: new Uint8Array() }, { bytes: new Uint8Array(256001) }, { bytes: [] },
      { bytes: new Uint8Array(new SharedArrayBuffer(8)) }, { sha256: "a".repeat(64) }, { variant: "other" },
      { variant: "thumbnail", bytes: new Uint8Array(32001) }, { authorizeMutation: undefined },
      { context: { ...f.context, kind: "profile" } }]) await assert.rejects(() => client.upload(f.input(changes)), publicCode("PUBLIC_INPUT"));
    assert.equal(f.calls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 0);
    const mutable = bytes.slice();
    f.hook(({ request }) => { if (request.url.startsWith("https://api.")) mutable.fill(0); });
    await client.upload(f.input({ bytes: mutable })); assert.deepEqual(mutable, new Uint8Array(bytes.length));
  } finally { f.close(); }
});

test("only one concurrent grant can leave SQLite, and a restart cannot reupload an unknown result", async () => {
  const f = await fixture();
  try {
    const client = f.client();
    const results = await Promise.allSettled([client.upload(f.input()), client.upload(f.input())]);
    assert.equal(results.filter(r => r.status === "fulfilled").length, 1);
    assert.equal(results.find(r => r.status === "rejected").reason.code, "PUBLIC_PENDING");
    assert.equal(f.calls.length, 2);
    const reopened = new PublicRecordRegistry(f.storage, { clock: f.clock });
    await assert.rejects(() => f.client({ registry: reopened }).upload(f.input()), publicCode("PUBLIC_PENDING"));
    assert.equal(f.calls.length, 2);
  } finally { f.close(); }
});

test("each immutable version has separate full/thumbnail attempts and rejects replacement CAS", async () => {
  const f = await fixture();
  try {
    const a = await f.registry.claimAvatarTransfer(f.context, { variant: "image", sha256: sha(bytes), byteCount: bytes.length });
    const b = await f.registry.claimAvatarTransfer(f.context, { variant: "thumbnail", sha256: sha(bytes), byteCount: bytes.length });
    assert.notEqual(a.transferID, b.transferID);
    await f.registry.acknowledgeAvatarTransfer(a, sha("receipt"), sha("checksum"), { envelope: "synthetic-envelope", expiresAt: f.clock() + 120000 });
    await f.registry.acknowledgeAvatarTransfer(a, sha("receipt"), sha("checksum"), { envelope: "synthetic-envelope", expiresAt: f.clock() + 120000 });
    await assert.rejects(() => f.registry.acknowledgeAvatarTransfer(a, sha("other"), sha("checksum"), { envelope: "synthetic-envelope", expiresAt: f.clock() + 120000 }), publicCode("PUBLIC_CONFLICT"));
    await assert.rejects(() => f.registry.reserve({ accountID: f.signedIn.accountID, kind: "avatar", logicalID: f.versionID,
      requestID: randomUUID(), payloadHash: sha("changed"), expectedTag: "existing-tag" }), publicCode("PUBLIC_INPUT"));
    assert.throws(() => normalizePublicInput("avatar", { receipt: "client" }, f.clock()), publicCode("PUBLIC_INPUT"));
  } finally { f.close(); }
});

test("a durability failure prevents the grant and retains the conservative claimed attempt", async () => {
  let armed = false;
  const f = await fixture({ syncHook: () => {
    if (armed && f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n) throw new Error("PRIVATE DISK PATH");
  } });
  try {
    armed = true;
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 0); armed = false;
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 1);
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_PENDING"));
  } finally { armed = false; f.close(); }
});

test("invalid grant URLs cannot turn the signed client into a proxy or receive any binary request", async () => {
  for (const bad of ["http://" + host + "/x", "https://127.0.0.1/x", "https://" + host + ".evil.invalid/x",
    "https://user:pass@" + host + "/x", "https://" + host + ":8443/x", "https://" + host + "/x#fragment",
    "https://" + host + "/x\n", "https://other.icloud-content.com/x", "https://" + host + ":443/x"]) {
    const f = await fixture();
    try {
      f.hook(() => Response.json({ tokens: [{ recordName: f.context.recordName, fieldName: "image", url: bad }] }));
      await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_RESPONSE")); assert.equal(f.calls.length, 1);
    } finally { f.close(); }
  }
});

test("a grant is bound to exactly one known record and field", async () => {
  const f = await fixture();
  try {
    f.hook(() => Response.json({ tokens: [{ recordName: f.context.recordName, fieldName: "thumbnail", url }] }));
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_RESPONSE")); assert.equal(f.calls.length, 1);
  } finally { f.close(); }
});

test("manual redirects on either request never forward bytes or signatures", async () => {
  for (const where of [1, 2]) {
    const f = await fixture();
    try {
      f.hook(() => f.calls.length === where ? new Response(null, { status: 302, headers: { Location: "https://evil.invalid/SENSITIVE" } }) : undefined);
      await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE")); assert.equal(f.calls.length, where);
    } finally { f.close(); }
  }
});

test("bad receipt shape, length or size never acknowledges the attempt or exposes upstream content", async () => {
  for (const change of [{ size: 999 }, { receipt: "" }, { downloadURL: "https://evil.invalid" }, { extra: "PRIVATE" }, { fileChecksum: "\nPRIVATE" }]) {
    const f = await fixture();
    try {
      f.hook(() => f.calls.length === 2 ? Response.json({ singleFile: { ...file(bytes.length), ...change } }) : undefined);
      await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_RESPONSE"));
      assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
      await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_PENDING"));
    } finally { f.close(); }
  }
});

test("response streams are bounded without trusting Content-Length and invalid JSON/type is rejected", async () => {
  for (const response of [() => new Response("x".repeat(16385), { headers: { "Content-Type": "application/json" } }),
    () => new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "16385" } }),
    () => new Response("{}", { headers: { "Content-Type": "text/html" } }),
    () => new Response("{", { headers: { "Content-Type": "application/json" } })]) {
    const f = await fixture();
    try {
      f.hook(response);
      await assert.rejects(() => f.client().upload(f.input()), error => ["PUBLIC_RESPONSE", "PUBLIC_UNAVAILABLE"].includes(error.code));
      assert.equal(f.calls.length, 1);
    } finally { f.close(); }
  }
});

test("deadline and caller cancellation stop late fetch completions from starting the binary upload", async () => {
  for (const timed of [true, false]) {
    const f = await fixture(); let release, reached;
    try {
      const ready = new Promise(resolve => { reached = resolve; });
      f.hook(async () => { reached(); await new Promise(resolve => { release = resolve; }); });
      const controller = new AbortController();
      const result = assert.rejects(() => f.client({ timeoutMilliseconds: timed ? 100 : 8000 }).upload(f.input({ signal: controller.signal })), publicCode("PUBLIC_UNAVAILABLE"));
      await ready; if (!timed) controller.abort(); await result;
      release(); await new Promise(resolve => setTimeout(resolve, 10)); assert.equal(f.calls.length, 1);
    } finally { release?.(); f.close(); }
  }
});

test("disabled or already aborted requests do not claim an attempt, including synchronous authorization rejection", async () => {
  const f = await fixture();
  try {
    const controller = new AbortController(); controller.abort();
    await assert.rejects(() => f.client().upload(f.input({ signal: controller.signal })), publicCode("PUBLIC_UNAVAILABLE"));
    await assert.rejects(() => f.client().upload(f.input({ authorizeMutation: () => false })), publicCode("PUBLIC_SCOPE"));
    await assert.rejects(() => f.client().upload(f.input({ authorizeMutation: () => {} })), publicCode("PUBLIC_SCOPE"));
    await assert.rejects(() => f.client().upload(f.input({ authorizeMutation: () => ({ accountID: randomUUID() }) })), publicCode("PUBLIC_SCOPE"));
    await assert.rejects(() => f.client().upload(f.input({ authorizeMutation: async () => {} })), publicCode("PUBLIC_SCOPE"));
    f.disable(); await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 0);
  } finally { f.close(); }
});

test("deletion during grant fences the binary request and removes metadata without touching another owner", async () => {
  const f = await fixture();
  try {
    const other = await f.session("other.user"), version = randomUUID();
    const b = await f.registry.reserve({ accountID: other.accountID, kind: "avatar", logicalID: version, requestID: randomUUID(), payloadHash: sha("B") });
    await f.registry.claimAvatarTransfer(b, { variant: "image", sha256: sha("B"), byteCount: 1 });
    let deleted = false;
    f.hook(async () => { if (!deleted) { deleted = true; const ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket); } });
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 1);
    const a = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=?").get(f.context.recordName);
    assert.deepEqual({ ...a }, { record_name: f.context.recordName, variant: "image", transfer_id: null, request_id: null, payload_hash: null,
      generation: null, content_sha256: null, byte_count: null, phase: "erased", receipt_hash: null, file_checksum_hash: null, receipt_envelope: null, receipt_expires_at: null, started_at: 0 });
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1 WHERE record_name=?").get(b.recordName).phase, "claimed");
    const fence = f.model.records.get(f.context.recordName);
    assert.deepEqual(Object.keys(fence.fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    new PublicRecordRegistry(f.storage, { clock: f.clock });
  } finally { f.close(); }
});

test("acknowledgement after account deletion or tampered transfer context fails closed", async () => {
  const f = await fixture();
  try {
    const lease = await f.registry.claimAvatarTransfer(f.context, { variant: "image", sha256: sha(bytes), byteCount: bytes.length });
    assert.throws(() => f.registry.assertAvatarTransferCurrent({ ...lease, variant: "thumbnail" }), publicCode("PUBLIC_SCOPE"));
    assert.throws(() => f.registry.assertAvatarTransferCurrent({ ...lease, transferID: randomUUID() }), publicCode("PUBLIC_SCOPE"));
    const ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket);
    await assert.rejects(() => f.registry.acknowledgeAvatarTransfer(lease, sha("late"), sha("checksum"), { envelope: "synthetic-envelope", expiresAt: f.clock() + 120000 }), publicCode("PUBLIC_ERASED"));
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "erased");
  } finally { f.close(); }
});

test("a rollback before a consumed claim cannot start another upload after the remote checkpoint advanced", async () => {
  const f = await fixture();
  try {
    const before = f.db.prepare("SELECT * FROM public_registry_checkpoint_v1").get();
    await f.client().upload(f.input());
    f.db.exec("DELETE FROM avatar_asset_transfers_v1");
    f.db.prepare("UPDATE public_registry_checkpoint_v1 SET confirmed_value=?,confirmed_tag=?,pending_value=?,pending_expected_tag=?").run(
      before.confirmed_value, before.confirmed_tag, before.pending_value, before.pending_expected_tag);
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.calls.length, 2);
  } finally { f.close(); }
});

test("lost upload response stays claimed across reopen and cannot dispatch a second binary upload", async () => {
  const f = await fixture();
  try {
    f.hook(async ({ request }) => {
      if (f.calls.length === 2) { await request.arrayBuffer(); throw new Error("PRIVATE receipt/url/body details"); }
    });
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    const reopened = new PublicRecordRegistry(f.storage, { clock: f.clock });
    await assert.rejects(() => f.client({ registry: reopened }).upload(f.input()), publicCode("PUBLIC_PENDING"));
    assert.equal(f.calls.length, 2); assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
  } finally { f.close(); }
});

test("receipt durability failure releases no handle and preserves the consumed attempt", async () => {
  let armed = false;
  const f = await fixture({ syncHook: () => {
    if (armed && f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get()?.phase === "acknowledged") throw new Error("PRIVATE sync");
  } });
  try {
    armed = true;
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 2); armed = false;
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "acknowledged");
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_PENDING"));
    assert.equal(f.calls.length, 2);
  } finally { armed = false; f.close(); }
});

test("a failed claim INSERT rolls back, never sends a grant, and allows only a genuine unclaimed retry", async () => {
  let armed = false;
  const f = await fixture({ sqlHook: sql => { if (armed && sql.startsWith("INSERT INTO avatar_asset_transfers_v1")) throw new Error("PRIVATE SQL"); } });
  try {
    armed = true;
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 0);
    armed = false; await f.client().upload(f.input()); assert.equal(f.calls.length, 2);
  } finally { armed = false; f.close(); }
});

test("deletion after the binary upload prevents a late receipt from restoring transfer metadata", async () => {
  const f = await fixture();
  try {
    f.hook(async () => { if (f.calls.length === 2) { const ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket); } });
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 2);
    const row = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").get();
    assert.equal(row.phase, "erased"); assert.equal(row.receipt_hash, null); assert.equal(row.content_sha256, null);
  } finally { f.close(); }
});

test("revoking a session during grant aborts before upload and never produces a usable handle", async () => {
  const f = await fixture();
  try {
    f.hook(async () => { await f.state.revokeSession(f.signedIn.sessionToken); });
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 1); assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
  } finally { f.close(); }
});

test("erasure metadata failure cannot acknowledge deletion; retry keeps exact fences and completes", async () => {
  let armed = false;
  const f = await fixture({ sqlHook: sql => { if (armed && sql.startsWith("UPDATE avatar_asset_transfers_v1 SET phase='erased'")) throw new Error("PRIVATE erase SQL"); } });
  try {
    await f.client().upload(f.input()); const ticket = await f.beginDeletion(f.signedIn); armed = true;
    await assert.rejects(() => f.erase(ticket), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(f.context.recordName).phase, "erasing");
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "acknowledged");
    armed = false; f.advance(60001);
    assert.equal((await f.erase(ticket)).remaining, false);
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "erased");
  } finally { armed = false; f.close(); }
});

test("missing transfer table with existing avatar reservations fails closed rather than resetting attempts", async () => {
  const f = await fixture();
  try {
    await f.client().upload(f.input()); f.db.exec("DROP TABLE avatar_asset_transfers_v1");
    assert.throws(() => new PublicRecordRegistry(f.storage, { clock: f.clock }), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
  } finally { f.close(); }
});

test("a stalled response body is cancelled at the shared deadline without a binary request", async () => {
  const f = await fixture(); let cancelled = false;
  try {
    f.hook(() => new Response(new ReadableStream({
      start(controller) { controller.enqueue(new TextEncoder().encode('{"tokens":[')); },
      cancel() { cancelled = true; },
    }), { headers: { "Content-Type": "application/json" } }));
    await assert.rejects(() => f.client({ timeoutMilliseconds: 100 }).upload(f.input()), publicCode("PUBLIC_UNAVAILABLE"));
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(cancelled, true); assert.equal(f.calls.length, 1);
  } finally { f.close(); }
});

test("synchronous cancellation inside authorization cannot dispatch or leave an unhandled rejection", async () => {
  const f = await fixture();
  try {
    const controller = new AbortController();
    await assert.rejects(() => f.client().upload(f.input({ signal: controller.signal,
      authorizeMutation: () => controller.abort() })), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.calls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1").get().n, 0);
  } finally { f.close(); }
});

test("an attached avatar cannot use generic reads and exact erasure strips both assets and retained transfer metadata", async () => {
  const f = await fixture();
  try {
    const assets = f.client(), handle = await assets.upload(f.input());
    // Explicit provider model of a future enclosing-record create, not an actual Apple asset.
    f.model.records.set(f.context.recordName, { recordName: f.context.recordName, recordType: "EchoesAvatarV1", recordChangeTag: "attached-tag",
      fields: { schemaVersion: { type: "INT64", value: 1 }, ownerKey: { type: "STRING", value: f.context.ownerKey },
        erased: { type: "INT64", value: 0 }, image: assets.recordField(handle, f.fieldOptions()),
        thumbnail: { type: "ASSET", value: { ...file(1), downloadURL: "https://synthetic-asset.icloud-content.com/PRIVATE-DOWNLOAD-TOKEN" } } } });
    await f.registry.settle(f.context, "attached-tag"); await f.checkpoint.advance();
    const read = await f.repository.beginRead({ accessToken: f.signedIn.sessionToken });
    await assert.rejects(() => read.lookup([f.context.recordName], "avatar"), publicCode("PUBLIC_INPUT"));
    const ticket = await f.beginDeletion(f.signedIn); assert.equal((await f.erase(ticket)).remaining, false);
    const fields = f.model.records.get(f.context.recordName).fields;
    assert.deepEqual(Object.keys(fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "erased");
    assert.equal(f.db.prepare("SELECT receipt_hash FROM avatar_asset_transfers_v1").get().receipt_hash, null);
    assert.equal(f.model.requests.some(call => call.operation === "query"), false);
  } finally { f.close(); }
});

test("unending tiny response chunks cannot starve the timer or spend unbounded SQL reads", async () => {
  const f = await fixture(); let pulls = 0, cancelled = false;
  try {
    f.hook(() => new Response(new ReadableStream({
      pull(controller) { pulls++; controller.enqueue(new Uint8Array([32])); },
      cancel() { cancelled = true; },
    }), { headers: { "Content-Type": "application/json" } }));
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_RESPONSE"));
    assert.equal(cancelled, true); assert.ok(pulls <= 67); assert.equal(f.calls.length, 1);
  } finally { f.close(); }
});

test("clock deadline is enforced during body processing even before the timer can run", async () => {
  const f = await fixture();
  try {
    f.hook(() => new Response(new ReadableStream({
      start(controller) { f.advance(8000); controller.enqueue(new TextEncoder().encode('{}')); controller.close(); },
    }), { headers: { "Content-Type": "application/json" } }));
    await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_UNAVAILABLE")); assert.equal(f.calls.length, 1);
  } finally { f.close(); }
});


test("real fetch accepts bounded gzip grant and receipt bodies using decoded bytes", async t => {
  const f = await fixture();
  try {
    const server = await gzipJSONServer(t, () => f.calls.length === 1
      ? { tokens: [{ recordName: f.context.recordName, fieldName: "image", url }] }
      : { singleFile: file(bytes.length) });
    f.hook(({ signal }) => server.fetch(signal));
    const client = f.client(), handle = await client.upload(f.input());
    assert.equal(server.calls, 2); assert.equal(f.calls.length, 2);
    assert.deepEqual(client.recordField(handle, f.fieldOptions()), { type: "ASSET", value: file(bytes.length) });
  } finally { f.close(); }
});


test("encoded responses retain decoded bounds and identity length mismatches still block upload", async t => {
  for (const kind of ["gzip-limit", "identity-length", "unsupported-encoding"]) {
    const f = await fixture();
    try {
      if (kind === "gzip-limit") {
        const server = await gzipJSONServer(t, () => ({ padding: "p".repeat(20000) }));
        f.hook(({ signal }) => server.fetch(signal));
      } else {
        f.hook(() => Response.json({ tokens: [{ recordName: f.context.recordName, fieldName: "image", url }] },
          { headers: kind === "identity-length" ? { "Content-Length": "1" } : { "Content-Encoding": "unknown" } }));
      }
      await assert.rejects(() => f.client().upload(f.input()), publicCode("PUBLIC_RESPONSE"));
      assert.equal(f.calls.length, 1);
      assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
    } finally { f.close(); }
  }
});
