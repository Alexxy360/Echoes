import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { reportReviewFixture } from "./support/community-report-review-fixture.mjs";
import { avatarReportReviewStateFixture } from "./support/avatar-report-review-state-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
for (const photo of [false, true]) test((photo ? "photo" : "message") + " retirement through actual workerd edge Runtime DO SQL survives recreation and blocks a delayed decision", { timeout: 30000 }, async t => {
  const f = photo ? await avatarReportReviewStateFixture(t) : await reportReviewFixture(t, { startAt: Date.now() }); let worker;
  try {
    if (photo) f.advance(Math.max(0, Date.now() - f.clock()));
    const operator = photo ? await f.session("synthetic.photo.report.operator") : f.operator;
    const foreign = photo ? await f.session("synthetic.reader") : f.author;
    worker = await avatarWorker({ reportEntry: !photo });
    const common = { retirement: true, now: f.clock(), operatorID: operator.accountID, reportID: photo ? f.report.context.recordName : f.report.recordName,
      tables: sqliteSnapshot(f.db), records: [...f.model.records.values(), ...f.model.controls.values()], privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const input = photo ? { ...common, synthetic: "echoes-owned-photo-report-review-v1", http: true, operatorToken: operator.sessionToken,
      foreignToken: foreign.sessionToken, authorID: f.signedIn.accountID, imageSHA256: f.publication.descriptor.image.sha256, versionID: f.publication.versionID,
      reason: f.report.input.reason, assets: [...f.uploadedBytes].map(([name, bytes]) => [name, Buffer.from(bytes).toString("base64")]) } :
      { ...common, synthetic: "echoes-owned-report-http-proof-v1", token: operator.sessionToken, authorID: f.author.accountID, authorToken: f.author.sessionToken };
    const response = await fetch(new URL(photo ? "/photo-report-review-proof" : "/report-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
    assert.deepEqual(result.retirement, { unconfirmedBefore: true, retired: true, recovered: true, lateBlocked: true, noEffect: true });
    assert.equal(result.actualSQL, true); assert.ok(result.signatures > 20); assert.equal(photo ? result.confirmedAfterRecreationAndExpiry : result.confirmedAfterNewRuntime, true);
    if (photo) assert.equal(result.downloads, 2); else assert.equal(result.hidden, true);
    assert.doesNotMatch(JSON.stringify(result), /PRIVATE|downloadURL|sessionToken|reason|https:/);
  } finally { if (worker) await worker.stop(); }
});
