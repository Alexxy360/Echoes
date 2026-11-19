import { plain, publicUUID } from "./public-record-schema.mjs";
import { communityText } from "./community-domain.mjs";
import { CommunityReportReviewError } from "./community-report-review-state.mjs";

const fail = code => { throw new CommunityReportReviewError(code); };
const exact = (value, keys) => plain(value) && Object.keys(value).sort().join() === [...keys].sort().join();
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const reportID = value => typeof value === "string" && /^community-v1-report-[a-f0-9]{64}$/.test(value);
const messageID = value => typeof value === "string" && /^community-v1-message-[a-f0-9]{64}$/.test(value);
const verdict = value => ["dismiss", "hide_message"].includes(value);
const time = value => Number.isSafeInteger(value) && value >= 0;
const text = (value, maximum) => { try { return communityText(value, maximum) === value; } catch { return false; } };
export const reportReviewPaths = new Map(["queue", "inspect", "decide", "recover"].map(action => ["/v1/moderation/reports/" + action, action]));
export function reportReviewers(json = "[]") {
  try {
    if (typeof json !== "string" || json.length > 2048) fail("REPORT_REVIEW_INPUT");
    const values = JSON.parse(json);
    if (!Array.isArray(values) || values.length > 16 || values.some(value => !id(value)) || new Set(values).size !== values.length) fail("REPORT_REVIEW_INPUT");
    return Object.freeze(values.slice().sort());
  } catch { fail("REPORT_REVIEW_INPUT"); }
}
export function reportReviewInput(action, value) {
  const keys = { queue: ["after"], inspect: ["reportID"], decide: ["inspectionID", "decisionID", "verdict"], recover: ["reportID", "decisionID", "verdict", "contentHash"] }[action];
  if (!keys || !exact(value, keys) || action === "queue" && value.after !== null && !reportID(value.after) ||
      keys.includes("reportID") && !reportID(value.reportID) || keys.includes("inspectionID") && !id(value.inspectionID) ||
      keys.includes("decisionID") && !id(value.decisionID) || keys.includes("verdict") && !verdict(value.verdict) ||
      keys.includes("contentHash") && !hash(value.contentHash)) fail("REPORT_REVIEW_INPUT");
  return Object.freeze({ ...value });
}
export function reportReviewHeaders(request) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get("Content-Type") ?? "") ||
      request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity") fail("REPORT_REVIEW_INPUT");
  for (const name of ["Range", "If-None-Match", "If-Modified-Since", "X-Echoes-Avatar-Intent", "X-Echoes-Avatar-Manifest", "X-Echoes-Avatar-Review"]) if (request.headers.has(name)) fail("REPORT_REVIEW_INPUT");
  const auth = request.headers.get("Authorization"), length = request.headers.get("Content-Length");
  if (typeof auth !== "string" || auth.length !== 87 || !auth.startsWith("Bearer ") || !id(auth.slice(7, 43)) || !/^\.[A-Za-z0-9_-]{43}$/.test(auth.slice(43))) fail("REPORT_REVIEW_SCOPE");
  if (length !== null && (!/^[1-9]\d{0,2}$/.test(length) || Number(length) > 512)) fail("REPORT_REVIEW_INPUT");
  return { accessToken: auth.slice(7), maximum: 512, length: length === null ? null : Number(length) };
}
export function reportReviewResult(action, value, input, now = Date.now()) {
  if (!time(now) || !plain(value) || value.schemaVersion !== 1) fail("REPORT_REVIEW_RESPONSE");
  const dates = (item, lifetime) => time(item.createdAt) && item.createdAt <= now && time(item.expiresAt) && item.expiresAt > now && item.expiresAt - item.createdAt === lifetime;
  if (action === "queue") {
    if (!exact(value, ["schemaVersion", "items", "after"]) || !Array.isArray(value.items) || value.items.length > 20 || value.after !== null && !reportID(value.after)) fail("REPORT_REVIEW_RESPONSE");
    let previous = input?.after ?? "";
    for (const item of value.items) {
      if (!exact(item, ["reportID", "createdAt", "expiresAt"]) || !reportID(item.reportID) || item.reportID <= previous || !dates(item, 2592000000)) fail("REPORT_REVIEW_RESPONSE");
      previous = item.reportID;
    }
    if (value.after !== null && (value.after < previous || input?.after && value.after <= input.after)) fail("REPORT_REVIEW_RESPONSE");
  } else if (action === "inspect") {
    if (!exact(value, ["schemaVersion", "inspectionID", "inspectionExpiresAt", "contentHash", "reportID", "createdAt", "expiresAt", "reason", "messageID", "message"]) ||
        !id(value.inspectionID) || !hash(value.contentHash) || !reportID(value.reportID) || !messageID(value.messageID) || !dates(value, 2592000000) ||
        !time(value.inspectionExpiresAt) || value.inspectionExpiresAt <= now || value.inspectionExpiresAt > now + 90000 || value.inspectionExpiresAt > value.expiresAt ||
        !text(value.reason, 500) || input && input.reportID !== value.reportID) fail("REPORT_REVIEW_RESPONSE");
    if (value.message !== null && (!exact(value.message, ["authorID", "name", "text", "createdAt", "expiresAt"]) ||
        !id(value.message.authorID) || !text(value.message.name, 40) || !text(value.message.text, 500) || !dates(value.message, 7200000))) fail("REPORT_REVIEW_RESPONSE");
  } else {
    const keys = ["schemaVersion", "reportID", "decisionID", "verdict", "contentHash", "revision", action === "decide" ? "inspectionID" : "outcome"];
    if (!["decide", "recover"].includes(action) || !exact(value, keys) || !reportID(value.reportID) || !id(value.decisionID) || !verdict(value.verdict) || !hash(value.contentHash) ||
        action === "decide" && (!id(value.inspectionID) || !id(value.revision)) ||
        action === "recover" && (!["confirmed", "not-applied", "superseded"].includes(value.outcome) || (value.outcome === "confirmed" ? !id(value.revision) : value.revision !== null))) fail("REPORT_REVIEW_RESPONSE");
    if (input && Object.keys(input).some(key => value[key] !== input[key])) fail("REPORT_REVIEW_RESPONSE");
  }
  return Object.freeze(structuredClone(value));
}
export function reportReviewDeadline(signal, milliseconds = 12000) {
  if (!Number.isInteger(milliseconds) || milliseconds < 1 || milliseconds > 15000) fail("REPORT_REVIEW_INPUT");
  const controller = new AbortController(), started = Date.now(), mono = performance.now(); let closed = false, reject;
  const stopped = new Promise((_, fail) => { reject = fail; }); void stopped.catch(() => {});
  const cancel = () => { if (!closed) { controller.abort(); reject(new CommunityReportReviewError()); } };
  if (signal?.aborted) cancel(); else signal?.addEventListener("abort", cancel, { once: true });
  const timer = setTimeout(cancel, milliseconds);
  const check = () => { if (closed || controller.signal.aborted || signal?.aborted || Date.now() < started || performance.now() < mono ||
    Date.now() - started >= milliseconds || performance.now() - mono >= milliseconds) fail(); };
  return { signal: controller.signal, check, async run(task) {
    check(); const value = await Promise.race([Promise.resolve().then(() => { check(); return task(); }), stopped]); check(); return value;
  }, close() { closed = true; clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", cancel); } };
}
/** One retained operation. Failed/unconfirmed stream cancellation poisons this gate until instance restart. */
export function reportReviewAdmission() {
  let occupied = false;
  return () => {
    if (occupied) fail("REPORT_REVIEW_CAPACITY"); occupied = true;
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
export async function reportReviewBody(source, { maximum, length }, deadline, poison, code = "REPORT_REVIEW_INPUT") {
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
  } catch (error) { throw error instanceof CommunityReportReviewError ? error : new CommunityReportReviewError(code); }
  finally {
    let failed = false;
    try { await reader.cancel(); } catch { poison(); failed = true; }
    try { reader.releaseLock(); } catch { poison(); failed = true; }
    for (const chunk of chunks) chunk.fill(0);
    if (failed) fail(code);
  }
}
export async function reportReviewReadInput(request, headers, deadline, admission, milliseconds = 3000) {
  const inputDeadline = reportReviewDeadline(deadline.signal, milliseconds);
  try { return await admission.run(deadline, () => reportReviewBody(request, headers, inputDeadline, () => admission.poison())); }
  finally { inputDeadline.close(); }
}
export const reportReviewErrorStatuses = Object.freeze({ REPORT_REVIEW_INPUT: 400, REPORT_REVIEW_SCOPE: 403, REPORT_REVIEW_STALE: 409,
  REPORT_REVIEW_CAPACITY: 429, REPORT_REVIEW_RESPONSE: 503, REPORT_REVIEW_UNAVAILABLE: 503,
  INVALID_REQUEST: 400, HTTPS_REQUIRED: 400, NOT_FOUND: 404, METHOD_NOT_ALLOWED: 405, ORIGIN_NOT_ALLOWED: 403,
  INVALID_SESSION: 401, ACCOUNT_DISABLED: 403, DELETION_IN_PROGRESS: 403, FEATURE_DISABLED: 503, GATEWAY_DISABLED: 503,
  RATE_LIMITED: 429, CAPACITY_LIMITED: 503, LIMIT_UNAVAILABLE: 503, UNAVAILABLE: 503 });
export async function reportReviewEdgeResponse(response, action, input, deadline, admission, clock = Date.now) {
  try {
    if (!(response instanceof Response) || response.redirected || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff") fail("REPORT_REVIEW_RESPONSE");
    const maximum = response.status === 200 ? action === "inspect" ? 12288 : action === "queue" ? 8192 : 2048 : 2048;
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^[1-9]\d{0,5}$/.test(length) || Number(length) > maximum)) fail("REPORT_REVIEW_RESPONSE");
    const body = await reportReviewBody(response, { maximum, length: length === null ? null : Number(length) }, deadline, () => admission.poison(), "REPORT_REVIEW_RESPONSE");
    if (!plain(body) || body.protocolVersion !== 1) fail("REPORT_REVIEW_RESPONSE");
    let result, headers = { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" };
    if (response.status === 200) { const { protocolVersion, ...value } = body; result = { protocolVersion, ...reportReviewResult(action, value, input, clock()) }; }
    else {
      if (!exact(body, ["protocolVersion", "error"]) || reportReviewErrorStatuses[body.error] !== response.status) fail("REPORT_REVIEW_RESPONSE");
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
    throw error instanceof CommunityReportReviewError ? error : new CommunityReportReviewError("REPORT_REVIEW_RESPONSE");
  }
}
