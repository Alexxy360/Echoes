import { AvatarIntakeError, avatarMutationAdmission, avatarMutationBody, avatarMutationDeadline,
  avatarMutationHeaders, avatarMutationInput, avatarMutationSnapshot } from "./avatar-upload-http.mjs";
import { publicUUID } from "./public-record-schema.mjs";

/** Native owner actions only. No action can approve/review content or accept provider metadata. */
export function createAvatarUploadHandler({ authentication, limits, checkpoint, avatarPublication, isEnabled,
  isAvatarUploadEnabled, avatarWithdrawal, isAvatarWithdrawalEnabled, avatarUploadTimeoutMilliseconds = 20000, inputTimeoutMilliseconds = 3000 } = {}) {
  const claim = avatarMutationAdmission();
  if (!Number.isInteger(avatarUploadTimeoutMilliseconds) || avatarUploadTimeoutMilliseconds < 1 || avatarUploadTimeoutMilliseconds > 20000) throw new Error("Photo configuration unavailable.");
  return async (request, serverBudgetHash, action) => {
    let admission, deadline, bytes;
    try {
      const withdrawal = action === "status" || action === "clear", coordinator = withdrawal ? avatarWithdrawal : avatarPublication;
      const featureEnabled = withdrawal ? isAvatarWithdrawalEnabled : isAvatarUploadEnabled;
      const method = { upload: "prepareUpload", recover: "prepareRecovery", publish: "preparePublish", clear: "prepareClear", status: "prepareStatus" }[action];
      if (isEnabled() !== true || featureEnabled() !== true || typeof coordinator?.[method] !== "function" ||
          typeof limits.consumeAvatarMutation !== "function" || typeof authentication.authorize !== "function") throw new AvatarIntakeError("FEATURE_DISABLED");
      admission = claim(action); deadline = avatarMutationDeadline(request.signal, avatarUploadTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (isEnabled() !== true || featureEnabled() !== true) throw new AvatarIntakeError("FEATURE_DISABLED"); };
      await awaited(() => limits.consume(serverBudgetHash, { heavy: true })); check();
      const headers = avatarMutationHeaders(request, action);
      const authorize = () => {
        const identity = authentication.authorize(headers.accessToken);
        if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarIntakeError("INVALID_SESSION"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID)) throw new AvatarIntakeError("INVALID_SESSION");
        return identity.accountID;
      };
      const accountID = authorize();
      await awaited(() => limits.consumeAvatarMutation(accountID, { upload: action === "upload" })); check();
      // Authenticate again after durable admission, before consuming any file bytes.
      if (authorize() !== accountID) throw new AvatarIntakeError("INVALID_SESSION");
      bytes = await awaited(() => avatarMutationBody(request, headers, deadline.signal, inputTimeoutMilliseconds)); check();
      let input = headers.intent;
      if (action !== "upload") {
        try { input = avatarMutationInput(action, JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))); }
        catch { throw new AvatarIntakeError("AVATAR_INPUT"); }
      }
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); check();
      let final;
      try {
        final = await awaited(() => coordinator[method]({ ...input, accessToken: headers.accessToken, signal: deadline.signal,
          ...(action === "upload" ? { bytes } : {}) }));
      } catch (error) { check(); await awaited(() => checkpoint?.advance({ signal: deadline.signal })); throw error; }
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); check();
      if (typeof final !== "function") throw new AvatarIntakeError("AVATAR_RESPONSE");
      const value = final();
      if (value && typeof value.then === "function") { void value.catch?.(() => {}); throw new AvatarIntakeError("AVATAR_RESPONSE"); }
      const snapshot = avatarMutationSnapshot(value);
      return Response.json({ protocolVersion: 1, ...snapshot }, { headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });
    } finally {
      bytes?.fill(0); deadline?.close(); admission?.close();
      if (request.body && !request.body.locked) void request.body.cancel().catch(() => {});
    }
  };
}
