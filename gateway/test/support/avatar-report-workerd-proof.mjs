import { Buffer } from "node:buffer";
import { randomBytes, createPublicKey, createHash, verify } from "node:crypto";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";

// Loopback-only local proof. Accounts/provider/platform metadata are explicit synthetic models.
export async function avatarReportWorkerdProof(request, storage) {
  const raw = new Uint8Array(await request.arrayBuffer()); if (raw.length > 262144) throw Error("Fixture too large");
  const p = JSON.parse(new TextDecoder().decode(raw));
  if (p.synthetic !== "echoes-owned-local-photo-report-v1" || !Number.isSafeInteger(p.now)) throw Error("Synthetic fixture required");
  const clock = () => p.now, renewalProofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
  new AuthenticationState(storage, { clock, renewalProofs }); new CommunityState(storage, { clock }); new PublicRecordRegistry(storage, { clock });
  new GatewayLimits(storage, { clock }); new AccountDeletionState(storage, { clock });
  const allowed = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(r => r.name));
  let rows = 0;
  storage.transactionSync(() => {
    for (const table of p.tables) {
      if (!allowed.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || (rows += table.rows.length) > 10000) throw Error("Unexpected synthetic table");
      const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(r => r.name));
      storage.sql.exec(`DELETE FROM ${table.name}`);
      for (const row of table.rows) {
        const keys = Object.keys(row); if (keys.some(k => !columns.has(k) || !/^[a-z0-9_]+$/.test(k))) throw Error("Unexpected synthetic column");
        storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(k => row[k]));
      }
    }
  }); await storage.sync();
  const records = new Map(p.records.map(r => [r.recordName, r])), publicKey = createPublicKey(p.privateKeyPEM);
  let sequence = 0, creates = 0, lostACK = false, loseNextACK = false, lookups = 0;
  const provider = async req => {
    const url = new URL(req.url), raw = await req.text(), body = JSON.parse(raw), hash = createHash("sha256").update(raw).digest("base64");
    if (url.origin !== "https://api.apple-cloudkit.com" || req.method !== "POST" || req.redirect !== "manual" ||
      !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${hash}:${url.pathname}`), publicKey,
        Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw Error("Synthetic signature mismatch");
    if (url.pathname.endsWith("/records/lookup")) { lookups++; return Response.json({ records: body.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) }); }
    if (!url.pathname.endsWith("/records/modify") || body.operations.length !== 1) throw Error("Unexpected synthetic provider operation");
    const op = body.operations[0], old = records.get(op.record.recordName);
    if (op.record.recordName === checkpointRecordName) {
      if (op.operationType !== "replace" || old.recordChangeTag !== op.record.recordChangeTag) return Response.json({ records: [{ recordName: checkpointRecordName, serverErrorCode: "CONFLICT" }] });
    } else {
      if (op.operationType !== "create" || op.record.recordType !== "EchoesAvatarReportV1" || old || !p.allowedReportIDs.includes(op.record.recordName)) throw Error("Unexpected synthetic report mutation");
      creates++;
    }
    const saved = { ...op.record, recordChangeTag: "photo-report-proof-" + ++sequence }; records.set(saved.recordName, saved);
    if (loseNextACK && saved.recordType === "EchoesAvatarReportV1") { loseNextACK = false; lostACK = true; throw Error("Synthetic lost acknowledgement"); }
    return Response.json({ records: [saved] });
  };
  const secret = () => randomBytes(32).toString("base64url");
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_REPORT_ENABLED: "1", AVATAR_READ_ENABLED: "1",
    AVATAR_DOWNLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]', CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development",
    CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: p.privateKeyPEM, APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: p.signInPrivateKeyPEM,
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const options = { clock, fetchImplementation: provider }; let runtime = createGatewayRuntime(storage, env, options);
  const id = { toString: () => "synthetic-photo-report-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw Error("Unexpected synthetic authority"); return id; }, get(object) {
    if (object !== id) throw Error("Unexpected synthetic object"); return { fetch: req => handleAuthorityRequest(req, { runtime, env, objectID: id, clock }) };
  } };
  const call = async (action, body, token = p.accessToken) => {
    const req = new Request("https://synthetic-photo-report.invalid/v1/community/avatar/report" + (action === "recover" ? "/recover" : ""), { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + token, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(body), signal: request.signal });
    Object.defineProperty(req, "cf", { value: { colo: "WAW" } });
    const response = await forwardGatewayRequest(req, env, { clock });
    if (response.headers.get("Cache-Control") !== "no-store" || response.headers.get("X-Content-Type-Options") !== "nosniff") throw Error("Unsafe response");
    return { status: response.status, body: await response.json() };
  };
  const accepted = await call("submit", p.first); p.now += 10000; loseNextACK = true;
  const unknown = await call("submit", p.second), beforeRecovery = creates;
  env.AVATAR_READ_ENABLED = "0"; env.AVATAR_DOWNLOAD_HOSTS_JSON = "[]";
  runtime = createGatewayRuntime(storage, env, options);
  const recovered = await call("recover", { requestID: p.second.requestID });
  const foreign = await call("recover", { requestID: p.second.requestID }, p.foreignToken);
  const deniedSubmit = await call("submit", p.first);
  env.AVATAR_REPORT_ENABLED = "0"; const disabled = await call("recover", { requestID: p.second.requestID });
  const intents = storage.sql.exec("SELECT request_id,ready FROM community_intents_v1 WHERE kind='avatarreport' ORDER BY request_id").toArray();
  const budgetRows = storage.sql.exec("SELECT kind,count FROM gateway_windows_v1 WHERE kind LIKE 'avatar-report%' ORDER BY kind,count").toArray();
  return Response.json({ accepted, unknown, recovered, foreign, deniedSubmit, disabled, creates, beforeRecovery, lostACK, lookups, intents, budgetRows });
}
