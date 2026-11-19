import { randomBytes, randomUUID, generateKeyPairSync } from "node:crypto";
import { avatarReportFixture } from "./avatar-report-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";

export async function photoReportHTTPFixture(t, { runtime = false, settings = {} } = {}) {
  const f = await avatarReportFixture(); t.after(() => f.close());
  const limits = new GatewayLimits(f.storage, { clock: f.clock });
  let feature = true, readable = true, cancellable = false, prepared = false, afterAdvance;
  const counts = { network: 0, account: 0, scheduled: 0, verifies: 0 };
  const actor = Object.fromEntries(["prepareSubmit", "prepareRecovery", "prepareCancellation"].map(method => [method, async input => {
    const final = await f.reports[method](input); prepared = true; return final;
  }]));
  const deps = { authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
    limits: { async consume(...args) { counts.network++; return limits.consume(...args); },
      async consumeAvatarReport(...args) { counts.account++; return limits.consumeAvatarReport(...args); } },
    checkpoint: { async verify(...args) { counts.verifies++; return f.checkpoint.verify(...args); },
      async advance(...args) { await f.checkpoint.advance(...args); if (prepared) await afterAdvance?.(); } },
    avatarReports: { ...actor, waitForPendingOperations: () => f.reports.waitForPendingOperations() },
    isEnabled: () => true, isAvatarReportEnabled: () => feature, isAvatarReportCancelEnabled: () => cancellable, isAvatarReadEnabled: () => readable,
    scheduleMaintenance: async () => { counts.scheduled++; }, clock: f.clock, ...settings };
  Object.assign(f.storage, { async getAlarm() { return null; }, async setAlarm() {}, async deleteAlarm() {} });
  const secret = () => randomBytes(32).toString("base64url");
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(f.clock() + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_REPORT_ENABLED: "1", AVATAR_READ_ENABLED: "1",
    AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", ...syntheticPublicKeyConfiguration(),
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const runtimeOptions = { clock: f.clock, fetchImplementation: (...args) => f.model.fetch(...args) };
  const authority = runtime ? createGatewayRuntime(f.storage, env, runtimeOptions) : { handle: createGatewayHTTPHandler(deps) };
  const forwarded = [], id = { toString: () => "synthetic-photo-report-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw Error("Wrong synthetic authority"); return id; }, get(object) {
    if (object !== id) throw Error("Wrong synthetic object"); return { fetch(req) { forwarded.push(req); return handleAuthorityRequest(req, { runtime: authority, env, objectID: id, clock: f.clock }); } };
  } };
  const body = (action, changes = {}) => ({ ...(action === "submit" ? { requestID: randomUUID(), ownerID: f.signedIn.accountID, versionID: f.photo.versionID,
    reason: "PRIVATE_SYNTHETIC_PHOTO_REASON", coordinate: f.coordinate } : { requestID: randomUUID() }), ...changes });
  const request = (action, changes = {}, options = {}) => {
    const raw = options.rawBody ?? JSON.stringify(body(action, changes));
    return new Request("https://echoes-authority.internal/v1/community/avatar/report" + (action === "submit" ? "" : "/" + action), { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + (options.token ?? f.viewer.sessionToken), ...options.headers }, body: raw,
      ...(raw instanceof ReadableStream ? { duplex: "half" } : {}), ...(options.signal ? { signal: options.signal } : {}) });
  };
  return { ...f, env, deps, limits, authority, runtimeOptions, forwarded, body, request,
    call(action, changes = {}, options = {}) { prepared = false; return authority.handle(request(action, changes, options), options.budget ?? "c".repeat(64)); },
    edge(action, changes = {}, options = {}) {
      const req = request(action, changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(req, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(req, env, { clock: f.clock });
    },
    setCancellable(value) { cancellable = value; f.setReportsCancellable(value); env.AVATAR_REPORT_CANCEL_ENABLED = value ? "1" : "0"; },
    setFeature(value) { feature = value; }, setReadable(value) { readable = value; }, afterLastAdvance(fn) { afterAdvance = fn; }, counts: () => ({ ...counts }) };
}
