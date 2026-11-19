import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm, writeFile, readFile, readdir, stat, chmod, symlink, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { generateKeyPairSync, randomUUID, verify, createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { digest } from "../src/public-record-schema.mjs";
import { communityProtocolCommand, retiredDiagnosticKey } from "../scripts/community-protocol-cli.mjs";
import { CommunityProtocolJournal } from "../scripts/community-protocol-journal.mjs";
import { readProtocolPrivateFile, publishProtocolPrivateJSON } from "../scripts/community-protocol-files.mjs";
import { CommunityProtocolModel } from "./support/community-protocol-fixture.mjs";

const code = expected => error => error?.code === expected;
const exec = promisify(execFile);
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "echoes-protocol-cli-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const prepared = await communityProtocolCommand(["prepare", root]);
  const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const keyPath = join(root, "synthetic-unregistered-key.pem"), permitPath = join(root, "permit.json");
  await writeFile(keyPath, pair.privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600 });
  let now = Date.now(); const model = new CommunityProtocolModel(), env = { ECHOES_ALLOW_COMMUNITY_PROTOCOL_DEV: "1" };
  const f = { root, prepared, pair, keyPath, permitPath, model, env, signedCalls: 0,
    permit: { schemaVersion: 1, purpose: "echoes-community-protocol-development-v1", scope: prepared.scope, planSHA256: prepared.planSHA256,
      window: { id: randomUUID(), issuedAt: now, expiresAt: now + 60000, mode: "full" }, keyID: "synthetic-new-key", retiredKeyID: retiredDiagnosticKey.keyID,
      publicKeySHA256: digest(pair.publicKey.export({ type: "spki", format: "der" })), retiredPublicKeySHA256: retiredDiagnosticKey.publicKeySHA256, identityModel: "individual-owner-administrator-v1" },
    options: { env, clock: () => now, async fetchImplementation(request, options) {
      f.signedCalls++; const body = await request.text(), path = new URL(request.url).pathname;
      const stamp = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date"), hash = createHash("sha256").update(body).digest("base64");
      assert.equal(verify("sha256", Buffer.from(`${stamp}:${hash}:${path}`), pair.publicKey,
        Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64")), true);
      return Response.json(await model.request(path.split("/").slice(-2).join("/"), JSON.parse(body), options));
    } },
    advance(ms) { now += ms; },
    async save() { await writeFile(permitPath, JSON.stringify(f.permit), { mode: 0o600 }); },
    args(command = "run") { return [command, prepared.directory, prepared.planSHA256, permitPath, keyPath]; },
    async run(command = "run") { return communityProtocolCommand(f.args(command), f.options); },
    async receipt() { return JSON.parse(await readFile(join(prepared.directory, "report-" + f.permit.window.id + ".json"), "utf8")); },
  };
  await f.save(); return f;
}

test("prepare and inspect need no credentials or activation, persist a private inventory and leave no network path", async t => {
  const f = await fixture(t), directory = f.prepared.directory;
  assert.equal(f.prepared.windowActivated, false); assert.equal(f.prepared.networkRequests, 0); assert.equal(f.prepared.records.length, 8);
  for (const name of await readdir(directory)) assert.equal((await stat(join(directory, name))).mode & 0o077, 0);
  assert.equal((await stat(directory)).mode & 0o077, 0);
  const result = await communityProtocolCommand(["inspect", directory, f.prepared.planSHA256], { env: {} });
  assert.equal(result.state, null); assert.equal(result.networkRequests, 0); assert.equal(f.signedCalls, 0);
});

test("disabled run refuses before opening even a missing journal, permit or key", async () => {
  await assert.rejects(communityProtocolCommand(["run", "/missing/private", "a".repeat(64), "/missing/permit", "/missing/key"], { env: {} }), code("CLI_DISABLED"));
});

test("strict permit refuses scope, hash, time, mode, unknown fields and reuse of retired credentials before reading a missing key", async t => {
  const f = await fixture(t), good = structuredClone(f.permit); await unlink(f.keyPath);
  for (const mutate of [p => p.scope.environment = "production", p => p.scope.database = "private", p => p.planSHA256 = "b".repeat(64),
    p => p.window.issuedAt += 60001, p => p.window.expiresAt = p.window.issuedAt, p => p.window.expiresAt += 1800000,
    p => p.window.mode = "cleanup", p => p.extra = true, p => p.publicKeySHA256 = p.retiredPublicKeySHA256, p => p.keyID = p.retiredKeyID,
    p => p.retiredKeyID = "incorrect-old-key", p => p.retiredPublicKeySHA256 = "a".repeat(64)]) {
    f.permit = structuredClone(good); mutate(f.permit); await f.save(); await assert.rejects(f.run(), code("CLI_PERMIT"));
  }
  assert.equal(f.signedCalls, 0);
});

test("private files reject symlinks, public permissions, excessive bytes, wrong fingerprints and altered inventories without IO", async t => {
  const f = await fixture(t);
  await chmod(f.permitPath, 0o644); await assert.rejects(f.run(), code("CLI_PRIVATE_FILE")); await chmod(f.permitPath, 0o600);
  const alias = join(f.root, "alias"); await symlink(f.permitPath, alias);
  assert.throws(() => readProtocolPrivateFile(alias, 8192), code("CLI_PRIVATE_FILE"));
  await writeFile(f.permitPath, " ".repeat(8193)); await assert.rejects(f.run(), code("CLI_PRIVATE_FILE")); await f.save();
  const replacement = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  await writeFile(f.keyPath, replacement.privateKey.export({ type: "pkcs8", format: "pem" })); await assert.rejects(f.run(), code("CLI_KEY"));
  const inventoryPath = join(f.prepared.directory, "inventory.json"), original = await readFile(inventoryPath, "utf8"), changed = JSON.parse(original);
  changed.plan.records[0].recordName = "unreviewed"; await writeFile(inventoryPath, JSON.stringify(changed));
  await assert.rejects(f.run(), code("CLI_INVENTORY")); assert.equal(f.signedCalls, 0);
});

test("a full signed synthetic protocol leaves a durable receipt, no records, and cannot be rerun", async t => {
  const f = await fixture(t), result = await f.run();
  assert.equal(result.exitCode, 0); assert.equal(result.status, "protocol_verified"); assert.equal(f.signedCalls, 9); assert.equal(f.model.records.size, 0);
  assert.deepEqual(await f.receipt(), JSON.parse(JSON.stringify(result)));
  const serialized = JSON.stringify(result); assert.equal(serialized.includes("PRIVATE KEY"), false); assert.equal(serialized.includes(f.keyPath), false);
  await assert.rejects(f.run(), code("CLI_RECOVERY"));
  const inspection = await communityProtocolCommand(["inspect", f.prepared.directory, f.prepared.planSHA256]);
  assert.equal(inspection.state.cleanupComplete, true); assert.equal(inspection.state.callsTotal, 9);
});

test("revoked permit stops further IO and cleanup requires a fresh window without a second create", async t => {
  const f = await fixture(t); let revoked = false;
  f.model.after = async (call, body) => {
    if (!revoked && call.payload.operations?.[0].operationType === "create") { revoked = true; await unlink(f.permitPath); }
    return body;
  };
  const initial = await f.run(); assert.equal(initial.exitCode, 3); assert.equal(initial.pendingRecordNames.length, 8); assert.equal(f.signedCalls, 2);
  f.model.after = undefined;
  await f.save(); await assert.rejects(f.run("cleanup"), code("CLI_PERMIT"));
  f.permit.window.mode = "cleanup"; await f.save(); await assert.rejects(f.run("cleanup"), code("CLI_RECOVERY"));
  f.permit.window.id = randomUUID(); await f.save(); const cleanup = await f.run("cleanup");
  assert.equal(cleanup.status, "cleanup_verified"); assert.equal(cleanup.protocolSucceeded, false); assert.equal(f.model.records.size, 0);
  assert.equal(f.model.calls.filter(call => call.payload.operations?.[0].operationType === "create").length, 1);
  assert.equal(cleanup.windowCalls, 3);
});

test("expired window after create leaves pending records and cannot authorize automatic cleanup", async t => {
  const f = await fixture(t);
  f.model.after = (call, body) => { if (call.payload.operations?.[0].operationType === "create") f.advance(60001); return body; };
  const result = await f.run(); assert.equal(result.exitCode, 3); assert.equal(result.pendingRecordNames.length, 8); assert.equal(f.signedCalls, 2);
  await assert.rejects(f.run(), code("CLI_PERMIT"));
});

test("atomic private publication never overwrites an existing report or accepts a public directory", async t => {
  const root = await mkdtemp(join(tmpdir(), "echoes-protocol-files-")); t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, "report.json"); await publishProtocolPrivateJSON(path, { status: "first" });
  await assert.rejects(publishProtocolPrivateJSON(path, { status: "overwrite" }), code("CLI_FILE_WRITE"));
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), { status: "first" });
  assert.deepEqual(await readdir(root), ["report.json"]);
  await chmod(root, 0o755); await assert.rejects(publishProtocolPrivateJSON(join(root, "new.json"), {}), code("CLI_FILE_WRITE"));
});

test("a preexisting attempt reservation prevents IO even when the durable run state is still new", async t => {
  const f = await fixture(t), reservation = join(f.prepared.directory, "attempt-" + f.permit.window.id + ".json");
  await publishProtocolPrivateJSON(reservation, { reserved: true }); await assert.rejects(f.run(), code("CLI_FILE_WRITE")); assert.equal(f.signedCalls, 0);
  const journal = await CommunityProtocolJournal.open(f.prepared.directory, f.prepared.planSHA256); assert.equal(journal.snapshot().state, null); journal.close();
});

test("an existing receipt refuses IO and an injected publication failure after IO never becomes a successful result", async t => {
  const f = await fixture(t), path = join(f.prepared.directory, "report-" + f.permit.window.id + ".json");
  await publishProtocolPrivateJSON(path, { operatorArtifact: true });
  await assert.rejects(f.run(), code("CLI_FILE_WRITE")); assert.equal(f.signedCalls, 0); await unlink(path);
  f.model.after = async (call, body) => {
    if (call.payload.operations?.[0].operationType === "delete") await publishProtocolPrivateJSON(path, { concurrentArtifact: true });
    return body;
  };
  await assert.rejects(f.run(), error => error.code === "CLI_FILE_WRITE" && error.protocolMayHaveStarted === true);
  assert.deepEqual(JSON.parse(await readFile(path, "utf8")), { concurrentArtifact: true }); assert.equal(f.model.records.size, 0);
  const journal = await CommunityProtocolJournal.open(f.prepared.directory, f.prepared.planSHA256);
  assert.equal(journal.snapshot().state.cleanupComplete, true); journal.close();
});

test("the real CLI prints only a fixed refusal code for disabled or malformed private configuration", async t => {
  const f = await fixture(t), script = fileURLToPath(new URL("../scripts/community-protocol-cli.mjs", import.meta.url));
  for (const active of [false, true]) {
    if (active) await writeFile(f.permitPath, '{"PRIVATE-MATERIAL"');
    try { await exec(process.execPath, [script, ...f.args()], { env: { ...process.env, ECHOES_ALLOW_COMMUNITY_PROTOCOL_DEV: active ? "1" : "0" } }); assert.fail("refusal required"); }
    catch (error) {
      assert.equal(error.code, 2); assert.equal(error.stdout, "");
      assert.equal(error.stderr.includes("PRIVATE-MATERIAL"), false); assert.equal(error.stderr.includes(f.permitPath), false);
      assert.match(error.stderr, new RegExp('"errorCode":"' + (active ? "CLI_CONFIGURATION" : "CLI_DISABLED") + '"'));
    }
  }
});

test("the real CLI terminates only its own hung synthetic IO after expiry plus grace and preserves an unknown intent", async t => {
  const f = await fixture(t), script = fileURLToPath(new URL("../scripts/community-protocol-cli.mjs", import.meta.url));
  const preload = join(f.root, "synthetic-fetch-preload.mjs"), called = join(f.root, "synthetic-request.marker");
  // This unregistered test key and preload never contact Apple. Only the child gets the substituted fetch.
  await writeFile(preload, 'import { writeFileSync } from "node:fs";\nglobalThis.fetch = async () => { writeFileSync(' + JSON.stringify(called) + ', "synthetic", {mode:0o600}); setInterval(() => {}, 100); return new Promise(() => {}); };\n', { mode: 0o600 });
  const started = Date.now(); f.permit.window.issuedAt = started; f.permit.window.expiresAt = started + 2000; await f.save();
  try {
    await exec(process.execPath, ["--import", preload, script, ...f.args()], { env: { ...process.env, ECHOES_ALLOW_COMMUNITY_PROTOCOL_DEV: "1" }, timeout: 16000 });
    assert.fail("watchdog required");
  } catch (error) {
    assert.equal(error.code, 3); assert.equal(error.killed, false); assert.equal(error.stdout, ""); assert.match(error.stderr, /CLI_DRAIN_DEADLINE/);
  }
  assert.equal(await readFile(called, "utf8"), "synthetic"); assert.ok(Date.now() - started < 15000);
  const journal = await CommunityProtocolJournal.open(f.prepared.directory, f.prepared.planSHA256), state = journal.snapshot().state;
  assert.equal(state.phase, "preflight_pending"); assert.equal(state.callsTotal, 1); assert.equal(state.cleanupComplete, false); journal.close();
});
