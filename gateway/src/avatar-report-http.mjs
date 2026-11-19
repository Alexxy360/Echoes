import { plain, publicUUID } from "./public-record-schema.mjs";
import { AvatarReportError, avatarReportInput, avatarReportResult } from "./avatar-report-domain.mjs";
import { reportReviewAdmission, reportReviewDeadline, reportReviewReadInput, reportReviewBody, reportReviewErrorStatuses } from "./report-review-http.mjs";

export { avatarReportInput, avatarReportResult };
export const avatarReportPaths = new Map([["/v1/community/avatar/report", "submit"], ["/v1/community/avatar/report/recover", "recover"]]);
// Reuse only the bounded JSON/IO mechanics, never the moderator authorization or its public codes.
export const avatarReportAdmission = reportReviewAdmission;
export const avatarReportDeadline = reportReviewDeadline;
export const avatarReportReadInput = reportReviewReadInput;
export function avatarReportHTTPError(error) {
  if (error instanceof AvatarReportError) return error;
  const mapped = { REPORT_REVIEW_INPUT: "AVATAR_REPORT_INPUT", REPORT_REVIEW_SCOPE: "AVATAR_REPORT_SCOPE", REPORT_REVIEW_STALE: "AVATAR_REPORT_CONFLICT",
    REPORT_REVIEW_CAPACITY: "AVATAR_REPORT_LIMIT", REPORT_REVIEW_RESPONSE: "AVATAR_REPORT_RESPONSE", REPORT_REVIEW_UNAVAILABLE: "AVATAR_REPORT_UNAVAILABLE" }[error?.code];
  return mapped ? new AvatarReportError(mapped) : error;
}
const fail = code => { throw new AvatarReportError(code); };
export function avatarReportHeaders(request) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers.get("Content-Type") ?? "") ||
      request.headers.has("Content-Encoding") && request.headers.get("Content-Encoding") !== "identity") fail("AVATAR_REPORT_INPUT");
  for (const name of ["Range", "If-None-Match", "If-Modified-Since", "X-Echoes-Avatar-Intent", "X-Echoes-Avatar-Manifest", "X-Echoes-Avatar-Selection", "X-Echoes-Avatar-Review"]) if (request.headers.has(name)) fail("AVATAR_REPORT_INPUT");
  const auth = request.headers.get("Authorization"), length = request.headers.get("Content-Length");
  if (typeof auth !== "string" || auth.length !== 87 || !auth.startsWith("Bearer ") || !publicUUID.test(auth.slice(7, 43)) || !/^\.[A-Za-z0-9_-]{43}$/.test(auth.slice(43))) fail("AVATAR_REPORT_SCOPE");
  if (length !== null && (!/^[1-9]\d{0,3}$/.test(length) || Number(length) > 4096)) fail("AVATAR_REPORT_INPUT");
  return { accessToken: auth.slice(7), maximum: 4096, length: length === null ? null : Number(length) };
}
export const avatarReportErrorStatuses = Object.freeze({
  ...Object.fromEntries(Object.entries(reportReviewErrorStatuses).filter(([key]) => !key.startsWith("REPORT_REVIEW_"))),
  AVATAR_REPORT_INPUT: 400, AVATAR_REPORT_SCOPE: 401, AVATAR_REPORT_NOT_FOUND: 404, AVATAR_REPORT_CONFLICT: 409,
  AVATAR_REPORT_LIMIT: 429, AVATAR_REPORT_RESPONSE: 503, AVATAR_REPORT_UNAVAILABLE: 503,
  REAUTH_REQUIRED: 401, PUBLIC_INPUT: 400, PUBLIC_SCOPE: 503, PUBLIC_RESPONSE: 503, PUBLIC_CONFLICT: 409,
  PUBLIC_PENDING: 409, PUBLIC_ERASED: 409, PUBLIC_LIMIT: 429, PUBLIC_THROTTLED: 503, PUBLIC_REGISTRY_UNVERIFIED: 503, PUBLIC_UNAVAILABLE: 503
});
export async function avatarReportEdgeResponse(response, action, input, deadline, admission) {
  try {
    if (!(response instanceof Response) || response.redirected || response.headers.has("Content-Range") ||
        response.headers.has("Content-Encoding") && response.headers.get("Content-Encoding") !== "identity" ||
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(response.headers.get("Content-Type") ?? "") ||
        response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff") fail("AVATAR_REPORT_RESPONSE");
    const rawLength = response.headers.get("Content-Length");
    if (rawLength !== null && (!/^[1-9]\d{0,3}$/.test(rawLength) || Number(rawLength) > 2048)) fail("AVATAR_REPORT_RESPONSE");
    const body = await reportReviewBody(response, { maximum: 2048, length: rawLength === null ? null : Number(rawLength) }, deadline,
      () => admission.poison(), "REPORT_REVIEW_RESPONSE");
    if (!plain(body) || body.protocolVersion !== 1) fail("AVATAR_REPORT_RESPONSE");
    const headers = { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" };
    let result;
    if (response.status === 200) { const { protocolVersion, ...value } = body; result = { protocolVersion, ...avatarReportResult(action, value, input) }; }
    else {
      if (Object.keys(body).sort().join() !== "error,protocolVersion" || avatarReportErrorStatuses[body.error] !== response.status) fail("AVATAR_REPORT_RESPONSE");
      result = body; const retry = response.headers.get("Retry-After");
      if (/^\d{1,6}$/.test(retry ?? "") && Number(retry) <= 86400) headers["Retry-After"] = retry;
      if (response.status === 405) headers.Allow = "POST";
    }
    deadline.check(); return Response.json(result, { status: response.status, headers });
  } catch (error) {
    if (response instanceof Response && response.body) {
      if (response.body.locked) admission.poison(); else try { await response.body.cancel(); } catch { admission.poison(); }
    }
    const mapped = avatarReportHTTPError(error); throw mapped instanceof AvatarReportError ? mapped : new AvatarReportError("AVATAR_REPORT_RESPONSE");
  }
}
