import { publicUUID } from "./public-record-schema.mjs";
import { CommunityReportReviewError } from "./community-report-review-state.mjs";
import { reportReviewAdmission, reportReviewDeadline, reportReviewHeaders, reportReviewReadInput, reportReviewInput, reportReviewResult } from "./report-review-http.mjs";

const fail = code => { throw new CommunityReportReviewError(code); };
const sync = (value, code) => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail(code); } return value; };
const response = (value, status = 200) => Response.json({ protocolVersion: 1, ...value }, { status,
  headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });

/** Closed native moderation HTTP. Authority alone resolves session and separate report operator role. */
export function createReportReviewHandler({ authentication, limits, checkpoint, reportReview, isEnabled,
  isReportReviewEnabled, isReportReviewer, scheduleMaintenance, clock = Date.now, reportTimeoutMilliseconds = 12000, inputTimeoutMilliseconds = 3000 } = {}) {
  if ([isReportReviewEnabled, isReportReviewer, clock].some(value => typeof value !== "function") ||
      !Number.isInteger(reportTimeoutMilliseconds) || reportTimeoutMilliseconds < 1 || reportTimeoutMilliseconds > 12000) throw new Error("Report review configuration unavailable.");
  const claim = reportReviewAdmission();
  return async (request, budget, action) => {
    let admission, deadline;
    try {
      const method = { queue: "prepareQueue", inspect: "prepareInspection", decide: "prepareDecision", recover: "prepareRecovery" }[action];
      const flag = fn => { try { return sync(fn()) === true; } catch { return false; } };
      const enabled = () => flag(isEnabled) && flag(isReportReviewEnabled);
      if (!enabled() || typeof reportReview?.[method] !== "function" || typeof reportReview?.waitForPendingOperations !== "function" || typeof limits.consumeReportReview !== "function") return response({ error: "FEATURE_DISABLED" }, 503);
      admission = claim(); deadline = reportReviewDeadline(request.signal, reportTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (!enabled()) fail(); };
      await awaited(() => limits.consume(budget, { heavy: true })); check();
      const headers = reportReviewHeaders(request);
      const authorize = expected => {
        check(); let identity;
        try { identity = sync(authentication.authorize(headers.accessToken), "REPORT_REVIEW_SCOPE"); } catch { fail("REPORT_REVIEW_SCOPE"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) fail("REPORT_REVIEW_SCOPE");
        let role; try { role = sync(isReportReviewer(identity.accountID), "REPORT_REVIEW_SCOPE"); } catch { fail("REPORT_REVIEW_SCOPE"); }
        if (role !== true) fail("REPORT_REVIEW_SCOPE"); check(); return identity.accountID;
      };
      const operatorID = authorize();
      await awaited(() => limits.consumeReportReview(operatorID, { inspection: action === "inspect" })); authorize(operatorID);
      const input = reportReviewInput(action, await reportReviewReadInput(request, headers, deadline, admission, inputTimeoutMilliseconds)); authorize(operatorID);
      await awaited(() => scheduleMaintenance()); authorize(operatorID);
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); authorize(operatorID);
      let final;
      try { final = await awaited(async () => {
        try { return await reportReview[method]({ ...input, accessToken: headers.accessToken, signal: deadline.signal }); }
        finally { await reportReview.waitForPendingOperations(); }
      }); } catch (error) { authorize(operatorID); await awaited(() => checkpoint?.advance({ signal: deadline.signal })); throw error; }
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); authorize(operatorID);
      if (typeof final !== "function") fail("REPORT_REVIEW_RESPONSE");
      const value = sync(final(), "REPORT_REVIEW_RESPONSE"), result = reportReviewResult(action, value, input, clock());
      authorize(operatorID); return response(result);
    } finally {
      // A parsing reader owns its tracked cancellation. Early rejections retain cancellation separately.
      if (admission && request.body && !request.body.locked) admission.cancelBody(request.body);
      deadline?.close(); admission?.close();
    }
  };
}
