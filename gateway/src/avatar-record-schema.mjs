import { PublicRecordError, plain, publicUUID, recordIdentity, liveFields, digest, validTag, matchesFields } from "./public-record-schema.mjs";

const exact = (value, keys) => plain(value) && Object.keys(value).sort().join("|") === [...keys].sort().join("|");
const manifestKeys = ["schemaVersion", "ownerID", "versionID", "variant", "byteCount", "width", "height", "sha256"];
/** Canonical wire descriptor, NOT evidence of normalization by an untrusted caller.
 * Recovery must bind it to the existing registry payload and completed server uploads.
 */
export function avatarDescriptor(value, accountID) {
  if (!exact(value, ["image", "thumbnail", "requestID"]) || typeof accountID !== "string" || !publicUUID.test(accountID) ||
      typeof value.requestID !== "string" || !publicUUID.test(value.requestID)) throw new PublicRecordError("PUBLIC_INPUT");
  const result = { normalizationVersion: 1 };
  for (const variant of ["image", "thumbnail"]) {
    const m = value[variant], maximum = variant === "image" ? 512 : 128;
    if (!exact(m, manifestKeys) || m.schemaVersion !== 1 || m.ownerID !== accountID || typeof m.versionID !== "string" ||
        !publicUUID.test(m.versionID) || m.variant !== variant || !Number.isInteger(m.byteCount) || m.byteCount < 1 ||
        m.byteCount > (variant === "image" ? 256000 : 32000) ||
        !Number.isInteger(m.width) || m.width < 1 || m.width > maximum || !Number.isInteger(m.height) || m.height < 1 || m.height > maximum ||
        typeof m.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(m.sha256)) throw new PublicRecordError("PUBLIC_INPUT");
    result[variant] = Object.freeze({ schemaVersion: 1, ownerID: accountID, versionID: m.versionID, variant,
      byteCount: m.byteCount, width: m.width, height: m.height, sha256: m.sha256 });
  }
  const ratio = Math.min(1, 128 / Math.max(result.image.width, result.image.height));
  if (result.image.versionID !== result.thumbnail.versionID || result.thumbnail.width !== Math.max(1, Math.round(result.image.width * ratio)) ||
      result.thumbnail.height !== Math.max(1, Math.round(result.image.height * ratio))) throw new PublicRecordError("PUBLIC_INPUT");
  result.requestID = value.requestID;
  return Object.freeze(result);
}
export const avatarDescriptorHash = descriptor => digest(JSON.stringify(descriptor));
export function avatarMetadata(context, descriptor) {
  const identity = recordIdentity(context.accountID, "avatar", descriptor.image.versionID);
  if (context.kind !== "avatar" || context.recordName !== identity.recordName || context.requestID !== descriptor.requestID ||
      context.payloadHash !== avatarDescriptorHash(descriptor) || descriptor.image.ownerID !== context.accountID) throw new PublicRecordError("PUBLIC_SCOPE");
  const input = { normalizationVersion: 1, versionID: descriptor.image.versionID, moderationState: "pending" };
  for (const variant of ["image", "thumbnail"]) for (const key of ["byteCount", "width", "height", "sha256"]) {
    input[variant + key[0].toUpperCase() + key.slice(1)] = descriptor[variant][key];
  }
  return liveFields(context, input);
}
/** Provider projection stays internal. downloadURL is neither an application DTO nor authorization. */
export function validateAvatarRecord(record, context, descriptor, commitments) {
  const opaque = value => typeof value === "string" && /^[\x21-\x7e]{1,8192}$/.test(value);
  if (!plain(record) || record.deleted || record.serverErrorCode || record.recordName !== context.recordName || record.recordType !== context.recordType ||
      !validTag(record.recordChangeTag) || !plain(record.fields) || record.fields.schemaVersion?.value !== 1 ||
      record.fields.ownerKey?.value !== context.ownerKey) throw new PublicRecordError("PUBLIC_SCOPE");
  if (record.fields.erased?.value === 1) throw new PublicRecordError("PUBLIC_ERASED");
  const metadata = Object.fromEntries(Object.entries(record.fields).filter(([key]) => !["image", "thumbnail"].includes(key)));
  if (!matchesFields(metadata, avatarMetadata(context, descriptor))) throw new PublicRecordError("PUBLIC_CONFLICT");
  const assets = {};
  for (const variant of ["image", "thumbnail"]) {
    const field = record.fields[variant], value = field?.value, expected = commitments?.[variant];
    if (!expected || expected.sha256 !== descriptor[variant].sha256 || expected.byteCount !== descriptor[variant].byteCount ||
        !plain(field) || Object.keys(field).some(key => !["value", "type"].includes(key)) ||
        field.type !== undefined && !["ASSET", "ASSETID"].includes(field.type) || !plain(value) ||
        Object.keys(value).some(key => !["fileChecksum", "size", "receipt", "referenceChecksum", "wrappingKey", "downloadURL"].includes(key)) ||
        value.size !== expected.byteCount || !opaque(value.fileChecksum) || digest(value.fileChecksum) !== expected.fileChecksumHash ||
        ["receipt", "referenceChecksum", "wrappingKey", "downloadURL"].some(key => Object.hasOwn(value, key) && !opaque(value[key]))) throw new PublicRecordError("PUBLIC_RESPONSE");
    assets[variant] = Object.freeze({ ...value });
  }
  if (context.phase === "settled" && context.recordTag !== record.recordChangeTag) throw new PublicRecordError("PUBLIC_CONFLICT");
  return Object.freeze({ tag: record.recordChangeTag, assets: Object.freeze(assets) });
}
