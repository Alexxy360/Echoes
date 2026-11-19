import { PublicRecordError, recordIdentity, fieldValues, digest } from "./public-record-schema.mjs";

/** A content-free permanent fence in the same immutable record identity, never a DELETE. */
export function avatarReportCancellationKey(accountID, requestID) {
  const identity = recordIdentity(accountID, "avatarreport", requestID);
  return digest("echoes/avatar-report-cancellation/v1\0" + identity.ownerKey + "\0" + requestID);
}
export function avatarReportCancellationFields(context, key) {
  if (context?.kind !== "avatarreport" || context.recordType !== "EchoesAvatarReportV1" ||
      !/^community-v1-avatarreport-[a-f0-9]{64}$/.test(context.recordName ?? "") || !/^[a-f0-9]{64}$/.test(context.ownerKey ?? "") ||
      !/^[a-f0-9]{64}$/.test(key ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
  return fieldValues({ schemaVersion: 1, ownerKey: context.ownerKey, erased: 1, retentionKey: key });
}
