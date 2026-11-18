import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { avatarPublicationFixture } from "./support/avatar-publication-fixture.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { CloudKitPublicRetentionProcessor } from "../src/public-retention-processor.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { avatarRetirementGraceMilliseconds as grace } from "../src/avatar-retirement-state.mjs";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createGatewayLocalMaintenance } from "../src/gateway-runtime.mjs";
import { fixture } from "./support/authentication-fixture.mjs";

const stage = f => f.call("prepareUpload", f.upload());
const clear = f => f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.policy.snapshot(f.signedIn.accountID).generation }));
const name = (f, status) => recordIdentity(f.signedIn.accountID, "avatar", status.versionID).recordName;
const phase = (f, id) => f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(id).phase;
const makeProcessor = f => new CloudKitPublicRetentionProcessor({ registry: f.registry, client: f.client, checkpoint: f.checkpoint, clock: f.clock, isEnabled: () => true });
const step = async f => { const p = makeProcessor(f), r = await p.step(); await tick(); return r; };
const fence = (f, id) => {
  const record = f.model.records.get(id);
  assert.deepEqual(Object.keys(record.fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
  assert.equal(record.fields.erased.value, 1); assert.equal(phase(f, id), "erased");
};

test("withdrawing a staged photo retires its exact version and later removes both asset fields and local secrets", async () => {
  const f = await avatarPublicationFixture();
  try {
    const status = await stage(f), id = name(f, status), old = f.registry.owned(f.signedIn.accountID, "avatar", status.versionID);
    await clear(f); const retired = f.db.prepare("SELECT * FROM avatar_retirements_v1").get();
    assert.equal(retired.record_name, id); assert.equal(retired.request_id, status.requestID); assert.equal(retired.retired_at, f.clock());
    assert.equal(f.registry.readable(id, "avatar"), null);
    assert.throws(() => f.registry.assertMutationCurrent(old), e => e.code === "PUBLIC_ERASED");
    const before = f.model.requests.length; assert.equal((await step(f)).processed, 0); assert.equal(f.model.requests.length, before);
    f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, id);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE record_name=?").get(id).n, 0);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1 WHERE request_id=?").get(status.requestID).n, 0);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_retirements_v1").get().n, 0);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "none");
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 2);
  } finally { f.close(); }
});

test("retiring a superseded picture preserves the new approved publication and its asset commitments", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f), current = await stage(f), id = name(f, current);
    await f.call("prepareReview", f.review(current));
    const approved = await f.call("prepareStatus", f.credentials());
    await f.call("preparePublish", f.credentials(f.publication(approved)));
    const saved = structuredClone(f.model.records.get(id)), publication = f.policy.readPublication(f.signedIn.accountID);
    f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, name(f, old));
    assert.deepEqual(f.model.records.get(id), saved); assert.equal(f.policy.readPublication(f.signedIn.accountID).versionID, current.versionID);
    assert.equal(f.policy.assertReadPublication(publication).stagedTag, publication.stagedTag);
    assert.equal(f.registry.readAvatarAssetCommitments(publication.avatar).image.sha256, publication.descriptor.image.sha256);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published");
  } finally { f.close(); }
});

test("failed or idempotent selection changes cannot retire a current photo or extend an existing retirement deadline", async () => {
  const f = await avatarPublicationFixture();
  try {
    const current = await stage(f);
    await assert.rejects(() => f.call("prepareUpload", f.upload({ expectedGeneration: 0 })), e => e.code === "AVATAR_STALE");
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_retirements_v1").get().n, 0);
    const requestID = randomUUID(), expectedGeneration = current.generation;
    await f.call("prepareClear", f.credentials({ requestID, expectedGeneration }));
    const original = f.db.prepare("SELECT * FROM avatar_retirements_v1").get();
    await f.registry.backfillRetention(); const dueAt = f.registry.retentionSchedule().dueAt;
    f.advance(60000); await f.call("prepareClear", f.credentials({ requestID, expectedGeneration })); await f.registry.backfillRetention();
    assert.deepEqual(f.db.prepare("SELECT * FROM avatar_retirements_v1").get(), original); assert.equal(f.registry.retentionSchedule().dueAt, dueAt);
  } finally { f.close(); }
});

test("bounded legacy backfill discovers historical versions after clear and keeps the latest selection untouched", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f); await clear(f);
    f.db.prepare("DELETE FROM avatar_retirements_v1").run(); // Simulate the older policy schema, before retirement tracking.
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
    assert.equal(registry.retentionSchedule().needsBackfill, true);
    assert.equal(await registry.backfillRetention(1), 1);
    assert.equal(registry.retentionSchedule().needsBackfill, false);
    assert.equal(f.db.prepare("SELECT record_name FROM avatar_retirements_v1").get().record_name, name(f, old));
    assert.equal(registry.retentionSchedule().dueAt, f.clock() + grace);
    f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, name(f, old));
  } finally { f.close(); }
});

test("a late original CREATE cannot resurrect a photo withdrawn while its provider response was held", async () => {
  const f = await avatarPublicationFixture(); let release, entered;
  const held = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  try {
    const input = f.upload(), id = recordIdentity(f.signedIn.accountID, "avatar", input.versionID).recordName;
    f.setRecordHook(async call => {
      if (call.operation === "modify" && call.body.operations.some(op => op.operationType === "create" && op.record.recordName === id)) { entered(); await held; }
    });
    const original = assert.rejects(() => f.call("prepareUpload", input)); await started;
    await clear(f); f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, id);
    release(); await original; await f.client.waitForPendingOperations(); fence(f, id);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE record_name=?").get(id).n, 0);
  } finally { release(); await tick(); f.close(); }
});

test("a forged retirement for the current picture fails before photo IO instead of deleting its assets", async () => {
  const f = await avatarPublicationFixture();
  try {
    const current = await stage(f), id = name(f, current);
    f.db.prepare("INSERT INTO avatar_retirements_v1(record_name,account_id,request_id,version_id,retired_at) VALUES(?,?,?,?,?)")
      .run(id, f.signedIn.accountID, current.requestID, current.versionID, f.clock());
    f.advance(grace); const before = f.model.requests.length;
    await assert.rejects(() => step(f), e => e.code === "PUBLIC_REGISTRY_UNVERIFIED");
    assert.equal(f.model.requests.length, before); assert.ok(f.model.records.get(id).fields.image);
  } finally { f.close(); }
});

test("unknown retirement writes stay retryable and an actual account deletion has priority over avatar retention", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f), id = name(f, old); await clear(f); f.advance(grace);
    f.setRecordHook(call => { if (call.operation === "modify" && call.body.operations.some(op => op.record.recordName === id)) throw new Error("Synthetic lost reply"); });
    await assert.rejects(() => step(f)); assert.equal(phase(f, id), "settled");
    assert.equal(f.db.prepare("SELECT state FROM public_retention_v1 WHERE record_name=?").get(id).state, "fencing");
    f.setRecordHook(undefined); await f.relogin(); const ticket = await f.beginDeletion(f.signedIn); f.advance(60001);
    assert.equal((await step(f)).processed, 0); const receipt = await f.erase(ticket); assert.equal(receipt.remaining, false);
    assert.equal(f.model.records.get(id).fields.retentionKey, undefined); assert.ok(f.model.records.get(id).fields.deletionKey);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_retirements_v1").get().n, 0);
  } finally { f.close(); }
});

test("retired avatar metadata and leases survive a fresh registry instance without reopening mutation access", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f), id = name(f, old), context = f.registry.owned(f.signedIn.accountID, "avatar", old.versionID);
    await clear(f); await f.registry.backfillRetention(); f.advance(grace);
    const reopened = new PublicRecordRegistry(f.storage, { clock: f.clock }), leases = await reopened.claimExpiredRecords();
    assert.equal(leases.length, 1); assert.equal(leases[0].context.recordName, id);
    assert.throws(() => reopened.assertMutationCurrent(context), e => e.code === "PUBLIC_ERASED");
    assert.equal(reopened.assertRetentionCurrent(leases[0]).recordName, id);
  } finally { f.close(); }
});

test("retirement is atomic with a selection transaction and survives an unknown durability response", async () => {
  let failSQL = false, failSync = false;
  const f = await avatarPublicationFixture({
    sqlHook(sql) { if (failSQL && sql.startsWith("INSERT INTO avatar_profiles_v1")) throw new Error("Synthetic SQL failure"); },
    async syncHook() { if (failSync) throw new Error("Synthetic durability failure"); },
  });
  try {
    const current = await stage(f), id = name(f, current), input = { accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: current.generation };
    failSQL = true; await assert.rejects(() => f.policy.clear(input)); failSQL = false;
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_retirements_v1").get().n, 0);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).versionID, current.versionID);
    failSync = true; await assert.rejects(() => f.policy.clear(input)); failSync = false;
    assert.equal(f.policy.snapshot(f.signedIn.accountID).versionID, null);
    assert.equal(f.db.prepare("SELECT record_name FROM avatar_retirements_v1").get().record_name, id);
    f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, id);
  } finally { failSQL = false; failSync = false; f.close(); }
});

test("file-backed reopen preserves retirement time and provider fencing without a fresh upload", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-photo-retirement-")), path = join(directory, "state.sqlite");
  let f = await avatarPublicationFixture({ path });
  try {
    const old = await stage(f), id = name(f, old); await clear(f); await f.registry.backfillRetention();
    const saved = { records: structuredClone(f.model.records), controls: structuredClone(f.model.controls), sequence: f.model.sequence,
      retirement: { ...f.db.prepare("SELECT * FROM avatar_retirements_v1").get() } };
    f.close(); f = await avatarPublicationFixture({ path, bootstrap: false });
    f.model.records = saved.records; f.model.controls = saved.controls; f.model.sequence = saved.sequence;
    assert.deepEqual({ ...f.db.prepare("SELECT * FROM avatar_retirements_v1").get() }, saved.retirement);
    f.advance(grace); assert.equal((await step(f)).processed, 1); fence(f, id); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); rmSync(directory, { recursive: true }); }
});

test("key-free local maintenance expires encrypted upload receipts while retaining consumed transfers and source scope", async () => {
  const f = await avatarPublicationFixture(); let alarm = null;
  try {
    f.setRecordHook(call => { if (call.operation === "modify" && call.body.operations.some(op => op.record.recordType === "EchoesAvatarV1")) throw new Error("Synthetic lost create reply"); });
    await assert.rejects(() => stage(f)); f.setRecordHook(undefined);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE receipt_envelope IS NOT NULL").get().n, 2);
    const before = f.model.requests.length; f.advance(128001);
    Object.assign(f.storage, { async getAlarm() { return alarm; }, async setAlarm(value) { alarm = value; }, async deleteAlarm() { alarm = null; } });
    await createGatewayLocalMaintenance(f.storage, { clock: f.clock }).alarm();
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE receipt_envelope IS NOT NULL").get().n, 0);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE phase='acknowledged'").get().n, 2);
    assert.equal(f.db.prepare("SELECT asset_claims FROM public_records_v1 WHERE kind='avatar'").get().asset_claims, 3);
    assert.equal(f.model.requests.length, before); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "uploading");
  } finally { f.close(); }
});

test("an incomplete or corrupt current selection cannot authorize retirement of historical assets", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f), id = name(f, old); await clear(f); await f.registry.backfillRetention(); f.advance(grace);
    const original = { ...f.db.prepare("SELECT * FROM avatar_profiles_v1").get() }, before = f.model.requests.length;
    for (const [column, value] of [["request_id", null], ["version_id", "foreign-invalid"], ["generation", 0], ["updated_at", f.clock() + 1]]) {
      f.db.prepare(`UPDATE avatar_profiles_v1 SET ${column}=?`).run(value);
      await assert.rejects(() => step(f), e => e.code === "PUBLIC_REGISTRY_UNVERIFIED");
      assert.equal(f.model.requests.length, before); assert.ok(f.model.records.get(id).fields.image);
      f.db.prepare(`UPDATE avatar_profiles_v1 SET ${column}=?`).run(original[column]);
    }
    assert.equal((await step(f)).processed, 1); fence(f, id);
  } finally { f.close(); }
});

test("local cleanup accepts the older transfer schema with no receipt column without needing provider keys", async () => {
  const f = fixture(); let alarm = null;
  try {
    f.db.exec("CREATE TABLE avatar_asset_transfers_v1(record_name TEXT,variant TEXT,phase TEXT)");
    f.db.prepare("INSERT INTO avatar_asset_transfers_v1 VALUES('synthetic-owned','image','claimed')").run();
    Object.assign(f.storage, { async getAlarm() { return alarm; }, async setAlarm(value) { alarm = value; }, async deleteAlarm() { alarm = null; } });
    await createGatewayLocalMaintenance(f.storage, { clock: f.clock }).alarm();
    assert.equal(alarm, null); assert.equal(f.db.prepare("SELECT phase FROM avatar_asset_transfers_v1").get().phase, "claimed");
  } finally { f.close(); }
});

test("a rolled-back clock cannot replace a later clear intent or move its retirement deadline backwards", async () => {
  const f = await avatarPublicationFixture();
  try {
    await stage(f); await clear(f); f.advance(1000); await clear(f);
    const before = { ...f.db.prepare("SELECT * FROM avatar_profiles_v1").get() };
    f.advance(-1); await assert.rejects(() => f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: before.generation }));
    assert.deepEqual({ ...f.db.prepare("SELECT * FROM avatar_profiles_v1").get() }, before);
  } finally { f.close(); }
});
