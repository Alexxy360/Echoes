import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { publicRecordTypes } from "../src/public-record-schema.mjs";
import { checkpointRecordType } from "../src/public-registry-checkpoint.mjs";

export const communitySchemaRole = "EchoesCommunityService";
const common = { schemaVersion: "INT64", ownerKey: "STRING", erased: "INT64", accountID: "STRING", mutationKey: "STRING",
  payloadHash: "STRING", createdAt: "INT64", updatedAt: "INT64", deletionKey: "STRING" };
const retained = { retentionKey: "STRING" };
const variants = Object.fromEntries(["image", "thumbnail"].flatMap(name => [
  [name, "ASSET"], [name + "ByteCount", "INT64"], [name + "Width", "INT64"], [name + "Height", "INT64"], [name + "Sha256", "STRING"],
]));
const query = { location: ["QUERYABLE", "SORTABLE"], erased: ["QUERYABLE"], expiresAt: ["QUERYABLE", "SORTABLE"] };
const catalog = [
  { name: publicRecordTypes.profile, fields: { ...common, name: "STRING" } },
  { name: publicRecordTypes.presence, fields: { ...common, ...retained, active: "INT64", generation: "INT64", name: "STRING",
    latitude: "DOUBLE", longitude: "DOUBLE", location: "LOCATION", song: "STRING", songID: "STRING", expiresAt: "INT64" }, indexes: { ...query, active: ["QUERYABLE"], updatedAt: ["SORTABLE"] } },
  { name: publicRecordTypes.message, fields: { ...common, ...retained, name: "STRING", text: "STRING", latitude: "DOUBLE", longitude: "DOUBLE",
    location: "LOCATION", expiresAt: "INT64" }, indexes: { ...query, createdAt: ["QUERYABLE", "SORTABLE"] } },
  { name: publicRecordTypes.block, fields: { ...common, targetID: "STRING", blocked: "INT64" } },
  { name: publicRecordTypes.report, fields: { ...common, ...retained, messageID: "STRING", reason: "STRING" } },
  { name: publicRecordTypes.avatar, fields: { ...common, ...retained, normalizationVersion: "INT64", versionID: "STRING", moderationState: "STRING", ...variants } },
  { name: publicRecordTypes.avatarprofile, fields: { ...common, versionID: "STRING", generation: "INT64" } },
  { name: checkpointRecordType, fields: { schemaVersion: "INT64", registryID: "STRING", anchorID: "STRING", parentAnchorID: "STRING", registeredCount: "INT64" } },
];

/** Deliberately limited checker for this exported grammar subset, NOT an Apple schema validator. */
export function inspectSchema(text) {
  if (typeof text !== "string" || Buffer.byteLength(text) > 65536 || !text.startsWith("DEFINE SCHEMA")) throw new Error("Schema input unavailable.");
  const roles = [...text.matchAll(/CREATE ROLE ([A-Za-z][A-Za-z0-9_]*);/g)].map(match => match[1]);
  const types = [...text.matchAll(/RECORD TYPE ([A-Za-z][A-Za-z0-9_]*)\s*\(([\s\S]*?)\);/g)].map(match => {
    const fields = {}, grants = [];
    for (const raw of match[2].split("\n")) {
      const line = raw.trim().replace(/,$/, ""); if (!line) continue;
      if (line.startsWith("GRANT ")) {
        const grant = /^GRANT ((?:READ|CREATE|WRITE)(?:, (?:READ|CREATE|WRITE))*) TO ("_[a-z]+"|[A-Za-z][A-Za-z0-9_]*)$/.exec(line);
        if (!grant) throw new Error("Unsupported schema grant.");
        grants.push({ role: grant[2].replaceAll('"', ""), rights: grant[1].split(", ") }); continue;
      }
      const field = /^("___[A-Za-z]+"|[A-Za-z][A-Za-z0-9_]*)\s+(STRING|INT64|DOUBLE|LOCATION|ASSET|TIMESTAMP|REFERENCE|LIST<INT64>)(?:\s+((?:(?:QUERYABLE|SORTABLE|SEARCHABLE)\s*)+))?$/.exec(line);
      if (!field) throw new Error("Unsupported schema field.");
      const name = field[1].replaceAll('"', ""); if (Object.hasOwn(fields, name)) throw new Error("Duplicate schema field.");
      const options = field[3]?.trim().split(/\s+/) ?? [];
      if (new Set(options).size !== options.length) throw new Error("Duplicate schema field option.");
      fields[name] = { type: field[2], options };
    }
    return { name: match[1], fields, grants };
  });
  const rest = text.replace(/^DEFINE SCHEMA/, "").replace(/CREATE ROLE [A-Za-z][A-Za-z0-9_]*;/g, "")
    .replace(/RECORD TYPE [A-Za-z][A-Za-z0-9_]*\s*\([\s\S]*?\);/g, "").trim();
  if (rest || new Set(roles).size !== roles.length || new Set(types.map(type => type.name)).size !== types.length) throw new Error("Unsupported or duplicate schema definition.");
  const permittedRoles = new Set([...roles, "_creator", "_icloud", "_world"]);
  if (types.some(type => type.grants.some(grant => !permittedRoles.has(grant.role)))) throw new Error("Unknown schema role.");
  return { roles, types };
}
export function prepareCommunitySchema(original) {
  const before = inspectSchema(original), known = new Set(before.types.map(type => type.name));
  if (before.roles.includes(communitySchemaRole) || catalog.some(type => known.has(type.name))) throw new Error("Existing community definitions require an explicit comparison, never replacement.");
  const additions = catalog.map(type => {
    const fields = Object.entries(type.fields).map(([name, kind]) => `        ${name} ${kind}${type.indexes?.[name] ? " " + type.indexes[name].join(" ") : ""}`);
    if (type.indexes) fields.unshift('        "___recordID" REFERENCE QUERYABLE SORTABLE');
    fields.push(`        GRANT READ, CREATE, WRITE TO ${communitySchemaRole}`);
    return `    RECORD TYPE ${type.name} (\n${fields.join(",\n")}\n    );`;
  });
  const schema = original + `\n    CREATE ROLE ${communitySchemaRole};\n\n` + additions.join("\n\n") + "\n";
  const after = inspectSchema(schema);
  const originalTypes = after.types.filter(type => known.has(type.name));
  if (JSON.stringify(originalTypes) !== JSON.stringify(before.types)) throw new Error("Existing schema changed.");
  for (const type of after.types.filter(type => !known.has(type.name))) {
    if (type.grants.length !== 1 || type.grants[0].role !== communitySchemaRole || type.grants[0].rights.join() !== "READ,CREATE,WRITE") throw new Error("New type privileges unavailable.");
  }
  return { schema, scope: { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development" },
    inputSHA256: createHash("sha256").update(original).digest("hex"), proposedSHA256: createHash("sha256").update(schema).digest("hex"),
    preservedTypes: before.types.map(type => type.name), addedRole: communitySchemaRole, addedTypes: after.types.filter(type => !known.has(type.name)),
    remoteValidation: "not performed", remoteImport: false, roleAssignments: [], dataOperations: [] };
}
export function verifyCommunityProposal(original, proposed) {
  const expected = prepareCommunitySchema(original);
  if (proposed !== expected.schema) throw new Error("Proposed schema differs from the reviewed additive contract.");
  return { inputSHA256: expected.inputSHA256, proposedSHA256: expected.proposedSHA256 };
}
/** Read-back comparison only; the caller must independently verify the console scope. */
export function verifyInstalledCommunitySchema(original, installed) {
  const expected = inspectSchema(prepareCommunitySchema(original).schema), actual = inspectSchema(installed);
  const newTypes = new Set(catalog.map(type => type.name));
  const implicit = { ___createTime: "TIMESTAMP", ___createdBy: "REFERENCE", ___etag: "STRING", ___modTime: "TIMESTAMP",
    ___modifiedBy: "REFERENCE", ___recordID: "REFERENCE" };
  const canonical = schema => ({ roles: [...schema.roles].sort(), types: schema.types.map(type => {
    const fields = Object.entries(type.fields).filter(([name, field]) => {
      const specified = expected.types.find(candidate => candidate.name === type.name)?.fields[name];
      return !(newTypes.has(type.name) && !specified && implicit[name] === field.type && field.options.length === 0);
    }).sort(([a], [b]) => a.localeCompare(b)).map(([name, field]) => [name, field.type, [...field.options].sort()]);
    const grants = type.grants.map(grant => [grant.role, [...grant.rights].sort()]).sort(([a], [b]) => a.localeCompare(b));
    return { name: type.name, fields, grants };
  }).sort((a, b) => a.name.localeCompare(b.name)) });
  if (JSON.stringify(canonical(actual)) !== JSON.stringify(canonical(expected))) throw new Error("Installed schema differs from the approved contract.");
  return { types: expected.types.length, roles: expected.roles.length, installedSHA256: createHash("sha256").update(installed).digest("hex") };
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 5) throw new Error("Provide original schema, proposed schema and report paths. This command performs no network operations.");
  const result = prepareCommunitySchema(await readFile(process.argv[2], "utf8"));
  await writeFile(process.argv[3], result.schema);
  const { schema, ...report } = result; await writeFile(process.argv[4], JSON.stringify(report, null, 2) + "\n");
}
