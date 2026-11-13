import { test } from "node:test";
import assert from "node:assert/strict";
import { handleDevelopmentProbe, jsonResponse } from "../src/probe-http.mjs";

const now = Date.parse("2026-11-13T10:00:00Z");
const env = { PROBE_ENABLED: "1", CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
  PROBE_RUN_ID: "00000000-0000-4000-8000-000000000001", PROBE_BEARER_TOKEN: "A".repeat(43),
  PROBE_EXPIRES_AT: new Date(now + 3600000).toISOString() };
function request({ body = "{}", authorization = "Bearer " + env.PROBE_BEARER_TOKEN, path = "/probe", method = "POST", type = "application/json" } = {}) {
  return new Request("https://test.invalid" + path, { method,
    headers: { Authorization: authorization, "Content-Type": type, Origin: "https://untrusted.invalid" },
    ...(method === "POST" ? { body } : {}),
  });
}

test("unauthorized requests never reach the durable gate", async () => {
  for (const authorization of ["", "Bearer wrong", "bearer " + env.PROBE_BEARER_TOKEN, "Bearer " + "B".repeat(43), "x".repeat(257)]) {
    let calls = 0;
    const response = await handleDevelopmentProbe(request({ authorization }), env, async () => { calls++; }, now);
    assert.equal(response.status, 401);
    assert.equal(calls, 0);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(response.headers.get("Access-Control-Allow-Origin"), null);
  }
});

test("missing, expired, excessive or incorrect activation fails closed", async () => {
  for (const change of [ { PROBE_ENABLED: "0" }, { CLOUDKIT_ENVIRONMENT: "production" },
    { CLOUDKIT_CONTAINER: "iCloud.other" }, { PROBE_RUN_ID: "-".repeat(36) },
    { PROBE_BEARER_TOKEN: "short" }, { PROBE_EXPIRES_AT: new Date(now).toISOString() },
    { PROBE_EXPIRES_AT: new Date(now + 7200001).toISOString() }, { PROBE_EXPIRES_AT: "invalid" } ]) {
    const response = await handleDevelopmentProbe(request(), { ...env, ...change }, () => { throw new Error("Gate must not be called"); }, now);
    assert.equal(response.status, 503);
  }
});

test("client cannot select records, payload or destination and oversized input is rejected", async () => {
  for (const body of ['{"recordName":"someone-else"}', '[]', '{}x', 'x'.repeat(65), 'ą'.repeat(33)]) {
    let calls = 0;
    assert.equal((await handleDevelopmentProbe(request({ body }), env, () => { calls++; }, now)).status, 400);
    assert.equal(calls, 0);
  }
  assert.equal((await handleDevelopmentProbe(request({ type: "text/plain" }), env, () => { throw new Error(); }, now)).status, 400);
});

test("only POST /probe without query is an executable route", async () => {
  const unreachable = () => { throw new Error("Gate must not be called"); };
  assert.equal((await handleDevelopmentProbe(request({ path: "/probe?recordName=x" }), env, unreachable, now)).status, 404);
  assert.equal((await handleDevelopmentProbe(request({ path: "/private/records/query" }), env, unreachable, now)).status, 404);
  const response = await handleDevelopmentProbe(request({ method: "GET" }), env, unreachable, now);
  assert.equal(response.status, 405);
  assert.equal(response.headers.get("Allow"), "POST");
});

test("valid caller can invoke only the server-configured run, with uncached output", async () => {
  let calls = 0;
  const response = await handleDevelopmentProbe(request(), env, async (runID) => {
    calls++;
    assert.equal(runID, env.PROBE_RUN_ID);
    return jsonResponse({ runIdentifier: runID, state: "synthetic-test" });
  }, now);
  assert.equal(response.status, 200);
  assert.equal(calls, 1);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(JSON.stringify(await response.json()).includes(env.PROBE_BEARER_TOKEN), false);
});

test("upstream failures are generic and health never executes a probe", async () => {
  const response = await handleDevelopmentProbe(request(), env, () => { throw new Error("SYNTHETIC-PRIVATE-DETAIL"); }, now);
  assert.equal(response.status, 503);
  assert.equal((await response.text()).includes("SYNTHETIC-PRIVATE-DETAIL"), false);
  const malformed = await handleDevelopmentProbe(request(), env, () => new Response("SYNTHETIC-PRIVATE-DETAIL", { status: 500 }), now);
  assert.equal(malformed.status, 503);
  assert.equal((await malformed.text()).includes("SYNTHETIC-PRIVATE-DETAIL"), false);
  const health = await handleDevelopmentProbe(request({ path: "/health", method: "GET" }), {}, () => { throw new Error(); }, now);
  assert.deepEqual(await health.json(), { status: "ok", mode: "development-diagnostic" });
});
