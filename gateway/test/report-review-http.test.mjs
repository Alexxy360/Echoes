import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { reportHTTPFixture } from "./support/report-review-http-fixture.mjs";
import { activeGatewayConfiguration } from "../src/gateway-runtime.mjs";
import { reportReviewInput, reportReviewResult, reportReviewAdmission, reportReviewDeadline, reportReviewBody, reportReviewEdgeResponse } from "../src/report-review-http.mjs";

const code = value => error => error?.code === value;
const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
const json = async (response, status = 200) => { const body = await response.json(); assert.equal(response.status, status, JSON.stringify(body)); return body; };
function safe(response) { assert.equal(response.headers.get("Cache-Control"), "no-store"); assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff"); assert.equal(response.headers.has("Access-Control-Allow-Origin"), false); }

for (const runtime of [false, true]) test(`closed HTTP inspection/decision/recovery works through ${runtime ? "concrete Runtime and edge" : "authority"} with exact response identities`, async t => {
  const f = await reportHTTPFixture(t, { runtime }), call = runtime ? f.edge.bind(f) : f.call.bind(f);
  let response = await call("queue"); safe(response); assert.equal((await json(response)).items[0].reportID, f.report.recordName);
  const inspection = await json(await call("inspect")); assert.equal(inspection.message.text, "PRIVATE-SYNTHETIC-MESSAGE");
  const intent = { inspectionID: inspection.inspectionID, decisionID: randomUUID(), verdict: "hide_message" };
  const result = await json(await call("decide", intent)); assert.equal(result.decisionID, intent.decisionID);
  assert.deepEqual((await json(await call("queue"))).items, []);
  const outcome = await json(await call("recover", { reportID: inspection.reportID, decisionID: intent.decisionID, verdict: intent.verdict, contentHash: inspection.contentHash }));
  assert.equal(outcome.outcome, "confirmed"); assert.equal(outcome.revision, result.revision);
  assert.equal(f.db.prepare("SELECT hidden FROM community_intents_v1 WHERE account_id=? AND kind='message'").get(f.author.accountID).hidden, 1);
});

test("report role is separate from avatars and missing/invalid/empty activation configuration is closed", async t => {
  const f = await reportHTTPFixture(t), original = { ...f.env };
  for (const changes of [{ REPORT_REVIEWER_IDS_JSON: "[]" }, { REPORT_REVIEWER_IDS_JSON: '{"operator":true}' },
    { REPORT_REVIEWER_IDS_JSON: JSON.stringify([f.operator.accountID, f.operator.accountID]) }, { COMMUNITY_ENABLED: "0" }, { REPORT_REVIEW_ENABLED: "true" }]) {
    assert.equal(activeGatewayConfiguration({ ...original, ...changes }, f.clock()), null);
  }
  const disabled = { ...original, REPORT_REVIEW_ENABLED: "0", REPORT_REVIEWER_IDS_JSON: "[]", AVATAR_REVIEWER_IDS_JSON: JSON.stringify([f.operator.accountID]) };
  assert.equal(activeGatewayConfiguration(disabled, f.clock()).reportReviewEnabled, false);
  f.env.REPORT_REVIEW_ENABLED = "0"; assert.equal((await json(await f.edge("queue"), 503)).error, "FEATURE_DISABLED"); assert.equal(f.forwarded.length, 0);
});

test("ordinary and asynchronous-role callers are refused before body, scheduling or provider access", async t => {
  const f = await reportHTTPFixture(t), before = f.model.checkpointRequests.length;
  const result = await json(await f.call("inspect", {}, { token: f.reporter.sessionToken }), 403); assert.equal(result.error, "REPORT_REVIEW_SCOPE");
  assert.equal(f.counts().scheduled, 0); assert.equal(f.counts().accountLimits, 0); assert.equal(f.model.checkpointRequests.length, before);
  const other = await reportHTTPFixture(t, { settings: { isReportReviewer: async () => true } });
  assert.equal((await json(await other.call("queue"), 403)).error, "REPORT_REVIEW_SCOPE");
});

test("strict body and headers reject owner/role fields, bad lengths, encodings and conditional requests", async t => {
  const f = await reportHTTPFixture(t);
  for (const [changes, options] of [[{ operator: true }, {}], [{ accountID: f.reporter.accountID }, {}], [{}, { rawBody: '{"after":' }],
    [{}, { headers: { "Content-Encoding": "gzip" } }], [{}, { headers: { Range: "bytes=0-10" } }], [{}, { headers: { "Content-Length": "513" } }]]) {
    const result = await json(await f.call("queue", changes, options), 400); assert.equal(result.error, "REPORT_REVIEW_INPUT");
  }
  assert.equal(f.counts().scheduled, 0);
});

test("the last authority checkpoint cannot release confidential content after role revocation", async t => {
  const f = await reportHTTPFixture(t); f.afterLastAdvance(() => f.role(false));
  const body = await json(await f.call("inspect"), 403); assert.equal(body.error, "REPORT_REVIEW_SCOPE"); assert.equal(JSON.stringify(body).includes("PRIVATE"), false);
});

test("account quotas count invalid attempted bodies and use a separate namespace from avatar review", async t => {
  const f = await reportHTTPFixture(t);
  for (let i = 0; i < 30; i++) await f.limits.consumeReportReview(f.operator.accountID);
  await assert.rejects(f.limits.consumeReportReview(f.operator.accountID), code("RATE_LIMITED"));
  await f.limits.consumeAvatarReview(f.operator.accountID);
  assert.equal((await json(await f.call("queue"), 429)).error, "RATE_LIMITED");
});

test("edge canonicalizes bounded input, strips client budget/role headers and binds the result to the request", async t => {
  const f = await reportHTTPFixture(t);
  await json(await f.edge("queue", {}, { rawBody: ' { "after" : null } ', headers: { "X-Echoes-Request-Budget": "forged", "X-Operator": "yes" } }));
  const forwarded = f.forwarded[0]; assert.match(forwarded.headers.get("X-Echoes-Request-Budget"), /^[a-f0-9]{64}$/);
  assert.equal(forwarded.headers.has("X-Operator"), false); assert.equal(forwarded.headers.get("Content-Length"), "14");
});

test("edge rejects mismatched private payloads and configuration changes during upstream work", async t => {
  const f = await reportHTTPFixture(t); let calls = 0;
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() {
    calls++; f.env.REPORT_REVIEWER_IDS_JSON = JSON.stringify([f.reporter.accountID]);
    return Response.json({ protocolVersion: 1, schemaVersion: 1, items: [], after: null }, { headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
  } });
  assert.equal((await json(await f.edge("queue"), 503)).error, "REPORT_REVIEW_UNAVAILABLE"); assert.equal(calls, 1);
  const g = await reportHTTPFixture(t), value = await json(await g.call("inspect"));
  g.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() { return Response.json({ ...value, reportID: "community-v1-report-" + "a".repeat(64) }, { headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); } });
  assert.equal((await json(await g.edge("inspect"), 503)).error, "REPORT_REVIEW_RESPONSE");
});

test("strict result validation removes protocol confusion and can never forward reporter/GPS fields or wrong intent IDs", async t => {
  const f = await reportHTTPFixture(t), value = await json(await f.call("inspect")), { protocolVersion, ...valid } = value;
  for (const mutate of [v => v.reporterID = f.reporter.accountID, v => v.message.latitude = 1, v => v.inspectionExpiresAt = f.clock(), v => v.message.expiresAt += 1]) {
    const changed = structuredClone(valid); mutate(changed); assert.throws(() => reportReviewResult("inspect", changed, { reportID: f.report.recordName }, f.clock()), code("REPORT_REVIEW_RESPONSE"));
  }
  assert.throws(() => reportReviewInput("recover", { reportID: f.report.recordName, decisionID: randomUUID(), verdict: "hide_message", contentHash: "a".repeat(64), revision: randomUUID() }), code("REPORT_REVIEW_INPUT"));
});

test("body cancellation retains admission after abort until the actual cancellation promise resolves", async () => {
  const entered = barrier(), release = barrier(), controller = new AbortController(), claim = reportReviewAdmission(), admission = claim(), deadline = reportReviewDeadline(controller.signal, 1000);
  const body = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"after":')); }, cancel() { entered.release(); return release.promise; } });
  const actual = admission.run(deadline, () => reportReviewBody(new Request("https://synthetic.invalid", { method: "POST", body, duplex: "half" }), { maximum: 512, length: null }, deadline, () => admission.poison())).catch(error => error);
  await tick(); controller.abort(); await entered.promise; admission.close();
  assert.throws(claim, code("REPORT_REVIEW_CAPACITY")); release.release(); await actual; await tick(); await tick(); claim().close(); deadline.close();
});

test("failed cancellation permanently closes its admission gate", async () => {
  const claim = reportReviewAdmission(), admission = claim(), deadline = reportReviewDeadline(undefined, 1000);
  const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array(513)); }, cancel() { throw new Error("PRIVATE-CANCEL"); } });
  await assert.rejects(admission.run(deadline, () => reportReviewBody(new Response(stream), { maximum: 512, length: null }, deadline, () => admission.poison())), code("REPORT_REVIEW_INPUT"));
  admission.close(); deadline.close(); assert.throws(claim, code("REPORT_REVIEW_CAPACITY"));
});

test("edge response validation bounds bytes, status/error pairs and cache metadata", async () => {
  for (const response of [Response.json({ protocolVersion: 1, error: "PRIVATE-ERROR" }, { status: 403 }),
    new Response(" ".repeat(8193), { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }),
    Response.json({ protocolVersion: 1, schemaVersion: 1, items: [], after: null }, { headers: { "Cache-Control": "public, max-age=60", "X-Content-Type-Options": "nosniff" } })]) {
    const admission = reportReviewAdmission()(), deadline = reportReviewDeadline(undefined, 1000);
    await assert.rejects(admission.run(deadline, () => reportReviewEdgeResponse(response, "queue", { after: null }, deadline, admission)), code("REPORT_REVIEW_RESPONSE")); admission.close(); deadline.close();
  }
});

test("authority admission remains occupied after abort until the coordinator's actual provider drain", async t => {
  const f = await reportHTTPFixture(t), entered = barrier(), release = barrier(), controller = new AbortController(); let held = false;
  f.model.before = async call => { if (!held && call.operation === "lookup") { held = true; entered.release(); await release.promise; } };
  const running = f.call("inspect", {}, { signal: controller.signal });
  await entered.promise; controller.abort(); await json(await running, 503);
  assert.equal((await json(await f.call("queue"), 429)).error, "REPORT_REVIEW_CAPACITY");
  release.release(); await f.review.waitForPendingOperations(); await tick(); await tick(); f.model.before = undefined;
  assert.equal((await json(await f.call("queue"))).items.length, 1);
});

test("edge withholds a fully parsed response when operator configuration changes during its body", async t => {
  const f = await reportHTTPFixture(t), entered = barrier(); let streamController;
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() {
    const stream = new ReadableStream({ start(controller) { streamController = controller; }, pull() { entered.release(); } });
    return new Response(stream, { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
  } });
  const running = f.edge("queue"); await entered.promise;
  f.env.REPORT_REVIEWER_IDS_JSON = JSON.stringify([f.reporter.accountID]);
  streamController.enqueue(new TextEncoder().encode(JSON.stringify({ protocolVersion: 1, schemaVersion: 1, items: [], after: null }))); streamController.close();
  assert.equal((await json(await running, 503)).error, "REPORT_REVIEW_UNAVAILABLE");
});
