import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { retentionFixture } from "./support/public-retention-fixture.mjs";
import { profileInput, syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { maintenanceRuntimeFixture } from "./support/maintenance-runtime-fixture.mjs";
import { setTimeout as delay } from "node:timers/promises";
import { avatarPublicationFixture } from "./support/avatar-publication-fixture.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";

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

test("real local workerd fences a superseded avatar, removes its transfer metadata and preserves the current picture", { timeout: 30000 }, async () => {
  const f = await avatarPublicationFixture(); let worker;
  try {
    const old = await f.call("prepareUpload", f.upload()), current = await f.call("prepareUpload", f.upload());
    const oldName = recordIdentity(f.signedIn.accountID, "avatar", old.versionID).recordName;
    const currentName = recordIdentity(f.signedIn.accountID, "avatar", current.versionID).recordName;
    const presenceInput = { name: "Maja", latitude: 51.1123456, longitude: 17.0345678, song: "Synthetic song", songID: "123", generation: 0, measuredAt: f.clock() };
    const oldPresenceRequestID = randomUUID();
    const presence = await f.repository.writeLatest({ accessToken: f.signedIn.sessionToken, kind: "presence", logicalID: "singleton",
      requestID: oldPresenceRequestID, input: presenceInput, authorizeMutation() {} });
    const messageID = randomUUID(), message = await f.repository.write({ accessToken: f.signedIn.sessionToken, kind: "message", logicalID: messageID,
      requestID: messageID, input: { name: "Maja", text: "Syntetyczna wiadomość", latitude: 51.1123456, longitude: 17.0345678 } });
    const profile = await f.repository.write(profileInput(f.signedIn, "Trwały profil"));
    f.advance(86400000); await f.relogin();
    worker = await avatarWorker({ retentionEntry: true });
    const response = await fetch(new URL("/retention-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ synthetic: "echoes-owned-local-retention-proof-v1", now: f.clock(), tables: sqliteSnapshot(f.db),
        records: [...f.model.records.values(), ...f.model.controls.values()], sessionToken: f.signedIn.sessionToken,
        expiredNames: [presence.recordName, message.recordName, oldName], profileName: profile.recordName,
        oldPresenceRequestID, presenceInput, retiredAvatarName: oldName, currentAvatarName: currentName,
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY }) });
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
    assert.equal(result.processed, 3); assert.equal(result.emptyFences, true); assert.equal(result.erased, 2);
    assert.equal(result.avatarTransfersRemaining, 0); assert.equal(result.currentAvatarPreserved, true);
    assert.equal(result.presenceRestored, true); assert.equal(result.profilePreserved, true); assert.equal(result.occupiedAfterDrain, false);
  } finally { if (worker) await worker.stop(); f.close(); }
});

test("real local workerd expires the current staging selection and preserves its terminal snapshot after fencing", { timeout: 30000 }, async () => {
  const f = await avatarPublicationFixture(); let worker;
  try {
    const selected = await f.call("prepareUpload", f.upload()), id = recordIdentity(f.signedIn.accountID, "avatar", selected.versionID).recordName;
    const presenceInput = { name: "Maja", latitude: 51.1123456, longitude: 17.0345678, song: "Synthetic song", songID: "123", generation: 0, measuredAt: f.clock() };
    const oldPresenceRequestID = randomUUID();
    const presence = await f.repository.writeLatest({ accessToken: f.signedIn.sessionToken, kind: "presence", logicalID: "singleton",
      requestID: oldPresenceRequestID, input: presenceInput, authorizeMutation() {} });
    const messageID = randomUUID(), message = await f.repository.write({ accessToken: f.signedIn.sessionToken, kind: "message", logicalID: messageID,
      requestID: messageID, input: { name: "Maja", text: "Syntetyczna wiadomość", latitude: 51.1123456, longitude: 17.0345678 } });
    const profile = await f.repository.write(profileInput(f.signedIn, "Trwały profil"));
    f.advance(8 * 86400000); await f.relogin();
    worker = await avatarWorker({ retentionEntry: true });
    const response = await fetch(new URL("/retention-proof", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ synthetic: "echoes-owned-local-retention-proof-v1", now: f.clock(), tables: sqliteSnapshot(f.db),
        records: [...f.model.records.values(), ...f.model.controls.values()], sessionToken: f.signedIn.sessionToken,
        expiredNames: [presence.recordName, message.recordName, id], profileName: profile.recordName,
        oldPresenceRequestID, presenceInput, retiredAvatarName: id, expiredAvatarAccountID: f.signedIn.accountID,
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY }) });
    const result = await response.json(); assert.equal(response.status, 200, JSON.stringify(result));
    assert.equal(result.processed, 3); assert.equal(result.emptyFences, true); assert.equal(result.erased, 2);
    assert.equal(result.avatarTransfersRemaining, 0); assert.equal(result.expiredSelectionRetained, true);
    assert.equal(result.presenceRestored, true); assert.equal(result.profilePreserved, true);
  } finally { if (worker) await worker.stop(); f.close(); }
});

test("real local workerd delivers a native alarm through Runtime and its independent durable maintenance budget", { timeout: 30000 }, async () => {
  const f = await maintenanceRuntimeFixture(); let worker;
  try {
    const presence = await f.repository.writeLatest({ accessToken: f.signedIn.sessionToken, kind: "presence", logicalID: "singleton", requestID: randomUUID(),
      input: { name: "Maja", latitude: 51.1123456, longitude: 17.0345678, song: "Synthetic song", songID: "123", generation: 0, measuredAt: f.clock() }, authorizeMutation() {} });
    const message = await f.message(), id = randomUUID();
    const report = await f.repository.write({ accessToken: f.signedIn.sessionToken, kind: "report", logicalID: id, requestID: id,
      input: { messageID: message.record.recordName, reason: "SYNTHETIC-PRIVATE-REPORT" } });
    const profile = await f.repository.write(profileInput(f.signedIn, "Trwały profil"));
    f.advance(30 * 86400000);
    f.activate({ PUBLIC_RETENTION_ENABLED: "1", GATEWAY_EXPIRES_AT: new Date(f.clock() + 6 * 86400000).toISOString() });
    worker = await avatarWorker({ retentionEntry: true });
    const response = await fetch(new URL("/maintenance-start", worker.origin), { method: "POST", headers: { "Content-Type": "application/json", Connection: "close" },
      body: JSON.stringify({ synthetic: "echoes-owned-local-retention-proof-v1", now: f.clock(), tables: sqliteSnapshot(f.db), env: f.env,
        records: [...f.model.records.values(), ...f.model.controls.values()],
        expiredNames: [presence.recordName, message.record.recordName, report.recordName], profileName: profile.recordName,
        privateKeyPEM: syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY }) });
    assert.equal(response.status, 202, await response.text());
    let result;
    for (let i = 0; i < 100; i++) {
      result = await (await fetch(new URL("/maintenance-status", worker.origin), { headers: { Connection: "close" } })).json();
      if (!result.pending) break;
      await delay(50);
    }
    assert.equal(result.pending, undefined, "Native workerd alarm did not deliver within five seconds");
    assert.equal(result.error, undefined, JSON.stringify(result));
    assert.equal(result.deliveries, 1); assert.equal(result.emptyFences, true); assert.equal(result.erased, 2);
    assert.equal(result.profilePreserved, true); assert.equal(result.metadataOnly, 1); assert.ok(result.signatures >= 6);
    assert.deepEqual(result.budget, [{ total: 1, deletion: 0, retention: 1 }]); assert.equal(result.nextAlarm, null);
  } finally { if (worker) await worker.stop(); f.close(); }
});
