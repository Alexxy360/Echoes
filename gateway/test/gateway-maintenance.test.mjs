import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { GatewayLimits, GatewayLimitError, edgeBudgetHash } from "../src/gateway-limits.mjs";
import { GatewayMaintenance } from "../src/gateway-maintenance.mjs";
import { AccountDeletionState } from "../src/account-deletion-state.mjs";
import { appleSubjectHash } from "../src/refresh-credential-vault.mjs";
import { fixture, hash, start } from "./support/authentication-fixture.mjs";

const secret = randomBytes(32).toString("base64url");
const limited = code => error => error instanceof GatewayLimitError && error.code === code && error.cause === undefined;
function setup(options) {
  const f = fixture(options); let alarm = null, writes = 0;
  f.storage.getAlarm = async () => alarm;
  f.storage.deleteAlarm = async () => { alarm = null; };
  f.storage.setAlarm = async value => { alarm = value; writes++; };
  const limits = new GatewayLimits(f.storage, { clock: f.clock });
  const deletions = new AccountDeletionState(f.storage, { clock: f.clock });
  const maintenance = new GatewayMaintenance(f.storage, { clock: f.clock, limits, deletions });
  return { ...f, limits, deletions, maintenance, alarm: () => alarm, alarmWrites: () => writes,
    addJob(id = randomUUID()) {
      f.db.prepare(`INSERT INTO auth_account_deletions_v1
        (deletion_id,status_hash,account_id,subject_hash,created_at,settle_after) VALUES (?,?,?,?,?,?)`)
        .run(id, hash(id), randomUUID(), hash(id), f.clock(), f.clock() + 60000);
      return id;
    },
  };
}

test("edge budget canonicalizes IPv6 networks and mapped IPv4 and changes across UTC days without storing the IP", () => {
  const key = ip => edgeBudgetHash(ip, secret, start);
  assert.equal(key("2001:db8:1:2::1"), key("2001:0DB8:0001:0002:ffff:0000:0000:2"));
  assert.notEqual(key("2001:db8:1:2::1"), key("2001:db8:1:3::1"));
  assert.equal(key("192.0.2.1"), key("::FFFF:192.0.2.1"));
  assert.notEqual(key("192.0.2.1"), edgeBudgetHash("192.0.2.1", secret, start + 86400000));
  assert.match(key("192.0.2.1"), /^[a-f0-9]{64}$/);
  for (const value of [undefined, "", "192.0.2.1, 198.51.100.1", "private", "fe80::1%en0", "[::1]"]) {
    assert.throws(() => key(value), limited("LIMIT_UNAVAILABLE"));
  }
  assert.throws(() => edgeBudgetHash("192.0.2.1", "weak", start), limited("LIMIT_UNAVAILABLE"));
});

test("durable network and heavy windows deny excess requests and reopen after a minute", async () => {
  const f = setup();
  try {
    for (let i = 0; i < 120; i++) await f.limits.consume(hash("network"));
    await assert.rejects(() => f.limits.consume(hash("network")), limited("RATE_LIMITED"));
    for (let i = 0; i < 12; i++) await f.limits.consume(hash("heavy-network"), { heavy: true });
    await assert.rejects(() => f.limits.consume(hash("heavy-network"), { heavy: true }), limited("RATE_LIMITED"));
    f.advance(60000); await f.limits.consume(hash("network")); await f.limits.consume(hash("heavy-network"), { heavy: true });
    for (const row of f.db.prepare("SELECT * FROM gateway_windows_v1").all()) assert.match(row.key_hash, /^[a-f0-9]{64}$/);
  } finally { f.close(); }
});

test("global request and expensive-operation ceilings survive different budget hashes and reset at UTC day change", async () => {
  const f = setup();
  try {
    for (let i = 0; i < 300; i++) await f.limits.consume(hash("heavy-" + i), { heavy: true });
    await assert.rejects(() => f.limits.consume(hash("new-heavy"), { heavy: true }), limited("RATE_LIMITED"));
    for (let i = 301; i < 2000; i++) await f.limits.consume(hash("request-" + i));
    await assert.rejects(() => f.limits.consume(hash("new-request")), limited("RATE_LIMITED"));
    f.advance(86400000); await f.limits.consume(hash("new-request"), { heavy: true });
  } finally { f.close(); }
});

test("a storage reopen does not reset durable request budgets", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-rate-")), path = join(directory, "state.sqlite");
  let f = setup({ path });
  try {
    for (let i = 0; i < 12; i++) await f.limits.consume(hash("shared"), { heavy: true });
    f.close(); f = setup({ path });
    await assert.rejects(() => f.limits.consume(hash("shared"), { heavy: true }), limited("RATE_LIMITED"));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("limits fail closed on invalid context and failed durability and cleanup removes only a bounded batch", async () => {
  let fail = false; const f = setup({ syncHook: async () => { if (fail) throw new Error("PRIVATE-STORAGE"); } });
  try {
    await assert.rejects(() => f.limits.consume("client-picked"), limited("LIMIT_UNAVAILABLE"));
    fail = true; await assert.rejects(() => f.limits.consume(hash("valid")), limited("LIMIT_UNAVAILABLE")); fail = false;
    for (let i = 0; i < 150; i++) f.db.prepare("INSERT INTO gateway_windows_v1(kind,key_hash,window_start,count) VALUES ('network',?,?,1)")
      .run(hash(String(i)), start - 120000);
    await f.limits.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM gateway_windows_v1 WHERE window_start<?").get(start).count, 50);
  } finally { f.close(); }
});

test("maintenance scheduling preserves an earlier alarm and restores a missing or too-late one", async () => {
  const f = setup();
  try {
    await f.maintenance.schedule(); assert.equal(f.alarm(), start + 60000); assert.equal(f.alarmWrites(), 1);
    await f.maintenance.schedule(); assert.equal(f.alarmWrites(), 1);
    await f.storage.setAlarm(start + 1000); await f.maintenance.schedule(); assert.equal(f.alarm(), start + 1000);
    await f.storage.setAlarm(start + 120000); await f.maintenance.schedule(); assert.equal(f.alarm(), start + 60000);
  } finally { f.close(); }
});

test("the next alarm is durable before any cleanup failure and provider work is not started", async () => {
  const f = setup(); let calls = 0;
  try {
    const maintenance = new GatewayMaintenance(f.storage, { clock: f.clock, deletions: f.deletions,
      limits: { async purgeExpired() { throw new Error("PRIVATE-CLEANUP-ERROR"); } } });
    await assert.rejects(() => maintenance.alarm({ processor: { async step() { calls++; } } }));
    assert.equal(f.alarm(), start + 60000); assert.equal(calls, 0);
  } finally { f.close(); }
});

test("alarm retention works without signing/encryption keys and processes bounded expired authentication rows", async () => {
  const f = setup();
  try {
    for (let i = 0; i < 150; i++) f.db.prepare(`INSERT INTO auth_challenges_v1
      (challenge_id,nonce_hash,expires_at,state) VALUES (?,?,?,'pending')`).run(randomUUID(), hash("nonce"), start - 1);
    await f.maintenance.alarm();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_challenges_v1").get().count, 50);
    await f.maintenance.alarm();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_challenges_v1").get().count, 0);
    assert.equal(f.alarm(), null);
  } finally { f.close(); }
});

test("fair persisted rotation reaches jobs beyond the first ten even when earlier jobs remain pending", async () => {
  const f = setup(); const visited = [];
  try {
    for (let i = 0; i < 12; i++) f.addJob();
    for (let i = 0; i < 12; i++) await f.maintenance.alarm({ processor: { async step(id) { visited.push(id); } } });
    assert.equal(new Set(visited).size, 12);
    await f.maintenance.alarm({ processor: { async step(id) { visited.push(id); } } });
    assert.equal(visited[12], visited[0]);
  } finally { f.close(); }
});

test("bulk secret expiry cannot be starved behind another pending deletion and makes no Apple call", async () => {
  const f = setup();
  try {
    for (let i = 0; i < 3; i++) {
      const session = await f.session("synthetic." + i), id = randomUUID();
      f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1,generation=generation+1 WHERE account_id=?").run(session.accountID);
      f.db.prepare(`INSERT INTO auth_account_deletions_v1
        (deletion_id,status_hash,account_id,subject_hash,created_at,settle_after) VALUES (?,?,?,?,?,?)`)
        .run(id, hash(id), session.accountID, appleSubjectHash("synthetic." + i), start, start + 60000);
    }
    f.advance(8 * 86400000); await f.maintenance.alarm();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1 WHERE apple_status='manual-required'").get().count, 3);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1 WHERE local_status='removed'").get().count, 0);
  } finally { f.close(); }
});

test("a new object instance resumes its maintenance cursor instead of restarting at the oldest job", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-alarm-")), path = join(directory, "state.sqlite");
  let f = setup({ path }); const visited = [];
  try {
    f.addJob(); f.addJob();
    await f.maintenance.alarm({ processor: { async step(id) { visited.push(id); } } });
    f.close(); f = setup({ path });
    await f.maintenance.alarm({ processor: { async step(id) { visited.push(id); } } });
    assert.notEqual(visited[0], visited[1]);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});
