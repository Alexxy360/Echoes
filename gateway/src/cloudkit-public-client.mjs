import { CloudKitDevelopmentSigner } from "./cloudkit-request.mjs";
import { PublicRecordError, plain, publicRecordName, publicRecordTypes, validTag } from "./public-record-schema.mjs";
import { checkpointRecordName, checkpointRecordType, checkpointFields } from "./public-registry-checkpoint.mjs";

const responseLimit = 512 * 1024;
const recordCodes = new Set(["NOT_FOUND", "EXISTS", "CONFLICT", "ACCESS_DENIED", "AUTHENTICATION_FAILED",
  "AUTHENTICATION_REQUIRED", "THROTTLED", "QUOTA_EXCEEDED", "BAD_REQUEST", "INTERNAL_ERROR", "TRY_AGAIN_LATER"]);
const types = new Set([...Object.values(publicRecordTypes), checkpointRecordType]);
/** Server-only, fixed Development/public target. It is never an HTTP proxy or a client signer. */
export class CloudKitPublicClient {
  #signer; #fetch; #enabled; #clock; #timeout;
  constructor({ container, environment, keyID, privateKeyPEM, fetchImplementation = fetch,
    isEnabled, clock = Date.now, timeoutMilliseconds = 8000 } = {}) {
    if (container !== "iCloud.mpvEcho.Echo" || environment !== "development" || typeof fetchImplementation !== "function" ||
        typeof isEnabled !== "function" || typeof clock !== "function" || !Number.isInteger(timeoutMilliseconds) ||
        timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) throw new PublicRecordError();
    try { this.#signer = new CloudKitDevelopmentSigner({ container, environment, keyID, privateKeyPEM }); }
    catch { throw new PublicRecordError(); }
    this.#fetch = fetchImplementation; this.#enabled = isEnabled; this.#clock = clock; this.#timeout = timeoutMilliseconds;
  }
  #check(signal) { if (signal?.aborted || !this.#enabled()) throw new PublicRecordError(); }
  async #json(response, signal) {
    if (!(response instanceof Response) || !response.ok) {
      await response?.body?.cancel().catch(() => {});
      throw new PublicRecordError(response?.status === 429 ? "PUBLIC_THROTTLED" : "PUBLIC_UNAVAILABLE");
    }
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") || !response.body) {
      void response.body?.cancel().catch(() => {}); throw new PublicRecordError("PUBLIC_RESPONSE");
    }
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > responseLimit)) {
      await response.body.cancel().catch(() => {}); throw new PublicRecordError("PUBLIC_RESPONSE");
    }
    const reader = response.body.getReader(), parts = []; let size = 0;
    const abort = () => { void reader.cancel().catch(() => {}); };
    signal.addEventListener("abort", abort, { once: true });
    try {
      while (true) {
        this.#check(signal);
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > responseLimit) throw new PublicRecordError("PUBLIC_RESPONSE");
        parts.push(value);
      }
      this.#check(signal);
      const bytes = new Uint8Array(size); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } finally {
      signal.removeEventListener("abort", abort); await reader.cancel().catch(() => {}); reader.releaseLock();
    }
  }
  async #call(operation, payload, names, parent) {
    this.#check(parent);
    const controller = new AbortController(); let timer, rejectCancellation;
    const cancelled = new Promise((_, reject) => { rejectCancellation = reject; });
    const abort = () => { controller.abort(); rejectCancellation(new PublicRecordError()); };
    parent?.addEventListener("abort", abort, { once: true });
    try {
      const request = this.#signer.request(operation, payload, new Date(this.#clock()));
      const operationPromise = (async () => {
        const response = await this.#fetch(request, { signal: controller.signal });
        const body = await this.#json(response, controller.signal);
        if (!plain(body) || body.serverErrorCode || !Array.isArray(body.records) || body.records.length !== names.length) throw new PublicRecordError("PUBLIC_RESPONSE");
        const records = new Map();
        for (const record of body.records) {
          if (!plain(record) || !names.includes(record.recordName) || records.has(record.recordName)) throw new PublicRecordError("PUBLIC_RESPONSE");
          if (record.serverErrorCode !== undefined) {
            if (!recordCodes.has(record.serverErrorCode)) throw new PublicRecordError("PUBLIC_RESPONSE");
            records.set(record.recordName, Object.freeze({ recordName: record.recordName, serverErrorCode: record.serverErrorCode }));
          } else {
            if (!types.has(record.recordType) || !validTag(record.recordChangeTag) || !plain(record.fields) || record.deleted) throw new PublicRecordError("PUBLIC_RESPONSE");
            records.set(record.recordName, record);
          }
        }
        this.#check(parent); return records;
      })();
      return await Promise.race([operationPromise, cancelled, new Promise((_, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(new PublicRecordError()); }, this.#timeout);
      })]);
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
    finally { clearTimeout(timer); controller.abort(); parent?.removeEventListener("abort", abort); }
  }
  async lookup(names, { metadataOnly = false, signal } = {}) {
    if (!Array.isArray(names) || names.length < 1 || names.length > 25 || new Set(names).size !== names.length ||
        names.some(name => typeof name !== "string" || !publicRecordName.test(name))) throw new PublicRecordError("PUBLIC_INPUT");
    return this.#call("records/lookup", { records: names.map(recordName => ({ recordName })),
      ...(metadataOnly ? { desiredKeys: ["schemaVersion", "ownerKey", "erased", "deletionKey"] } : {}) }, names, signal);
  }
  async lookupCheckpoint({ signal } = {}) {
    return (await this.#call("records/lookup", { records: [{ recordName: checkpointRecordName }] }, [checkpointRecordName], signal)).get(checkpointRecordName);
  }
  async replaceCheckpoint(value, expectedTag, { signal } = {}) {
    if (!validTag(expectedTag) || value?.parentAnchorID === "") throw new PublicRecordError("PUBLIC_INPUT");
    return (await this.#call("records/modify", { atomic: false, operations: [{ operationType: "replace", record: {
      recordName: checkpointRecordName, recordType: checkpointRecordType, recordChangeTag: expectedTag,
      fields: checkpointFields(value) } }] }, [checkpointRecordName], signal)).get(checkpointRecordName);
  }
  /** Trusted one-time operator operation after inventory/approval. Never called by runtime recovery. */
  async createCheckpointForBootstrap(value, { signal } = {}) {
    if (value?.parentAnchorID !== "" || value?.registeredCount !== 0) throw new PublicRecordError("PUBLIC_INPUT");
    return (await this.#call("records/modify", { atomic: false, operations: [{ operationType: "create", record: {
      recordName: checkpointRecordName, recordType: checkpointRecordType, fields: checkpointFields(value) } }] },
    [checkpointRecordName], signal)).get(checkpointRecordName);
  }
  async modify(operations, { signal } = {}) {
    if (!Array.isArray(operations) || operations.length < 1 || operations.length > 25 ||
        new Set(operations.map(op => op?.record?.recordName)).size !== operations.length || operations.some(op =>
          !plain(op) || !["create", "replace"].includes(op.operationType) || !plain(op.record) || !publicRecordName.test(op.record.recordName ?? "") ||
          !Object.values(publicRecordTypes).includes(op.record.recordType) || !plain(op.record.fields) || (op.operationType === "replace" ? !validTag(op.record.recordChangeTag) : op.record.recordChangeTag !== undefined))) throw new PublicRecordError("PUBLIC_INPUT");
    return this.#call("records/modify", { atomic: false, operations }, operations.map(op => op.record.recordName), signal);
  }
}
