import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { publicFixture, syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";

test("real local workerd SQLite signatures fence known and unseen report attempts and recover lost cancellation ACK without mutation and retain background expiry", { timeout: 30000 }, async () => {
  const f = await publicFixture(); let worker;
  try {
    const session = await f.session(), knownRequestID = randomUUID(), unknownRequestID = randomUUID(), retentionRequestID = randomUUID();
    const original = await f.repository.write({ accessToken: session.sessionToken, kind: "avatarreport", logicalID: knownRequestID, requestID: knownRequestID, authorizeMutation: () => true,
      input: { avatarID: recordIdentity(randomUUID(), "avatar", randomUUID()).recordName, versionID: randomUUID(), publicationGeneration: 1, imageSHA256: "a".repeat(64), reason: "PRIVATE_SYNTHETIC_CANCEL_REASON" } });
    await f.repository.write({ accessToken: session.sessionToken, kind: "avatarreport", logicalID: retentionRequestID, requestID: retentionRequestID, authorizeMutation: () => true,
      input: { avatarID: recordIdentity(randomUUID(), "avatar", randomUUID()).recordName, versionID: randomUUID(), publicationGeneration: 1, imageSHA256: "b".repeat(64), reason: "PRIVATE_BACKGROUND_CANCEL_REASON" } });
    worker = await avatarWorker();
    const body = { synthetic: "echoes-owned-local-report-cancellation-v1", now: f.clock(), accessToken: session.sessionToken, accountID: session.accountID, knownRequestID, unknownRequestID, retentionRequestID, original,
      allowedRecordNames: [knownRequestID, unknownRequestID, retentionRequestID].map(id => recordIdentity(session.accountID, "avatarreport", id).recordName),
      records: [...f.model.records.values(), ...f.model.controls.values()], tables: sqliteSnapshot(f.db), privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY };
    const response = await fetch(new URL("/photo-report-cancellation-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" }, body: JSON.stringify(body) });
    const value = await response.json(); assert.equal(response.status, 200, JSON.stringify(value));
    assert.equal(value.known.outcome, "cancelled"); assert.equal(value.uncertain, true); assert.equal(value.recovery.outcome, "cancelled");
    assert.equal(value.beforeRecovery, 2); assert.equal(value.afterRecovery, 2); assert.equal(value.delayedCode, "EXISTS"); assert.deepEqual(value.background, { processed: 1 }); assert.equal(value.remainingRetention, 0);
    for (const record of value.records) assert.deepEqual(record.fields, ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
    assert.ok(value.rows.every(row => row.phase === "erased" && row.request_id === null && row.payload_hash === null && typeof row.avatar_report_cancel_tag === "string"));
    assert.equal(value.rows.length, 3); assert.equal(JSON.stringify(value).includes("PRIVATE_SYNTHETIC_CANCEL_REASON"), false); assert.equal(JSON.stringify(value).includes("PRIVATE_BACKGROUND_CANCEL_REASON"), false);
  } finally { if (worker) await worker.stop(); f.close(); }
});
