import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarPublicationFixture } from "./support/avatar-publication-fixture.mjs";
import { profileInput } from "./support/public-record-fixture.mjs";
import { sqliteSnapshot, restoreSQLite } from "./support/sqlite-snapshot.mjs";
const code = expected => e => e?.code === expected && e.message === "Profile photo operation could not be completed." && e.cause === undefined;
const photoWrite = call => call.operation === "modify" && call.body.operations[0]?.record.recordType === "EchoesAvatarProfileV1";
const pause = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function stage(f, input = f.upload()) { return f.call("prepareUpload", input); }
async function approve(f, status) { await f.call("prepareReview", f.review(status)); return f.call("prepareStatus", f.credentials()); }
async function publish(f, status) { return f.call("preparePublish", f.credentials(f.publication(status))); }

test("actual pipeline persists consent and server descriptor, awaits review and writes an independent CloudKit photo profile", async () => {
  const f = await avatarPublicationFixture();
  try {
    const name = await f.repository.write(profileInput(f.signedIn));
    const input = f.upload(), pending = await stage(f, input);
    assert.equal(pending.status, "pending-review"); assert.equal(pending.publishedVersionID, null); assert.equal(pending.generation, 1);
    await assert.rejects(() => publish(f, pending), code("AVATAR_PENDING"));
    assert.equal(f.model.records.size, 2); // Text profile + immutable bytes, no photo pointer yet.
    const approved = await approve(f, pending); assert.equal(approved.status, "approved"); assert.equal(approved.publishedVersionID, null);
    const result = await publish(f, approved); assert.equal(result.status, "published"); assert.equal(result.publishedVersionID, input.versionID);
    const pointer = f.registry.owned(f.signedIn.accountID, "avatarprofile", "singleton");
    assert.equal(f.model.records.get(pointer.recordName).fields.versionID.value, input.versionID);
    await f.repository.write({ ...profileInput(f.signedIn, "Inna nazwa"), expectedTag: name.recordChangeTag });
    assert.equal(f.model.records.get(pointer.recordName).fields.versionID.value, input.versionID);
    assert.equal(f.assetCalls.length, 4);
    const rows = JSON.stringify(f.db.prepare("SELECT * FROM avatar_jobs_v1").all());
    for (const value of ["Inna nazwa", "SYNTHETIC-PRIVATE", "downloadURL", "wrappingKey"]) assert.equal(rows.includes(value), false);
  } finally { f.close(); }
});

test("lost staging response recovers by request ID after reopen without client manifests or another upload", async () => {
  const f = await avatarPublicationFixture();
  try {
    const input = f.upload();
    f.setRecordHook(call => { if (call.operation === "modify" && call.body.operations[0].record.recordType === "EchoesAvatarV1") throw new Error("SYNTHETIC lost asset record reply"); });
    await assert.rejects(() => stage(f, input), code("AVATAR_UNAVAILABLE")); f.setRecordHook(undefined);
    const job = f.db.prepare("SELECT * FROM avatar_jobs_v1").get(); assert.ok(job.descriptor_json); assert.equal(job.staged_tag, null);
    const recovered = await f.call("prepareRecovery", f.credentials({ requestID: input.requestID }), f.reopen());
    assert.equal(recovered.status, "pending-review"); assert.equal(f.assetCalls.length, 4);
    assert.equal(f.model.records.size, 1);
  } finally { f.close(); }
});

test("explicit consent is required before decode/upload and input cannot select another owner or inject provider metadata", async () => {
  const f = await avatarPublicationFixture();
  try {
    for (const changes of [{ consentVersion: undefined }, { consentVersion: 0 }, { accountID: randomUUID() },
      { receipt: "SYNTHETIC" }, { url: "https://evil.invalid" }, { bytes: new Uint8Array(256001) }, { bytes: new Uint8Array(new SharedArrayBuffer(8)) }]) {
      await assert.rejects(() => stage(f, f.upload(changes)), code("AVATAR_INPUT"));
    }
    assert.equal(f.assetCalls.length, 0); assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n, 0);
  } finally { f.close(); }
});

test("same operation is idempotent but different bytes, version or stale CAS cannot reuse its consent", async () => {
  const f = await avatarPublicationFixture();
  try {
    const input = f.upload(), first = await stage(f, input); assert.deepEqual(await stage(f, input), first);
    await assert.rejects(() => stage(f, { ...input, versionID: randomUUID() }), code("AVATAR_STALE"));
    await assert.rejects(() => stage(f, { ...input, bytes: new Uint8Array([1, 2, 3]) }), code("AVATAR_STALE"));
    await assert.rejects(() => stage(f, f.upload({ expectedGeneration: 0 })), code("AVATAR_STALE"));
    assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("rate budget limits new versions, survives clear and exempts exact recovery and privacy withdrawal", async () => {
  const f = await avatarPublicationFixture();
  try {
    for (let i = 0; i < 3; i++) await stage(f);
    await assert.rejects(() => stage(f), code("AVATAR_RATE"));
    const current = f.policy.snapshot(f.signedIn.accountID);
    const cleared = await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: current.generation }));
    assert.equal(cleared.status, "none"); assert.equal(cleared.publishedVersionID, null);
    await assert.rejects(() => stage(f), code("AVATAR_RATE"));
    f.advance(600000); await f.relogin(); assert.equal((await stage(f)).status, "pending-review");
  } finally { f.close(); }
});

test("new selection hides the previous picture immediately and late old approval cannot publish it", async () => {
  const f = await avatarPublicationFixture();
  try {
    const old = await approve(f, await stage(f)); await publish(f, old);
    const next = await stage(f); assert.equal(next.publishedVersionID, null); assert.equal(next.status, "pending-review");
    await assert.rejects(() => f.call("prepareReview", f.review(old)), code("AVATAR_STALE"));
    await assert.rejects(() => publish(f, old), code("AVATAR_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).versionID, next.versionID);
  } finally { f.close(); }
});

for (const phase of ["before", "after"]) test(`clear hides an in-flight photo publication paused ${phase} CloudKit applies it`, async () => {
  const f = await avatarPublicationFixture(), reached = pause(), resume = pause();
  try {
    const approved = await approve(f, await stage(f)); let held = false;
    const hook = async call => { if (!held && photoWrite(call)) { held = true; reached.resolve(); await resume.promise; } };
    if (phase === "before") f.model.before = hook; else f.setRecordHook(hook);
    const writing = publish(f, approved), outcome = writing.catch(e => e); await reached.promise;
    const clear = f.credentials({ requestID: randomUUID(), expectedGeneration: approved.generation });
    await f.call("prepareClear", clear); resume.resolve(); assert.equal((await outcome).code, "AVATAR_STALE");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    const pointer = f.registry.owned(f.signedIn.accountID, "avatarprofile", "singleton");
    assert.equal(f.model.records.get(pointer.recordName).fields.versionID.value, "");
  } finally { resume.resolve(); f.close(); }
});

test("a stale editor cannot clear a newer generation and repeated exact clear stays idempotent", async () => {
  const f = await avatarPublicationFixture();
  try {
    await stage(f); const newer = await stage(f);
    await assert.rejects(() => f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: 1 })), code("AVATAR_STALE"));
    const body = f.credentials({ requestID: randomUUID(), expectedGeneration: newer.generation });
    const first = await f.call("prepareClear", body); assert.deepEqual(await f.call("prepareClear", body), first);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
  } finally { f.close(); }
});

test("review rejection, reapproval and stale decision IDs cannot finish a previously captured publish lease", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f), body = f.review(pending), review = await f.call("prepareReview", body);
    assert.deepEqual(await f.call("prepareReview", body), review);
    let approved = f.policy.snapshot(f.signedIn.accountID), lease = f.policy.publishLease(f.policy.intent(f.signedIn.accountID, approved.requestID));
    await f.call("prepareReview", f.review(approved, "rejected"));
    await assert.rejects(() => publish(f, approved), code("AVATAR_STALE"));
    await assert.rejects(() => publish(f, f.policy.snapshot(f.signedIn.accountID)), code("AVATAR_REJECTED"));
    await assert.rejects(() => f.call("prepareReview", body), code("AVATAR_STALE"));
    approved = await approve(f, f.policy.snapshot(f.signedIn.accountID));
    assert.throws(() => f.policy.assertPublishCurrent(lease), code("AVATAR_STALE"));
    assert.equal((await publish(f, approved)).status, "published");
  } finally { f.close(); }
});

test("operator role is separate, synchronous and checked again after the outer checkpoint", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f), input = f.review(pending);
    for (const authorizeOperator of [undefined, () => ({ operatorID: f.signedIn.accountID, scope: "user" }), async () => ({ operatorID: f.operatorID, scope: "avatar-review" })]) {
      await assert.rejects(() => f.call("prepareReview", input, f.make({ authorizeOperator })), code("AVATAR_SCOPE"));
    }
    const finalize = await f.coordinator.prepareReview(input); f.disableOperator();
    assert.throws(() => finalize(), code("AVATAR_SCOPE"));
  } finally { f.close(); }
});

test("a finalizer captured before clear cannot return an old publication as the active selection", async () => {
  const f = await avatarPublicationFixture();
  try {
    const approved = await approve(f, await stage(f));
    const final = await f.coordinator.preparePublish(f.credentials(f.publication(approved)));
    await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: approved.generation }));
    assert.throws(() => final(), code("AVATAR_STALE"));
  } finally { f.close(); }
});

test("lost pointer acknowledgement reopens and publishes without new file uploads", async () => {
  const f = await avatarPublicationFixture();
  try {
    const approved = await approve(f, await stage(f));
    f.setRecordHook(call => { if (photoWrite(call)) throw new Error("SYNTHETIC lost pointer response"); });
    await assert.rejects(() => publish(f, approved), code("AVATAR_UNAVAILABLE")); f.setRecordHook(undefined);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    const result = await f.call("preparePublish", f.credentials(f.publication(approved)), f.reopen());
    assert.equal(result.publishedVersionID, approved.versionID); assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("suspension, account generation, cancellation and activation cannot leak a captured result", async () => {
  const f = await avatarPublicationFixture();
  try {
    const input = f.upload(), pending = await stage(f, input), final = await f.coordinator.prepareStatus(f.credentials());
    await f.social.setSuspended(f.signedIn.accountID, true); assert.throws(() => final(), code("AVATAR_STALE"));
    await assert.rejects(() => stage(f), code("AVATAR_STALE")); await f.social.setSuspended(f.signedIn.accountID, false);
    const oldCredentials = f.credentials({ requestID: pending.requestID }); await f.nextLoginGeneration();
    await assert.rejects(() => f.call("prepareRecovery", oldCredentials), code("AVATAR_STALE"));
    assert.equal((await f.call("prepareRecovery", f.credentials({ requestID: pending.requestID }))).status, "pending-review");
    const controller = new AbortController(); controller.abort(); await assert.rejects(() => stage(f, f.upload({ signal: controller.signal })), code("AVATAR_UNAVAILABLE"));
    f.disable(); await assert.rejects(() => f.coordinator.prepareStatus(f.credentials()), code("AVATAR_UNAVAILABLE"));
  } finally { f.close(); }
});

test("account erasure clears consent, descriptors, review and selection together and fences late work", async () => {
  const f = await avatarPublicationFixture();
  try {
    const approved = await approve(f, await stage(f)); await publish(f, approved);
    const final = await f.coordinator.prepareStatus(f.credentials()), ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_profiles_v1").get().n, 0);
    assert.throws(() => final(), code("AVATAR_STALE"));
    assert.ok([...f.model.records.values()].every(r => r.fields.erased.value === 1 && r.fields.image === undefined && r.fields.versionID === undefined));
  } finally { f.close(); }
});

test("restored consent/review metadata cannot bypass a newer remote checkpoint", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f), snapshot = sqliteSnapshot(f.db); await approve(f, pending);
    restoreSQLite(f.storage, snapshot);
    await assert.rejects(() => f.call("prepareStatus", f.credentials(), f.reopen()), code("AVATAR_UNAVAILABLE"));
  } finally { f.close(); }
});

test("bounded version history never blocks withdrawal even when no further upload fits", async () => {
  const f = await avatarPublicationFixture();
  try {
    for (let i = 0; i < 1000; i++) {
      if (i && i % 3 === 0) f.advance(600000);
      await f.policy.select({ accountID: f.signedIn.accountID, requestID: randomUUID(), versionID: randomUUID(), expectedGeneration: i,
        sourceHash: "a".repeat(64), consentVersion: 1 });
    }
    await f.relogin();
    await assert.rejects(() => stage(f), code("AVATAR_CAPACITY"));
    const result = await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: 1000 }));
    assert.equal(result.publishedVersionID, null); assert.equal(result.status, "none"); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); }
});

test("a consent transaction failure rolls back the selection and starts no file transfer", async () => {
  let armed = false;
  const f = await avatarPublicationFixture({ sqlHook: sql => { if (armed && sql.startsWith("INSERT INTO avatar_jobs_v1")) throw new Error("SYNTHETIC private SQL details"); } });
  try {
    armed = true; await assert.rejects(() => stage(f), code("AVATAR_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_profiles_v1").get().n, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n, 0); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); }
});

test("uncertain consent durability returns no false result and exact retry keeps one consent and upload", async () => {
  let armed = false;
  const f = await avatarPublicationFixture({ syncHook: () => {
    if (armed && f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n) { armed = false; throw new Error("SYNTHETIC sync"); }
  } });
  try {
    const input = f.upload(); armed = true; await assert.rejects(() => stage(f, input), code("AVATAR_UNAVAILABLE"));
    assert.equal(f.assetCalls.length, 0);
    assert.equal((await stage(f, input)).status, "pending-review"); assert.equal(f.assetCalls.length, 4);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_jobs_v1").get().n, 1);
  } finally { f.close(); }
});

test("reject then reapprove during an in-flight publication cannot restore an old moderation lease", async () => {
  const f = await avatarPublicationFixture(), reached = pause(), resume = pause();
  try {
    const approved = await approve(f, await stage(f)); let held = false;
    f.model.before = async call => { if (!held && photoWrite(call)) { held = true; reached.resolve(); await resume.promise; } };
    const writing = publish(f, approved), outcome = writing.catch(e => e); await reached.promise;
    await f.call("prepareReview", f.review(approved, "rejected"));
    const next = await approve(f, f.policy.snapshot(f.signedIn.accountID));
    resume.resolve(); assert.equal((await outcome).code, "AVATAR_STALE");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    assert.equal((await publish(f, next)).status, "published");
  } finally { resume.resolve(); f.close(); }
});

test("lost clear response recovers by request ID and keeps the image hidden throughout", async () => {
  const f = await avatarPublicationFixture();
  try {
    const approved = await approve(f, await stage(f)); await publish(f, approved);
    const clear = f.credentials({ requestID: randomUUID(), expectedGeneration: approved.generation });
    f.setRecordHook(call => { if (photoWrite(call)) throw new Error("SYNTHETIC unknown clear"); });
    await assert.rejects(() => f.call("prepareClear", clear), code("AVATAR_UNAVAILABLE")); f.setRecordHook(undefined);
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    assert.equal((await f.call("prepareRecovery", f.credentials({ requestID: clear.requestID }), f.reopen())).status, "none");
    assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("server copies input before await and keeps raw source bytes out of returned status and finalizers", async () => {
  const { digest } = await import("../src/public-record-schema.mjs");
  const f = await avatarPublicationFixture();
  try {
    const original = digest(f.sourceBytes); await stage(f); assert.equal(digest(f.sourceBytes), original);
    let changed = false;
    f.model.beforeCheckpoint = () => { if (!changed) { changed = true; f.sourceBytes.fill(0); } };
    const status = await stage(f); assert.equal(status.status, "pending-review");
    assert.equal(f.db.prepare("SELECT source_hash FROM avatar_jobs_v1 WHERE request_id=?").get(status.requestID).source_hash, original);
    assert.equal(JSON.stringify(status).includes("bytes"), false);
  } finally { f.close(); }
});

test("another application account cannot recover, publish or review the owner's photo intent", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f), other = await f.session("synthetic.reader");
    const input = { accessToken: other.sessionToken, requestID: pending.requestID };
    await assert.rejects(() => f.call("prepareRecovery", input), code("AVATAR_STALE"));
    await assert.rejects(() => f.call("preparePublish", { ...f.publication(pending), ...input }), code("AVATAR_STALE"));
    const status = await f.call("prepareStatus", { accessToken: other.sessionToken }); assert.equal(status.generation, 0); assert.equal(status.versionID, null);
    await assert.rejects(() => f.call("prepareReview", { ...f.review(pending), accessToken: other.sessionToken }), code("AVATAR_INPUT"));
    assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("late operator adapter errors are redacted by the returned finalizer", async () => {
  const f = await avatarPublicationFixture();
  try {
    const pending = await stage(f); let throwLate = false;
    const instance = f.make({ authorizeOperator: () => {
      if (throwLate) throw new Error("SYNTHETIC private operator failure"); return { operatorID: f.operatorID, scope: "avatar-review" };
    } });
    const finalize = await instance.coordinator.prepareReview(f.review(pending)); throwLate = true;
    assert.throws(() => finalize(), code("AVATAR_SCOPE"));
  } finally { f.close(); }
});
