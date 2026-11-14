import { AuthenticationStateError } from "./authentication-state.mjs";
import { GatewayLimitError } from "./gateway-limits.mjs";

export const gatewayPaths = new Set(["/v1/auth/challenge", "/v1/auth/login", "/v1/auth/renew", "/v1/auth/session",
  "/v1/auth/logout", "/v1/auth/logout-all", "/v1/account/deletion", "/v1/account/deletion/status", "/v1/account/deletion/private-cleanup"]);
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function gatewayJSON(value, status = 200, extra = {}) {
  return Response.json({ protocolVersion: 1, ...value }, { status, headers: {
    "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff", ...extra,
  } });
}
export class GatewayHTTPError extends Error {
  constructor(code = "INVALID_REQUEST", status = 400) { super("Gateway request could not be processed."); this.code = code; this.status = status; }
}
export function gatewayFailure(error) {
  if (error instanceof GatewayHTTPError) return gatewayJSON({ error: error.code }, error.status, error.status === 405 ? { Allow: "POST" } : {});
  if (error instanceof GatewayLimitError) return gatewayJSON({ error: error.code }, error.code === "RATE_LIMITED" ? 429 : 503,
    { "Retry-After": String(error.retryAfterSeconds) });
  if (error instanceof AuthenticationStateError) {
    const map = {
      INVALID_IDENTITY: [401], INVALID_CHALLENGE: [401], INVALID_SESSION: [401], REAUTH_REQUIRED: [401], NO_ACCOUNT: [404],
      ACCOUNT_DISABLED: [403], DELETION_IN_PROGRESS: [403], ISSUE_LIMITED: [429, 300], SESSION_LIMITED: [409],
      RENEWAL_BUSY: [409, 5], CREDENTIAL_LIMITED: [503, 60],
    };
    const [status, retry] = map[error.code] ?? [503, 30];
    return gatewayJSON({ error: error.code }, status, retry ? { "Retry-After": String(retry) } : {});
  }
  return gatewayJSON({ error: "UNAVAILABLE" }, 503, { "Retry-After": "30" });
}
export function inspectGatewayRequest(request) {
  const url = new URL(request.url);
  if (url.search || url.hash || url.username || url.password) throw new GatewayHTTPError();
  if (url.protocol !== "https:") throw new GatewayHTTPError("HTTPS_REQUIRED", 400);
  if (url.pathname === "/health" && request.method === "GET") return { path: "/health" };
  if (!gatewayPaths.has(url.pathname)) throw new GatewayHTTPError("NOT_FOUND", 404);
  if (request.method !== "POST") throw new GatewayHTTPError("METHOD_NOT_ALLOWED", 405);
  if (request.headers.has("Origin") || (request.headers.has("Sec-Fetch-Site") && request.headers.get("Sec-Fetch-Site") !== "none")) {
    throw new GatewayHTTPError("ORIGIN_NOT_ALLOWED", 403);
  }
  return { path: url.pathname };
}
function fields(value, required, optional = []) {
  if (!value || typeof value !== "object" || Array.isArray(value) || required.some(key => !Object.hasOwn(value, key)) ||
      Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) throw new GatewayHTTPError();
}
function uuidField(value) { if (typeof value !== "string" || !uuid.test(value)) throw new GatewayHTTPError(); }
function opaqueField(value, maximum) {
  if (typeof value !== "string" || value.length > maximum || !/^[\x21-\x7e]+$/.test(value)) throw new GatewayHTTPError();
}
function bearer(request, maximum) {
  const header = request.headers.get("Authorization");
  if (typeof header !== "string" || header.length > maximum + 7 || !/^Bearer [\x21-\x7e]+$/.test(header)) throw new GatewayHTTPError("INVALID_SESSION", 401);
  return header.slice(7);
}
async function objectBody(request, maximum, timeout) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get("Content-Type") ?? "") ||
      (request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity")) throw new GatewayHTTPError("UNSUPPORTED_MEDIA_TYPE", 415);
  const length = request.headers.get("Content-Length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > maximum)) throw new GatewayHTTPError("BODY_TOO_LARGE", 413);
  if (!request.body) throw new GatewayHTTPError();
  const reader = request.body.getReader(); let timer, total = 0; const chunks = [];
  const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new GatewayHTTPError("REQUEST_TIMEOUT", 408)), timeout); });
  try {
    while (true) {
      const { value, done } = await Promise.race([reader.read(), deadline]);
      if (done) break; total += value.byteLength;
      if (total > maximum) throw new GatewayHTTPError("BODY_TOO_LARGE", 413);
      chunks.push(value);
    }
    const bytes = new Uint8Array(total); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    fields(body, [], Object.keys(body ?? {})); return body;
  } catch (error) { throw error instanceof GatewayHTTPError ? error : new GatewayHTTPError(); }
  finally {
    clearTimeout(timer); void reader.cancel().catch(() => {});
    try { reader.releaseLock(); } catch { /* Input cancellation must not change the public error. */ }
  }
}
function sessionResponse(value) {
  if (!value || typeof value.sessionToken !== "string" || value.sessionToken.length !== 80 ||
      !uuid.test(value.sessionToken.slice(0, 36)) || !/^\.[A-Za-z0-9_-]{43}$/.test(value.sessionToken.slice(36)) ||
      typeof value.renewalToken !== "string" || value.renewalToken.length > 120 ||
      !/^[a-f0-9-]{36}\.[A-Za-z0-9_-]{1,16}\.[0-9]{1,10}\.[A-Za-z0-9_-]{43}$/.test(value.renewalToken) ||
      !Number.isSafeInteger(value.expiresAt) || value.expiresAt <= 0 ||
      !Number.isSafeInteger(value.renewalExpiresAt) || value.renewalExpiresAt < value.expiresAt) throw new Error();
  if (typeof value.accountID !== "string" || !uuid.test(value.accountID)) throw new Error();
  return gatewayJSON({ sessionToken: value.sessionToken, renewalToken: value.renewalToken,
    accountID: value.accountID, expiresAt: value.expiresAt, renewalExpiresAt: value.renewalExpiresAt });
}
function deletionResponse(value, status = 200) {
  if (typeof value?.deletionID !== "string" || !uuid.test(value.deletionID)) throw new Error();
  if (!["pending", "draining", "deleted"].includes(value.publicData) ||
      !["awaiting-device", "device-acknowledged"].includes(value.privateData) ||
      !["pending", "retained-tokens-processed", "manual-required"].includes(value.appleAuthorization) ||
      !["blocked", "removed"].includes(value.localAccount) || typeof value.attentionRequired !== "boolean" || typeof value.completed !== "boolean") throw new Error();
  return gatewayJSON({ deletionID: value.deletionID, publicData: value.publicData, privateData: value.privateData,
    appleAuthorization: value.appleAuthorization, localAccount: value.localAccount,
    attentionRequired: value.attentionRequired, completed: value.completed }, status);
}

/** Closed native API. serverBudgetHash is supplied by the trusted edge/authority, never taken from JSON. */
export function createGatewayHTTPHandler({ authentication, login, renewal, deletions, deletionCoordinator,
  deletionEnabled = false, limits, scheduleMaintenance, isEnabled, inputTimeoutMilliseconds = 3000 } = {}) {
  if (typeof authentication?.issueChallenge !== "function" || typeof login?.login !== "function" || typeof renewal?.renew !== "function" ||
      typeof limits?.consume !== "function" || typeof scheduleMaintenance !== "function" || typeof isEnabled !== "function" ||
      typeof deletionEnabled !== "boolean" || !Number.isInteger(inputTimeoutMilliseconds) || inputTimeoutMilliseconds < 1 || inputTimeoutMilliseconds > 3000 ||
      (deletionEnabled && (typeof deletions?.status !== "function" || typeof deletionCoordinator?.request !== "function"))) throw new Error("Gateway dependencies are unavailable.");
  return async (request, serverBudgetHash) => {
    try {
      const { path } = inspectGatewayRequest(request);
      if (path === "/health") return gatewayJSON({ status: "ok", mode: "development-gateway" });
      if (isEnabled() !== true) return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503);
      const heavy = ["/v1/auth/login", "/v1/auth/renew", "/v1/account/deletion"].includes(path);
      await limits.consume(serverBudgetHash, { heavy });
      const body = await objectBody(request, heavy ? 16384 : 256, inputTimeoutMilliseconds);
      if (path.startsWith("/v1/account/") && !deletionEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      if (path === "/v1/auth/challenge") {
        fields(body, ["purpose"]);
        if (!["login", "account_deletion"].includes(body.purpose)) throw new GatewayHTTPError();
        if (body.purpose === "account_deletion" && !deletionEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
        await scheduleMaintenance();
        const value = await authentication.issueChallenge(serverBudgetHash, { purpose: body.purpose });
        if (typeof value.challengeID !== "string" || !uuid.test(value.challengeID) ||
            typeof value.nonce !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value.nonce) || !Number.isSafeInteger(value.expiresAt)) throw new Error();
        return gatewayJSON({ challengeID: value.challengeID, nonce: value.nonce, expiresAt: value.expiresAt });
      }
      if (path === "/v1/auth/login") {
        fields(body, ["challengeID", "identityToken", "authorizationCode"]); uuidField(body.challengeID);
        opaqueField(body.identityToken, 12288); opaqueField(body.authorizationCode, 2048);
        await scheduleMaintenance(); return sessionResponse(await login.login(body));
      }
      if (path === "/v1/auth/renew") {
        fields(body, []); const token = bearer(request, 120);
        await scheduleMaintenance(); return sessionResponse(await renewal.renew(token));
      }
      if (path === "/v1/auth/session") {
        fields(body, []); const value = authentication.authorize(bearer(request, 80));
        return gatewayJSON({ accountID: value.accountID, expiresAt: value.expiresAt });
      }
      if (path === "/v1/auth/logout" || path === "/v1/auth/logout-all") {
        fields(body, []); const token = bearer(request, path.endsWith("-all") ? 80 : 120); await scheduleMaintenance();
        if (path.endsWith("-all")) await authentication.revokeAllSessions(token);
        else try { await authentication.revokeRenewal(token); } catch (error) {
          if (!(error instanceof AuthenticationStateError && error.code === "INVALID_SESSION")) throw error;
        }
        return new Response(null, { status: 204, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
      }
      fields(body, ["deletionID"], path === "/v1/account/deletion" ? ["challengeID", "identityToken", "expectedAccountID"] : []);
      uuidField(body.deletionID); const statusToken = bearer(request, 80);
      if (statusToken.length !== 80 || statusToken.slice(0, 37) !== body.deletionID + "." ||
          !/^[A-Za-z0-9_-]{43}$/.test(statusToken.slice(37))) throw new GatewayHTTPError("INVALID_SESSION", 401);
      if (path === "/v1/account/deletion" && Object.keys(body).length > 1) {
        uuidField(body.challengeID); opaqueField(body.identityToken, 12288);
        if (body.expectedAccountID !== undefined) uuidField(body.expectedAccountID);
      }
      await scheduleMaintenance();
      if (path === "/v1/account/deletion") return deletionResponse(await deletionCoordinator.request({ ...body, statusToken }), 202);
      if (path.endsWith("/private-cleanup")) return deletionResponse(await deletions.acknowledgePrivateCleanup({ ...body, statusToken }));
      return deletionResponse(deletions.status({ ...body, statusToken }));
    } catch (error) { return gatewayFailure(error); }
  };
}
