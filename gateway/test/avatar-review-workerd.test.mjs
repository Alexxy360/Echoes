import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

test("actual local workerd routes protected moderation HTTP through edge and authority before exact durable decision", { timeout: 30000 }, async () => {
  const f = await avatarUploadHTTPFixture(); let worker;
  try {
    // The real platform alarm uses wall time. Issue a fresh synthetic session at that same time.
    f.advance(Math.max(0, Date.now() - f.clock())); const author = await f.relogin();
    worker = await avatarWorker();
    const input = { synthetic: "echoes-owned-upload-http-v1", review: true, now: f.clock(), token: author.sessionToken,
      intent: f.body("upload"), source: Buffer.from(f.sourceBytes).toString("base64"), tables: sqliteSnapshot(f.db),
      records: [...f.model.records.values(), ...f.model.controls.values()], privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/upload-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    assert.deepEqual(body.review, { bytesMatch: true, approved: true, notPublished: true, exactReplay: true, rejectedWithoutInspection: true,
      notApplied: true, confirmedAfterExpiry: true, expiredReceiptsRemoved: true, actualSQL: true });
    assert.equal(body.downloads, 1); assert.equal(body.uploads, 2); assert.ok(body.signatures > 20);
    assert.equal(body.cleared.status, "none"); assert.equal(body.status.status, "none");
    assert.doesNotMatch(JSON.stringify(body), /sessionToken|SYNTHETIC-PRIVATE|downloadURL|https:/);
  } finally { if (worker) await worker.stop(); f.close(); }
});


test("actual community entry leaves operator endpoints disabled without activation or secrets", { timeout: 30000 }, async () => {
  const worker = await avatarWorker({ communityEntry: true });
  try {
    for (const path of ["queue", "inspect", "decide", "recover"].map(action => "/v1/moderation/avatar/" + action).concat("/v1/community/avatar/preview")) {
      const response = await fetch(new URL(path, worker.origin), { method: "POST",
        headers: { "Content-Type": "application/json", Connection: "close" }, body: "{}" });
      assert.equal(response.status, 503); assert.equal((await response.json()).error, "GATEWAY_DISABLED");
    }
  } finally { await worker.stop(); }
});

test("actual local workerd returns the owner's approved unpublished JPEG with moderator and upload disabled", { timeout: 30000 }, async () => {
  const f = await avatarUploadHTTPFixture(); let worker;
  try {
    f.advance(Math.max(0, Date.now() - f.clock())); const author = await f.relogin(); worker = await avatarWorker();
    const input = { synthetic: "echoes-owned-upload-http-v1", review: true, ownerPreview: true, now: f.clock(), token: author.sessionToken,
      intent: f.body("upload"), source: Buffer.from(f.sourceBytes).toString("base64"), tables: sqliteSnapshot(f.db),
      records: [...f.model.records.values(), ...f.model.controls.values()], privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/upload-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    assert.deepEqual(body.ownerPreview, { bytesMatch: true, exactSelection: true, ownImage: true, privateNoStore: true, noModeratorRole: true, notPublished: true });
    assert.equal(body.downloads, 2); assert.equal(body.uploads, 2); assert.equal(body.cleared.status, "none"); assert.equal(body.status.status, "none");
    assert.doesNotMatch(JSON.stringify(body), /sessionToken|SYNTHETIC-PRIVATE|downloadURL|https:/);
  } finally { if (worker) await worker.stop(); f.close(); }
});
