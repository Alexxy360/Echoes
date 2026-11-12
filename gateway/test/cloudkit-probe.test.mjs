import { test } from "node:test";
import assert from "node:assert/strict";
import { probeCloudKitDevelopment } from "../src/cloudkit-probe.mjs";

const signer = { request: (operation, payload) => new Request("https://test.invalid/" + operation, {
  method: "POST", body: JSON.stringify(payload),
}) };
function server(options = {}) {
  const requests = [];
  let stored;
  return { requests, fetch: async (request, init) => {
    assert.ok(init.signal instanceof AbortSignal);
    const body = await request.json();
    requests.push(body);
    const op = body.operations?.[0];
    const name = op?.record.recordName ?? body.records?.[0].recordName;
    if (op?.operationType === "create") {
      if (options.collision) return Response.json({ records: [{ recordName: name, serverErrorCode: "EXISTS" }] });
      stored = op.record;
      if (options.unknownWrite) throw new Error("UNSAFE-TRANSPORT-DETAIL");
      return Response.json({ records: [stored] });
    }
    if (op?.operationType === "forceDelete") {
      if (options.cleanupFailure) return Response.json({ records: [{ recordName: name, serverErrorCode: "ACCESS_DENIED", reason: "PRIVATE-REASON" }] });
      if (options.absent) return Response.json({ records: [{ recordName: name, serverErrorCode: "NOT_FOUND" }] });
      return Response.json({ records: [{ recordName: name, deleted: true }] });
    }
    if (options.readFailure) return Response.json({ records: [{ recordName: name, serverErrorCode: "THROTTLED", reason: "PRIVATE-REASON" }] });
    if (options.oversize) return new Response("x".repeat(65537));
    if (options.wrongRecord) return Response.json({ records: [{ ...stored, recordName: "somebody-else" }] });
    return Response.json({ records: [stored] });
  } };
}

test("synthetic probe creates, verifies and deletes only its own server-chosen UUID", async () => {
  const mock = server();
  const report = await probeCloudKitDevelopment(signer, mock.fetch);
  assert.equal(report.writeSucceeded, true);
  assert.equal(report.readBackSucceeded, true);
  assert.equal(report.cleanupSucceeded, true);
  assert.match(report.syntheticRecordName, /^gateway-probe-[A-Fa-f0-9-]{36}$/);
  assert.equal(mock.requests.length, 3);
  assert.equal(mock.requests[0].operations[0].operationType, "create");
  assert.equal(mock.requests[2].operations[0].operationType, "forceDelete");
  for (const body of mock.requests) {
    assert.equal(body.operations?.[0].record.recordName ?? body.records[0].recordName, report.syntheticRecordName);
  }
});

test("HTTP-200 per-record errors fail the probe and cleanup still runs without exposing server reasons", async () => {
  const mock = server({ readFailure: true });
  const report = await probeCloudKitDevelopment(signer, mock.fetch);
  assert.equal(report.readBackSucceeded, false);
  assert.equal(report.errorCode, "THROTTLED");
  assert.equal(report.cleanupSucceeded, true);
  assert.equal(JSON.stringify(report).includes("PRIVATE-REASON"), false);
});

test("unknown create outcome still attempts cleanup and does not retry the write", async () => {
  const mock = server({ unknownWrite: true });
  const report = await probeCloudKitDevelopment(signer, mock.fetch);
  assert.equal(report.errorCode, "TRANSPORT_FAILED");
  assert.equal(report.cleanupSucceeded, true);
  assert.equal(mock.requests.length, 2);
  assert.equal(JSON.stringify(report).includes("UNSAFE-TRANSPORT-DETAIL"), false);
});

test("a pre-existing record is never deleted", async () => {
  const mock = server({ collision: true });
  const report = await probeCloudKitDevelopment(signer, mock.fetch);
  assert.equal(report.errorCode, "EXISTS");
  assert.equal(report.cleanupSucceeded, false);
  assert.equal(report.cleanupSkippedExistingRecord, true);
  assert.equal(mock.requests.length, 1);
});

test("cleanup error stays visible; missing record is confirmed absent", async () => {
  const failed = await probeCloudKitDevelopment(signer, server({ cleanupFailure: true }).fetch);
  assert.equal(failed.cleanupSucceeded, false);
  assert.equal(failed.cleanupErrorCode, "ACCESS_DENIED");
  assert.equal((await probeCloudKitDevelopment(signer, server({ absent: true }).fetch)).cleanupSucceeded, true);
});

test("mismatched or oversized response is not accepted, and only the generated UUID is cleaned up", async () => {
  for (const options of [{ wrongRecord: true }, { oversize: true }]) {
    const mock = server(options);
    const report = await probeCloudKitDevelopment(signer, mock.fetch);
    assert.equal(report.readBackSucceeded, false);
    assert.equal(report.cleanupSucceeded, true);
    assert.equal(mock.requests[2].operations[0].record.recordName, report.syntheticRecordName);
  }
});
