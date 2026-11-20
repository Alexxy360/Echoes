import assert from "node:assert/strict";
import { randomBytes, generateKeyPairSync } from "node:crypto";
import { avatarReportReviewFixture } from "./avatar-report-review-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";

export async function avatarReportReviewHTTPFixture(t, { runtime = false, settings = {}, ...options } = {}) {
  const f = await avatarReportReviewFixture(t, options), limits = new GatewayLimits(f.storage, { clock: f.clock });
  let enabled = true, feature = true, prepared = false, afterAdvance;
  const counts = { networkLimits: 0, accountLimits: 0, scheduled: 0, verifies: 0 };
  const methods = Object.fromEntries(["prepareQueue", "prepareInspection", "prepareDecision", "prepareRecovery"].map(method => [method, async input => {
    const final = await f.review[method](input); prepared = true; return final;
  }]));
  const deps = { authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
    limits: { async consume(...args) { counts.networkLimits++; return limits.consume(...args); },
      async consumeAvatarReportReview(...args) { counts.accountLimits++; return limits.consumeAvatarReportReview(...args); } },
    checkpoint: { async verify(...args) { counts.verifies++; return f.checkpoint.verify(...args); },
      async advance(...args) { await f.checkpoint.advance(...args); if (prepared) await afterAdvance?.(); } },
    avatarReportReview: { ...methods, waitForPendingOperations: () => f.review.waitForPendingOperations() },
    isEnabled: () => enabled, isAvatarReportReviewEnabled: () => feature, isAvatarReportReviewer: id => feature && f.reviewConfiguration.isOperator(id),
    scheduleMaintenance: async () => { counts.scheduled++; }, clock: f.clock, ...settings };
  Object.assign(f.storage, { async getAlarm() { return null; }, async setAlarm() {}, async deleteAlarm() {} });
  const secret = () => randomBytes(32).toString("base64url");
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(f.clock() + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_REPORT_REVIEW_ENABLED: "1", AVATAR_REPORT_REVIEWER_IDS_JSON: JSON.stringify([f.operator.accountID]), AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]',
    CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", ...syntheticPublicKeyConfiguration(),
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const runtimeOptions = { clock: f.clock, fetchImplementation: (request, ...args) => new URL(request.url).origin === "https://api.apple-cloudkit.com" ? f.model.fetch(request, ...args) : f.configuration.fetchImplementation(request, ...args) };
  const authority = runtime ? createGatewayRuntime(f.storage, env, runtimeOptions) : { handle: createGatewayHTTPHandler(deps) };
  const forwarded = [], objectID = { toString: () => "synthetic-report-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { assert.equal(name, authorityName); return objectID; }, get(id) {
    assert.equal(id, objectID); return { fetch(request) { forwarded.push(request); return handleAuthorityRequest(request, { runtime: authority, env, objectID, clock: f.clock }); } };
  } };
  const body = (action, changes = {}) => ({ ...({ queue: { after: null }, inspect: { reportID: f.report.context.recordName }, decide: {}, recover: {} }[action]), ...changes });
  const request = (action, changes = {}, options = {}) => {
    const raw = options.rawBody ?? JSON.stringify(body(action, changes));
    return new Request("https://echoes-authority.internal/v1/moderation/avatar-reports/" + action, { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + (options.token ?? f.operator.sessionToken), ...options.headers }, body: raw,
      ...(raw instanceof ReadableStream ? { duplex: "half" } : {}), ...(options.signal ? { signal: options.signal } : {}) });
  };
  return { ...f, env, deps, limits, authority, runtimeOptions, forwarded, body, request,
    call(action, changes = {}, options = {}) { prepared = false; return authority.handle(request(action, changes, options), options.budget ?? "d".repeat(64)); },
    edge(action, changes = {}, options = {}) {
      const req = request(action, changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(req, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(req, env, { clock: f.clock });
    },
    setEnabled(value) { enabled = value; }, setFeature(value) { feature = value; }, afterLastAdvance(fn) { afterAdvance = fn; }, counts: () => ({ ...counts }),
  };
}
