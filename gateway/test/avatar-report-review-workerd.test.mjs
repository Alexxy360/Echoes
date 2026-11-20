import { test } from "node:test";
import assert from "node:assert/strict";
import { avatarReportReviewStateFixture } from "./support/avatar-report-review-state-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

test("real local workerd uses DO SQLite, signed provider reads and protected JPEG before exact photo-report decision and readonly recovery", { timeout: 30000 }, async t => {
  const f = await avatarReportReviewStateFixture(t); let worker;
  try {
    worker = await avatarWorker();
    const input = { synthetic: "echoes-owned-photo-report-review-v1", now: f.clock(), operatorID: f.operator.accountID, operatorToken: f.operator.sessionToken,
      foreignToken: f.viewer.sessionToken, authorID: f.signedIn.accountID, reportID: f.report.context.recordName,
      imageSHA256: f.publication.descriptor.image.sha256, versionID: f.publication.versionID, reason: f.report.input.reason,
      tables: sqliteSnapshot(f.db), records: [...f.model.records.values(), ...f.model.controls.values()],
      assets: [...f.uploadedBytes].map(([name, bytes]) => [name, Buffer.from(bytes).toString("base64")]), privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY };
    const response = await fetch(new URL("/photo-report-review-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    for (const key of ["ordinaryDenied", "revoked", "exactImage", "exactReplay", "rejected", "confirmedAfterRecreationAndExpiry", "closedQueue", "actualSQL"]) assert.equal(body[key], true, key);
    assert.equal(body.queued, 1); assert.equal(body.downloads, 1); assert.ok(body.signatures >= 10);
    assert.doesNotMatch(JSON.stringify(body), /PRIVATE|downloadURL|sessionToken|https:/);
  } finally { if (worker) await worker.stop(); }
});
