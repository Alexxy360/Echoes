import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
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
export async function avatarReadWorkerdProof(request, storage, { http = false } = {}) {
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length > 262144) throw new Error("Synthetic fixture limit");
  const p = JSON.parse(new TextDecoder().decode(bytes));
  if (p.synthetic !== "echoes-owned-local-avatar-proof-v1" || !Number.isSafeInteger(p.now)) throw new Error("Synthetic fixture required");
  const clock = () => p.now, proofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
  new AuthenticationState(storage, { clock, renewalProofs: proofs });
  new CommunityState(storage, { clock }); new PublicRecordRegistry(storage, { clock });
  new GatewayLimits(storage, { clock }); new AccountDeletionState(storage, { clock });
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
    if (http) {
      const secret = () => randomBytes(32).toString("base64url");
      const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
        ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_READ_ENABLED: "1",
        AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
        CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: p.privateKeyPEM, APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: p.signInPrivateKeyPEM,
        REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
      const fetchImplementation = async (req, options) => {
        if (new URL(req.url).origin === "https://api.apple-cloudkit.com") return provider(req);
        const url = new URL(req.url); downloadCount++;
        if (url.hostname !== "synthetic-avatar.icloud-content.com" || req.method !== "GET" || req.redirect !== "manual" ||
            [...req.headers.keys()].sort().join() !== "accept,cache-control") throw new Error("Synthetic asset scope mismatch");
        const bytes = Buffer.from(files.get(url.pathname.slice("/private/".length)), "base64");
        return new Response(bytes, { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length) } });
      };
      const runtime = createGatewayRuntime(storage, env, { clock, fetchImplementation });
      const id = { toString: () => "synthetic-avatar-http-authority" };
      env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw new Error("Wrong synthetic authority"); return id; },
        get(object) { if (object !== id) throw new Error("Wrong synthetic object"); return { fetch: req => handleAuthorityRequest(req, { runtime, env, objectID: id, clock }) }; } };
      const { accessToken, ...selection } = p.input; delete selection.signal;
      const incoming = new Request("https://synthetic-avatar-edge.invalid/v1/community/avatar/read", { method: "POST",
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + accessToken, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(selection), signal: request.signal });
      // Explicit platform metadata model: the actual Cloudflare edge is not contacted.
      Object.defineProperty(incoming, "cf", { value: { colo: "WAW" } });
      const response = await forwardGatewayRequest(incoming, env, { clock });
      response.headers.set("X-Synthetic-Download-Count", String(downloadCount)); return response;
    }
    const finalize = await reader.prepare({ ...p.input, signal: request.signal }); await checkpoint.advance();
    const response = finalize(); response.headers.set("X-Synthetic-Download-Count", String(downloadCount)); return response;
  } catch (error) { return Response.json({ error: error.code ?? "SYNTHETIC_UNAVAILABLE", downloadCount }, { status: 400 }); }
}
