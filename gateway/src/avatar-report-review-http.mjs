import { avatarHTTPManifest } from "./gateway-avatar-http.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { communityText } from "./community-domain.mjs";
import { AvatarReportReviewError } from "./avatar-report-review-state.mjs";

const fail = code => { throw new AvatarReportReviewError(code); };
const exact = (value, keys) => plain(value) && Object.keys(value).sort().join() === [...keys].sort().join();
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const reportID = value => typeof value === "string" && /^community-v1-avatarreport-[a-f0-9]{64}$/.test(value);
const verdict = value => ["dismiss", "hide_photo"].includes(value);
const time = value => Number.isSafeInteger(value) && value >= 0;
const text = (value, maximum) => { try { return communityText(value, maximum) === value && [...value].every(c => c.codePointAt(0) < 0xd800 || c.codePointAt(0) > 0xdfff); } catch { return false; } };
export const avatarReportReviewPaths = new Map(["queue", "inspect", "decide", "recover", "retire"].map(action => ["/v1/moderation/avatar-reports/" + action, action]));
export function avatarReportReviewers(json = "[]") {
  try {
    if (typeof json !== "string" || json.length > 2048) fail("AVATAR_REPORT_REVIEW_INPUT");
    const values = JSON.parse(json);
    if (!Array.isArray(values) || values.length > 16 || values.some(value => !id(value)) || new Set(values).size !== values.length) fail("AVATAR_REPORT_REVIEW_INPUT");
    return Object.freeze(values.slice().sort());
  } catch { fail("AVATAR_REPORT_REVIEW_INPUT"); }
}
export function avatarReportReviewInput(action, value) {
  const keys = { queue: ["after"], inspect: ["reportID"], decide: ["inspectionID", "decisionID", "verdict"], recover: ["reportID", "decisionID", "verdict", "contentHash"], retire: ["reportID", "decisionID", "verdict", "contentHash"] }[action];
  if (!keys || !exact(value, keys) || action === "queue" && value.after !== null && !reportID(value.after) ||
      keys.includes("reportID") && !reportID(value.reportID) || keys.includes("inspectionID") && !id(value.inspectionID) ||
      keys.includes("decisionID") && !id(value.decisionID) || keys.includes("verdict") && !verdict(value.verdict) ||
      keys.includes("contentHash") && !hash(value.contentHash)) fail("AVATAR_REPORT_REVIEW_INPUT");
  return Object.freeze({ ...value });
}
export function avatarReportReviewHeaders(request) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get("Content-Type") ?? "") ||
      request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity") fail("AVATAR_REPORT_REVIEW_INPUT");
  for (const name of ["Range", "If-None-Match", "If-Modified-Since", "X-Echoes-Avatar-Intent", "X-Echoes-Avatar-Manifest", "X-Echoes-Avatar-Review", "X-Echoes-Avatar-Report-Review"]) if (request.headers.has(name)) fail("AVATAR_REPORT_REVIEW_INPUT");
  const auth = request.headers.get("Authorization"), length = request.headers.get("Content-Length");
  if (typeof auth !== "string" || auth.length !== 87 || !auth.startsWith("Bearer ") || !id(auth.slice(7, 43)) || !/^\.[A-Za-z0-9_-]{43}$/.test(auth.slice(43))) fail("AVATAR_REPORT_REVIEW_SCOPE");
  if (length !== null && (!/^[1-9]\d{0,2}$/.test(length) || Number(length) > 512)) fail("AVATAR_REPORT_REVIEW_INPUT");
  return { accessToken: auth.slice(7), maximum: 512, length: length === null ? null : Number(length) };
}
export function avatarReportReviewResult(action, value, input, now = Date.now()) {
  if (!time(now) || !plain(value) || value.schemaVersion !== 1) fail("AVATAR_REPORT_REVIEW_RESPONSE");
  const dates = (item, lifetime) => time(item.createdAt) && item.createdAt <= now && time(item.expiresAt) && item.expiresAt > now && item.expiresAt - item.createdAt === lifetime;
  if (action === "queue") {
    if (!exact(value, ["schemaVersion", "items", "after"]) || !Array.isArray(value.items) || value.items.length > 20 || value.after !== null && !reportID(value.after)) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    let previous = input?.after ?? "";
    for (const item of value.items) {
      if (!exact(item, ["reportID", "createdAt", "expiresAt"]) || !reportID(item.reportID) || item.reportID <= previous || !dates(item, 2592000000)) fail("AVATAR_REPORT_REVIEW_RESPONSE");
      previous = item.reportID;
    }
    if (value.after !== null && (value.after < previous || input?.after && value.after <= input.after)) fail("AVATAR_REPORT_REVIEW_RESPONSE");
  } else if (action === "inspect") {
    if (!exact(value, ["schemaVersion", "inspectionID", "inspectionExpiresAt", "contentHash", "reportID", "createdAt", "expiresAt", "reason", "photo"]) ||
        !id(value.inspectionID) || !hash(value.contentHash) || !reportID(value.reportID) || !dates(value, 2592000000) ||
        !time(value.inspectionExpiresAt) || value.inspectionExpiresAt <= now || value.inspectionExpiresAt > now + 90000 || value.inspectionExpiresAt > value.expiresAt ||
        !text(value.reason, 500) || input && input.reportID !== value.reportID) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    if (value.photo !== null) {
      const photo = value.photo;
      if (!exact(photo, ["ownerID", "versionID", "publicationGeneration", "manifest"]) || !id(photo.ownerID) || !id(photo.versionID) ||
          !Number.isSafeInteger(photo.publicationGeneration) || photo.publicationGeneration < 1 || photo.publicationGeneration >= Number.MAX_SAFE_INTEGER) fail("AVATAR_REPORT_REVIEW_RESPONSE");
      let manifest; try { manifest = avatarHTTPManifest(JSON.stringify(photo.manifest)); } catch { fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
      if (manifest.variant !== "image" || manifest.ownerID !== photo.ownerID || manifest.versionID !== photo.versionID) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    }
  } else {
    const keys = ["schemaVersion", "reportID", "decisionID", "verdict", "contentHash", "revision", action === "decide" ? "inspectionID" : "outcome"];
    if (!["decide", "recover", "retire"].includes(action) || !exact(value, keys) || !reportID(value.reportID) || !id(value.decisionID) || !verdict(value.verdict) || !hash(value.contentHash) ||
        action === "decide" && (!id(value.inspectionID) || !id(value.revision)) ||
        ["recover", "retire"].includes(action) && (!(action === "retire" ? ["retired", "confirmed", "superseded"] : ["confirmed", "not-applied", "superseded", "retired"]).includes(value.outcome) || (value.outcome === "confirmed" ? !id(value.revision) : value.revision !== null))) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    if (input && Object.keys(input).some(key => value[key] !== input[key])) fail("AVATAR_REPORT_REVIEW_RESPONSE");
  }
  return Object.freeze(structuredClone(value));
}
export function avatarReportReviewDeadline(signal, milliseconds = 12000) {
  if (!Number.isInteger(milliseconds) || milliseconds < 1 || milliseconds > 15000) fail("AVATAR_REPORT_REVIEW_INPUT");
  const controller = new AbortController(), started = Date.now(), mono = performance.now(); let closed = false, reject;
  if (!Number.isSafeInteger(started) || started < 0 || !Number.isFinite(mono) || mono < 0) fail();
  let wallFloor = started, monoFloor = mono;
  const stopped = new Promise((_, fail) => { reject = fail; }); void stopped.catch(() => {});
  const cancel = () => { if (!closed) { controller.abort(); reject(new AvatarReportReviewError()); } };
  if (signal?.aborted) cancel(); else signal?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(cancel, milliseconds);
  const check = () => {
    const wall = Date.now(), tick = performance.now();
    if (closed || controller.signal.aborted || signal?.aborted || !Number.isSafeInteger(wall) || wall < wallFloor || !Number.isFinite(tick) || tick < monoFloor ||
        wall - started >= milliseconds || tick - mono >= milliseconds) fail();
    wallFloor = wall; monoFloor = tick;
  };
  return { signal: controller.signal, check, async run(task) {
    check(); const value = await Promise.race([Promise.resolve().then(() => { check(); return task(); }), stopped]); check(); return value;
  }, close() { closed = true; clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", cancel); } };
}
/** One retained operation. Failed/unconfirmed stream cancellation poisons this gate until instance restart. */
export function avatarReportReviewAdmission() {
  let occupied = false;
  return () => {
    if (occupied) fail("AVATAR_REPORT_REVIEW_CAPACITY"); occupied = true;
    let closed = false, released = false, poisoned = false; const pending = new Set();
    const release = () => { if (closed && !pending.size && !released && !poisoned) { released = true; occupied = false; } };
    const cancelBody = body => {
      if (!body) return;
      try {
        if (body.locked) { poisoned = true; return; }
        const cancel = body.cancel(); pending.add(cancel);
        void cancel.then(() => { pending.delete(cancel); release(); }, () => { poisoned = true; });
      } catch { poisoned = true; }
    };
    return { poison() { poisoned = true; }, cancelBody, async run(deadline, task) {
      if (closed) fail(); deadline.check();
      const actual = Promise.resolve().then(() => { deadline.check(); return task(); }); pending.add(actual);
      const settled = value => { pending.delete(actual); if (closed && value instanceof Response) cancelBody(value.body); release(); };
      void actual.then(settled, () => settled());
      return deadline.run(() => actual);
    }, close() { closed = true; release(); } };
  };
}
export async function avatarReportReviewBody(source, { maximum, length }, deadline, poison, code = "AVATAR_REPORT_REVIEW_INPUT") {
  if (!source.body) fail(code);
  let reader; try { reader = source.body.getReader(); } catch { poison(); fail(code); }
  const chunks = []; let total = 0;
  try {
    while (true) {
      const { value, done } = await deadline.run(() => reader.read()); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || chunks.length >= 128 || (total += value.byteLength) > maximum) fail(code);
      chunks.push(value.slice());
    }
    if (!total || length !== null && total !== length) fail(code);
    const bytes = new Uint8Array(total); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
    finally { bytes.fill(0); }
  } catch (error) { throw error instanceof AvatarReportReviewError ? error : new AvatarReportReviewError(code); }
  finally {
    let failed = false;
    try { await reader.cancel(); } catch { poison(); failed = true; }
    try { reader.releaseLock(); } catch { poison(); failed = true; }
    for (const chunk of chunks) chunk.fill(0);
    if (failed) fail(code);
  }
}
export async function avatarReportReviewReadInput(request, headers, deadline, admission, milliseconds = 3000) {
  const inputDeadline = avatarReportReviewDeadline(deadline.signal, milliseconds);
  try { return await admission.run(deadline, () => avatarReportReviewBody(request, headers, inputDeadline, () => admission.poison())); }
  finally { inputDeadline.close(); }
}
export const avatarReportReviewErrorStatuses = Object.freeze({ AVATAR_REPORT_REVIEW_INPUT: 400, AVATAR_REPORT_REVIEW_SCOPE: 403, AVATAR_REPORT_REVIEW_STALE: 409,
  AVATAR_REPORT_REVIEW_CAPACITY: 429, AVATAR_REPORT_REVIEW_RESPONSE: 503, AVATAR_REPORT_REVIEW_UNAVAILABLE: 503,
  INVALID_REQUEST: 400, HTTPS_REQUIRED: 400, NOT_FOUND: 404, METHOD_NOT_ALLOWED: 405, ORIGIN_NOT_ALLOWED: 403,
  INVALID_SESSION: 401, ACCOUNT_DISABLED: 403, DELETION_IN_PROGRESS: 403, FEATURE_DISABLED: 503, GATEWAY_DISABLED: 503,
  RATE_LIMITED: 429, CAPACITY_LIMITED: 503, LIMIT_UNAVAILABLE: 503, UNAVAILABLE: 503 });
export async function avatarReportReviewEdgeResponse(response, action, input, deadline, admission, clock = Date.now) {
  try {
    if (action === "inspect" && response instanceof Response && response.status === 200) {
      if (response.redirected || response.headers.get("Content-Type") !== avatarReportReviewInspectionType ||
          response.headers.get("Cache-Control") !== "private, no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff" ||
          response.headers.has("Content-Range") || response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity") fail("AVATAR_REPORT_REVIEW_RESPONSE");
      const rawLength = response.headers.get("Content-Length");
      if (!/^[1-9]\d{0,5}$/.test(rawLength ?? "") || Number(rawLength) > avatarReportReviewInspectionMaximum) fail("AVATAR_REPORT_REVIEW_RESPONSE");
      const bytes = await avatarReportReviewRawBody(response, { maximum: avatarReportReviewInspectionMaximum, length: Number(rawLength) }, deadline, () => admission.poison());
      try { return encodeAvatarReportReviewInspection(decodeAvatarReportReviewInspection(bytes, input, clock()), input, clock()); }
      finally { bytes.fill(0); }
    }
    if (!(response instanceof Response) || response.redirected || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff") fail("AVATAR_REPORT_REVIEW_RESPONSE");
    const maximum = response.status === 200 ? action === "inspect" ? 12288 : action === "queue" ? 8192 : 2048 : 2048;
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^[1-9]\d{0,5}$/.test(length) || Number(length) > maximum)) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    const body = await avatarReportReviewBody(response, { maximum, length: length === null ? null : Number(length) }, deadline, () => admission.poison(), "AVATAR_REPORT_REVIEW_RESPONSE");
    if (!plain(body) || body.protocolVersion !== 1) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    let result, headers = { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" };
    if (response.status === 200) { const { protocolVersion, ...value } = body; result = { protocolVersion, ...avatarReportReviewResult(action, value, input, clock()) }; }
    else {
      if (!exact(body, ["protocolVersion", "error"]) || avatarReportReviewErrorStatuses[body.error] !== response.status) fail("AVATAR_REPORT_REVIEW_RESPONSE");
      result = body; const retry = response.headers.get("Retry-After");
      if (/^\d{1,6}$/.test(retry ?? "") && Number(retry) <= 86400) headers["Retry-After"] = retry;
      if (response.status === 405) headers.Allow = "POST";
    }
    deadline.check(); return Response.json(result, { status: response.status, headers });
  } catch (error) {
    if (response instanceof Response && response.body) {
      if (response.body.locked) admission.poison();
      else try { await response.body.cancel(); } catch { admission.poison(); }
    }
    throw error instanceof AvatarReportReviewError ? error : new AvatarReportReviewError("AVATAR_REPORT_REVIEW_RESPONSE");
  }
}


export const avatarReportReviewInspectionType = "application/vnd.echoes.avatar-report-inspection.v1";
export const avatarReportReviewInspectionMaximum = 4 + 12288 + 256000;
function checkedInspectionImage(metadata, bytes) {
  if (metadata.photo === null) { if (bytes !== null) fail("AVATAR_REPORT_REVIEW_RESPONSE"); return; }
  const manifest = metadata.photo.manifest;
  if (!(bytes instanceof Uint8Array) || bytes.byteLength !== manifest.byteCount || digest(bytes) !== manifest.sha256) fail("AVATAR_REPORT_REVIEW_RESPONSE");
  const decoded = inspectAvatarJPEG(bytes, { maximumBytes: 256000, maximumPixels: 512 });
  try { if (decoded.width !== manifest.width || decoded.height !== manifest.height || digest(decoded.bytes) !== manifest.sha256) fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
  finally { decoded.bytes.fill(0); }
}
/** Consumes the trusted coordinator image copy even on validation/serialization failure. */
export function encodeAvatarReportReviewInspection(value, input, now = Date.now()) {
  let json, bytes;
  try {
    if (!exact(value, ["metadata", "image"])) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    const metadata = avatarReportReviewResult("inspect", value.metadata, input, now); checkedInspectionImage(metadata, value.image);
    json = new TextEncoder().encode(JSON.stringify({ protocolVersion: 1, ...metadata }));
    if (json.byteLength < 1 || json.byteLength > 12288) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    bytes = new Uint8Array(4 + json.byteLength + (value.image?.byteLength ?? 0));
    new DataView(bytes.buffer).setUint32(0, json.byteLength, false); bytes.set(json, 4); if (value.image) bytes.set(value.image, 4 + json.byteLength);
    return new Response(bytes, { status: 200, headers: { "Content-Type": avatarReportReviewInspectionType, "Content-Length": String(bytes.byteLength),
      "Cache-Control": "private, no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });
  } catch { fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
  finally { if (value?.image instanceof Uint8Array) value.image.fill(0); json?.fill(0); bytes?.fill(0); }
}
/** Validates the complete bounded frame before returning any reason or pixels. Caller owns returned copy. */
export function decodeAvatarReportReviewInspection(bytes, input, now = Date.now()) {
  try {
    if (!(bytes instanceof Uint8Array) || bytes.byteLength < 6 || bytes.byteLength > avatarReportReviewInspectionMaximum) fail();
    const length = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(0, false);
    if (length < 1 || length > 12288 || 4 + length > bytes.byteLength) fail();
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(4, 4 + length)));
    if (!plain(body) || body.protocolVersion !== 1) fail();
    const { protocolVersion, ...raw } = body, metadata = avatarReportReviewResult("inspect", raw, input, now);
    const image = metadata.photo === null && bytes.byteLength === 4 + length ? null : bytes.subarray(4 + length);
    checkedInspectionImage(metadata, image); return Object.freeze({ metadata, image: image?.slice() ?? null });
  } catch { fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
}
async function avatarReportReviewRawBody(source, { maximum, length }, deadline, poison) {
  if (!source.body) fail("AVATAR_REPORT_REVIEW_RESPONSE");
  let reader; try { reader = source.body.getReader(); } catch { poison(); fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
  const chunks = []; let total = 0, bytes;
  try {
    while (true) {
      const { value, done } = await deadline.run(() => reader.read()); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || chunks.length >= 128 || (total += value.byteLength) > maximum) fail("AVATAR_REPORT_REVIEW_RESPONSE");
      chunks.push(value.slice());
    }
    if (!total || total !== length) fail("AVATAR_REPORT_REVIEW_RESPONSE");
    bytes = new Uint8Array(total); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  } catch { bytes?.fill(0); fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
  finally {
    let failed = false; try { await reader.cancel(); } catch { poison(); failed = true; }
    try { reader.releaseLock(); } catch { poison(); failed = true; }
    for (const chunk of chunks) chunk.fill(0);
    if (failed) { bytes?.fill(0); fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
  }
}
