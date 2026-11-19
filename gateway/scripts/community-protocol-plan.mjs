import { randomUUID } from "node:crypto";
import { plain, publicUUID, digest, recordIdentity, normalizePublicInput, inputHash, liveFields, erasedFields } from "../src/public-record-schema.mjs";
import { avatarDescriptor, avatarDescriptorHash, avatarMetadata } from "../src/avatar-record-schema.mjs";
import { expiredPublicFields } from "../src/public-retention-policy.mjs";
import { checkpointFields, checkpointRecordType } from "../src/public-registry-checkpoint.mjs";

const scope = { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development", database: "public",
  reviewedSchemaSHA256: "6ee9f8e03394b502839774280090718f8ead5ea7090e19063c8c7d4d8c111025" };
function freeze(value) {
  if (value && typeof value === "object") { for (const item of Object.values(value)) freeze(item); Object.freeze(value); }
  return value;
}
const canonical = value => JSON.stringify(value && typeof value === "object" ? Array.isArray(value) ? value.map(item => JSON.parse(canonical(item))) :
  Object.fromEntries(Object.keys(value).sort().map(key => [key, JSON.parse(canonical(value[key]))])) : value);

/** Pure preparation. No transport, credentials, file access, activation or live runner. */
export function makeCommunityProtocolPlan(seed = { runID: randomUUID(), accountID: randomUUID(), startedAt: Date.now() }) {
  if (!plain(seed) || Object.keys(seed).sort().join() !== "accountID,runID,startedAt" ||
      !publicUUID.test(seed.runID ?? "") || !publicUUID.test(seed.accountID ?? "") || seed.runID === seed.accountID ||
      !Number.isSafeInteger(seed.startedAt) || seed.startedAt < 0 || seed.startedAt > Number.MAX_SAFE_INTEGER - 2592000000) {
    throw new Error("Invalid synthetic Development plan seed.");
  }
  const id = label => {
    const hex = digest("echoes/community-protocol-plan/v1\0" + seed.runID + "\0" + label).slice(0, 32);
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
  };
  const request = kind => id("request/" + kind), avatarVersion = id("avatar-version"), targetID = id("block-target");
  const messageName = recordIdentity(seed.accountID, "message", request("message")).recordName;
  const syntheticName = "Protocol " + seed.runID.slice(0, 8);
  const inputs = {
    profile: { name: syntheticName },
    presence: { name: syntheticName, latitude: 0, longitude: 0, song: "", songID: "", generation: 0, measuredAt: seed.startedAt },
    message: { name: syntheticName, text: "Synthetic Development protocol test " + seed.runID, latitude: 0, longitude: 0 },
    block: { targetID, blocked: true },
    report: { messageID: messageName, reason: "Synthetic Development protocol test " + seed.runID },
    avatarprofile: { versionID: avatarVersion, generation: 1 },
  };
  const records = ["profile", "presence", "message", "block", "report", "avatar", "avatarprofile"].map(kind => {
    const logicalID = ["profile", "presence", "avatarprofile"].includes(kind) ? "singleton" :
      kind === "block" ? targetID : kind === "avatar" ? avatarVersion : request(kind);
    const context = { ...recordIdentity(seed.accountID, kind, logicalID), requestID: request(kind),
      createdAt: seed.startedAt, startedAt: seed.startedAt };
    let initial;
    if (kind === "avatar") {
      const manifest = variant => ({ schemaVersion: 1, ownerID: seed.accountID, versionID: avatarVersion, variant,
        byteCount: 100, width: variant === "image" ? 512 : 128, height: variant === "image" ? 512 : 128,
        sha256: digest(seed.runID + "/synthetic-manifest/" + variant) });
      const descriptor = avatarDescriptor({ requestID: context.requestID, image: manifest("image"), thumbnail: manifest("thumbnail") }, seed.accountID);
      context.payloadHash = avatarDescriptorHash(descriptor); initial = avatarMetadata(context, descriptor);
    } else {
      const input = normalizePublicInput(kind, inputs[kind], seed.startedAt);
      context.payloadHash = inputHash(input); initial = liveFields(context, input);
    }
    const replaced = ["presence", "message", "report", "avatar"].includes(kind) ? expiredPublicFields(context) : erasedFields(context, id("deletion"));
    return { kind, recordType: context.recordType, recordName: context.recordName, initial, replaced };
  });
  const checkpoint = { schemaVersion: 1, registryID: id("registry"), anchorID: id("anchor"), parentAnchorID: "", registeredCount: 0 };
  records.push({ kind: "checkpoint", recordType: checkpointRecordType, recordName: "community-protocol-checkpoint-v1-" + seed.runID,
    initial: checkpointFields(checkpoint), replaced: checkpointFields({ ...checkpoint, parentAnchorID: checkpoint.anchorID, anchorID: id("next-anchor"), registeredCount: 1 }) });
  const plan = freeze({ schemaVersion: 1, scope: { ...scope }, seed: { ...seed }, records,
    constraints: { maximumRecords: 8, maximumBatchCalls: 9, metadataOnlyAvatar: true, assetOperations: false, queries: false,
      requiresDurableJournal: true, requiresFreshTags: true, skipExplicitExistingRecord: true, forceDelete: false, activation: false },
    steps: ["persist inventory", "exact lookup; require all absent", "create once", "exact lookup and verify initial fields",
      "replace by fresh tag", "exact lookup and verify field removal", "stale-tag replace must conflict",
      "reconcile exact owned records", "delete by fresh tag", "exact lookup and verify absence"],
  });
  return { plan, sha256: digest(canonical(plan)) };
}

/** Bind a reviewed serialized inventory to its hash and deterministic synthetic payload. */
export function verifyCommunityProtocolPlan(plan, expectedSHA256) {
  if (!plain(plan) || typeof expectedSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(expectedSHA256)) throw new Error("Invalid protocol plan.");
  const expected = makeCommunityProtocolPlan(plan.seed);
  if (canonical(plan) !== canonical(expected.plan) || expected.sha256 !== expectedSHA256) throw new Error("Protocol plan differs from reviewed inventory.");
  return expected;
}
