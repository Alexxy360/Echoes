import { DatabaseSync } from "node:sqlite";
import { randomUUID, randomBytes, createPrivateKey, createPublicKey } from "node:crypto";
import { readFile, mkdtemp, chmod } from "node:fs/promises";
import { openSync, closeSync, fsyncSync, lstatSync, constants } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { initSync } from "jpeg-encoder-wasm/pkg/esm/jpeg_encoder.js";
import { encodeJpeg, WasmColorType, WasmSamplingFactor } from "jpeg-encoder-wasm";
import { AvatarNormalizer, normalizedAvatarManifest } from "../src/avatar-normalizer.mjs";
import { AvatarReceiptVault } from "../src/avatar-receipt-vault.mjs";
import { CloudKitAvatarAssets } from "../src/cloudkit-avatar-assets.mjs";
import { CloudKitAvatarRepository } from "../src/cloudkit-avatar-repository.mjs";
import { CloudKitPublicClient } from "../src/cloudkit-public-client.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint, checkpointRecord, validCheckpoint, checkpointFields } from "../src/public-registry-checkpoint.mjs";
import { avatarDescriptor, validateAvatarRecord, avatarMetadata } from "../src/avatar-record-schema.mjs";
import { AvatarDownloadScope, avatarDownloadHosts, avatarDownloadURL } from "../src/avatar-protected-download.mjs";
import { digest, recordIdentity, plain, publicUUID, validTag, matchesFields } from "../src/public-record-schema.mjs";
import { queryCanonical } from "./community-query-plan.mjs";
import { readProtocolPrivateFile, ensureProtocolParent, publishProtocolPrivateJSON, requireProtocolFileAbsent } from "./community-protocol-files.mjs";

const purpose = "echoes-avatar-assets-development-v1";
const scope = Object.freeze({ team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development", database: "public",
  reviewedSchemaSHA256: "495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543" });
const limits = Object.freeze({ apiRequests: 64, grants: 2, uploads: 2, downloads: 2, uploadedBytes: 16384,
  jsonBytes: 16384, requestMilliseconds: 8000, windowMilliseconds: 1800000 });
// Upload host is observed. Download candidates are trial-only, not verified production configuration.
const uploadHosts = ["cws.icloud-content.com"], downloadHosts = ["cws.icloud-content.com", "cvws.icloud-content.com"];
const registeredKey = Object.freeze({ keyID: "e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10",
  publicKeySHA256: "dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60" });
const providerErrors = new Set(["BAD_REQUEST", "ACCESS_DENIED", "AUTHENTICATION_FAILED", "AUTHENTICATION_REQUIRED",
  "THROTTLED", "QUOTA_EXCEEDED", "INTERNAL_ERROR", "TRY_AGAIN_LATER", "NOT_FOUND", "EXISTS", "CONFLICT"]);
// Closed heuristic hints, not provider text or a statement of the underlying cause.
function failureHints(bytes) {
  try {
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    const code = plain(body) && typeof body.serverErrorCode === "string" ? body.serverErrorCode : null;
    const reason = plain(body) && typeof body.reason === "string" ? body.reason : "";
    return { providerErrorCode: code === null ? null : providerErrors.has(code) ? code : "OTHER",
      providerReasonCategory: /asset/i.test(reason) && /type|enum/i.test(reason) ? "asset_type" :
        /asset/i.test(reason) && /receipt|checksum|reference/i.test(reason) ? "asset_receipt" :
        /field|column|record type/i.test(reason) && /unknown|not found|invalid/i.test(reason) ? "schema_field" : "other" };
  } catch { return { providerErrorCode: null, providerReasonCategory: "unreadable" }; }
}
const fail = code => { throw new AssetTrialError(code); };
const exact = (value, keys) => plain(value) && Object.keys(value).sort().join() === [...keys].sort().join();
const same = (a, b) => queryCanonical(a) === queryCanonical(b);
const readJSON = (path, limit = 16384) => {
  const f = readProtocolPrivateFile(path, limit);
  try { return { ...f, value: JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(f.bytes)) }; }
  finally { f.bytes.fill(0); }
};
export class AssetTrialError extends Error {
  constructor(code = "ASSET_TRIAL_INCOMPLETE") { super("Development asset trial refused or incomplete."); this.code = code; }
}
async function codecs() {
  return { decoderModule: await WebAssembly.compile(await readFile(new URL("../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm", import.meta.url))),
    encoderModule: await WebAssembly.compile(await readFile(new URL("../node_modules/jpeg-encoder-wasm/pkg/esm/jpeg_encoder_bg.wasm", import.meta.url))) };
}
async function normalized(plan) {
  const modules = await codecs(); initSync({ module: modules.encoderModule });
  const pixels = new Uint8Array(192 * 96 * 4);
  for (let y = 0; y < 96; y++) for (let x = 0; x < 192; x++) pixels.set([x, y * 2, 110, 255], (y * 192 + x) * 4);
  const bytes = encodeJpeg(pixels, 192, 96, WasmColorType.Rgba,
    { quality: 80, samplingFactor: WasmSamplingFactor.F_2_2, chromaSubsampling: "average" });
  pixels.fill(0);
  try { return await new AvatarNormalizer({ ...modules, isEnabled: () => true }).prepare({ bytes,
    versionID: plan.versionID, requestID: plan.requestID, authorize: () => ({ accountID: plan.accountID }) }); }
  finally { bytes.fill(0); }
}
function openRegistry(directory, create = false) {
  const path = join(directory, "registry.sqlite");
  if (create) closeSync(openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600));
  else {
    const info = lstatSync(path);
    if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0 || info.uid !== process.getuid()) fail("ASSET_TRIAL_STATE");
  }
  const db = new DatabaseSync(path); db.exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=0;");
  const storage = {
    sql: { exec(sql, ...bindings) { const rows = db.prepare(sql).all(...bindings); return { toArray: () => rows }; } },
    transactionSync(action) { db.exec("BEGIN IMMEDIATE"); try { const result = action(); db.exec("COMMIT"); return result; }
      catch (error) { db.exec("ROLLBACK"); throw error; } },
    async sync() { for (const file of [path, directory]) { const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW); try { fsyncSync(fd); } finally { closeSync(fd); } } },
  };
  db.exec("CREATE TABLE IF NOT EXISTS auth_accounts_v1(account_id TEXT PRIMARY KEY,generation INTEGER NOT NULL,disabled INTEGER NOT NULL)");
  return { db, storage, registry: new PublicRecordRegistry(storage), close() { db.close(); } };
}
function verifyPrepared(prepared) {
  if (!exact(prepared, ["plan", "sha256"]) || prepared.sha256 !== digest(queryCanonical(prepared.plan))) fail("ASSET_TRIAL_INVENTORY");
  const p = prepared.plan;
  if (!exact(p, ["schemaVersion", "purpose", "scope", "runID", "accountID", "versionID", "requestID", "avatarRecordName", "checkpointName", "initialCheckpoint", "descriptor", "uploadHosts", "downloadHosts", "limits"]) ||
      p.schemaVersion !== 1 || p.purpose !== purpose || !same(p.scope, scope) || !same(p.limits, limits) ||
      !same(p.uploadHosts, uploadHosts) || !same(p.downloadHosts, downloadHosts) ||
      [p.runID, p.accountID, p.versionID, p.requestID].some(id => typeof id !== "string" || !publicUUID.test(id)) ||
      p.checkpointName !== "community-registry-checkpoint-trial-v1-" + p.runID ||
      p.avatarRecordName !== recordIdentity(p.accountID, "avatar", p.versionID).recordName ||
      !validCheckpoint(p.initialCheckpoint) || p.initialCheckpoint.parentAnchorID !== "" || p.initialCheckpoint.registeredCount !== 0) fail("ASSET_TRIAL_INVENTORY");
  const descriptor = avatarDescriptor({ image: p.descriptor?.image, thumbnail: p.descriptor?.thumbnail, requestID: p.requestID }, p.accountID);
  if (!same(descriptor, p.descriptor) || descriptor.image.versionID !== p.versionID ||
      descriptor.image.byteCount + descriptor.thumbnail.byteCount > limits.uploadedBytes) fail("ASSET_TRIAL_INVENTORY");
  return prepared;
}
export async function prepareAssetTrial(parent) {
  await ensureProtocolParent(parent); const directory = await mkdtemp(join(parent, "echoes-avatar-assets-")); await chmod(directory, 0o700);
  const store = openRegistry(directory, true);
  try {
    const p = { schemaVersion: 1, purpose, scope, runID: randomUUID(), accountID: randomUUID(), versionID: randomUUID(), requestID: randomUUID() };
    store.db.prepare("INSERT INTO auth_accounts_v1 VALUES(?,1,0)").run(p.accountID);
    p.avatarRecordName = recordIdentity(p.accountID, "avatar", p.versionID).recordName;
    p.checkpointName = "community-registry-checkpoint-trial-v1-" + p.runID;
    p.initialCheckpoint = await store.registry.prepareBootstrap();
    const handle = await normalized(p);
    p.descriptor = avatarDescriptor({ image: normalizedAvatarManifest(handle, "image"), thumbnail: normalizedAvatarManifest(handle, "thumbnail"), requestID: p.requestID }, p.accountID);
    p.uploadHosts = uploadHosts; p.downloadHosts = downloadHosts; p.limits = limits;
    const prepared = verifyPrepared({ plan: p, sha256: digest(queryCanonical(p)) });
    await publishProtocolPrivateJSON(join(directory, "inventory.json"), prepared);
    await publishProtocolPrivateJSON(join(directory, "receipt-key.json"), { activeKeyID: "trial-v1", keys: { "trial-v1": randomBytes(32).toString("base64url") } });
    await store.storage.sync(); return { directory, prepared };
  } finally { store.close(); }
}

/** Retain native fetch AND body/cancel work. No URL, signature or provider body is persisted. */
export class AssetTrialTransport {
  #plan; #fetch; #check; #save; #counts = { api: 0, grants: 0, uploads: 0, downloads: 0 }; #pending = new Set();
  #diagnostics = null;
  #grants = new Set(); #uploads = new Set(); #downloads = new Set(); #downloadURLs = new Set(); #creates = new Set();
  constructor({ plan, fetchImplementation, check, saveIntent }) {
    this.#plan = verifyPrepared({ plan, sha256: digest(queryCanonical(plan)) }).plan;
    this.#fetch = fetchImplementation; this.#check = check; this.#save = saveIntent;
  }
  get counts() { return { ...this.#counts }; }
  get diagnostics() { return this.#diagnostics && { ...this.#diagnostics }; }
  get creates() { return new Set(this.#creates); }
  allowDownload(url) { this.#downloadURLs.add(avatarDownloadURL(url, avatarDownloadHosts(this.#plan.downloadHosts))); }
  async fetch(request, options = {}) {
    this.#check(); if (this.#pending.size) fail("ASSET_TRIAL_PENDING_IO");
    if (!(request instanceof Request) || request.redirect !== "manual" || !options.signal || options.signal.aborted) fail("ASSET_TRIAL_SCOPE");
    const u = new URL(request.url), p = this.#plan; let kind, variant, operation, mutations;
    if (u.origin === "https://api.apple-cloudkit.com") {
      const base = "https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/";
      operation = request.url.slice(base.length);
      if (!request.url.startsWith(base) || request.method !== "POST" || !["assets/upload", "records/lookup", "records/modify"].includes(operation) || this.#counts.api >= limits.apiRequests) fail("ASSET_TRIAL_SCOPE");
      this.#counts.api++;
      const body = await request.clone().json();
      if (operation === "assets/upload") {
        if (!exact(body, ["tokens"]) || !Array.isArray(body.tokens) || body.tokens.length !== 1) fail("ASSET_TRIAL_SCOPE");
        const t = body.tokens[0]; variant = t?.fieldName;
        if (!exact(t, ["recordName", "recordType", "fieldName"]) || t.recordName !== p.avatarRecordName || t.recordType !== "EchoesAvatarV1" ||
            !["image", "thumbnail"].includes(variant) || this.#grants.has(variant) || this.#counts.grants >= limits.grants) fail("ASSET_TRIAL_SCOPE");
        this.#counts.grants++; this.#grants.add(variant);
      } else {
        let records;
        if (operation === "records/lookup") {
          if (!exact(body, ["records"]) || !Array.isArray(body.records) || body.records.some(row => !exact(row, ["recordName"]))) fail("ASSET_TRIAL_SCOPE");
          records = body.records;
        } else {
          if (!exact(body, ["atomic", "operations"]) || body.atomic !== false || !Array.isArray(body.operations)) fail("ASSET_TRIAL_SCOPE");
          records = body.operations.map(op => {
            if (!exact(op, ["operationType", "record"]) || !["create", "replace", "delete"].includes(op.operationType)) fail("ASSET_TRIAL_SCOPE");
            const row = op.record, checkpoint = row?.recordName === p.checkpointName;
            if (!exact(row, ["recordName", "recordType", ...(op.operationType === "create" ? [] : ["recordChangeTag"]), ...(op.operationType === "delete" ? [] : ["fields"])]) ||
                row.recordType !== (checkpoint ? "EchoesRegistryCheckpointV1" : "EchoesAvatarV1") ||
                op.operationType !== "create" && !validTag(row.recordChangeTag) ||
                !checkpoint && op.operationType === "replace" ||
                op.operationType === "delete" && !this.#creates.has(row.recordName)) fail("ASSET_TRIAL_SCOPE");
            if (checkpoint && op.operationType !== "delete") {
              const value = Object.fromEntries(Object.entries(row.fields).map(([k, f]) => [k, f?.value]));
              if (!validCheckpoint(value) || value.registryID !== p.initialCheckpoint.registryID ||
                  !matchesFields(row.fields, checkpointFields(value)) || op.operationType === "create" && !same(value, p.initialCheckpoint)) fail("ASSET_TRIAL_SCOPE");
            }
            return row;
          });
        }
        if (!records.length || records.length > 2 || new Set(records.map(r => r.recordName)).size !== records.length ||
            records.some(r => ![p.avatarRecordName, p.checkpointName].includes(r.recordName))) fail("ASSET_TRIAL_SCOPE");
        if (operation === "records/modify") for (const op of body.operations) if (op.operationType === "create") {
          if (this.#creates.has(op.record.recordName)) fail("ASSET_TRIAL_REPEAT"); this.#creates.add(op.record.recordName);
        }
        if (operation === "records/modify") mutations = body.operations.map(op => ({ operationType: op.operationType, recordName: op.record.recordName }));
      }
      kind = "api";
    } else {
      if (u.protocol !== "https:" || u.port || u.username || u.password || u.hash || request.credentials !== "omit" || request.headers.has("authorization") ||
          [...request.headers.keys()].some(k => !["content-type", "cache-control", "accept"].includes(k))) fail("ASSET_TRIAL_SCOPE");
      if (request.method === "POST" && p.uploadHosts.includes(u.hostname)) {
        const bytes = new Uint8Array(await request.clone().arrayBuffer());
        try { variant = ["image", "thumbnail"].find(v => p.descriptor[v].sha256 === digest(bytes) && p.descriptor[v].byteCount === bytes.byteLength); }
        finally { bytes.fill(0); }
        if (!variant || !this.#grants.has(variant) || this.#uploads.has(variant) || this.#counts.uploads >= limits.uploads) fail("ASSET_TRIAL_SCOPE");
        this.#counts.uploads++; this.#uploads.add(variant); kind = "upload";
      } else if (request.method === "GET" && this.#downloadURLs.has(request.url) && p.downloadHosts.includes(u.hostname)) {
        if (this.#downloads.has(request.url) || this.#counts.downloads >= limits.downloads) fail("ASSET_TRIAL_SCOPE");
        this.#counts.downloads++; this.#downloads.add(request.url); kind = "download";
      } else fail("ASSET_TRIAL_SCOPE");
    }
    this.#check(); await this.#save({ kind, ...(operation ? { operation } : {}), ...(variant ? { variant } : {}), ...(mutations ? { mutations } : {}), counts: this.counts }); this.#check();
    this.#diagnostics = { kind, ...(operation ? { operation } : {}), ...(variant ? { variant } : {}), httpStatus: null, decodedBytes: null };
    const controller = new AbortController(); let rejectAbort;
    const cancelled = new Promise((_, reject) => { rejectAbort = reject; });
    const abort = () => { controller.abort(); rejectAbort(new AssetTrialError("ASSET_TRIAL_CANCELLED")); };
    options.signal.addEventListener("abort", abort, { once: true });
    const timer = setTimeout(abort, limits.requestMilliseconds);
    if (options.signal.aborted) abort();
    const work = this.#perform(request, { signal: controller.signal }, kind).finally(() => {
      clearTimeout(timer); options.signal.removeEventListener("abort", abort);
    }); this.#pending.add(work);
    void work.then(() => this.#pending.delete(work), () => this.#pending.delete(work)); return await Promise.race([work, cancelled]);
  }
  async #perform(request, options, kind) {
    let response, reader;
    try {
      response = await this.#fetch(request, options); this.#check();
      if (response instanceof Response) this.#diagnostics = { ...this.#diagnostics, httpStatus: response.status,
        jsonContentType: /^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") ?? ""),
        contentEncoding: [null, "identity", "gzip", "x-gzip", "deflate", "br"].includes(response.headers.get("content-encoding")) ? response.headers.get("content-encoding") : "other" };
      if (!(response instanceof Response) || response.redirected || response.url && response.url !== request.url || !response.body) fail("ASSET_TRIAL_RESPONSE");
      const max = kind === "download" ? limits.uploadedBytes : limits.jsonBytes;
      const encoding = response.headers.get("content-encoding") ?? "identity", length = response.headers.get("content-length");
      if (length !== null && (!/^\d+$/.test(length) || +length > max) ||
          (kind === "download" ? !["identity"].includes(encoding) : !["identity", "gzip", "x-gzip", "deflate", "br"].includes(encoding))) fail("ASSET_TRIAL_RESPONSE");
      const parts = []; let size = 0; reader = response.body.getReader();
      while (true) {
        this.#check(); if (options.signal.aborted) fail("ASSET_TRIAL_CANCELLED"); const { done, value } = await reader.read(); if (done) break;
        if (!(value instanceof Uint8Array) || !value.byteLength || parts.length >= 64 || (size += value.byteLength) > max) fail("ASSET_TRIAL_RESPONSE"); parts.push(value.slice());
      }
      this.#check(); if (options.signal.aborted || encoding === "identity" && length !== null && size !== +length) fail("ASSET_TRIAL_RESPONSE");
      this.#diagnostics = { ...this.#diagnostics, decodedBytes: size };
      const bytes = new Uint8Array(size); let at = 0; for (const part of parts) { bytes.set(part, at); at += part.length; part.fill(0); }
      if (!response.ok) {
        try {
          if (this.#diagnostics.jsonContentType) this.#diagnostics = { ...this.#diagnostics, ...failureHints(bytes) };
          fail("ASSET_TRIAL_RESPONSE");
        } finally { bytes.fill(0); }
      }
      return new Response(bytes, { status: response.status, headers: response.headers });
    } finally { if (reader) { await reader.cancel(); reader.releaseLock(); } else await response?.body?.cancel(); }
  }
  async drain(milliseconds = 8000) {
    let timer;
    try { return await Promise.race([Promise.allSettled([...this.#pending]).then(() => true), new Promise(resolve => { timer = setTimeout(() => resolve(false), milliseconds); })]); }
    finally { clearTimeout(timer); }
  }
}

export async function assetTrialCommand(args, { env = process.env, clock = Date.now, monotonic = () => performance.now(), fetchImplementation = fetch, signal,
  keyRegistration = registeredKey } = {}) {
  const [command, directory, sha256, permitPath, keyPath] = args;
  if (command === "prepare" && args.length === 2) {
    const result = await prepareAssetTrial(directory); return { status: "prepared", directory: result.directory, planSHA256: result.prepared.sha256, networkRequests: 0 };
  }
  if (!(command === "inspect" && args.length === 3 || command === "run" && args.length === 5)) fail("ASSET_TRIAL_USAGE");
  await ensureProtocolParent(directory); const prepared = verifyPrepared(readJSON(join(directory, "inventory.json")).value);
  if (sha256 !== prepared.sha256) fail("ASSET_TRIAL_INVENTORY");
  const p = prepared.plan;
  if (command === "inspect") return { status: "inspected", planSHA256: sha256, records: 2, descriptor: p.descriptor,
    uploadHosts: p.uploadHosts, downloadHostCandidates: p.downloadHosts, networkRequests: 0 };
  if (env.ECHOES_ALLOW_ASSET_TRIAL_DEV !== "1") fail("ASSET_TRIAL_DISABLED");
  try { requireProtocolFileAbsent(join(directory, "attempt.json")); } catch { fail("ASSET_TRIAL_CONSUMED"); }
  const permitFile = readJSON(permitPath), permit = permitFile.value, now = clock(), startMono = monotonic();
  if (!exact(permit, ["schemaVersion", "purpose", "scope", "planSHA256", "window", "keyID", "publicKeySHA256", "identityModel"]) ||
      permit.schemaVersion !== 1 || permit.purpose !== purpose || permit.planSHA256 !== sha256 || !same(permit.scope, scope) ||
      permit.identityModel !== "individual-owner-administrator-v1" || !exact(permit.window, ["id", "issuedAt", "expiresAt"]) || !publicUUID.test(permit.window.id ?? "") ||
      !Number.isSafeInteger(now) || !Number.isSafeInteger(permit.window.issuedAt) || !Number.isSafeInteger(permit.window.expiresAt) ||
      permit.window.issuedAt > now || now >= permit.window.expiresAt || permit.window.expiresAt - permit.window.issuedAt < 1 ||
      permit.window.expiresAt - permit.window.issuedAt > limits.windowMilliseconds || !Number.isFinite(startMono) ||
      permit.keyID !== keyRegistration.keyID || permit.publicKeySHA256 !== keyRegistration.publicKeySHA256) fail("ASSET_TRIAL_PERMIT");
  const keyFile = readProtocolPrivateFile(keyPath, 8192); let pem;
  try { pem = new TextDecoder("utf-8", { fatal: true }).decode(keyFile.bytes);
    if (digest(createPublicKey(createPrivateKey(pem)).export({ type: "spki", format: "der" })) !== permit.publicKeySHA256) fail("ASSET_TRIAL_KEY");
  } finally { keyFile.bytes.fill(0); }
  const handle = await normalized(p), descriptor = avatarDescriptor({ requestID: p.requestID,
    image: normalizedAvatarManifest(handle, "image"), thumbnail: normalizedAvatarManifest(handle, "thumbnail") }, p.accountID);
  if (!same(descriptor, p.descriptor)) fail("ASSET_TRIAL_INVENTORY");
  const controller = new AbortController(), abort = () => controller.abort(); signal?.addEventListener("abort", abort, { once: true });
  let lastWall = now, lastMono = startMono, sequence = 0, store, transport, client, started = false, protocolSucceeded = false, cleanupSucceeded = false, pendingIO = false, errorCode = null;
  let phase = "preflight", failedPhase = null, failureDiagnostics = null, cleanupErrorCode = null;
  const check = () => {
    const wall = clock(), mono = monotonic(), current = readJSON(permitPath);
    if (signal?.aborted || controller.signal.aborted || env.ECHOES_ALLOW_ASSET_TRIAL_DEV !== "1" || current.sha256 !== permitFile.sha256 || current.identity !== permitFile.identity ||
        !Number.isSafeInteger(wall) || !Number.isFinite(mono) || wall < lastWall || mono < lastMono || wall >= permit.window.expiresAt ||
        mono - startMono >= permit.window.expiresAt - now) fail("ASSET_TRIAL_WINDOW");
    lastWall = wall; lastMono = mono;
  };
  const timer = setTimeout(abort, Math.min(limits.windowMilliseconds, permit.window.expiresAt - now)); timer.unref();
  try {
    check(); requireProtocolFileAbsent(join(directory, "attempt.json")); store = openRegistry(directory);
    if (!same(await store.registry.prepareBootstrap(), p.initialCheckpoint)) fail("ASSET_TRIAL_STATE");
    await publishProtocolPrivateJSON(join(directory, "attempt.json"), { planSHA256: sha256, window: permit.window }); started = true;
    transport = new AssetTrialTransport({ plan: p, fetchImplementation, check, saveIntent: value => publishProtocolPrivateJSON(join(directory, "request-" + String(++sequence).padStart(3, "0") + ".json"), value) });
    const config = { container: scope.container, environment: "development", keyID: permit.keyID, privateKeyPEM: pem,
      isEnabled: () => { check(); return true; }, fetchImplementation: (...values) => transport.fetch(...values), clock };
    client = new CloudKitPublicClient({ ...config, checkpointName: p.checkpointName });
    const signer = new CloudKitDevelopmentSigner(config), checkpoint = new PublicRegistryCheckpoint({ registry: store.registry, client });
    const avatarBefore = (await client.lookup([p.avatarRecordName], { signal: controller.signal })).get(p.avatarRecordName);
    const controlBefore = await client.lookupCheckpoint({ signal: controller.signal });
    if (avatarBefore?.serverErrorCode !== "NOT_FOUND" || controlBefore?.serverErrorCode !== "NOT_FOUND") fail("ASSET_TRIAL_COLLISION");
    await publishProtocolPrivateJSON(join(directory, "preflight-absent.json"), { avatar: true, checkpoint: true });
    let projection, context;
    try {
      phase = "bootstrap";
      await client.createCheckpointForBootstrap(p.initialCheckpoint, { signal: controller.signal }); await checkpoint.verify({ signal: controller.signal });
      const identity = () => { check(); return { accountID: p.accountID }; };
      const assets = new CloudKitAvatarAssets({ ...config, registry: store.registry, checkpoint,
        receiptVault: new AvatarReceiptVault(readJSON(join(directory, "receipt-key.json")).value), verifiedUploadHosts: p.uploadHosts });
      const repository = new CloudKitAvatarRepository({ registry: store.registry, client, assets, checkpoint, authentication: { authorize: identity }, isEnabled: config.isEnabled });
      phase = "stage";
      const result = await repository.stage({ accessToken: "local-synthetic-identity", normalized: handle, requestID: p.requestID, authorizeMutation: identity, signal: controller.signal });
      if (result.status !== "staged") fail("ASSET_TRIAL_RESPONSE");
      context = store.registry.owned(p.accountID, "avatar", p.versionID);
      const record = (await client.lookup([p.avatarRecordName], { signal: controller.signal })).get(p.avatarRecordName);
      projection = validateAvatarRecord(record, context, descriptor, store.registry.avatarAssetCommitments(context));
      phase = "cas";
      const old = checkpointRecord(await client.lookupCheckpoint({ signal: controller.signal }), p.checkpointName);
      await checkpoint.advance({ signal: controller.signal });
      const conflict = await client.replaceCheckpoint({ ...old.value, parentAnchorID: old.value.anchorID, anchorID: randomUUID() }, old.tag, { signal: controller.signal });
      if (conflict?.serverErrorCode !== "CONFLICT") fail("ASSET_TRIAL_CAS");
      for (const variant of ["image", "thumbnail"]) {
        phase = "download_" + variant;
        const url = avatarDownloadURL(projection.assets[variant].downloadURL, avatarDownloadHosts(p.downloadHosts)); transport.allowDownload(url);
        const download = new AvatarDownloadScope().operation();
        try {
          download.adopt(await transport.fetch(new Request(url, { method: "GET", credentials: "omit", redirect: "manual", headers: { Accept: "image/jpeg", "Cache-Control": "no-store" } }), { signal: controller.signal }));
          const bytes = await download.read({ url, manifest: descriptor[variant], signal: controller.signal, check });
          try { if (digest(bytes) !== descriptor[variant].sha256) fail("ASSET_TRIAL_BYTES"); } finally { bytes.fill(0); }
        } finally { await download.finish(client); }
      }
      protocolSucceeded = true;
    } catch (error) { errorCode = safeCode(error); failedPhase = phase; failureDiagnostics = transport.diagnostics; }
    // Cleanup also runs after a rejected upload/read, but only after concrete network work drains.
    phase = "cleanup";
    if (!(await transport.drain())) fail("ASSET_TRIAL_PENDING_IO"); await client.waitForPendingOperations(); check();
    const deletion = [];
    for (const name of transport.creates) {
      const record = name === p.checkpointName ? await client.lookupCheckpoint({ signal: controller.signal }) :
        (await client.lookup([name], { signal: controller.signal })).get(name);
      if (record.serverErrorCode === "NOT_FOUND") continue;
      if (name === p.checkpointName) {
        if (checkpointRecord(record, name).value.registryID !== p.initialCheckpoint.registryID) fail("ASSET_TRIAL_CLEANUP_SCOPE");
      } else {
        context = store.registry.owned(p.accountID, "avatar", p.versionID);
        // A provider-timeout may have committed CREATE before local settle. Compare actual commitments.
        validateAvatarRecord(record, context, descriptor, store.registry.avatarAssetCommitments(context));
        const meta = Object.fromEntries(Object.entries(record.fields).filter(([key]) => !["image", "thumbnail"].includes(key)));
        if (!matchesFields(meta, avatarMetadata(context, descriptor))) fail("ASSET_TRIAL_CLEANUP_SCOPE");
      }
      deletion.push({ operationType: "delete", record: { recordName: name, recordType: record.recordType, recordChangeTag: record.recordChangeTag } });
    }
    if (deletion.length) {
      const request = signer.request("records/modify", { atomic: false, operations: deletion }, new Date(clock()));
      const response = await transport.fetch(request, { signal: controller.signal }); const body = await response.json();
      if (!Array.isArray(body?.records) || body.records.length !== deletion.length || deletion.some(op => !body.records.some(r => r.recordName === op.record.recordName && r.deleted === true && !r.serverErrorCode))) fail("ASSET_TRIAL_CLEANUP");
    }
    for (const name of transport.creates) {
      const record = name === p.checkpointName ? await client.lookupCheckpoint({ signal: controller.signal }) :
        (await client.lookup([name], { signal: controller.signal })).get(name);
      if (record?.serverErrorCode !== "NOT_FOUND") fail("ASSET_TRIAL_CLEANUP");
    }
    cleanupSucceeded = true;
  } catch (error) {
    if (errorCode !== null) cleanupErrorCode = safeCode(error);
    else { errorCode = safeCode(error); failedPhase = phase; failureDiagnostics = transport?.diagnostics ?? null; }
  }
  finally {
    clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", abort);
    const drained = !transport || await transport.drain();
    if (drained) store?.close(); else { pendingIO = true; errorCode = "ASSET_TRIAL_PENDING_IO"; }
  }
  const result = { status: protocolSucceeded && cleanupSucceeded ? "asset_protocol_verified" : "incomplete", protocolSucceeded, cleanupSucceeded, errorCode,
    failedPhase, failureDiagnostics, cleanupErrorCode,
    planSHA256: sha256, counts: transport?.counts ?? { api: 0, grants: 0, uploads: 0, downloads: 0 },
    pendingIO, providerPhysicalAssetDeletionVerified: false, realSessionAuthorizationVerified: false };
  if (started) await publishProtocolPrivateJSON(join(directory, "report.json"), result);
  return result;
}
function safeCode(error) {
  return error instanceof AssetTrialError ? error.code : typeof error?.code === "string" &&
    /^(PUBLIC_[A-Z_]+|AVATAR_DOWNLOAD_RESPONSE)$/.test(error.code) ? error.code : "ASSET_TRIAL_INCOMPLETE";
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const controller = new AbortController(); const abort = () => controller.abort(); process.on("SIGTERM", abort); process.on("SIGINT", abort);
  const watchdog = setTimeout(() => { process.stderr.write('{"status":"incomplete","errorCode":"ASSET_TRIAL_DRAIN_DEADLINE"}\n'); process.exit(3); }, limits.windowMilliseconds + 8000); watchdog.unref();
  let exitCode;
  try { const result = await assetTrialCommand(process.argv.slice(2), { signal: controller.signal }); await new Promise(resolve => process.stdout.write(JSON.stringify(result) + "\n", resolve)); exitCode = result.status === "incomplete" ? 3 : 0; }
  catch (error) { await new Promise(resolve => process.stderr.write(JSON.stringify({ status: "refused", errorCode: safeCode(error) }) + "\n", resolve)); exitCode = 2; }
  finally { clearTimeout(watchdog); process.off("SIGTERM", abort); process.off("SIGINT", abort); }
  // Only this operator process. Durable intents remain; remote completion/physical erasure is not inferred.
  process.exit(exitCode);
}
