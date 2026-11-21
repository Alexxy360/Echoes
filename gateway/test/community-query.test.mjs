import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { mkdtemp, rm, stat, writeFile, readFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { makeCommunityQueryPlan, verifyCommunityQueryPlan, communityQueryPayload, CommunityQueryPages } from "../scripts/community-query-plan.mjs";
import { CommunityQueryTransport } from "../scripts/community-query-transport.mjs";
import { CommunityQueryJournal } from "../scripts/community-query-journal.mjs";
import { communityQueryCommand, verifyCommunityQueryPermit, retiredDiagnosticKey } from "../scripts/community-query-cli.mjs";
import { makeCommunityProtocolPlan } from "../scripts/community-protocol-plan.mjs";
import { CommunityProtocolTransport } from "../scripts/community-protocol-transport.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { CloudKitPublicClient } from "../src/cloudkit-public-client.mjs";
import { publishProtocolPrivateJSON } from "../scripts/community-protocol-files.mjs";
import { queryFixture, CommunityQueryModel } from "./support/community-query-fixture.mjs";
import { barrier } from "./support/community-protocol-fixture.mjs";

const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" }), pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const signer = container => new CloudKitDevelopmentSigner({ container: container ?? "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-query-key", privateKeyPEM: pem });
const code = value => error => error.code === value;
const row = (plan, name) => { const item = plan.records.find(item => item.recordName === name); return {
  recordName: name, recordType: item.recordType, fields: { ownerKey: item.initial.ownerKey } }; };
const page = (plan, kind, offset = 0) => ({ records: plan.expected[kind].slice(offset, offset + 2).map(name => row(plan, name)),
  ...(offset === 0 ? { continuationMarker: "synthetic-page-2" } : {}) });

test("deterministic twelve-record production-shaped inventory is hash-bound to the installed schema", () => {
  const prepared = makeCommunityQueryPlan();
  assert.deepEqual(verifyCommunityQueryPlan(JSON.parse(JSON.stringify(prepared.plan)), prepared.sha256), prepared);
  assert.equal(new Set(prepared.plan.records.map(row => row.recordName)).size, 12);
  assert.equal(new Set(prepared.plan.records.map(row => row.initial.accountID.value)).size, 12);
  assert.equal(Object.isFrozen(prepared.plan.records[0].initial), true);
  for (const mutate of [p => p.records[0].initial.name.value = "changed", p => p.query.radius++,
    p => p.scope.environment = "production", p => p.constraints.maximumBatchCalls++, p => p.seed.extra = true]) {
    const changed = structuredClone(prepared.plan); mutate(changed);
    assert.throws(() => verifyCommunityQueryPlan(changed, prepared.sha256));
  }
  assert.throws(() => verifyCommunityQueryPlan(makeCommunityProtocolPlan().plan, prepared.sha256));
});

test("query predicates and sorts equal the actual production client, with only owned IN references and page-size override", async () => {
  const { plan } = makeCommunityQueryPlan();
  for (const kind of ["presence", "message"]) {
    let captured;
    const client = new CloudKitPublicClient({ container: plan.scope.container, environment: "development", keyID: "synthetic-query-key",
      privateKeyPEM: pem, isEnabled: () => true, fetchImplementation: async request => { captured = await request.json(); return Response.json({ records: [] }); } });
    await client.regionalCandidates({ kind, coordinate: plan.query.center, cutoff: plan.query.cutoff });
    const bounded = communityQueryPayload(plan, kind);
    const own = bounded.query.filterBy.pop();
    assert.equal(own.systemFieldName, "recordName"); assert.equal(own.comparator, "IN"); assert.equal(own.fieldValue.type, "REFERENCE_LIST");
    assert.deepEqual(own.fieldValue.value.map(ref => ref.recordName), plan.records.filter(row => row.kind === kind).map(row => row.recordName));
    bounded.resultsLimit = captured.resultsLimit; assert.deepEqual(bounded, captured);
  }
});

test("page accumulator proves ties/order and continuation, rejecting foreign/duplicate/missing/extra fields and cursor cycles", () => {
  const prepared = makeCommunityQueryPlan(), { plan } = prepared;
  for (const kind of ["presence", "message"]) {
    const pages = new CommunityQueryPages(prepared, kind);
    assert.equal(pages.accept(page(plan, kind)).complete, false);
    assert.deepEqual(pages.accept(page(plan, kind, 2)).recordNames, plan.expected[kind]);
    assert.throws(() => pages.accept(page(plan, kind, 2)));
    for (const mutate of [p => p.records.reverse(), p => p.records[0].recordName = "foreign", p => p.records.push(p.records[0]),
      p => p.records[0].fields.text = { value: "unexpected" }, p => p.records[0].fields.ownerKey.value = "other",
      p => delete p.continuationMarker, p => p.continuationMarker = "", p => p.extra = true]) {
      const fresh = new CommunityQueryPages(prepared, kind), body = structuredClone(page(plan, kind)); mutate(body);
      assert.throws(() => fresh.accept(body));
    }
    const cycle = new CommunityQueryPages(prepared, kind); cycle.accept({ records: [], continuationMarker: "a" });
    assert.throws(() => cycle.accept({ records: [], continuationMarker: "a" }));
    const empty = new CommunityQueryPages(prepared, kind);
    for (let i = 0; i < 5; i++) empty.accept({ records: [], continuationMarker: String(i) });
    assert.throws(() => empty.accept({ records: [], continuationMarker: "last" }));
  }
});

test("closed transport rejects broader queries, altered writes, assets and old-scope use before any fetch", async () => {
  const prepared = makeCommunityQueryPlan(); let calls = 0;
  const client = new CommunityQueryTransport({ prepared, signer: signer(), isEnabled: () => true,
    fetchImplementation: async () => { calls++; return Response.json({}); } });
  for (const mutate of [p => p.query.filterBy.pop(), p => p.query.filterBy.at(-1).fieldValue.value.pop(),
    p => p.query.filterBy.at(-1).fieldValue.value[0].recordName = "foreign", p => p.query.filterBy[0].distance++,
    p => p.query.sortBy.reverse(), p => p.resultsLimit = 25, p => p.desiredKeys.push("text"),
    p => p.continuationMarker = null, p => p.zoneID = { zoneName: "other" }]) {
    const payload = structuredClone(communityQueryPayload(prepared.plan, "presence")); mutate(payload);
    await assert.rejects(client.request("records/query", payload), code("PROTOCOL_SCOPE"));
  }
  for (const [operation, payload] of [["assets/upload", {}], ["records/lookup", { records: [{ recordName: "foreign" }] }],
    ["records/modify", { atomic: false, operations: [{ operationType: "forceDelete", record: {} }] }]]) {
    await assert.rejects(client.request(operation, payload), code("PROTOCOL_SCOPE"));
  }
  assert.throws(() => new CommunityProtocolTransport({ prepared, signer: signer() }));
  const disabled = new CommunityQueryTransport({ prepared, signer: signer(), fetchImplementation: async () => calls++ });
  await assert.rejects(disabled.request("records/query", communityQueryPayload(prepared.plan, "presence")), code("PROTOCOL_DENIED"));
  const foreign = new CommunityQueryTransport({ prepared, signer: signer("iCloud.other"), isEnabled: () => true, fetchImplementation: async () => calls++ });
  await assert.rejects(foreign.request("records/query", communityQueryPayload(prepared.plan, "presence")), code("PROTOCOL_SCOPE"));
  assert.equal(calls, 0);
});

test("real signature and bounded JSON bridge execute both paginated synthetic queries and fresh-tag cleanup", async t => {
  const f = await queryFixture(t); let requests = 0;
  const transport = new CommunityQueryTransport({ prepared: f.prepared, signer: signer(), isEnabled: () => true, clock: f.clock,
    fetchImplementation: async (request, options) => {
      requests++; const text = await request.text(), path = new URL(request.url).pathname;
      const at = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date"), hash = createHash("sha256").update(text).digest("base64");
      assert.equal(verify("sha256", Buffer.from(`${at}:${hash}:${path}`), pair.publicKey,
        Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64")), true);
      assert.equal(request.redirect, "manual");
      return Response.json(await f.model.request(path.split("/").slice(-2).join("/"), JSON.parse(text), options));
    } });
  const report = await f.run({ transport });
  assert.equal(report.protocolSucceeded, true); assert.equal(report.cleanupSucceeded, true); assert.equal(report.pendingIO, false);
  assert.equal(requests, 10); assert.equal(report.windowCalls, 10); assert.equal(f.model.records.size, 0);
  for (const kind of ["presence", "message"]) assert.deepEqual(report.queryEvidence[kind], { pages: 2, recordNames: f.prepared.plan.expected[kind], complete: true });
  const queries = f.model.calls.filter(call => call.operation === "records/query");
  assert.equal(queries.length, 4); assert.equal(queries.every(call => call.payload.query.filterBy.at(-1).fieldValue.value.length === 6), true);
});

test("preflight collision writes nothing; create-time explicit EXISTS is never deleted", async t => {
  const a = await queryFixture(t), item = a.prepared.plan.records[0];
  a.model.records.set(item.recordName, { recordName: item.recordName, recordType: item.recordType, recordChangeTag: "foreign", fields: item.initial });
  const report = await a.run(); assert.equal(report.errorCode, "PROTOCOL_EXISTING"); assert.equal(a.model.calls.length, 1); assert.equal(a.model.records.size, 1);
  const b = await queryFixture(t), collided = b.prepared.plan.records[0];
  b.model.before = call => { if (call.operation === "records/modify" && call.payload.operations[0].operationType === "create")
    b.model.records.set(collided.recordName, { recordName: collided.recordName, recordChangeTag: "foreign", recordType: collided.recordType, fields: collided.initial }); };
  const partial = await b.run(); assert.equal(partial.protocolSucceeded, false);
  assert.deepEqual(partial.skippedExistingRecordNames, [collided.recordName]); assert.equal(b.model.records.size, 1);
  assert.equal(b.model.calls.some(call => call.operation === "records/modify" && call.payload.operations.some(op => op.operationType === "delete" && op.record.recordName === collided.recordName)), false);
});

test("provider query error or malformed continuation is a failure with own cleanup, without retry", async t => {
  for (const response of [{ serverErrorCode: "BAD_REQUEST", reason: "SYNTHETIC-PRIVATE" }, { records: [], continuationMarker: "loop" }]) {
    const f = await queryFixture(t); f.model.before = call => call.operation === "records/query" ? response : undefined;
    const result = await f.run(); assert.equal(result.protocolSucceeded, false); assert.equal(result.errorCode, "PROTOCOL_RESPONSE");
    assert.equal(result.cleanupSucceeded, true); assert.equal(f.model.records.size, 0);
    assert.ok(f.model.calls.filter(call => call.operation === "records/query").length <= 2);
    assert.equal(JSON.stringify(result).includes("SYNTHETIC-PRIVATE"), false);
  }
});

test("interrupted query can resume only exact cleanup under a fresh permit window after reopening journal", async t => {
  const f = await queryFixture(t); let revoked = false;
  f.model.after = (call, body) => { if (call.operation === "records/query") revoked = true; return body; };
  const result = await f.run({ isAuthorized: () => !revoked });
  assert.equal(result.cleanupSucceeded, false); assert.equal(f.model.records.size, 12);
  const previousWindow = f.journal.snapshot().state.window; await f.reopen();
  await assert.rejects(f.run(), code("PROTOCOL_RECOVERY"));
  await assert.rejects(f.run({ window: { ...previousWindow, mode: "cleanup" } }), code("PROTOCOL_RECOVERY"));
  f.model.after = undefined;
  const start = f.model.calls.length, cleanup = await f.run({ window: f.window("cleanup") });
  assert.equal(cleanup.cleanupSucceeded, true); assert.equal(cleanup.protocolSucceeded, false); assert.equal(cleanup.windowCalls, 3);
  assert.equal(f.model.calls.slice(start).some(call => call.operation === "records/query" || call.payload.operations?.some(op => op.operationType === "create")), false);
});

test("uncertain create remains pending when absent; a changed own ID is not deleted", async t => {
  const a = await queryFixture(t);
  a.model.before = call => { if (call.operation === "records/modify" && call.payload.operations[0].operationType === "create") throw new Error("Unknown delivery"); };
  const uncertain = await a.run(); assert.equal(uncertain.cleanupSucceeded, false); assert.equal(uncertain.pendingRecordNames.length, 12);
  const b = await queryFixture(t), changed = b.prepared.plan.records[0];
  b.model.before = call => { if (call.operation === "records/query") {
    b.model.records.get(changed.recordName).fields = { ownerKey: { value: "other" } }; return { records: [] };
  } };
  const guarded = await b.run(); assert.equal(guarded.cleanupSucceeded, false); assert.deepEqual(guarded.pendingRecordNames, [changed.recordName]);
  assert.equal(b.model.records.size, 1);
});

test("wall/monotonic regressions, expired permission and default deny stop calls", async t => {
  for (const mutate of [f => f.moveWall(-1), f => f.moveMono(-1), f => f.advance(60000)]) {
    const f = await queryFixture(t); f.model.after = (call, body) => { mutate(f); return body; };
    const result = await f.run(); assert.equal(result.protocolSucceeded, false); assert.equal(f.model.calls.length, 1);
  }
  const f = await queryFixture(t); await assert.rejects(f.run({ isAuthorized: () => false }), code("PROTOCOL_DENIED")); assert.equal(f.model.calls.length, 0);
});

test("aborted uncooperative transport holds its only slot until actual IO completes", async () => {
  const prepared = makeCommunityQueryPlan(), entered = barrier(), release = barrier(), controller = new AbortController();
  const client = new CommunityQueryTransport({ prepared, signer: signer(), isEnabled: () => true, fetchImplementation: async () => {
    entered.release(); await release.promise; return Response.json({ records: [] });
  } });
  const pending = client.request("records/query", communityQueryPayload(prepared.plan, "message"), { signal: controller.signal });
  await entered.promise; controller.abort(); let drained = false;
  const drain = client.waitForPendingOperations().then(() => drained = true);
  await new Promise(resolve => setImmediate(resolve)); assert.equal(drained, false);
  await assert.rejects(client.request("records/query", communityQueryPayload(prepared.plan, "message")), code("PROTOCOL_LIMIT"));
  release.release(); await assert.rejects(pending, code("PROTOCOL_CANCELLED")); await drain;
});

test("new CLI prepare/inspect use private journal with no network; old permit cannot activate it", async t => {
  const root = await mkdtemp(join(tmpdir(), "echoes-query-cli-test-")); t.after(() => rm(root, { recursive: true, force: true }));
  let calls = 0;
  const options = { fetchImplementation: async () => { calls++; throw new Error("No network allowed"); } };
  const prepared = await communityQueryCommand(["prepare", root], options);
  assert.equal(prepared.networkRequests, 0); assert.equal(prepared.records.length, 12);
  for (const path of [prepared.directory, join(prepared.directory, "inventory.json"), join(prepared.directory, "journal.sqlite")]) {
    assert.equal((await stat(path)).mode & 0o077, 0);
  }
  const inspected = await communityQueryCommand(["inspect", prepared.directory, prepared.planSHA256], options);
  assert.equal(inspected.state, null); assert.equal(inspected.windowActivated, false);
  await assert.rejects(communityQueryCommand(["run", prepared.directory, prepared.planSHA256, "/nonexistent-permit", "/nonexistent-key"], options), code("CLI_DISABLED"));
  const plan = makeCommunityQueryPlan(), now = plan.plan.seed.startedAt;
  const permit = { schemaVersion: 1, purpose: "echoes-community-query-development-v1", scope: plan.plan.scope,
    planSHA256: plan.sha256, window: { id: randomUUID(), issuedAt: now, expiresAt: now + 60000, mode: "full" },
    keyID: "synthetic-key", publicKeySHA256: "a".repeat(64), retiredKeyID: retiredDiagnosticKey.keyID,
    retiredPublicKeySHA256: retiredDiagnosticKey.publicKeySHA256, identityModel: "individual-owner-administrator-v1" };
  assert.deepEqual(verifyCommunityQueryPermit(permit, plan, "full", now), permit);
  for (const mutate of [p => p.purpose = "echoes-community-protocol-development-v1", p => p.planSHA256 = "b".repeat(64),
    p => p.scope = { ...p.scope, environment: "production" }, p => p.window = { ...p.window, expiresAt: now + 1800001 },
    p => p.keyID = retiredDiagnosticKey.keyID]) {
    const changed = structuredClone(permit); mutate(changed); assert.throws(() => verifyCommunityQueryPermit(changed, plan, "full", now), code("CLI_PERMIT"));
  }
  const journal = await CommunityQueryJournal.open(prepared.directory, prepared.planSHA256);
  await assert.rejects(CommunityQueryJournal.open(prepared.directory, prepared.planSHA256), code("JOURNAL_BUSY")); journal.close();
  await publishProtocolPrivateJSON(join(root, "not-a-permit.json"), permit); assert.equal(calls, 0);
});

test("CLI binds the real private key, persists one attempt/receipt, and permits only cleanup after revocation", async t => {
  const root = await mkdtemp(join(tmpdir(), "echoes-query-cli-run-")); t.after(() => rm(root, { recursive: true, force: true }));
  for (const revoke of [false, true]) {
    const prepared = await communityQueryCommand(["prepare", root]), model = new CommunityQueryModel();
    const keyPath = join(prepared.directory, "synthetic-unregistered-key.pem"), permitPath = join(prepared.directory, "permit.json");
    const now = Date.now(), permit = { schemaVersion: 1, purpose: "echoes-community-query-development-v1", scope: prepared.scope,
      planSHA256: prepared.planSHA256, window: { id: randomUUID(), issuedAt: now, expiresAt: now + 60000, mode: "full" },
      keyID: "synthetic-query-key", publicKeySHA256: createHash("sha256").update(pair.publicKey.export({ type: "spki", format: "der" })).digest("hex"),
      retiredKeyID: retiredDiagnosticKey.keyID, retiredPublicKeySHA256: retiredDiagnosticKey.publicKeySHA256,
      identityModel: "individual-owner-administrator-v1" };
    await writeFile(keyPath, pem, { mode: 0o600 }); await publishProtocolPrivateJSON(permitPath, permit);
    let signedCalls = 0;
    const options = { env: { ECHOES_ALLOW_COMMUNITY_QUERY_DEV: "1" }, clock: () => now, fetchImplementation: async (request, options) => {
      signedCalls++; const payload = await request.json(), operation = new URL(request.url).pathname.split("/").slice(-2).join("/");
      const body = await model.request(operation, payload, options);
      if (revoke && payload.operations?.[0].operationType === "create") await unlink(permitPath);
      return Response.json(body);
    } };
    const args = command => [command, prepared.directory, prepared.planSHA256, permitPath, keyPath];
    const result = await communityQueryCommand(args("run"), options);
    const saved = JSON.parse(await readFile(join(prepared.directory, "report-" + permit.window.id + ".json"), "utf8"));
    assert.deepEqual(saved, JSON.parse(JSON.stringify(result)));
    assert.equal(result.exitCode, revoke ? 3 : 0); assert.equal(signedCalls, revoke ? 2 : 10);
    if (revoke) {
      permit.window = { ...permit.window, id: randomUUID(), mode: "cleanup" }; await publishProtocolPrivateJSON(permitPath, permit);
      const before = model.calls.length, cleanup = await communityQueryCommand(args("cleanup"), options);
      assert.equal(cleanup.exitCode, 0); assert.equal(cleanup.windowCalls, 3);
      assert.equal(model.calls.slice(before).some(call => call.operation === "records/query" || call.payload.operations?.some(op => op.operationType === "create")), false);
    }
    assert.equal(model.records.size, 0);
    await assert.rejects(communityQueryCommand(args("run"), options), code(revoke ? "CLI_PERMIT" : "CLI_RECOVERY"));
  }
});

test("failed durable commit sends nothing; body size and pending drain errors never become accepted results", async t => {
  const f = await queryFixture(t), originalWrite = f.journal.write.bind(f.journal); let writes = 0;
  f.journal.write = value => { if (++writes === 2) throw new Error("Synthetic disk full"); return originalWrite(value); };
  const failed = await f.run(); assert.equal(failed.storageHealthy, false); assert.equal(failed.protocolSucceeded, false); assert.equal(f.model.calls.length, 0);
  for (const response of [new Response("{}", { headers: { "Content-Type": "text/html" } }),
    new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "65537" } }),
    new Response(" ".repeat(65537), { headers: { "Content-Type": "application/json" } })]) {
    const prepared = makeCommunityQueryPlan(), client = new CommunityQueryTransport({ prepared, signer: signer(), isEnabled: () => true,
      fetchImplementation: async () => response });
    await assert.rejects(client.request("records/query", communityQueryPayload(prepared.plan, "presence")), code("PROTOCOL_RESPONSE"));
    await client.waitForPendingOperations();
  }
  const prepared = makeCommunityQueryPlan(), controller = new AbortController(), entered = barrier();
  const stream = new ReadableStream({ start() { entered.release(); }, cancel() { throw new Error("Synthetic drain fault"); } });
  const client = new CommunityQueryTransport({ prepared, signer: signer(), isEnabled: () => true, fetchImplementation: async () =>
    new Response(stream, { headers: { "Content-Type": "application/json" } }) });
  const pending = client.request("records/query", communityQueryPayload(prepared.plan, "presence"), { signal: controller.signal });
  await entered.promise; await new Promise(resolve => setImmediate(resolve)); controller.abort();
  await assert.rejects(pending, code("PROTOCOL_CANCELLED")); await assert.rejects(client.waitForPendingOperations(), code("PROTOCOL_DRAIN"));
});
