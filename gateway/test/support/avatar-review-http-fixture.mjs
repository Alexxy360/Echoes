import assert from "node:assert/strict";
import { randomBytes, generateKeyPairSync } from "node:crypto";
import { avatarReviewFixture } from "./avatar-review-fixture.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";

export async function avatarReviewHTTPFixture({ runtime = false, ...settings } = {}) {
  const f = await avatarReviewFixture(), limits = new GatewayLimits(f.storage, { clock: f.clock });
  const secret = () => randomBytes(32).toString("base64url");
  let enabled = true, feature = true, prepared = false, afterAdvance;
  const counts = { budgets: 0, accountLimits: 0, verifies: 0, scheduled: 0 };
  const isReviewer = id => { if (!feature || !f.operators.has(id)) return false; f.social.assertActive(id); return true; };
  const deps = { authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
    limits: { async consume(...args) { counts.budgets++; return limits.consume(...args); },
      async consumeAvatarReview(...args) { counts.accountLimits++; return limits.consumeAvatarReview(...args); } },
    checkpoint: { async verify(...args) { counts.verifies++; return f.checkpoint.verify(...args); },
      async advance(...args) { await f.checkpoint.advance(...args); if (prepared) await afterAdvance?.(); } },
    avatarReview: Object.fromEntries(["prepareQueue", "prepareInspection", "prepareDecision", "prepareRecovery"].map(method => [method, async value => {
      const final = await f.coordinator[method](value); prepared = true; return final;
    }])), isEnabled: () => enabled, isAvatarReviewEnabled: () => feature, isAvatarReviewer: isReviewer,
    scheduleMaintenance: async () => { counts.scheduled++; }, clock: f.clock, ...settings };
  f.storage.getAlarm = async () => null; f.storage.setAlarm = async () => {}; f.storage.deleteAlarm = async () => {};
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(f.clock() + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_UPLOAD_ENABLED: "0", AVATAR_READ_ENABLED: "0",
    AVATAR_REVIEW_ENABLED: "1", AVATAR_REVIEWER_IDS_JSON: JSON.stringify([f.reviewer.accountID]), AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]',
    CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", ...syntheticPublicKeyConfiguration(),
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const runtimeOptions = { clock: f.clock, fetchImplementation: (request, context) => new URL(request.url).origin === "https://api.apple-cloudkit.com"
    ? f.model.fetch(request, context) : f.configuration.fetchImplementation(request, context) };
  const direct = createGatewayHTTPHandler(deps), authority = runtime ? createGatewayRuntime(f.storage, env, runtimeOptions) : { handle: direct };
  const forwarded = [], objectID = { toString: () => "synthetic-review-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { assert.equal(name, authorityName); return objectID; }, get(id) {
    assert.equal(id, objectID); return { fetch(request) { forwarded.push(request); return handleAuthorityRequest(request, { runtime: authority, env, objectID, clock: f.clock }); } };
  } };
  const body = (action, changes = {}) => ({ ...({ queue: {}, inspect: { accountID: f.signedIn.accountID, requestID: f.pending.requestID }, decide: {} }[action]), ...changes });
  const request = (action, changes = {}, options = {}) => {
    const raw = options.rawBody ?? JSON.stringify(body(action, changes));
    return new Request("https://echoes-authority.internal/v1/moderation/avatar/" + action, { method: options.method ?? "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + (options.token ?? f.reviewer.sessionToken), ...options.headers }, body: raw,
      ...(raw instanceof ReadableStream ? { duplex: "half" } : {}), ...(options.signal ? { signal: options.signal } : {}) });
  };
  return { ...f, env, runtimeOptions, authority, dependencies: deps, limits, forwarded, request, body,
    call(action, changes = {}, options = {}) { prepared = false; return authority.handle(request(action, changes, options), options.budget ?? "d".repeat(64)); },
    edge(action, changes = {}, options = {}) {
      const r = request(action, changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(r, env, { clock: f.clock });
    },
    setEnabled(v) { enabled = v; }, setFeature(v) { feature = v; }, afterLastAdvance(fn) { afterAdvance = fn; },
    counts() { return { ...counts }; } };
}
