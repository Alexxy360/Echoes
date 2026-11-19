import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { inspectSchema, communitySchemaRole } from "./prepare-community-schema.mjs";
import { publicRecordTypes } from "../src/public-record-schema.mjs";
import { checkpointRecordType } from "../src/public-registry-checkpoint.mjs";

export const avatarReportFields = Object.freeze({ schemaVersion: "INT64", ownerKey: "STRING", erased: "INT64", accountID: "STRING",
  mutationKey: "STRING", payloadHash: "STRING", createdAt: "INT64", updatedAt: "INT64", deletionKey: "STRING", retentionKey: "STRING",
  avatarID: "STRING", versionID: "STRING", publicationGeneration: "INT64", imageSHA256: "STRING", reason: "STRING" });
const sha = value => createHash("sha256").update(value).digest("hex");
/** Add one server-only type. Existing definitions are preserved byte-for-byte, never regenerated. */
export function prepareAvatarReportSchema(original) {
  const before = inspectSchema(original), known = new Set(before.types.map(type => type.name));
  const required = ["profile", "presence", "message", "block", "report", "avatar", "avatarprofile"].map(kind => publicRecordTypes[kind]);
  if (!before.roles.includes(communitySchemaRole) || known.has(publicRecordTypes.avatarreport) ||
      [...required, checkpointRecordType].some(type => !known.has(type))) throw new Error("Installed base schema and existing service role required; no replacement allowed.");
  const fields = Object.entries(avatarReportFields).map(([name, type]) => `        ${name} ${type}`);
  fields.push(`        GRANT READ, CREATE, WRITE TO ${communitySchemaRole}`);
  const schema = original + `\n    RECORD TYPE ${publicRecordTypes.avatarreport} (\n${fields.join(",\n")}\n    );\n`;
  const after = inspectSchema(schema);
  if (JSON.stringify(after.types.slice(0, -1)) !== JSON.stringify(before.types) || JSON.stringify(after.roles) !== JSON.stringify(before.roles) ||
      after.types.at(-1).grants.length !== 1 || after.types.at(-1).grants[0].role !== communitySchemaRole) throw new Error("Schema preservation failed.");
  return { schema, scope: { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development" },
    inputSHA256: sha(original), proposedSHA256: sha(schema), preservedTypes: before.types.map(type => type.name), preservedRoles: before.roles,
    addedRole: null, addedTypes: [after.types.at(-1)], roleAssignments: [], remoteValidation: "not performed", remoteImport: false, dataOperations: [] };
}
export function verifyAvatarReportProposal(original, proposed) {
  const expected = prepareAvatarReportSchema(original);
  if (expected.schema !== proposed) throw new Error("Proposal differs from the additive photo-report contract.");
  return { inputSHA256: expected.inputSHA256, proposedSHA256: expected.proposedSHA256 };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 5) throw new Error("Provide base schema, proposed schema and report paths. This command performs no network operations.");
  const { schema, ...report } = prepareAvatarReportSchema(await readFile(process.argv[2], "utf8"));
  await writeFile(process.argv[3], schema); await writeFile(process.argv[4], JSON.stringify(report, null, 2) + "\n");
}
