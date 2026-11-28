import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { checkpointRecord, sameCheckpoint, validCheckpoint } from "../src/public-registry-checkpoint.mjs";
import { avatarDescriptor, avatarDescriptorHash, validateAvatarRecord } from "../src/avatar-record-schema.mjs";
import { digest, plain, recordIdentity, validTag } from "../src/public-record-schema.mjs";
import { queryCanonical } from "./community-query-plan.mjs";

const fail = code => { throw Object.assign(new Error("Synthetic asset cleanup refused or incomplete."), { cleanupCode: code }); };
const base = "https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/";
/** No generic recovery or publication. Only the exact previously created synthetic inventory. */
export function verifyAssetCleanupExpected({ prepared, context, commitments, checkpoint }) {
  const p = prepared?.plan;
  if (prepared?.sha256 !== digest(queryCanonical(p)) || p?.purpose !== "echoes-avatar-assets-development-v1" ||
      p.scope?.team !== "22YC9RAP4P" || p.scope.container !== "iCloud.mpvEcho.Echo" || p.scope.environment !== "development" || p.scope.database !== "public" ||
      p.checkpointName !== "community-registry-checkpoint-trial-v1-" + p.runID ||
      p.avatarRecordName !== recordIdentity(p.accountID, "avatar", p.versionID).recordName ||
      context?.recordName !== p.avatarRecordName || context.accountID !== p.accountID || context.kind !== "avatar" || context.recordType !== "EchoesAvatarV1" ||
      context.ownerKey !== recordIdentity(p.accountID, "avatar", p.versionID).ownerKey || context.requestID !== p.requestID ||
      context.expectedTag !== null || !["pending", "settled"].includes(context.phase) ||
      !validCheckpoint(checkpoint) || checkpoint.registryID !== p.initialCheckpoint.registryID) fail("CLEANUP_SCOPE");
  const descriptor = avatarDescriptor({ image: p.descriptor.image, thumbnail: p.descriptor.thumbnail, requestID: p.requestID }, p.accountID);
  if (context.payloadHash !== avatarDescriptorHash(descriptor)) fail("CLEANUP_SCOPE");
  for (const v of ["image", "thumbnail"]) if (commitments?.[v]?.sha256 !== descriptor[v].sha256 || commitments[v].byteCount !== descriptor[v].byteCount ||
      !/^[a-f0-9]{64}$/.test(commitments[v].fileChecksumHash ?? "")) fail("CLEANUP_SCOPE");
  return descriptor;
}
function recordMap(body, names) {
  if (!plain(body) || body.serverErrorCode || !Array.isArray(body.records) || body.records.length !== names.length) fail("CLEANUP_RESPONSE");
  const records = new Map();
  for (const r of body.records) {
    if (!plain(r) || !names.includes(r.recordName) || records.has(r.recordName)) fail("CLEANUP_RESPONSE");
    records.set(r.recordName, r);
  }
  return records;
}
/** For deletion only, ignore a bounded optional wire label after checking its shape. Ownership,
 * metadata, both immutable manifests and uploaded-file checksums still pass the production validator.
 * This never relaxes the normal application reader or opens a provider download URL.
 */
export function verifyAssetCleanupAvatar(record, expected) {
  const { prepared, context, commitments } = expected, p = prepared.plan;
  const fields = { ...record.fields };
  for (const v of ["image", "thumbnail"]) {
    const field = fields[v];
    if (!plain(field) || Object.keys(field).some(k => !["type", "value"].includes(k)) ||
        field.type !== undefined && (typeof field.type !== "string" || !/^[A-Z_]{1,32}$/.test(field.type))) fail("CLEANUP_ASSET");
    fields[v] = { value: field.value };
  }
  validateAvatarRecord({ ...record, fields }, context, p.descriptor, commitments);
}
export async function runAssetCleanup({ expected, signer, isAuthorized = () => false, saveIntent, fetchImplementation = fetch, signal, clock = Date.now } = {}) {
  verifyAssetCleanupExpected(expected);
  if (!(signer instanceof CloudKitDevelopmentSigner) || typeof saveIntent !== "function") fail("CLEANUP_SCOPE");
  const p = expected.prepared.plan, names = [p.avatarRecordName, p.checkpointName], pending = new Set();
  let requests = 0, deleted = 0, succeeded = false, errorCode = null, diagnostics = null, assetFieldTypes = null;
  const check = () => { if (signal?.aborted || isAuthorized() !== true) fail("CLEANUP_DISABLED"); };
  const call = async (operation, payload) => {
    check(); if (pending.size || requests >= 3) fail("CLEANUP_LIMIT");
    if (operation === "records/lookup") {
      if (queryCanonical(payload) !== queryCanonical({ records: names.map(recordName => ({ recordName })) })) fail("CLEANUP_SCOPE");
    } else if (operation !== "records/modify" || payload.atomic !== false || !Array.isArray(payload.operations) || !payload.operations.length || payload.operations.length > 2 ||
        new Set(payload.operations.map(o => o.record?.recordName)).size !== payload.operations.length || payload.operations.some(o =>
          Object.keys(o).sort().join() !== "operationType,record" || o.operationType !== "delete" || !names.includes(o.record?.recordName) ||
          Object.keys(o.record).sort().join() !== "recordChangeTag,recordName,recordType" || !validTag(o.record.recordChangeTag) ||
          o.record.recordType !== (o.record.recordName === p.avatarRecordName ? "EchoesAvatarV1" : "EchoesRegistryCheckpointV1"))) fail("CLEANUP_SCOPE");
    const request = signer.request(operation, payload, new Date(clock()));
    if (request.url !== base + operation || request.method !== "POST" || request.redirect !== "manual") fail("CLEANUP_SCOPE");
    await saveIntent({ sequence: ++requests, operation, targets: operation === "records/lookup" ? names : payload.operations.map(o => o.record.recordName) }); check();
    const controller = new AbortController(); let rejectAbort, reader, response, timer;
    const cancelled = new Promise((_, reject) => { rejectAbort = reject; });
    const abort = () => { controller.abort(); void reader?.cancel().catch(() => {}); rejectAbort(Object.assign(new Error(), { cleanupCode: "CLEANUP_CANCELLED" })); };
    signal?.addEventListener("abort", abort, { once: true }); timer = setTimeout(abort, 8000);
    const work = (async () => {
      try {
        response = await fetchImplementation(request, { signal: controller.signal }); check();
        diagnostics = { operation, httpStatus: response instanceof Response ? response.status : null, decodedBytes: 0 };
        if (!(response instanceof Response) || !response.ok || response.redirected || !response.body ||
            !/^application\/json(?:\s*;|$)/i.test(response.headers.get("content-type") ?? "")) fail("CLEANUP_RESPONSE");
        const length = response.headers.get("content-length"), encoding = (response.headers.get("content-encoding") ?? "identity").trim().toLowerCase();
        if (!["identity", "gzip", "x-gzip", "deflate", "br"].includes(encoding) || length !== null && (!/^\d+$/.test(length) || +length > 16384)) fail("CLEANUP_RESPONSE");
        reader = response.body.getReader(); const parts = []; let size = 0;
        while (true) { check(); if (controller.signal.aborted) fail("CLEANUP_CANCELLED"); const { done, value } = await reader.read(); if (done) break;
          if (!(value instanceof Uint8Array) || !value.length || parts.length >= 64 || (size += value.length) > 16384) fail("CLEANUP_RESPONSE"); parts.push(value); }
        check(); if (controller.signal.aborted || encoding === "identity" && length !== null && size !== +length) fail("CLEANUP_RESPONSE");
        diagnostics.decodedBytes = size; const bytes = new Uint8Array(size); let at = 0; for (const part of parts) { bytes.set(part, at); at += part.length; }
        try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); } finally { bytes.fill(0); }
      } finally {
        try { if (reader) { await reader.cancel(); reader.releaseLock(); } else await response?.body?.cancel(); }
        finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); }
      }
    })();
    pending.add(work); void work.then(() => pending.delete(work), () => pending.delete(work));
    return await Promise.race([work, cancelled]);
  };
  try {
    check(); const before = recordMap(await call("records/lookup", { records: names.map(recordName => ({ recordName })) }), names), operations = [];
    for (const [name, record] of before) {
      if (record.serverErrorCode === "NOT_FOUND") continue;
      if (record.serverErrorCode) fail("CLEANUP_RESPONSE");
      if (name === p.avatarRecordName) {
        assetFieldTypes = Object.fromEntries(["image", "thumbnail"].map(v => [v, record.fields?.[v]?.type === undefined ? "absent" :
          ["ASSET", "ASSETID"].includes(record.fields[v].type) ? record.fields[v].type : "OTHER"]));
        verifyAssetCleanupAvatar(record, expected);
      } else if (!sameCheckpoint(checkpointRecord(record, name).value, expected.checkpoint)) fail("CLEANUP_CHECKPOINT");
      operations.push({ operationType: "delete", record: { recordName: name, recordType: record.recordType, recordChangeTag: record.recordChangeTag } });
    }
    if (operations.length) {
      const ack = recordMap(await call("records/modify", { atomic: false, operations }), operations.map(o => o.record.recordName));
      deleted = [...ack.values()].filter(r => r.deleted === true && !r.serverErrorCode).length;
      const after = recordMap(await call("records/lookup", { records: names.map(recordName => ({ recordName })) }), names);
      succeeded = [...after.values()].every(r => r.serverErrorCode === "NOT_FOUND");
    } else succeeded = true;
  } catch (e) { errorCode = e.cleanupCode ?? (["PUBLIC_SCOPE", "PUBLIC_RESPONSE", "PUBLIC_CONFLICT", "PUBLIC_ERASED"].includes(e.code) ? e.code : "CLEANUP_INCOMPLETE"); }
  let timer; const drained = await Promise.race([Promise.allSettled([...pending]).then(() => true), new Promise(resolve => { timer = setTimeout(() => resolve(false), 8000); })]); clearTimeout(timer);
  return { cleanupSucceeded: succeeded && drained, requests, deleteAcknowledgements: deleted, pendingIO: !drained, errorCode,
    diagnostics, assetFieldTypes, uploads: 0, downloads: 0, creates: 0, providerPhysicalAssetDeletionVerified: false };
}
