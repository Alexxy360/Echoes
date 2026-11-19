import { publicUUID } from "./public-record-schema.mjs";
import { AvatarReportError } from "./avatar-report-domain.mjs";
import { avatarReportAdmission, avatarReportDeadline, avatarReportHeaders, avatarReportReadInput, avatarReportInput, avatarReportResult, avatarReportHTTPError } from "./avatar-report-http.mjs";
const fail = code => { throw new AvatarReportError(code); };
const sync = value => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail(); } return value; };
const response = (value, status = 200) => Response.json({ protocolVersion: 1, ...value }, { status,
  headers: { "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" } });

export function createAvatarReportHandler({ authentication, limits, checkpoint, avatarReports, isEnabled, isAvatarReadEnabled,
  isAvatarReportEnabled, scheduleMaintenance, avatarReportTimeoutMilliseconds = 12000, inputTimeoutMilliseconds = 3000 } = {}) {
  if ([isAvatarReportEnabled, isAvatarReadEnabled].some(value => typeof value !== "function") ||
      !Number.isInteger(avatarReportTimeoutMilliseconds) || avatarReportTimeoutMilliseconds < 1 || avatarReportTimeoutMilliseconds > 12000) throw new Error("Photo report configuration unavailable.");
  const claim = avatarReportAdmission();
  return async (request, budget, action) => {
    let admission, deadline;
    try {
      const method = { submit: "prepareSubmit", recover: "prepareRecovery" }[action];
      const flag = fn => { try { return sync(fn()) === true; } catch { return false; } };
      const enabled = () => flag(isEnabled) && flag(isAvatarReportEnabled) && (action !== "submit" || flag(isAvatarReadEnabled));
      if (!enabled() || !method || typeof avatarReports?.[method] !== "function" || typeof avatarReports.waitForPendingOperations !== "function" || typeof limits.consumeAvatarReport !== "function") return response({ error: "FEATURE_DISABLED" }, 503);
      admission = claim(); deadline = avatarReportDeadline(request.signal, avatarReportTimeoutMilliseconds);
      const awaited = task => admission.run(deadline, task);
      const check = () => { deadline.check(); if (!enabled()) fail(); };
      await awaited(() => limits.consume(budget, { heavy: true })); check();
      const headers = avatarReportHeaders(request);
      const authorize = expected => {
        check(); let identity; try { identity = sync(authentication.authorize(headers.accessToken)); } catch { fail("AVATAR_REPORT_SCOPE"); }
        if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) fail("AVATAR_REPORT_SCOPE");
        return identity.accountID;
      };
      const accountID = authorize();
      await awaited(() => limits.consumeAvatarReport(accountID, { submit: action === "submit" })); authorize(accountID);
      const input = avatarReportInput(action, await avatarReportReadInput(request, headers, deadline, admission, inputTimeoutMilliseconds)); authorize(accountID);
      await awaited(() => scheduleMaintenance()); authorize(accountID);
      await awaited(() => checkpoint?.verify({ signal: deadline.signal })); authorize(accountID);
      let final;
      try {
        final = await awaited(async () => {
          try { return await avatarReports[method]({ ...input, accessToken: headers.accessToken, signal: deadline.signal }); }
          finally { try { await avatarReports.waitForPendingOperations(); } catch (error) { admission.poison(); throw error; } }
        });
      } catch (error) { authorize(accountID); await awaited(() => checkpoint?.advance({ signal: deadline.signal })); throw error; }
      await awaited(() => checkpoint?.advance({ signal: deadline.signal })); authorize(accountID);
      if (typeof final !== "function") fail("AVATAR_REPORT_RESPONSE");
      const result = avatarReportResult(action, sync(final()), input, accountID); authorize(accountID); return response(result);
    } catch (error) { throw avatarReportHTTPError(error); }
    finally {
      if (admission && request.body && !request.body.locked) admission.cancelBody(request.body);
      deadline?.close(); admission?.close();
    }
  };
}
