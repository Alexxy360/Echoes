import { Buffer } from "node:buffer";
import { createHash, createPublicKey, randomBytes, randomUUID, verify } from "node:crypto";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { createWorkerAvatarNormalizer } from "../../src/avatar-codecs-workerd.mjs";
import { avatarIntentHeader } from "../../src/avatar-upload-http.mjs";
import { AvatarReviewCoordinator, avatarReviewHeader } from "../../src/avatar-review-coordinator.mjs";
import { AvatarReviewReceipts } from "../../src/avatar-review-state.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { PublicRegistryCheckpoint } from "../../src/public-registry-checkpoint.mjs";

/** Loopback-only fixture with actual Worker/SQLite/Wasm and independently verified S2S signatures.
 * Provider, platform metadata and account proof are models. Never imported by production sources.
 */
export async function avatarUploadWorkerdProof(request, storage) {
  const bytes = new Uint8Array(await request.arrayBuffer()); if (bytes.length > 262144) throw new Error("Synthetic fixture size");
  const p = JSON.parse(new TextDecoder().decode(bytes));
  if (p.synthetic !== "echoes-owned-upload-http-v1" || !Number.isSafeInteger(p.now)) throw new Error("Synthetic fixture required");
  const clock = () => p.now, secret = () => randomBytes(32).toString("base64url");
  const proofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: secret() } });
  new AuthenticationState(storage, { clock, renewalProofs: proofs }); new CommunityState(storage, { clock });
  new PublicRecordRegistry(storage, { clock }); new GatewayLimits(storage, { clock }); new AccountDeletionState(storage, { clock });
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
  const records = new Map(p.records.map(r => [r.recordName, r])), grants = new Map(), files = new Map(), publicKey = createPublicKey(p.privateKeyPEM);
  let signatures = 0, sequence = 0, uploads = 0, downloads = 0;
  const provider = async req => {
    const url = new URL(req.url);
    if (url.origin !== "https://api.apple-cloudkit.com") {
      if (p.review === true && req.method === "GET" && url.hostname === "synthetic-avatar.icloud-content.com" && url.pathname.startsWith("/private/")) {
        if (req.redirect !== "manual" || req.credentials !== undefined && req.credentials !== "omit" || [...req.headers.keys()].sort().join() !== "accept,cache-control") throw new Error("Synthetic download scope");
        const bytes = files.get(url.pathname.slice("/private/".length)); if (!bytes) throw new Error("Synthetic file missing"); downloads++;
        return new Response(bytes.slice(), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length) } });
      }
      if (!grants.has(req.url) || req.redirect !== "manual" || req.method !== "POST" || [...req.headers.keys()].sort().join() !== "cache-control,content-type") throw new Error("Synthetic file scope");
      const token = grants.get(req.url), bytes = new Uint8Array(await req.arrayBuffer()); uploads++;
      files.set(token.recordName + "/" + token.fieldName, bytes);
      return Response.json({ singleFile: { size: bytes.length, fileChecksum: "SYNTHETIC-CHECKSUM-" + createHash("sha256").update(bytes).digest("hex"), receipt: "SYNTHETIC-PRIVATE-" + token.fieldName } });
    }
    const raw = await req.text(), body = JSON.parse(raw), hash = createHash("sha256").update(raw).digest("base64");
    if (req.redirect !== "manual" || !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${hash}:${url.pathname}`), publicKey,
      Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw new Error("Synthetic signature mismatch");
    signatures++;
    if (url.pathname.endsWith("/assets/upload")) {
      const token = body.tokens[0], target = "https://synthetic-avatar.icloud-content.com/upload/" + token.recordName + "/" + token.fieldName;
      grants.set(target, token); return Response.json({ tokens: [{ recordName: token.recordName, fieldName: token.fieldName, url: target }] });
    }
    if (url.pathname.endsWith("/records/lookup")) return Response.json({ records: body.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) });
    if (!url.pathname.endsWith("/records/modify")) throw new Error("Unexpected synthetic operation");
    return Response.json({ records: body.operations.map(op => {
      const old = records.get(op.record.recordName);
      if (op.operationType === "create" ? !!old : op.operationType !== "replace" || !old || old.recordChangeTag !== op.record.recordChangeTag) return { recordName: op.record.recordName, serverErrorCode: "CONFLICT" };
      const saved = structuredClone({ ...op.record, recordChangeTag: "synthetic-upload-" + ++sequence });
      for (const variant of ["image", "thumbnail"]) {
        const value = saved.fields[variant]?.value;
        if (value?.receipt) saved.fields[variant].value = { size: value.size, fileChecksum: value.fileChecksum, downloadURL: "https://synthetic-avatar.icloud-content.com/private/" + saved.recordName + "/" + variant };
      }
      records.set(saved.recordName, saved); return saved;
    }) });
  };
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_UPLOAD_ENABLED: "1", AVATAR_UPLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]',
    CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: p.privateKeyPEM,
    APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: p.signInPrivateKeyPEM,
    REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1", REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }), REQUEST_BUDGET_KEY: secret() };
  const runtime = createGatewayRuntime(storage, env, { clock, fetchImplementation: provider, avatarNormalizerFactory: createWorkerAvatarNormalizer });
  const id = { toString: () => "synthetic-upload-http-authority" };
  env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw new Error("Wrong authority"); return id; }, get(object) {
    if (object !== id) throw new Error("Wrong object"); return { fetch: req => handleAuthorityRequest(req, { runtime, env, objectID: id, clock }) };
  } };
  const invoke = async (action, value = {}) => {
    const req = new Request("https://synthetic-upload.invalid/v1/community/avatar/" + action, { method: "POST", signal: request.signal,
      headers: { "Content-Type": action === "upload" ? "image/jpeg" : "application/json", Authorization: "Bearer " + p.token, "CF-Connecting-IP": "192.0.2.17",
        ...(action === "upload" ? { [avatarIntentHeader]: JSON.stringify(value) } : {}) },
      body: action === "upload" ? Buffer.from(p.source, "base64") : JSON.stringify(value) });
    Object.defineProperty(req, "cf", { value: { colo: "WAW" } });
    const response = await forwardGatewayRequest(req, env, { clock }), body = await response.json();
    if (response.status !== 200) throw new Error("Synthetic upload status: " + body.error); return body;
  };
  const uploaded = await invoke("upload", p.intent), firstUploadCount = uploads;
  const recovered = await invoke("recover", { requestID: p.intent.requestID });
  if (uploads !== firstUploadCount) throw new Error("Recovery repeated a synthetic upload");
  let review;
  if (p.review === true) {
    const registry = new PublicRecordRegistry(storage, { clock });
    const client = new CloudKitPublicClient({ container: env.CLOUDKIT_CONTAINER, environment: "development", keyID: env.CLOUDKIT_KEY_ID,
      privateKeyPEM: p.privateKeyPEM, clock, fetchImplementation: provider, isEnabled: () => true });
    const checkpoint = new PublicRegistryCheckpoint({ registry, client });
    const auth = new AuthenticationState(storage, { clock, renewalProofs: proofs }), policy = new AvatarPolicyState(storage, { registry, clock });
    const ownerID = auth.authorize(p.token).accountID;
    const reviewer = new AvatarReviewCoordinator({ authentication: auth, communityState: new CommunityState(storage, { clock }),
      avatarPolicy: policy, receipts: new AvatarReviewReceipts(storage, { clock }), registry, client, checkpoint,
      isEnabled: () => true, isOperator: id => id === ownerID, clock, verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"], fetchImplementation: provider });
    let rejectedWithoutInspection = false;
    try { await reviewer.prepareDecision({ accessToken: p.token, inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "approved" }); }
    catch (e) { rejectedWithoutInspection = e.code === "AVATAR_REVIEW_STALE"; }
    const show = await reviewer.prepareInspection({ accessToken: p.token, accountID: ownerID, requestID: uploaded.requestID });
    await checkpoint.advance(); const image = show(), header = JSON.parse(image.headers.get(avatarReviewHeader));
    const shown = new Uint8Array(await image.arrayBuffer()), manifest = JSON.parse(image.headers.get("x-echoes-avatar-manifest"));
    const body = { accessToken: p.token, inspectionID: header.inspectionID, decisionID: randomUUID(), verdict: "approved" };
    const decide = await reviewer.prepareDecision(body); await checkpoint.advance(); const approved = decide();
    const repeat = await reviewer.prepareDecision(body); await checkpoint.advance(); const replayed = repeat();
    review = { bytesMatch: createHash("sha256").update(shown).digest("hex") === manifest.sha256,
      approved: approved.verdict === "approved", notPublished: policy.snapshot(ownerID).publishedVersionID === null,
      exactReplay: approved.revision === replayed.revision && approved.decisionID === replayed.decisionID, rejectedWithoutInspection,
      actualSQL: storage.sql.exec("SELECT COUNT(*) n FROM avatar_review_receipts_v1 WHERE result_revision IS NOT NULL").toArray()[0].n === 1 };
  }
  const cleared = await invoke("clear", { requestID: randomUUID(), expectedGeneration: uploaded.generation });
  const status = await invoke("status");
  return Response.json({ ...(review ? { review, downloads } : {}), uploaded, recovered, cleared, status, uploads, grants: grants.size, signatures,
    assetRecords: [...records.values()].filter(r => r.recordType === "EchoesAvatarV1").length,
    actualSQL: storage.sql.exec("SELECT COUNT(*) AS n FROM avatar_jobs_v1").toArray()[0].n === 1 });
}
