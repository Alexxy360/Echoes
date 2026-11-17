import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

test("actual local workerd inspects normalized content before a durable moderation decision and exact replay", { timeout: 30000 }, async () => {
  const f = await avatarUploadHTTPFixture(); let worker;
  try {
    worker = await avatarWorker();
    const input = { synthetic: "echoes-owned-upload-http-v1", review: true, now: f.clock(), token: f.signedIn.sessionToken,
      intent: f.body("upload"), source: Buffer.from(f.sourceBytes).toString("base64"), tables: sqliteSnapshot(f.db),
      records: [...f.model.records.values(), ...f.model.controls.values()], privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/upload-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    assert.deepEqual(body.review, { bytesMatch: true, approved: true, notPublished: true, exactReplay: true, rejectedWithoutInspection: true, actualSQL: true });
    assert.equal(body.downloads, 1); assert.equal(body.uploads, 2); assert.ok(body.signatures > 20);
    assert.equal(body.cleared.status, "none"); assert.equal(body.status.status, "none");
    assert.doesNotMatch(JSON.stringify(body), /sessionToken|SYNTHETIC-PRIVATE|downloadURL|https:/);
  } finally { if (worker) await worker.stop(); f.close(); }
});
