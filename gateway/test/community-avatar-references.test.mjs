import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { avatarReadFixture } from "./support/avatar-read-fixture.mjs";
import { avatarHTTPFixture } from "./support/avatar-http-fixture.mjs";
import { CommunityCoordinator } from "../src/community-coordinator.mjs";
import { CommunityAvatarReferences } from "../src/community-avatar-references.mjs";
import { recordIdentity, digest } from "../src/public-record-schema.mjs";

const code = value => error => error?.code === value;
async function setup() {
  const f = await avatarReadFixture(); let enabled = true;
  const references = new CommunityAvatarReferences({ avatarPolicy: f.policy, communityState: f.social, clock: f.clock, isEnabled: () => enabled });
  const coordinator = new CommunityCoordinator({ state: f.social, authentication: f.state, repository: f.profiles,
    avatarReferences: references, cursorSecret: randomBytes(32).toString("base64url"), clock: f.clock });
  const prepare = (session, action, body = {}) => coordinator.prepare(action, body, { accessToken: session.sessionToken });
  const call = async (session, action, body = {}) => { const finalize = await prepare(session, action, body); await f.checkpoint.advance(); return finalize(); };
  await call(f.signedIn, "profile/save", { requestID: randomUUID(), name: "Maja", revision: null });
  const sent = await call(f.signedIn, "send", { requestID: randomUUID(), name: "Maja", text: "Test", coordinate: f.coordinate });
  return { ...f, publicationCall: f.call, references, prepare, call, sent, setEnabled(value) { enabled = value; } };
}

test("approved profile, map and message metadata contain only the selected version, with no asset IO", async () => {
  const f = await setup();
  try {
    const start = f.model.requests.length, asset = f.policy.readPublication(f.signedIn.accountID).avatar.recordName;
    const profile = await f.call(f.signedIn, "profile");
    const map = await f.call(f.viewer, "nearby", { coordinate: f.coordinate });
    const feed = await f.call(f.viewer, "messages", { coordinate: f.coordinate });
    assert.deepEqual(profile.profile, { name: "Maja", revision: profile.profile.revision, avatarVersionID: f.photo.versionID });
    assert.equal(map.users[0].avatarVersionID, f.photo.versionID);
    assert.equal(feed.messages[0].avatarVersionID, f.photo.versionID);
    assert.equal(feed.messages[0].id, f.sent.id);
    const serialized = JSON.stringify([profile, map, feed]);
    for (const secret of ["downloadURL", "receipt", "fileChecksum", "descriptor", "moderation", "pointerTag", "SYNTHETIC", asset]) assert.equal(serialized.includes(secret), false, secret);
    assert.equal(f.model.requests.slice(start).some(call => call.operation === "lookup" && call.body.records.some(row => row.recordName === asset)), false);
    assert.equal(f.downloads.length, 0);
    assert.equal(f.model.requests.slice(start).some(call => call.operation === "modify" && call.body.operations.some(row => row.record.recordType === "EchoesAvatarV1")), false);
  } finally { f.close(); }
});

test("own profile reference needs no active presence or coordinate, but a peer message loses its reference", async () => {
  const f = await setup();
  try {
    await f.call(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
    assert.equal((await f.call(f.signedIn, "profile")).profile.avatarVersionID, f.photo.versionID);
    const page = await f.call(f.viewer, "messages", { coordinate: f.coordinate });
    assert.equal(page.messages.length, 1); assert.equal(page.messages[0].avatarVersionID, null);
    assert.equal((await f.call(f.signedIn, "messages", { coordinate: f.coordinate })).messages[0].avatarVersionID, f.photo.versionID);
  } finally { f.close(); }
});

for (const state of ["none", "uploading", "pending", "rejected", "cleared"]) test(`photo ${state} is an explicit null and never exposes a pending version`, async () => {
  const f = await setup();
  try {
    if (state === "none") f.db.prepare("DELETE FROM avatar_profiles_v1 WHERE account_id=?").run(f.signedIn.accountID);
    else if (state === "cleared") await f.callCommunity(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
    if (state !== "none") {
      if (state === "cleared") await f.publicationCall("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.policy.snapshot(f.signedIn.accountID).generation }));
      else if (state === "uploading") await f.policy.select({ ...f.upload(), accountID: f.signedIn.accountID, sourceHash: digest(f.sourceBytes) });
      else if (state === "pending") await f.publicationCall("prepareUpload", f.upload());
      else await f.publicationCall("prepareReview", f.review(f.policy.snapshot(f.signedIn.accountID), "rejected"));
    }
    assert.equal((await f.call(f.signedIn, "profile")).profile.avatarVersionID, null);
  } finally { f.close(); }
});

test("a changed moderation decision after preparation strips the reference before the final response", async () => {
  const f = await setup();
  try {
    const finalize = await f.prepare(f.viewer, "nearby", { coordinate: f.coordinate });
    await f.publicationCall("prepareReview", f.review(f.policy.snapshot(f.signedIn.accountID), "rejected"));
    await f.checkpoint.advance(); const result = finalize();
    assert.equal(result.users.length, 1); assert.equal(result.users[0].avatarVersionID, null);
  } finally { f.close(); }
});

test("clear after feed preparation strips the old reference without deleting the message", async () => {
  const f = await setup();
  try {
    const finalize = await f.prepare(f.viewer, "messages", { coordinate: f.coordinate });
    await f.publicationCall("prepareClear", f.credentials({ requestID: randomUUID(), expectedGeneration: f.policy.snapshot(f.signedIn.accountID).generation }));
    await f.checkpoint.advance(); const result = finalize();
    assert.equal(result.messages.length, 1); assert.equal(result.messages[0].avatarVersionID, null);
  } finally { f.close(); }
});

test("a replacement never gets added to an already prepared response", async () => {
  const f = await setup();
  try {
    const finalize = await f.prepare(f.viewer, "nearby", { coordinate: f.coordinate });
    const next = await f.publicationCall("prepareUpload", f.upload());
    await f.publicationCall("prepareReview", f.review(next));
    const published = await f.publicationCall("preparePublish", f.credentials(f.publication()));
    await f.checkpoint.advance(); assert.equal(finalize().users[0].avatarVersionID, null);
    f.advance(3000);
    assert.equal((await f.call(f.viewer, "nearby", { coordinate: f.coordinate })).users[0].avatarVersionID, published.versionID);
  } finally { f.close(); }
});

for (const event of ["stop", "expiry", "block", "reverse-block", "suspend"]) test(`${event} after preparation cannot return a stale peer reference`, async () => {
  const f = await setup();
  try {
    if (event === "expiry") { f.advance(599990); f.viewer = await f.session("synthetic.reader"); }
    const map = await f.prepare(f.viewer, "nearby", { coordinate: f.coordinate });
    const feed = await f.prepare(f.viewer, "messages", { coordinate: f.coordinate });
    if (event === "stop") await f.call(f.signedIn, "stop", { requestID: randomUUID(), generation: 0 });
    if (event === "expiry") f.advance(11);
    if (event === "block") await f.call(f.viewer, "block", { requestID: randomUUID(), accountID: f.signedIn.accountID, blocked: true, generation: 0 });
    if (event === "reverse-block") await f.call(f.signedIn, "block", { requestID: randomUUID(), accountID: f.viewer.accountID, blocked: true, generation: 0 });
    if (event === "suspend") await f.social.setSuspended(f.signedIn.accountID, true);
    await f.checkpoint.advance();
    assert.equal(map().users.length, 0);
    const messages = feed().messages;
    if (["block", "reverse-block", "suspend"].includes(event)) assert.equal(messages.length, 0);
    else { assert.equal(messages.length, 1); assert.equal(messages[0].avatarVersionID, null); }
  } finally { f.close(); }
});

test("a far or newly moved author keeps a nearby message but cannot disclose its photo reference", async () => {
  const f = await setup();
  try {
    const finalize = await f.prepare(f.viewer, "messages", { coordinate: f.coordinate });
    f.advance(5000);
    await f.call(f.signedIn, "publish", f.presenceBody({ coordinate: { latitude: 52.2297, longitude: 21.0122 } }));
    const old = finalize(); assert.equal(old.messages.length, 1); assert.equal(old.messages[0].avatarVersionID, null);
    const fresh = await f.call(f.viewer, "messages", { coordinate: f.coordinate });
    assert.equal(fresh.messages.length, 1); assert.equal(fresh.messages[0].avatarVersionID, null);
  } finally { f.close(); }
});

test("an expired viewer session rejects the entire prepared response", async () => {
  const f = await setup();
  try {
    const finalize = await f.prepare(f.viewer, "nearby", { coordinate: f.coordinate });
    f.advance(600001);
    assert.throws(finalize, code("INVALID_SESSION"));
  } finally { f.close(); }
});

test("reference enrichment batches at most 25 pointers and reuses validated map presence", async () => {
  const viewerID = randomUUID(), ids = Array.from({ length: 100 }, () => randomUUID()), values = new Map(), presenceItems = new Map(), calls = [];
  const coordinate = { latitude: 51, longitude: 17 }, now = 1000;
  for (const id of ids) {
    const value = { accountID: id, versionID: randomUUID(), generation: 1, pointerTag: "tag", pointer: recordIdentity(id, "avatarprofile", "singleton") };
    values.set(id, value);
    presenceItems.set(id, { context: { accountID: id, kind: "presence" }, input: { ...coordinate, active: 1 }, record: { fields: { expiresAt: { value: now + 1000 } } } });
  }
  const lease = { accountID: viewerID, check() {}, current: () => true, async lookup(names, kind) {
    calls.push({ names, kind }); assert.equal(kind, "avatarprofile"); assert.ok(names.length <= 25);
    return names.map(name => {
      const value = [...values.values()].find(v => v.pointer.recordName === name); assert.ok(value);
      return { context: { accountID: value.accountID, kind }, input: { versionID: value.versionID, generation: 1 }, record: { recordChangeTag: "tag" } };
    });
  } };
  const references = new CommunityAvatarReferences({ clock: () => now, isEnabled: () => true, communityState: { visible: () => true, assertActive() {} },
    avatarPolicy: { readPublication: id => values.get(id), assertReadPublication: value => values.get(value.accountID) } });
  const finalize = await references.prepare({ lease, ownerIDs: ids, coordinate, presenceItems });
  assert.equal(calls.length, 4);
  assert.deepEqual(ids.map(finalize), ids.map(id => values.get(id).versionID));
  assert.equal(finalize(randomUUID()), null);
  await assert.rejects(references.prepare({ lease, ownerIDs: [...ids, randomUUID()], coordinate }), code("COMMUNITY_INPUT"));
  await assert.rejects(references.prepare({ lease, ownerIDs: [ids[0], ids[0]], coordinate }), code("COMMUNITY_INPUT"));
});

test("disabled metadata performs no pointer lookup; disabling after prepare returns null", async () => {
  const f = await setup();
  try {
    f.setEnabled(false); const start = f.model.requests.length;
    const map = await f.call(f.viewer, "nearby", { coordinate: f.coordinate });
    assert.equal(Object.hasOwn(map.users[0], "avatarVersionID"), false);
    const pointer = recordIdentity(f.signedIn.accountID, "avatarprofile", "singleton").recordName;
    assert.equal(f.model.requests.slice(start).some(call => call.operation === "lookup" && call.body.records.some(row => row.recordName === pointer)), false);
    f.setEnabled(true); f.advance(3000);
    const finalize = await f.prepare(f.viewer, "nearby", { coordinate: f.coordinate });
    f.setEnabled(false); assert.equal(finalize().users[0].avatarVersionID, null);
  } finally { f.close(); }
});

test("a corrupted provider pointer fails closed instead of trusting only local metadata", async () => {
  const f = await setup();
  try {
    const pointer = recordIdentity(f.signedIn.accountID, "avatarprofile", "singleton").recordName;
    f.model.records.get(pointer).fields.versionID.value = randomUUID();
    await assert.rejects(f.call(f.viewer, "nearby", { coordinate: f.coordinate }), code("PUBLIC_RESPONSE"));
  } finally { f.close(); }
});

test("the concrete runtime composes reference metadata only while avatar read is active", async () => {
  const f = await avatarHTTPFixture({ runtime: true });
  try {
    const request = () => new Request("https://echoes-authority.internal/v1/community/nearby", { method: "POST", headers: {
      "Content-Type": "application/json", Authorization: "Bearer " + f.viewer.sessionToken }, body: JSON.stringify({ coordinate: f.coordinate }) });
    const response = await f.authority.handle(request(), "a".repeat(64));
    assert.equal(response.status, 200); assert.equal((await response.json()).users[0].avatarVersionID, f.photo.versionID);
    f.env.AVATAR_READ_ENABLED = "0"; f.advance(3000);
    const disabled = await f.authority.handle(request(), "a".repeat(64));
    assert.equal(disabled.status, 200); assert.equal(Object.hasOwn((await disabled.json()).users[0], "avatarVersionID"), false);
  } finally { f.close(); }
});
