import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { photoReportHTTPFixture } from "./support/avatar-report-http-fixture.mjs";
import { activeGatewayConfiguration, createGatewayRuntime } from "../src/gateway-runtime.mjs";
import { avatarReportAdmission, avatarReportDeadline, avatarReportEdgeResponse } from "../src/avatar-report-http.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";
const code = value => error => error?.code === value;
const json = async (r, status = 200) => { const b = await r.json(); assert.equal(r.status, status, JSON.stringify(b)); return b; };
const barrier = () => { let release; const promise = new Promise(r => { release = r; }); return { promise, release }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
const safe = r => { assert.equal(r.headers.get("Cache-Control"), "no-store"); assert.equal(r.headers.get("X-Content-Type-Options"), "nosniff"); assert.equal(r.headers.has("Access-Control-Allow-Origin"), false); };

for (const runtime of [false, true]) test(`photo report submit/recover uses ${runtime ? "concrete Runtime and edge" : "authority"} without moderator privileges or photo bytes`, async t => {
  const f = await photoReportHTTPFixture(t, { runtime }), call = runtime ? f.edge : f.call, requestID = randomUUID();
  const response = await call("submit", { requestID }); safe(response); const value = await json(response);
  assert.equal(value.reportID, recordIdentity(f.viewer.accountID, "avatarreport", requestID).recordName);
  assert.equal(value.outcome, "accepted"); assert.deepEqual(Object.keys(value).sort(), ["outcome", "protocolVersion", "reportID", "requestID", "schemaVersion"]);
  assert.deepEqual(await json(await call("recover", { requestID })), value); assert.equal(f.downloads.length, 0);
  assert.equal([...f.model.records.values()].filter(r => r.recordType === "EchoesAvatarReportV1").length, 1);
  assert.equal(JSON.stringify(value).includes("PRIVATE"), false); assert.equal(JSON.stringify(value).includes(f.signedIn.accountID), false);
});

test("photo report flag defaults closed and requires community but recovery does not require read/upload or moderator roles", async t => {
  const f = await photoReportHTTPFixture(t), env = { ...f.env }; delete env.AVATAR_REPORT_ENABLED;
  assert.equal(activeGatewayConfiguration(env, f.clock()).avatarReportEnabled, false);
  for (const changes of [{ AVATAR_REPORT_ENABLED: "true" }, { COMMUNITY_ENABLED: "0" }, { PUBLIC_RECORDS_ENABLED: "0" }]) assert.equal(activeGatewayConfiguration({ ...f.env, ...changes }, f.clock()), null);
  const requestID = randomUUID(); await json(await f.call("submit", { requestID }));
  f.env.AVATAR_READ_ENABLED = "0"; f.env.AVATAR_DOWNLOAD_HOSTS_JSON = "[]";
  f.env.COMMUNITY_AUTHORITY.get = () => ({ fetch: request => createGatewayRuntime(f.storage, f.env, f.runtimeOptions).handle(request, "a".repeat(64)) });
  assert.equal(activeGatewayConfiguration(f.env, f.clock()).avatarReportEnabled, true);
  assert.equal((await json(await f.edge("recover", { requestID }))).outcome, "accepted");
  assert.equal((await json(await f.edge("submit"), 503)).error, "FEATURE_DISABLED");
  f.env.AVATAR_REPORT_ENABLED = "0"; assert.equal((await json(await f.edge("recover", { requestID }), 503)).error, "FEATURE_DISABLED");
});

test("closed JSON and headers reject forged account/hash/generation/role fields before any scheduled/provider work", async t => {
  const cases = [[{ accountID: randomUUID() }, {}], [{ imageSHA256: "a".repeat(64) }, {}], [{ generation: 1 }, {}], [{ role: "moderator" }, {}],
    [{ reason: "\ud800" }, {}], [{}, { rawBody: '{"requestID":' }], [{}, { headers: { "Content-Encoding": "gzip" } }],
    [{}, { headers: { Range: "bytes=0-1" } }], [{}, { headers: { "X-Echoes-Avatar-Selection": "private" } }],
    [{}, { headers: { "Content-Length": "4097" } }], [{}, { headers: { "Content-Length": "1" } }], [{}, { rawBody: new Uint8Array([0xff]) }]];
  for (const [changes, options] of cases) {
    const f = await photoReportHTTPFixture(t), before = f.model.requests.length;
    assert.equal((await json(await f.call("submit", changes, options), 400)).error, "AVATAR_REPORT_INPUT");
    assert.equal(f.counts().scheduled, 0); assert.equal(f.model.requests.length, before);
  }
});

test("invalid sessions fail before account quota/body/provider and never borrow review roles", async t => {
  const f = await photoReportHTTPFixture(t), before = f.model.requests.length;
  const stream = new ReadableStream({ pull() { throw Error("body must not be read"); } });
  assert.equal((await json(await f.call("submit", {}, { token: randomUUID() + "." + "a".repeat(43), rawBody: stream }), 401)).error, "AVATAR_REPORT_SCOPE");
  assert.equal(f.counts().account, 0); assert.equal(f.counts().scheduled, 0); assert.equal(f.model.requests.length, before);
});

test("malformed bodies spend durable account quotas before parsing, and runtime recreation cannot reset them", async t => {
  const f = await photoReportHTTPFixture(t);
  for (let i = 0; i < 3; i++) await json(await f.call("submit", {}, { rawBody: "{" }), 400);
  assert.equal((await json(await f.call("submit"), 429)).error, "RATE_LIMITED");
  const limits = new GatewayLimits(f.storage, { clock: f.clock });
  await assert.rejects(limits.consumeAvatarReport(f.viewer.accountID, { submit: true }), code("RATE_LIMITED"));
  // Both denied attempts also spend the combined budget; one of six requests remains.
  await limits.consumeAvatarReport(f.viewer.accountID);
  await assert.rejects(limits.consumeAvatarReport(f.viewer.accountID), code("RATE_LIMITED"));
  assert.equal(f.counts().scheduled, 0);
});

test("both block directions and outside radius produce the same closed not-found response", async t => {
  for (const mode of ["forward", "reverse", "far"]) {
    const f = await photoReportHTTPFixture(t);
    if (mode !== "far") await f.callCommunity(mode === "forward" ? f.viewer : f.signedIn, "block", { requestID: randomUUID(),
      accountID: mode === "forward" ? f.signedIn.accountID : f.viewer.accountID, blocked: true, generation: 0 });
    const result = await json(await f.edge("submit", mode === "far" ? { coordinate: { latitude: 0, longitude: 0 } } : {}), 404);
    assert.deepEqual(result, { protocolVersion: 1, error: "AVATAR_REPORT_NOT_FOUND" });
  }
});

test("final checkpoint account revocation or publication withdrawal withholds accepted acknowledgement", async t => {
  for (const mode of ["account", "withdraw", "flag"]) {
    const f = await photoReportHTTPFixture(t); let done = false;
    f.afterLastAdvance(async () => {
      if (done) return; done = true;
      if (mode === "account") await f.state.disableAccount(f.viewer.accountID);
      if (mode === "withdraw") {
        const final = await f.coordinator.prepareClear(f.credentials({ requestID: randomUUID(), expectedGeneration: f.photo.generation })); await f.checkpoint.advance(); final();
      }
      if (mode === "flag") f.setFeature(false);
    });
    const value = await json(await f.call("submit"), mode === "account" ? 401 : mode === "withdraw" ? 404 : 503);
    assert.equal(JSON.stringify(value).includes("accepted"), false);
  }
});

test("abort retains authority admission until the real provider drains and cannot commit a late report", async t => {
  const f = await photoReportHTTPFixture(t), entered = barrier(), release = barrier(), controller = new AbortController();
  const avatarID = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
  f.model.before = async call => { if (call.operation === "lookup" && call.body.records.some(r => r.recordName === avatarID)) { entered.release(); await release.promise; } };
  const running = f.call("submit", {}, { signal: controller.signal }); await entered.promise; controller.abort();
  await json(await running, 503); assert.equal((await json(await f.call("recover"), 429)).error, "AVATAR_REPORT_LIMIT");
  release.release(); await f.reports.waitForPendingOperations(); await tick(); await tick(); f.model.before = undefined;
  assert.equal([...f.model.records.values()].filter(r => r.recordType === "EchoesAvatarReportV1").length, 0);
  assert.equal((await json(await f.call("recover"))).outcome, "unconfirmed");
});

test("bounded input deadline retains slow cancellation and maps shared IO codes into the photo-report domain", async t => {
  const f = await photoReportHTTPFixture(t, { settings: { inputTimeoutMilliseconds: 15 } }), cancelEntered = barrier(), release = barrier();
  const body = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("{")); }, cancel() { cancelEntered.release(); return release.promise; } });
  const running = f.call("submit", {}, { rawBody: body }); await cancelEntered.promise;
  assert.equal((await json(await f.call("recover"), 429)).error, "AVATAR_REPORT_LIMIT");
  release.release(); assert.equal((await json(await running, 503)).error, "AVATAR_REPORT_UNAVAILABLE");
  await tick(); await tick(); assert.equal((await json(await f.call("recover"))).outcome, "unconfirmed");
});

test("edge rebuilds only allowlisted headers and rejects origin/query/method impersonation", async t => {
  const f = await photoReportHTTPFixture(t), requestID = randomUUID();
  await json(await f.edge("recover", { requestID }, { headers: { "X-Operator": "true", "X-Forwarded-For": "1.1.1.1", "X-Echoes-Request-Budget": "private" } }));
  const forwarded = f.forwarded[0]; assert.equal(forwarded.headers.has("X-Operator"), false); assert.match(forwarded.headers.get("X-Echoes-Request-Budget"), /^[a-f0-9]{64}$/);
  assert.equal((await json(await f.call("recover", { requestID }, { headers: { Origin: "https://hostile.invalid" } }), 403)).error, "ORIGIN_NOT_ALLOWED");
  for (const request of [new Request("https://echoes-authority.internal/v1/community/avatar/report"), new Request("https://echoes-authority.internal/v1/community/avatar/report?account=x", { method: "POST" })]) await json(await f.authority.handle(request, "a".repeat(64)), request.method === "GET" ? 405 : 400);
});

test("edge rejects wrong intent identities, private fields, status/code confusion and cache metadata", async t => {
  const f = await photoReportHTTPFixture(t), input = f.body("recover"), value = { schemaVersion: 1, requestID: input.requestID,
    reportID: recordIdentity(f.viewer.accountID, "avatarreport", input.requestID).recordName, outcome: "unconfirmed" };
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
  for (const response of [Response.json({ protocolVersion: 1, ...value, requestID: randomUUID() }, { headers }),
    Response.json({ protocolVersion: 1, ...value, reason: "private" }, { headers }), Response.json({ protocolVersion: 1, error: "REPORT_REVIEW_SCOPE" }, { status: 403, headers }),
    Response.json({ protocolVersion: 1, error: "AVATAR_REPORT_SCOPE" }, { status: 404, headers }),
    new Response(" ".repeat(2049), { headers }), Response.json({ protocolVersion: 1, ...value }, { headers: { ...headers, "Cache-Control": "public" } })]) {
    const admission = avatarReportAdmission()(), deadline = avatarReportDeadline(undefined, 1000);
    await assert.rejects(admission.run(deadline, () => avatarReportEdgeResponse(response, "recover", input, deadline, admission)), code("AVATAR_REPORT_RESPONSE")); admission.close(); deadline.close();
  }
});

test("edge rechecks flags after upstream response body completes", async t => {
  const f = await photoReportHTTPFixture(t), entered = barrier(); let stream;
  const input = f.body("recover");
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() { return new Response(new ReadableStream({ start(c) { stream = c; }, pull() { entered.release(); } }),
    { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); } });
  const running = f.edge("recover", input); await entered.promise; f.env.AVATAR_REPORT_ENABLED = "0";
  stream.enqueue(new TextEncoder().encode(JSON.stringify({ protocolVersion: 1, schemaVersion: 1, ...input,
    reportID: recordIdentity(f.viewer.accountID, "avatarreport", input.requestID).recordName, outcome: "unconfirmed" }))); stream.close();
  assert.equal((await json(await running, 503)).error, "AVATAR_REPORT_UNAVAILABLE");
});

test("edge retains its admission for an aborted late response and maps busy into the photo report domain", async t => {
  const f = await photoReportHTTPFixture(t), entered = barrier(), release = barrier(), cancelEntered = barrier(), cancelRelease = barrier(), controller = new AbortController();
  const input = f.body("recover"); let fetches = 0;
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() {
    fetches++; entered.release(); await release.promise;
    return new Response(new ReadableStream({ cancel() { cancelEntered.release(); return cancelRelease.promise; } }),
      { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
  } });
  const pending = f.edge("recover", input, { signal: controller.signal }); await entered.promise; controller.abort();
  assert.equal((await json(await pending, 503)).error, "AVATAR_REPORT_UNAVAILABLE");
  assert.equal((await json(await f.edge("recover"), 429)).error, "AVATAR_REPORT_LIMIT");
  release.release(); await cancelEntered.promise;
  assert.equal((await json(await f.edge("recover"), 429)).error, "AVATAR_REPORT_LIMIT"); assert.equal(fetches, 1);
  cancelRelease.release(); await tick(); await tick();
  f.env.COMMUNITY_AUTHORITY.get = () => ({ async fetch() { return Response.json({ protocolVersion: 1, schemaVersion: 1, ...input,
    reportID: recordIdentity(f.viewer.accountID, "avatarreport", input.requestID).recordName, outcome: "unconfirmed" },
    { headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } }); } });
  assert.equal((await json(await f.edge("recover", input))).outcome, "unconfirmed");
});

test("actual byte/chunk budgets reject oversized and fragmented bodies before scheduled IO", async t => {
  for (const kind of ["bytes", "chunks", "null", "array"]) {
    const f = await photoReportHTTPFixture(t);
    const rawBody = kind === "bytes" ? " ".repeat(4097) : kind === "null" ? "null" : kind === "array" ? "[]" : new ReadableStream({ start(c) {
      for (let i = 0; i < 129; i++) c.enqueue(new Uint8Array([32])); c.close();
    } });
    assert.equal((await json(await f.call("submit", {}, { rawBody }), 400)).error, "AVATAR_REPORT_INPUT"); assert.equal(f.counts().scheduled, 0);
  }
});

test("report-only Runtime permits owner withdrawal/status but grants no upload/publish/reviewer route", async t => {
  const f = await photoReportHTTPFixture(t);
  f.env.AVATAR_READ_ENABLED = "0"; f.env.AVATAR_DOWNLOAD_HOSTS_JSON = "[]";
  const runtime = createGatewayRuntime(f.storage, f.env, f.runtimeOptions);
  const call = async (action, body) => runtime.handle(new Request("https://echoes-authority.internal" + (action.startsWith("/") ? action : "/v1/community/avatar/" + action), { method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + f.signedIn.sessionToken }, body: JSON.stringify(body) }), "a".repeat(64));
  assert.equal((await json(await call("status", {}))).status, "published");
  assert.equal((await json(await call("publish", {}), 503)).error, "FEATURE_DISABLED");
  assert.equal((await json(await call("/v1/moderation/avatar/queue", {}), 503)).error, "FEATURE_DISABLED");
  assert.equal((await json(await call("clear", { requestID: randomUUID(), expectedGeneration: f.photo.generation }))).status, "none");
});

test("real authority deadline aborts slow operations despite a frozen application clock and holds provider admission", async t => {
  const f = await photoReportHTTPFixture(t, { settings: { avatarReportTimeoutMilliseconds: 1000 } }), entered = barrier(), release = barrier(); let held = false;
  f.model.before = async call => { if (!held && call.operation === "lookup") { held = true; entered.release(); await release.promise; } };
  const pending = f.call("submit"); await Promise.race([entered.promise, pending.then(() => assert.fail("Deadline proof did not reach the held provider"))]);
  assert.equal((await json(await pending, 503)).error, "AVATAR_REPORT_UNAVAILABLE");
  assert.equal((await json(await f.call("recover"), 429)).error, "AVATAR_REPORT_LIMIT");
  release.release(); await tick(); await tick(); f.model.before = undefined;
});
