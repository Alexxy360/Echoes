import { randomUUID } from "node:crypto";

const recordType = "EchoesGatewayProbeV1";
class ProbeError extends Error {
  constructor(code = "INVALID_RESPONSE") {
    super("CloudKit Development probe failed.");
    this.code = code;
  }
}
const knownCodes = new Set(["NOT_FOUND", "EXISTS", "ACCESS_DENIED", "AUTHENTICATION_FAILED",
  "AUTHENTICATION_REQUIRED", "THROTTLED", "QUOTA_EXCEEDED", "CONFLICT", "BAD_REQUEST"]);

async function jsonLimited(response) {
  if (!response.ok) {
    await response.body?.cancel();
    throw new ProbeError(`HTTP_${response.status}`);
  }
  if (!response.body) throw new ProbeError();
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 64 * 1024) throw new ProbeError("RESPONSE_TOO_LARGE");
      chunks.push(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
  catch { throw new ProbeError(); }
}

function safeCode(error) {
  return error instanceof ProbeError ? error.code : "TRANSPORT_FAILED";
}

const uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
const uuidPattern = new RegExp("^" + uuid + "$");
const namePattern = new RegExp("^gateway-probe-" + uuid + "$");

/** Trusted server generates this before reserving a durable run. Never derive it from HTTP input. */
export function makeDevelopmentProbeContext() {
  return {
    runIdentifier: randomUUID(), startedAt: new Date().toISOString(),
    environment: "Development", recordType,
    syntheticRecordName: "gateway-probe-" + randomUUID(), nonce: randomUUID(),
  };
}

/** Trusted diagnostic only. A persisted context lets the operator reconcile a crash without a second write. */
export async function probeCloudKitDevelopment(signer, fetchImplementation = fetch, context = makeDevelopmentProbeContext()) {
  if (context?.environment !== "Development" || context.recordType !== recordType ||
      !uuidPattern.test(context.runIdentifier ?? "") || !namePattern.test(context.syntheticRecordName ?? "") ||
      !uuidPattern.test(context.nonce ?? "") || typeof context.startedAt !== "string" ||
      !Number.isFinite(Date.parse(context.startedAt))) {
    throw new TypeError("Invalid server-generated Development context.");
  }
  const { nonce } = context;
  const report = {
    runIdentifier: context.runIdentifier, startedAt: context.startedAt,
    environment: "Development", recordType, syntheticRecordName: context.syntheticRecordName,
    writeSucceeded: false, readBackSucceeded: false, cleanupSucceeded: false,
  };
  const name = report.syntheticRecordName;
  async function call(operation, payload) {
    const response = await fetchImplementation(signer.request(operation, payload), {
      signal: AbortSignal.timeout(10_000),
    });
    const body = await jsonLimited(response);
    if (body?.serverErrorCode) {
      throw new ProbeError(knownCodes.has(body.serverErrorCode) ? body.serverErrorCode : "CLOUDKIT_FAILED");
    }
    if (!Array.isArray(body?.records) || body.records.length !== 1) throw new ProbeError();
    const record = body.records[0];
    if (record?.recordName !== name) throw new ProbeError();
    if (record.serverErrorCode) {
      throw new ProbeError(knownCodes.has(record.serverErrorCode) ? record.serverErrorCode : "CLOUDKIT_FAILED");
    }
    return record;
  }
  let collision = false;
  try {
    const saved = await call("records/modify", { atomic: false, operations: [{
      operationType: "create", record: {
        recordName: name, recordType,
        fields: { nonce: { value: nonce, type: "STRING" }, schemaVersion: { value: 1, type: "INT64" } },
      },
    }] });
    if (saved.recordType !== recordType || saved.fields?.nonce?.value !== nonce) throw new ProbeError();
    report.writeSucceeded = true;
    const read = await call("records/lookup", { records: [{ recordName: name }], desiredKeys: ["nonce", "schemaVersion"] });
    if (read.recordType !== recordType || read.fields?.nonce?.value !== nonce || read.fields?.schemaVersion?.value !== 1) {
      throw new ProbeError();
    }
    report.readBackSucceeded = true;
  } catch (error) {
    collision = !report.writeSucceeded && error instanceof ProbeError && error.code === "EXISTS";
    report.errorCode = safeCode(error);
  }
  if (!collision) {
    // Only this disposable UUID may use forceDelete (no change tag after an unknown create response).
    // Never delete a record explicitly reported as pre-existing; never reuse this path for user data.
    try {
      const deleted = await call("records/modify", { atomic: false, operations: [{
        operationType: "forceDelete", record: { recordName: name },
      }] });
      if (deleted.deleted !== true) throw new ProbeError();
      report.cleanupSucceeded = true;
    } catch (error) {
      if (error instanceof ProbeError && error.code === "NOT_FOUND") report.cleanupSucceeded = true;
      else report.cleanupErrorCode = safeCode(error);
    }
  } else { report.cleanupSkippedExistingRecord = true; }
  return report;
}
