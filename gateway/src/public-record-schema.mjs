import { createHash } from "node:crypto";
import { approximateLocation } from "./community-geo.mjs";

export const publicRecordTypes = Object.freeze({ profile: "EchoesPublicProfileV1", presence: "EchoesPresenceV1",
  message: "EchoesLocalMessageV1", block: "EchoesBlockV1", report: "EchoesReportV1", avatarreport: "EchoesAvatarReportV1", avatar: "EchoesAvatarV1", avatarprofile: "EchoesAvatarProfileV1" });
export const publicUUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export const publicRecordName = /^community-v1-(profile|presence|message|block|report|avatarreport|avatar|avatarprofile)-[a-f0-9]{64}$/;
const codes = new Set(["PUBLIC_UNAVAILABLE", "PUBLIC_INPUT", "PUBLIC_CONFLICT", "PUBLIC_LIMIT", "PUBLIC_ERASED",
  "PUBLIC_PENDING", "PUBLIC_RESPONSE", "PUBLIC_THROTTLED", "PUBLIC_SCOPE", "PUBLIC_REGISTRY_UNVERIFIED"]);
export class PublicRecordError extends Error {
  constructor(code = "PUBLIC_UNAVAILABLE") { super("Community data operation could not be completed."); this.code = codes.has(code) ? code : "PUBLIC_UNAVAILABLE"; }
}
export function plain(value) { return value !== null && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype; }
export function digest(value) { return createHash("sha256").update(value).digest("hex"); }
export function ownerKey(accountID) {
  if (typeof accountID !== "string" || !publicUUID.test(accountID)) throw new PublicRecordError("PUBLIC_SCOPE");
  return digest("echoes/public-owner/v1\0" + accountID);
}
export function recordIdentity(accountID, kind, logicalID) {
  if (!Object.hasOwn(publicRecordTypes, kind) || (["profile", "presence", "avatarprofile"].includes(kind)
    ? logicalID !== "singleton" : typeof logicalID !== "string" || !publicUUID.test(logicalID))) throw new PublicRecordError("PUBLIC_INPUT");
  return recordIdentityFromKey(accountID, kind, digest("echoes/public-logical/v1\0" + logicalID));
}
export function recordIdentityFromKey(accountID, kind, logicalKey) {
  const owner = ownerKey(accountID);
  if (!Object.hasOwn(publicRecordTypes, kind) || typeof logicalKey !== "string" || !/^[a-f0-9]{64}$/.test(logicalKey)) throw new PublicRecordError("PUBLIC_SCOPE");
  return Object.freeze({ accountID, kind, recordType: publicRecordTypes[kind], ownerKey: owner,
    logicalKey, recordName: `community-v1-${kind}-` + digest("echoes/public-record/v1\0" + owner + "\0" + kind + "\0" + logicalKey) });
}
function text(value, maximum) {
  if (typeof value !== "string") throw new PublicRecordError("PUBLIC_INPUT");
  const clean = value.normalize("NFC").trim();
  if (!clean.length || clean.length > maximum || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(clean)) throw new PublicRecordError("PUBLIC_INPUT");
  return clean;
}
function keys(value, required) {
  if (!plain(value) || Object.keys(value).sort().join("\0") !== [...required].sort().join("\0")) throw new PublicRecordError("PUBLIC_INPUT");
}
function coordinate(latitude, longitude) {
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) throw new PublicRecordError("PUBLIC_INPUT");
  return approximateLocation({ latitude, longitude });
}
/** Strict server-side field inventory. No arbitrary CloudKit fields, owner, time or expiration from a client. */
export function normalizePublicInput(kind, value, now) {
  if (!Number.isSafeInteger(now) || now < 0) throw new PublicRecordError();
  switch (kind) {
  case "avatarprofile":
    keys(value, ["versionID", "generation"]);
    if (typeof value.versionID !== "string" || value.versionID !== "" && !publicUUID.test(value.versionID) ||
        !Number.isSafeInteger(value.generation) || value.generation < 1) throw new PublicRecordError("PUBLIC_INPUT");
    return { versionID: value.versionID, generation: value.generation };
  case "profile": keys(value, ["name"]); return { name: text(value.name, 40) };
  case "presence": {
    if (value?.active === false) {
      keys(value, ["active", "generation"]);
      if (!Number.isSafeInteger(value.generation) || value.generation < 0) throw new PublicRecordError("PUBLIC_INPUT");
      return { active: 0, generation: value.generation };
    }
    keys(value, ["name", "latitude", "longitude", "song", "songID", "generation", "measuredAt"]);
    if (!Number.isSafeInteger(value.generation) || value.generation < 0 || !Number.isSafeInteger(value.measuredAt) ||
        value.measuredAt < now - 60000 || value.measuredAt > now + 5000 || typeof value.song !== "string" ||
        value.song.length > 300 || typeof value.songID !== "string" || !/^[0-9]{0,30}$/.test(value.songID)) throw new PublicRecordError("PUBLIC_INPUT");
    return { active: 1, name: text(value.name, 40), ...coordinate(value.latitude, value.longitude),
      song: value.song, songID: value.songID, generation: value.generation };
  }
  case "message": keys(value, ["name", "text", "latitude", "longitude"]);
    return { name: text(value.name, 40), text: text(value.text, 500), ...coordinate(value.latitude, value.longitude) };
  case "block": keys(value, ["targetID", "blocked"]);
    if (!publicUUID.test(value.targetID ?? "") || typeof value.blocked !== "boolean") throw new PublicRecordError("PUBLIC_INPUT");
    return { targetID: value.targetID, blocked: value.blocked ? 1 : 0 };
  case "avatarreport":
    keys(value, ["avatarID", "versionID", "publicationGeneration", "imageSHA256", "reason"]);
    if (typeof value.avatarID !== "string" || !/^community-v1-avatar-[a-f0-9]{64}$/.test(value.avatarID) ||
        typeof value.versionID !== "string" || !publicUUID.test(value.versionID) ||
        !Number.isSafeInteger(value.publicationGeneration) || value.publicationGeneration < 1 ||
        typeof value.imageSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(value.imageSHA256)) throw new PublicRecordError("PUBLIC_INPUT");
    return { avatarID: value.avatarID, versionID: value.versionID, publicationGeneration: value.publicationGeneration,
      imageSHA256: value.imageSHA256, reason: text(value.reason, 500) };
  case "report": keys(value, ["messageID", "reason"]);
    if (typeof value.messageID !== "string" || !/^community-v1-message-[a-f0-9]{64}$/.test(value.messageID)) throw new PublicRecordError("PUBLIC_INPUT");
    return { messageID: value.messageID, reason: text(value.reason, 500) };
  default: throw new PublicRecordError("PUBLIC_INPUT");
  }
}
export function inputHash(input) { return digest(JSON.stringify(Object.fromEntries(Object.entries(input).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)))); }
export function fieldValues(fields) {
  return Object.fromEntries(Object.entries(fields).map(([key, value]) => [key, { value,
    type: typeof value === "string" ? "STRING" : ["latitude", "longitude"].includes(key) ? "DOUBLE" : Number.isInteger(value) ? "INT64" : "DOUBLE" }]));
}
export function liveFields(context, input) {
  const values = { schemaVersion: 1, ownerKey: context.ownerKey, erased: 0, accountID: context.accountID,
    mutationKey: digest("echoes/public-mutation/v1\0" + context.requestID), payloadHash: context.payloadHash,
    createdAt: context.createdAt, updatedAt: context.startedAt, ...input };
  if (context.kind === "presence") values.expiresAt = context.startedAt + (input.active === 0 ? 0 : 600000);
  if (context.kind === "message") values.expiresAt = context.createdAt + 7200000;
  const fields = fieldValues(values);
  if (context.kind === "message" || context.kind === "presence") {
    if (!publicRecordName.test(context.recordName ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
    fields.recordSortKey = { type: "STRING", value: context.recordName };
  }
  if (context.kind === "message" || context.kind === "presence" && input.active === 1) {
    fields.location = { type: "LOCATION", value: { latitude: input.latitude, longitude: input.longitude } };
  }
  return fields;
}
export function erasedFields(context, deletionID) {
  if (!publicUUID.test(deletionID ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
  return fieldValues({ schemaVersion: 1, ownerKey: context.ownerKey, erased: 1,
    deletionKey: digest("echoes/public-deletion/v1\0" + deletionID) });
}
export function validTag(tag) { return typeof tag === "string" && /^[\x21-\x7e]{1,512}$/.test(tag); }
export function matchesFields(actual, expected) {
  if (!plain(actual)) return false;
  const actualKeys = Object.keys(actual).filter(key => actual[key]?.value !== null);
  return actualKeys.length === Object.keys(expected).length && Object.entries(expected).every(([key, field]) =>
    plain(actual[key]) && (field.type === "LOCATION" ? plain(actual[key].value) &&
      actual[key].value.latitude === field.value.latitude && actual[key].value.longitude === field.value.longitude : actual[key].value === field.value) &&
      (actual[key].type === undefined || actual[key].type === field.type));
}
