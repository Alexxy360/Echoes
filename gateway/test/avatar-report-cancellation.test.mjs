import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint } from "../src/public-registry-checkpoint.mjs";
import { CloudKitPublicRepository } from "../src/public-record-repository.mjs";
import { retentionFixture } from "./support/public-retention-fixture.mjs";
import { sqliteSnapshot, restoreSQLite } from "./support/sqlite-snapshot.mjs";
import { avatarReportFields } from "../scripts/prepare-avatar-report-schema.mjs";
import { publicFixture, publicCode, publicClient } from "./support/public-record-fixture.mjs";
import { recordIdentity, matchesFields } from "../src/public-record-schema.mjs";
import { avatarReportCancellationFields, avatarReportCancellationKey } from "../src/avatar-report-cancellation.mjs";

const request = (session, requestID = randomUUID()) => ({ accessToken: session.sessionToken, kind: "avatarreport", logicalID: requestID, requestID, authorizeMutation: () => true,
  input: { avatarID: recordIdentity(randomUUID(), "avatar", randomUUID()).recordName, versionID: randomUUID(), publicationGeneration: 1, imageSHA256: "a".repeat(64), reason: "PRIVATE_REPORT_REASON" } });
const cancel = (f, session, requestID, changes = {}) => f.repository.cancelAvatarReport({ accessToken: session.sessionToken, requestID, authorizeMutation: () => true, ...changes });
const recover = (f, session, requestID) => f.repository.recoverAvatarReport({ accessToken: session.sessionToken, requestID, authorizeRead: () => true });
const recordOps = f => f.model.requests.filter(c => c.operation === "modify").flatMap(c => c.body.operations);

test("cancellation of an unknown own nonce creates a content-free same-identity fence and blocks any later report", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), result = await cancel(f, session, value.requestID);
    assert.equal(result.outcome, "cancelled"); const context = recordIdentity(session.accountID, "avatarreport", value.requestID), record = f.model.records.get(context.recordName);
    assert.equal(result.reportID, context.recordName); assert.ok(matchesFields(record.fields, avatarReportCancellationFields(context, avatarReportCancellationKey(session.accountID, value.requestID))));
    assert.equal(recordOps(f).length, 1); assert.equal(recordOps(f)[0].operationType, "create");
    await assert.rejects(() => f.repository.write(value), publicCode("PUBLIC_ERASED"));
    assert.equal((await recover(f, session, value.requestID)).outcome, "cancelled"); assert.equal(recordOps(f).length, 1);
    const row = f.db.prepare("SELECT * FROM public_records_v1 WHERE record_name=?").get(context.recordName);
    assert.equal(row.phase, "erased"); for (const key of ["request_id", "logical_key", "payload_hash"]) assert.equal(row[key], null);
  } finally { f.close(); }
});

test("cancellation replaces exact own report by CAS and removes every content field", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), saved = await f.repository.write(value);
    const result = await cancel(f, session, value.requestID), operation = recordOps(f).at(-1), record = f.model.records.get(saved.recordName);
    assert.equal(result.outcome, "cancelled"); assert.equal(operation.operationType, "replace"); assert.equal(operation.record.recordChangeTag, saved.recordChangeTag);
    assert.deepEqual(Object.keys(record.fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
    assert.equal(f.registry.readable(saved.recordName, "avatarreport"), null);
    const count = recordOps(f).length; await cancel(f, session, value.requestID); assert.equal(recordOps(f).length, count);
  } finally { f.close(); }
});

test("lost cancellation ACK recovers only from the exact remote fence without a second mutation", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session);
    f.model.after = call => { if (call.operation === "modify") throw Error("PRIVATE_LOST_CANCEL_ACK"); };
    await assert.rejects(() => cancel(f, session, value.requestID)); f.model.after = undefined;
    const before = recordOps(f).length;
    assert.equal((await recover(f, session, value.requestID)).outcome, "cancelled"); assert.equal(recordOps(f).length, before);
    assert.equal(f.registry.avatarReportCancellation(session.accountID, value.requestID).state, "settled");
  } finally { f.close(); }
});

test("uncommitted cancellation stays unconfirmed and read-only recovery never creates its missing fence", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session);
    f.model.before = call => { if (call.operation === "modify") throw Error("PRIVATE_CANCEL_BEFORE_COMMIT"); };
    await assert.rejects(() => cancel(f, session, value.requestID)); f.model.before = undefined;
    const count = recordOps(f).length; assert.equal((await recover(f, session, value.requestID)).outcome, "unconfirmed"); assert.equal(recordOps(f).length, count);
    assert.equal((await cancel(f, session, value.requestID)).outcome, "cancelled");
  } finally { f.close(); }
});

test("another account's same UUID cannot cancel or recover the original reporter's record", async () => {
  const f = await publicFixture();
  try {
    const a = await f.session(), b = await f.session("synthetic.other"), value = request(a), record = await f.repository.write(value);
    const result = await cancel(f, b, value.requestID); assert.notEqual(result.reportID, record.recordName); assert.deepEqual(f.model.records.get(record.recordName), record);
    assert.equal((await recover(f, a, value.requestID)).outcome, "accepted");
  } finally { f.close(); }
});

test("cancellation requires synchronous true authorization before reservation checkpoint or provider IO", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session();
    for (const guard of [() => false, () => undefined, () => Promise.resolve(true), () => Promise.reject(Error("synthetic"))]) {
      await assert.rejects(() => cancel(f, session, randomUUID(), { authorizeMutation: guard }), publicCode("PUBLIC_SCOPE"));
    }
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 0); assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

const gate = () => { let release; const promise = new Promise(r => { release = r; }); return { promise, release }; };

test("a delayed immutable CREATE cannot resurrect report content after cancellation fences its identity", async () => {
  const f = await publicFixture(), entered = gate(), release = gate();
  try {
    const session = await f.session(), value = request(session);
    f.model.before = async call => { if (call.operation === "modify" && call.body.operations.some(op => op.record.fields.erased?.value === 0)) { entered.release(); await release.promise; } };
    const original = f.repository.write(value).catch(error => error); await entered.promise;
    const client = publicClient((...args) => f.model.fetch(...args), { clock: f.clock });
    const repository = new CloudKitPublicRepository({ registry: f.registry, client, authentication: f.state, checkpoint: new PublicRegistryCheckpoint({ registry: f.registry, client }), clock: f.clock });
    assert.equal((await repository.cancelAvatarReport({ accessToken: session.sessionToken, requestID: value.requestID, authorizeMutation: () => true })).outcome, "cancelled");
    release.release(); assert.ok((await original).code); f.model.before = undefined;
    assert.equal(f.model.records.get(recordIdentity(session.accountID, "avatarreport", value.requestID).recordName).fields.erased.value, 1);
    assert.equal((await recover(f, session, value.requestID)).outcome, "cancelled");
  } finally { release.release(); f.close(); }
});

test("a CAS conflict never force-writes and exact cancellation can be explicitly resumed", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), saved = await f.repository.write(value); let changed = false;
    f.model.before = call => { if (!changed && call.operation === "modify" && call.body.operations.some(op => op.record.fields.erased?.value === 1)) { changed = true; f.model.records.get(saved.recordName).recordChangeTag = "synthetic-raced-tag"; } };
    await assert.rejects(() => cancel(f, session, value.requestID), publicCode("PUBLIC_CONFLICT"));
    assert.equal(f.model.records.get(saved.recordName).fields.erased.value, 0); assert.equal((await recover(f, session, value.requestID)).outcome, "unconfirmed");
    f.model.before = undefined; assert.equal((await cancel(f, session, value.requestID)).outcome, "cancelled");
    assert.ok(recordOps(f).every(op => !op.operationType.startsWith("force")));
  } finally { f.close(); }
});

test("an untrusted fence response with extra content is never a cancellation confirmation", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session);
    f.model.after = call => { if (call.operation === "modify") { const record = structuredClone(f.model.records.values().next().value); record.fields.reason = { type: "STRING", value: "PRIVATE_LEFTOVER" }; return Response.json({ records: [record] }); } };
    await assert.rejects(() => cancel(f, session, value.requestID), publicCode("PUBLIC_RESPONSE")); f.model.after = undefined;
    assert.equal(f.registry.avatarReportCancellation(session.accountID, value.requestID).state, "pending");
    assert.equal((await recover(f, session, value.requestID)).outcome, "cancelled");
  } finally { f.close(); }
});

test("live report tampering or foreign type owner and identity are refused before replacing anything", async () => {
  for (const mutate of [r => r.fields.reason.value = "PRIVATE_TAMPER", r => r.fields.ownerKey.value = "b".repeat(64), r => r.recordType = "EchoesReportV1"]) {
    const f = await publicFixture();
    try {
      const session = await f.session(), value = request(session), saved = await f.repository.write(value); mutate(f.model.records.get(saved.recordName));
      const count = recordOps(f).length; await assert.rejects(() => cancel(f, session, value.requestID)); assert.equal(recordOps(f).length, count);
    } finally { f.close(); }
  }
});

test("cancelled receipt requires an extant exact fence rather than a cached local flag", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), result = await cancel(f, session, value.requestID), saved = structuredClone(f.model.records.get(result.reportID));
    f.model.records.delete(result.reportID); const count = recordOps(f).length;
    assert.equal((await recover(f, session, value.requestID)).outcome, "unconfirmed"); assert.equal(recordOps(f).length, count);
    f.model.records.set(result.reportID, { ...saved, fields: { ...saved.fields, reason: { type: "STRING", value: "PRIVATE_EXTRA" } } });
    assert.equal((await recover(f, session, value.requestID)).outcome, "unconfirmed"); assert.equal(recordOps(f).length, count);
    f.model.records.set(result.reportID, saved); assert.equal((await recover(f, session, value.requestID)).outcome, "cancelled");
  } finally { f.close(); }
});

test("cancellation survives session generation changes and registry repository re-instantiation", async () => {
  const f = await publicFixture();
  try {
    const old = await f.session(), value = request(old); await cancel(f, old, value.requestID);
    await f.state.revokeAllSessions(old.sessionToken); const fresh = await f.session();
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock }), checkpoint = new PublicRegistryCheckpoint({ registry, client: f.client });
    const repository = new CloudKitPublicRepository({ registry, client: f.client, checkpoint, authentication: f.state, clock: f.clock });
    assert.equal((await repository.recoverAvatarReport({ accessToken: fresh.sessionToken, requestID: value.requestID, authorizeRead: () => true })).outcome, "cancelled");
    await assert.rejects(() => cancel(f, old, value.requestID));
    assert.equal(recordOps(f).length, 1);
  } finally { f.close(); }
});

test("an older SQLite snapshot cannot reopen a cancelled nonce without its committed checkpoint", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), before = sqliteSnapshot(f.db);
    await cancel(f, session, value.requestID); const count = recordOps(f).length;
    restoreSQLite(f.storage, before);
    await assert.rejects(() => f.repository.write(value), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await assert.rejects(() => cancel(f, session, value.requestID), publicCode("PUBLIC_REGISTRY_UNVERIFIED")); assert.equal(recordOps(f).length, count);
  } finally { f.close(); }
});

test("owner deletion cleans confirmed cancellation metadata in bounded pages without touching another account", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), other = await f.session("synthetic.other"), own = [];
    for (let n = 0; n < 27; n++) { const id = randomUUID(); own.push(id); await cancel(f, session, id); }
    const otherID = randomUUID(); await cancel(f, other, otherID);
    const ticket = await f.beginDeletion(session); const first = await f.erase(ticket); assert.equal(first.remaining, true);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1 WHERE account_id=? AND avatar_report_cancel_key IS NOT NULL").get(session.accountID).n, 2);
    f.advance(1000); assert.equal((await f.erase(ticket)).remaining, false);
    const rows = f.db.prepare("SELECT avatar_report_cancel_key,avatar_report_cancel_tag FROM public_records_v1 WHERE account_id=?").all(session.accountID);
    assert.equal(rows.length, 27); assert.ok(rows.every(row => row.avatar_report_cancel_key === null && row.avatar_report_cancel_tag === null));
    assert.equal((await recover(f, other, otherID)).outcome, "cancelled");
  } finally { f.close(); }
});

test("account deletion after a lost cancellation ACK replaces its pending fence and removes cancellation metadata", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), id = randomUUID();
    f.model.after = call => { if (call.operation === "modify") throw Error("lost cancellation response"); };
    await assert.rejects(() => cancel(f, session, id)); f.model.after = undefined;
    const ticket = await f.beginDeletion(session); await f.erase(ticket);
    const record = f.model.records.get(recordIdentity(session.accountID, "avatarreport", id).recordName);
    assert.deepEqual(Object.keys(record.fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    const row = f.db.prepare("SELECT avatar_report_cancel_key,avatar_report_cancel_tag FROM public_records_v1 WHERE record_name=?").get(record.recordName);
    assert.deepEqual({ ...row }, { avatar_report_cancel_key: null, avatar_report_cancel_tag: null });
  } finally { f.close(); }
});

test("an expired report fence can be explicitly closed as cancellation without resurrecting report data", async () => {
  const f = await retentionFixture();
  try {
    const value = request(f.session); await f.repository.write(value); f.advance(30 * 86400000); await f.step(); const fresh = await f.refreshSession();
    assert.equal((await cancel(f, fresh, value.requestID)).outcome, "cancelled");
    assert.equal((await recover(f, fresh, value.requestID)).outcome, "cancelled");
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_retention_v1").get().n, 0);
  } finally { f.close(); }
});

test("account disable during fence IO cannot complete or acknowledge cancellation", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), id = randomUUID();
    f.model.after = async call => { if (call.operation === "modify") await f.state.disableAccount(session.accountID); };
    await assert.rejects(() => cancel(f, session, id)); f.model.after = undefined;
    const row = f.db.prepare("SELECT * FROM public_records_v1").get(); assert.equal(row.avatar_report_cancel_tag, null); assert.equal(row.phase, "erasing");
  } finally { f.close(); }
});

test("cancellation fence uses only previously proposed CloudKit fields and stores no subject reason or location", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session); await f.repository.write(value); await cancel(f, session, value.requestID);
    const record = [...f.model.records.values()][0]; for (const [key, field] of Object.entries(record.fields)) assert.equal(avatarReportFields[key], field.type);
    const sql = JSON.stringify(f.db.prepare("SELECT * FROM public_records_v1").all());
    for (const raw of [value.input.reason, value.input.avatarID, value.input.versionID, value.input.imageSHA256, value.requestID]) assert.equal(sql.includes(raw), false);
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 1);
  } finally { f.close(); }
});

test("cancellation migration is additive idempotent and preserves old reports and record counts", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session), saved = await f.repository.write(value);
    f.db.exec("ALTER TABLE public_records_v1 DROP COLUMN avatar_report_cancel_tag"); f.db.exec("ALTER TABLE public_records_v1 DROP COLUMN avatar_report_cancel_key");
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock }); new PublicRecordRegistry(f.storage, { clock: f.clock });
    assert.equal(registry.readable(saved.recordName, "avatarreport").recordTag, saved.recordChangeTag);
    const row = f.db.prepare("SELECT * FROM public_records_v1").get(); assert.equal(row.avatar_report_cancel_key, null); assert.equal(row.avatar_report_cancel_tag, null);
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 1);
  } finally { f.close(); }
});

test("invalid cancellation metadata refuses registry startup instead of accepting a pretend terminal receipt", async () => {
  for (const sql of ["UPDATE public_records_v1 SET avatar_report_cancel_key=NULL", "UPDATE public_records_v1 SET avatar_report_cancel_tag='forged-tag'", "UPDATE public_records_v1 SET kind='report'", "UPDATE public_records_v1 SET phase='settled'"]) {
    const f = await publicFixture();
    try {
      const session = await f.session(); await cancel(f, session, randomUUID()); f.db.exec(sql);
      assert.throws(() => new PublicRecordRegistry(f.storage, { clock: f.clock }), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    } finally { f.close(); }
  }
  const pending = await publicFixture();
  try {
    const session = await pending.session(), id = randomUUID();
    await pending.registry.beginAvatarReportCancellation(session.accountID, id);
    pending.db.exec("UPDATE public_records_v1 SET avatar_report_cancel_key='" + "b".repeat(64) + "'");
    assert.throws(() => new PublicRecordRegistry(pending.storage, { clock: pending.clock }), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
  } finally { pending.close(); }

});

test("full own registry refuses an unknown cancellation reservation but still permits fencing an already registered report", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = request(session); await f.repository.write(value);
    for (let n = 0; n < 999; n++) { const requestID = randomUUID(); await f.registry.reserve({ accountID: session.accountID, kind: "report", logicalID: requestID, requestID, payloadHash: "b".repeat(64) }); }
    const before = recordOps(f).length;
    await assert.rejects(() => cancel(f, session, randomUUID()), publicCode("PUBLIC_LIMIT")); assert.equal(recordOps(f).length, before);
    assert.equal((await cancel(f, session, value.requestID)).outcome, "cancelled");
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope=?").get(session.accountID).value, 1000);
  } finally { f.close(); }
});

test("unfinished cancellation retains the original thirty-day retention and background cleanup confirms its fence", async () => {
  const f = await retentionFixture();
  try {
    const value = request(f.session); await f.repository.write(value); const due = f.clock() + 30 * 86400000;
    f.model.before = call => { if (call.operation === "modify") throw Error("caller disappeared before cancellation"); };
    await assert.rejects(() => cancel(f, f.session, value.requestID)); f.model.before = undefined;
    assert.equal(f.registry.retentionSchedule().dueAt, due);
    f.db.exec("DELETE FROM public_retention_v1"); assert.equal(f.registry.retentionSchedule().needsBackfill, true); assert.equal(await f.registry.backfillRetention(1), 1);
    assert.equal(f.registry.retentionSchedule().dueAt, due);
    f.advance(30 * 86400000); assert.deepEqual(await f.step(), { processed: 1 }); const fresh = await f.refreshSession();
    assert.equal((await recover(f, fresh, value.requestID)).outcome, "cancelled");
    assert.deepEqual(Object.keys([...f.model.records.values()][0].fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
  } finally { f.close(); }
});

test("an unseen cancellation has bounded retention even if its initial fence never reaches the provider", async () => {
  const f = await retentionFixture();
  try {
    const id = randomUUID(), due = f.clock() + 30 * 86400000;
    f.model.before = call => { if (call.operation === "modify") throw Error("offline fence"); };
    await assert.rejects(() => cancel(f, f.session, id)); f.model.before = undefined;
    assert.equal(f.registry.retentionSchedule().dueAt, due); f.advance(30 * 86400000); assert.deepEqual(await f.step(), { processed: 1 });
    const fresh = await f.refreshSession(); assert.equal((await recover(f, fresh, id)).outcome, "cancelled");
  } finally { f.close(); }
});
