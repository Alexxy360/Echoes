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
import { avatarReviewHeader } from "../../src/avatar-review-coordinator.mjs";
import { purgeAvatarReviewReceipts } from "../../src/avatar-review-state.mjs";
import { avatarSelectionHeader } from "../../src/avatar-owner-preview-http.mjs";

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
  const reviewOperatorID = new AuthenticationState(storage, { clock, renewalProofs: proofs }).authorize(p.token).accountID;
  const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
    ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", AVATAR_UPLOAD_ENABLED: "1", AVATAR_UPLOAD_HOSTS_JSON: '["synthetic-avatar.icloud-content.com"]',
    AVATAR_REVIEW_ENABLED: p.review === true ? "1" : "0", AVATAR_REVIEWER_IDS_JSON: JSON.stringify(p.review === true ? [reviewOperatorID] : []),
    AVATAR_OWNER_PREVIEW_ENABLED: p.ownerPreview === true ? "1" : "0",
    AVATAR_DOWNLOAD_HOSTS_JSON: p.review === true ? '["synthetic-avatar.icloud-content.com"]' : "[]",
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
  let review, ownerPreview;
  if (p.review === true) {
    const operatorCall = async (action, value, expectedStatus = 200) => {
      const req = new Request("https://synthetic-upload.invalid/v1/moderation/avatar/" + action, { method: "POST", signal: request.signal,
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + p.token, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(value) });
      Object.defineProperty(req, "cf", { value: { colo: "WAW" } });
      const response = await forwardGatewayRequest(req, env, { clock });
      if (response.status !== expectedStatus) throw new Error("Synthetic review status: " + (await response.json()).error);
      return response;
    };
    const missing = await operatorCall("decide", { inspectionID: randomUUID(), decisionID: randomUUID(), verdict: "approved" }, 409);
    const rejectedWithoutInspection = (await missing.json()).error === "AVATAR_REVIEW_STALE";
    const queue = await (await operatorCall("queue", {})).json();
    if (queue.items.length !== 1 || queue.items[0].requestID !== uploaded.requestID) throw new Error("Synthetic review queue");
    const recovery = { ...queue.items[0], decisionID: randomUUID(), verdict: "approved" };
    const unapplied = await (await operatorCall("recover", recovery)).json();
    const image = await operatorCall("inspect", { accountID: reviewOperatorID, requestID: uploaded.requestID });
    const header = JSON.parse(image.headers.get(avatarReviewHeader));
    const shown = new Uint8Array(await image.arrayBuffer()), manifest = JSON.parse(image.headers.get("x-echoes-avatar-manifest"));
    const body = { inspectionID: header.inspectionID, decisionID: recovery.decisionID, verdict: "approved" };
    const approved = await (await operatorCall("decide", body)).json();
    const replayed = await (await operatorCall("decide", body)).json();
    p.now += 90_000; await purgeAvatarReviewReceipts(storage, clock);
    const outcome = await (await operatorCall("recover", recovery)).json();
    const observed = await invoke("status");
    review = { bytesMatch: createHash("sha256").update(shown).digest("hex") === manifest.sha256,
      approved: approved.verdict === "approved", notPublished: observed.publishedVersionID === null && observed.status === "approved",
      exactReplay: approved.revision === replayed.revision && approved.decisionID === replayed.decisionID, rejectedWithoutInspection,
      notApplied: unapplied.outcome === "not-applied" && unapplied.revision === null,
      confirmedAfterExpiry: outcome.outcome === "confirmed" && outcome.revision === approved.revision,
      expiredReceiptsRemoved: storage.sql.exec("SELECT COUNT(*) n FROM avatar_review_receipts_v1").toArray()[0].n === 0,
      actualSQL: storage.sql.exec("SELECT COUNT(*) n FROM avatar_jobs_v1 WHERE decision_id=? AND moderation_state='approved'", body.decisionID).toArray()[0].n === 1 };
    if (p.ownerPreview === true) {
      env.AVATAR_REVIEW_ENABLED = "0"; env.AVATAR_REVIEWER_IDS_JSON = "[]"; env.AVATAR_UPLOAD_ENABLED = "0";
      const selection = { requestID: observed.requestID, versionID: observed.versionID, generation: observed.generation, reviewRevision: observed.reviewRevision };
      const req = new Request("https://synthetic-upload.invalid/v1/community/avatar/preview", { method: "POST", signal: request.signal,
        headers: { "Content-Type": "application/json", Authorization: "Bearer " + p.token, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(selection) });
      Object.defineProperty(req, "cf", { value: { colo: "WAW" } });
      const response = await forwardGatewayRequest(req, env, { clock });
      if (response.status !== 200) throw new Error("Synthetic owner preview: " + (await response.json()).error);
      const manifest = JSON.parse(response.headers.get("x-echoes-avatar-manifest")), proof = JSON.parse(response.headers.get(avatarSelectionHeader));
      const bytes = new Uint8Array(await response.arrayBuffer()), after = await invoke("status");
      ownerPreview = { bytesMatch: createHash("sha256").update(bytes).digest("hex") === manifest.sha256,
        exactSelection: JSON.stringify(proof) === JSON.stringify({ schemaVersion: 1, ...selection }),
        ownImage: manifest.ownerID === reviewOperatorID && manifest.versionID === selection.versionID && manifest.variant === "image",
        privateNoStore: response.headers.get("Cache-Control") === "private, no-store",
        noModeratorRole: env.AVATAR_REVIEW_ENABLED === "0" && env.AVATAR_REVIEWER_IDS_JSON === "[]",
        notPublished: after.status === "approved" && after.publishedVersionID === null };
    }
  }
  const cleared = await invoke("clear", { requestID: randomUUID(), expectedGeneration: uploaded.generation });
  const status = await invoke("status");
  return Response.json({ ...(review ? { review, downloads } : {}), ...(ownerPreview ? { ownerPreview } : {}), uploaded, recovered, cleared, status, uploads, grants: grants.size, signatures,
    assetRecords: [...records.values()].filter(r => r.recordType === "EchoesAvatarV1").length,
    actualSQL: storage.sql.exec("SELECT COUNT(*) AS n FROM avatar_jobs_v1").toArray()[0].n === 1 });
}
