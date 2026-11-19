import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { CommunityReportReview } from "../src/community-report-review.mjs";
import { reportReviewFixture as setup } from "./support/community-report-review-fixture.mjs";

const code = expected => error => error?.code === expected && !error.message.includes("PRIVATE") && error.cause === undefined;
const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };


test("report review is disabled and separately denies ordinary or promise-returning operator roles before IO", async t => {
  const f = await setup(t), before = f.model.checkpointRequests.length;
  for (const changes of [{ isEnabled: undefined }, { isOperator: undefined }, { isOperator: async () => true }]) {
    const review = new CommunityReportReview({ ...f.config, ...changes });
    await assert.rejects(review.prepareQueue(f.options()), error => ["REPORT_REVIEW_UNAVAILABLE", "REPORT_REVIEW_SCOPE"].includes(error.code));
  }
  await assert.rejects(f.review.prepareQueue({ accessToken: f.reporter.sessionToken }), code("REPORT_REVIEW_SCOPE"));
  assert.equal(f.model.checkpointRequests.length, before);
});

test("a stable 43-report keyset queue is bounded, complete, private and uses no provider report queries", async t => {
  const f = await setup(t); for (let i = 1; i < 43; i++) await f.makeReport();
  const before = f.model.requests.length, seen = [], sizes = []; let after = null;
  do {
    const page = await f.queue({ after }); sizes.push(page.items.length); seen.push(...page.items.map(item => item.reportID)); after = page.after;
    assert.equal(JSON.stringify(page).includes("PRIVATE"), false); assert.equal(JSON.stringify(page).includes(f.reporter.accountID), false);
    for (const item of page.items) assert.deepEqual(Object.keys(item).sort(), ["createdAt", "expiresAt", "reportID"]);
  } while (after);
  assert.deepEqual(sizes, [20, 20, 3]); assert.equal(new Set(seen).size, 43); assert.deepEqual(seen, [...seen].sort());
  assert.equal(f.model.requests.length, before);
});

test("inspection returns the exact confidential report and available message without GPS, reporter ID or extra profile data", async t => {
  const f = await setup(t), final = await f.review.prepareInspection(f.options({ reportID: f.report.recordName }));
  const result = final(); assert.equal(result.reason, "PRIVATE-SYNTHETIC-REPORT"); assert.equal(result.message.text, "PRIVATE-SYNTHETIC-MESSAGE");
  assert.equal(result.message.authorID, f.author.accountID); assert.equal(result.messageID, f.message.recordName);
  assert.equal(JSON.stringify(result).includes(f.reporter.accountID), false);
  for (const key of ["latitude", "longitude", "location", "song", "accessToken", "recordChangeTag"]) assert.equal(JSON.stringify(result).includes('"' + key + '"'), false);
  assert.throws(final, code("REPORT_REVIEW_UNAVAILABLE"));
});

test("inspection input rejects unrelated types, additional roles/owner fields and malformed cursors before provider IO", async t => {
  const f = await setup(t), before = f.model.checkpointRequests.length;
  for (const options of [{ reportID: f.message.recordName }, { reportID: f.report.recordName, operator: true }, { reportID: f.report.recordName, accountID: f.reporter.accountID }]) {
    await assert.rejects(f.review.prepareInspection(f.options(options)), code("REPORT_REVIEW_INPUT"));
  }
  await assert.rejects(f.review.prepareQueue(f.options({ after: f.message.recordName })), code("REPORT_REVIEW_INPUT"));
  assert.equal(f.model.checkpointRequests.length, before);
});

test("registry or provider payload mismatch never declassifies a reason and redacts private errors", async t => {
  const f = await setup(t), original = structuredClone(f.model.records.get(f.report.recordName));
  f.model.records.get(f.report.recordName).fields.reason.value = "PRIVATE-TAMPERED";
  await assert.rejects(f.inspect(), code("REPORT_REVIEW_UNAVAILABLE"));
  f.model.records.set(f.report.recordName, original); f.model.before = () => { throw new Error("PRIVATE-RAW-PROVIDER"); };
  await assert.rejects(f.inspect(), code("REPORT_REVIEW_UNAVAILABLE"));
});

test("late message expiry removes message contents while the longer-lived report remains reviewable", async t => {
  const f = await setup(t); f.advance(7199000); const replacement = await f.session("operator");
  const final = await f.review.prepareInspection({ accessToken: replacement.sessionToken, reportID: f.report.recordName });
  f.advance(1001); const result = final();
  assert.equal(result.reason, "PRIVATE-SYNTHETIC-REPORT"); assert.equal(result.message, null);
});

test("a normally expired message is shown as unavailable without preserving its text in a report snapshot", async t => {
  const f = await setup(t); f.advance(7200001);
  const replacement = await f.session("operator");
  const result = (await f.review.prepareInspection({ accessToken: replacement.sessionToken, reportID: f.report.recordName }))();
  assert.equal(result.reason, "PRIVATE-SYNTHETIC-REPORT"); assert.equal(result.message, null); assert.equal(JSON.stringify(result).includes("PRIVATE-SYNTHETIC-MESSAGE"), false);
});

test("report deletion and reviewer role removal after preparation suppress confidential final results", async t => {
  const f = await setup(t), reportFinal = await f.review.prepareInspection(f.options({ reportID: f.report.recordName }));
  await f.beginDeletion(f.reporter, "reporter"); assert.throws(reportFinal, code("REPORT_REVIEW_STALE"));
  const queueFinal = await f.review.prepareQueue(f.options()); f.role(false);
  assert.throws(queueFinal, code("REPORT_REVIEW_SCOPE"));
});

test("queue finalizer filters a report removed after the final checkpoint", async t => {
  const f = await setup(t), final = await f.review.prepareQueue(f.options());
  await f.beginDeletion(f.reporter, "reporter"); assert.deepEqual(final().items, []);
});

test("disable, wall expiry and monotonic rollback invalidate prepared data and release the slot", async t => {
  const f = await setup(t);
  let final = await f.review.prepareInspection(f.options({ reportID: f.report.recordName })); f.enable(false);
  assert.throws(final, code("REPORT_REVIEW_UNAVAILABLE")); f.enable(true);
  final = await f.review.prepareQueue(f.options()); f.moveMono(-1); assert.throws(final, code("REPORT_REVIEW_UNAVAILABLE"));
  f.moveMono(1); final = await f.review.prepareQueue(f.options()); f.advance(8001); assert.throws(final, code("REPORT_REVIEW_UNAVAILABLE"));
  assert.equal((await f.queue()).items.length, 1);
});

test("an old finalizer cannot free the slot occupied by a later uncooperative read", async t => {
  const f = await setup(t), old = await f.review.prepareQueue(f.options()); old();
  const entered = barrier(), release = barrier(); let held = false;
  f.model.beforeCheckpoint = async () => { if (!held) { held = true; entered.release(); await release.promise; } };
  const running = f.review.prepareQueue(f.options()); await entered.promise;
  assert.throws(old, code("REPORT_REVIEW_UNAVAILABLE"));
  await assert.rejects(f.review.prepareQueue(f.options()), code("REPORT_REVIEW_CAPACITY"));
  release.release(); (await running)();
});

test("aborted provider IO retains the only slot until actual completion, then permits a fresh authorized queue", async t => {
  const f = await setup(t), entered = barrier(), release = barrier(), controller = new AbortController(); let held = false;
  f.model.before = async () => { if (!held) { held = true; entered.release(); await release.promise; } };
  const running = f.review.prepareInspection(f.options({ reportID: f.report.recordName, signal: controller.signal })).catch(error => error);
  await entered.promise; controller.abort(); assert.equal((await running).code, "REPORT_REVIEW_UNAVAILABLE");
  await assert.rejects(f.review.prepareQueue(f.options()), code("REPORT_REVIEW_CAPACITY"));
  release.release(); await tick(); await tick(); f.model.before = undefined;
  assert.equal((await f.queue()).items.length, 1);
});

test("a finalizer remains bound to its original moderator even if the same token starts resolving to another allowed moderator", async t => {
  const f = await setup(t); let switched = false;
  const review = new CommunityReportReview({ ...f.config, authentication: { authorize(token) {
    return switched ? { accountID: f.author.accountID } : f.state.authorize(token);
  } }, isOperator: () => true });
  const final = await review.prepareQueue(f.options()); switched = true;
  assert.throws(final, code("REPORT_REVIEW_SCOPE"));
});

test("unsettled and expired reports never enter the operator queue", async t => {
  const f = await setup(t), requestID = randomUUID();
  await f.registry.reserve({ accountID: f.reporter.accountID, kind: "report", logicalID: requestID, requestID, payloadHash: "a".repeat(64) });
  assert.deepEqual((await f.queue()).items.map(item => item.reportID), [f.report.recordName]);
  f.advance(2592000001); const replacement = await f.session("operator");
  const result = (await f.review.prepareQueue({ accessToken: replacement.sessionToken }))(); assert.deepEqual(result.items, []);
});
