import { publicUUID } from "./public-record-schema.mjs";
import { AvatarReportReviewError } from "./avatar-report-review-state.mjs";
import { avatarReportReviewAdmission, avatarReportReviewDeadline, avatarReportReviewHeaders, avatarReportReviewReadInput, avatarReportReviewInput, avatarReportReviewResult, encodeAvatarReportReviewInspection } from "./avatar-report-review-http.mjs";

const fail = code => { throw new AvatarReportReviewError(code); };
const sync = (value, code) => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail(code); } return value; };
const response = (value, status = 200) => Response.json({ protocolVersion: 1, ...value }, { status,
  headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });

/** Closed native moderation HTTP. Authority alone resolves session and separate report operator role. */
export function createAvatarReportReviewHandler({ authentication, limits, checkpoint, avatarReportReview, isEnabled,
  isAvatarReportReviewEnabled, isAvatarReportReviewer, scheduleMaintenance, clock = Date.now, avatarReportReviewTimeoutMilliseconds = 12000, inputTimeoutMilliseconds = 3000 } = {}) {
  if ([isAvatarReportReviewEnabled, isAvatarReportReviewer, clock].some(value => typeof value !== "function") ||
      !Number.isInteger(avatarReportReviewTimeoutMilliseconds) || avatarReportReviewTimeoutMilliseconds < 1 || avatarReportReviewTimeoutMilliseconds > 12000) throw new Error("Report review configuration unavailable.");
  const claim = avatarReportReviewAdmission();
  return async (request, budget, action) => {
    let admission, deadline;
    try {
      const method = { queue: "prepareQueue", inspect: "prepareInspection", decide: "prepareDecision", recover: "prepareRecovery", retire: "prepareRetirement" }[action];
      const flag = fn => { try { return sync(fn()) === true; } catch { return false; } };
      const enabled = () => flag(isEnabled) && flag(isAvatarReportReviewEnabled);
      if (!enabled() || typeof avatarReportReview?.[method] !== "function" || typeof avatarReportReview?.waitForPendingOperations !== "function" || typeof limits.consumeAvatarReportReview !== "function") return response({ error: "FEATURE_DISABLED" }, 503);
      admission = claim(); deadline = avatarReportReviewDeadline(request.signal, avatarReportReviewTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (!enabled()) fail(); };
      await awaited(() => limits.consume(budget, { heavy: true })); check();
      const headers = avatarReportReviewHeaders(request);
      const authorize = expected => {
        check(); let identity;
        try { identity = sync(authentication.authorize(headers.accessToken), "AVATAR_REPORT_REVIEW_SCOPE"); } catch { fail("AVATAR_REPORT_REVIEW_SCOPE"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) fail("AVATAR_REPORT_REVIEW_SCOPE");
        let role; try { role = sync(isAvatarReportReviewer(identity.accountID), "AVATAR_REPORT_REVIEW_SCOPE"); } catch { fail("AVATAR_REPORT_REVIEW_SCOPE"); }
        if (role !== true) fail("AVATAR_REPORT_REVIEW_SCOPE"); check(); return identity.accountID;
      };
      const operatorID = authorize();
      await awaited(() => limits.consumeAvatarReportReview(operatorID, { inspection: action === "inspect" })); authorize(operatorID);
      const input = avatarReportReviewInput(action, await avatarReportReviewReadInput(request, headers, deadline, admission, inputTimeoutMilliseconds)); authorize(operatorID);
      await awaited(() => scheduleMaintenance()); authorize(operatorID);
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); authorize(operatorID);
      let final;
      try { final = await awaited(async () => {
        try { return await avatarReportReview[method]({ ...input, accessToken: headers.accessToken, signal: deadline.signal }); }
        finally { await avatarReportReview.waitForPendingOperations(); }
      }); } catch (error) { authorize(operatorID); await awaited(() => checkpoint?.advance({ signal: deadline.signal })); throw error; }
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); authorize(operatorID);
      if (typeof final !== "function") fail("AVATAR_REPORT_REVIEW_RESPONSE");
      const value = sync(final(), "AVATAR_REPORT_REVIEW_RESPONSE");
      if (action === "inspect") {
        let result;
        try { authorize(operatorID); result = encodeAvatarReportReviewInspection(value, input, clock()); authorize(operatorID); return result; }
        catch (error) { if (result) admission.cancelBody(result.body); throw error; }
        finally { if (value?.image instanceof Uint8Array) value.image.fill(0); }
      }
      const result = avatarReportReviewResult(action, value, input, clock());
      authorize(operatorID); return response(result);
    } finally {
      // A parsing reader owns its tracked cancellation. Early rejections retain cancellation separately.
      if (admission && request.body && !request.body.locked) admission.cancelBody(request.body);
      deadline?.close(); admission?.close();
    }
  };
}
