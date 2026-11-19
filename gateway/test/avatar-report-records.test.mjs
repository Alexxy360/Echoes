import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { publicFixture, publicCode } from "./support/public-record-fixture.mjs";
import { retentionFixture } from "./support/public-retention-fixture.mjs";
import { normalizePublicInput, recordIdentity, publicRecordTypes, liveFields, erasedFields } from "../src/public-record-schema.mjs";
import { publicRetentionDeadline, expiredPublicFields } from "../src/public-retention-policy.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { CloudKitPublicRepository } from "../src/public-record-repository.mjs";
import { prepareAvatarReportSchema, verifyAvatarReportProposal, avatarReportFields } from "../scripts/prepare-avatar-report-schema.mjs";
import { inspectSchema } from "../scripts/prepare-community-schema.mjs";

const day = 86400000;
const input = (session, changes = {}) => {
  const requestID = randomUUID();
  return { accessToken: session.sessionToken, kind: "avatarreport", requestID, logicalID: requestID, authorizeMutation: () => true,
    input: { avatarID: recordIdentity(randomUUID(), "avatar", randomUUID()).recordName, versionID: randomUUID(),
      publicationGeneration: 7, imageSHA256: "b".repeat(64), reason: "PRIVATE_SYNTHETIC_PHOTO_REPORT_REASON" }, ...changes };
};
const recover = (f, session, value, changes = {}) => f.repository.recoverAvatarReport({ accessToken: session.sessionToken,
  requestID: value.requestID, authorizeRead: () => true, ...changes });
const creates = f => f.model.requests.filter(call => call.operation === "modify").length;

const installed = await readFile(new URL("../schema/development-installed-20261119.ckdb", import.meta.url), "utf8");

test("photo-report schema adds one server-only type while preserving all thirteen installed types and roles", () => {
  const before = inspectSchema(installed), prepared = prepareAvatarReportSchema(installed), after = inspectSchema(prepared.schema);
  assert.equal(before.types.length, 13); assert.ok(prepared.schema.startsWith(installed));
  assert.deepEqual(after.types.slice(0, -1), before.types); assert.deepEqual(after.roles, before.roles);
  assert.equal(after.types.at(-1).name, publicRecordTypes.avatarreport);
  assert.deepEqual(after.types.at(-1).grants, [{ role: "EchoesCommunityService", rights: ["READ", "CREATE", "WRITE"] }]);
  assert.deepEqual(prepared.roleAssignments, []); assert.equal(prepared.addedRole, null); assert.equal(prepared.remoteImport, false);
  assert.deepEqual(prepared.dataOperations, []); assert.equal(prepared.remoteValidation, "not performed");
  assert.deepEqual(verifyAvatarReportProposal(installed, prepared.schema), { inputSHA256: prepared.inputSHA256, proposedSHA256: prepared.proposedSHA256 });
});

test("photo-report serializers and both content-free fences fit the additive schema without extra data fields", () => {
  const accountID = randomUUID(), value = input({ sessionToken: "synthetic" }), normalized = normalizePublicInput("avatarreport", value.input, 100);
  const context = { ...recordIdentity(accountID, "avatarreport", value.requestID), requestID: value.requestID,
    payloadHash: "a".repeat(64), createdAt: 100, startedAt: 100 };
  for (const fields of [liveFields(context, normalized), erasedFields(context, randomUUID()), expiredPublicFields(context)]) {
    for (const [name, field] of Object.entries(fields)) assert.equal(avatarReportFields[name], field.type);
  }
  assert.deepEqual(Object.keys(normalized).sort(), ["avatarID", "imageSHA256", "publicationGeneration", "reason", "versionID"]);
  assert.equal(publicRetentionDeadline(context), 100 + 30 * day);
});

test("photo-report schema refuses replacement missing base and changes to the reviewed proposal", () => {
  const prepared = prepareAvatarReportSchema(installed);
  assert.throws(() => prepareAvatarReportSchema(prepared.schema));
  assert.throws(() => prepareAvatarReportSchema(installed.replace("CREATE ROLE EchoesCommunityService;", "")));
  assert.throws(() => prepareAvatarReportSchema(installed.replace(/RECORD TYPE EchoesPresenceV1\s*\([\s\S]*?\);/, "")));
  assert.throws(() => verifyAvatarReportProposal(installed, prepared.schema.replace(/imageSHA256 STRING/, "imageSHA256 INT64")));
  assert.throws(() => verifyAvatarReportProposal(installed, prepared.schema + "\nCREATE ROLE UnreviewedRole;\n"));
});

test("photo-report input rejects arbitrary fields invalid versions misleading subjects and oversized reasons", () => {
  const raw = input({ sessionToken: "synthetic" }).input;
  for (const changes of [{ avatarID: recordIdentity(randomUUID(), "message", randomUUID()).recordName }, { versionID: "wrong" },
    { publicationGeneration: 0 }, { publicationGeneration: 1.5 }, { imageSHA256: "A".repeat(64) }, { reason: "x".repeat(501) },
    { coordinate: { latitude: 0, longitude: 0 } }, { ownerID: randomUUID() }, { downloadURL: "https://private.invalid" }, { messageID: "wrong" }]) {
    assert.throws(() => normalizePublicInput("avatarreport", { ...raw, ...changes }, 100), publicCode("PUBLIC_INPUT"));
  }
  assert.equal(normalizePublicInput("avatarreport", { ...raw, reason: "  Cafe\u0301  " }, 100).reason, "Café");
});

test("immutable photo report derives its reporter from authentication and keeps reason and image references out of SQL", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session), saved = await f.repository.write(value);
    assert.equal(saved.recordType, "EchoesAvatarReportV1"); assert.equal(saved.recordName, recordIdentity(session.accountID, "avatarreport", value.requestID).recordName);
    assert.equal(saved.fields.accountID.value, session.accountID); assert.equal(saved.fields.reason.value, value.input.reason);
    assert.equal(f.registry.reviewReportPage().items.length, 0); // Text-report moderator queue remains separate.
    const rows = JSON.stringify(f.storage.sql.exec("SELECT * FROM public_records_v1").toArray());
    assert.ok(!rows.includes(value.input.reason) && !rows.includes(value.input.avatarID) && !rows.includes(value.input.imageSHA256));
    assert.equal(f.db.prepare("SELECT due_at FROM public_retention_v1").get().due_at, f.clock() + 30 * day);
  } finally { f.close(); }
});

test("photo-report creation and recovery require synchronous true authorization before provider IO", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session);
    for (const guard of [() => false, () => undefined, () => Promise.resolve(true), () => Promise.reject(new Error("synthetic"))]) {
      await assert.rejects(() => f.repository.write({ ...value, authorizeMutation: guard }), publicCode("PUBLIC_SCOPE"));
      await assert.rejects(() => recover(f, session, value, { authorizeRead: guard }), publicCode("PUBLIC_SCOPE"));
    }
    assert.equal(f.model.requests.length, 0); assert.equal(f.registry.owned(session.accountID, "avatarreport", value.requestID), null);
  } finally { f.close(); }
});

test("same photo-report request is idempotent but content replacement CAS and alternate logical IDs are forbidden", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session), saved = await f.repository.write(value);
    assert.deepEqual(await f.repository.write(value), saved); assert.equal(creates(f), 1);
    await assert.rejects(() => f.repository.write({ ...value, input: { ...value.input, reason: "replacement" } }), publicCode("PUBLIC_CONFLICT"));
    await assert.rejects(() => f.repository.write({ ...value, expectedTag: saved.recordChangeTag }), publicCode("PUBLIC_INPUT"));
    await assert.rejects(() => f.repository.write({ ...value, logicalID: randomUUID() }), publicCode("PUBLIC_INPUT"));
    await assert.rejects(() => f.registry.reserve({ accountID: session.accountID, kind: "avatarreport", logicalID: value.requestID,
      requestID: value.requestID, payloadHash: "a".repeat(64), expectedTag: saved.recordChangeTag }), publicCode("PUBLIC_INPUT"));
    assert.equal(creates(f), 1);
  } finally { f.close(); }
});

test("lost photo-report acknowledgement is recovered from the exact own immutable record without another create", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session);
    f.model.after = call => { if (call.operation === "modify") throw new Error("PRIVATE_SYNTHETIC_LOST_ACK"); };
    await assert.rejects(() => f.repository.write(value)); f.model.after = undefined;
    assert.equal(f.registry.owned(session.accountID, "avatarreport", value.requestID).phase, "pending");
    const result = await recover(f, session, value);
    assert.deepEqual(result, { schemaVersion: 1, reportID: recordIdentity(session.accountID, "avatarreport", value.requestID).recordName, outcome: "accepted" });
    assert.equal(f.registry.owned(session.accountID, "avatarreport", value.requestID).phase, "settled"); assert.equal(creates(f), 1);
    assert.ok(!JSON.stringify(result).includes(value.input.reason));
  } finally { f.close(); }
});

test("missing pending photo report remains unconfirmed and recovery never fabricates or retransmits it", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session);
    f.model.before = call => { if (call.operation === "modify") throw new Error("PRIVATE_SYNTHETIC_BEFORE_COMMIT"); };
    await assert.rejects(() => f.repository.write(value)); f.model.before = undefined;
    const count = creates(f); assert.equal((await recover(f, session, value)).outcome, "unconfirmed");
    assert.equal(creates(f), count); assert.equal(f.model.records.size, 0);
    const unknown = input(session), queries = f.model.requests.length;
    assert.equal((await recover(f, session, unknown)).outcome, "unconfirmed"); assert.equal(f.model.requests.length, queries);
  } finally { f.close(); }
});

test("another account cannot discover or settle a reporter's pending photo report using the same request UUID", async () => {
  const f = await publicFixture();
  try {
    const owner = await f.session(), other = await f.session("synthetic.other"), value = input(owner);
    f.model.after = call => { if (call.operation === "modify") throw new Error("lost"); };
    await assert.rejects(() => f.repository.write(value)); f.model.after = undefined;
    const queries = f.model.requests.length, result = await recover(f, other, value);
    assert.equal(result.outcome, "unconfirmed"); assert.equal(f.model.requests.length, queries);
    assert.notEqual(result.reportID, recordIdentity(owner.accountID, "avatarreport", value.requestID).recordName);
    assert.equal(f.registry.owned(owner.accountID, "avatarreport", value.requestID).phase, "pending");
  } finally { f.close(); }
});

test("photo-report recovery rejects changed reason owner key or immutable settled record tag", async () => {
  for (const change of [record => { record.fields.reason.value = "tampered"; }, record => { record.fields.ownerKey.value = "c".repeat(64); },
    record => { record.recordChangeTag = "different-tag"; }]) {
    const f = await publicFixture();
    try {
      const session = await f.session(), value = input(session), saved = await f.repository.write(value);
      change(f.model.records.get(saved.recordName)); await assert.rejects(() => recover(f, session, value)); assert.equal(creates(f), 1);
    } finally { f.close(); }
  }
});

test("same reporter recovers after session generation changes and after repository recreation", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session); await f.repository.write(value);
    await f.state.revokeAllSessions(session.sessionToken); const fresh = await f.session();
    assert.equal(fresh.accountID, session.accountID);
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
    const repository = new CloudKitPublicRepository({ registry, client: f.client, authentication: f.state, checkpoint: f.checkpoint, clock: f.clock });
    assert.equal((await repository.recoverAvatarReport({ requestID: value.requestID, accessToken: fresh.sessionToken, authorizeRead: () => true })).outcome, "accepted");
    assert.equal(creates(f), 1);
  } finally { f.close(); }
});

test("thirty-day photo-report retention survives backfill and retries and removes all content with the real processor", async () => {
  const f = await retentionFixture();
  try {
    const value = input(f.session), saved = await f.repository.write(value), dueAt = f.clock() + 30 * day;
    f.db.exec("DELETE FROM public_retention_v1"); assert.equal(f.registry.retentionSchedule().needsBackfill, true);
    assert.equal(await f.registry.backfillRetention(1), 1); assert.equal(f.db.prepare("SELECT due_at FROM public_retention_v1").get().due_at, dueAt);
    f.advance(day); const fresh = await f.refreshSession();
    assert.equal((await recover(f, fresh, value)).outcome, "accepted"); assert.equal(f.db.prepare("SELECT due_at FROM public_retention_v1").get().due_at, dueAt);
    f.advance(29 * day); assert.equal(f.registry.readable(saved.recordName, "avatarreport"), null);
    assert.deepEqual(await f.step(), { processed: 1 });
    assert.deepEqual(Object.keys(f.model.records.get(saved.recordName).fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
    const current = await f.refreshSession(); await assert.rejects(() => recover(f, current, value));
  } finally { f.close(); }
});

test("deleting the reporter erases its photo report without touching another account's report", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), other = await f.session("synthetic.other"), value = input(session), theirs = input(other);
    const ours = await f.repository.write(value), preserved = await f.repository.write(theirs);
    const ticket = await f.beginDeletion(session); await f.erase(ticket);
    assert.deepEqual(Object.keys(f.model.records.get(ours.recordName).fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    assert.deepEqual(f.model.records.get(preserved.recordName).fields, preserved.fields);
    await assert.rejects(() => recover(f, session, value));
  } finally { f.close(); }
});

test("reporter deletion during recovery lookup cannot settle or disclose the old pending result", async () => {
  const f = await publicFixture();
  try {
    const session = await f.session(), value = input(session);
    f.model.after = call => { if (call.operation === "modify") throw new Error("lost acknowledgement"); };
    await assert.rejects(() => f.repository.write(value));
    f.model.after = async call => { if (call.operation === "lookup") await f.state.disableAccount(session.accountID); };
    await assert.rejects(() => recover(f, session, value));
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "pending"); assert.equal(creates(f), 1);
  } finally { f.close(); }
});

test("read authorization withdrawn in the final checkpoint cannot return an accepted photo-report result", async () => {
  const f = await publicFixture(); let allowed = true;
  try {
    const session = await f.session(), value = input(session); await f.repository.write(value);
    f.model.afterCheckpoint = call => { if (call.operation === "modify") allowed = false; };
    await assert.rejects(() => recover(f, session, value, { authorizeRead: () => allowed }), publicCode("PUBLIC_SCOPE"));
    f.model.afterCheckpoint = undefined; allowed = true;
    assert.equal((await recover(f, session, value)).outcome, "accepted"); assert.equal(creates(f), 1);
  } finally { f.close(); }
});

test("cancelled recovery rejects a late provider result and leaves unknown report state available for a new explicit read", async () => {
  const f = await publicFixture(); let release, entered;
  const blocked = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  const controller = new AbortController(); let pending;
  try {
    const session = await f.session(), value = input(session);
    f.model.after = call => { if (call.operation === "modify") throw new Error("lost acknowledgement"); };
    await assert.rejects(() => f.repository.write(value)); f.model.after = undefined;
    f.model.before = async call => { if (call.operation === "lookup") { entered(); await blocked; } };
    pending = recover(f, session, value, { signal: controller.signal }); await started; controller.abort();
    await assert.rejects(() => pending); release(); await f.client.waitForPendingOperations();
    assert.equal(f.registry.owned(session.accountID, "avatarreport", value.requestID).phase, "pending");
    f.model.before = undefined; assert.equal((await recover(f, session, value)).outcome, "accepted"); assert.equal(creates(f), 1);
  } finally { release(); await f.client.waitForPendingOperations(); f.close(); }
});

test("thirty-day fencing prevents a delayed photo-report CREATE from resurrecting expired content", async () => {
  const f = await retentionFixture(); let release, entered, pending;
  const blocked = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
  try {
    const value = input(f.session);
    f.model.before = async call => {
      if (call.operation === "modify" && call.body.operations[0].record.fields.erased.value === 0) { entered(); await blocked; }
    };
    pending = f.repository.write(value); await started;
    f.advance(30 * day); assert.deepEqual(await f.step(), { processed: 1 });
    release(); await assert.rejects(() => pending);
    const name = recordIdentity(f.session.accountID, "avatarreport", value.requestID).recordName;
    assert.deepEqual(Object.keys(f.model.records.get(name).fields).sort(), ["erased", "ownerKey", "retentionKey", "schemaVersion"]);
    assert.equal(f.db.prepare("SELECT phase FROM public_records_v1").get().phase, "erased");
  } finally { release(); if (pending) await Promise.allSettled([pending]); await f.client.waitForPendingOperations(); f.close(); }
});
