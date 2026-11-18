import assert from "node:assert/strict";
import { test } from "node:test";
import { setImmediate as tick } from "node:timers/promises";
import { readFileSync } from "node:fs";
import { maintenanceRuntimeFixture } from "./support/maintenance-runtime-fixture.mjs";
import { activeGatewayConfiguration, createGatewayLocalMaintenance } from "../src/gateway-runtime.mjs";

const expireMessages = f => f.advance(7200001);
const pending = f => f.db.prepare("SELECT count(*) AS n FROM public_retention_v1 WHERE state='pending'").get().n;
const erased = f => f.db.prepare("SELECT count(*) AS n FROM public_records_v1 WHERE phase='erased'").get().n;
const runAlarm = runtime => runtime.maintenance.alarm({ processor: runtime.processor });

test("retention is opt-in and a disabled alarm makes no provider or checkpoint call", async () => {
  const f = await maintenanceRuntimeFixture();
  try {
    await f.message(); expireMessages(f); delete f.env.PUBLIC_RETENTION_ENABLED;
    const runtime = f.activate(), before = f.counts(); await runAlarm(runtime);
    assert.deepEqual(f.counts(), before); assert.equal(pending(f), 1); assert.equal(f.budget(), undefined);
    assert.equal(activeGatewayConfiguration(f.env, f.clock()).retentionEnabled, false);
    const config = readFileSync(new URL("../wrangler.community.jsonc", import.meta.url), "utf8");
    assert.match(config, /"PUBLIC_RETENTION_ENABLED"\s*:\s*"0"/);
    for (const value of ["true", "", 1]) assert.equal(activeGatewayConfiguration({ ...f.env, PUBLIC_RETENTION_ENABLED: value }, f.clock()), null);
    assert.equal(activeGatewayConfiguration({ ...f.env, PUBLIC_RETENTION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "0" }, f.clock()), null);
  } finally { f.close(); }
});

test("an alarm runs retention without a community request or a live user session", async () => {
  const f = await maintenanceRuntimeFixture();
  try {
    const { record } = await f.message(); expireMessages(f);
    const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" }); await runAlarm(runtime); await tick();
    assert.equal(erased(f), 1); assert.equal(f.model.records.get(record.recordName).fields.text, undefined);
    assert.deepEqual({ ...f.budget() }, { total: 1, deletion: 0, retention: 1 });
    assert.equal(f.env.COMMUNITY_ENABLED, "0"); assert.equal(f.counts().apple, 0);
  } finally { f.close(); }
});

test("a real Runtime processes at most 25 rows per minute and ignores same-minute alarm retries", async () => {
  const f = await maintenanceRuntimeFixture();
  try {
    for (let i = 0; i < 26; i++) await f.message(); expireMessages(f);
    const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" }); await runAlarm(runtime); await tick();
    assert.equal(erased(f), 25); assert.equal(pending(f), 1);
    const before = f.counts(); await runAlarm(runtime);
    assert.deepEqual(f.counts(), before); assert.equal(f.budget().total, 1);
    f.advance(60000); await runAlarm(runtime); await tick();
    assert.equal(erased(f), 26); assert.equal(f.budget().total, 2);
  } finally { f.close(); }
});

test("account erasure and retention alternate independent provider lanes in the actual Runtime", async () => {
  const f = await maintenanceRuntimeFixture();
  try {
    const other = await f.session("synthetic.other"); await f.message(other); expireMessages(f);
    const fresh = await f.session(); const ticket = await f.beginDeletion(fresh); f.advance(60001);
    const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" }); await runAlarm(runtime); await tick();
    assert.equal(f.budget().deletion, 1); assert.equal(f.budget().retention, 0);
    assert.equal(f.counts().apple, 1); assert.equal(pending(f), 1);
    const job = f.db.prepare("SELECT tokens_processed,apple_status,public_status FROM auth_account_deletions_v1 WHERE deletion_id=?").get(ticket.deletionID);
    assert.deepEqual({ ...job }, { tokens_processed: 1, apple_status: "pending", public_status: "deleted" });
    f.advance(60000); await runAlarm(runtime); await tick();
    assert.deepEqual({ ...f.budget() }, { total: 2, deletion: 1, retention: 1 }); assert.equal(erased(f), 1);
  } finally { f.close(); }
});

test("disabling retention during durable admission consumes its attempt without making a provider call", async () => {
  let f, armed = false;
  f = await maintenanceRuntimeFixture({ syncHook: async () => {
    if (armed && f.db.prepare("SELECT last_ticket FROM maintenance_control_v1 WHERE singleton=1").get()?.last_ticket) f.env.PUBLIC_RETENTION_ENABLED = "0";
  } });
  try {
    await f.message(); expireMessages(f); const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" });
    const before = f.counts(); armed = true;
    await assert.rejects(() => runAlarm(runtime));
    assert.deepEqual(f.counts(), before); assert.equal(f.budget().retention, 1); assert.equal(pending(f), 1);
  } finally { f.close(); }
});

test("inactive or expired Runtime and key-free local maintenance preserve remote jobs without provider IO", async () => {
  const f = await maintenanceRuntimeFixture();
  try {
    await f.message(); expireMessages(f);
    const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" }); const before = f.counts();
    f.env.GATEWAY_ENABLED = "0"; await runAlarm(runtime);
    f.env.GATEWAY_ENABLED = "1"; f.env.GATEWAY_EXPIRES_AT = new Date(f.clock()).toISOString(); await runAlarm(runtime);
    delete f.env.CLOUDKIT_PRIVATE_KEY; assert.throws(() => f.activate());
    await createGatewayLocalMaintenance(f.storage, { clock: f.clock }).alarm();
    assert.deepEqual(f.counts(), before); assert.equal(pending(f), 1); assert.equal(f.budget(), undefined);
  } finally { f.close(); }
});

test("a timed-out Runtime retains its provider slot across later alarm minutes until real IO settles", { timeout: 20000 }, async () => {
  const f = await maintenanceRuntimeFixture(); let release, entered;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  try {
    await f.message(); expireMessages(f); const runtime = f.activate({ PUBLIC_RETENTION_ENABLED: "1" });
    f.model.before = async call => { if (call.operation === "lookup") { entered(); await held; } };
    const first = assert.rejects(() => runAlarm(runtime)); await started; await first;
    const before = f.counts(); assert.equal(f.budget().total, 1);
    f.advance(60000); await runAlarm(runtime);
    assert.deepEqual(f.counts(), before); assert.equal(f.budget().total, 1);
    release(); await tick(); await tick(); f.model.before = undefined;
    await runAlarm(runtime); await tick(); assert.equal(f.budget().total, 2); assert.equal(erased(f), 1);
  } finally { release(); await tick(); f.close(); }
});
