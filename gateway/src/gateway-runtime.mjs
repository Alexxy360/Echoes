import { AppleClientSecret, AppleOAuthClient } from "./apple-oauth.mjs";
import { ApplePublicKeySource, base64URLBytes } from "./apple-public-keys.mjs";
import { AppleIdentityTokenVerifier } from "./apple-identity.mjs";
import { AuthenticationState } from "./authentication-state.mjs";
import { AppleLoginCoordinator } from "./apple-login.mjs";
import { RefreshCredentialVault } from "./refresh-credential-vault.mjs";
import { RenewalProofs } from "./renewal-proofs.mjs";
import { SessionRenewalCoordinator } from "./session-renewal.mjs";
import { AccountDeletionState } from "./account-deletion-state.mjs";
import { AccountDeletionCoordinator, AccountDeletionProcessor } from "./account-deletion.mjs";
import { GatewayLimits, edgeBudgetHash } from "./gateway-limits.mjs";
import { GatewayMaintenance } from "./gateway-maintenance.mjs";
import { createGatewayHTTPHandler, inspectGatewayRequest, gatewayFailure, gatewayJSON } from "./gateway-http.mjs";

export const authorityName = "echoes-auth-authority-development-v1";
export function activeGatewayConfiguration(env, now = Date.now()) {
  if (!Number.isSafeInteger(now) || now < 0 || env.GATEWAY_ENABLED !== "1" || env.GATEWAY_ENVIRONMENT !== "development" ||
      env.CLOUDKIT_CONTAINER !== "iCloud.mpvEcho.Echo" || env.CLOUDKIT_ENVIRONMENT !== "development" ||
      !["0", "1"].includes(env.ACCOUNT_DELETION_ENABLED) ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(env.GATEWAY_EXPIRES_AT ?? "")) return null;
  const deadline = Date.parse(env.GATEWAY_EXPIRES_AT);
  if (!Number.isSafeInteger(deadline) || deadline <= now || deadline > now + 7 * 86400000) return null;
  const canonical = new Date(deadline).toISOString();
  if (env.GATEWAY_EXPIRES_AT !== canonical && env.GATEWAY_EXPIRES_AT !== canonical.replace(".000Z", "Z")) return null;
  return Object.freeze({ deadline, deletionEnabled: env.ACCOUNT_DELETION_ENABLED === "1" });
}
function keyMap(json) {
  if (typeof json !== "string" || json.length > 2048) throw new Error();
  const value = JSON.parse(json);
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length < 1 || Object.keys(value).length > 3) throw new Error();
  return value;
}

/** Concrete composition for the Development target. No fake Apple exchange, key or data-erasure fallback. */
export function createGatewayRuntime(storage, env, { clock = Date.now, fetchImplementation = (request, options) => fetch(request, options), erasePublicDataBatch } = {}) {
  try {
    const config = activeGatewayConfiguration(env, clock());
    if (!config || (config.deletionEnabled && typeof erasePublicDataBatch !== "function")) throw new Error();
    const refreshKeys = keyMap(env.REFRESH_KEYS_JSON), renewalKeys = keyMap(env.RENEWAL_KEYS_JSON);
    const allSecrets = [...Object.values(refreshKeys), ...Object.values(renewalKeys), env.REQUEST_BUDGET_KEY];
    if (new Set(allSecrets).size !== allSecrets.length || allSecrets.some(value => base64URLBytes(value, 32).length !== 32) ||
        (env.CLOUDKIT_PRIVATE_KEY !== undefined && env.CLOUDKIT_PRIVATE_KEY === env.APPLE_SIGNIN_PRIVATE_KEY)) throw new Error();
    const credentialVault = new RefreshCredentialVault({ activeKeyID: env.REFRESH_ACTIVE_KEY_ID, keys: refreshKeys });
    const renewalProofs = new RenewalProofs({ activeKeyID: env.RENEWAL_ACTIVE_KEY_ID, keys: renewalKeys });
    const clientSecret = new AppleClientSecret({ privateKeyPEM: env.APPLE_SIGNIN_PRIVATE_KEY, keyID: env.APPLE_SIGNIN_KEY_ID, clock });
    const guardedFetch = (...args) => {
      if (!activeGatewayConfiguration(env, clock())) throw new Error("Gateway is inactive.");
      return fetchImplementation(...args);
    };
    const apple = new AppleOAuthClient({ clientSecret, fetchImplementation: guardedFetch });
    const verifier = new AppleIdentityTokenVerifier({ keySource: new ApplePublicKeySource({ clock, fetchImplementation: guardedFetch }), clock });
    const authentication = new AuthenticationState(storage, { clock, renewalProofs });
    const limits = new GatewayLimits(storage, { clock });
    const deletions = new AccountDeletionState(storage, { clock });
    const maintenance = new GatewayMaintenance(storage, { clock, limits, deletions });
    const login = new AppleLoginCoordinator({ state: authentication, verifier, credentialVault,
      exchangeAuthorizationCode: input => apple.exchangeAuthorizationCode(input) });
    const renewal = new SessionRenewalCoordinator({ state: authentication, verifier, credentialVault, appleClient: apple });
    const deletionCoordinator = new AccountDeletionCoordinator({ authenticationState: authentication, deletionState: deletions, verifier });
    const processor = config.deletionEnabled ? new AccountDeletionProcessor({ deletionState: deletions, credentialVault,
      appleClient: apple, erasePublicDataBatch }) : undefined;
    const handle = createGatewayHTTPHandler({ authentication, login, renewal, deletions, deletionCoordinator,
      deletionEnabled: config.deletionEnabled, limits, scheduleMaintenance: () => maintenance.schedule(),
      isEnabled: () => activeGatewayConfiguration(env, clock()) !== null });
    return Object.freeze({ handle, maintenance, processor });
  } catch { throw new Error("Gateway configuration is unavailable."); }
}

/** Local retention remains callable after activation expires or provider secrets have been removed. */
export function createGatewayLocalMaintenance(storage, { clock = Date.now } = {}) {
  const limits = new GatewayLimits(storage, { clock }), deletions = new AccountDeletionState(storage, { clock });
  return new GatewayMaintenance(storage, { clock, limits, deletions });
}

export function handleAuthorityRequest(request, { runtime, env, objectID, clock = Date.now } = {}) {
  try {
    if (!activeGatewayConfiguration(env, clock()) || !runtime ||
        objectID.toString() !== env.COMMUNITY_AUTHORITY.idFromName(authorityName).toString() ||
        new URL(request.url).hostname !== "echoes-authority.internal" ||
        !/^[a-f0-9]{64}$/.test(request.headers.get("X-Echoes-Request-Budget") ?? "")) throw new Error();
    return runtime.handle(request, request.headers.get("X-Echoes-Request-Budget"));
  } catch { return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503); }
}

/** Thin public edge: only this boundary reads the platform client IP. All accounts use one private authority. */
export async function forwardGatewayRequest(request, env, { clock = Date.now } = {}) {
  try {
    const { path } = inspectGatewayRequest(request);
    if (path === "/health") return gatewayJSON({ status: "ok", mode: "development-gateway" });
    if (!activeGatewayConfiguration(env, clock())) return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503);
    if (!request.cf || typeof request.cf.colo !== "string" || !/^[A-Z]{3}$/.test(request.cf.colo)) throw new Error();
    const budget = edgeBudgetHash(request.headers.get("CF-Connecting-IP"), env.REQUEST_BUDGET_KEY, clock());
    const headers = new Headers();
    for (const name of ["Content-Type", "Content-Length", "Content-Encoding", "Authorization"]) {
      if (request.headers.has(name)) headers.set(name, request.headers.get(name));
    }
    headers.set("X-Echoes-Request-Budget", budget);
    const forwarded = new Request("https://echoes-authority.internal" + path, {
      method: request.method, headers, body: request.body, redirect: "manual", duplex: "half",
    });
    const id = env.COMMUNITY_AUTHORITY.idFromName(authorityName);
    const response = await env.COMMUNITY_AUTHORITY.get(id).fetch(forwarded);
    if (!(response instanceof Response) || ![200, 202, 204, 400, 401, 403, 404, 405, 408, 409, 413, 415, 429, 503].includes(response.status) ||
        (response.status !== 204 && !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? ""))) throw new Error();
    const safe = new Headers({ "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" });
    if (response.status !== 204) safe.set("Content-Type", "application/json");
    if (/^\d{1,6}$/.test(response.headers.get("Retry-After") ?? "")) safe.set("Retry-After", response.headers.get("Retry-After"));
    if (response.headers.get("Allow") === "POST") safe.set("Allow", "POST");
    return new Response(response.body, { status: response.status, headers: safe });
  } catch (error) { return gatewayFailure(error); }
}
