import { plain, publicUUID } from "./public-record-schema.mjs";
import { avatarEdgeErrorResponse } from "./gateway-avatar-http.mjs";
import { avatarPublicationKeys, validAvatarPublicationIntent } from "./avatar-publication-intent.mjs";

export const avatarIntentHeader = "X-Echoes-Avatar-Intent";
export const avatarUploadLimit = 256000;
export const avatarMutationPaths = new Map(["upload", "recover", "publish", "clear", "status"].map(action => ["/v1/community/avatar/" + action, action]));
export class AvatarIntakeError extends Error {
  constructor(code = "AVATAR_UNAVAILABLE") {
    super("Profile photo request could not be completed.");
    this.code = ["AVATAR_INPUT", "AVATAR_RESPONSE", "AVATAR_UNAVAILABLE", "AVATAR_RATE", "BODY_TOO_LARGE", "UNSUPPORTED_MEDIA_TYPE", "INVALID_SESSION", "FEATURE_DISABLED"].includes(code) ? code : "AVATAR_UNAVAILABLE";
  }
}
function exact(value, keys) { return plain(value) && Object.keys(value).sort().join() === [...keys].sort().join(); }
function id(value) { return typeof value === "string" && publicUUID.test(value); }
export function avatarMutationInput(action, value) {
  const keys = { upload: ["requestID", "versionID", "expectedGeneration", "consentVersion"], clear: ["requestID", "expectedGeneration"],
    recover: ["requestID"], publish: avatarPublicationKeys, status: [] }[action];
  if (!keys || !exact(value, keys) || keys.includes("requestID") && !id(value.requestID) || keys.includes("versionID") && !id(value.versionID) ||
      keys.includes("expectedGeneration") && (!Number.isSafeInteger(value.expectedGeneration) || value.expectedGeneration < 0 || value.expectedGeneration >= Number.MAX_SAFE_INTEGER) ||
      action === "upload" && value.consentVersion !== 1 || action === "publish" && !validAvatarPublicationIntent(value)) throw new AvatarIntakeError("AVATAR_INPUT");
  return Object.freeze({ ...value });
}
/** Headers bind one bounded JPEG to a closed intent, never an account, host, receipt or manifest. */
export function avatarMutationHeaders(request, action) {
  const upload = action === "upload", type = request.headers.get("Content-Type"), encoding = request.headers.get("Content-Encoding");
  if ((upload ? type !== "image/jpeg" : !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(type ?? "")) ||
      encoding !== null && encoding !== "identity") throw new AvatarIntakeError("UNSUPPORTED_MEDIA_TYPE");
  const raw = request.headers.get(avatarIntentHeader);
  let intent;
  if (upload) {
    if (typeof raw !== "string" || raw.length > 512 || /[^\x20-\x7e]/.test(raw)) throw new AvatarIntakeError("AVATAR_INPUT");
    try { intent = avatarMutationInput(action, JSON.parse(raw)); } catch { throw new AvatarIntakeError("AVATAR_INPUT"); }
  } else if (raw !== null) throw new AvatarIntakeError("AVATAR_INPUT");
  const length = request.headers.get("Content-Length"), maximum = upload ? avatarUploadLimit : 512;
  if (length !== null && (!/^[1-9]\d{0,5}$/.test(length) || Number(length) > maximum)) throw new AvatarIntakeError("BODY_TOO_LARGE");
  const auth = request.headers.get("Authorization");
  if (typeof auth !== "string" || auth.length !== 87 || !auth.startsWith("Bearer ") || !id(auth.slice(7, 43)) || !/^\.[A-Za-z0-9_-]{43}$/.test(auth.slice(43))) throw new AvatarIntakeError("INVALID_SESSION");
  return { intent, accessToken: auth.slice(7), maximum, length: length === null ? null : Number(length) };
}
/** Absolute wall deadline, independent of an endlessly producing/microtask stream. */
export function avatarMutationDeadline(signal, milliseconds = 20000) {
  if (!Number.isInteger(milliseconds) || milliseconds < 1 || milliseconds > 25000) throw new AvatarIntakeError("AVATAR_INPUT");
  const controller = new AbortController(), started = Date.now(); let closed = false, fail;
  const stopped = new Promise((_, reject) => { fail = reject; }); void stopped.catch(() => {});
  const cancel = () => { if (!closed) { controller.abort(); fail(new AvatarIntakeError()); } };
  if (signal?.aborted) cancel(); else signal?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(cancel, milliseconds);
  const check = () => { if (closed || signal?.aborted || controller.signal.aborted || Date.now() < started || Date.now() - started >= milliseconds) throw new AvatarIntakeError(); };
  return { signal: controller.signal, check,
    async run(action) { check(); const result = await Promise.race([Promise.resolve().then(() => { check(); return action(); }), stopped]); check(); return result; },
    close() { closed = true; clearTimeout(timer); signal?.removeEventListener("abort", cancel); controller.abort(); }
  };
}
/** Admission remains occupied until ignoring dependencies actually settle, even after timeout. */
export function avatarMutationAdmission() {
  let uploads = 0, controls = 0;
  return action => {
    const upload = action === "upload";
    if (upload ? uploads >= 1 : controls >= 4) throw new AvatarIntakeError("AVATAR_RATE");
    if (upload) uploads++; else controls++;
    const pending = new Set(); let closed = false, released = false;
    const release = () => {
      if (closed && !pending.size && !released) { released = true; if (upload) uploads--; else controls--; }
    };
    return {
      async run(deadline, action) {
        if (closed) throw new AvatarIntakeError(); deadline.check();
        const operation = Promise.resolve().then(() => { deadline.check(); return action(); }); pending.add(operation);
        const settled = () => { pending.delete(operation); release(); }; void operation.then(settled, settled);
        return deadline.run(() => operation);
      },
      close() { closed = true; release(); }
    };
  };
}
export async function avatarMutationBody(request, headers, signal, timeout = 3000) {
  if (!request.body) throw new AvatarIntakeError("AVATAR_INPUT");
  const deadline = avatarMutationDeadline(signal, timeout), reader = request.body.getReader(), chunks = []; let total = 0;
  try {
    while (true) {
      const { value, done } = await deadline.run(() => reader.read()); if (done) break;
      if (!(value instanceof Uint8Array) || !value.byteLength || chunks.length >= 128) throw new AvatarIntakeError("AVATAR_INPUT");
      if ((total += value.byteLength) > headers.maximum) throw new AvatarIntakeError("BODY_TOO_LARGE");
      chunks.push(value.slice());
    }
    deadline.check(); if (!total || headers.length !== null && total !== headers.length) throw new AvatarIntakeError("AVATAR_INPUT");
    const bytes = new Uint8Array(total); let offset = 0;
    for (const part of chunks) { bytes.set(part, offset); offset += part.byteLength; }
    return bytes;
  } finally {
    deadline.close(); void reader.cancel().catch(() => {}); try { reader.releaseLock(); } catch {}
    for (const part of chunks) part.fill(0);
  }
}
export function avatarMutationSnapshot(value) {
  const keys = ["generation", "requestID", "versionID", "publishedVersionID", "status", "reviewRevision"];
  if (!exact(value, keys) || !Number.isSafeInteger(value.generation) || value.generation < 0 ||
      !["none", "clearing", "uploading", "pending-review", "approved", "rejected", "published", "expired"].includes(value.status) ||
      [value.requestID, value.versionID, value.publishedVersionID, value.reviewRevision].some(v => v !== null && !id(v))) throw new AvatarIntakeError("AVATAR_RESPONSE");
  if (value.generation === 0 ? keys.filter(k => k.endsWith("ID") || k === "reviewRevision").some(k => value[k] !== null) || value.status !== "none" : value.requestID === null) throw new AvatarIntakeError("AVATAR_RESPONSE");
  if (value.versionID === null ? value.reviewRevision !== null || value.publishedVersionID !== null || !["none", "clearing"].includes(value.status) :
      value.reviewRevision === null || ["none", "clearing"].includes(value.status) || (value.status === "published" ? value.publishedVersionID !== value.versionID : value.publishedVersionID !== null)) throw new AvatarIntakeError("AVATAR_RESPONSE");
  return Object.freeze({ ...value });
}
/** Own the bounded JSON before closing the upstream signal; never forward private fields/headers. */
export async function avatarMutationEdgeResponse(response, deadline) {
  if (response?.status !== 200) {
    try { return await avatarEdgeErrorResponse(response, deadline); } catch { throw new AvatarIntakeError("AVATAR_RESPONSE"); }
  }
  let bytes;
  try {
    if (!(response instanceof Response) || response.redirected || !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff" || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity") throw new AvatarIntakeError("AVATAR_RESPONSE");
    const raw = response.headers.get("Content-Length");
    if (raw !== null && (!/^[1-9]\d{0,3}$/.test(raw) || Number(raw) > 2048)) throw new AvatarIntakeError("AVATAR_RESPONSE");
    bytes = await avatarMutationBody(response, { maximum: 2048, length: raw === null ? null : Number(raw) }, deadline.signal, 3000);
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (!plain(body) || body.protocolVersion !== 1) throw new AvatarIntakeError("AVATAR_RESPONSE");
    const { protocolVersion, ...rest } = body, snapshot = avatarMutationSnapshot(rest); deadline.check();
    return Response.json({ protocolVersion, ...snapshot }, { headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });
  } catch { throw new AvatarIntakeError("AVATAR_RESPONSE"); }
  finally { bytes?.fill(0); if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
}
