import { plain, publicUUID } from "./public-record-schema.mjs";
import { AvatarReviewError } from "./avatar-review-state.mjs";
import { avatarReviewHeader } from "./avatar-review-coordinator.mjs";
import { AvatarIntakeError, avatarMutationHeaders, avatarMutationBody, avatarMutationDeadline } from "./avatar-upload-http.mjs";
import { AvatarReadError, avatarManifestHeader } from "./cloudkit-avatar-reader.mjs";
import { avatarEdgeResponse, avatarHTTPManifest } from "./gateway-avatar-http.mjs";

export const avatarReviewPaths = new Map(["queue", "inspect", "decide", "recover"].map(action => ["/v1/moderation/avatar/" + action, action]));
const exact = (value, keys) => plain(value) && Object.keys(value).sort().join() === [...keys].sort().join();
const id = value => typeof value === "string" && publicUUID.test(value);
export function avatarReviewers(json = "[]") {
  try {
    if (typeof json !== "string" || json.length > 2048) throw new Error();
    const list = JSON.parse(json);
    if (!Array.isArray(list) || list.length > 16 || list.some(v => !id(v)) || new Set(list).size !== list.length) throw new Error();
    return Object.freeze(list.slice().sort());
  } catch { throw new AvatarReviewError("AVATAR_REVIEW_INPUT"); }
}
export function avatarReviewInput(action, value) {
  const keys = { queue: [], inspect: ["accountID", "requestID"], decide: ["inspectionID", "decisionID", "verdict"],
    recover: ["accountID", "requestID", "versionID", "generation", "reviewRevision", "decisionID", "verdict"] }[action];
  if (!keys || !exact(value, keys) || keys.some(k => k.endsWith("ID") && !id(value[k])) ||
      ["decide", "recover"].includes(action) && !["approved", "rejected"].includes(value.verdict) ||
      action === "recover" && (!id(value.reviewRevision) || !Number.isSafeInteger(value.generation) || value.generation < 1 || value.generation >= Number.MAX_SAFE_INTEGER)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
  return Object.freeze({ ...value });
}
export function avatarReviewHeaders(request) {
  if (request.headers.has(avatarReviewHeader) || request.headers.has(avatarManifestHeader)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
  return avatarMutationHeaders(request, "status"); // Strict JSON512, exact native bearer, no owner-upload intent.
}
export function reviewTransportError(e) {
  if (e instanceof AvatarReadError) return new AvatarReviewError(e.code === "AVATAR_READ_LIMIT" ? "AVATAR_REVIEW_CAPACITY" : "AVATAR_REVIEW_RESPONSE");
  if (e instanceof AvatarIntakeError) {
    if (e.code === "AVATAR_INPUT") return new AvatarReviewError("AVATAR_REVIEW_INPUT");
    if (e.code === "AVATAR_RESPONSE") return new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    if (e.code === "AVATAR_UNAVAILABLE") return new AvatarReviewError();
  }
  return e;
}
export function avatarReviewDeadline(signal, milliseconds = 12000) {
  const deadline = avatarMutationDeadline(signal, milliseconds);
  return { signal: deadline.signal, close: () => deadline.close(),
    check() { try { deadline.check(); } catch { throw new AvatarReviewError(); } },
    async run(action) { try { return await deadline.run(action); } catch (e) { throw reviewTransportError(e); } } };
}
/** One retained request per isolate/handler, including a provider that ignores timeout/abort. */
export function avatarReviewAdmission() {
  let occupied = false;
  return () => {
    if (occupied) throw new AvatarReviewError("AVATAR_REVIEW_CAPACITY");
    occupied = true; let closed = false, released = false; const pending = new Set();
    const release = () => { if (closed && pending.size === 0 && !released) { released = true; occupied = false; } };
    return { async run(deadline, task) {
      if (closed) throw new AvatarReviewError(); deadline.check();
      const operation = Promise.resolve().then(() => { deadline.check(); return task(); }); pending.add(operation);
      const settled = value => { pending.delete(operation); if (closed && value instanceof Response) void value.body?.cancel().catch(() => {}); release(); }; void operation.then(settled, () => settled());
      return deadline.run(() => operation);
    }, close() { closed = true; release(); } };
  };
}
export function avatarReviewResult(action, value, input) {
  if (action === "recover") {
    const keys = ["accountID", "requestID", "versionID", "generation", "reviewRevision", "decisionID", "verdict"];
    if (!exact(value, ["schemaVersion", ...keys, "outcome", "revision"]) || value.schemaVersion !== 1 ||
        !["confirmed", "not-applied", "superseded"].includes(value.outcome) ||
        (value.outcome === "confirmed" ? !id(value.revision) || value.revision === value.reviewRevision : value.revision !== null) ||
        input && keys.some(k => value[k] !== input[k])) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    try { avatarReviewInput("recover", Object.fromEntries(keys.map(k => [k, value[k]]))); }
    catch { throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE"); }
    return Object.freeze({ ...value });
  }
  if (action === "queue") {
    if (!exact(value, ["schemaVersion", "items"]) || value.schemaVersion !== 1 || !Array.isArray(value.items) || value.items.length > 20) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    const seen = new Set(), items = value.items.map(item => {
      if (!exact(item, ["accountID", "requestID", "versionID", "generation", "reviewRevision"]) ||
          [item.accountID, item.requestID, item.versionID, item.reviewRevision].some(v => !id(v)) ||
          !Number.isSafeInteger(item.generation) || item.generation < 1 || item.generation >= Number.MAX_SAFE_INTEGER ||
          seen.has(item.accountID)) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
      seen.add(item.accountID); return Object.freeze({ ...item });
    });
    return Object.freeze({ schemaVersion: 1, items: Object.freeze(items) });
  }
  if (action !== "decide" || !exact(value, ["schemaVersion", "inspectionID", "accountID", "requestID", "decisionID", "revision", "verdict"]) || value.schemaVersion !== 1 ||
      [value.inspectionID, value.accountID, value.requestID, value.decisionID, value.revision].some(v => !id(v)) ||
      !["approved", "rejected"].includes(value.verdict) || input && ["inspectionID", "decisionID", "verdict"].some(k => value[k] !== input[k])) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
  return Object.freeze({ ...value });
}
function inspectionHeader(raw, manifest, input, clock) {
  try {
    const now = clock();
    if (typeof raw !== "string" || raw.length > 1024 || /[^\x20-\x7e]/.test(raw)) throw new Error();
    const value = JSON.parse(raw);
    if (!exact(value, ["schemaVersion", "inspectionID", "expiresAt", "requestID", "generation", "reviewRevision"]) || value.schemaVersion !== 1 ||
        [value.inspectionID, value.requestID, value.reviewRevision].some(v => !id(v)) || !Number.isSafeInteger(value.generation) || value.generation < 1 || value.generation >= Number.MAX_SAFE_INTEGER ||
        !Number.isSafeInteger(value.expiresAt) || !Number.isSafeInteger(now) || now < 0 || value.expiresAt <= now || value.expiresAt > now + 90000 ||
        manifest.variant !== "image" || input && (value.requestID !== input.requestID || manifest.ownerID !== input.accountID)) throw new Error();
    return Object.freeze(value);
  } catch { throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE"); }
}
export async function avatarReviewImageResponse(response, deadline, { input, clock = Date.now } = {}) {
  let result;
  try {
    if (!(response instanceof Response) || response.status !== 200) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    const manifest = avatarHTTPManifest(response.headers.get(avatarManifestHeader));
    const header = inspectionHeader(response.headers.get(avatarReviewHeader), manifest, input, clock);
    result = await avatarEdgeResponse(response, deadline);
    inspectionHeader(JSON.stringify(header), manifest, input, clock); deadline.check();
    result.headers.set(avatarReviewHeader, JSON.stringify(header)); return result;
  } catch (e) {
    void result?.body?.cancel().catch(() => {});
    throw e instanceof AvatarReadError ? new AvatarReviewError("AVATAR_REVIEW_RESPONSE") : e;
  } finally { if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
}
const errorStatus = Object.freeze({ AVATAR_REVIEW_INPUT: 400, AVATAR_REVIEW_SCOPE: 403, AVATAR_REVIEW_STALE: 409,
  AVATAR_REVIEW_PENDING: 409, AVATAR_REVIEW_RESPONSE: 503, AVATAR_REVIEW_UNAVAILABLE: 503, AVATAR_REVIEW_RATE: 429, AVATAR_REVIEW_CAPACITY: 429,
  INVALID_REQUEST: 400, HTTPS_REQUIRED: 400, NOT_FOUND: 404, METHOD_NOT_ALLOWED: 405, ORIGIN_NOT_ALLOWED: 403,
  UNSUPPORTED_MEDIA_TYPE: 415, BODY_TOO_LARGE: 413, REQUEST_TIMEOUT: 408, INVALID_SESSION: 401, ACCOUNT_DISABLED: 403,
  DELETION_IN_PROGRESS: 403, FEATURE_DISABLED: 503, GATEWAY_DISABLED: 503, RATE_LIMITED: 429, CAPACITY_LIMITED: 503, LIMIT_UNAVAILABLE: 503, UNAVAILABLE: 503 });
export async function avatarReviewEdgeResponse(response, action, deadline, clock = Date.now) {
  if (response?.status === 200 && action === "inspect") return avatarReviewImageResponse(response, deadline, { clock });
  let bytes;
  try {
    if (!(response instanceof Response) || response.redirected || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("X-Content-Type-Options") !== "nosniff" || response.headers.get("Cache-Control") !== "no-store") throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    const maximum = response.status === 200 && action === "queue" ? 8192 : 2048, length = response.headers.get("Content-Length");
    if (length !== null && (!/^[1-9]\d{0,3}$/.test(length) || Number(length) > maximum)) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    bytes = await avatarMutationBody(response, { maximum, length: length === null ? null : Number(length) }, deadline.signal, 3000);
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (!plain(body) || body.protocolVersion !== 1) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    const headers = { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" };
    let value;
    if (response.status === 200) {
      const { protocolVersion, ...data } = body; value = { protocolVersion, ...avatarReviewResult(action, data) };
    } else {
      if (!exact(body, ["protocolVersion", "error"]) || errorStatus[body.error] !== response.status) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
      value = body; const retry = response.headers.get("Retry-After");
      if (/^\d{1,6}$/.test(retry ?? "") && Number(retry) <= 86400) headers["Retry-After"] = retry;
      if (response.status === 405) headers.Allow = "POST";
    }
    deadline.check(); return Response.json(value, { status: response.status, headers });
  } catch (e) { throw e instanceof AvatarReviewError ? e : new AvatarReviewError("AVATAR_REVIEW_RESPONSE"); }
  finally { bytes?.fill(0); if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
}
