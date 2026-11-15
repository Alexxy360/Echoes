import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { CloudKitPublicRepository } from "../src/public-record-repository.mjs";
import { PublicRegistryCheckpoint, checkpointRecordName, checkpointRecordType } from "../src/public-registry-checkpoint.mjs";
import { publicFixture, publicCode, profileInput, messageInput } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot, restoreSQLite } from "./support/sqlite-snapshot.mjs";

function reopen(f) {
  const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
  const checkpoint = new PublicRegistryCheckpoint({ registry, client: f.client });
  const repository = new CloudKitPublicRepository({ registry, checkpoint, client: f.client, authentication: f.state, clock: f.clock });
  return { registry, checkpoint, repository };
}

test("a missing remote checkpoint never creates a marker or admits a first content write", async () => {
  const f = await publicFixture({ bootstrap: false });
  try {
    const session = await f.session();
    await assert.rejects(() => f.repository.write(profileInput(session)), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.records.size, 0); assert.equal(f.model.controls.size, 0);
    assert.ok(f.model.checkpointRequests.every(call => call.operation === "lookup"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 0);
  } finally { f.close(); }
});

test("trusted empty bootstrap survives a lost response and cannot overwrite an existing checkpoint", async () => {
  const f = await publicFixture({ bootstrap: false });
  try {
    const initial = await f.registry.prepareBootstrap(); let lose = true;
    f.model.afterCheckpoint = call => { if (lose && call.operation === "modify") { lose = false; throw new Error("PRIVATE bootstrap transport"); } };
    await assert.rejects(() => f.client.createCheckpointForBootstrap(initial), publicCode("PUBLIC_UNAVAILABLE"));
    await f.checkpoint.verify();
    const state = await f.registry.checkpointState(); assert.equal(state.confirmed.value.anchorID, initial.anchorID);
    assert.equal(f.model.checkpointRequests.filter(call => call.operation === "modify").length, 1);
    const collision = await f.client.createCheckpointForBootstrap({ ...initial, anchorID: randomUUID() });
    assert.equal(collision.serverErrorCode, "EXISTS");
    await assert.rejects(() => f.registry.prepareBootstrap(), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.controls.get(checkpointRecordName).fields.anchorID.value, initial.anchorID);
  } finally { f.close(); }
});

test("an unknown checkpoint response is reconciled by its exact durable outbox without a second write", async () => {
  const f = await publicFixture();
  try {
    let lose = true;
    f.model.afterCheckpoint = call => { if (lose && call.operation === "modify") { lose = false; throw new Error("PRIVATE lost response"); } };
    await assert.rejects(() => f.checkpoint.advance(), publicCode("PUBLIC_UNAVAILABLE"));
    const pending = (await f.registry.checkpointState()).pending;
    assert.ok(pending); assert.equal(f.model.controls.get(checkpointRecordName).fields.anchorID.value, pending.value.anchorID);
    const writes = f.model.checkpointRequests.filter(call => call.operation === "modify").length;
    await reopen(f).checkpoint.verify();
    assert.equal((await f.registry.checkpointState()).pending, null);
    assert.equal(f.model.checkpointRequests.filter(call => call.operation === "modify").length, writes);
    await f.checkpoint.advance();
    const confirmed = (await f.registry.checkpointState()).confirmed;
    assert.notEqual(confirmed.value.anchorID, pending.value.anchorID);
    assert.equal(confirmed.value.parentAnchorID, pending.value.anchorID);
  } finally { f.close(); }
});

test("a failed confirmation transaction preserves the outbox and does not poison later checkpoint work", async () => {
  let armed = false;
  const f = await publicFixture({ sqlHook: sql => { if (armed && sql.startsWith("UPDATE public_registry_checkpoint_v1 SET confirmed_value")) throw new Error("PRIVATE SQL failure"); } });
  try {
    armed = true;
    await assert.rejects(() => f.checkpoint.advance(), publicCode("PUBLIC_UNAVAILABLE"));
    const pending = (await f.registry.checkpointState()).pending; assert.ok(pending);
    armed = false; await f.checkpoint.verify();
    assert.equal((await f.registry.checkpointState()).confirmed.value.anchorID, pending.value.anchorID);
    await f.checkpoint.advance();
  } finally { armed = false; f.close(); }
});

test("outbox durability precedes remote replacement and a pending base can be retried explicitly", async () => {
  let armed = false;
  const f = await publicFixture({ syncHook: () => {
    if (armed && f.db.prepare("SELECT pending_value FROM public_registry_checkpoint_v1").get()?.pending_value) throw new Error("PRIVATE sync failure");
  } });
  try {
    const writes = f.model.checkpointRequests.filter(call => call.operation === "modify").length;
    armed = true;
    await assert.rejects(() => f.checkpoint.advance(), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.model.checkpointRequests.filter(call => call.operation === "modify").length, writes);
    armed = false;
    f.model.beforeCheckpoint = call => {
      if (call.operation === "modify") {
        const row = f.db.prepare("SELECT pending_value FROM public_registry_checkpoint_v1").get();
        assert.equal(JSON.parse(row.pending_value).anchorID, call.body.operations[0].record.fields.anchorID.value);
      }
    };
    await f.checkpoint.advance();
  } finally { armed = false; f.close(); }
});

test("a restored registry cannot mask rollback by reaching the same record count on another branch", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(); await f.repository.write(profileInput(session));
    const snapshot = sqliteSnapshot(f.db);
    await f.repository.write(messageInput(session));
    restoreSQLite(f.storage, snapshot);
    const id = randomUUID();
    await f.registry.reserve({ accountID: session.accountID, kind: "message", logicalID: id, requestID: id, payloadHash: "b".repeat(64) });
    assert.equal((await f.registry.checkpointState()).registeredCount, f.model.controls.get(checkpointRecordName).fields.registeredCount.value);
    const before = f.model.requests.length;
    await assert.rejects(() => reopen(f).repository.write(messageInput(session)), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.requests.length, before);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 2);
  } finally { f.close(); }
});

test("rollback cannot return an empty erasure receipt while unregistered CloudKit content remains", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(); await f.repository.write(profileInput(session));
    const snapshot = sqliteSnapshot(f.db, name => name.startsWith("public_"));
    await f.repository.write(messageInput(session));
    const ticket = await f.beginDeletion(session), context = await f.deletions.claimPublicBatch(ticket.deletionID);
    restoreSQLite(f.storage, snapshot);
    const before = f.model.requests.length;
    await assert.rejects(() => reopen(f).repository.erasePublicDataBatch(context), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.requests.length, before);
    assert.equal(f.model.records.size, 2); assert.equal(f.deletions.status(ticket).publicData, "pending");
  } finally { f.close(); }
});

test("a full registry loss creates a different local epoch and never replaces the old remote checkpoint", async () => {
  const f = await publicFixture(), fresh = await publicFixture({ bootstrap: false });
  try {
    const session = await f.session(); await f.repository.write(profileInput(session));
    const checkpoint = new PublicRegistryCheckpoint({ registry: fresh.registry, client: f.client });
    const before = f.model.checkpointRequests.filter(call => call.operation === "modify").length;
    await assert.rejects(() => checkpoint.verify(), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await assert.rejects(() => checkpoint.advance(), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.checkpointRequests.filter(call => call.operation === "modify").length, before);
    assert.equal(f.model.records.size, 1);
  } finally { f.close(); fresh.close(); }
});

test("existing unanchored rows and inconsistent counters require investigation rather than automatic adoption", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(); await f.repository.write(profileInput(session));
    f.db.exec("DROP TABLE public_registry_checkpoint_v1");
    assert.throws(() => reopen(f), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 1);
  } finally { f.close(); }
  const other = await publicFixture();
  try {
    const session = await other.session(); await other.repository.write(profileInput(session));
    other.db.exec("UPDATE public_record_counts_v1 SET value=0 WHERE scope='*'");
    assert.throws(() => reopen(other), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
  } finally { other.close(); }
});

test("an old in-flight checkpoint cannot overwrite a later branch after a SQLite restore", async () => {
  const f = await publicFixture(); let release, reached;
  try {
    const snapshot = sqliteSnapshot(f.db), ready = new Promise(resolve => { reached = resolve; }); let hold = true;
    f.model.beforeCheckpoint = async call => {
      if (hold && call.operation === "modify") { hold = false; reached(); await new Promise(resolve => { release = resolve; }); }
    };
    const old = f.checkpoint.advance(), checked = assert.rejects(() => old, publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await ready; restoreSQLite(f.storage, snapshot);
    await reopen(f).checkpoint.advance();
    const current = (await f.registry.checkpointState()).confirmed;
    release(); await checked;
    assert.deepEqual((await f.registry.checkpointState()).confirmed, current);
    assert.equal(f.model.controls.get(checkpointRecordName).fields.anchorID.value, current.value.anchorID);
    assert.equal(f.model.requests.length, 0);
  } finally { release?.(); f.close(); }
});

test("if the old fork wins remotely, both newer local claims fail closed instead of disguising the fork", async () => {
  const f = await publicFixture(); const releases = []; let firstReached, secondReached;
  try {
    const snapshot = sqliteSnapshot(f.db), first = new Promise(resolve => { firstReached = resolve; }), second = new Promise(resolve => { secondReached = resolve; });
    f.model.beforeCheckpoint = async call => {
      if (call.operation === "modify") {
        const index = releases.length;
        const waiting = new Promise(resolve => { releases.push(resolve); });
        if (index === 0) firstReached(); else secondReached(); await waiting;
      }
    };
    const old = f.checkpoint.advance(), checkedOld = assert.rejects(() => old, publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await first; restoreSQLite(f.storage, snapshot);
    const newer = reopen(f), next = newer.checkpoint.advance(), checkedNext = assert.rejects(() => next, publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    await second; releases[0](); await checkedOld; releases[1](); await checkedNext;
    await assert.rejects(() => newer.checkpoint.verify(), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.model.requests.length, 0);
  } finally { for (const release of releases) release(); f.close(); }
});

test("checkpoint metadata cannot be read or replaced through generic social record methods", async () => {
  const f = await publicFixture();
  try {
    await assert.rejects(() => f.client.lookup([checkpointRecordName]), publicCode("PUBLIC_INPUT"));
    await assert.rejects(() => f.client.modify([{ operationType: "replace", record: { recordName: checkpointRecordName,
      recordType: checkpointRecordType, recordChangeTag: "1", fields: {} } }]), publicCode("PUBLIC_INPUT"));
    await assert.rejects(() => f.client.createCheckpointForBootstrap({ schemaVersion: 1, registryID: randomUUID(), anchorID: randomUUID(), parentAnchorID: randomUUID(), registeredCount: 0 }), publicCode("PUBLIC_INPUT"));
  } finally { f.close(); }
});
