import { plain, publicUUID } from "./public-record-schema.mjs";

// A user's publication choice is tied to one existing image and moderation revision.
// No owner, JPEG, provider URL or server authority can be supplied in this envelope.
export const avatarPublicationKeys = Object.freeze(["requestID", "versionID", "generation", "reviewRevision", "consentVersion"]);
export function validAvatarPublicationIntent(value) {
  return plain(value) && Object.keys(value).sort().join() === [...avatarPublicationKeys].sort().join() &&
    [value.requestID, value.versionID, value.reviewRevision].every(v => typeof v === "string" && publicUUID.test(v)) &&
    Number.isSafeInteger(value.generation) && value.generation > 0 && value.generation < Number.MAX_SAFE_INTEGER && value.consentVersion === 1;
}
