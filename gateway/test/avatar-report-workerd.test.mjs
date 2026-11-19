import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID, generateKeyPairSync } from "node:crypto";
import { avatarReportFixture } from "./support/avatar-report-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";

test("real local workerd edge/Runtime/DO SQLite signs exact photo reports and recovers lost ACK after Runtime recreation without another CREATE", { timeout: 30000 }, async () => {
  const f = await avatarReportFixture(); let worker;
  try {
    worker = await avatarWorker();
    const { accessToken, ...first } = f.reportInput(), second = { ...first, requestID: randomUUID() };
    const body = { synthetic: "echoes-owned-local-photo-report-v1", now: f.clock(), accessToken, foreignToken: f.signedIn.sessionToken, first, second,
      tables: sqliteSnapshot(f.db), records: [...f.model.records.values(), ...f.model.controls.values()],
      allowedReportIDs: [first, second].map(input => recordIdentity(f.viewer.accountID, "avatarreport", input.requestID).recordName),
      privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }) };
    const response = await fetch(new URL("/photo-report-proof", worker.origin), { method: "POST", body: JSON.stringify(body), headers: { "Content-Type": "application/json", Connection: "close" } });
    const value = await response.json(); assert.equal(response.status, 200, JSON.stringify(value));
    assert.equal(value.accepted.status, 200); assert.equal(value.accepted.body.outcome, "accepted");
    assert.equal(value.unknown.status, 503); assert.equal(value.lostACK, true);
    assert.equal(value.recovered.status, 200); assert.equal(value.recovered.body.outcome, "accepted"); assert.equal(value.recovered.body.requestID, second.requestID);
    assert.equal(value.recovered.body.reportID, body.allowedReportIDs[1]); assert.equal(value.creates, 2); assert.equal(value.beforeRecovery, 2);
    assert.equal(value.foreign.status, 200); assert.equal(value.foreign.body.outcome, "unconfirmed"); assert.notEqual(value.foreign.body.reportID, value.recovered.body.reportID);
    assert.deepEqual(value.deniedSubmit, { status: 503, body: { protocolVersion: 1, error: "FEATURE_DISABLED" } }); assert.deepEqual(value.disabled, value.deniedSubmit);
    assert.equal(value.intents.length, 2); assert.ok(value.intents.every(r => r.ready === 1));
    assert.ok(value.budgetRows.some(r => r.kind === "avatar-report-submit" && r.count === 2)); assert.ok(value.lookups > 0);
    assert.equal(JSON.stringify(value).includes(first.reason), false); assert.equal(JSON.stringify(value).includes(f.signedIn.accountID), false);
  } finally { if (worker) await worker.stop(); f.close(); }
});
