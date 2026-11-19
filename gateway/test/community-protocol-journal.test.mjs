import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { spawn } from "node:child_process";
import { chmod, lstat, rename, symlink, unlink } from "node:fs/promises";
import { join } from "node:path";
import { CommunityProtocolJournal } from "../scripts/community-protocol-journal.mjs";
import { protocolFixture } from "./support/community-protocol-fixture.mjs";

const code = value => error => error?.code === value;

test("journal persists the reviewed inventory privately and refuses a different plan hash", async t => {
  const f = await protocolFixture(t), directory = f.journal.directory;
  assert.equal((await lstat(directory)).mode & 0o077, 0);
  for (const name of ["journal.sqlite", "lease.sqlite"]) assert.equal((await lstat(join(directory, name))).mode & 0o077, 0);
  f.journal.write({ phase: "synthetic storage check", synthetic: true });
  await f.reopen();
  assert.deepEqual(f.journal.snapshot().plan, f.prepared.plan); assert.equal(f.journal.snapshot().state.synthetic, true);
  f.journal.close();
  await assert.rejects(CommunityProtocolJournal.open(directory, "0".repeat(64)), code("JOURNAL_SCOPE"));
});

test("independent connections cannot run concurrently and the lease releases after close", async t => {
  const f = await protocolFixture(t);
  await assert.rejects(CommunityProtocolJournal.open(f.journal.directory, f.prepared.sha256));
  await f.reopen(); assert.equal(f.journal.snapshot().state, null);
});

test("SQL transaction abort leaves the prior durable state and revision intact", async t => {
  const f = await protocolFixture(t); f.journal.write({ phase: "before", synthetic: true });
  const previous = f.journal.snapshot(), db = new DatabaseSync(join(f.journal.directory, "journal.sqlite"));
  db.exec("CREATE TRIGGER synthetic_abort BEFORE UPDATE ON snapshot BEGIN SELECT RAISE(ABORT,'synthetic abort'); END"); db.close();
  assert.throws(() => f.journal.write({ phase: "after", synthetic: true }), code("JOURNAL_FAILED"));
  assert.deepEqual(f.journal.snapshot(), previous); await f.reopen(); assert.deepEqual(f.journal.snapshot(), previous);
});

test("corrupted state, unsafe file permissions and symlink replacement are refused", async t => {
  const f = await protocolFixture(t), directory = f.journal.directory;
  f.journal.close(); await chmod(join(directory, "journal.sqlite"), 0o644);
  await assert.rejects(CommunityProtocolJournal.open(directory, f.prepared.sha256), code("JOURNAL_SCOPE"));
  await chmod(join(directory, "journal.sqlite"), 0o600);
  await rename(join(directory, "lease.sqlite"), join(directory, "original-lease.sqlite"));
  await symlink(join(directory, "original-lease.sqlite"), join(directory, "lease.sqlite"));
  await assert.rejects(CommunityProtocolJournal.open(directory, f.prepared.sha256), code("JOURNAL_SCOPE"));
  await unlink(join(directory, "lease.sqlite")); await rename(join(directory, "original-lease.sqlite"), join(directory, "lease.sqlite"));
  f.journal = await CommunityProtocolJournal.open(directory, f.prepared.sha256);
  const db = new DatabaseSync(join(directory, "journal.sqlite")); db.exec("UPDATE snapshot SET state='{}'"); db.close();
  assert.throws(() => f.journal.snapshot(), code("JOURNAL_SCOPE"));
});

test("SIGKILL releases only the process lease; the durable create intent survives and recovery never repeats create", async t => {
  const f = await protocolFixture(t), directory = f.journal.directory; f.journal.close();
  const journalURL = new URL("../scripts/community-protocol-journal.mjs", import.meta.url).href;
  const runnerURL = new URL("../scripts/community-protocol-runner.mjs", import.meta.url).href;
  const source = `import {CommunityProtocolJournal} from ${JSON.stringify(journalURL)};
    import {runCommunityProtocol} from ${JSON.stringify(runnerURL)}; import {randomUUID} from 'node:crypto';
    const journal=await CommunityProtocolJournal.open(process.argv[1],process.argv[2]);
    const at=journal.snapshot().plan.seed.startedAt; process.stdin.resume();
    await runCommunityProtocol({journal,window:{id:randomUUID(),issuedAt:at,expiresAt:at+60000,mode:'full'},
      isAuthorized:()=>true,clock:()=>at,monotonic:()=>0,transport:{
        async request(operation,payload){if(operation==='records/lookup')return{records:payload.records.map(row=>({...row,serverErrorCode:'NOT_FOUND'}))};
          process.stdout.write('CREATE_PENDING\\n');await new Promise(()=>{});},async waitForPendingOperations(){}}});`;
  const child = spawn(process.execPath, ["--input-type=module", "-e", source, directory, f.prepared.sha256], { stdio: ["pipe", "pipe", "pipe"] });
  const exited = new Promise(resolve => child.once("exit", (exitCode, signal) => resolve({ exitCode, signal })));
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); await exited; });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Synthetic child did not reach durable intent.")), 10000); let text = "";
    child.stdout.on("data", bytes => { text += bytes.toString(); if (text.includes("CREATE_PENDING")) { clearTimeout(timer); resolve(); } });
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("exit", () => { clearTimeout(timer); if (!text.includes("CREATE_PENDING")) reject(new Error("Synthetic child exited before intent.")); });
  });
  await assert.rejects(CommunityProtocolJournal.open(directory, f.prepared.sha256));
  child.kill("SIGKILL"); assert.equal((await exited).signal, "SIGKILL");
  f.journal = await CommunityProtocolJournal.open(directory, f.prepared.sha256);
  const state = f.journal.snapshot().state;
  assert.equal(state.phase, "create_pending"); assert.equal(state.createAttempted, true); assert.equal(state.callsTotal, 2);
  const recovered = await f.run({ window: f.window("cleanup") });
  assert.equal(recovered.cleanupSucceeded, false); assert.equal(recovered.pendingRecordNames.length, 8);
  assert.equal(f.model.calls.every(call => call.operation === "records/lookup"), true);
});
