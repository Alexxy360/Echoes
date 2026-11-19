import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { digest } from "../src/public-record-schema.mjs";
import { CommunityReportReview } from "../src/community-report-review.mjs";
import { CommunityReportReviewState, purgeCommunityReportReviews, communityReportReviewWakeAt } from "../src/community-report-review-state.mjs";
import { GatewayMaintenance } from "../src/gateway-maintenance.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";
import { reportReviewFixture as setup } from "./support/community-report-review-fixture.mjs";

const code = expected => error => error?.code === expected && !error.message.includes("PRIVATE") && error.cause === undefined;
const sessionKey = token => digest("echoes/report-review-session/v1\0" + token);
const decision = (inspection, verdict = "hide_message", decisionID = randomUUID()) => ({ inspectionID: inspection.inspectionID, decisionID, verdict });
const recovery = (inspection, intent) => ({ reportID: inspection.reportID, contentHash: inspection.contentHash, decisionID: intent.decisionID, verdict: intent.verdict });
const decide = async (f, intent) => (await f.review.prepareDecision(f.options(intent)))();
const recover = async (f, query, accessToken = f.operator.sessionToken) => (await f.review.prepareRecovery({ ...query, accessToken }))();
const hidden = f => f.db.prepare("SELECT hidden FROM community_intents_v1 WHERE account_id=? AND kind='message'").get(f.author.accountID).hidden;

test("inspection persists only bounded metadata and an exact verified content commitment before delivery", async t => {
  const f = await setup(t), inspection = await f.inspect();
  const row = f.db.prepare("SELECT * FROM community_report_inspections_v1").get();
  assert.equal(row.verified, 1); assert.equal(row.report_id, f.report.recordName); assert.equal(row.content_hash, inspection.contentHash);
  assert.equal(row.expires_at - row.created_at, 90000);
  const serialized = JSON.stringify(row);
  for (const value of ["PRIVATE-SYNTHETIC-REPORT", "PRIVATE-SYNTHETIC-MESSAGE", f.operator.sessionToken, "latitude", "longitude"]) assert.equal(serialized.includes(value), false);
});

test("hide decision atomically closes the report and suppresses exactly its message; exact retry and recovery preserve the revision", async t => {
  const f = await setup(t), inspection = await f.inspect(), intent = decision(inspection);
  const before = f.registry.readable(f.message.recordName, "message"); assert.equal(f.community.visible(f.operator.accountID, before), true);
  const result = await decide(f, intent); assert.equal(hidden(f), 1); assert.equal(f.community.visible(f.operator.accountID, before), false);
  assert.deepEqual((await f.queue()).items, []); assert.equal((await decide(f, intent)).revision, result.revision);
  assert.equal((await recover(f, recovery(inspection, intent))).revision, result.revision);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 1);
});

test("dismissal closes only the report and cannot later be changed into a hide with another decision ID or verdict", async t => {
  const f = await setup(t), inspection = await f.inspect(), intent = decision(inspection, "dismiss");
  await decide(f, intent); assert.equal(hidden(f), 0); assert.deepEqual((await f.queue()).items, []);
  await assert.rejects(decide(f, { ...intent, verdict: "hide_message" }), code("REPORT_REVIEW_STALE"));
  await assert.rejects(decide(f, decision(inspection)), code("REPORT_REVIEW_STALE"));
  await assert.rejects(f.inspect(), code("REPORT_REVIEW_STALE")); assert.equal(hidden(f), 0);
});

test("changed report or message content invalidates the inspection instead of authorizing a decision on new material", async t => {
  const f = await setup(t), inspection = await f.inspect(), original = structuredClone(f.model.records.get(f.message.recordName));
  f.model.records.get(f.message.recordName).fields.text.value = "PRIVATE-REPLACED";
  await assert.rejects(decide(f, decision(inspection)), code("REPORT_REVIEW_UNAVAILABLE"));
  f.model.records.set(f.message.recordName, original);
  f.model.records.get(f.report.recordName).fields.reason.value = "PRIVATE-REPLACED-REPORT";
  await assert.rejects(decide(f, decision(inspection)), code("REPORT_REVIEW_UNAVAILABLE")); assert.equal(hidden(f), 0);
});

test("a replacement inspection invalidates the old receipt even for the same report and session", async t => {
  const f = await setup(t), old = await f.inspect(), current = await f.inspect();
  await assert.rejects(decide(f, decision(old)), code("REPORT_REVIEW_STALE"));
  await decide(f, decision(current, "dismiss")); assert.equal(hidden(f), 0);
});

test("an expired inspection cannot mutate policy and fresh inspection remains available", async t => {
  const f = await setup(t), inspection = await f.inspect(); f.advance(90001);
  await assert.rejects(decide(f, decision(inspection)), code("REPORT_REVIEW_STALE")); assert.equal(hidden(f), 0);
  assert.notEqual((await f.inspect()).inspectionID, inspection.inspectionID);
});

test("session rotation invalidates old inspection authority while same-account recovery works after receipt expiry", async t => {
  const f = await setup(t), inspection = await f.inspect(), intent = decision(inspection, "dismiss"), result = await decide(f, intent);
  const replacement = await f.session("operator");
  await assert.rejects(f.review.prepareDecision({ ...intent, accessToken: replacement.sessionToken }), code("REPORT_REVIEW_STALE"));
  f.advance(90001); const outcome = await recover(f, recovery(inspection, intent), replacement.sessionToken);
  assert.equal(outcome.outcome, "confirmed"); assert.equal(outcome.revision, result.revision);
});

test("another allowed operator cannot claim the first operator's receipt or confirmed recovery result", async t => {
  const f = await setup(t), inspection = await f.inspect(), intent = decision(inspection, "dismiss"); await decide(f, intent);
  const other = await f.session("other-operator"), review = new CommunityReportReview({ ...f.config, isOperator: () => true });
  await assert.rejects(review.prepareDecision({ ...intent, accessToken: other.sessionToken }), code("REPORT_REVIEW_STALE"));
  const result = (await review.prepareRecovery({ ...recovery(inspection, intent), accessToken: other.sessionToken }))();
  assert.equal(result.outcome, "superseded"); assert.equal(result.revision, null);
  await assert.rejects(review.prepareRecovery({ ...recovery(inspection, intent), reviewerID: f.operator.accountID, accessToken: other.sessionToken }), code("REPORT_REVIEW_INPUT"));
});

test("unavailable message material permits only dismissal after a fresh inspection", async t => {
  const f = await setup(t); f.advance(7200001); const replacement = await f.session("operator");
  const inspection = (await f.review.prepareInspection({ accessToken: replacement.sessionToken, reportID: f.report.recordName }))(); assert.equal(inspection.message, null);
  await assert.rejects(f.review.prepareDecision({ ...decision(inspection), accessToken: replacement.sessionToken }), code("REPORT_REVIEW_STALE"));
  const result = (await f.review.prepareDecision({ ...decision(inspection, "dismiss"), accessToken: replacement.sessionToken }))(); assert.equal(result.verdict, "dismiss");
});

test("SQL failure after the policy update rolls back both hiding and the decision; recovery reports not-applied", async t => {
  let armed = false; const f = await setup(t, { sqlHook(sql) { if (armed && sql.startsWith("INSERT INTO community_report_decisions_v1")) throw new Error("PRIVATE-SQL-FAULT"); } });
  const inspection = await f.inspect(), intent = decision(inspection); armed = true;
  await assert.rejects(decide(f, intent), code("REPORT_REVIEW_UNAVAILABLE")); armed = false;
  assert.equal(hidden(f), 0); assert.equal((await recover(f, recovery(inspection, intent))).outcome, "not-applied");
  await decide(f, intent); assert.equal(hidden(f), 1);
});

test("lost durability acknowledgement after commit is an unknown result, recovered without a new decision", async t => {
  let f, armed = false, lost = false;
  f = await setup(t, { syncHook() {
    if (armed && !lost && f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n) { lost = true; throw new Error("PRIVATE-SYNC-FAULT"); }
  } });
  const inspection = await f.inspect(), intent = decision(inspection); armed = true;
  await assert.rejects(decide(f, intent), code("REPORT_REVIEW_UNAVAILABLE")); assert.equal(hidden(f), 1);
  const result = await recover(f, recovery(inspection, intent)); assert.equal(result.outcome, "confirmed");
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 1);
});

test("late role revocation withholds acknowledgement without pretending a committed action was undone", async t => {
  const f = await setup(t), inspection = await f.inspect(), intent = decision(inspection);
  f.model.beforeCheckpoint = call => { if (call.operation === "modify" && f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n) f.role(false); };
  await assert.rejects(decide(f, intent), code("REPORT_REVIEW_SCOPE")); assert.equal(hidden(f), 1);
  f.role(true); f.model.beforeCheckpoint = undefined;
  assert.equal((await recover(f, recovery(inspection, intent))).outcome, "confirmed");
});

test("author or reporter erasure before decision invalidates the inspected authority", async t => {
  const f = await setup(t), inspection = await f.inspect(); await f.beginDeletion(f.author, "author");
  await assert.rejects(decide(f, decision(inspection)), code("REPORT_REVIEW_STALE")); assert.equal(hidden(f), 0);
});

test("opposite decisions from two inspected operators have one atomic winner", async t => {
  const f = await setup(t), first = await f.inspect(), other = await f.session("other-operator"), otherReview = new CommunityReportReview({ ...f.config, isOperator: () => true });
  const second = (await otherReview.prepareInspection({ accessToken: other.sessionToken, reportID: f.report.recordName }))();
  const calls = [[f.operator, first, "hide_message"], [other, second, "dismiss"]].map(([operator, inspection, verdict]) => {
    const key = sessionKey(operator.sessionToken), receipt = f.reviews.get(operator.accountID, key, inspection.inspectionID);
    return f.reviews.decide({ reviewerID: operator.accountID, sessionKey: key, inspectionID: inspection.inspectionID,
      decisionID: randomUUID(), verdict, content: receipt.content, authorize() { return true; } });
  });
  const results = await Promise.allSettled(calls); assert.equal(results.filter(v => v.status === "fulfilled").length, 1);
  assert.equal(results.find(v => v.status === "rejected").reason.code, "REPORT_REVIEW_STALE"); assert.equal(hidden(f), 1);
});

test("bounded metadata retention removes receipts and expired decisions without reversing the policy effect", async t => {
  const f = await setup(t), inspection = await f.inspect(); await decide(f, decision(inspection));
  assert.equal(communityReportReviewWakeAt(f.storage, f.clock), f.clock() + 90000);
  f.advance(90001); await purgeCommunityReportReviews(f.storage, f.clock);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_inspections_v1").get().n, 0);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 1);
  f.advance(2592000000); await purgeCommunityReportReviews(f.storage, f.clock);
  assert.equal(communityReportReviewWakeAt(f.storage, f.clock), null); assert.equal(hidden(f), 1);
});

test("a real file reopen recovers an applied decision and exact revision without an inspection receipt or network", async t => {
  const root = await mkdtemp(join(tmpdir(), "echoes-report-decision-")); t.after(() => rm(root, { recursive: true, force: true }));
  const f = await setup(t, { path: join(root, "state.sqlite") }), inspection = await f.inspect(), intent = decision(inspection), result = await decide(f, intent);
  f.advance(90001); await purgeCommunityReportReviews(f.storage, f.clock); f.close();
  const db = new DatabaseSync(join(root, "state.sqlite")); db.exec("PRAGMA synchronous=FULL");
  const storage = { sql: { exec(sql, ...args) { return { toArray: () => db.prepare(sql).all(...args) }; } },
    transactionSync(action) { db.exec("BEGIN IMMEDIATE"); try { const value = action(); db.exec("COMMIT"); return value; } catch (error) { db.exec("ROLLBACK"); throw error; } }, async sync() {} };
  try {
    const reviews = new CommunityReportReviewState(storage, { clock: f.clock });
    const outcome = await reviews.recover({ ...recovery(inspection, intent), reviewerID: f.operator.accountID });
    assert.equal(outcome.outcome, "confirmed"); assert.equal(outcome.revision, result.revision);
  } finally { db.close(); }
});

test("local maintenance removes erased-report metadata without provider access and preserves hidden policy", async t => {
  const f = await setup(t), inspection = await f.inspect(); await decide(f, decision(inspection)); await f.beginDeletion(f.reporter, "reporter");
  let alarm = null; Object.assign(f.storage, { async getAlarm() { return alarm; }, async setAlarm(value) { alarm = value; }, async deleteAlarm() { alarm = null; } });
  const maintenance = new GatewayMaintenance(f.storage, { limits: new GatewayLimits(f.storage, { clock: f.clock }), deletions: f.deletions, clock: f.clock });
  const before = f.model.requests.length + f.model.checkpointRequests.length; await maintenance.alarm({ providerBusy: () => true });
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 0);
  assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_inspections_v1").get().n, 0); assert.equal(hidden(f), 1);
  assert.equal(f.model.requests.length + f.model.checkpointRequests.length, before);
});

test("inspection metadata removal cannot reset the independent ten-per-minute reviewer budget", async t => {
  const f = await setup(t);
  for (let i = 0; i < 10; i++) {
    await f.inspect(); f.db.prepare("DELETE FROM community_report_inspections_v1").run();
  }
  await assert.rejects(f.inspect(), code("REPORT_REVIEW_CAPACITY"));
  f.advance(60000); assert.ok((await f.inspect()).inspectionID);
});

test("an unconfirmed inspection cannot authorize a decision", async t => {
  const f = await setup(t), inspection = await f.inspect(), key = sessionKey(f.operator.sessionToken);
  const content = f.reviews.get(f.operator.accountID, key, inspection.inspectionID).content;
  const pending = await f.reviews.reserve(f.operator.accountID, key, content);
  await assert.rejects(decide(f, decision(pending)), code("REPORT_REVIEW_STALE")); assert.equal(hidden(f), 0);
  await f.reviews.confirm(f.operator.accountID, key, pending.inspectionID); await decide(f, decision(pending, "dismiss"));
});

test("only synchronous true authorization can mutate policy; false, missing result and promises are denied", async t => {
  const f = await setup(t), inspection = await f.inspect(), key = sessionKey(f.operator.sessionToken);
  const content = f.reviews.get(f.operator.accountID, key, inspection.inspectionID).content;
  for (const authorize of [() => false, () => undefined, async () => true]) {
    await assert.rejects(f.reviews.decide({ reviewerID: f.operator.accountID, sessionKey: key, ...decision(inspection), content, authorize }), code("REPORT_REVIEW_SCOPE"));
  }
  assert.equal(hidden(f), 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 0);
});

test("reusing a decision ID for another report cannot hide the message or create a second audit row", async t => {
  const f = await setup(t), first = await f.inspect(), intent = decision(first, "dismiss"); await decide(f, intent);
  const second = await f.makeReport(), inspection = await f.inspect({ reportID: second.recordName });
  await assert.rejects(decide(f, decision(inspection, "hide_message", intent.decisionID)), code("REPORT_REVIEW_STALE"));
  assert.equal(hidden(f), 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_report_decisions_v1").get().n, 1);
});
