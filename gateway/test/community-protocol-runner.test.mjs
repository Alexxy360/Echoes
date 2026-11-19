import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { join } from "node:path";
import { CommunityProtocolJournal } from "../scripts/community-protocol-journal.mjs";
import { checkpointRecordName } from "../src/public-registry-checkpoint.mjs";
import { protocolFixture, barrier } from "./support/community-protocol-fixture.mjs";

const code = value => error => error?.code === value;
const creates = f => f.model.calls.filter(call => call.payload.operations?.[0]?.operationType === "create");
const deletes = f => f.model.calls.filter(call => call.payload.operations?.[0]?.operationType === "delete");

test("all eight protocol records complete conditional replacement, null-field removal, stale conflict and verified cleanup in nine calls", async t => {
  const f = await protocolFixture(t); f.model.nullFields = true;
  f.model.records.set(checkpointRecordName, { fields: { privateSentinel: { value: "UNRELATED" } } });
  const report = await f.run();
  assert.equal(report.protocolSucceeded, true); assert.equal(report.cleanupSucceeded, true); assert.equal(report.windowCalls, 9);
  assert.deepEqual(report.pendingRecordNames, []); assert.equal(creates(f).length, 1); assert.equal(deletes(f).length, 1);
  assert.equal(f.model.records.size, 1); assert.equal(f.model.records.get(checkpointRecordName).fields.privateSentinel.value, "UNRELATED");
  for (const call of f.model.calls) {
    const names = call.payload.records?.map(row => row.recordName) ?? call.payload.operations.map(row => row.record.recordName);
    assert.ok(names.every(name => f.prepared.plan.records.some(item => item.recordName === name)));
  }
  const stale = f.model.calls.filter(call => call.payload.operations?.[0]?.operationType === "replace").at(-1);
  for (const operation of stale.payload.operations.filter(operation => operation.record.recordType !== "EchoesRegistryCheckpointV1")) {
    assert.equal(operation.record.fields.erased.value, 1); assert.equal(operation.record.fields.name, undefined);
  }
  await f.reopen(); assert.equal(f.journal.snapshot().state.cleanupComplete, true);
  await assert.rejects(f.run(), code("PROTOCOL_RECOVERY")); assert.equal(creates(f).length, 1);
});

test("preflight existing data aborts before mutations and never cleans it", async t => {
  const f = await protocolFixture(t), item = f.prepared.plan.records[0];
  f.model.records.set(item.recordName, { recordName: item.recordName, fields: { owner: { value: "OTHER" } } });
  const report = await f.run();
  assert.equal(report.protocolSucceeded, false); assert.equal(report.errorCode, "PROTOCOL_EXISTING");
  assert.equal(f.model.calls.length, 1); assert.equal(creates(f).length, 0); assert.equal(deletes(f).length, 0);
  assert.equal(f.model.records.get(item.recordName).fields.owner.value, "OTHER");
});

test("a create collision remains protected even in a malformed partial batch response", async t => {
  const f = await protocolFixture(t), item = f.prepared.plan.records[0];
  f.model.before = call => {
    if (call.payload.operations?.[0]?.operationType === "create") f.model.records.set(item.recordName, {
      recordName: item.recordName, recordType: item.recordType, recordChangeTag: "other-tag", fields: structuredClone(item.initial) });
  };
  f.model.after = (call, body) => call.payload.operations?.[0]?.operationType === "create" ? { records: body.records.slice(0, -1) } : undefined;
  const report = await f.run();
  assert.equal(report.protocolSucceeded, false); assert.equal(report.cleanupSucceeded, true);
  assert.deepEqual(report.skippedExistingRecordNames, [item.recordName]); assert.equal(f.model.records.size, 1);
  assert.ok(deletes(f).every(call => call.payload.operations.every(operation => operation.record.recordName !== item.recordName)));
});

test("unknown create with committed own records reconciles and cleans without another create", async t => {
  const f = await protocolFixture(t);
  f.model.after = call => { if (call.payload.operations?.[0]?.operationType === "create") throw new Error("PRIVATE-PROVIDER-DETAIL"); };
  const report = await f.run();
  assert.equal(report.protocolSucceeded, false); assert.equal(report.cleanupSucceeded, true);
  assert.equal(f.model.records.size, 0); assert.equal(creates(f).length, 1);
  assert.equal(JSON.stringify(report).includes("PRIVATE-PROVIDER-DETAIL"), false);
});

test("missing records after unknown create remain pending; a fresh cleanup window recovers a delayed write after reopen", async t => {
  const f = await protocolFixture(t); let delayed;
  f.model.before = call => {
    if (call.payload.operations?.[0]?.operationType === "create") { delayed = structuredClone(call.payload); throw new Error("unknown create"); }
  };
  const first = await f.run();
  assert.equal(first.cleanupSucceeded, false); assert.equal(first.pendingRecordNames.length, 8); assert.equal(deletes(f).length, 0);
  await f.reopen(); f.advance(1000); f.model.before = undefined;
  f.model.apply("records/modify", delayed);
  const recovered = await f.run({ window: f.window("cleanup") });
  assert.equal(recovered.cleanupSucceeded, true); assert.equal(recovered.protocolSucceeded, false);
  assert.equal(f.model.records.size, 0); assert.equal(creates(f).length, 1);
});

test("revocation and expired permission leave cleanup pending without further remote IO", async t => {
  const f = await protocolFixture(t); let authorized = true;
  f.model.after = call => { if (call.payload.operations?.[0]?.operationType === "create") authorized = false; };
  const report = await f.run({ isAuthorized: () => authorized });
  assert.equal(report.cleanupSucceeded, false); assert.equal(report.errorCode, "PROTOCOL_DENIED");
  assert.equal(f.model.calls.length, 2); assert.equal(f.model.records.size, 8);
  await f.reopen(); f.advance(1000); f.model.after = undefined;
  assert.equal((await f.run({ window: f.window("cleanup") })).cleanupSucceeded, true);
});

for (const variant of ["wall rollback", "monotonic rollback", "expiry"]) test(`protocol closes on ${variant} after a write`, async t => {
  const f = await protocolFixture(t);
  f.model.after = call => {
    if (call.payload.operations?.[0]?.operationType !== "create") return;
    if (variant === "wall rollback") f.moveWall(-1);
    else if (variant === "monotonic rollback") f.moveMono(-1);
    else f.advance(60000);
  };
  const report = await f.run();
  assert.equal(report.cleanupSucceeded, false); assert.equal(f.model.calls.length, 2);
  assert.equal(report.errorCode, variant === "expiry" ? "PROTOCOL_WINDOW" : "PROTOCOL_CLOCK");
});

test("cancellation retains the run and filesystem lock until actual in-flight work finishes", async t => {
  const f = await protocolFixture(t), entered = barrier(), release = barrier(), controller = new AbortController();
  f.model.before = async call => { if (call.payload.operations?.[0]?.operationType === "create") { entered.release(); await release.promise; } };
  const running = f.run({ signal: controller.signal }); let settled = false; void running.then(() => settled = true);
  await entered.promise; controller.abort(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(settled, false); assert.equal(f.model.calls.length, 2); assert.throws(() => f.journal.close(), code("JOURNAL_BUSY"));
  await assert.rejects(CommunityProtocolJournal.open(f.journal.directory, f.prepared.sha256));
  release.release(); const report = await running;
  assert.equal(report.cleanupSucceeded, false); assert.equal(f.model.calls.length, 2); assert.equal(f.model.records.size, 8);
});

test("failed drain cannot release the journal; explicit local drain confirmation releases it without network calls", async t => {
  const f = await protocolFixture(t); f.model.drainFault = true;
  const report = await f.run();
  assert.equal(report.pendingIO, true); assert.equal(report.cleanupSucceeded, false);
  assert.throws(() => f.journal.close(), code("JOURNAL_BUSY"));
  const count = f.model.calls.length; f.model.drainFault = false; await report.waitForSafeRelease();
  assert.equal(f.model.calls.length, count); await f.reopen();
});

test("a transaction failure before create prevents dispatch and preserves the previous journal revision", async t => {
  const f = await protocolFixture(t), db = new DatabaseSync(join(f.journal.directory, "journal.sqlite"));
  db.exec(`CREATE TRIGGER synthetic_failure BEFORE UPDATE ON snapshot WHEN json_extract(NEW.state,'$.phase')='create_pending'
    BEGIN SELECT RAISE(ABORT,'synthetic local failure'); END`); db.close();
  const report = await f.run();
  assert.equal(report.storageHealthy, false); assert.equal(creates(f).length, 0); assert.equal(deletes(f).length, 0);
  assert.equal(f.journal.snapshot().state.createAttempted, false);
  await f.reopen(); assert.equal(f.journal.snapshot().state.callsTotal, 1);
});

test("a failed final commit cannot expose volatile terminal success", async t => {
  const f = await protocolFixture(t), db = new DatabaseSync(join(f.journal.directory, "journal.sqlite"));
  db.exec(`CREATE TRIGGER synthetic_final_failure BEFORE UPDATE ON snapshot WHEN json_extract(NEW.state,'$.phase')='settled'
    BEGIN SELECT RAISE(ABORT,'synthetic final failure'); END`); db.close();
  const report = await f.run();
  assert.equal(report.storageHealthy, false); assert.equal(report.cleanupSucceeded, false); assert.equal(report.protocolSucceeded, false);
  assert.equal(f.model.records.size, 0); assert.equal(f.journal.snapshot().state.cleanupComplete, false);
});

test("unexpected content or a different record type is never erased by cleanup", async t => {
  const f = await protocolFixture(t), item = f.prepared.plan.records[2];
  f.model.after = (call, body) => {
    if (call.payload.operations?.[0]?.operationType === "create") {
      f.model.records.get(item.recordName).fields.extra = { type: "STRING", value: "PRIVATE-UNEXPECTED" };
      throw new Error("unknown response");
    }
  };
  const report = await f.run();
  assert.deepEqual(report.pendingRecordNames, [item.recordName]); assert.equal(f.model.records.size, 1);
  assert.equal(JSON.stringify(report).includes("PRIVATE-UNEXPECTED"), false);
});

test("default authorization is closed and cleanup cannot replay an earlier authorization window", async t => {
  const f = await protocolFixture(t), window = f.window();
  await assert.rejects(f.run({ isAuthorized: undefined, window }), code("PROTOCOL_DENIED"));
  assert.equal(f.model.calls.length, 0); assert.equal(f.journal.snapshot().state, null);
  await f.run({ window });
  await assert.rejects(f.run({ window: { ...window, mode: "cleanup" } }), code("PROTOCOL_RECOVERY"));
});

test("dispatch timeout uses permission remaining after the durable commit rather than before disk IO", async t => {
  const f = await protocolFixture(t), entered = barrier(), release = barrier(), aborted = barrier(); let advanced = false;
  const journal = { snapshot: () => f.journal.snapshot(), beginRun: () => f.journal.beginRun(), endRun: token => f.journal.endRun(token),
    write(state) {
      const result = f.journal.write(state);
      if (state.phase === "create_pending" && !advanced) { advanced = true; f.advance(4995); }
      return result;
    } };
  f.model.before = async call => {
    if (call.payload.operations?.[0]?.operationType === "create") {
      call.signal.addEventListener("abort", aborted.release, { once: true }); entered.release(); await release.promise;
    }
  };
  const running = f.run({ journal, window: f.window("full", 5000) }); let timer;
  try {
    await entered.promise;
    await Promise.race([aborted.promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Dispatch retained the pre-commit timeout.")), 250); })]);
  } finally { clearTimeout(timer); release.release(); await running; }
  assert.equal(f.report.errorCode, "PROTOCOL_TIMEOUT");
});
