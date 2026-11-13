import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runReservedProbe } from "../src/probe-gate.mjs";
import { makeDevelopmentProbeContext } from "../src/cloudkit-probe.mjs";

const runID = "00000000-0000-4000-8000-000000000001";
const adapter = (db) => ({ exec: (sql, ...values) => {
  const rows = db.prepare(sql).all(...values);
  return { toArray: () => rows };
} });
function success(context) {
  return { runIdentifier: context.runIdentifier, syntheticRecordName: context.syntheticRecordName,
    writeSucceeded: true, readBackSucceeded: true, cleanupSucceeded: true };
}

test("concurrent and repeated requests execute one persisted run", async () => {
  const db = new DatabaseSync(":memory:");
  try {
    let calls = 0, release;
    const wait = new Promise((resolve) => { release = resolve; });
    const execute = async (context) => {
      calls++;
      const stored = JSON.parse(db.prepare("SELECT context FROM development_probe WHERE run_id=?").get(runID).context);
      assert.equal(stored.nonce, context.nonce); // Reconciliation exists before any external operation.
      await wait;
      return success(context);
    };
    const first = runReservedProbe(adapter(db), runID, execute);
    const running = await runReservedProbe(adapter(db), runID, execute);
    assert.equal(running.status, 202);
    const pending = await running.json();
    assert.equal(pending.state, "running-or-unknown");
    assert.equal(Object.hasOwn(pending, "nonce"), false);
    assert.equal(calls, 1);
    release();
    const report = await (await first).json();
    const repeated = await runReservedProbe(adapter(db), runID, execute);
    assert.equal(repeated.status, 200);
    assert.deepEqual(await repeated.json(), report);
    assert.equal(calls, 1);
  } finally { db.close(); }
});

test("completed reservation survives a new database connection", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-probe-ledger-"));
  const path = join(directory, "ledger.sqlite");
  let db = new DatabaseSync(path);
  try {
    await runReservedProbe(adapter(db), runID, async (context) => success(context));
    db.close();
    db = new DatabaseSync(path);
    const report = await runReservedProbe(adapter(db), runID, () => { throw new Error("Must not execute again"); });
    assert.equal(report.status, 200);
    assert.equal((await report.json()).cleanupSucceeded, true);
  } finally { db.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("unknown execution is retained without exposing the exception or restarting", async () => {
  const db = new DatabaseSync(":memory:");
  try {
    let calls = 0;
    const execute = async () => { calls++; throw new Error("SYNTHETIC-SECRET-DETAIL"); };
    const first = await runReservedProbe(adapter(db), runID, execute);
    assert.equal(first.status, 502);
    const report = await first.json();
    assert.equal(report.errorCode, "EXECUTION_UNKNOWN");
    assert.equal(JSON.stringify(report).includes("SYNTHETIC-SECRET-DETAIL"), false);
    assert.equal((await runReservedProbe(adapter(db), runID, execute)).status, 502);
    assert.equal(calls, 1);
  } finally { db.close(); }
});

test("crash marker does not start another CloudKit write", async () => {
  const db = new DatabaseSync(":memory:");
  try {
    db.exec("CREATE TABLE development_probe(run_id TEXT PRIMARY KEY,status TEXT NOT NULL,context TEXT NOT NULL,report TEXT,http_status INTEGER)");
    const context = makeDevelopmentProbeContext();
    db.prepare("INSERT INTO development_probe(run_id,status,context) VALUES (?,'running',?)").run(runID, JSON.stringify(context));
    const response = await runReservedProbe(adapter(db), runID, () => { throw new Error("Must not execute"); });
    assert.equal(response.status, 202);
    assert.equal((await response.json()).syntheticRecordName, context.syntheticRecordName);
  } finally { db.close(); }
});

test("cleanup failure is not a successful response or a reason to rerun", async () => {
  const db = new DatabaseSync(":memory:");
  try {
    let calls = 0;
    const execute = async (context) => { calls++; return { ...success(context), cleanupSucceeded: false, cleanupErrorCode: "THROTTLED" }; };
    const first = await runReservedProbe(adapter(db), runID, execute);
    assert.equal(first.status, 502);
    assert.equal((await first.json()).cleanupErrorCode, "THROTTLED");
    assert.equal((await runReservedProbe(adapter(db), runID, execute)).status, 502);
    assert.equal(calls, 1);
  } finally { db.close(); }
});

test("durability confirmation precedes external work; a failed confirmation never executes it", async () => {
  const db = new DatabaseSync(":memory:");
  try {
    let executed = 0, release;
    const durable = new Promise((resolve) => { release = resolve; });
    const pending = runReservedProbe(adapter(db), runID, async (context) => { executed++; return success(context); }, () => durable);
    assert.equal(executed, 0);
    release();
    assert.equal((await pending).status, 200);
    assert.equal(executed, 1);
    const secondRun = "00000000-0000-4000-8000-000000000002";
    await assert.rejects(() => runReservedProbe(adapter(db), secondRun, async () => { executed++; },
      async () => { throw new Error("Synthetic storage failure"); }), /storage failure/);
    assert.equal(executed, 1);
  } finally { db.close(); }
});
