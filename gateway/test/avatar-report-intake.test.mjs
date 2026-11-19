import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { avatarReportFixture } from "./support/avatar-report-fixture.mjs";
import { avatarReportInput } from "../src/avatar-report-domain.mjs";
import { recordIdentity } from "../src/public-record-schema.mjs";
const code = value => error => error?.code === value;
const reports = f => [...f.model.records.values()].filter(record => record.recordType === "EchoesAvatarReportV1");
const pause = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const tick = () => new Promise(resolve => setImmediate(resolve));

test("intake derives exact current version generation and hash without downloading pixels or changing publication", async () => {
  const f = await avatarReportFixture();
  try {
    const before = f.policy.snapshot(f.signedIn.accountID), requestID = randomUUID(), result = await f.submit({ requestID });
    assert.equal(result.outcome, "accepted"); assert.equal(result.requestID, requestID); assert.equal(f.downloads.length, 0);
    const [record] = reports(f); assert.equal(record.fields.accountID.value, f.viewer.accountID);
    assert.equal(record.fields.avatarID.value, recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName);
    assert.equal(record.fields.imageSHA256.value, f.policy.readPublication(f.signedIn.accountID).descriptor.image.sha256);
    assert.equal(record.fields.publicationGeneration.value, before.generation);
    assert.deepEqual(f.policy.snapshot(f.signedIn.accountID), before);
    assert.equal(f.social.avatarReportIntent(f.viewer.accountID, requestID).ready, 1);
    assert.deepEqual(Object.keys(result).sort(), ["outcome", "reportID", "requestID", "schemaVersion"]);
  } finally { f.close(); }
});

test("intake denies self reporting old version far position and missing active presence before any report write", async () => {
  for (const mode of ["self", "old", "far", "hidden"]) {
    const f = await avatarReportFixture();
    try {
      const value = f.reportInput();
      if (mode === "self") value.ownerID = f.viewer.accountID;
      if (mode === "old") value.versionID = randomUUID();
      if (mode === "far") value.coordinate = { latitude: 0, longitude: 0 };
      if (mode === "hidden") await f.callCommunity(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
      await assert.rejects(() => f.reports.prepareSubmit(value), code(mode === "self" ? "AVATAR_REPORT_INPUT" : "AVATAR_REPORT_NOT_FOUND"));
      assert.equal(reports(f).length, 0); assert.equal(f.downloads.length, 0);
    } finally { f.close(); }
  }
});

test("both block directions prevent photo reporting and do not expose report or target data", async () => {
  for (const reverse of [false, true]) {
    const f = await avatarReportFixture();
    try {
      await f.callCommunity(reverse ? f.signedIn : f.viewer, "block", { requestID: randomUUID(),
        accountID: reverse ? f.viewer.accountID : f.signedIn.accountID, blocked: true, generation: 0 });
      await assert.rejects(() => f.submit(), code("AVATAR_REPORT_NOT_FOUND")); assert.equal(reports(f).length, 0);
    } finally { f.close(); }
  }
});

test("new reports require readable activation but exact own recovery remains available after read is disabled", async () => {
  const f = await avatarReportFixture();
  try {
    const requestID = randomUUID(); await f.submit({ requestID }); f.setReportsReadable(false);
    await assert.rejects(() => f.submit(), code("AVATAR_REPORT_UNAVAILABLE"));
    assert.equal((await f.recover(requestID)).outcome, "accepted"); assert.equal(reports(f).length, 1);
    f.disableReports(); await assert.rejects(() => f.recover(requestID), code("AVATAR_REPORT_UNAVAILABLE"));
  } finally { f.close(); }
});

test("disabled async and false activation never begin provider work", async () => {
  const f = await avatarReportFixture();
  try {
    const count = f.model.requests.length;
    for (const value of [false, Promise.resolve(true), Promise.reject(new Error("synthetic"))]) {
      await assert.rejects(() => f.makeReports({ isEnabled: () => value }).prepareSubmit(f.reportInput()), code("AVATAR_REPORT_UNAVAILABLE"));
    }
    assert.equal(f.model.requests.length, count); assert.equal(reports(f).length, 0);
  } finally { f.close(); }
});

test("malformed report subjects extra privileges and lone surrogates are rejected by the closed input", () => {
  const value = { requestID: randomUUID(), ownerID: randomUUID(), versionID: randomUUID(), reason: "reason", coordinate: { latitude: 0, longitude: 0 } };
  for (const change of [{ accountID: randomUUID() }, { generation: 8 }, { imageSHA256: "a".repeat(64) }, { role: "moderator" },
    { coordinate: null }, { reason: "\ud800" }, { reason: "a\udfff" }, { reason: "a".repeat(501) }]) assert.throws(() => avatarReportInput("submit", { ...value, ...change }), code("AVATAR_REPORT_INPUT"));
  assert.equal(avatarReportInput("submit", { ...value, reason: " Cafe\u0301 " }).reason, "Café");
  assert.equal(avatarReportInput("submit", { ...value, reason: "🎵" }).reason, "🎵");
});

test("photo report and message report share the durable anti-spam interval", async () => {
  const f = await avatarReportFixture();
  try {
    await f.submit();
    await assert.rejects(() => f.social.begin({ accountID: f.viewer.accountID, kind: "report", logicalID: randomUUID(),
      requestID: randomUUID(), payloadHash: "b".repeat(64) }), code("COMMUNITY_RATE_LIMITED"));
    await assert.rejects(() => f.submit(), code("AVATAR_REPORT_LIMIT"));
    f.advance(10000); await f.submit(); assert.equal(reports(f).length, 2);
  } finally { f.close(); }
});

test("lost acknowledgement recovers the same report and finishes the original private intent without a new create", async () => {
  const f = await avatarReportFixture();
  try {
    const requestID = randomUUID();
    f.model.after = call => { if (call.operation === "modify" && call.body.operations.some(op => op.record.recordType === "EchoesAvatarReportV1")) throw new Error("PRIVATE_LOST_ACK"); };
    await assert.rejects(() => f.submit({ requestID })); f.model.after = undefined;
    assert.equal(f.social.avatarReportIntent(f.viewer.accountID, requestID).ready, 0);
    const creates = f.model.requests.filter(call => call.operation === "modify").length;
    await f.call("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.photo.generation }));
    const recovered = await f.recover(requestID); assert.equal(recovered.outcome, "accepted");
    assert.equal(f.social.avatarReportIntent(f.viewer.accountID, requestID).ready, 1);
    assert.equal(f.model.requests.filter(call => call.operation === "modify" && call.body.operations.some(op => op.record.recordType === "EchoesAvatarReportV1")).length, 1);
    assert.ok(f.model.requests.filter(call => call.operation === "modify").length >= creates); assert.equal(reports(f).length, 1);
  } finally { f.close(); }
});

test("account disable during remote subject lookup cannot persist or return a report", async () => {
  const f = await avatarReportFixture();
  try {
    const avatarID = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
    f.model.after = async call => { if (call.operation === "lookup" && call.body.records.some(item => item.recordName === avatarID)) await f.state.disableAccount(f.viewer.accountID); };
    await assert.rejects(() => f.submit(), code("AVATAR_REPORT_SCOPE")); assert.equal(reports(f).length, 0);
  } finally { f.close(); }
});

test("late response after cancellation retains one admission until actual provider drain and cannot create a report", async () => {
  const f = await avatarReportFixture(), entered = pause(), released = pause(), controller = new AbortController();
  try {
    const avatarID = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
    f.model.before = async call => { if (call.operation === "lookup" && call.body.records.some(item => item.recordName === avatarID)) { entered.resolve(); await released.promise; } };
    const pending = f.reports.prepareSubmit(f.reportInput({ signal: controller.signal })).catch(error => error);
    await entered.promise; controller.abort(); assert.equal((await pending).code, "AVATAR_REPORT_UNAVAILABLE");
    assert.equal(f.reports.isOccupied, true); await assert.rejects(() => f.submit(), code("AVATAR_REPORT_LIMIT"));
    released.resolve(); await f.reports.waitForPendingOperations(); f.model.before = undefined;
    assert.equal(f.reports.isOccupied, false); assert.equal(reports(f).length, 0); await f.submit();
  } finally { released.resolve(); await f.reports.waitForPendingOperations(); await tick(); f.close(); }
});

test("server rejects corrupted exact avatar and publication commitments without a report write", async () => {
  for (const change of [record => record.fields.imageSha256.value = "a".repeat(64), record => record.fields.versionID.value = randomUUID(), record => record.recordChangeTag = "forged-tag"]) {
    const f = await avatarReportFixture();
    try {
      const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
      change(f.model.records.get(name));
      await assert.rejects(() => f.submit(), code("AVATAR_REPORT_CONFLICT")); assert.equal(reports(f).length, 0);
    } finally { f.close(); }
  }
});

test("a block applied during report CREATE or after preparation withholds acceptance; recovery never makes another create", async () => {
  for (const when of ["write", "final"]) {
    const f = await avatarReportFixture();
    try {
      const block = async () => f.callCommunity(f.signedIn, "block", { requestID: randomUUID(), accountID: f.viewer.accountID, blocked: true, generation: 0 });
      const requestID = randomUUID();
      if (when === "write") {
        f.model.after = async call => { if (call.operation === "modify" && call.body.operations.some(op => op.record.recordType === "EchoesAvatarReportV1")) { f.model.after = undefined; await block(); } };
        await assert.rejects(() => f.submit({ requestID }), code("AVATAR_REPORT_NOT_FOUND"));
      } else {
        const final = await f.reports.prepareSubmit(f.reportInput({ requestID })); await block();
        assert.throws(final, code("AVATAR_REPORT_NOT_FOUND"));
      }
      assert.equal(reports(f).length, 1); assert.equal((await f.recover(requestID)).outcome, "accepted");
      assert.equal(f.model.requests.filter(call => call.operation === "modify" && call.body.operations.some(op => op.record.recordType === "EchoesAvatarReportV1")).length, 1);
    } finally { f.close(); }
  }
});

test("submit and recovery finalizers reject a report that expires after preparation", async () => {
  for (const action of ["submit", "recover"]) {
    const f = await avatarReportFixture();
    try {
      const requestID = randomUUID(); await f.submit({ requestID });
      f.advance(30 * 86400000 - 1000);
      const reporter = await f.session("synthetic.reader"), owner = await f.session();
      await f.callCommunity(owner, "publish", f.presenceBody());
      const final = await (action === "submit" ? f.reports.prepareSubmit(f.reportInput({ requestID, accessToken: reporter.sessionToken })) : f.reports.prepareRecovery({ accessToken: reporter.sessionToken, requestID }));
      f.advance(1000);
      assert.throws(final, code("AVATAR_REPORT_CONFLICT"));
    } finally { f.close(); }
  }
});

test("same intent changed reason conflicts and retries cannot extend original retention", async () => {
  const f = await avatarReportFixture();
  try {
    const requestID = randomUUID(), first = await f.submit({ requestID }), expiry = f.db.prepare("SELECT due_at FROM public_retention_v1 WHERE record_name=?").get(first.reportID).due_at;
    await assert.rejects(() => f.submit({ requestID, reason: "different" }), code("AVATAR_REPORT_CONFLICT"));
    assert.equal((await f.submit({ requestID })).reportID, first.reportID);
    assert.equal(reports(f).length, 1); assert.equal(f.db.prepare("SELECT due_at FROM public_retention_v1 WHERE record_name=?").get(first.reportID).due_at, expiry);
  } finally { f.close(); }
});

test("clock rollback and real deadline with frozen clocks cannot release late acceptance", async () => {
  for (const mode of ["rollback", "deadline"]) {
    const f = await avatarReportFixture(), entered = pause(), release = pause();
    let wall = f.clock();
    const actor = f.makeReports({ clock: () => wall, monotonic: () => 1, timeoutMilliseconds: mode === "deadline" ? 500 : 8000 });
    try {
      const name = recordIdentity(f.signedIn.accountID, "avatar", f.photo.versionID).recordName;
      f.model.before = async call => { if (call.operation === "lookup" && call.body.records.some(r => r.recordName === name)) { entered.resolve(); await release.promise; } };
      const pending = actor.prepareSubmit(f.reportInput()).catch(error => error); await Promise.race([entered.promise, pending.then(() => assert.fail("Clock proof did not reach held provider"))]);
      if (mode === "rollback") { wall--; release.resolve(); }
      assert.equal((await pending).code, "AVATAR_REPORT_UNAVAILABLE");
      if (mode === "deadline") assert.equal(actor.isOccupied, true);
      release.resolve(); await actor.waitForPendingOperations(); assert.equal(reports(f).length, 0);
    } finally { release.resolve(); await actor.waitForPendingOperations(); f.close(); }
  }
});

test("unconfirmed provider drain latches the actor closed and an old finalizer cannot free a new operation", async () => {
  const f = await avatarReportFixture();
  try {
    const final = await f.reports.prepareSubmit(f.reportInput()); final(); f.advance(10000);
    const fresh = await f.reports.prepareSubmit(f.reportInput()); assert.throws(final, code("AVATAR_REPORT_UNAVAILABLE"));
    assert.equal(f.reports.isOccupied, true); fresh(); assert.equal(f.reports.isOccupied, false);
    const actor = f.makeReports({ client: { lookup: (...args) => f.client.lookup(...args), async waitForPendingOperations() { throw Error("PRIVATE_UNCONFIRMED_DRAIN"); } } });
    await assert.rejects(() => actor.prepareRecovery({ accessToken: f.viewer.sessionToken, requestID: randomUUID() }), code("AVATAR_REPORT_UNAVAILABLE"));
    assert.equal(actor.isOccupied, true); const before = f.model.requests.length;
    await assert.rejects(() => actor.prepareRecovery({ accessToken: f.viewer.sessionToken, requestID: randomUUID() }), code("AVATAR_REPORT_LIMIT"));
    await assert.rejects(() => actor.waitForPendingOperations(), code("AVATAR_REPORT_UNAVAILABLE")); assert.equal(f.model.requests.length, before);
  } finally { f.close(); }
});
