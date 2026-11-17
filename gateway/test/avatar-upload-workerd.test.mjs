import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

test("actual CommunityAuthority entry bundles static Wasm and stays disabled without activation or secrets", { timeout: 30000 }, async () => {
  const worker = await avatarWorker({ communityEntry: true });
  try {
    const health = await fetch(new URL("/health", worker.origin), { headers: { Connection: "close" } });
    assert.equal(health.status, 200); assert.equal((await health.json()).status, "ok");
    const disabled = await fetch(new URL("/v1/community/avatar/upload", worker.origin), { method: "POST",
      headers: { "Content-Type": "image/jpeg", Connection: "close" }, body: new Uint8Array([1, 2, 3]) });
    assert.equal(disabled.status, 503); assert.deepEqual(await disabled.json(), { protocolVersion: 1, error: "GATEWAY_DISABLED" });
  } finally { await worker.stop(); }
});

test("actual local workerd composes binary intake, edge, auth, SQLite, Wasm, encrypted assets and request-only recovery", { timeout: 30000 }, async () => {
  const f = await avatarUploadHTTPFixture(); let worker;
  try {
    worker = await avatarWorker();
    const value = { synthetic: "echoes-owned-upload-http-v1", now: f.clock(), token: f.signedIn.sessionToken, intent: f.body("upload"),
      source: Buffer.from(f.sourceBytes).toString("base64"), tables: sqliteSnapshot(f.db), records: [...f.model.records.values(), ...f.model.controls.values()],
      privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/upload-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(value) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(body.uploaded.status, "pending-review"); assert.equal(body.uploaded.publishedVersionID, null);
    assert.equal(body.recovered.requestID, value.intent.requestID); assert.equal(body.recovered.status, "pending-review");
    assert.equal(body.cleared.status, "none"); assert.equal(body.cleared.generation, 2); assert.equal(body.cleared.versionID, null);
    assert.deepEqual(body.status, body.cleared); assert.equal(body.uploads, 2); assert.equal(body.grants, 2);
    assert.equal(body.assetRecords, 1); assert.equal(body.actualSQL, true); assert.ok(body.signatures > 10);
    assert.doesNotMatch(JSON.stringify(body), /receipt|SYNTHETIC-PRIVATE|https:/);
  } finally { if (worker) await worker.stop(); f.close(); }
});
