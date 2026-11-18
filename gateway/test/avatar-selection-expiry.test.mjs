import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { avatarPublicationFixture } from "./support/avatar-publication-fixture.mjs";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { CloudKitPublicRetentionProcessor } from "../src/public-retention-processor.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { avatarMutationSnapshot } from "../src/avatar-upload-http.mjs";
import { avatarSelectionLifetimeMilliseconds as lifetime } from "../src/avatar-selection-expiry.mjs";
import { exportAvatarExpiryNativeFixture } from "../scripts/export-avatar-expiry-native-fixture.mjs";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const day = 86400000;
const stage = f => f.call("prepareUpload", f.upload());
const snapshot = f => f.policy.snapshot(f.signedIn.accountID, { allowUnpersistedExpiry: true });
const recordName = (f, status) => recordIdentity(f.signedIn.accountID, "avatar", status.versionID).recordName;
const step = async f => {
  const p = new CloudKitPublicRetentionProcessor({ registry: f.registry, client: f.client, checkpoint: f.checkpoint, clock: f.clock, isEnabled: () => true });
  const r = await p.step(); await tick(); return r;
};
const selectOnly = f => f.policy.select({ accountID: f.signedIn.accountID, requestID: randomUUID(), versionID: randomUUID(),
  expectedGeneration: snapshot(f).generation, sourceHash: "a".repeat(64), consentVersion: 1 });
const clearOnly = f => f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: snapshot(f).generation });

test("an unfinished selection expires exactly after seven days before any alarm and cannot dispatch a late upload", async () => {
  const f = await avatarPublicationFixture();
  try {
    const original = await selectOnly(f);
    f.advance(lifetime - 1); assert.equal(snapshot(f).status, "uploading"); f.advance(1);
    const expired = snapshot(f); assert.equal(expired.status, "expired"); assert.equal(expired.requestID, original.requestID);
    assert.throws(() => f.policy.snapshot(f.signedIn.accountID), e => e.code === "AVATAR_PENDING");
    assert.equal(expired.versionID, original.versionID); assert.equal(expired.generation, original.generation);
    assert.equal(expired.publishedVersionID, null); assert.ok(expired.reviewRevision); assert.deepEqual(avatarMutationSnapshot(expired), expired);
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, null);
    assert.throws(() => f.policy.intent(f.signedIn.accountID, original.requestID), e => e.code === "AVATAR_STALE");
    const before = f.assetCalls.length;
    await f.relogin(); await assert.rejects(() => f.call("prepareUpload", f.upload({ requestID: original.requestID,
      versionID: original.versionID, expectedGeneration: original.generation - 1 })), e => e.code === "AVATAR_STALE");
    assert.equal(f.assetCalls.length, before);
    await f.registry.backfillRetention(); assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1").get().n, 0);
    assert.equal(snapshot(f).status, "expired"); assert.equal(f.registry.retentionSchedule().dueAt, null);
    const next = await selectOnly(f); assert.equal(next.generation, original.generation + 1); assert.equal(snapshot(f).status, "uploading");
  } finally { f.close(); }
});

test("expired staged content is hidden immediately, fences later, and remains a recoverable terminal owner snapshot", async () => {
  const f = await avatarPublicationFixture();
  try {
    const original = await stage(f), id = recordName(f, original), context = f.registry.owned(f.signedIn.accountID, "avatar", original.versionID);
    f.advance(lifetime); assert.equal(snapshot(f).status, "expired"); assert.equal(f.registry.readable(id, "avatar"), null);
    assert.throws(() => f.registry.assertMutationCurrent(context), e => e.code === "PUBLIC_ERASED");
    assert.equal(f.policy.reviewQueue().length, 0); const recordsBefore = f.model.requests.length;
    await f.relogin(); const recovered = await f.call("prepareRecovery", f.credentials({ requestID: original.requestID }));
    assert.equal(recovered.status, "expired"); assert.equal(recovered.versionID, original.versionID); assert.equal(f.model.requests.length, recordsBefore);
    assert.equal((await step(f)).processed, 0); assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, f.clock());
    f.advance(day); assert.equal((await step(f)).processed, 1);
    assert.deepEqual(Object.keys(f.model.records.get(id).fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1").get().n, 0); assert.equal(snapshot(f).status, "expired");
    await f.relogin(); const fresh = await stage(f); assert.equal(fresh.generation, original.generation + 1); assert.equal(fresh.status, "pending-review");
  } finally { f.close(); }
});

test("a rejection gets seven days from the last review while approved published photos have no selection TTL", async () => {
  const f = await avatarPublicationFixture();
  try {
    const original = await stage(f); f.advance(2 * day); await f.call("prepareReview", f.review(original, "rejected"));
    f.advance(lifetime - 1); assert.equal(snapshot(f).status, "rejected"); f.advance(1); assert.equal(snapshot(f).status, "expired");
    await f.relogin(); const next = await stage(f); await f.call("prepareReview", f.review(next));
    const approved = snapshot(f); await f.call("preparePublish", f.credentials(f.publication(approved)));
    const id = recordName(f, approved), saved = structuredClone(f.model.records.get(id));
    f.advance(60 * day); await step(f); assert.equal(snapshot(f).status, "published"); assert.deepEqual(f.model.records.get(id), saved);
    assert.equal(f.policy.readPublication(f.signedIn.accountID).versionID, approved.versionID);
  } finally { f.close(); }
});

test("a late review or captured approval cannot revive a selection whose server deadline has passed", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f); await f.call("prepareReview", f.review(pending));
    const intent = f.policy.intent(f.signedIn.accountID, pending.requestID), lease = f.policy.publishLease(intent);
    f.advance(lifetime);
    assert.throws(() => f.policy.assertPublishCurrent(lease), e => e.code === "AVATAR_STALE");
    await assert.rejects(() => f.call("prepareReview", f.review(snapshot(f))), e => e.code === "AVATAR_STALE");
    assert.equal(snapshot(f).status, "expired");
  } finally { f.close(); }
});

test("clear or replacement after virtual expiry keeps the original deadline instead of adding another seven days", async () => {
  for (const action of ["clear", "select"]) {
    const f = await avatarPublicationFixture();
    try {
      const old = await stage(f), id = recordName(f, old), created = f.clock(); f.advance(lifetime + 2 * day); await f.relogin();
      if (action === "clear") await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: old.generation }));
      else await stage(f);
      assert.equal(f.db.prepare("SELECT retired_at FROM avatar_retirements_v1 WHERE record_name=?").get(id).retired_at, created + lifetime);
      assert.equal((await step(f)).processed, 1); assert.equal(f.model.records.get(id).fields.erased.value, 1);
      assert.notEqual(snapshot(f).status, "expired");
    } finally { f.close(); }
  }
});

test("orphan policy jobs with no record receive a future local wake and are purged in bounded batches", async () => {
  const f = await avatarPublicationFixture();
  try {
    for (let i = 0; i < 101; i++) { if (i % 3 === 0) f.advance(600000); await selectOnly(f); await clearOnly(f); }
    const schedule = f.registry.retentionSchedule(); assert.equal(schedule.dueAt, null); assert.ok(schedule.wakeAt > f.clock());
    f.advance(lifetime); await f.registry.backfillRetention();
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1").get().n, 1);
    assert.equal(f.registry.retentionSchedule().needsBackfill, true);
    await f.registry.backfillRetention(); assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1").get().n, 0);
    assert.equal(f.registry.retentionSchedule().wakeAt, null); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); }
});

test("selection expiry migrates older profile tables without changing published approval or resetting generation", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f);
    f.db.exec("ALTER TABLE avatar_profiles_v1 DROP COLUMN expired_at"); f.db.exec("ALTER TABLE avatar_profiles_v1 DROP COLUMN expired_review_revision");
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, null);
    f.advance(lifetime); await registry.backfillRetention();
    assert.equal(snapshot(f).status, "expired"); assert.equal(snapshot(f).generation, pending.generation);
  } finally { f.close(); }
});

test("account deletion takes priority over expiring a current picture and does not leave a terminal tombstone", async () => {
  const f = await avatarPublicationFixture();
  try {
    await stage(f); f.advance(lifetime); await f.relogin(); const ticket = await f.beginDeletion(f.signedIn); f.advance(60001);
    assert.equal((await step(f)).processed, 0); assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, null);
    assert.equal((await f.erase(ticket)).remaining, false); assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_profiles_v1").get().n, 0);
  } finally { f.close(); }
});

test("expired owner recovery finalizers reject a newer selection and never expose an unrelated version", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await stage(f); f.advance(lifetime); await f.relogin();
    const final = await f.coordinator.prepareRecovery(f.credentials({ requestID: old.requestID }));
    await stage(f); assert.throws(() => final(), e => e.code === "AVATAR_STALE");
  } finally { f.close(); }
});

test("actual local Runtime HTTP returns expired owner state before and after fencing without another asset transfer", async () => {
  const fixture = await exportAvatarExpiryNativeFixture();
  assert.equal(fixture.additionalTransfersAfterExpiry, 0); const initial = fixture.snapshots.pending;
  for (const key of ["expired", "recovered", "expiredAfterFence"]) {
    const value = fixture.snapshots[key]; assert.equal(value.status, "expired");
    for (const field of ["requestID", "versionID", "generation", "reviewRevision"]) assert.equal(value[field], initial[field]);
    assert.equal(value.publishedVersionID, null); assert.deepEqual(avatarMutationSnapshot(Object.fromEntries(Object.entries(value).filter(([k]) => k !== "protocolVersion"))),
      Object.fromEntries(Object.entries(value).filter(([k]) => k !== "protocolVersion")));
  }
});

test("an expired selection remains terminal after file-backed reopen even when its job and assets are already fenced", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-photo-expiry-")), path = join(directory, "state.sqlite");
  let f = await avatarPublicationFixture({ path });
  try {
    const original = await stage(f); f.advance(lifetime + day); await step(f);
    const terminal = snapshot(f), now = f.clock(); assert.equal(terminal.status, "expired");
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_jobs_v1").get().n, 0);
    const model = { records: structuredClone(f.model.records), controls: structuredClone(f.model.controls), sequence: f.model.sequence };
    f.close(); f = await avatarPublicationFixture({ path, bootstrap: false }); f.advance(now - f.clock());
    Object.assign(f.model, model); assert.deepEqual(snapshot(f), terminal);
    assert.throws(() => f.policy.intent(f.signedIn.accountID, original.requestID), e => e.code === "AVATAR_STALE");
    await f.relogin(); const next = await stage(f); assert.equal(next.generation, terminal.generation + 1);
  } finally { f.close(); rmSync(directory, { recursive: true }); }
});

test("expiry and retirement markers roll back together when the profile transition cannot be committed", async () => {
  let armed = false;
  const f = await avatarPublicationFixture({ sqlHook(sql) { if (armed && sql.startsWith("UPDATE avatar_profiles_v1 SET expired_at=")) throw new Error("Synthetic expiry transaction failure"); } });
  try {
    await stage(f); f.advance(lifetime); armed = true;
    await assert.rejects(() => f.registry.backfillRetention()); armed = false;
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, null);
    assert.equal(f.db.prepare("SELECT count(*) n FROM avatar_retirements_v1").get().n, 0);
    assert.equal(f.db.prepare("SELECT count(*) n FROM public_retention_v1").get().n, 0);
    assert.equal(snapshot(f).status, "expired"); await f.registry.backfillRetention();
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, f.clock());
  } finally { armed = false; f.close(); }
});

test("a terminal HTTP expiry is durable and a rolled-back clock cannot revive the forgotten selection", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    const first = await (await f.call("upload")).json(); f.advance(lifetime); await f.relogin();
    f.env.GATEWAY_EXPIRES_AT = new Date(f.clock() + 6 * day).toISOString();
    const response = await f.call("status"), expired = await response.json();
    assert.equal(response.status, 200); assert.equal(expired.status, "expired");
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, f.clock());
    f.advance(-1); assert.throws(() => f.policy.intent(f.signedIn.accountID, first.requestID));
    const late = await f.call("recover", { requestID: first.requestID }); assert.notEqual(late.status, 200);
    f.advance(1); const restored = await (await f.call("status")).json(); assert.equal(restored.status, "expired");
    assert.equal(restored.requestID, expired.requestID); assert.equal(f.transfers.length, 4);
  } finally { f.close(); }
});

test("crossing the selection deadline during the final checkpoint cannot emit an unpersisted terminal response", async () => {
  const f = await avatarUploadHTTPFixture();
  try {
    const first = await f.call("upload"); assert.equal(first.status, 200); await first.body.cancel();
    f.advance(lifetime - 1); await f.relogin(); let armed = true;
    f.afterLastAdvance(async () => { if (armed) { armed = false; f.advance(1); } });
    const response = await f.call("status"); assert.notEqual(response.status, 200);
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, null);
    const retried = await f.call("status"); assert.equal(retried.status, 200); assert.equal((await retried.json()).status, "expired");
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, f.clock());
  } finally { f.close(); }
});

test("failed expiry durability cannot return a terminal finalizer and an exact fresh retry confirms the same state", async () => {
  let armed = false;
  const f = await avatarPublicationFixture({ async syncHook() { if (armed) throw new Error("Synthetic expiry durability unavailable"); } });
  try {
    await stage(f); f.advance(lifetime); await f.relogin(); armed = true;
    await assert.rejects(() => f.coordinator.prepareStatus(f.credentials())); armed = false;
    const final = await f.coordinator.prepareStatus(f.credentials()); assert.equal(final().status, "expired");
    assert.equal(f.db.prepare("SELECT expired_at FROM avatar_profiles_v1").get().expired_at, f.clock());
  } finally { armed = false; f.close(); }
});
