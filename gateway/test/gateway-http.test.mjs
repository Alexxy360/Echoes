import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { RenewalProofs } from "../src/renewal-proofs.mjs";
import { RefreshCredentialVault } from "../src/refresh-credential-vault.mjs";
import { createGatewayRuntime, createGatewayLocalMaintenance, activeGatewayConfiguration, authorityName,
  forwardGatewayRequest, handleAuthorityRequest } from "../src/gateway-runtime.mjs";
import { createGatewayHTTPHandler } from "../src/gateway-http.mjs";
import { fixture, hash, start, syntheticCode } from "./support/authentication-fixture.mjs";

function setup({ deletionEnabled = true, ...options } = {}) {
  const refresh = randomBytes(32).toString("base64url"), renewal = randomBytes(32).toString("base64url");
  const f = fixture({ ...options, renewalProofs: new RenewalProofs({ activeKeyID: "v1", keys: { v1: renewal } }),
    credentialVault: new RefreshCredentialVault({ activeKeyID: "v1", keys: { v1: refresh } }) });
  const key = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" });
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", ACCOUNT_DELETION_ENABLED: deletionEnabled ? "1" : "0",
    GATEWAY_EXPIRES_AT: new Date(start + 6 * 86400000).toISOString(), CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: key, REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1",
    REFRESH_KEYS_JSON: JSON.stringify({ v1: refresh }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: renewal }),
    REQUEST_BUDGET_KEY: randomBytes(32).toString("base64url") };
  let alarm = null, failAlarm = false, exchangeToken, externalCalls = 0, revokes = 0, exchanges = 0;
  f.storage.getAlarm = async () => alarm;
  f.storage.deleteAlarm = async () => { alarm = null; };
  f.storage.setAlarm = async value => { if (failAlarm) throw new Error("PRIVATE-ALARM-DETAIL"); alarm = value; };
  const fetchImplementation = async (request, fetchOptions) => {
    externalCalls++;
    if (request.url === "https://appleid.apple.com/auth/keys") {
      assert.ok(fetchOptions.signal instanceof AbortSignal); return Response.json({ keys: [f.publicJWK] });
    }
    const form = new URLSearchParams(await request.text());
    assert.equal(form.get("client_id"), "mpvEcho.Echo");
    if (request.url === "https://appleid.apple.com/auth/revoke") { revokes++; return new Response(null, { status: 200 }); }
    assert.equal(request.url, "https://appleid.apple.com/auth/token");
    if (form.get("grant_type") === "authorization_code") exchanges++;
    return Response.json({ access_token: "SYNTHETIC-ACCESS", token_type: "Bearer", expires_in: 3600,
      ...(form.get("grant_type") === "authorization_code" ? { refresh_token: "SYNTHETIC-REFRESH" } : {}),
      id_token: form.get("grant_type") === "authorization_code" ? exchangeToken : f.token(null) });
  };
  const erased = [];
  const erasePublicDataBatch = async context => {
    erased.push(context.accountID); return { accountID: context.accountID, deletionID: context.deletionID, remaining: false };
  };
  const dependencies = { clock: f.clock, fetchImplementation, ...(deletionEnabled ? { erasePublicDataBatch } : {}) };
  const runtime = createGatewayRuntime(f.storage, env, dependencies);
  function request(path, body = {}, token, extra = {}) {
    const headers = new Headers({ "Content-Type": "application/json", ...(token ? { Authorization: "Bearer " + token } : {}), ...extra.headers });
    return new Request("https://echoes-authority.internal" + path, { method: extra.method ?? "POST", headers,
      ...((extra.method ?? "POST") !== "GET" ? { body: extra.rawBody ?? JSON.stringify(body) } : {}) });
  }
  const call = async (path, body = {}, token, extra = {}) => {
    const response = await runtime.handle(request(path, body, token, extra), extra.budget ?? hash("trusted-edge-budget"));
    return { status: response.status, headers: response.headers, body: response.status === 204 ? null : await response.json() };
  };
  return { ...f, env, runtime, dependencies, request, call, erased,
    failAlarm(value) { failAlarm = value; }, alarm: () => alarm, counts: () => ({ externalCalls, exchanges, revokes }),
    async login() {
      const challenge = await call("/v1/auth/challenge", { purpose: "login" }); assert.equal(challenge.status, 200);
      exchangeToken = f.token(challenge.body);
      return call("/v1/auth/login", { challengeID: challenge.body.challengeID, identityToken: exchangeToken, authorizationCode: syntheticCode });
    },
  };
}

test("concrete HTTP composition completes challenge, code exchange, access, rotation and idempotent logout", async () => {
  const f = setup();
  try {
    const login = await f.login(); assert.equal(login.status, 200); assert.equal(login.body.protocolVersion, 1);
    assert.equal(login.headers.get("Cache-Control"), "no-store"); assert.equal(login.headers.has("Access-Control-Allow-Origin"), false);
    for (const privateValue of ["SYNTHETIC-REFRESH", "SYNTHETIC-ACCESS", "PRIVATE KEY", "private-synthetic@example.invalid"]) {
      assert.equal(JSON.stringify(login.body).includes(privateValue), false);
    }
    assert.equal((await f.call("/v1/auth/session", {}, login.body.sessionToken)).body.accountID, login.body.accountID);
    f.advance(2 * 3600000);
    assert.equal((await f.call("/v1/auth/session", {}, login.body.sessionToken)).status, 401);
    const next = await f.call("/v1/auth/renew", {}, login.body.renewalToken); assert.equal(next.status, 200);
    assert.notEqual(next.body.renewalToken, login.body.renewalToken); assert.equal(f.counts().exchanges, 1);
    assert.equal((await f.call("/v1/auth/logout", {}, next.body.renewalToken)).status, 204);
    assert.equal((await f.call("/v1/auth/logout", {}, next.body.renewalToken)).status, 204);
    assert.equal((await f.call("/v1/auth/session", {}, next.body.sessionToken)).status, 401);
    assert.equal(f.counts().externalCalls, 2); assert.ok(f.alarm() !== null);
  } finally { f.close(); }
});

test("replaying an older renewal through HTTP unambiguously requires reauthentication and revokes that family", async () => {
  const f = setup();
  try {
    const first = await f.login(), next = await f.call("/v1/auth/renew", {}, first.body.renewalToken);
    assert.equal(next.status, 200);
    const replay = await f.call("/v1/auth/renew", {}, first.body.renewalToken);
    assert.equal(replay.status, 401); assert.equal(replay.body.error, "REAUTH_REQUIRED");
    assert.equal((await f.call("/v1/auth/session", {}, next.body.sessionToken)).status, 401);
  } finally { f.close(); }
});

test("the native route list rejects generic RPC, methods, queries, browser origin and unexpected identity fields", async () => {
  const f = setup();
  try {
    for (const [path, extra, status] of [["/disableAccount", {}, 404], ["/v1/auth/login?nonce=PRIVATE", {}, 400],
      ["/v1/auth/login", { method: "GET" }, 405], ["/v1/auth/login", { headers: { Origin: "https://attacker.invalid" } }, 403],
      ["/v1/auth/login", { headers: { "Sec-Fetch-Site": "cross-site" } }, 403]]) {
      const result = await f.call(path, {}, undefined, extra); assert.equal(result.status, status);
      assert.equal(result.headers.has("Access-Control-Allow-Origin"), false);
      if (status === 405) assert.equal(result.headers.get("Allow"), "POST");
    }
    for (const key of ["authorID", "expectedNonce", "issuer", "keyURL", "serverBudgetHash"]) {
      const result = await f.call("/v1/auth/login", { challengeID: randomUUID(), identityToken: "PRIVATE", authorizationCode: "PRIVATE", [key]: "PRIVATE" });
      assert.equal(result.status, 400); assert.equal(JSON.stringify(result.body).includes("PRIVATE"), false);
    }
    assert.equal(f.counts().externalCalls, 0);
  } finally { f.close(); }
});

test("JSON input has byte/UTF8/shape/content encoding limits before authentication", async () => {
  const f = setup();
  try {
    const cases = [{ rawBody: "{" }, { rawBody: "null" }, { rawBody: "[]" }, { rawBody: '"text"' },
      { rawBody: new Uint8Array([0xc3, 0x28]) }, { headers: { "Content-Type": "text/plain" }, status: 415 },
      { headers: { "Content-Encoding": "gzip" }, status: 415 }, { rawBody: "x".repeat(257), status: 413 },
      { headers: { "Content-Length": "999999" }, status: 413 }];
    for (const extra of cases) {
      const result = await f.call("/v1/auth/session", {}, "PRIVATE", extra); assert.equal(result.status, extra.status ?? 400);
    }
    assert.equal(f.counts().externalCalls, 0);
  } finally { f.close(); }
});

test("stalled request bodies time out without invoking any state mutation", async () => {
  let invoked = 0;
  const handle = createGatewayHTTPHandler({ authentication: { issueChallenge() { invoked++; } }, login: { login() {} }, renewal: { renew() {} },
    limits: { async consume() {} }, scheduleMaintenance: async () => {}, isEnabled: () => true, inputTimeoutMilliseconds: 15 });
  const request = new Request("https://api.invalid/v1/auth/challenge", { method: "POST", headers: { "Content-Type": "application/json" },
    body: new ReadableStream({ start() {} }), duplex: "half" });
  const result = await handle(request, hash("edge")); assert.equal(result.status, 408); assert.equal(invoked, 0);
});

test("maintenance scheduling must succeed before the one-use code or challenge is processed", async () => {
  const f = setup();
  try {
    f.failAlarm(true); const result = await f.call("/v1/auth/challenge", { purpose: "login" });
    assert.equal(result.status, 503); assert.equal(f.counts().externalCalls, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_challenges_v1").get().count, 0);
  } finally { f.close(); }
});

test("deletion HTTP returns a recoverable ticket status and only the internal alarm processes public data and Apple", async () => {
  const f = setup();
  try {
    const login = await f.login(), challenge = await f.call("/v1/auth/challenge", { purpose: "account_deletion" });
    const deletionID = randomUUID(), statusToken = deletionID + "." + randomBytes(32).toString("base64url");
    const body = { deletionID, challengeID: challenge.body.challengeID, identityToken: f.token(challenge.body), expectedAccountID: login.body.accountID };
    const first = await f.call("/v1/account/deletion", body, statusToken); assert.equal(first.status, 202);
    assert.equal((await f.call("/v1/auth/session", {}, login.body.sessionToken)).status, 401);
    const retry = await f.call("/v1/account/deletion", { deletionID }, statusToken); assert.equal(retry.status, 202);
    assert.equal(f.erased.length, 0); assert.equal(f.counts().revokes, 0);
    assert.equal((await f.call("/v1/account/deletion/private-cleanup", { deletionID }, statusToken)).status, 200);
    await f.runtime.maintenance.alarm({ processor: f.runtime.processor }); f.advance(60001);
    await f.runtime.maintenance.alarm({ processor: f.runtime.processor });
    const status = await f.call("/v1/account/deletion/status", { deletionID }, statusToken);
    assert.equal(status.body.completed, true); assert.equal(status.body.appleAuthorization, "retained-tokens-processed");
    assert.equal(f.counts().revokes, 1); assert.equal(f.erased.length, 2);
    assert.equal(JSON.stringify(status.body).includes(login.body.accountID), false);
  } finally { f.close(); }
});

test("deletion cannot be enabled without the real erasure dependency and disabled capabilities do not accept jobs", async () => {
  const f = setup({ deletionEnabled: false });
  try {
    assert.equal((await f.call("/v1/auth/challenge", { purpose: "account_deletion" })).status, 503);
    const deletionID = randomUUID(), token = deletionID + "." + randomBytes(32).toString("base64url");
    assert.equal((await f.call("/v1/account/deletion", { deletionID }, token)).status, 503);
    f.env.ACCOUNT_DELETION_ENABLED = "1";
    assert.throws(() => createGatewayRuntime(f.storage, f.env, { clock: f.clock }), /Gateway configuration is unavailable/);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 0);
  } finally { f.close(); }
});

test("configuration rejects missing/reused secrets, invalid scope/deadlines, and never falls back to a permissive runtime", () => {
  const f = setup();
  try {
    for (const changes of [{ REQUEST_BUDGET_KEY: "" }, { REQUEST_BUDGET_KEY: JSON.parse(f.env.REFRESH_KEYS_JSON).v1 },
      { RENEWAL_KEYS_JSON: f.env.REFRESH_KEYS_JSON }, { APPLE_SIGNIN_PRIVATE_KEY: "PRIVATE-INVALID" }, { GATEWAY_ENVIRONMENT: "production" },
      { GATEWAY_ENABLED: "0" }, { GATEWAY_EXPIRES_AT: "tomorrow" }, { GATEWAY_EXPIRES_AT: new Date(start + 8 * 86400000).toISOString() }]) {
      assert.throws(() => createGatewayRuntime(f.storage, { ...f.env, ...changes }, f.dependencies), error =>
        error.message === "Gateway configuration is unavailable." && error.cause === undefined);
    }
    assert.equal(activeGatewayConfiguration({}, start), null);
  } finally { f.close(); }
});

test("activation expiry stops new HTTP/provider work while local retention remains callable without keys", async () => {
  const f = setup();
  try {
    await f.login(); const before = f.counts().externalCalls; f.advance(31 * 86400000);
    assert.equal((await f.call("/v1/auth/challenge", { purpose: "login" })).status, 503);
    delete f.env.APPLE_SIGNIN_PRIVATE_KEY; delete f.env.REFRESH_KEYS_JSON; delete f.env.RENEWAL_KEYS_JSON;
    await createGatewayLocalMaintenance(f.storage, { clock: f.clock }).alarm();
    assert.equal(f.counts().externalCalls, before);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
  } finally { f.close(); }
});

test("public edge strips spoofed budget/forwarding headers, hashes platform IP and routes every client to one authority", async () => {
  const f = setup(); let seen, names = [];
  try {
    f.env.COMMUNITY_AUTHORITY = { idFromName(name) { names.push(name); return "fixed-object"; }, get(id) {
      assert.equal(id, "fixed-object"); return { fetch(request) { seen = request;
        return handleAuthorityRequest(request, { runtime: f.runtime, env: f.env, objectID: id, clock: f.clock });
      } };
    } };
    const edge = () => { const request = new Request("https://gateway.invalid/v1/auth/challenge", { method: "POST",
      headers: { "Content-Type": "application/json", "CF-Connecting-IP": "192.0.2.17", "X-Echoes-Request-Budget": "a".repeat(64),
        "X-Forwarded-For": "198.51.100.1", Cookie: "PRIVATE-COOKIE" }, body: '{"purpose":"login"}' });
      Object.defineProperty(request, "cf", { value: { colo: "WAW" } }); return request; };
    const response = await forwardGatewayRequest(edge(), f.env, { clock: f.clock }); assert.equal(response.status, 200);
    assert.notEqual(seen.headers.get("X-Echoes-Request-Budget"), "a".repeat(64));
    assert.equal(seen.headers.get("CF-Connecting-IP"), null); assert.equal(seen.headers.get("Cookie"), null);
    assert.equal(seen.headers.get("X-Forwarded-For"), null); assert.equal(seen.url, "https://echoes-authority.internal/v1/auth/challenge");
    assert.ok(names.every(name => name === authorityName)); assert.equal(response.headers.has("Set-Cookie"), false);
    assert.equal((await handleAuthorityRequest(seen, { runtime: f.runtime, env: f.env, objectID: "another-object", clock: f.clock })).status, 503);
  } finally { f.close(); }
});

test("edge fails closed without platform context and rejects redirects or private upstream diagnostics", async () => {
  const f = setup(); let invoked = 0;
  try {
    f.env.COMMUNITY_AUTHORITY = { idFromName: () => "fixed", get: () => ({ async fetch() { invoked++; throw new Error("PRIVATE-UPSTREAM-DETAIL"); } }) };
    const request = f.request("/v1/auth/challenge", { purpose: "login" });
    const missing = await forwardGatewayRequest(request, f.env, { clock: f.clock }); assert.equal(missing.status, 503); assert.equal(invoked, 0);
    const input = () => { const r = f.request("/v1/auth/challenge", { purpose: "login" }, undefined,
      { headers: { "CF-Connecting-IP": "2001:db8::1" } }); Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); return r; };
    const failed = await forwardGatewayRequest(input(), f.env, { clock: f.clock });
    assert.equal(failed.status, 503); assert.equal((await failed.text()).includes("PRIVATE-UPSTREAM"), false);
    f.env.COMMUNITY_AUTHORITY.get = () => ({ fetch: async () => Response.redirect("https://attacker.invalid/", 302) });
    assert.equal((await forwardGatewayRequest(input(), f.env, { clock: f.clock })).status, 503);
    assert.equal(f.counts().externalCalls, 0);
  } finally { f.close(); }
});

test("health stays a shallow liveness response while the default target is disabled", async () => {
  const response = await forwardGatewayRequest(new Request("https://api.invalid/health"), {});
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), { protocolVersion: 1, status: "ok", mode: "development-gateway" });
  assert.equal((await forwardGatewayRequest(new Request("https://api.invalid/v1/auth/challenge", { method: "POST" }), {})).status, 503);
});
