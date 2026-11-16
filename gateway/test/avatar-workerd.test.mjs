import assert from "node:assert/strict";
import { test } from "node:test";
import { AvatarNormalizer, normalizedAvatarManifest } from "../src/avatar-normalizer.mjs";
import { avatarCodecs, avatarImage, withAvatarMetadata, markerOffset, invalidAvatarHuffman } from "./support/avatar-image-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";

test("real workerd Durable Object normalizes the same synthetic bytes as Node and rejects corrupt input", { timeout: 30000 }, async () => {
  const server = await avatarWorker();
  try {
    const bytes = withAvatarMetadata(await avatarImage({ width: 256, height: 128 }));
    const n = new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => true });
    const handle = await n.prepare({ bytes, versionID: "64000000-0000-4000-8000-000000000002",
      requestID: "64000000-0000-4000-8000-000000000003", authorize: () => ({ accountID: "64000000-0000-4000-8000-000000000001" }) });
    const response = await fetch(server.origin, { method: "POST", body: bytes, headers: { Connection: "close" } });
    const value = await response.json();
    assert.equal(response.status, 200, JSON.stringify(value)); assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual(value, { image: normalizedAvatarManifest(handle, "image"), thumbnail: normalizedAvatarManifest(handle, "thumbnail"), sqlAvailable: true, receiptCryptoAvailable: true });
    const invalid = await fetch(server.origin, { method: "POST", body: new Uint8Array([255, 216, 255, 217]), headers: { Connection: "close" } });
    assert.equal(invalid.status, 400); assert.deepEqual(await invalid.json(), { error: "PUBLIC_INPUT" });
    const scan = markerOffset(bytes, 0xda), end = scan + 2 + ((bytes[scan + 2] << 8) | bytes[scan + 3]);
    const cut = new Uint8Array([...bytes.subarray(0, end + 1), 255, 217]);
    const corrupted = await fetch(server.origin, { method: "POST", body: cut, headers: { Connection: "close" } });
    assert.equal(corrupted.status, 400);
    const fatal = await fetch(server.origin, { method: "POST", body: invalidAvatarHuffman(bytes), headers: { Connection: "close" } });
    assert.equal(fatal.status, 400);
    const healthy = await fetch(server.origin, { method: "POST", body: bytes, headers: { Connection: "close" } });
    assert.equal(healthy.status, 200);
    const large = await avatarImage({ width: 512, height: 512, noise: true });
    const worstCase = await fetch(server.origin, { method: "POST", body: large, headers: { Connection: "close" } });
    assert.equal(worstCase.status, 200);
    const limits = await worstCase.json();
    assert.equal(limits.image.width, 512); assert.equal(limits.image.height, 512); assert.ok(limits.image.byteCount <= 256000);
    assert.equal(limits.thumbnail.width, 128); assert.ok(limits.thumbnail.byteCount <= 32000); assert.equal(limits.sqlAvailable, true);
  } finally { await server.stop(); }
});
