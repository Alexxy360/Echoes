import { plain, publicUUID, recordIdentity } from "./public-record-schema.mjs";
import { communityCoordinate, communityText } from "./community-domain.mjs";

const codes = new Set(["AVATAR_REPORT_INPUT", "AVATAR_REPORT_SCOPE", "AVATAR_REPORT_NOT_FOUND", "AVATAR_REPORT_CONFLICT",
  "AVATAR_REPORT_LIMIT", "AVATAR_REPORT_RESPONSE", "AVATAR_REPORT_UNAVAILABLE"]);
export class AvatarReportError extends Error {
  constructor(code = "AVATAR_REPORT_UNAVAILABLE") { super("Photo report could not be completed."); this.code = codes.has(code) ? code : "AVATAR_REPORT_UNAVAILABLE"; }
}
export const avatarReportFail = code => { throw new AvatarReportError(code); };
export const avatarReportExact = (value, keys) => plain(value) && Object.keys(value).sort().join() === [...keys].sort().join();
const id = value => typeof value === "string" && publicUUID.test(value);
export function avatarReportInput(action, value) {
  const keys = action === "submit" ? ["requestID", "ownerID", "versionID", "reason", "coordinate"] : action === "recover" ? ["requestID"] : null;
  if (!keys || !avatarReportExact(value, keys) || !id(value.requestID) || action === "submit" && (!id(value.ownerID) || !id(value.versionID))) avatarReportFail("AVATAR_REPORT_INPUT");
  if (action === "recover") return Object.freeze({ requestID: value.requestID });
  try {
    const reason = communityText(value.reason, 500), coordinate = Object.freeze(communityCoordinate(value.coordinate));
    // JSON escapes can carry lone surrogates even through a fatal UTF-8 decoder.
    for (const character of reason) if (character.codePointAt(0) >= 0xd800 && character.codePointAt(0) <= 0xdfff) throw new Error();
    return Object.freeze({ requestID: value.requestID, ownerID: value.ownerID, versionID: value.versionID, reason, coordinate });
  } catch { avatarReportFail("AVATAR_REPORT_INPUT"); }
}
export function avatarReportResult(action, value, input, accountID) {
  if (!["submit", "recover"].includes(action) || !avatarReportExact(value, ["schemaVersion", "requestID", "reportID", "outcome"]) || value.schemaVersion !== 1 ||
      !id(value.requestID) || value.requestID !== input.requestID || typeof value.reportID !== "string" || !/^community-v1-avatarreport-[a-f0-9]{64}$/.test(value.reportID) ||
      !["accepted", "unconfirmed"].includes(value.outcome) || action === "submit" && value.outcome !== "accepted" ||
      accountID !== undefined && value.reportID !== recordIdentity(accountID, "avatarreport", input.requestID).recordName) avatarReportFail("AVATAR_REPORT_RESPONSE");
  return Object.freeze({ ...value });
}
