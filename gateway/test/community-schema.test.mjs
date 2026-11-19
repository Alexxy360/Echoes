import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { communitySchemaRole, inspectSchema, prepareCommunitySchema, verifyCommunityProposal, verifyInstalledCommunitySchema } from "../scripts/prepare-community-schema.mjs";
import { publicRecordTypes, recordIdentity, normalizePublicInput, liveFields, erasedFields } from "../src/public-record-schema.mjs";
import { avatarDescriptor, avatarDescriptorHash, avatarMetadata } from "../src/avatar-record-schema.mjs";
import { expiredPublicFields } from "../src/public-retention-policy.mjs";
import { checkpointFields, checkpointRecordType } from "../src/public-registry-checkpoint.mjs";
import { CloudKitPublicClient } from "../src/cloudkit-public-client.mjs";

const original = await readFile(new URL("../schema/development-export-20261119.ckdb", import.meta.url), "utf8");
const prepared = prepareCommunitySchema(original), before = inspectSchema(original), after = inspectSchema(prepared.schema);
const types = new Map(after.types.map(type => [type.name, type]));
// This fixture is the already imported eight-type proposal; later additive types have their own proposal.
const historicalKinds = ["profile", "presence", "message", "block", "report", "avatar", "avatarprofile"];
const now = 1795040000000, accountID = randomUUID();
function context(kind) {
  return { ...recordIdentity(accountID, kind, ["profile", "presence", "avatarprofile"].includes(kind) ? "singleton" : randomUUID()),
    requestID: randomUUID(), payloadHash: "a".repeat(64), createdAt: now, startedAt: now };
}
function accepts(recordType, fields) {
  for (const [name, field] of Object.entries(fields)) {
    assert.equal(types.get(recordType).fields[name]?.type, field.type, recordType + "." + name);
  }
}

test("additive proposal preserves the exported definitions and grants no ordinary public access or role membership", () => {
  assert.equal(prepared.inputSHA256, "869adb25159e1575a2ed848b491b7170f5fe0c0e661716e60e4b9da49d747b27");
  assert.ok(prepared.schema.startsWith(original));
  assert.deepEqual(after.types.slice(0, before.types.length), before.types);
  assert.deepEqual(after.roles, [...before.roles, communitySchemaRole]);
  assert.equal(before.types.length, 5); assert.equal(prepared.addedTypes.length, 8);
  assert.deepEqual(new Set(prepared.addedTypes.map(type => type.name)), new Set([...historicalKinds.map(kind => publicRecordTypes[kind]), checkpointRecordType]));
  for (const type of prepared.addedTypes) {
    assert.deepEqual(type.grants, [{ role: communitySchemaRole, rights: ["READ", "CREATE", "WRITE"] }]);
  }
  assert.deepEqual(prepared.roleAssignments, []); assert.deepEqual(prepared.dataOperations, []);
  assert.equal(prepared.remoteImport, false); assert.equal(prepared.remoteValidation, "not performed");
});

test("actual live, inactive, deletion, retention, avatar and checkpoint serializers fit the proposed field types", () => {
  const coordinate = { latitude: 51.11, longitude: 17.03 };
  const inputs = {
    profile: { name: "Syntetyczny profil" },
    presence: { name: "Syntetyczna obecność", ...coordinate, song: "", songID: "", generation: 1, measuredAt: now },
    message: { name: "Syntetyczny autor", text: "Syntetyczna wiadomość", ...coordinate },
    block: { targetID: randomUUID(), blocked: true },
    report: { messageID: recordIdentity(accountID, "message", randomUUID()).recordName, reason: "Syntetyczne zgłoszenie" },
    avatarprofile: { versionID: randomUUID(), generation: 1 },
  };
  for (const [kind, input] of Object.entries(inputs)) {
    accepts(publicRecordTypes[kind], liveFields(context(kind), normalizePublicInput(kind, input, now)));
  }
  accepts(publicRecordTypes.presence, liveFields(context("presence"), normalizePublicInput("presence", { active: false, generation: 2 }, now)));
  accepts(publicRecordTypes.avatarprofile, liveFields(context("avatarprofile"), normalizePublicInput("avatarprofile", { versionID: "", generation: 2 }, now)));
  const avatar = context("avatar"), versionID = randomUUID();
  Object.assign(avatar, recordIdentity(accountID, "avatar", versionID));
  const manifest = variant => ({ schemaVersion: 1, ownerID: accountID, versionID, variant, byteCount: 100,
    width: variant === "image" ? 512 : 128, height: variant === "image" ? 512 : 128, sha256: "b".repeat(64) });
  const descriptor = avatarDescriptor({ requestID: avatar.requestID, image: manifest("image"), thumbnail: manifest("thumbnail") }, accountID);
  avatar.payloadHash = avatarDescriptorHash(descriptor);
  accepts(avatar.recordType, { ...avatarMetadata(avatar, descriptor), image: { type: "ASSET" }, thumbnail: { type: "ASSET" } });
  for (const kind of historicalKinds) accepts(publicRecordTypes[kind], erasedFields(context(kind), randomUUID()));
  for (const kind of ["presence", "message", "report", "avatar"]) accepts(publicRecordTypes[kind], expiredPublicFields(context(kind)));
  accepts(checkpointRecordType, checkpointFields({ schemaVersion: 1, registryID: randomUUID(), anchorID: randomUUID(), parentAnchorID: "", registeredCount: 0 }));
});

test("real regional request builders require only the proposed field and system indexes", async () => {
  const privateKeyPEM = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" });
  const calls = [];
  const client = new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-schema-contract",
    privateKeyPEM, isEnabled: () => true, clock: () => now, fetchImplementation: async request => {
      calls.push(JSON.parse(await request.text())); return Response.json({ records: [] });
    } });
  for (const kind of ["presence", "message"]) {
    await client.regionalCandidates({ kind, coordinate: { latitude: 51.11, longitude: 17.03 }, cutoff: now });
    const { query } = calls.at(-1), type = types.get(query.recordType);
    for (const filter of query.filterBy) {
      assert.ok(type.fields[filter.fieldName]?.options.includes("QUERYABLE"), filter.fieldName);
      if (["NEAR", "GREATER_THAN", "LESS_THAN_OR_EQUALS"].includes(filter.comparator)) {
        assert.ok(type.fields[filter.fieldName]?.options.includes("SORTABLE"), filter.fieldName);
      }
    }
    for (const sort of query.sortBy) {
      const name = sort.systemFieldName === "recordName" ? "___recordID" : sort.fieldName;
      assert.ok(type.fields[name]?.options.includes("SORTABLE"), name);
    }
  }
  assert.equal(calls.length, 2);
});

test("existing community types or role stop preparation rather than replace a concurrent schema", () => {
  assert.throws(() => prepareCommunitySchema(prepared.schema), /explicit comparison/);
  assert.throws(() => prepareCommunitySchema(original + "\nCREATE ROLE EchoesCommunityService;"), /explicit comparison/);
  assert.throws(() => prepareCommunitySchema(original + "\nRECORD TYPE EchoesPresenceV1 (\n name STRING\n);"), /explicit comparison/);
});

test("unsupported exports, duplicate definitions and undeclared roles fail the limited local checker", () => {
  for (const bad of [original + "\nRESET SCHEMA;", original + "\nCREATE ROLE EchoesGatewayProbeService;",
    original.replace("nonce           STRING,", "nonce           STRING,\nnonce STRING,"),
    original.replace("nonce           STRING,", "nonce BYTES,"),
    original.replace('"___recordID"   REFERENCE,', '"___recordID" REFERENCE SORTABLE,'),
    original.replace("QUERYABLE SEARCHABLE SORTABLE", "QUERYABLE QUERYABLE"),
    original.replace('TO "_world"', 'TO "_unknown"'),
    original.replace("TO EchoesGatewayProbeService", "TO MissingRole")]) assert.throws(() => inspectSchema(bad));
});

test("reviewed proposal verification rejects added privileges, missing fields, edited originals or a changed source export", () => {
  assert.equal(verifyCommunityProposal(original, prepared.schema).proposedSHA256, prepared.proposedSHA256);
  for (const changed of [prepared.schema.replace("TO EchoesCommunityService", 'TO "_world"'),
    prepared.schema.replace("retentionKey STRING,", ""), prepared.schema.replace("LIST<INT64>", "STRING"),
    prepared.schema + "\nCREATE ROLE ExtraRole;"]) assert.throws(() => verifyCommunityProposal(original, changed), /reviewed additive contract/);
  assert.throws(() => verifyCommunityProposal(original + "\n", prepared.schema), /reviewed additive contract/);
});

const withImplicitSystemFields = prepared.schema.replace("RECORD TYPE EchoesPublicProfileV1 (", `RECORD TYPE EchoesPublicProfileV1 (
        "___recordID" REFERENCE,
        "___createTime" TIMESTAMP,
        "___createdBy" REFERENCE,
        "___etag" STRING,
        "___modTime" TIMESTAMP,
        "___modifiedBy" REFERENCE,`);
test("read-back comparison accepts only known unindexed implicit fields on newly added types and harmless formatting/order", () => {
  const reformatted = withImplicitSystemFields.replaceAll("QUERYABLE SORTABLE", "SORTABLE QUERYABLE")
    .replaceAll("READ, CREATE, WRITE", "WRITE, CREATE, READ").replaceAll("schemaVersion INT64", "schemaVersion    INT64");
  const result = verifyInstalledCommunitySchema(original, reformatted);
  assert.equal(result.types, 13); assert.equal(result.roles, 2);
});

test("read-back comparison detects missing/extra types, old rights drift, builtin access and altered/new indexes or fields", () => {
  for (const changed of [original, prepared.schema + "\nRECORD TYPE ExtraType (\n name STRING\n);",
    prepared.schema.replace('GRANT READ TO "_world"', 'GRANT READ TO "_icloud"'),
    prepared.schema.replace("TO EchoesCommunityService", 'TO "_creator"'),
    prepared.schema.replace("location LOCATION QUERYABLE SORTABLE", "location LOCATION"),
    prepared.schema.replace("retentionKey STRING,", "retentionKey INT64,"),
    withImplicitSystemFields.replace('"___etag" STRING,', '"___etag" INT64,'),
    withImplicitSystemFields.replace('"___createTime" TIMESTAMP,\n        "___createdBy"', '"___createTime" TIMESTAMP QUERYABLE,\n        "___createdBy"'),
    prepared.schema.replace("retentionKey STRING,", '"___future" STRING,\n retentionKey STRING,')]) {
    assert.throws(() => verifyInstalledCommunitySchema(original, changed));
  }
});

test("partial-import recovery preserves the existing service role only after an explicit comparison option", async () => {
  const partial = await readFile(new URL("../schema/development-after-failed-import-20261119.ckdb", import.meta.url), "utf8");
  const snapshot = inspectSchema(partial);
  assert.deepEqual(snapshot.types, before.types); assert.deepEqual(snapshot.roles, [...before.roles, communitySchemaRole]);
  assert.throws(() => prepareCommunitySchema(partial), /explicit comparison/);
  const recovered = prepareCommunitySchema(partial, { preserveExistingServiceRole: true });
  assert.equal(recovered.inputSHA256, "0138e853eb0dd20de0aab908c9a1d90e24c0ba7e97005f6c30423f4c90e45ddd");
  assert.equal(recovered.addedRole, null); assert.deepEqual(recovered.preservedRoles, snapshot.roles);
  assert.ok(recovered.schema.startsWith(partial));
  assert.equal(inspectSchema(recovered.schema).roles.filter(role => role === communitySchemaRole).length, 1);
  assert.equal(verifyInstalledCommunitySchema(partial, recovered.schema, { preserveExistingServiceRole: true }).types, 13);
  assert.throws(() => prepareCommunitySchema(recovered.schema, { preserveExistingServiceRole: true }), /explicit comparison/);
});

test("regional tie keys are server-derived, match record IDs and disappear from deletion/retention fences", () => {
  for (const kind of ["message", "presence"]) {
    const c = context(kind), input = kind === "message" ? { name: "Test", text: "Test", latitude: 0, longitude: 0 } : { active: false, generation: 0 };
    assert.throws(() => normalizePublicInput(kind, { ...input, recordSortKey: "forged" }, now));
    const fields = liveFields(c, normalizePublicInput(kind, input, now));
    assert.deepEqual(fields.recordSortKey, { type: "STRING", value: c.recordName });
    assert.ok(types.get(c.recordType).fields.recordSortKey.options.includes("SORTABLE"));
    assert.equal(types.get(c.recordType).fields.___recordID.options.includes("SORTABLE"), false);
    assert.equal(Object.hasOwn(erasedFields(c, randomUUID()), "recordSortKey"), false);
    assert.equal(Object.hasOwn(expiredPublicFields(c), "recordSortKey"), false);
  }
});
