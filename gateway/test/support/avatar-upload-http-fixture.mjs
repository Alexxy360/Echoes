import assert from "node:assert/strict";
import { createHash, createPublicKey, generateKeyPairSync, randomBytes, randomUUID, verify } from "node:crypto";
import { avatarPublicationFixture } from "./avatar-publication-fixture.mjs";
import { avatarCodecs } from "./avatar-image-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./public-record-fixture.mjs";
import { AvatarNormalizer } from "../../src/avatar-normalizer.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { avatarIntentHeader } from "../../src/avatar-upload-http.mjs";

export async function avatarUploadHTTPFixture({ runtime = false, readEnabled = false, ...settings } = {}) {
  const f = await avatarPublicationFixture(), limits = new GatewayLimits(f.storage, { clock: f.clock }), modules = await avatarCodecs();
  const key = syntheticPublicKeyConfiguration(), grants = new Map(), transfers = [], forwarded = [];
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(f.clock() + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_UPLOAD_ENABLED: "1",
    AVATAR_UPLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
    AVATAR_READ_ENABLED: readEnabled ? "1" : "0", AVATAR_DOWNLOAD_HOSTS_JSON: readEnabled ? '["synthetic-avatar.icloud-content.com"]' : "[]",
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" }),
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: randomBytes(32).toString("base64url") }),
    RENEWAL_KEYS_JSON: JSON.stringify({ v1: randomBytes(32).toString("base64url") }), REQUEST_BUDGET_KEY: randomBytes(32).toString("base64url"), ...key };
  let enabled = true, feature = true, prepared = false, lastAdvance, assetHook, budgets = 0, accountLimits = 0, verifies = 0;
  const provider = async (request, options) => {
    const url = new URL(request.url);
    if (url.origin === "https://api.apple-cloudkit.com" && !url.pathname.endsWith("/assets/upload")) return f.model.fetch(request, options);
    let payload, phase;
    if (url.origin === "https://api.apple-cloudkit.com") {
      phase = "grant"; const raw = await request.clone().text(), body = JSON.parse(raw);
      const signed = `${request.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${createHash("sha256").update(raw).digest("base64")}:${url.pathname}`;
      assert.equal(verify("sha256", Buffer.from(signed), createPublicKey(key.CLOUDKIT_PRIVATE_KEY), Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64")), true);
      assert.equal(body.tokens.length, 1); const token = body.tokens[0];
      const target = "https://synthetic-avatar.icloud-content.com/upload/" + token.recordName + "/" + token.fieldName;
      grants.set(target, token); payload = { tokens: [{ recordName: token.recordName, fieldName: token.fieldName, url: target }] };
    } else {
      phase = "upload"; assert.equal(url.hostname, "synthetic-avatar.icloud-content.com");
      const token = grants.get(request.url); assert.ok(token);
      const bytes = new Uint8Array(await request.clone().arrayBuffer());
      f.uploadedBytes.set(token.recordName + "/" + token.fieldName, bytes);
      payload = { singleFile: { fileChecksum: "SYNTHETIC-CHECKSUM-" + createHash("sha256").update(bytes).digest("hex"), size: bytes.length, receipt: "SYNTHETIC-PRIVATE-" + token.fieldName } };
    }
    const call = { phase, request, signal: options.signal }; transfers.push(call);
    return await assetHook?.(call) ?? Response.json(payload);
  };
  f.storage.getAlarm = async () => null; f.storage.setAlarm = async () => {}; f.storage.deleteAlarm = async () => {};
  const dependencies = { authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
    limits: { async consume(...args) { budgets++; return limits.consume(...args); },
      async consumeAvatarMutation(...args) { accountLimits++; return limits.consumeAvatarMutation(...args); } },
    checkpoint: { async verify(options) { verifies++; return f.checkpoint.verify(options); },
      async advance(options) { await f.checkpoint.advance(options); if (prepared) await lastAdvance?.(); } },
    avatarPublication: Object.fromEntries(["prepareUpload", "prepareStatus", "prepareRecovery", "preparePublish", "prepareClear"].map(name => [name, async input => {
      const result = await f.coordinator[name](input); prepared = true; return result;
    }])), isAvatarUploadEnabled: () => feature, isEnabled: () => enabled, scheduleMaintenance: async () => {}, ...settings };
  const runtimeOptions = { clock: f.clock, fetchImplementation: provider, avatarNormalizerFactory: isEnabled => new AvatarNormalizer({ ...modules, isEnabled }) };
  const direct = createGatewayHTTPHandler(dependencies), authority = runtime ? createGatewayRuntime(f.storage, env, runtimeOptions) : { handle: direct };
  const objectID = { toString: () => "synthetic-avatar-upload-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { assert.equal(name, authorityName); return objectID; }, get(value) {
    assert.equal(value, objectID); return { fetch(request) { forwarded.push(request); return handleAuthorityRequest(request, { runtime: authority, env, objectID, clock: f.clock }); } };
  } };
  const body = (action, changes = {}) => {
    const state = f.policy.snapshot(f.signedIn.accountID), requestID = state.requestID ?? randomUUID();
    return { ...({ upload: { requestID: randomUUID(), versionID: randomUUID(), expectedGeneration: state.generation, consentVersion: 1 },
      clear: { requestID: randomUUID(), expectedGeneration: state.generation }, recover: { requestID }, publish: { requestID }, status: {} }[action]), ...changes };
  };
  const request = (action, changes = {}, options = {}) => {
    const value = body(action, changes), upload = action === "upload";
    const headers = { "Content-Type": upload ? "image/jpeg" : "application/json", Authorization: "Bearer " + (options.token ?? f.signedIn.sessionToken),
      ...(upload ? { [avatarIntentHeader]: JSON.stringify(value) } : {}), ...options.headers };
    const raw = options.rawBody ?? (upload ? f.sourceBytes.slice() : JSON.stringify(value));
    return new Request("https://echoes-authority.internal/v1/community/avatar/" + action, { method: "POST", headers, body: raw,
      ...(raw instanceof ReadableStream ? { duplex: "half" } : {}), ...(options.signal ? { signal: options.signal } : {}) });
  };
  return { ...f, env, limits, dependencies, authority, runtimeOptions, provider, transfers, forwarded, body, request,
    call(action, changes = {}, options = {}) { prepared = false; return authority.handle(request(action, changes, options), options.budget ?? "a".repeat(64)); },
    edge(action, changes = {}, options = {}) { const r = request(action, changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(r, env, { clock: f.clock }); },
    setEnabled(v) { enabled = v; }, setFeature(v) { feature = v; }, afterLastAdvance(fn) { lastAdvance = fn; },
    onAsset(fn) { assetHook = fn; }, counts() { return { budgets, accountLimits, verifies }; } };
}
