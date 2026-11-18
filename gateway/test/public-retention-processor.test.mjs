import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { CloudKitPublicRetentionProcessor } from "../src/public-retention-processor.mjs";
import { retentionFixture } from "./support/public-retention-fixture.mjs";
import { publicCode, profileInput, messageInput, publicClient } from "./support/public-record-fixture.mjs";

const hour = 3600000;
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function contentFree(record) { assert.deepEqual(Object.keys(record.fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]); }

test("retention processor is disabled by default and malformed internal options cause no provider calls", async () => {
  const f = await retentionFixture();
  try {
    await f.message(); f.advance(2 * hour); const before = f.model.requests.length;
    const disabled = new CloudKitPublicRetentionProcessor({ ...f.configuration, isEnabled: undefined });
    await assert.rejects(() => disabled.step(), publicCode("PUBLIC_UNAVAILABLE")); await tick();
    await assert.rejects(() => f.makeProcessor({ clock() { throw new Error("PRIVATE-CLOCK-ERROR"); } }).step(), publicCode("PUBLIC_UNAVAILABLE"));
    for (const options of [{ maximumRecords: 0 }, { maximumRecords: 26 }, { owner: f.session.accountID }, { signal: {} }]) {
      await assert.rejects(() => f.processor.step(options), publicCode("PUBLIC_INPUT"));
    }
    assert.equal(f.model.requests.length, before);
    assert.equal(f.db.prepare("SELECT state FROM public_retention_v1").get().state, "pending");
  } finally { f.close(); }
});

test("exact expired messages lose all content while persistent profiles remain unchanged", async () => {
  const f = await retentionFixture();
  try {
    const message = await f.message(), profile = await f.repository.write(profileInput(f.session));
    f.advance(2 * hour); assert.deepEqual(await f.step(), { processed: 1 });
    contentFree(f.model.records.get(message.record.recordName));
    assert.deepEqual(f.model.records.get(profile.recordName).fields, profile.fields);
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(message.record.recordName).phase, "erased");
    const reads = f.model.requests.filter(r => r.operation === "lookup");
    assert.deepEqual(reads.at(-1).body.desiredKeys, ["schemaVersion", "ownerKey", "erased", "deletionKey", "retentionKey"]);
    assert.deepEqual(await f.step(), { processed: 0 });
  } finally { f.close(); }
});

test("a missing reserved CREATE receives a durable fence so the original request cannot resurrect content", async () => {
  const f = await retentionFixture();
  try {
    const input = messageInput(f.session);
    const waiting = deferred(), entered = deferred();
    f.model.before = async call => {
      if (call.operation === "modify" && call.body.operations[0].record.fields.erased.value === 0) {
        entered.resolve(); await waiting.promise;
      }
    };
    const original = f.repository.write(input); await entered.promise;
    f.advance(2 * hour); assert.deepEqual(await f.step(), { processed: 1 });
    const name = [...f.model.records.keys()][0]; contentFree(f.model.records.get(name));
    waiting.resolve(); await assert.rejects(() => original);
    contentFree(f.model.records.get(name));
    assert.equal(f.model.records.size, 1);
  } finally { f.close(); }
});

test("a lost modify response stays pending and a later exact inspection confirms the same content-free fence", async () => {
  const f = await retentionFixture();
  try {
    const message = await f.message(); f.advance(2 * hour);
    f.model.after = call => { if (call.operation === "modify") throw new Error("PRIVATE-provider-error"); };
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_UNAVAILABLE")); await tick();
    contentFree(f.model.records.get(message.record.recordName));
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "settled");
    f.model.after = undefined; f.advance(60000);
    assert.deepEqual(await f.step(), { processed: 1 });
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "erased");
  } finally { f.close(); }
});

test("presence needs a confirmed exact fence and fresh intent before it can publish again", async () => {
  const f = await retentionFixture();
  try {
    const presence = await f.presence(); f.advance(600000);
    assert.deepEqual(await f.step(), { processed: 1 }); contentFree(f.model.records.get(presence.record.recordName));
    await f.refreshSession();
    await assert.rejects(() => f.repository.writeLatest({ ...presence.input,
      accessToken: f.presenceInput().accessToken, input: { ...presence.input.input, measuredAt: f.clock() } }), publicCode("PUBLIC_ERASED"));
    const fresh = await f.repository.writeLatest(f.presenceInput());
    assert.equal(fresh.recordName, presence.record.recordName); assert.equal(fresh.fields.erased.value, 0);
    assert.equal(f.registry.readable(fresh.recordName, "presence").requestID, f.registry.owned(f.session.accountID, "presence", "singleton").requestID);
  } finally { f.close(); }
});

test("an unconfirmed or modified presence fence never permits fresh publication", async () => {
  const f = await retentionFixture();
  try {
    const presence = await f.presence(); f.advance(600000);
    f.model.after = call => { if (call.operation === "modify") throw new Error("PRIVATE-lost-fence"); };
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_UNAVAILABLE")); await tick(); f.model.after = undefined;
    await f.refreshSession();
    await assert.rejects(() => f.repository.writeLatest(f.presenceInput()), publicCode("PUBLIC_ERASED"));
    f.advance(60000); await f.step();
    f.model.records.get(presence.record.recordName).recordChangeTag = "unexpected-foreign-tag";
    await assert.rejects(() => f.repository.writeLatest(f.presenceInput()), publicCode("PUBLIC_ERASED"));
  } finally { f.close(); }
});

test("account erasure accepts its own exact retention fence and removes pending local expiry work", async () => {
  const f = await retentionFixture();
  try {
    const presence = await f.presence(); f.advance(600000);
    f.model.after = call => { if (call.operation === "modify") throw new Error("PRIVATE-lost-fence"); };
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_UNAVAILABLE")); await tick(); f.model.after = undefined;
    const ticket = await f.beginDeletion(f.session); f.advance(60001);
    const result = await f.erase(ticket); assert.equal(result.remaining, false);
    const stored = f.model.records.get(presence.record.recordName);
    assert.deepEqual(Object.keys(stored.fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    assert.equal(f.db.prepare("SELECT count(*) n FROM public_retention_v1").get().n, 0);
  } finally { f.close(); }
});

test("account deletion during metadata or mutation IO prevents a false expiry receipt", async () => {
  for (const operation of ["lookup", "modify"]) {
    const f = await retentionFixture();
    try {
      await f.message(); f.advance(2 * hour); let ticket;
      f.model.after = async call => { if (call.operation === operation) ticket = await f.beginDeletion(f.session); };
      const before = f.model.requests.filter(c => c.operation === "modify").length;
      await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_SCOPE")); await tick();
      assert.ok(ticket); assert.equal(f.model.requests.filter(c => c.operation === "modify").length, before + (operation === "modify" ? 1 : 0));
      assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "settled");
      f.model.after = undefined; f.advance(60001); assert.equal((await f.erase(ticket)).remaining, false);
    } finally { f.close(); }
  }
});

test("foreign owner/type, extra metadata and mismatched fences stop before modifying CloudKit", async () => {
  for (const mutate of [
    r => { r.fields.ownerKey.value = "b".repeat(64); },
    r => { r.recordType = "EchoesPublicProfileV1"; },
    r => { r.fields.unexpected = { value: "PRIVATE-content", type: "STRING" }; },
    r => { r.fields.erased.value = 1; r.fields.retentionKey = { value: "b".repeat(64) }; },
  ]) {
    const f = await retentionFixture();
    try {
      await f.message(); f.advance(2 * hour); const before = f.model.requests.filter(c => c.operation === "modify").length;
      f.model.after = async call => { if (call.operation === "lookup") { const data = await call.response.json(); mutate(data.records[0]); return Response.json(data); } };
      await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_SCOPE")); await tick();
      assert.equal(f.model.requests.filter(c => c.operation === "modify").length, before);
    } finally { f.close(); }
  }
});

test("malformed full modification replies cannot prove erasure even if the provider committed a fence", async () => {
  const f = await retentionFixture();
  try {
    const message = await f.message(); f.advance(2 * hour);
    f.model.after = async call => {
      if (call.operation === "modify") { const data = await call.response.json(); data.records[0].fields.text = { value: "PRIVATE-leftover", type: "STRING" }; return Response.json(data); }
    };
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_RESPONSE")); await tick();
    contentFree(f.model.records.get(message.record.recordName));
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "settled");
  } finally { f.close(); }
});

test("one conflict is not blindly retried while other verified records can finish", async () => {
  const f = await retentionFixture();
  try {
    const first = await f.message(), second = await f.message(); f.advance(2 * hour);
    f.model.before = call => {
      if (call.operation === "modify") f.model.records.get(first.record.recordName).recordChangeTag = "concurrent-tag";
    };
    const before = f.model.requests.filter(c => c.operation === "modify").length;
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_CONFLICT")); await tick();
    assert.equal(f.model.requests.filter(c => c.operation === "modify").length, before + 1);
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(first.record.recordName).phase, "settled");
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1 WHERE record_name=?").get(second.record.recordName).phase, "erased");
  } finally { f.close(); }
});

test("disabling or rolling back time during checkpoint validation prevents every subsequent provider operation", async () => {
  for (const action of [f => f.disable(), f => f.advance(-1), f => f.advance(8000)]) {
    const f = await retentionFixture();
    try {
      await f.message(); f.advance(2 * hour);
      f.model.afterCheckpoint = call => { if (call.operation === "lookup") action(f); };
      const before = f.model.requests.length;
      await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_UNAVAILABLE")); await tick();
      assert.equal(f.model.requests.length, before);
    } finally { f.close(); }
  }
});

test("checkpoint rollback refuses retention before claiming or changing user records", async () => {
  const f = await retentionFixture();
  try {
    await f.message(); f.advance(2 * hour);
    for (const record of f.model.controls.values()) record.recordChangeTag = "rolled-back-checkpoint";
    const before = f.model.requests.length;
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_REGISTRY_UNVERIFIED")); await tick();
    assert.equal(f.model.requests.length, before);
    assert.equal(f.db.prepare("SELECT state FROM public_retention_v1").get().state, "pending");
  } finally { f.close(); }
});

test("timeout retains one slot until the actual ignored provider fetch and body work finishes", async () => {
  const f = await retentionFixture(); const entered = deferred(), release = deferred();
  try {
    await f.message(); f.advance(2 * hour);
    f.model.before = async call => { if (call.operation === "lookup") { entered.resolve(); await release.promise; } };
    const processor = f.makeProcessor({ timeoutMilliseconds: 30 });
    const operation = processor.step(); await entered.promise;
    await assert.rejects(() => operation, publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(processor.isOccupied, true);
    await assert.rejects(() => processor.step(), publicCode("PUBLIC_LIMIT"));
    release.resolve(); await f.client.waitForPendingOperations(); await tick();
    assert.equal(processor.isOccupied, false);
  } finally { release.resolve(); await f.client.waitForPendingOperations(); f.close(); }
});

test("an aborted checkpoint fetch keeps the retention slot until its real underlying operation settles", async () => {
  const f = await retentionFixture(); const entered = deferred(), release = deferred(), controller = new AbortController();
  try {
    await f.message(); f.advance(2 * hour);
    f.model.beforeCheckpoint = async call => { if (call.operation === "lookup") { entered.resolve(); await release.promise; } };
    const operation = f.processor.step({ signal: controller.signal }); await entered.promise; controller.abort();
    await assert.rejects(() => operation, publicCode("PUBLIC_UNAVAILABLE")); await tick();
    assert.equal(f.processor.isOccupied, true);
    await assert.rejects(() => f.processor.step(), publicCode("PUBLIC_LIMIT"));
    release.resolve(); await f.checkpoint.waitForPendingOperations(); await tick();
    assert.equal(f.processor.isOccupied, false);
    assert.equal(f.db.prepare("SELECT state FROM public_retention_v1").get().state, "pending");
  } finally { release.resolve(); await f.client.waitForPendingOperations(); f.close(); }
});

test("private report reason expires after thirty days without a live user session", async () => {
  const f = await retentionFixture();
  try {
    const message = await f.message(), id = randomUUID();
    const report = await f.repository.write({ accessToken: f.session.sessionToken, kind: "report", logicalID: id, requestID: id,
      input: { messageID: message.record.recordName, reason: "SYNTHETIC-PRIVATE-REPORT-REASON" } });
    f.advance(30 * 86400000);
    assert.deepEqual(await f.step(), { processed: 2 });
    contentFree(f.model.records.get(report.recordName)); contentFree(f.model.records.get(message.record.recordName));
    assert.equal(f.db.prepare("SELECT count(*) n FROM public_records_v1 WHERE phase='erased'").get().n, 2);
  } finally { f.close(); }
});

test("aborted body cancellation retains the slot until the original cancel promise actually settles", async () => {
  const f = await retentionFixture(), entered = deferred(), release = deferred(), controller = new AbortController();
  let cancelled = false;
  const client = publicClient(async () => new Response(new ReadableStream({
    pull() { entered.resolve(); return release.promise; },
    cancel() { cancelled = true; return release.promise; },
  }), { headers: { "Content-Type": "application/json" } }), { clock: f.clock });
  try {
    await f.message(); f.advance(2 * hour);
    const processor = f.makeProcessor({ client });
    const operation = processor.step({ signal: controller.signal }); await entered.promise; controller.abort();
    await assert.rejects(() => operation, publicCode("PUBLIC_UNAVAILABLE")); await tick();
    assert.equal(cancelled, true); assert.equal(processor.isOccupied, true);
    await assert.rejects(() => processor.step(), publicCode("PUBLIC_LIMIT"));
    release.resolve(); await client.waitForPendingOperations(); await tick();
    assert.equal(processor.isOccupied, false);
  } finally { release.resolve(); await client.waitForPendingOperations(); f.close(); }
});

test("null removed fields in a CloudKit replace response are accepted but contain no retained value", async () => {
  const f = await retentionFixture();
  try {
    await f.message(); f.advance(2 * hour);
    f.model.after = async call => {
      if (call.operation === "modify") {
        const data = await call.response.json();
        for (const key of ["text", "latitude", "longitude", "location"]) data.records[0].fields[key] = { value: null };
        return Response.json(data);
      }
    };
    assert.deepEqual(await f.step(), { processed: 1 });
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "erased");
  } finally { f.close(); }
});

test("public JSON transport bounds pathological fragment counts and rejects non-byte chunks", async () => {
  for (const mode of ["empty", "non-byte"]) {
    const f = await retentionFixture(); let pulls = 0, cancelled = false;
    const client = publicClient(async () => new Response(new ReadableStream({
      pull(controller) {
        if (++pulls >= 5000) { controller.close(); return; }
        controller.enqueue(mode === "empty" ? new Uint8Array() : "not-byte-data");
      },
      cancel() { cancelled = true; },
    }), { headers: { "Content-Type": "application/json" } }), { clock: f.clock });
    try {
      await f.message(); f.advance(2 * hour);
      await assert.rejects(() => f.makeProcessor({ client }).step(), publicCode("PUBLIC_RESPONSE"));
      await client.waitForPendingOperations(); await tick();
      assert.equal(cancelled, true); assert.ok(pulls < 4500);
      assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "settled");
    } finally { await client.waitForPendingOperations(); f.close(); }
  }
});
