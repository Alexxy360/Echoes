import { plain } from "./public-record-schema.mjs";
import { validAvatarPublicationIntent } from "./avatar-publication-intent.mjs";
import { AvatarReadError, avatarManifestHeader } from "./cloudkit-avatar-reader.mjs";
import { avatarHTTPManifest, avatarEdgeResponse } from "./gateway-avatar-http.mjs";
import { AvatarIntakeError, avatarMutationHeaders, avatarMutationBody } from "./avatar-upload-http.mjs";

export const avatarOwnerPreviewPath = "/v1/community/avatar/preview";
export const avatarSelectionHeader = "X-Echoes-Avatar-Selection";
const keys = ["requestID", "versionID", "generation", "reviewRevision"];
export function avatarOwnerPreviewInput(value) {
  if (!plain(value) || Object.keys(value).sort().join() !== [...keys].sort().join() ||
      !validAvatarPublicationIntent({ ...value, consentVersion: 1 })) throw new AvatarReadError("AVATAR_READ_INPUT");
  return Object.freeze({ ...value });
}
export function avatarOwnerPreviewHeaders(request) {
  if ([avatarSelectionHeader, avatarManifestHeader, "X-Echoes-Avatar-Review"].some(key => request.headers.has(key))) throw new AvatarReadError("AVATAR_READ_INPUT");
  try { return avatarMutationHeaders(request, "status"); }
  catch (e) { throw avatarOwnerPreviewError(e); }
}
export function avatarOwnerPreviewError(e) {
  if (e instanceof AvatarIntakeError) {
    const code = { AVATAR_INPUT: "AVATAR_READ_INPUT", AVATAR_RESPONSE: "AVATAR_READ_RESPONSE", AVATAR_UNAVAILABLE: "AVATAR_READ_UNAVAILABLE" }[e.code];
    if (code) return new AvatarReadError(code);
  }
  return e;
}
/** One unsettled request, retained after timeout until every ignoring dependency returns. */
export function avatarOwnerPreviewAdmission() {
  let occupied = false;
  return () => {
    if (occupied) throw new AvatarReadError("AVATAR_READ_LIMIT");
    occupied = true; let closed = false, released = false; const pending = new Set();
    const release = () => { if (closed && !pending.size && !released) { released = true; occupied = false; } };
    return { async run(deadline, task) {
      if (closed) throw new AvatarReadError(); deadline.check();
      const operation = Promise.resolve().then(() => { deadline.check(); return task(); }); pending.add(operation);
      const settled = value => { pending.delete(operation); if (closed && value instanceof Response) void value.body?.cancel().catch(() => {}); release(); };
      void operation.then(settled, () => settled()); return deadline.run(() => operation);
    }, close() { closed = true; release(); } };
  };
}
/** This correlation is not a grant/receipt and does not prove that a person saw the image. */
export async function avatarOwnerPreviewResponse(response, deadline, { selection, accountID } = {}) {
  let result;
  try {
    if (response?.status !== 200) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    const raw = response.headers.get(avatarSelectionHeader);
    if (typeof raw !== "string" || raw.length > 512 || /[^\x20-\x7e]/.test(raw)) throw new Error();
    const proof = JSON.parse(raw), { schemaVersion, ...tuple } = proof;
    if (schemaVersion !== 1) throw new Error();
    avatarOwnerPreviewInput(tuple);
    if (selection && keys.some(key => tuple[key] !== selection[key])) throw new Error();
    const manifest = avatarHTTPManifest(response.headers.get(avatarManifestHeader));
    if (manifest.variant !== "image" || manifest.versionID !== tuple.versionID || accountID !== undefined && manifest.ownerID !== accountID) throw new Error();
    result = await avatarEdgeResponse(response, deadline);
    const headers = new Headers(result.headers); headers.set(avatarSelectionHeader, JSON.stringify({ schemaVersion: 1, ...tuple }));
    deadline.check(); return new Response(result.body, { status: 200, headers });
  } catch (e) {
    if (result?.body) void result.body.cancel().catch(() => {});
    throw e instanceof AvatarReadError && e.code !== "AVATAR_READ_INPUT" ? e : new AvatarReadError("AVATAR_READ_RESPONSE");
  } finally { if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
}
const errorStatus = Object.freeze({ AVATAR_READ_INPUT: 400, AVATAR_READ_NOT_FOUND: 404, AVATAR_READ_STALE: 401,
  AVATAR_READ_UNAVAILABLE: 503, AVATAR_READ_RESPONSE: 503, AVATAR_READ_LIMIT: 429, INVALID_REQUEST: 400, HTTPS_REQUIRED: 400,
  NOT_FOUND: 404, METHOD_NOT_ALLOWED: 405, ORIGIN_NOT_ALLOWED: 403, UNSUPPORTED_MEDIA_TYPE: 415, BODY_TOO_LARGE: 413,
  REQUEST_TIMEOUT: 408, INVALID_SESSION: 401, REAUTH_REQUIRED: 401, ACCOUNT_DISABLED: 403, DELETION_IN_PROGRESS: 403,
  FEATURE_DISABLED: 503, GATEWAY_DISABLED: 503, RATE_LIMITED: 429, CAPACITY_LIMITED: 503, LIMIT_UNAVAILABLE: 503, UNAVAILABLE: 503,
  PUBLIC_INPUT: 400, PUBLIC_CONFLICT: 409, PUBLIC_PENDING: 409, PUBLIC_ERASED: 409, PUBLIC_LIMIT: 429, PUBLIC_THROTTLED: 503,
  PUBLIC_REGISTRY_UNVERIFIED: 503, PUBLIC_UNAVAILABLE: 503 });
export async function avatarOwnerPreviewEdgeResponse(response, deadline, options) {
  if (response?.status === 200) return avatarOwnerPreviewResponse(response, deadline, options);
  let bytes;
  try {
    if (!(response instanceof Response) || response.redirected || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff") throw new Error();
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^[1-9]\d{0,3}$/.test(length) || Number(length) > 2048)) throw new Error();
    bytes = await avatarMutationBody(response, { maximum: 2048, length: length === null ? null : Number(length) }, deadline.signal, 3000);
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (!plain(body) || Object.keys(body).sort().join() !== "error,protocolVersion" || body.protocolVersion !== 1 ||
        !Object.hasOwn(errorStatus, body.error) || errorStatus[body.error] !== response.status) throw new Error();
    const headers = { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" };
    const retry = response.headers.get("Retry-After"); if (/^\d{1,6}$/.test(retry ?? "") && Number(retry) <= 86400) headers["Retry-After"] = retry;
    if (response.status === 405) headers.Allow = "POST";
    deadline.check(); return Response.json(body, { status: response.status, headers });
  } catch (e) { throw e instanceof AvatarReadError ? e : new AvatarReadError("AVATAR_READ_RESPONSE"); }
  finally { bytes?.fill(0); if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
}
