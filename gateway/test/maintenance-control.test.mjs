import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate as tick } from "node:timers/promises";
import { GatewayMaintenanceBudget, MaintenanceProviderWork, MaintenanceControlError } from "../src/gateway-maintenance-control.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";
import { AppleOAuthClient, AppleOAuthError } from "../src/apple-oauth.mjs";
import { fixture, hash } from "./support/authentication-fixture.mjs";

const day = 86400000, minute = 60000;
const code = value => error => error instanceof MaintenanceControlError && error.code === value && error.message === "Maintenance could not be completed." && error.cause === undefined;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function setup({ at, ...options } = {}) {
  const f = fixture(options); f.advance((at ?? f.clock() - f.clock() % day) - f.clock());
  return { ...f, budget: new GatewayMaintenanceBudget(f.storage, { clock: f.clock }) };
}

test("maintenance budget consumes one durable provider attempt per UTC minute across both lanes", async () => {
  const f = setup();
  try {
    const permit = await f.budget.consume("deletion"); f.budget.assertCurrent(permit);
    assert.equal(f.budget.preferredLane(), "retention");
    await assert.rejects(() => f.budget.consume("retention"), code("MAINTENANCE_LIMITED"));
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1").get().total, 1);
    f.advance(minute); await f.budget.consume("retention");
    assert.equal(f.budget.preferredLane(), "deletion");
    assert.throws(() => f.budget.assertCurrent(permit), code("MAINTENANCE_UNAVAILABLE"));
  } finally { f.close(); }
});

test("simultaneous alarm retries cannot reserve two attempts in the same minute", async () => {
  const f = setup();
  try {
    const results = await Promise.allSettled([f.budget.consume("deletion"), f.budget.consume("retention")]);
    assert.equal(results.filter(r => r.status === "fulfilled").length, 1);
    assert.equal(results.filter(r => r.status === "rejected" && code("MAINTENANCE_LIMITED")(r.reason)).length, 1);
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1").get().total, 1);
  } finally { f.close(); }
});

test("daily lane reservations prevent one class from consuming the other's capacity and reset at UTC midnight", async () => {
  const f = setup();
  try {
    for (let i = 0; i < 180; i++) { await f.budget.consume("retention"); f.advance(minute); }
    await assert.rejects(() => f.budget.consume("retention"), code("MAINTENANCE_LIMITED"));
    for (let i = 0; i < 180; i++) { await f.budget.consume("deletion"); f.advance(minute); }
    const counts = f.db.prepare("SELECT total,deletion,retention FROM maintenance_daily_v1").get();
    assert.deepEqual({ ...counts }, { total: 360, deletion: 180, retention: 180 });
    for (const lane of ["deletion", "retention"]) await assert.rejects(() => f.budget.consume(lane), code("MAINTENANCE_LIMITED"));
    f.advance(day - f.clock() % day); await f.budget.consume("retention");
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1 ORDER BY day DESC LIMIT 1").get().total, 1);
  } finally { f.close(); }
});

test("user request quota exhaustion does not consume the reserved maintenance pool", async () => {
  const f = setup();
  try {
    const limits = new GatewayLimits(f.storage, { clock: f.clock });
    for (let i = 0; i < 2000; i++) await limits.consume(hash("synthetic-user-" + i));
    await assert.rejects(() => limits.consume(hash("blocked")), e => e.code === "RATE_LIMITED");
    await f.budget.consume("retention");
    assert.equal(f.db.prepare("SELECT requests FROM gateway_daily_v1").get().requests, 2000);
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1").get().total, 1);
  } finally { f.close(); }
});

test("maintenance consumption leaves ordinary request budgets unchanged", async () => {
  const f = setup();
  try {
    await f.budget.consume("deletion");
    const limits = new GatewayLimits(f.storage, { clock: f.clock }); await limits.consume(hash("user"), { heavy: true });
    assert.deepEqual({ ...f.db.prepare("SELECT requests,heavy FROM gateway_daily_v1").get() }, { requests: 1, heavy: 1 });
  } finally { f.close(); }
});

test("file-backed reopen preserves the minute fence, counters and next lane", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-maintenance-budget-")), path = join(directory, "state.sqlite");
  let f = setup({ path });
  try {
    await f.budget.consume("deletion"); const at = f.clock(); f.close(); f = setup({ path, at });
    assert.equal(f.budget.preferredLane(), "retention");
    await assert.rejects(() => f.budget.consume("retention"), code("MAINTENANCE_LIMITED"));
    f.advance(minute); await f.budget.consume("retention");
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1").get().total, 2);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("purging old days retains a clock floor and cannot restore a previous day's budget", async () => {
  const f = setup();
  try {
    await f.budget.consume("deletion"); f.advance(3 * day); await f.budget.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) n FROM maintenance_daily_v1").get().n, 0);
    f.advance(-2 * day); await assert.rejects(() => f.budget.consume("retention"), code("MAINTENANCE_UNAVAILABLE"));
    await assert.rejects(() => f.budget.purgeExpired(), code("MAINTENANCE_UNAVAILABLE"));
  } finally { f.close(); }
});

test("failed durability or an expired permit never authorizes provider work and the attempt remains consumed", async () => {
  const f = setup();
  try {
    f.storage.sync = async () => { throw new Error("PRIVATE-storage"); };
    await assert.rejects(() => f.budget.consume("deletion"), code("MAINTENANCE_UNAVAILABLE"));
    f.storage.sync = async () => {};
    await assert.rejects(() => f.budget.consume("retention"), code("MAINTENANCE_LIMITED"));
    f.advance(minute); const permit = await f.budget.consume("retention");
    assert.throws(() => f.budget.assertCurrent({ ...permit, lane: "deletion" }), code("MAINTENANCE_UNAVAILABLE"));
    f.advance(minute); assert.throws(() => f.budget.assertCurrent(permit), code("MAINTENANCE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT total FROM maintenance_daily_v1").get().total, 2);
  } finally { f.close(); }
});

test("crossing midnight during durability closes the old permit before any provider call", async () => {
  const f = setup();
  try {
    f.advance(day - 1);
    f.storage.sync = async () => { f.advance(1); };
    await assert.rejects(() => f.budget.consume("deletion"), code("MAINTENANCE_UNAVAILABLE"));
  } finally { f.close(); }
});

test("bad lane, clock and corrupted counters fail with a sanitized control error", async () => {
  const f = setup();
  try {
    await assert.rejects(() => f.budget.consume("client-picked"), code("MAINTENANCE_UNAVAILABLE"));
    const bad = new GatewayMaintenanceBudget(f.storage, { clock() { throw new Error("PRIVATE-clock"); } });
    await assert.rejects(() => bad.consume("retention"), code("MAINTENANCE_UNAVAILABLE"));
    await f.budget.consume("retention"); f.advance(minute);
    f.db.exec("UPDATE maintenance_daily_v1 SET total=0");
    await assert.rejects(() => f.budget.consume("deletion"), code("MAINTENANCE_UNAVAILABLE"));
  } finally { f.close(); }
});

test("the provider slot is retained until actual drain even after a step returns", async () => {
  const drain = deferred(); const work = new MaintenanceProviderWork(() => drain.promise); let calls = 0;
  assert.equal(await work.run(async () => "finished"), "finished"); assert.equal(work.isOccupied, true);
  await assert.rejects(() => work.run(async () => { calls++; }), code("MAINTENANCE_BUSY"));
  assert.equal(calls, 0); drain.resolve(); await tick(); assert.equal(work.isOccupied, false);
});

test("failed provider drain keeps both lanes closed instead of assuming the work stopped", async () => {
  const work = new MaintenanceProviderWork(async () => { throw new Error("PRIVATE-drain"); });
  await work.run(async () => {}); await tick(); assert.equal(work.isOccupied, true);
  await assert.rejects(() => work.run(async () => {}), code("MAINTENANCE_BUSY"));
});

test("an ignored Apple revoke fetch remains tracked after its timeout", async () => {
  const entered = deferred(), release = deferred();
  const apple = new AppleOAuthClient({ clientSecret: { create: () => "SYNTHETIC-JWT" }, timeoutMilliseconds: 20,
    fetchImplementation: async () => { entered.resolve(); await release.promise; return new Response(null); } });
  const work = new MaintenanceProviderWork(() => apple.waitForPendingOperations());
  try {
    const pending = work.run(() => apple.revokeRefreshToken("SYNTHETIC-REFRESH")); await entered.promise;
    await assert.rejects(() => pending, e => e instanceof AppleOAuthError && e.code === "OAUTH_UNAVAILABLE");
    assert.equal(work.isOccupied, true);
    await assert.rejects(() => work.run(async () => {}), code("MAINTENANCE_BUSY"));
    release.resolve(); await apple.waitForPendingOperations(); await tick(); assert.equal(work.isOccupied, false);
  } finally { release.resolve(); await apple.waitForPendingOperations(); }
});

test("Apple response body cancellation keeps the first cancel promise tracked until it settles", async () => {
  const entered = deferred(), release = deferred(); let cancelled = false;
  const apple = new AppleOAuthClient({ clientSecret: { create: () => "SYNTHETIC-JWT" }, timeoutMilliseconds: 20,
    fetchImplementation: async () => new Response(new ReadableStream({
      pull() { entered.resolve(); return release.promise; }, cancel() { cancelled = true; return release.promise; },
    }), { headers: { "Content-Type": "application/json" } }) });
  const work = new MaintenanceProviderWork(() => apple.waitForPendingOperations());
  try {
    const pending = work.run(() => apple.revokeRefreshToken("SYNTHETIC-REFRESH")); await entered.promise;
    await assert.rejects(() => pending, e => e instanceof AppleOAuthError && e.code === "OAUTH_UNAVAILABLE");
    assert.equal(cancelled, true); assert.equal(work.isOccupied, true);
    release.resolve(); await apple.waitForPendingOperations(); await tick(); assert.equal(work.isOccupied, false);
  } finally { release.resolve(); await apple.waitForPendingOperations(); }
});

test("Apple body transport bounds empty fragment floods and rejects non-byte chunks with a sanitized error", async () => {
  for (const invalidChunk of [false, true]) {
    let reads = 0, cancelled = false;
    const apple = new AppleOAuthClient({ clientSecret: { create: () => "SYNTHETIC-JWT" },
      fetchImplementation: async () => new Response(new ReadableStream({
        pull(controller) { reads++; controller.enqueue(invalidChunk ? "PRIVATE-INVALID-CHUNK" : new Uint8Array()); },
        cancel() { cancelled = true; },
      }), { headers: { "Content-Type": "application/json" } }) });
    await assert.rejects(() => apple.revokeRefreshToken("SYNTHETIC-REFRESH"), error =>
      error instanceof AppleOAuthError && error.code === "OAUTH_UNAVAILABLE" && error.cause === undefined && !JSON.stringify(error).includes("PRIVATE"));
    await apple.waitForPendingOperations(); assert.equal(cancelled, true); assert.ok(reads <= (invalidChunk ? 2 : 4098));
  }
});
