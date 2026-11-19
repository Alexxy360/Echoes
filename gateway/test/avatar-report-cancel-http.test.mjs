import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { photoReportHTTPFixture } from "./support/avatar-report-http-fixture.mjs";
import { activeGatewayConfiguration } from "../src/gateway-runtime.mjs";
import { avatarReportInput, avatarReportResult } from "../src/avatar-report-domain.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
const json = async (r, status = 200) => { const b = await r.json(); assert.equal(r.status, status, JSON.stringify(b)); return b; };
const tick = () => new Promise(r => setImmediate(r));
const barrier = () => { let release; const promise = new Promise(r => { release = r; }); return { promise, release }; };

test("cancellation input/outcome contract is closed and rejects accepted cancellation or cancelled submission", () => {
  const requestID = randomUUID(), account = randomUUID(), result = { schemaVersion: 1, requestID, reportID: recordIdentity(account, "avatarreport", requestID).recordName, outcome: "cancelled" };
  assert.deepEqual(avatarReportInput("cancel", { requestID }), { requestID });
  for (const extra of ["accountID", "reason", "coordinate", "generation", "role", "ownerID"]) assert.throws(() => avatarReportInput("cancel", { requestID, [extra]: "private" }));
  assert.deepEqual(avatarReportResult("cancel", result, { requestID }, account), result);
  assert.deepEqual(avatarReportResult("recover", result, { requestID }, account), result);
  assert.throws(() => avatarReportResult("submit", result, { requestID }, account));
  for (const outcome of ["accepted", "unconfirmed"]) assert.throws(() => avatarReportResult("cancel", { ...result, outcome }, { requestID }, account));
});

test("cancel flag defaults closed, requires report parent, and malformed values close the entire config", async t => {
  const f = await photoReportHTTPFixture(t);
  assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarReportCancelEnabled, false);
  assert.equal((await json(await f.edge("cancel"), 503)).error, "FEATURE_DISABLED");
  for (const change of [{ AVATAR_REPORT_CANCEL_ENABLED: "true" }, { AVATAR_REPORT_CANCEL_ENABLED: 1 }, { AVATAR_REPORT_CANCEL_ENABLED: "1", AVATAR_REPORT_ENABLED: "0" }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...change }, f.clock()), null);
  assert.equal(f.model.requests.filter(r => r.operation === "modify" && r.body.operations[0].record.recordType === "EchoesAvatarReportV1").length, 0);
});

for (const runtime of [false, true]) test(`cancel/recover uses ${runtime ? "concrete Runtime/edge" : "authority"} without read/upload/review and clears only own exact intent`, async t => {
  const f = await photoReportHTTPFixture(t, { runtime }), call = runtime ? f.edge : f.call, requestID = randomUUID();
  const accepted = await json(await call("submit", { requestID }));
  const oldIntent = f.social.avatarReportIntent(f.viewer.accountID, requestID);
  f.setCancellable(true); f.env.AVATAR_READ_ENABLED = "0"; f.env.AVATAR_DOWNLOAD_HOSTS_JSON = "[]"; f.setReportsReadable(false); f.setReadable(false);
  const result = await json(await call("cancel", { requestID }));
  assert.deepEqual(result, { ...accepted, outcome: "cancelled" });
  const row = f.db.prepare("SELECT ready,active,hidden FROM community_intents_v1 WHERE account_id=? AND kind='avatarreport' AND request_id=?").get(f.viewer.accountID, requestID);
  assert.deepEqual({ ...row }, { ready: 0, active: 0, hidden: 1 });
  await assert.rejects(f.social.finish(oldIntent));
  assert.equal(f.registry.readable(accepted.reportID, "avatarreport"), null);
  f.setCancellable(false);
  assert.deepEqual(await json(await call("recover", { requestID })), result);
  assert.equal((await json(await call("cancel", { requestID }), 503)).error, "FEATURE_DISABLED");
  assert.equal(f.downloads.length, 0);
});

test("unknown UUID cancellation creates a permanent fence without community intent and isolates another account", async t => {
  const f = await photoReportHTTPFixture(t, { runtime: true }), requestID = randomUUID(); f.setCancellable(true);
  const result = await json(await f.edge("cancel", { requestID })); assert.equal(result.outcome, "cancelled");
  assert.equal(f.social.avatarReportIntent(f.viewer.accountID, requestID), null);
  const foreign = await json(await f.edge("recover", { requestID }, { token: f.signedIn.sessionToken }));
  assert.equal(foreign.outcome, "unconfirmed"); assert.notEqual(foreign.reportID, result.reportID);
  const fields = f.model.records.get(result.reportID).fields;
  assert.deepEqual(Object.keys(fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
});

test("lost cancellation ACK recovers from exact fence while cancel flag is off and does not send another mutation", async t => {
  const f = await photoReportHTTPFixture(t, { runtime: true }), requestID = randomUUID(); f.setCancellable(true);
  const accepted = await json(await f.edge("submit", { requestID }));
  let lost = false;
  f.model.after = async call => { if (!lost && call.operation === "modify" && call.body.operations[0].record.recordName === accepted.reportID) { lost = true; throw Error("Synthetic lost cancel ACK"); } };
  await json(await f.edge("cancel", { requestID }), 503); assert.equal(lost, true);
  f.model.after = undefined; f.setCancellable(false);
  const before = f.model.requests.filter(c => c.operation === "modify" && c.body.operations[0].record.recordName === accepted.reportID).length;
  const result = await json(await f.edge("recover", { requestID })); assert.equal(result.outcome, "cancelled");
  assert.equal(f.model.requests.filter(c => c.operation === "modify" && c.body.operations[0].record.recordName === accepted.reportID).length, before);
});

test("cancel consumes the shared durable write budget before parsing, with no separate quota bypass", async t => {
  const f = await photoReportHTTPFixture(t); f.setCancellable(true);
  await json(await f.call("submit", {}, { rawBody: "{" }), 400);
  for (let n = 0; n < 2; n++) await json(await f.call("cancel", {}, { rawBody: "{" }), 400);
  assert.equal((await json(await f.call("cancel"), 429)).error, "RATE_LIMITED");
  assert.equal((await json(await f.call("submit"), 429)).error, "RATE_LIMITED");
  assert.equal(f.counts().scheduled, 0);
});

test("cancel finalizer withholds success after cancellation flag or account revocation", async t => {
  for (const mode of ["flag", "account"]) {
    const f = await photoReportHTTPFixture(t); f.setCancellable(true); let once = false;
    f.afterLastAdvance(async () => { if (once) return; once = true; if (mode === "flag") f.setCancellable(false); else await f.state.disableAccount(f.viewer.accountID); });
    const value = await json(await f.call("cancel"), mode === "flag" ? 503 : 401);
    assert.equal(JSON.stringify(value).includes("cancelled"), false);
  }
});

test("abort retains cancellation admission until actual provider drains; recovery then proves only the committed fence", async t => {
  const f = await photoReportHTTPFixture(t), entered = barrier(), release = barrier(), controller = new AbortController(), requestID = randomUUID();
  f.setCancellable(true);
  const name = recordIdentity(f.viewer.accountID, "avatarreport", requestID).recordName;
  f.model.before = async c => { if (c.operation === "lookup" && c.body.records.some(r => r.recordName === name)) { entered.release(); await release.promise; } };
  const running = f.call("cancel", { requestID }, { signal: controller.signal }); await entered.promise; controller.abort();
  await json(await running, 503);
  assert.equal((await json(await f.call("recover", { requestID }), 429)).error, "AVATAR_REPORT_LIMIT");
  release.release(); await f.reports.waitForPendingOperations(); await tick(); await tick(); f.model.before = undefined;
  assert.equal(f.model.records.has(name), false);
  assert.equal((await json(await f.call("recover", { requestID }))).outcome, "unconfirmed");
  assert.equal((await json(await f.call("cancel", { requestID }))).outcome, "cancelled");
});

test("actor rejects asynchronous or default cancellation grants before reserving a fence", async t => {
  const f = await photoReportHTTPFixture(t), requestID = randomUUID();
  for (const canCancel of [undefined, () => false, async () => true, () => 1]) {
    const actor = f.makeReports({ canCancel });
    await assert.rejects(actor.prepareCancellation({ accessToken: f.viewer.sessionToken, requestID }));
    assert.equal(f.registry.avatarReportCancellation(f.viewer.accountID, requestID), null);
  }
});

test("cancellation finalizer rejects a replaced registry confirmation tag after the last checkpoint", async t => {
  const f = await photoReportHTTPFixture(t), requestID = randomUUID(); f.setCancellable(true); let once = false;
  f.afterLastAdvance(async () => {
    if (once) return; once = true;
    const name = recordIdentity(f.viewer.accountID, "avatarreport", requestID).recordName;
    f.db.prepare("UPDATE public_records_v1 SET record_tag=?,avatar_report_cancel_tag=? WHERE record_name=?").run("synthetic-replaced", "synthetic-replaced", name);
  });
  const result = await json(await f.call("cancel", { requestID }), 409);
  assert.equal(result.error, "AVATAR_REPORT_CONFLICT");
});

test("edge withholds cancellation ACK when its flag changes while the upstream body is still streaming", async t => {
  const f = await photoReportHTTPFixture(t), entered = barrier(), requestID = randomUUID(); f.setCancellable(true); let stream;
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() { return new Response(new ReadableStream({ start(c) { stream = c; }, pull() { entered.release(); } }),
    { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); } });
  const running = f.edge("cancel", { requestID }); await entered.promise; f.setCancellable(false);
  stream.enqueue(new TextEncoder().encode(JSON.stringify({ protocolVersion: 1, schemaVersion: 1, requestID,
    reportID: recordIdentity(f.viewer.accountID, "avatarreport", requestID).recordName, outcome: "cancelled" }))); stream.close();
  assert.equal((await json(await running, 503)).error, "AVATAR_REPORT_UNAVAILABLE");
});
