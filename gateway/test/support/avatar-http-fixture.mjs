import { generateKeyPairSync, randomBytes } from "node:crypto";
import { avatarReadFixture } from "./avatar-read-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { avatarReadPath } from "../../src/gateway-avatar-http.mjs";

export async function avatarHTTPFixture({ runtime = false, ...settings } = {}) {
  const f = await avatarReadFixture(), limits = new GatewayLimits(f.storage, { clock: f.clock });
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(f.clock() + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_READ_ENABLED: "1",
    AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: randomBytes(32).toString("base64url") }),
    RENEWAL_KEYS_JSON: JSON.stringify({ v1: randomBytes(32).toString("base64url") }), REQUEST_BUDGET_KEY: randomBytes(32).toString("base64url"), ...syntheticPublicKeyConfiguration() };
  let enabled = true, feature = true, prepared = false, lastAdvance, requestCount = 0, verifies = 0, reads = 0, accountLimits = 0, runtimeDownloads = 0;
  const provider = async (request, options) => {
    if (new URL(request.url).origin === "https://api.apple-cloudkit.com") return f.model.fetch(request, options);
    if (new URL(request.url).hostname !== "synthetic-avatar.icloud-content.com") throw new Error("Unexpected synthetic host");
    runtimeDownloads++;
    const bytes = f.uploadedBytes.get(new URL(request.url).pathname.slice("/private/".length));
    if (!bytes) throw new Error("Synthetic asset missing");
    return new Response(bytes.slice(), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length) } });
  };
  f.storage.getAlarm = async () => null; f.storage.setAlarm = async () => {}; f.storage.deleteAlarm = async () => {};
  const dependencies = {
    authentication: f.state, login: { login() { throw new Error("Not used by read proof"); } }, renewal: { renew() {} }, sessionReset: { reset() {} },
    limits: {
      async consume(...args) { requestCount++; return limits.consume(...args); },
      async consumeAvatarRead(...args) { accountLimits++; return limits.consumeAvatarRead(...args); }
    },
    checkpoint: {
      async verify(options) { verifies++; return f.checkpoint.verify(options); },
      async advance(options) { const result = await f.checkpoint.advance(options); if (prepared) await lastAdvance?.(); return result; }
    },
    avatarReader: { async prepare(input) { reads++; const finalize = await f.reader.prepare(input); prepared = true; return finalize; } },
    isAvatarReadEnabled: () => feature, isEnabled: () => enabled, scheduleMaintenance: async () => {}, ...settings
  };
  const direct = createGatewayHTTPHandler(dependencies);
  const authority = runtime ? createGatewayRuntime(f.storage, env, { clock: f.clock, fetchImplementation: provider }) : { handle: direct };
  const id = { toString: () => "synthetic-avatar-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw new Error("Wrong authority"); return id; },
    get(object) { if (object !== id) throw new Error("Wrong object"); return { fetch: request => handleAuthorityRequest(request, { runtime: authority, env, objectID: id, clock: f.clock }) }; } };
  const body = (changes = {}) => ({ ownerID: f.signedIn.accountID, versionID: f.photo.versionID, variant: "thumbnail", coordinate: f.coordinate, ...changes });
  const request = (changes = {}, options = {}) => {
    const headers = { "Content-Type": "application/json", Authorization: "Bearer " + (options.token ?? f.viewer.sessionToken), ...options.headers };
    return new Request("https://echoes-authority.internal" + avatarReadPath, { method: "POST", headers,
      body: options.rawBody ?? JSON.stringify(body(changes)), ...(options.signal ? { signal: options.signal } : {}),
      ...(options.rawBody instanceof ReadableStream ? { duplex: "half" } : {}) });
  };
  return { ...f, env, limits, dependencies, authority, provider, body, request,
    call(changes, options = {}) { return authority.handle(request(changes, options), options.budget ?? "a".repeat(64)); },
    edge(changes = {}, options = {}) {
      const r = request(changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(r, env, { clock: f.clock });
    },
    setEnabled(v) { enabled = v; }, setFeature(v) { feature = v; }, afterLastAdvance(fn) { lastAdvance = fn; },
    counts() { return { requestCount, verifies, reads, accountLimits, runtimeDownloads }; }
  };
}
