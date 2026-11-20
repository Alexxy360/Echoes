import { test } from "node:test";
import assert from "node:assert/strict";
import { avatarReportReviewStateFixture } from "./support/avatar-report-review-state-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

import { generateKeyPairSync } from "node:crypto";

test("real local workerd carries framed photo-report HTTP through edge Runtime authority and durable exact decision recovery", { timeout: 30000 }, async t => {
  const f = await avatarReportReviewStateFixture(t); let worker;
  try {
    // Real alarms use wall time: keep this explicit synthetic clock and session validity aligned.
    f.advance(Math.max(0, Date.now() - f.clock()));
    const operator = await f.session("synthetic.photo.report.operator"), foreign = await f.session("synthetic.reader");
    worker = await avatarWorker();
    const input = { synthetic: "echoes-owned-photo-report-review-v1", http: true, signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }), now: f.clock(), operatorID: f.operator.accountID, operatorToken: operator.sessionToken,
      foreignToken: foreign.sessionToken, authorID: f.signedIn.accountID, reportID: f.report.context.recordName,
      imageSHA256: f.publication.descriptor.image.sha256, versionID: f.publication.versionID, reason: f.report.input.reason,
      tables: sqliteSnapshot(f.db), records: [...f.model.records.values(), ...f.model.controls.values()],
      assets: [...f.uploadedBytes].map(([name, bytes]) => [name, Buffer.from(bytes).toString("base64")]), privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY };
    const response = await fetch(new URL("/photo-report-review-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body));
    for (const key of ["ordinaryDenied", "privateFrame", "exactImage", "exactReplay", "disabled", "confirmedAfterRecreationAndExpiry", "closedQueue", "actualSQL"]) assert.equal(body[key], true, key);
    assert.equal(body.queued, 1); assert.equal(body.downloads, 1); assert.ok(body.signatures >= 10);
    assert.doesNotMatch(JSON.stringify(body), /PRIVATE|downloadURL|sessionToken|https:/);
  } finally { if (worker) await worker.stop(); }
});
