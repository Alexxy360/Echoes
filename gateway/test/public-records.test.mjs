import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { CloudKitPublicRepository } from "../src/public-record-repository.mjs";
import { normalizePublicInput, fieldValues, recordIdentity, ownerKey } from "../src/public-record-schema.mjs";
import { publicFixture, publicClient, publicCode, profileInput, messageInput } from "./support/public-record-fixture.mjs";

test("durable registry limits bound each owner and the whole controlled target without provider requests", async () => {
  const f = publicFixture();
  try {
    const owners = [];
    for (let user = 0; user < 10; user++) {
      const session = await f.session("quota.user." + user); owners.push(session.accountID);
      for (let record = 0; record < 1000; record++) {
        const id = randomUUID();
        await f.registry.reserve({ accountID: session.accountID, kind: "message", logicalID: id, requestID: id, payloadHash: "a".repeat(64) });
      }
      const id = randomUUID();
      await assert.rejects(() => f.registry.reserve({ accountID: session.accountID, kind: "message", logicalID: id,
        requestID: id, payloadHash: "b".repeat(64) }), publicCode("PUBLIC_LIMIT"));
    }
    const extra = await f.session("quota.extra"), id = randomUUID();
    await assert.rejects(() => f.registry.reserve({ accountID: extra.accountID, kind: "message", logicalID: id,
      requestID: id, payloadHash: "c".repeat(64) }), publicCode("PUBLIC_LIMIT"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 10000);
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 10000);
    const reopened = new PublicRecordRegistry(f.storage, { clock: f.clock });
    await assert.rejects(() => reopened.reserve({ accountID: owners[0], kind: "message", logicalID: id,
      requestID: id, payloadHash: "c".repeat(64) }), publicCode("PUBLIC_LIMIT"));
    assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("an insert failure rolls back both registry counters and the record reservation", async () => {
  let armed = false;
  const f = publicFixture({ sqlHook: sql => { if (armed && sql.startsWith("INSERT INTO public_records_v1")) throw new Error("PRIVATE SQL path"); } });
  try {
    const session = await f.session(), input = profileInput(session); armed = true;
    await assert.rejects(() => f.repository.write(input), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 0);
    assert.equal(f.model.requests.length, 0); armed = false;
    await f.repository.write(input);
    assert.equal(f.db.prepare("SELECT value FROM public_record_counts_v1 WHERE scope='*'").get().value, 1);
  } finally { f.close(); }
});

test("signed public writes derive the owner from access, reserve first and keep text/GPS out of SQLite", async () => {
  const f = publicFixture();
  try {
    const session = await f.session();
    f.model.before = () => {
      const row = f.db.prepare("SELECT * FROM public_records_v1").get(); assert.equal(row.phase, "pending");
      assert.equal(row.account_id, session.accountID);
    };
    const saved = await f.repository.write(messageInput(session, "PRIVATE-SYNTHETIC-CONTENT"));
    assert.equal(saved.fields.latitude.value, 51.112); assert.equal(saved.fields.longitude.value, 17.035);
    assert.equal(saved.fields.accountID.value, session.accountID); assert.equal(saved.fields.ownerKey.value, ownerKey(session.accountID));
    const row = f.db.prepare("SELECT * FROM public_records_v1").get();
    assert.equal(row.phase, "settled"); assert.equal(JSON.stringify(row).includes("PRIVATE-SYNTHETIC-CONTENT"), false);
    assert.equal(JSON.stringify(row).includes("51.112"), false);
  } finally { f.close(); }
});

test("create and conditional replace preserve versions, idempotency and conflict with a stale editor", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(), initial = profileInput(session), first = await f.repository.write(initial);
    assert.deepEqual(await f.repository.write(initial), first); assert.equal(f.model.requests.length, 1);
    const update = { ...profileInput(session, "Nowa nazwa"), expectedTag: first.recordChangeTag };
    const second = await f.repository.write(update); assert.notEqual(second.recordChangeTag, first.recordChangeTag);
    await assert.rejects(() => f.repository.write({ ...profileInput(session), expectedTag: first.recordChangeTag }), publicCode("PUBLIC_CONFLICT"));
    await assert.rejects(() => f.repository.write(initial), publicCode("PUBLIC_CONFLICT"));
    assert.equal(f.model.records.get(first.recordName).fields.name.value, "Nowa nazwa");
  } finally { f.close(); }
});

test("lost create/replace responses reconcile only the same durable operation, including after reopen", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(), input = profileInput(session); let lose = true;
    f.model.after = () => { if (lose) { lose = false; throw new Error("PRIVATE upstream body"); } };
    await assert.rejects(() => f.repository.write(input), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "pending");
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
    const reopened = new CloudKitPublicRepository({ registry, client: f.client, authentication: f.state, clock: f.clock });
    await assert.rejects(() => reopened.write(profileInput(session, "Other")), publicCode("PUBLIC_PENDING"));
    const recovered = await reopened.write(input);
    assert.equal(f.model.records.size, 1); assert.equal(recovered.fields.name.value, "Maja");
    lose = true; const update = { ...profileInput(session, "Druga"), expectedTag: recovered.recordChangeTag };
    await assert.rejects(() => reopened.write(update), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal((await reopened.write(update)).fields.name.value, "Druga");
    assert.equal(f.model.records.size, 1);
  } finally { f.close(); }
});

test("durability failure prevents dispatch and a genuine retry retains the original request identity", async () => {
  let armed = false;
  const f = publicFixture({ syncHook: () => { if (armed) throw new Error("PRIVATE disk error"); } });
  try {
    const session = await f.session(), input = profileInput(session); armed = true;
    await assert.rejects(() => f.repository.write(input), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal(f.model.requests.length, 0); armed = false;
    await f.repository.write(input); assert.equal(f.model.requests.length, 1);
  } finally { f.close(); }
});

test("a deletion beginning during durability prevents the prepared write from ever being dispatched", async () => {
  let hook;
  const f = publicFixture({ syncHook: async () => { const action = hook; hook = undefined; await action?.(); } });
  try {
    const session = await f.session(); let ticket;
    hook = async () => { ticket = await f.beginDeletion(session); };
    await assert.rejects(() => f.repository.write(profileInput(session)), error => error.code === "INVALID_SESSION");
    assert.equal(f.model.requests.length, 0);
    assert.equal((await f.erase(ticket)).remaining, false);
    assert.equal([...f.model.records.values()][0].fields.erased.value, 1);
  } finally { f.close(); }
});

test("an unknown create still queued in transit loses to its exact durable erasure fence", async () => {
  const f = publicFixture(); let release, reached;
  try {
    const session = await f.session(), ready = new Promise(resolve => { reached = resolve; });
    let hold = true;
    f.model.before = async call => {
      if (hold && call.operation === "modify") { hold = false; reached(); await new Promise(resolve => { release = resolve; }); }
    };
    const write = f.repository.write(profileInput(session)); const checked = assert.rejects(() => write, error => ["PUBLIC_SCOPE", "PUBLIC_ERASED", "PUBLIC_CONFLICT", "INVALID_SESSION"].includes(error.code));
    await ready;
    const ticket = await f.beginDeletion(session); assert.equal((await f.erase(ticket)).remaining, false);
    release(); await checked;
    const record = [...f.model.records.values()][0]; assert.equal(record.fields.erased.value, 1); assert.equal(record.fields.name, undefined);
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "erased");
  } finally { release?.(); f.close(); }
});

test("an update committing before erasure is removed, and one committing after its fence conflicts", async () => {
  for (const beforeCommit of [true, false]) {
    const f = publicFixture(); let release, reached;
    try {
      const session = await f.session(), first = await f.repository.write(profileInput(session));
      const ready = new Promise(resolve => { reached = resolve; }); let hold = true;
      const hook = async call => { if (hold && call.operation === "modify") { hold = false; reached(); await new Promise(resolve => { release = resolve; }); } };
      if (beforeCommit) f.model.before = hook; else f.model.after = hook;
      const update = f.repository.write({ ...profileInput(session, "PRIVATE-NEW-CONTENT"), expectedTag: first.recordChangeTag });
      const checked = assert.rejects(() => update, error => ["PUBLIC_SCOPE", "PUBLIC_ERASED", "PUBLIC_CONFLICT", "INVALID_SESSION"].includes(error.code));
      await ready; const ticket = await f.beginDeletion(session); await f.erase(ticket);
      release(); await checked;
      const record = f.model.records.get(first.recordName); assert.equal(record.fields.erased.value, 1); assert.equal(record.fields.name, undefined);
    } finally { release?.(); f.close(); }
  }
});

test("exact-ID erasure covers all five types without queries, strips unknown fields and preserves another owner", async () => {
  const f = publicFixture();
  try {
    const a = await f.session(), b = await f.session("another.user");
    const profile = await f.repository.write(profileInput(a));
    const message = await f.repository.write(messageInput(a));
    await f.repository.write({ accessToken: a.sessionToken, kind: "presence", logicalID: "singleton", requestID: randomUUID(),
      input: { name: "Maja", latitude: 51.123456, longitude: 17.123456, measuredAt: f.clock(), song: "Track", songID: "123", generation: 0 } });
    await f.repository.write({ accessToken: a.sessionToken, kind: "block", logicalID: b.accountID, requestID: randomUUID(), input: { targetID: b.accountID, blocked: true } });
    assert.equal(JSON.stringify(f.db.prepare("SELECT * FROM public_records_v1 WHERE kind='block'").get()).includes(b.accountID), false);
    const reportID = randomUUID();
    await f.repository.write({ accessToken: a.sessionToken, kind: "report", logicalID: reportID, requestID: reportID, input: { messageID: message.recordName, reason: "synthetic" } });
    const other = await f.repository.write(profileInput(b, "Other owner"));
    f.model.records.get(profile.recordName).fields.futurePrivateField = { value: "UNKNOWN-CONTENT", type: "STRING" };
    const ticket = await f.beginDeletion(a); const receipt = await f.erase(ticket); assert.equal(receipt.remaining, false);
    for (const record of f.model.records.values()) {
      if (record.recordName === other.recordName) assert.equal(record.fields.name.value, "Other owner");
      else assert.deepEqual(Object.keys(record.fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    }
    assert.equal(f.model.requests.some(call => call.operation === "query"), false);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1 WHERE phase='erased'").get().n, 5);
    for (const row of f.db.prepare("SELECT * FROM public_records_v1 WHERE phase='erased'").all()) {
      assert.equal(row.logical_key, null); assert.equal(row.payload_hash, null); assert.equal(row.request_id, null);
      assert.equal(row.created_at, 0); assert.equal(row.started_at, 0); assert.equal(row.generation, 0);
    }
  } finally { f.close(); }
});

test("batches are at most 25 and public completion needs a later settle pass plus the separate private ACK", async () => {
  const f = publicFixture();
  try {
    const session = await f.session();
    for (let i = 0; i < 52; i++) await f.repository.write(messageInput(session, "message " + i));
    const ticket = await f.beginDeletion(session);
    assert.equal((await f.erase(ticket)).remaining, true); f.advance(1001);
    assert.equal((await f.erase(ticket)).remaining, true); f.advance(1001);
    assert.equal((await f.erase(ticket)).remaining, false);
    assert.equal(f.deletions.status(ticket).publicData, "draining");
    f.advance(60001); assert.equal((await f.erase(ticket)).remaining, false);
    assert.equal(f.deletions.status(ticket).publicData, "deleted"); assert.equal(f.deletions.status(ticket).completed, false);
    assert.ok(f.model.requests.every(call => (call.body.operations?.length ?? call.body.records.length) <= 25));
    await f.deletions.acknowledgePrivateCleanup(ticket);
    await f.processor().step(ticket.deletionID);
    assert.equal(f.deletions.status(ticket).completed, true);
  } finally { f.close(); }
});

test("wrong owner or expired erasure lease cannot select records or advance the local ledger", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(); await f.repository.write(profileInput(session));
    const ticket = await f.beginDeletion(session), context = await f.deletions.claimPublicBatch(ticket.deletionID), count = f.model.requests.length;
    await assert.rejects(() => f.repository.erasePublicDataBatch({ ...context, accountID: randomUUID() }), publicCode("PUBLIC_SCOPE"));
    f.advance(60001);
    await assert.rejects(() => f.repository.erasePublicDataBatch(context), publicCode("PUBLIC_SCOPE"));
    assert.equal(f.model.requests.length, count);
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "settled");
  } finally { f.close(); }
});

test("partial modify errors keep erasure incomplete and a fresh batch reconciles already-cleared content", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(); await f.repository.write(profileInput(session)); await f.repository.write(messageInput(session));
    const ticket = await f.beginDeletion(session), context = await f.deletions.claimPublicBatch(ticket.deletionID); let first = true;
    f.model.after = async call => {
      if (call.operation === "modify" && first) {
        first = false; const body = await call.response.json(); body.records[0] = { recordName: body.records[0].recordName, serverErrorCode: "THROTTLED" }; return Response.json(body);
      }
    };
    await assert.rejects(() => f.repository.erasePublicDataBatch(context), publicCode("PUBLIC_THROTTLED"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1 WHERE phase='erased'").get().n, 1);
    await f.deletions.failPublicBatch(context.leaseID); f.advance(60001);
    assert.equal((await f.erase(ticket)).remaining, false);
  } finally { f.close(); }
});

test("a fence returned by metadata is replaced again so unexpected content cannot hide behind erased=1", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(); const saved = await f.repository.write(profileInput(session));
    const ticket = await f.beginDeletion(session); let fail = true;
    f.model.after = call => { if (call.operation === "modify" && fail) { fail = false; throw new Error("lost erasure response"); } };
    const context = await f.deletions.claimPublicBatch(ticket.deletionID);
    await assert.rejects(() => f.repository.erasePublicDataBatch(context), publicCode("PUBLIC_UNAVAILABLE"));
    f.model.records.get(saved.recordName).fields.extra = { value: "UNEXPECTED-CONTENT", type: "STRING" };
    await f.deletions.failPublicBatch(context.leaseID); f.advance(60001); await f.erase(ticket);
    assert.equal(f.model.records.get(saved.recordName).fields.extra, undefined);
  } finally { f.close(); }
});

test("foreign provider metadata never authorizes a replace or false erasure receipt", async () => {
  const f = publicFixture();
  try {
    const session = await f.session(), saved = await f.repository.write(profileInput(session));
    f.model.records.get(saved.recordName).fields.ownerKey.value = ownerKey(randomUUID());
    const ticket = await f.beginDeletion(session), context = await f.deletions.claimPublicBatch(ticket.deletionID), count = f.model.requests.length;
    await assert.rejects(() => f.repository.erasePublicDataBatch(context), publicCode("PUBLIC_SCOPE"));
    assert.equal(f.model.requests.length, count + 1); assert.notEqual(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "erased");
  } finally { f.close(); }
});

test("strict field schemas forbid forged owner/time/expiry/asset fields and keep coordinate types stable", () => {
  const now = 1800000000000;
  for (const input of [undefined, null, [], { name: "A", accountID: randomUUID() }, { name: "A", expiresAt: now }, { name: "A", avatar: "file:///private" }, { name: "\u202eA" }]) {
    assert.throws(() => normalizePublicInput("profile", input, now), publicCode("PUBLIC_INPUT"));
  }
  const zero = normalizePublicInput("message", { name: " A ", text: " Hi ", latitude: 0, longitude: 180 }, now);
  assert.equal(fieldValues(zero).latitude.type, "DOUBLE"); assert.equal(fieldValues(zero).longitude.type, "DOUBLE");
  assert.equal(zero.name, "A");
  assert.throws(() => recordIdentity(randomUUID(), "profile", randomUUID()), publicCode("PUBLIC_INPUT"));
  assert.throws(() => normalizePublicInput("presence", { name: "A", latitude: 0, longitude: 0, song: "", songID: "", generation: 0, measuredAt: now - 60001 }, now), publicCode("PUBLIC_INPUT"));
});

test("transport rejects redirects, bad JSON, duplicates, foreign IDs and overlong responses without leaking reasons", async () => {
  const identity = recordIdentity(randomUUID(), "profile", "singleton"), name = identity.recordName;
  const valid = { recordName: name, recordType: identity.recordType, recordChangeTag: "1", fields: {} };
  const replies = [() => new Response("PRIVATE reason", { status: 302, headers: { Location: "https://attacker.invalid" } }),
    () => Response.json({ records: [valid, valid] }), () => Response.json({ records: [{ ...valid, recordName: "other" }] }),
    () => new Response("{bad", { headers: { "Content-Type": "application/json" } }),
    () => new Response(" ".repeat(512 * 1024 + 1), { headers: { "Content-Type": "application/json" } }),
    () => new Response("{}", { headers: { "Content-Type": "text/plain" } })];
  for (const reply of replies) {
    const client = publicClient(async () => reply());
    await assert.rejects(() => client.lookup([name]), error => error.message === "Community data operation could not be completed." && !error.message.includes("PRIVATE"));
  }
});

test("transport imposes its own deadline even when fetch ignores AbortSignal and cancels stalled bodies", async () => {
  const name = recordIdentity(randomUUID(), "profile", "singleton").recordName;
  const client = publicClient(async () => new Promise(() => {}), { timeoutMilliseconds: 10 });
  await assert.rejects(() => client.lookup([name]), publicCode("PUBLIC_UNAVAILABLE"));
  let cancelled = false;
  const stalled = publicClient(async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }), { headers: { "Content-Type": "application/json" } }), { timeoutMilliseconds: 10 });
  await assert.rejects(() => stalled.lookup([name]), publicCode("PUBLIC_UNAVAILABLE")); assert.equal(cancelled, true);
});

test("parent cancellation and disabled runtime stop the transport without waiting for provider cooperation", async () => {
  const name = recordIdentity(randomUUID(), "profile", "singleton").recordName, controller = new AbortController(); let reached;
  const ready = new Promise(resolve => { reached = resolve; });
  const client = publicClient(async () => { reached(); return new Promise(() => {}); });
  const call = client.lookup([name], { signal: controller.signal }); const checked = assert.rejects(() => call, publicCode("PUBLIC_UNAVAILABLE"));
  await ready; controller.abort(); await checked;
  let calls = 0;
  const disabled = publicClient(async () => { calls++; }, { isEnabled: () => false });
  await assert.rejects(() => disabled.lookup([name]), publicCode("PUBLIC_UNAVAILABLE")); assert.equal(calls, 0);
});

test("only controlled Development/public records and create/replace operations are permitted", async () => {
  assert.throws(() => publicClient(async () => {}, { environment: "production" }), publicCode("PUBLIC_UNAVAILABLE"));
  assert.throws(() => publicClient(async () => {}, { container: "iCloud.other.app" }), publicCode("PUBLIC_UNAVAILABLE"));
  const name = recordIdentity(randomUUID(), "profile", "singleton").recordName;
  const client = publicClient(async () => { throw new Error("must not fetch"); });
  for (const operationType of ["delete", "forceDelete", "forceUpdate", "forceReplace"]) {
    await assert.rejects(() => client.modify([{ operationType, record: { recordName: name, recordType: "EchoesPublicProfileV1", fields: {} } }]), publicCode("PUBLIC_INPUT"));
  }
});
