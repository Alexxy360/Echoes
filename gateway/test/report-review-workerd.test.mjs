import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { reportReviewFixture } from "./support/community-report-review-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";

test("actual local workerd performs closed report HTTP, atomic decision and recovery through a fresh Runtime on real DO SQLite", { timeout: 30000 }, async t => {
  const f = await reportReviewFixture(t, { startAt: Date.now() }); const worker = await avatarWorker({ reportEntry: true });
  try {
    const input = { synthetic: "echoes-owned-report-http-proof-v1", now: f.clock(), token: f.operator.sessionToken, operatorID: f.operator.accountID,
      authorID: f.author.accountID, authorToken: f.author.sessionToken, reportID: f.report.recordName, tables: sqliteSnapshot(f.db),
      records: [...f.model.records.values(), ...f.model.controls.values()], privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/report-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(input) });
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
    assert.deepEqual({ ...result, signatures: 0 }, { actualSQL: true, hidden: true, closed: true, confirmedAfterNewRuntime: true,
      ordinaryDenied: true, disabled: true, noContentsInSQL: true, privateNoStore: true, signatures: 0 });
    assert.ok(result.signatures > 20); assert.doesNotMatch(JSON.stringify(result), /sessionToken|SYNTHETIC-PRIVATE|reason|https:/);
  } finally { await worker.stop(); }
});
