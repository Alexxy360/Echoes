import { publicUUID } from "./public-record-schema.mjs";
import { AvatarReviewError } from "./avatar-review-state.mjs";
import { AvatarIntakeError, avatarMutationBody } from "./avatar-upload-http.mjs";
import { avatarReviewHeaders, avatarReviewInput, avatarReviewResult, avatarReviewImageResponse,
  avatarReviewAdmission, avatarReviewDeadline, reviewTransportError } from "./avatar-review-http.mjs";

export function createAvatarReviewHandler({ authentication, limits, checkpoint, avatarReview, isEnabled,
  isAvatarReviewEnabled, isAvatarReviewer, scheduleMaintenance, clock = Date.now, reviewTimeoutMilliseconds = 12000, inputTimeoutMilliseconds = 3000 } = {}) {
  if (typeof isAvatarReviewEnabled !== "function" || typeof isAvatarReviewer !== "function" || typeof clock !== "function" ||
      !Number.isInteger(reviewTimeoutMilliseconds) || reviewTimeoutMilliseconds < 1 || reviewTimeoutMilliseconds > 12000) throw new Error("Review configuration unavailable.");
  const claim = avatarReviewAdmission();
  return async (request, serverBudgetHash, action) => {
    let admission, deadline, bytes, response;
    try {
      const method = { queue: "prepareQueue", inspect: "prepareInspection", decide: "prepareDecision", recover: "prepareRecovery", retire: "prepareRetirement" }[action];
      const flag = callback => {
        try { const value = callback(); if (value && typeof value.then === "function") { void value.catch?.(() => {}); return false; } return value === true; }
        catch { return false; }
      };
      const enabled = () => flag(isEnabled) && flag(isAvatarReviewEnabled);
      if (!enabled() || typeof avatarReview?.[method] !== "function" || typeof limits.consumeAvatarReview !== "function") throw new AvatarIntakeError("FEATURE_DISABLED");
      admission = claim(); deadline = avatarReviewDeadline(request.signal, reviewTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (!enabled()) throw new AvatarIntakeError("FEATURE_DISABLED"); };
      await awaited(() => limits.consume(serverBudgetHash, { heavy: true })); check();
      const headers = avatarReviewHeaders(request);
      const authorize = expected => {
        check(); let identity;
        try { identity = authentication.authorize(headers.accessToken); }
        catch (e) { if (e?.code === "INVALID_SESSION") throw new AvatarIntakeError("INVALID_SESSION"); throw new AvatarReviewError(); }
        if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarIntakeError("INVALID_SESSION"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && expected !== identity.accountID) throw new AvatarIntakeError("INVALID_SESSION");
        let role; try { role = isAvatarReviewer(identity.accountID); } catch { throw new AvatarReviewError("AVATAR_REVIEW_SCOPE"); }
        if (role && typeof role.then === "function") { void role.catch?.(() => {}); throw new AvatarReviewError("AVATAR_REVIEW_SCOPE"); }
        if (role !== true) throw new AvatarReviewError("AVATAR_REVIEW_SCOPE");
        check(); return identity.accountID;
      };
      const accountID = authorize();
      await awaited(() => limits.consumeAvatarReview(accountID, { inspection: action === "inspect" })); authorize(accountID);
      bytes = await awaited(() => avatarMutationBody(request, headers, deadline.signal, inputTimeoutMilliseconds)); authorize(accountID);
      let input; try { input = avatarReviewInput(action, JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))); }
      catch { throw new AvatarReviewError("AVATAR_REVIEW_INPUT"); }
      await awaited(() => scheduleMaintenance()); authorize(accountID);
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); authorize(accountID);
      let final;
      try { final = await awaited(() => avatarReview[method]({ ...input, accessToken: headers.accessToken, signal: deadline.signal })); }
      catch (e) { authorize(accountID); await awaited(() => checkpoint?.advance({ signal: deadline.signal })); throw e; }
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); authorize(accountID);
      if (typeof final !== "function") throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
      const value = final();
      if (value && typeof value.then === "function") { void value.then(v => v?.body?.cancel().catch(() => {})).catch(() => {}); throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE"); }
      if (action === "inspect") {
        response = value; const result = await awaited(() => avatarReviewImageResponse(response, deadline, { input, clock }));
        try { authorize(accountID); return result; } catch (e) { void result.body?.cancel().catch(() => {}); throw e; }
      }
      const result = avatarReviewResult(action, value, input); authorize(accountID);
      return Response.json({ protocolVersion: 1, ...result }, { headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });
    } catch (e) { throw reviewTransportError(e); }
    finally {
      bytes?.fill(0); deadline?.close(); admission?.close();
      if (request.body && !request.body.locked) void request.body.cancel().catch(() => {});
      if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
    }
  };
}
