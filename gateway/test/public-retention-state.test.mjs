import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { publicRetentionDeadline, publicRetentionIntentKey, expiredPublicFields } from "../src/public-retention-policy.mjs";
import { publicFixture, publicCode } from "./support/public-record-fixture.mjs";
import { hash } from "./support/authentication-fixture.mjs";

const hour = 3600000, day = 86400000;
async function setup(options) {
  const f = await publicFixture({ bootstrap: false, ...options });
  const session = await f.session();
  return { ...f, session,
    async reserve(kind = "message", changes = {}) {
      const id = randomUUID();
      return f.registry.reserve({ accountID: session.accountID, kind,
        logicalID: ["presence", "profile", "avatarprofile"].includes(kind) ? "singleton" : id,
        requestID: id, payloadHash: hash(id), ...changes });
    },
  };
}

test("retention derives server lifetimes only for presence, messages and reports and rejects overflow", async () => {
  const f = await setup();
  try {
    for (const [kind, lifetime] of [["presence", 600000], ["message", 2 * hour], ["report", 30 * day]]) {
      const context = await f.reserve(kind);
      assert.equal(publicRetentionDeadline(context), f.clock() + lifetime);
      const fields = expiredPublicFields(context);
      assert.deepEqual(Object.keys(fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
      assert.equal(fields.retentionKey.value, publicRetentionIntentKey(context));
      assert.equal(fields.erased.value, 1);
    }
    for (const kind of ["profile", "block", "avatar", "avatarprofile"]) assert.equal(publicRetentionDeadline({ kind }), null);
    assert.throws(() => publicRetentionDeadline({ kind: "report", createdAt: Number.MAX_SAFE_INTEGER }), publicCode("PUBLIC_UNAVAILABLE"));
    assert.throws(() => publicRetentionDeadline({ kind: "unknown" }), publicCode("PUBLIC_SCOPE"));
    assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("a durable reservation queues metadata without public content and retries never extend the deadline", async () => {
  const f = await setup();
  try {
    const context = await f.reserve();
    const old = f.db.prepare("SELECT * FROM public_retention_v1").get();
    f.advance(hour);
    const retry = await f.registry.reserve({ accountID: context.accountID, kind: context.kind,
      logicalID: context.requestID, requestID: context.requestID, payloadHash: context.payloadHash });
    assert.equal(retry.startedAt, context.startedAt);
    assert.deepEqual(f.db.prepare("SELECT * FROM public_retention_v1").get(), old);
    assert.equal(old.state, "pending");
    assert.match(old.intent_key, /^[a-f0-9]{64}$/);
    assert.deepEqual(Object.keys(old).sort(), ["due_at", "fence_tag", "intent_key", "lease_at", "lease_id", "record_name", "state"]);
  } finally { f.close(); }
});

test("expired records are hidden and cannot dispatch or settle even before queue backfill", async () => {
  const f = await setup();
  try {
    const context = await f.reserve(); await f.registry.settle(context, "live-1");
    assert.ok(f.registry.readable(context.recordName, "message"));
    f.db.exec("DELETE FROM public_retention_v1"); // Legacy registry without the new projection.
    f.advance(2 * hour);
    assert.equal(f.registry.readable(context.recordName, "message"), null);
    assert.throws(() => f.registry.assertMutationCurrent(context), publicCode("PUBLIC_ERASED"));
    await assert.rejects(() => f.registry.settle(context, "late-tag"), publicCode("PUBLIC_ERASED"));
    await assert.rejects(() => f.registry.reserve({ accountID: context.accountID, kind: "message",
      logicalID: context.requestID, requestID: context.requestID, payloadHash: context.payloadHash }), publicCode("PUBLIC_ERASED"));
    assert.equal((await f.registry.claimExpiredRecords()).length, 1);
  } finally { f.close(); }
});

test("backfill is bounded and excludes persistent profiles, blocks and avatar versions", async () => {
  const f = await setup();
  try {
    for (const kind of ["message", "message", "report", "presence", "profile", "block", "avatar", "avatarprofile"]) await f.reserve(kind);
    f.db.exec("DELETE FROM public_retention_v1");
    assert.equal(await f.registry.backfillRetention(2), 2);
    assert.equal(await f.registry.backfillRetention(2), 2);
    assert.equal(await f.registry.backfillRetention(2), 0);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM public_retention_v1").get().n, 4);
    for (const limit of [0, 101, 1.5]) await assert.rejects(() => f.registry.backfillRetention(limit), publicCode("PUBLIC_INPUT"));
    assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("claims are due-only, bounded and exclusive and start at the exact lifetime boundary", async () => {
  const f = await setup();
  try {
    const presence = await f.reserve("presence"); await f.reserve("message"); await f.reserve("report");
    f.advance(599999); assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    f.advance(1); const [lease] = await f.registry.claimExpiredRecords(1);
    assert.equal(lease.context.recordName, presence.recordName);
    assert.equal(lease.expiresAt - lease.leasedAt, 60000);
    assert.ok(f.registry.assertRetentionCurrent(lease));
    assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    for (const limit of [0, 26, NaN]) await assert.rejects(() => f.registry.claimExpiredRecords(limit), publicCode("PUBLIC_INPUT"));
  } finally { f.close(); }
});

test("expired or rolled-back leases cannot complete and a new claim invalidates the old token", async () => {
  const f = await setup();
  try {
    await f.reserve(); f.advance(2 * hour);
    const [first] = await f.registry.claimExpiredRecords();
    f.advance(-1); assert.throws(() => f.registry.assertRetentionCurrent(first), publicCode("PUBLIC_SCOPE"));
    f.advance(60001); assert.throws(() => f.registry.assertRetentionCurrent(first), publicCode("PUBLIC_SCOPE"));
    const [second] = await f.registry.claimExpiredRecords(); assert.notEqual(second.leaseID, first.leaseID);
    await assert.rejects(() => f.registry.completeRetention(first, "old-fence"), publicCode("PUBLIC_SCOPE"));
    assert.ok(f.registry.assertRetentionCurrent(second));
    await assert.rejects(() => f.registry.completeRetention(second, "\n"), publicCode("PUBLIC_RESPONSE"));
  } finally { f.close(); }
});

test("retiring presence blocks delayed settlement and all fresh intents until its exact fence is confirmed", async () => {
  const f = await setup();
  try {
    const old = await f.reserve("presence"); await f.registry.settle(old, "live-1");
    f.advance(600000); const [lease] = await f.registry.claimExpiredRecords();
    const fresh = { accountID: old.accountID, kind: "presence", logicalID: "singleton", requestID: randomUUID(), payloadHash: hash("new"), expectedTag: "live-1" };
    await assert.rejects(() => f.registry.reserveLatest(fresh), publicCode("PUBLIC_PENDING"));
    await assert.rejects(() => f.registry.settle(old, "late-old-response"), publicCode("PUBLIC_PENDING"));
    await f.registry.completeRetention(lease, "fence-2");
    assert.equal(f.registry.readable(old.recordName, "presence"), null);
    f.advance(-1); assert.equal(f.registry.readable(old.recordName, "presence"), null);
    await assert.rejects(() => f.registry.reserveLatest({ ...fresh, requestID: old.requestID, payloadHash: old.payloadHash }), publicCode("PUBLIC_ERASED"));
    f.advance(2);
    const next = await f.registry.reserveLatest({ ...fresh, expectedTag: "fence-2" });
    assert.equal(publicRetentionDeadline(next), f.clock() + 600000);
    await f.registry.settle(next, "new-live-3");
    assert.equal(f.registry.readable(next.recordName, "presence").requestID, fresh.requestID);
    assert.throws(() => f.registry.assertMutationCurrent(old), publicCode("PUBLIC_CONFLICT"));
    assert.throws(() => f.registry.assertRetentionCurrent(lease), publicCode("PUBLIC_SCOPE"));
  } finally { f.close(); }
});

test("a new presence intent replaces only its own pending expiry and cannot inherit a previous request deadline", async () => {
  const f = await setup();
  try {
    const old = await f.reserve("presence"); await f.registry.settle(old, "1"); f.advance(599999);
    const next = await f.registry.reserveLatest({ accountID: old.accountID, kind: "presence", logicalID: "singleton",
      requestID: randomUUID(), payloadHash: hash("fresh-presence"), expectedTag: "1" });
    f.advance(1); assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    assert.equal(publicRetentionDeadline(next), f.clock() + 599999);
    assert.notEqual(publicRetentionIntentKey(next), publicRetentionIntentKey(old));
  } finally { f.close(); }
});

test("immutable expiry preserves consumed identities and quota fences and never erases an unrelated record", async () => {
  const f = await setup();
  try {
    const expired = await f.reserve(), retained = await f.reserve("profile");
    f.advance(2 * hour); const [lease] = await f.registry.claimExpiredRecords();
    await f.registry.completeRetention(lease, "fence-1");
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(expired.recordName).phase, "erased");
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(retained.recordName).phase, "pending");
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM public_retention_v1").get().n, 0);
    assert.equal(await f.registry.backfillRetention(), 0);
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 2);
    await assert.rejects(() => f.registry.reserve({ accountID: expired.accountID, kind: "message", logicalID: expired.requestID,
      requestID: expired.requestID, payloadHash: expired.payloadHash }), publicCode("PUBLIC_ERASED"));
    new PublicRecordRegistry(f.storage, { clock: f.clock });
    assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("reports expire after thirty days while messages expire after two hours without requiring a live session", async () => {
  const f = await setup();
  try {
    const report = await f.reserve("report"); await f.reserve();
    f.advance(2 * hour);
    const [message] = await f.registry.claimExpiredRecords(); assert.equal(message.context.kind, "message");
    await f.registry.completeRetention(message, "message-fence");
    f.advance(30 * day - 2 * hour - 1); assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    f.advance(1); const [lease] = await f.registry.claimExpiredRecords();
    assert.equal(lease.context.recordName, report.recordName);
    await f.registry.completeRetention(lease, "report-fence");
  } finally { f.close(); }
});

test("claim durability failure cannot expose a usable lease and preserves the consumed slot for later recovery", async () => {
  const f = await setup();
  try {
    await f.reserve(); f.advance(2 * hour);
    // Let backfill sync complete; fail only the subsequent durable claim.
    let count = 0;
    f.storage.sync = async () => { if (++count === 2) throw new Error("PRIVATE-disk-failure"); };
    await assert.rejects(() => f.registry.claimExpiredRecords(), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT state FROM public_retention_v1").get().state, "fencing");
    assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    f.advance(60000); assert.equal((await f.registry.claimExpiredRecords()).length, 1);
  } finally { f.close(); }
});

test("account deletion takes precedence, invalidates existing leases and removes their local queue rows", async () => {
  const f = await setup();
  try {
    await f.reserve(); f.advance(2 * hour); const [lease] = await f.registry.claimExpiredRecords();
    const ticket = await f.beginDeletion(f.session); f.advance(60001);
    assert.throws(() => f.registry.assertRetentionCurrent(lease), publicCode("PUBLIC_SCOPE"));
    assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    const deletion = await f.deletions.claimPublicBatch(ticket.deletionID);
    const rows = await f.registry.erasureBatch(deletion, 25);
    await f.registry.completeErasure(deletion, new Map(rows.map(row => [row.recordName, "deletion-fence"])));
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM public_retention_v1").get().n, 0);
  } finally { f.close(); }
});

test("lease substitution across records and mismatched private projections fail closed", async () => {
  const f = await setup();
  try {
    await f.reserve(); await f.reserve(); f.advance(2 * hour);
    const [a, b] = await f.registry.claimExpiredRecords();
    assert.throws(() => f.registry.assertRetentionCurrent({ ...a, context: b.context }), publicCode("PUBLIC_SCOPE"));
    f.db.prepare("UPDATE public_retention_v1 SET intent_key=? WHERE record_name=?").run(hash("corrupt"), a.context.recordName);
    assert.throws(() => f.registry.assertRetentionCurrent(a), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await assert.rejects(() => f.registry.completeRetention(a, "tag"), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
  } finally { f.close(); }
});

test("an account disabled during claim durability cannot receive the prepared lease", async () => {
  const f = await setup();
  try {
    await f.reserve(); f.advance(2 * hour); let syncs = 0;
    f.storage.sync = async () => {
      if (++syncs === 2) f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1,generation=generation+1 WHERE account_id=?").run(f.session.accountID);
    };
    await assert.rejects(() => f.registry.claimExpiredRecords(), publicCode("PUBLIC_SCOPE"));
    assert.deepEqual(await f.registry.claimExpiredRecords(), []);
    assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("fair cursor and leases survive a file-backed SQLite reopen and do not starve later records", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-retention-state-")), path = join(directory, "state.sqlite");
  let f = await setup({ path });
  try {
    for (let i = 0; i < 4; i++) await f.reserve();
    f.advance(2 * hour);
    const [a] = await f.registry.claimExpiredRecords(1), [b] = await f.registry.claimExpiredRecords(1);
    const expected = f.db.prepare("SELECT record_name FROM public_retention_v1 ORDER BY record_name").all()[2].record_name;
    f.close(); f = await publicFixture({ bootstrap: false, path }); f.advance(2 * hour + 60000);
    const [c] = await f.registry.claimExpiredRecords(1);
    assert.notEqual(a.context.recordName, b.context.recordName);
    assert.equal(c.context.recordName, expected);
    assert.throws(() => f.registry.assertRetentionCurrent(a), publicCode("PUBLIC_SCOPE"));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});
