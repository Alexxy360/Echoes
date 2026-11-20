import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AvatarReportReviewState, avatarReportReviewContent, avatarReportReviewContentHash, purgeAvatarReportReviews, avatarReportReviewWakeAt } from "../src/avatar-report-review-state.mjs";
import { avatarReportReviewStateFixture as setup } from "./support/avatar-report-review-state-fixture.mjs";
const code = expected => error => error.code === "AVATAR_REPORT_REVIEW_" + expected && !error.message.includes("PRIVATE") && error.cause === undefined;
const query = o => ({ reviewerID: o.reviewerID, reportID: o.content.reportID, decisionID: o.decisionID, verdict: o.verdict, contentHash: avatarReportReviewContentHash(o.content) });
const rows = (f, sql, ...args) => f.storage.sql.exec(sql, ...args).toArray();

test("photo-report snapshot is metadata only and rejects a newer or unrelated publication", async t => {
  const f = await setup(t), json = JSON.stringify(f.content);
  for (const secret of [f.report.input.reason, "coordinate", "downloadURL", "receipt", "thumbnail", "accessToken"]) assert.equal(json.includes(secret), false);
  for (const change of [{ versionID: randomUUID() }, { generation: f.publication.generation + 1 }, { stagedTag: "different" }]) {
    assert.throws(() => avatarReportReviewContent(f.report, { ...f.publication, ...change }), code("STALE"));
  }
  assert.throws(() => avatarReportReviewContentHash({ ...f.content, reason: "PRIVATE" }), code("INPUT"));
});

test("photo-report keyset queue scans twenty at a time, separates messages and never queries the provider", async t => {
  const f = await setup(t); for (let i = 1; i < 43; i++) await f.makeReport();
  const before = f.model.requests.length, seen = []; let after = null;
  do { const page = f.registry.reviewAvatarReportPage(after); assert.ok(page.items.length <= 20); seen.push(...page.items.map(x => x.recordName)); after = page.after; } while (after);
  assert.equal(seen.length, 43); assert.equal(new Set(seen).size, 43); assert.deepEqual(seen, [...seen].sort());
  assert.equal(f.model.requests.length, before); assert.deepEqual(f.registry.reviewReportPage().items, []);
  assert.throws(() => f.registry.reviewAvatarReportPage("community-v1-report-" + "a".repeat(64)));
});

test("unverified receipt cannot decide; verification binds exact reviewer session and content", async t => {
  const f = await setup(t), receipt = await f.reviews.reserve(f.operator.accountID, f.sessionKey, f.content), o = f.optionsFor(receipt);
  await assert.rejects(f.reviews.decide(o), code("STALE"));
  await f.reviews.confirm(f.operator.accountID, f.sessionKey, receipt.inspectionID);
  for (const change of [{ reviewerID: f.viewer.accountID }, { sessionKey: "a".repeat(64) }, { content: { ...f.content, imageSHA256: "a".repeat(64) } }]) await assert.rejects(f.reviews.decide({ ...o, ...change }), code("STALE"));
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published");
});

test("only synchronous true authorization admits a photo-report decision", async t => {
  const f = await setup(t), receipt = await f.inspect();
  for (const authorize of [() => false, () => undefined, () => 1, async () => true]) await assert.rejects(f.reviews.decide(f.optionsFor(receipt, "hide_photo", { authorize })), code("SCOPE"));
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published"); assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
});

test("confirmed hide atomically rejects only the inspected publication and exact replay never creates a new decision", async t => {
  const f = await setup(t), receipt = await f.inspect(), o = f.optionsFor(receipt), result = await f.reviews.decide(o);
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected"); assert.throws(() => f.policy.readPublication(f.signedIn.accountID));
  assert.deepEqual(await f.reviews.decide(o), result); assert.equal(f.reviews.isOpen(f.report.context), false);
  const { reviewerID, ...identity } = query(o);
  assert.deepEqual(await f.reviews.recover(query(o)), { ...identity, outcome: "confirmed", revision: result.revision });
});

test("dismissal preserves publication, and a missing original photo permits dismissal but never hide", async t => {
  const f = await setup(t), missing = avatarReportReviewContent(f.report, null), receipt = await f.inspect(missing);
  await assert.rejects(f.reviews.decide(f.optionsFor(receipt, "hide_photo", { content: missing })), code("STALE"));
  const o = f.optionsFor(receipt, "dismiss", { content: missing }); await f.reviews.decide(o);
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published"); assert.equal((await f.reviews.recover(query(o))).outcome, "confirmed");
});

test("clear or a replacement generation after inspection cannot be hidden by the old report", async t => {
  const f = await setup(t), receipt = await f.inspect();
  await f.policy.clear({ accountID: f.signedIn.accountID, requestID: randomUUID(), expectedGeneration: f.publication.generation });
  await assert.rejects(f.reviews.decide(f.optionsFor(receipt)), code("STALE"));
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "clearing"); assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
});

test("changed tags, descriptor, revision or pointer never turn an old photo report into a new hide", async t => {
  const cases = [
    ["UPDATE avatar_jobs_v1 SET moderation_revision=? WHERE account_id=?", () => randomUUID(), "author"],
    ["UPDATE avatar_profiles_v1 SET pointer_tag=? WHERE account_id=?", () => "tampered", "author"],
    ["UPDATE public_records_v1 SET record_tag=? WHERE record_name=?", () => "tampered", "avatar"],
    ["UPDATE avatar_jobs_v1 SET descriptor_json=? WHERE account_id=?", () => "{}", "author"]
  ];
  for (const [sql, value, target] of cases) {
    const f = await setup(t), receipt = await f.inspect();
    f.storage.sql.exec(sql, value(), target === "avatar" ? f.content.avatarID : f.signedIn.accountID);
    await assert.rejects(f.reviews.decide(f.optionsFor(receipt)), e => e.code.startsWith("AVATAR_REPORT_REVIEW_"));
    assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
  }
});

test("conflicting moderator decision has one durable winner and read-only superseded recovery", async t => {
  const f = await setup(t), first = await f.inspect(), other = await f.session("other.operator"), key = "b".repeat(64), second = await f.inspect(f.content, other.accountID, key);
  const o = f.optionsFor(first), loser = f.optionsFor(second, "dismiss", { reviewerID: other.accountID, sessionKey: key });
  const result = await f.reviews.decide(o); await assert.rejects(f.reviews.decide(loser), code("STALE"));
  assert.equal((await f.reviews.recover(query(loser))).outcome, "superseded"); assert.equal((await f.reviews.recover(query(o))).revision, result.revision);
});

test("SQLite failure rolls back both photo rejection and report decision", async t => {
  let failInsert = false; const f = await setup(t, { sqlHook: sql => { if (failInsert && sql.startsWith("INSERT INTO avatar_report_decisions_v1")) throw new Error("PRIVATE SQL"); } });
  const receipt = await f.inspect(); failInsert = true; await assert.rejects(f.reviews.decide(f.optionsFor(receipt)), code("UNAVAILABLE")); failInsert = false;
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published"); assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
});

test("lost durable ACK is recovered without another photo mutation or another decision ID", async t => {
  let failSync = false; const f = await setup(t, { syncHook: async () => { if (failSync) throw new Error("PRIVATE sync"); } });
  const receipt = await f.inspect(), o = f.optionsFor(receipt); failSync = true; await assert.rejects(f.reviews.decide(o), code("UNAVAILABLE")); failSync = false;
  const revision = f.policy.snapshot(f.signedIn.accountID).reviewRevision;
  assert.equal((await f.reviews.recover(query(o))).outcome, "confirmed"); assert.equal(f.policy.snapshot(f.signedIn.accountID).reviewRevision, revision);
});

test("receipt replacement, expiry and rollback do not revive old inspection authority", async t => {
  const f = await setup(t), first = await f.inspect(), second = await f.inspect();
  await assert.rejects(f.reviews.decide(f.optionsFor(first)), code("STALE"));
  f.advance(-1); await assert.rejects(f.reviews.decide(f.optionsFor(second)), code("STALE")); f.advance(90001);
  await assert.rejects(f.reviews.decide(f.optionsFor(second)), code("STALE"));
  assert.equal(avatarReportReviewWakeAt(f.storage, f.clock), f.clock()); await purgeAvatarReportReviews(f.storage, f.clock);
  assert.equal(rows(f, "SELECT * FROM avatar_report_inspections_v1").length, 0);
});

test("ten inspections per minute and 256 live slots fail closed without a provider call", async t => {
  const f = await setup(t); for (let i = 0; i < 10; i++) await f.reviews.reserve(f.operator.accountID, f.sessionKey, f.content);
  await assert.rejects(f.reviews.reserve(f.operator.accountID, f.sessionKey, f.content), code("CAPACITY"));
  const row = rows(f, "SELECT * FROM avatar_report_inspections_v1")[0];
  for (let i = 0; i < 255; i++) f.storage.sql.exec("INSERT INTO avatar_report_inspections_v1 VALUES(?,?,?,?,?,?,?,?,?,?)", i.toString(16).padStart(64, "0"), row.session_key, row.inspection_key, row.report_id, row.content, row.content_hash, row.target_owner, row.created_at, row.expires_at, row.verified);
  await assert.rejects(f.reviews.reserve(f.viewer.accountID, f.sessionKey, f.content), code("CAPACITY"));
});

test("cancellation hides report from photo queue and invalidates its open receipt", async t => {
  const f = await setup(t), receipt = await f.inspect(); f.setReportsCancellable(true); await f.cancel(f.report.context.requestID);
  assert.deepEqual(f.registry.reviewAvatarReportPage().items, []); await assert.rejects(f.reviews.decide(f.optionsFor(receipt)), code("STALE"));
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published");
});

test("disabled reviewer is denied immediately and owner erasure removes only related photo moderation metadata", async t => {
  const f = await setup(t), receipt = await f.inspect();
  await f.beginDeletion(f.operator, "synthetic.photo.report.operator");
  await assert.rejects(f.reviews.decide(f.optionsFor(receipt)), code("SCOPE"));
  await f.social.eraseOwner(f.operator.accountID); assert.equal(rows(f, "SELECT * FROM avatar_report_inspections_v1").length, 0);
  assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "published");
});

test("real file SQLite reopens the exact decision metadata while recovery stays read-only", async t => {
  const dir = await mkdtemp(join(tmpdir(), "echoes-photo-report-review-")); t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "state.sqlite"), f = await setup(t, { path }), receipt = await f.inspect(), o = f.optionsFor(receipt);
  const decision = await f.reviews.decide(o), db = new DatabaseSync(path);
  const storage = { sql: { exec(sql, ...args) { const value = db.prepare(sql).all(...args); return { toArray: () => value }; } },
    transactionSync(fn) { db.exec("BEGIN IMMEDIATE"); try { const result = fn(); db.exec("COMMIT"); return result; } catch (e) { db.exec("ROLLBACK"); throw e; } }, async sync() {} };
  try { const reopened = new AvatarReportReviewState(storage, { clock: f.clock }); assert.equal((await reopened.recover(query(o))).revision, decision.revision); }
  finally { db.close(); }
});

test("report expiration cuts off inspection and recovery and bounded cleanup removes decision without un-hiding photo", async t => {
  const f = await setup(t), receipt = await f.inspect(), o = f.optionsFor(receipt); await f.reviews.decide(o);
  f.advance(2592000001);
  assert.throws(() => f.reviews.outcome(query(o)), code("STALE")); assert.deepEqual(f.registry.reviewAvatarReportPage().items, []);
  await purgeAvatarReportReviews(f.storage, f.clock); assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
  assert.equal(rows(f, "SELECT moderation_state FROM avatar_jobs_v1 WHERE account_id=?", f.signedIn.accountID)[0].moderation_state, "rejected");
});

test("reporter erasure removes only its own moderation metadata and preserves other reporter decision", async t => {
  const f = await setup(t), first = await f.inspect(); await f.reviews.decide(f.optionsFor(first, "dismiss"));
  const other = await f.session("other.reporter"), requestID = randomUUID();
  const record = await f.repository.write({ accessToken: other.sessionToken, kind: "avatarreport", logicalID: requestID, requestID, input: f.report.input, authorizeMutation: () => true });
  const [report] = await f.lease.lookup([record.recordName], "avatarreport"), content = avatarReportReviewContent(report, f.publication), receipt = await f.inspect(content);
  await f.reviews.decide(f.optionsFor(receipt, "dismiss", { content }));
  await f.beginDeletion(f.viewer, "synthetic.reader"); await f.social.eraseOwner(f.viewer.accountID);
  assert.deepEqual(rows(f, "SELECT report_id FROM avatar_report_decisions_v1").map(x => x.report_id), [record.recordName]);
});

test("author erasure removes related inspection/decision metadata and cannot make another photo readable", async t => {
  const f = await setup(t), receipt = await f.inspect(); await f.reviews.decide(f.optionsFor(receipt));
  await f.beginDeletion(f.signedIn, "synthetic.user"); await f.social.eraseOwner(f.signedIn.accountID);
  assert.equal(rows(f, "SELECT * FROM avatar_report_inspections_v1").length, 0); assert.equal(rows(f, "SELECT * FROM avatar_report_decisions_v1").length, 0);
  assert.throws(() => f.policy.readPublication(f.signedIn.accountID));
});

test("local maintenance recognizes absent or partial photo-review schemas and never silently skips corruption", async t => {
  const f = await setup(t); f.db.exec("DROP TABLE avatar_report_review_budgets_v1");
  assert.throws(() => avatarReportReviewWakeAt(f.storage, f.clock), code("UNAVAILABLE"));
  await assert.rejects(purgeAvatarReportReviews(f.storage, f.clock), code("UNAVAILABLE"));
  f.db.exec("DROP TABLE avatar_report_inspections_v1; DROP TABLE avatar_report_decisions_v1");
  assert.equal(avatarReportReviewWakeAt(f.storage, f.clock), null); await purgeAvatarReportReviews(f.storage, f.clock);
});
