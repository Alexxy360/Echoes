import assert from "node:assert/strict";
import { test } from "node:test";
import { createServer } from "node:http";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import { CommunityProtocolTransport } from "../scripts/community-protocol-transport.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { makeCommunityProtocolPlan } from "../scripts/community-protocol-plan.mjs";
import { protocolFixture, barrier } from "./support/community-protocol-fixture.mjs";

const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const signer = (container = "iCloud.mpvEcho.Echo") => new CloudKitDevelopmentSigner({ container, environment: "development", keyID: "synthetic-protocol-key", privateKeyPEM: pem });
const code = expected => error => error?.code === expected;
const lookup = prepared => ({ records: [{ recordName: prepared.plan.records[0].recordName }] });
function transport(fetchImplementation, options = {}) {
  const prepared = options.prepared ?? makeCommunityProtocolPlan();
  return { prepared, client: new CommunityProtocolTransport({ prepared, signer: signer(), isEnabled: () => true, fetchImplementation, ...options }) };
}
function signed(request, body) {
  const path = new URL(request.url).pathname, at = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date");
  const hash = createHash("sha256").update(body).digest("base64");
  return verify("sha256", Buffer.from(`${at}:${hash}:${path}`), pair.publicKey, Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"));
}

test("real signer and bounded HTTP JSON bridge complete the engine against an explicitly synthetic provider", async t => {
  const f = await protocolFixture(t); let requests = 0;
  const { client } = transport(async (request, options) => {
    requests++; const body = await request.text(); assert.equal(signed(request, body), true);
    assert.equal(new URL(request.url).origin, "https://api.apple-cloudkit.com"); assert.equal(request.redirect, "manual");
    const operation = new URL(request.url).pathname.split("/").slice(-2).join("/");
    return Response.json(await f.model.request(operation, JSON.parse(body), options));
  }, { prepared: f.prepared });
  const report = await f.run({ transport: client });
  assert.equal(report.protocolSucceeded, true); assert.equal(report.cleanupSucceeded, true); assert.equal(requests, 9);
});

test("default disabled transport signs or sends nothing", async () => {
  let calls = 0;
  const { prepared, client } = transport(async () => { calls++; throw new Error("should not run"); }, { isEnabled: undefined });
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_DENIED")); assert.equal(calls, 0);
});

test("only exact reviewed IDs, field inventories, conditional tags and uniform operations can be dispatched", async () => {
  let calls = 0;
  const { prepared, client } = transport(async () => { calls++; return Response.json({}); });
  const first = prepared.plan.records[0], second = prepared.plan.records[1];
  const create = item => ({ operationType: "create", record: { recordName: item.recordName, recordType: item.recordType, fields: structuredClone(item.initial) } });
  const valid = { atomic: false, operations: [create(first)] };
  const invalid = [
    ["records/query", { query: {} }], ["assets/upload", {}], ["records/lookup", { records: [{ recordName: "community-registry-checkpoint-v1" }] }],
    ["records/lookup", { ...lookup(prepared), desiredKeys: ["private"] }], ["records/lookup", { records: Array(9).fill(lookup(prepared).records[0]) }],
    ...[
      payload => payload.atomic = true,
      payload => payload.operations[0].operationType = "forceDelete",
      payload => payload.operations[0].record.fields.name.value = "unreviewed",
      payload => payload.operations[0].record.fields.extra = { type: "STRING", value: null },
      payload => payload.operations[0].record.fields.name.type = undefined,
      payload => payload.operations[0].record.recordType = second.recordType,
      payload => payload.operations.push({ operationType: "replace", record: { recordName: second.recordName, recordType: second.recordType, fields: second.replaced, recordChangeTag: "tag" } }),
      payload => { payload.operations[0].operationType = "delete"; delete payload.operations[0].record.fields; },
    ].map(mutate => { const payload = structuredClone(valid); mutate(payload); return ["records/modify", payload]; }),
  ];
  for (const [operation, payload] of invalid) await assert.rejects(client.request(operation, payload), code("PROTOCOL_SCOPE"));
  assert.equal(calls, 0);
});

test("a valid signer configured for a different container cannot send credentials there", async () => {
  let calls = 0;
  const { client, prepared } = transport(async () => { calls++; return Response.json({}); }, { signer: signer("iCloud.example.other") });
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_SCOPE")); assert.equal(calls, 0);
});

test("malformed HTTP/body responses reject without exposing their content", async () => {
  for (const response of [new Response("PRIVATE-HTML", { headers: { "Content-Type": "text/html" } }),
    new Response("PRIVATE-JSON", { headers: { "Content-Type": "application/json" } }),
    new Response(new Uint8Array([0xff]), { headers: { "Content-Type": "application/json" } }),
    new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "65537" } }),
    new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "bad" } }),
    new Response(" ".repeat(65537), { headers: { "Content-Type": "application/json" } }),
    new Response("PRIVATE-ERROR", { status: 503, headers: { "Content-Type": "application/json" } })]) {
    const { client, prepared } = transport(async () => response);
    await assert.rejects(client.request("records/lookup", lookup(prepared)), error => error.code === "PROTOCOL_RESPONSE" && !error.message.includes("PRIVATE"));
    await client.waitForPendingOperations();
  }
});

test("64 KiB JSON boundary is accepted and 1025 empty fragments cannot keep the reader running", async () => {
  const prepared = makeCommunityProtocolPlan(), body = JSON.stringify({ records: [{ recordName: prepared.plan.records[0].recordName, serverErrorCode: "NOT_FOUND" }] });
  const { client } = transport(async () => new Response(body.padEnd(65536), { headers: { "Content-Type": "application/json" } }), { prepared });
  assert.equal((await client.request("records/lookup", lookup(prepared))).records.length, 1);
  let fragments = 0;
  const stream = new ReadableStream({ pull(controller) { fragments++; controller.enqueue(new Uint8Array()); } });
  const next = transport(async () => new Response(stream, { headers: { "Content-Type": "application/json" } }));
  await assert.rejects(next.client.request("records/lookup", lookup(next.prepared)), code("PROTOCOL_RESPONSE"));
  assert.ok(fragments <= 1026); await next.client.waitForPendingOperations();
});

test("an uncooperative fetch retains the only slot and drain until it actually settles", async () => {
  const started = barrier(), release = barrier(), controller = new AbortController();
  const { prepared, client } = transport(async () => { started.release(); await release.promise; return Response.json({ records: [] }); });
  const request = client.request("records/lookup", lookup(prepared), { signal: controller.signal });
  await started.promise; controller.abort(); let drained = false; const drain = client.waitForPendingOperations().then(() => drained = true);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(drained, false);
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_LIMIT"));
  release.release(); await assert.rejects(request, code("PROTOCOL_CANCELLED")); await drain;
});

test("response body cancellation must finish before releasing the slot", async () => {
  const cancelEntered = barrier(), release = barrier(), controller = new AbortController();
  const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"records":[')); }, cancel() { cancelEntered.release(); return release.promise; } });
  const { prepared, client } = transport(async () => new Response(stream, { headers: { "Content-Type": "application/json" } }));
  const request = client.request("records/lookup", lookup(prepared), { signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve)); controller.abort(); await cancelEntered.promise;
  let drained = false; const drain = client.waitForPendingOperations().then(() => drained = true);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(drained, false);
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_LIMIT"));
  release.release(); await assert.rejects(request, code("PROTOCOL_CANCELLED")); await drain;
});

test("failed body cancellation permanently refuses positive drain and subsequent IO", async () => {
  const controller = new AbortController();
  const stream = new ReadableStream({ cancel() { return Promise.reject(new Error("PRIVATE-CANCEL")); } });
  const { prepared, client } = transport(async () => new Response(stream, { headers: { "Content-Type": "application/json" } }));
  const request = client.request("records/lookup", lookup(prepared), { signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve)); controller.abort();
  await assert.rejects(request, code("PROTOCOL_CANCELLED"));
  await assert.rejects(client.waitForPendingOperations(), code("PROTOCOL_DRAIN"));
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_DRAIN"));
});

test("revocation while reading refuses the response and retains no successful result", async () => {
  let enabled = true;
  const { prepared, client } = transport(async () => { enabled = false; return Response.json({ records: [] }); }, { isEnabled: () => enabled });
  await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_DENIED")); await client.waitForPendingOperations();
});

test("native fetch never forwards signed headers through a redirect to another loopback server", async () => {
  let destinationCalls = 0;
  const destination = createServer((_, response) => { destinationCalls++; response.end("PRIVATE"); });
  await new Promise(resolve => destination.listen(0, "127.0.0.1", resolve));
  const target = `http://127.0.0.1:${destination.address().port}/unexpected`;
  const origin = createServer((request, response) => { request.resume(); response.writeHead(302, { Location: target }); response.end(); });
  await new Promise(resolve => origin.listen(0, "127.0.0.1", resolve));
  try {
    const { prepared, client } = transport(async (request, options) => fetch(new Request(`http://127.0.0.1:${origin.address().port}${new URL(request.url).pathname}`, {
      method: request.method, headers: request.headers, body: await request.text(), redirect: request.redirect }), options));
    await assert.rejects(client.request("records/lookup", lookup(prepared)), code("PROTOCOL_RESPONSE"));
    assert.equal(destinationCalls, 0); await client.waitForPendingOperations();
  } finally {
    origin.closeAllConnections(); destination.closeAllConnections();
    await Promise.all([new Promise(resolve => origin.close(resolve)), new Promise(resolve => destination.close(resolve))]);
  }
});
