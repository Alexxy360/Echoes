import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { communityCoordinate } from "./community-domain.mjs";
import { AvatarReadError, avatarManifestHeader } from "./cloudkit-avatar-reader.mjs";

export const avatarReadPath = "/v1/community/avatar/read";
export const avatarReadInputLimit = 2048;
const domains = ["icloud-content.com", "icloud.com", "apple-cloudkit.com"];

/** Deployment configuration only, never request-provided URLs or a provider wildcard. */
export function avatarDownloadHosts(json) {
  try {
    if (typeof json !== "string" || json.length > 4096) throw new Error();
    const values = JSON.parse(json);
    if (!Array.isArray(values) || values.length < 1 || values.length > 8 || new Set(values).size !== values.length ||
        values.some(host => typeof host !== "string" || host.length > 253 || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(host) ||
          !domains.some(domain => host.endsWith("." + domain)))) throw new Error();
    return Object.freeze(values.slice());
  } catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
}
export function avatarReadBody(value) {
  if (!plain(value) || ["ownerID", "versionID", "variant"].some(key => !Object.hasOwn(value, key)) ||
      Object.keys(value).some(key => !["ownerID", "versionID", "variant", "coordinate", "knownSHA256"].includes(key)) ||
      [value.ownerID, value.versionID].some(v => typeof v !== "string" || !publicUUID.test(v)) || !["image", "thumbnail"].includes(value.variant) ||
      value.knownSHA256 !== undefined && (typeof value.knownSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(value.knownSHA256))) throw new AvatarReadError("AVATAR_READ_INPUT");
  let coordinate;
  if (value.coordinate !== undefined) {
    try { coordinate = Object.freeze(communityCoordinate(value.coordinate)); } catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
  }
  return Object.freeze({ ownerID: value.ownerID, versionID: value.versionID, variant: value.variant,
    ...(coordinate ? { coordinate } : {}), ...(value.knownSHA256 === undefined ? {} : { knownSHA256: value.knownSHA256 }) });
}
export function avatarHTTPManifest(raw) {
  try {
    if (typeof raw !== "string" || raw.length > 2048 || /[^\x20-\x7e]/.test(raw)) throw new Error();
    const v = JSON.parse(raw);
    if (!plain(v) || Object.keys(v).sort().join() !== "byteCount,height,ownerID,schemaVersion,sha256,variant,versionID,width" || v.schemaVersion !== 1 ||
        [v.ownerID, v.versionID].some(id => typeof id !== "string" || !publicUUID.test(id)) || !["image", "thumbnail"].includes(v.variant) ||
        typeof v.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(v.sha256) || !Number.isSafeInteger(v.byteCount) || v.byteCount < 1 ||
        v.byteCount > (v.variant === "image" ? 256000 : 32000) || [v.width, v.height].some(n => !Number.isSafeInteger(n) || n < 1 || n > (v.variant === "image" ? 512 : 128))) throw new Error();
    return Object.freeze(v);
  } catch { throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
}

/** Request-scoped total deadline. It limits logical waiting; arbitrary injected IO can ignore abort. */
export function avatarHTTPDeadline(signal, milliseconds = 12000) {
  if (!Number.isInteger(milliseconds) || milliseconds < 1 || milliseconds > 15000) throw new AvatarReadError("AVATAR_READ_INPUT");
  const controller = new AbortController(), started = Date.now(); let closed = false, timer, reject;
  const cancelled = new Promise((_, fail) => { reject = fail; });
  // May be aborted before the first run; attach a rejection handler immediately.
  void cancelled.catch(() => {});
  const cancel = () => { if (closed) return; controller.abort(); reject(new AvatarReadError()); };
  if (signal?.aborted) cancel(); else signal?.addEventListener("abort", cancel, { once: true });
  timer = setTimeout(cancel, milliseconds);
  const check = () => {
    if (closed || controller.signal.aborted || signal?.aborted || Date.now() - started >= milliseconds || Date.now() < started) throw new AvatarReadError();
  };
  return Object.freeze({ signal: controller.signal, check,
    async run(action) { check(); const value = await Promise.race([Promise.resolve().then(() => { check(); return action(); }), cancelled]); check(); return value; },
    close() { closed = true; clearTimeout(timer); signal?.removeEventListener("abort", cancel); controller.abort(); }
  });
}

let edgeActive = 0;
/** Only a response from the fixed private authority reaches this boundary. Buffer a bounded copy so
 * Workers emits a fixed-length TypedArray body rather than silently dropping Content-Length on a
 * generic stream. No provider headers, URL or receipt are forwarded. */
export async function avatarEdgeResponse(response, deadline) {
  if (edgeActive >= 4) { void response?.body?.cancel().catch(() => {}); throw new AvatarReadError("AVATAR_READ_LIMIT"); }
  edgeActive++;
  let reader, data; const parts = [];
  try {
    deadline.check();
    if (!(response instanceof Response) || response.redirected || ![200, 204].includes(response.status) ||
        response.headers.has("Content-Range") || response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        response.headers.get("X-Content-Type-Options") !== "nosniff" ||
        response.headers.get("Cache-Control")?.toLowerCase().split(",").map(s => s.trim()).sort().join() !== "no-store,private") throw new AvatarReadError("AVATAR_READ_RESPONSE");
    const manifest = avatarHTTPManifest(response.headers.get(avatarManifestHeader));
    const headers = new Headers({ "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", [avatarManifestHeader]: JSON.stringify(manifest) });
    if (response.status === 204) {
      if (response.body !== null || response.headers.has("Content-Length") || response.headers.has("Content-Type")) throw new AvatarReadError("AVATAR_READ_RESPONSE");
      return new Response(null, { status: 204, headers });
    }
    if (!response.body || response.headers.get("Content-Type") !== "image/jpeg" || response.headers.get("Content-Length") !== String(manifest.byteCount)) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    reader = response.body.getReader(); let count = 0;
    while (true) {
      deadline.check(); const { done, value } = await deadline.run(() => reader.read()); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || parts.length >= 128 || (count += value.byteLength) > manifest.byteCount) throw new AvatarReadError("AVATAR_READ_RESPONSE");
      parts.push(value.slice());
    }
    deadline.check(); if (count !== manifest.byteCount) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    data = new Uint8Array(count); let offset = 0;
    for (const part of parts) { data.set(part, offset); offset += part.byteLength; }
    if (digest(data) !== manifest.sha256) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    headers.set("Content-Type", "image/jpeg"); headers.set("Content-Length", String(count));
    deadline.check(); return new Response(data.slice(), { status: 200, headers });
  } finally {
    if (reader) { void reader.cancel().catch(() => {}); try { reader.releaseLock(); } catch {} }
    else void response?.body?.cancel().catch(() => {});
    data?.fill(0); for (const part of parts) part.fill(0); edgeActive--;
  }
}

const errorCodes = new Set(["INVALID_REQUEST", "HTTPS_REQUIRED", "NOT_FOUND", "METHOD_NOT_ALLOWED", "ORIGIN_NOT_ALLOWED",
  "UNSUPPORTED_MEDIA_TYPE", "BODY_TOO_LARGE", "REQUEST_TIMEOUT", "INVALID_SESSION", "REAUTH_REQUIRED", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS",
  "FEATURE_DISABLED", "GATEWAY_DISABLED", "RATE_LIMITED", "CAPACITY_LIMITED", "LIMIT_UNAVAILABLE", "UNAVAILABLE",
  "PUBLIC_INPUT", "PUBLIC_CONFLICT", "PUBLIC_PENDING", "PUBLIC_ERASED", "PUBLIC_LIMIT", "PUBLIC_THROTTLED", "PUBLIC_UNAVAILABLE",
  "AVATAR_READ_INPUT", "AVATAR_READ_NOT_FOUND", "AVATAR_READ_STALE", "AVATAR_READ_UNAVAILABLE", "AVATAR_READ_RESPONSE", "AVATAR_READ_LIMIT"]);
/** Error streams also need an owned bounded body: closing the request signal after returning a
 * passthrough stream can abort that stream before the native client receives its rejection code. */
export async function avatarEdgeErrorResponse(response, deadline) {
  if (edgeActive >= 4) { void response?.body?.cancel().catch(() => {}); throw new AvatarReadError("AVATAR_READ_LIMIT"); }
  edgeActive++;
  let reader, data; const parts = [];
  try {
    deadline.check();
    if (!(response instanceof Response) || response.redirected || ![400, 401, 403, 404, 405, 408, 409, 413, 415, 429, 503].includes(response.status) ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.has("Content-Range") || response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" || !response.body) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^\d{1,5}$/.test(length) || Number(length) > 32768)) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    reader = response.body.getReader(); let count = 0;
    while (true) {
      deadline.check(); const { done, value } = await deadline.run(() => reader.read()); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || parts.length >= 128 || (count += value.byteLength) > 32768) throw new AvatarReadError("AVATAR_READ_RESPONSE");
      parts.push(value.slice());
    }
    if (length !== null && count !== Number(length)) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    data = new Uint8Array(count); let offset = 0;
    for (const part of parts) { data.set(part, offset); offset += part.byteLength; }
    let body;
    try { body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data)); } catch { throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
    if (!plain(body) || Object.keys(body).sort().join() !== "error,protocolVersion" || body.protocolVersion !== 1 || !errorCodes.has(body.error)) throw new AvatarReadError("AVATAR_READ_RESPONSE");
    const headers = new Headers({ "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" });
    const retry = response.headers.get("Retry-After");
    if (/^\d{1,6}$/.test(retry ?? "") && Number(retry) <= 86400) headers.set("Retry-After", retry);
    if (response.status === 405 && response.headers.get("Allow") === "POST") headers.set("Allow", "POST");
    deadline.check(); return Response.json({ protocolVersion: 1, error: body.error }, { status: response.status, headers });
  } finally {
    if (reader) { void reader.cancel().catch(() => {}); try { reader.releaseLock(); } catch {} }
    else void response?.body?.cancel().catch(() => {});
    data?.fill(0); for (const part of parts) part.fill(0); edgeActive--;
  }
}
