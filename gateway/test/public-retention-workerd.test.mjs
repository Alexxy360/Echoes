import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { retentionFixture } from "./support/public-retention-fixture.mjs";
import { profileInput, syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";

test("real local workerd SQL and signed provider model erase expired content and restore only fresh presence", { timeout: 30000 }, async () => {
  const f = await retentionFixture(); let worker;
  try {
    const presence = await f.presence(), message = await f.message(), id = randomUUID();
    const report = await f.repository.write({ accessToken: f.session.sessionToken, kind: "report", logicalID: id, requestID: id,
      input: { messageID: message.record.recordName, reason: "SYNTHETIC-PRIVATE-REPORT" } });
    const profile = await f.repository.write(profileInput(f.session, "Trwały profil"));
    f.advance(30 * 86400000); const session = await f.refreshSession();
    worker = await avatarWorker({ retentionEntry: true });
    const response = await fetch(new URL("/retention-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ synthetic: "echoes-owned-local-retention-proof-v1", now: f.clock(), tables: sqliteSnapshot(f.db),
        records: [...f.model.records.values(), ...f.model.controls.values()], sessionToken: session.sessionToken,
        expiredNames: [presence.record.recordName, message.record.recordName, report.recordName], profileName: profile.recordName,
        oldPresenceRequestID: presence.input.requestID, presenceInput: presence.input.input,
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY }) });
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
    assert.equal(result.processed, 3); assert.equal(result.emptyFences, true); assert.equal(result.erased, 2);
    assert.equal(result.retryCode, "PUBLIC_ERASED"); assert.equal(result.presenceRestored, true);
    assert.equal(result.profilePreserved, true); assert.equal(result.occupiedAfterDrain, false);
    assert.equal(result.metadataOnly, 1); assert.ok(result.signatures >= 10);
  } finally { if (worker) await worker.stop(); f.close(); }
});
