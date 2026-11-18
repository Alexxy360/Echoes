import { publicUUID } from "./public-record-schema.mjs";
import { AvatarReadError } from "./cloudkit-avatar-reader.mjs";
import { AvatarIntakeError, avatarMutationBody } from "./avatar-upload-http.mjs";
import { avatarHTTPDeadline } from "./gateway-avatar-http.mjs";
import { avatarOwnerPreviewHeaders, avatarOwnerPreviewInput, avatarOwnerPreviewResponse, avatarOwnerPreviewAdmission, avatarOwnerPreviewError } from "./avatar-owner-preview-http.mjs";

export function createAvatarOwnerPreviewHandler({ authentication, limits, checkpoint, avatarOwnerPreview, isEnabled,
  isAvatarOwnerPreviewEnabled, previewTimeoutMilliseconds = 12000, inputTimeoutMilliseconds = 3000 } = {}) {
  if (typeof isAvatarOwnerPreviewEnabled !== "function" || !Number.isInteger(previewTimeoutMilliseconds) || previewTimeoutMilliseconds < 1 || previewTimeoutMilliseconds > 12000) throw new Error("Owner preview configuration unavailable.");
  const claim = avatarOwnerPreviewAdmission();
  return async (request, serverBudgetHash) => {
    let admission, deadline, bytes, response;
    try {
      const enabled = () => isEnabled() === true && isAvatarOwnerPreviewEnabled() === true;
      if (!enabled() || typeof avatarOwnerPreview?.prepare !== "function" || typeof limits.consumeAvatarRead !== "function") throw new AvatarIntakeError("FEATURE_DISABLED");
      admission = claim(); deadline = avatarHTTPDeadline(request.signal, previewTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (!enabled()) throw new AvatarIntakeError("FEATURE_DISABLED"); };
      await awaited(() => limits.consume(serverBudgetHash, { heavy: true })); check();
      const headers = avatarOwnerPreviewHeaders(request);
      const authorize = expected => {
        check(); const identity = authentication.authorize(headers.accessToken);
        if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarIntakeError("INVALID_SESSION"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) throw new AvatarIntakeError("INVALID_SESSION");
        return identity.accountID;
      };
      const accountID = authorize();
      await awaited(() => limits.consumeAvatarRead(accountID, { variant: "image" })); authorize(accountID);
      bytes = await awaited(() => avatarMutationBody(request, headers, deadline.signal, inputTimeoutMilliseconds)); authorize(accountID);
      let selection; try { selection = avatarOwnerPreviewInput(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))); }
      catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); authorize(accountID);
      const final = await awaited(() => avatarOwnerPreview.prepare({ ...selection, accessToken: headers.accessToken, signal: deadline.signal })); authorize(accountID);
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); authorize(accountID);
      if (typeof final !== "function" || typeof final.validate !== "function") throw new AvatarReadError("AVATAR_READ_RESPONSE");
      response = final();
      if (response && typeof response.then === "function") { void response.then(v => v?.body?.cancel().catch(() => {})).catch(() => {}); throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
      const result = await awaited(() => avatarOwnerPreviewResponse(response, deadline, { selection, accountID }));
      try {
        authorize(accountID); const validated = final.validate();
        if (validated && typeof validated.then === "function") { void validated.catch?.(() => {}); throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
        return result;
      } catch (e) { void result.body?.cancel().catch(() => {}); throw e; }
    } catch (e) { throw avatarOwnerPreviewError(e); }
    finally {
      bytes?.fill(0); deadline?.close(); admission?.close();
      if (request.body && !request.body.locked) void request.body.cancel().catch(() => {});
      if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
    }
  };
}
