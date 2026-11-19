import { AuthenticationStateError } from "./authentication-state.mjs";
import { GatewayLimitError } from "./gateway-limits.mjs";
import { CommunityError } from "./community-domain.mjs";
import { PublicRecordError } from "./public-record-schema.mjs";
import { communityActions } from "./community-coordinator.mjs";
import { AvatarReadError } from "./cloudkit-avatar-reader.mjs";
import { avatarReadPath, avatarReadInputLimit, avatarReadBody, avatarHTTPDeadline } from "./gateway-avatar-http.mjs";
import { AvatarPolicyError } from "./avatar-policy-state.mjs";
import { AvatarIntakeError, avatarMutationPaths } from "./avatar-upload-http.mjs";
import { createAvatarUploadHandler } from "./gateway-avatar-upload.mjs";
import { AvatarReviewError } from "./avatar-review-state.mjs";
import { avatarReviewPaths } from "./avatar-review-http.mjs";
import { createAvatarReviewHandler } from "./gateway-avatar-review.mjs";
import { avatarOwnerPreviewPath } from "./avatar-owner-preview-http.mjs";
import { createAvatarOwnerPreviewHandler } from "./gateway-avatar-owner-preview.mjs";
import { CommunityReportReviewError } from "./community-report-review-state.mjs";
import { reportReviewPaths, reportReviewErrorStatuses } from "./report-review-http.mjs";
import { createReportReviewHandler } from "./gateway-report-review.mjs";

import { AvatarReportError } from "./avatar-report-domain.mjs";
import { avatarReportPaths, avatarReportErrorStatuses } from "./avatar-report-http.mjs";
import { createAvatarReportHandler } from "./gateway-avatar-report.mjs";

export const gatewayPaths = new Set(["/v1/auth/challenge", "/v1/auth/login", "/v1/auth/renew", "/v1/auth/session",
  "/v1/auth/logout", "/v1/auth/logout-all", "/v1/auth/session-reset", "/v1/account/deletion", "/v1/account/deletion/recover", "/v1/account/deletion/status", "/v1/account/deletion/private-cleanup"]);
for (const action of communityActions) gatewayPaths.add("/v1/community/" + action);
gatewayPaths.add(avatarReadPath);
gatewayPaths.add(avatarOwnerPreviewPath);
for (const path of [...avatarMutationPaths.keys(), ...avatarReviewPaths.keys(), ...reportReviewPaths.keys(), ...avatarReportPaths.keys()]) gatewayPaths.add(path);
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
  if (error instanceof AvatarReportError) {
    const status = avatarReportErrorStatuses[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof CommunityReportReviewError) {
    const status = reportReviewErrorStatuses[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof AvatarReviewError) {
    const status = { AVATAR_REVIEW_INPUT: 400, AVATAR_REVIEW_SCOPE: 403, AVATAR_REVIEW_STALE: 409, AVATAR_REVIEW_PENDING: 409,
      AVATAR_REVIEW_RATE: 429, AVATAR_REVIEW_CAPACITY: 429, AVATAR_REVIEW_RESPONSE: 503, AVATAR_REVIEW_UNAVAILABLE: 503 }[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof AvatarPolicyError || error instanceof AvatarIntakeError) {
    const status = { AVATAR_INPUT: 400, AVATAR_STALE: 409, AVATAR_PENDING: 409, AVATAR_REJECTED: 409,
      AVATAR_SCOPE: 403, AVATAR_RATE: 429, AVATAR_CAPACITY: 429, AVATAR_RESPONSE: 503, AVATAR_UNAVAILABLE: 503,
      BODY_TOO_LARGE: 413, UNSUPPORTED_MEDIA_TYPE: 415, INVALID_SESSION: 401, FEATURE_DISABLED: 503 }[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof AvatarReadError) {
    const status = { AVATAR_READ_INPUT: 400, AVATAR_READ_NOT_FOUND: 404, AVATAR_READ_STALE: 401,
      AVATAR_READ_LIMIT: 429, AVATAR_READ_RESPONSE: 503, AVATAR_READ_UNAVAILABLE: 503 }[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof CommunityError || error instanceof PublicRecordError) {
    const status = { COMMUNITY_INPUT: 400, COMMUNITY_STALE: 409, COMMUNITY_NOT_FOUND: 404, COMMUNITY_RATE_LIMITED: 429,
      COMMUNITY_CAPACITY: 429, COMMUNITY_TEXT_REJECTED: 400, COMMUNITY_CURSOR: 400,
      PUBLIC_INPUT: 400, PUBLIC_CONFLICT: 409, PUBLIC_PENDING: 409, PUBLIC_ERASED: 409, PUBLIC_LIMIT: 429, PUBLIC_THROTTLED: 503 }[error.code] ?? 503;
    return gatewayJSON({ error: error.code }, status, [429, 503].includes(status) ? { "Retry-After": "5" } : {});
  }
  if (error instanceof GatewayHTTPError) return gatewayJSON({ error: error.code }, error.status, error.status === 405 ? { Allow: "POST" } : {});
  if (error instanceof GatewayLimitError) return gatewayJSON({ error: error.code }, error.code === "RATE_LIMITED" ? 429 : 503,
    { "Retry-After": String(error.retryAfterSeconds) });
  if (error instanceof AuthenticationStateError) {
    const map = {
      INVALID_IDENTITY: [401], INVALID_CHALLENGE: [401], INVALID_SESSION: [401], REAUTH_REQUIRED: [401], NO_ACCOUNT: [404], NO_DELETION: [404],
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
async function objectBody(request, maximum, timeout, signal = request.signal) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get("Content-Type") ?? "") ||
      (request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity")) throw new GatewayHTTPError("UNSUPPORTED_MEDIA_TYPE", 415);
  const length = request.headers.get("Content-Length");
  if (length !== null && (!/^\d{1,7}$/.test(length) || Number(length) > maximum)) throw new GatewayHTTPError("BODY_TOO_LARGE", 413);
  if (!request.body) throw new GatewayHTTPError();
  const reader = request.body.getReader(); let timer, total = 0, reject; const chunks = [], started = Date.now();
  const cancelled = new Promise((_, fail) => { reject = fail; }); void cancelled.catch(() => {});
  const abort = () => reject(new GatewayHTTPError("REQUEST_TIMEOUT", 408));
  if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
  timer = setTimeout(abort, timeout);
  const check = () => { if (signal?.aborted || Date.now() - started >= timeout || Date.now() < started) throw new GatewayHTTPError("REQUEST_TIMEOUT", 408); };
  try {
    while (true) {
      check(); const { value, done } = await Promise.race([reader.read(), cancelled]); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || chunks.length >= 128) throw new GatewayHTTPError();
      total += value.byteLength; if (total > maximum) throw new GatewayHTTPError("BODY_TOO_LARGE", 413);
      chunks.push(value.slice());
    }
    check(); if (length !== null && total !== Number(length)) throw new GatewayHTTPError();
    const bytes = new Uint8Array(total); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    fields(body, [], Object.keys(body ?? {})); return body;
  } catch (error) { throw error instanceof GatewayHTTPError ? error : new GatewayHTTPError(); }
  finally {
    clearTimeout(timer); signal?.removeEventListener("abort", abort); void reader.cancel().catch(() => {});
    try { reader.releaseLock(); } catch { /* Input cancellation must not change the public error. */ }
    for (const chunk of chunks) chunk.fill(0);
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
function deletionResponse(value, status = 200, recovered = false) {
  if (typeof value?.deletionID !== "string" || !uuid.test(value.deletionID) ||
      typeof value.accountID !== "string" || !uuid.test(value.accountID)) throw new Error();
  if (!["pending", "draining", "deleted"].includes(value.publicData) ||
      !["awaiting-device", "device-acknowledged"].includes(value.privateData) ||
      !["pending", "retained-tokens-processed", "manual-required"].includes(value.appleAuthorization) ||
      !["blocked", "removed"].includes(value.localAccount) || typeof value.attentionRequired !== "boolean" || typeof value.completed !== "boolean") throw new Error();
  if (recovered && (typeof value.statusToken !== "string" || value.statusToken.length !== 80 ||
      value.statusToken.slice(0, 37) !== value.deletionID + "." || !/^[A-Za-z0-9_-]{43}$/.test(value.statusToken.slice(37)))) throw new Error();
  return gatewayJSON({ deletionID: value.deletionID, accountID: value.accountID,
    ...(recovered ? { statusToken: value.statusToken } : {}), publicData: value.publicData, privateData: value.privateData,
    appleAuthorization: value.appleAuthorization, localAccount: value.localAccount,
    attentionRequired: value.attentionRequired, completed: value.completed }, status);
}

/** Closed native API. serverBudgetHash is supplied by the trusted edge/authority, never taken from JSON. */
export function createGatewayHTTPHandler({ authentication, login, renewal, sessionReset, deletions, deletionCoordinator,
  deletionEnabled = false, community, isCommunityEnabled = () => false, avatarReader, isAvatarReadEnabled = () => false,
  avatarPublication, isAvatarUploadEnabled = () => false, avatarUploadTimeoutMilliseconds = 20000,
  avatarWithdrawal = avatarPublication, isAvatarWithdrawalEnabled = isAvatarUploadEnabled,
  avatarReview, isAvatarReviewEnabled = () => false, isAvatarReviewer = () => false, reviewTimeoutMilliseconds = 12000, clock = Date.now,
  avatarOwnerPreview, isAvatarOwnerPreviewEnabled = () => false, previewTimeoutMilliseconds = 12000,
  avatarReports, isAvatarReportEnabled = () => false, isAvatarReportCancelEnabled = () => false, avatarReportTimeoutMilliseconds = 12000,
  reportReview, isReportReviewEnabled = () => false, isReportReviewer = () => false, reportTimeoutMilliseconds = 12000,
  limits, scheduleMaintenance, isEnabled, checkpoint, inputTimeoutMilliseconds = 3000, avatarTimeoutMilliseconds = 12000 } = {}) {
  let activeAvatar = 0;
  if (typeof authentication?.issueChallenge !== "function" || typeof login?.login !== "function" || typeof renewal?.renew !== "function" ||
      typeof sessionReset?.reset !== "function" ||
      (checkpoint !== undefined && (typeof checkpoint?.verify !== "function" || typeof checkpoint.advance !== "function")) ||
      typeof limits?.consume !== "function" || typeof scheduleMaintenance !== "function" || typeof isEnabled !== "function" || typeof isCommunityEnabled !== "function" ||
      typeof isAvatarWithdrawalEnabled !== "function" || typeof isAvatarUploadEnabled !== "function" || typeof isAvatarReadEnabled !== "function" || !Number.isInteger(avatarTimeoutMilliseconds) || avatarTimeoutMilliseconds < 1 || avatarTimeoutMilliseconds > 12000 ||
      typeof deletionEnabled !== "boolean" || !Number.isInteger(inputTimeoutMilliseconds) || inputTimeoutMilliseconds < 1 || inputTimeoutMilliseconds > 3000 ||
      (deletionEnabled && (typeof deletions?.status !== "function" || typeof deletionCoordinator?.request !== "function" || typeof deletionCoordinator?.recover !== "function"))) throw new Error("Gateway dependencies are unavailable.");
  const uploadHandler = createAvatarUploadHandler({ authentication, limits, checkpoint, avatarPublication, isEnabled,
    isAvatarUploadEnabled, avatarWithdrawal, isAvatarWithdrawalEnabled, avatarUploadTimeoutMilliseconds, inputTimeoutMilliseconds });
  const reviewHandler = createAvatarReviewHandler({ authentication, limits, checkpoint, avatarReview, isEnabled,
    isAvatarReviewEnabled, isAvatarReviewer, scheduleMaintenance, clock, reviewTimeoutMilliseconds, inputTimeoutMilliseconds });
  const previewHandler = createAvatarOwnerPreviewHandler({ authentication, limits, checkpoint, avatarOwnerPreview, isEnabled,
    isAvatarOwnerPreviewEnabled, previewTimeoutMilliseconds, inputTimeoutMilliseconds });
  const photoReportHandler = createAvatarReportHandler({ authentication, limits, checkpoint, avatarReports, isEnabled,
    isAvatarReportEnabled, isAvatarReportCancelEnabled, isAvatarReadEnabled, scheduleMaintenance, avatarReportTimeoutMilliseconds, inputTimeoutMilliseconds });
  const reportHandler = createReportReviewHandler({ authentication, limits, checkpoint, reportReview, isEnabled,
    isReportReviewEnabled, isReportReviewer, scheduleMaintenance, clock, reportTimeoutMilliseconds, inputTimeoutMilliseconds });
  return async (request, serverBudgetHash) => {
    let avatarDeadline, avatarClaimed = false;
    try {
      const { path } = inspectGatewayRequest(request);
      if (path === "/health") return gatewayJSON({ status: "ok", mode: "development-gateway" });
      if (isEnabled() !== true) return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503);
      if (path === avatarOwnerPreviewPath) return await previewHandler(request, serverBudgetHash);
      if (avatarReportPaths.has(path)) return await photoReportHandler(request, serverBudgetHash, avatarReportPaths.get(path));
      if (reportReviewPaths.has(path)) return await reportHandler(request, serverBudgetHash, reportReviewPaths.get(path));
      if (avatarReviewPaths.has(path)) return await reviewHandler(request, serverBudgetHash, avatarReviewPaths.get(path));
      if (avatarMutationPaths.has(path)) return await uploadHandler(request, serverBudgetHash, avatarMutationPaths.get(path));
      const avatar = path === avatarReadPath, social = !avatar && path.startsWith("/v1/community/");
      if (avatar) {
        if (isAvatarReadEnabled() !== true || typeof avatarReader?.prepare !== "function" || typeof limits.consumeAvatarRead !== "function") return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
        if (activeAvatar >= 4) throw new AvatarReadError("AVATAR_READ_LIMIT");
        activeAvatar++; avatarClaimed = true;
        avatarDeadline = avatarHTTPDeadline(request.signal, avatarTimeoutMilliseconds);
      }
      const awaited = async action => avatarDeadline ? avatarDeadline.run(action) : action();
      const checkAvatar = () => {
        if (!avatar) return;
        avatarDeadline.check();
        if (isEnabled() !== true || isAvatarReadEnabled() !== true) throw new GatewayHTTPError("FEATURE_DISABLED", 503);
      };
      if (social && (isCommunityEnabled() !== true || typeof community?.prepare !== "function")) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      const heavy = avatar || social || ["/v1/auth/login", "/v1/auth/renew", "/v1/auth/session-reset", "/v1/account/deletion", "/v1/account/deletion/recover"].includes(path);
      await awaited(() => limits.consume(serverBudgetHash, { heavy })); checkAvatar();
      const body = await awaited(() => objectBody(request, avatar ? avatarReadInputLimit : social ? 49152 : heavy ? 16384 : 256, inputTimeoutMilliseconds, avatarDeadline?.signal ?? request.signal));
      let photo;
      if (avatar) {
        checkAvatar(); const selection = avatarReadBody(body), accessToken = bearer(request, 80);
        if (accessToken.length !== 80 || !uuid.test(accessToken.slice(0, 36)) || !/^\.[A-Za-z0-9_-]{43}$/.test(accessToken.slice(36))) throw new GatewayHTTPError("INVALID_SESSION", 401);
        const identity = authentication.authorize(accessToken);
        if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new GatewayHTTPError("INVALID_SESSION", 401); }
        if (!identity || typeof identity.accountID !== "string" || !uuid.test(identity.accountID)) throw new GatewayHTTPError("INVALID_SESSION", 401);
        await awaited(() => limits.consumeAvatarRead(identity.accountID, { variant: selection.variant })); checkAvatar();
        photo = { ...selection, accessToken, signal: avatarDeadline.signal };
      }
      // Budget, bounded body, closed avatar input/session/account limits precede checkpoint IO.
      await awaited(() => checkpoint?.verify({ signal: avatarDeadline?.signal ?? request.signal })); checkAvatar();
      const dispatch = async () => {
        if (avatar) {
          checkAvatar(); const finalize = await avatarReader.prepare(photo); checkAvatar();
          if (typeof finalize !== "function") throw new Error();
          return finalize;
        }
        if (social) {
          const finalize = await community.prepare(path.slice("/v1/community/".length), body, { accessToken: bearer(request, 80), signal: request.signal });
          if (typeof finalize !== "function") throw new Error();
          return () => gatewayJSON(finalize());
        }
        if (path.startsWith("/v1/account/") && !deletionEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
        if (path === "/v1/auth/challenge") {
          fields(body, ["purpose"]);
          if (!["login", "account_deletion", "session_reset", "deletion_recovery"].includes(body.purpose)) throw new GatewayHTTPError();
          if (["account_deletion", "deletion_recovery"].includes(body.purpose) && !deletionEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
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
        if (path === "/v1/auth/session-reset") {
          fields(body, ["challengeID", "identityToken"], ["expectedAccountID"]); uuidField(body.challengeID);
          opaqueField(body.identityToken, 12288);
          if (body.expectedAccountID !== undefined) uuidField(body.expectedAccountID);
          await scheduleMaintenance(); await sessionReset.reset(body);
          return new Response(null, { status: 204, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
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
        if (path === "/v1/account/deletion/recover") {
          fields(body, ["challengeID", "identityToken"], ["expectedAccountID"]); uuidField(body.challengeID);
          opaqueField(body.identityToken, 12288);
          if (body.expectedAccountID !== undefined) uuidField(body.expectedAccountID);
          // Recovery takes only fresh owner proof; do not accept a bearer as a substitute.
          if (request.headers.has("Authorization")) throw new GatewayHTTPError();
          await scheduleMaintenance();
          return deletionResponse(await deletionCoordinator.recover(body), 200, true);
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
      };
      let response;
      try { response = await awaited(dispatch); }
      catch (error) { checkAvatar(); await awaited(() => checkpoint?.advance({ signal: avatarDeadline?.signal ?? request.signal })); throw error; }
      await awaited(() => checkpoint?.advance({ signal: avatarDeadline?.signal ?? request.signal })); checkAvatar();
      if (isEnabled() !== true) return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503);
      if (social && isCommunityEnabled() !== true) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      const result = typeof response === "function" ? response() : response;
      if (avatar && !(result instanceof Response)) {
        void result?.catch?.(() => {}); throw new AvatarReadError("AVATAR_READ_RESPONSE");
      }
      return result;
    } catch (error) { return gatewayFailure(error); }
    finally {
      avatarDeadline?.close();
      if (avatarClaimed) {
        if (request.body && !request.body.locked) void request.body.cancel().catch(() => {});
        activeAvatar--;
      }
    }
  };
}
