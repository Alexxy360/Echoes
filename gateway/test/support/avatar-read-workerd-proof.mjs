import { Buffer } from "node:buffer";
import { randomBytes, createPublicKey, verify } from "node:crypto";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint, checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";
import { CloudKitAvatarReader } from "../../src/cloudkit-avatar-reader.mjs";
import { createHash } from "node:crypto";

/** Owned loopback test data only. This module is never imported into the gateway runtime.
 * Actual workerd SQL/auth/crypto/policy/repository/reader with explicit signed provider/file models.
 */
export async function avatarReadWorkerdProof(request, storage) {
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length > 262144) throw new Error("Synthetic fixture limit");
  const p = JSON.parse(new TextDecoder().decode(bytes));
  if (p.synthetic !== "echoes-owned-local-avatar-proof-v1" || !Number.isSafeInteger(p.now)) throw new Error("Synthetic fixture required");
  const clock = () => p.now, proofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
  new AuthenticationState(storage, { clock, renewalProofs: proofs });
  new CommunityState(storage, { clock }); new PublicRecordRegistry(storage, { clock });
  const allowed = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(r => r.name));
  let rows = 0;
  storage.transactionSync(() => {
    for (const table of p.tables) {
      if (!allowed.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || (rows += table.rows.length) > 10000) throw new Error("Unexpected synthetic table");
      const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(r => r.name));
      storage.sql.exec(`DELETE FROM ${table.name}`);
      for (const row of table.rows) {
        const keys = Object.keys(row);
        if (keys.some(k => !columns.has(k) || !/^[a-z0-9_]+$/.test(k))) throw new Error("Unexpected synthetic column");
        storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(k => row[k]));
      }
    }
  });
  await storage.sync();
  const authentication = new AuthenticationState(storage, { clock, renewalProofs: proofs }), community = new CommunityState(storage, { clock });
  const registry = new PublicRecordRegistry(storage, { clock }), records = new Map(p.records.map(r => [r.recordName, r]));
  const publicKey = createPublicKey(p.privateKeyPEM); let sequence = 0, downloadCount = 0;
  const provider = async req => {
    const url = new URL(req.url), raw = await req.text(), body = JSON.parse(raw), hash = createHash("sha256").update(raw).digest("base64");
    if (url.origin !== "https://api.apple-cloudkit.com" || req.redirect !== "manual" ||
        !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${hash}:${url.pathname}`), publicKey,
          Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw new Error("Synthetic signature mismatch");
    if (url.pathname.endsWith("/records/lookup")) return Response.json({ records: body.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) });
    if (!url.pathname.endsWith("/records/modify") || body.operations.length !== 1 || body.operations[0].record.recordName !== checkpointRecordName) throw new Error("Unexpected synthetic provider operation");
    const op = body.operations[0], old = records.get(checkpointRecordName);
    if (op.operationType !== "replace" || old.recordChangeTag !== op.record.recordChangeTag) return Response.json({ records: [{ recordName: checkpointRecordName, serverErrorCode: "CONFLICT" }] });
    const saved = { ...op.record, recordChangeTag: "local-workerd-proof-" + ++sequence }; records.set(checkpointRecordName, saved);
    return Response.json({ records: [saved] });
  };
  const client = new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-public-v1",
    privateKeyPEM: p.privateKeyPEM, fetchImplementation: provider, isEnabled: () => true, clock });
  const checkpoint = new PublicRegistryCheckpoint({ registry, client });
  const profiles = new CloudKitPublicRepository({ registry, client, authentication, checkpoint, clock });
  const policy = new AvatarPolicyState(storage, { registry, clock }), files = new Map(p.files);
  const reader = new CloudKitAvatarReader({ authentication, communityState: community, avatarPolicy: policy, profileRepository: profiles, registry, client, checkpoint,
    clock, isEnabled: () => true, verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"], fetchImplementation: async req => {
      const url = new URL(req.url); downloadCount++;
      if (url.hostname !== "synthetic-avatar.icloud-content.com" || req.method !== "GET" || req.redirect !== "manual" || req.credentials !== undefined && req.credentials !== "omit" ||
          [...req.headers.keys()].sort().join() !== "accept,cache-control") throw new Error("Synthetic file scope mismatch");
      const file = Buffer.from(files.get(url.pathname.slice("/private/".length)), "base64");
      return new Response(file, { headers: { "Content-Type": "image/jpeg", "Content-Length": String(file.length) } });
    } });
  try {
    const finalize = await reader.prepare({ ...p.input, signal: request.signal }); await checkpoint.advance();
    const response = finalize(); response.headers.set("X-Synthetic-Download-Count", String(downloadCount)); return response;
  } catch (error) { return Response.json({ error: error.code ?? "SYNTHETIC_UNAVAILABLE", downloadCount }, { status: 400 }); }
}
