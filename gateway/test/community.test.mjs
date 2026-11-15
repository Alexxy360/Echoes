import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { publicFixture, publicCode } from "./support/public-record-fixture.mjs";
import { hash } from "./support/authentication-fixture.mjs";
import { CommunityState } from "../src/community-state.mjs";
import { CommunityCoordinator } from "../src/community-coordinator.mjs";
import { CommunityCursor, CommunityError, approximateLocation, distanceMeters } from "../src/community-domain.mjs";
import { createGatewayHTTPHandler } from "../src/gateway-http.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";

const center = { latitude: 51.1123456, longitude: 17.0345678 };
const far = { latitude: 52.2297, longitude: 21.0122 };
const code = expected => error => error?.code === expected;
async function setup(options) {
  const f = await publicFixture(options), social = new CommunityState(f.storage, { clock: f.clock });
  const secret = randomBytes(32).toString("base64url");
  const community = new CommunityCoordinator({ state: social, authentication: f.state, repository: f.repository, cursorSecret: secret, clock: f.clock });
  const prepare = (session, action, body = {}) => community.prepare(action, body, { accessToken: session.sessionToken });
  const call = async (session, action, body = {}) => { const finalize = await prepare(session, action, body); await f.checkpoint.advance(); return finalize(); };
  const sendBody = (text = "Wiadomość testowa", coordinate = center) => ({ requestID: randomUUID(), name: "Maja", text, coordinate });
  const publishBody = (generation = 0, coordinate = center) => ({ requestID: randomUUID(), name: "Maja", coordinate, song: "", songID: "", generation, measuredAt: f.clock() });
  return { ...f, social, community, secret, prepare, call, sendBody, publishBody };
}
function pause() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
function presenceModify(call, active) { return call.operation === "modify" && call.body.operations[0]?.record.recordType === "EchoesPresenceV1" && call.body.operations[0].record.fields.active?.value === active; }

test("community uses the original 500 m approximation, including dateline and poles, and stores no exact GPS in either authority or CloudKit", async () => {
  const f = await setup();
  try {
    const author = await f.session(), reader = await f.session("reader");
    await f.call(author, "publish", f.publishBody());
    const nearby = await f.call(reader, "nearby", { coordinate: center });
    assert.equal(nearby.users.length, 1); assert.equal(nearby.users[0].id, author.accountID);
    const location = approximateLocation(center); assert.deepEqual({ latitude: nearby.users[0].latitude, longitude: nearby.users[0].longitude }, location);
    assert.ok(distanceMeters(center, location) < 400); assert.notEqual(location.latitude, center.latitude);
    const serializedSQL = JSON.stringify(f.db.prepare("SELECT * FROM community_intents_v1").all()) + JSON.stringify(f.db.prepare("SELECT * FROM community_accounts_v1").all());
    for (const value of ["Maja", String(center.latitude), String(center.longitude)]) assert.equal(serializedSQL.includes(value), false);
    assert.equal(JSON.stringify([...f.model.records.values()]).includes(String(center.latitude)), false);
    const query = f.model.requests.find(call => call.operation === "query");
    assert.deepEqual(query.body.query.filterBy[0].fieldValue.value, location);
    for (const coordinate of [{ latitude: 0, longitude: 179.9999 }, { latitude: 90, longitude: 179 }, { latitude: -90, longitude: -179 }]) {
      assert.ok(distanceMeters(coordinate, approximateLocation(coordinate)) < 400);
    }
    assert.ok(distanceMeters({ latitude: 0, longitude: 179.999 }, { latitude: 0, longitude: -179.999 }) < 300);
    // At the dateline, wrapping a longitude on the original adaptive grid is not idempotent.
    // Reading must validate the exact original payload rather than coarsening its coordinate again.
    f.advance(5000); const wrapped = { latitude: -88.0279999999999, longitude: 179.98800000000006 };
    const sent = await f.call(author, "send", f.sendBody("Dateline", wrapped));
    assert.deepEqual((await f.call(reader, "messages", { coordinate: wrapped })).messages.map(row => row.id), [sent.id]);
  } finally { f.close(); }
});

test("visibility stop advances generation, removes content, is idempotent and rejects an old publish", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), first = f.publishBody();
    await f.call(a, "publish", first);
    const stop = { requestID: randomUUID(), generation: 0 };
    const stopped = await f.call(a, "stop", stop); assert.equal(stopped.generation, 1); assert.equal(stopped.visible, false);
    assert.equal((await f.call(a, "stop", stop)).generation, 1);
    const record = f.model.records.get(stopped.id);
    for (const key of ["name", "latitude", "longitude", "location", "song", "songID"]) assert.equal(Object.hasOwn(record.fields, key), false);
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 0);
    await assert.rejects(() => f.call(a, "publish", first), code("COMMUNITY_STALE"));
    f.advance(5000); await f.call(a, "publish", f.publishBody(1));
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 1);
    await assert.rejects(() => f.call(a, "stop", stop), code("COMMUNITY_STALE"));
  } finally { f.close(); }
});

for (const phase of ["before", "after"]) test(`stop wins over an in-flight publish paused ${phase} CloudKit applies it`, async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), entered = pause(), resume = pause(); let held = false;
    f.model[phase] = async call => { if (!held && presenceModify(call, 1)) { held = true; entered.resolve(); await resume.promise; } };
    const publishing = f.call(a, "publish", f.publishBody()); const outcome = publishing.catch(error => error);
    await entered.promise;
    const stopped = await f.call(a, "stop", { requestID: randomUUID(), generation: 0 });
    resume.resolve(); assert.equal((await outcome).code, "COMMUNITY_STALE");
    assert.equal(f.model.records.get(stopped.id).fields.active.value, 0);
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 0);
  } finally { f.close(); }
});

test("a late stop cannot clear a newer generation even when its old conditional write was already dispatched", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"); await f.call(a, "publish", f.publishBody());
    const entered = pause(), resume = pause(); let held = false;
    f.model.before = async call => { if (!held && presenceModify(call, 0)) { held = true; entered.resolve(); await resume.promise; } };
    const stopping = f.call(a, "stop", { requestID: randomUUID(), generation: 0 }).catch(error => error);
    await entered.promise; assert.equal((await f.call(a, "visibility")).generation, 1);
    f.advance(5000); await f.call(a, "publish", f.publishBody(1)); resume.resolve();
    assert.equal((await stopping).code, "COMMUNITY_STALE");
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 1);
  } finally { f.close(); }
});

test("latest-intent slots recover unknown CloudKit outcomes; incomplete publication stays hidden", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"); let lost = false;
    f.model.after = call => { if (!lost && presenceModify(call, 1)) { lost = true; throw new Error("PRIVATE-PROVIDER-DETAIL"); } };
    await assert.rejects(() => f.call(a, "publish", f.publishBody()), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 0);
    const stopped = await f.call(a, "stop", { requestID: randomUUID(), generation: 0 });
    assert.equal(stopped.visible, false); assert.equal(f.model.records.get(stopped.id).fields.active.value, 0);
    f.advance(5000); await f.call(a, "publish", f.publishBody(1));
    assert.equal((await f.call(b, "nearby", { coordinate: center })).users.length, 1);
  } finally { f.close(); }
});

test("bidirectional blocks apply before provider acknowledgement and invalidate an already prepared read", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"); const sent = await f.call(a, "send", f.sendBody());
    const pendingRead = await f.prepare(b, "messages", { coordinate: center, knownIDs: [sent.id] });
    f.model.before = call => { if (call.operation === "modify" && call.body.operations[0].record.recordType === "EchoesBlockV1") throw new Error("lost"); };
    await assert.rejects(() => f.call(a, "block", { requestID: randomUUID(), accountID: b.accountID, blocked: true }), publicCode("PUBLIC_UNAVAILABLE"));
    const read = pendingRead(); assert.equal(read.messages.length, 0); assert.deepEqual(read.removedIDs, [sent.id]);
    assert.deepEqual((await f.call(a, "blocked")).accountIDs, [b.accountID]);
    f.model.before = undefined; f.advance(1000);
    await f.call(a, "block", { requestID: randomUUID(), accountID: b.accountID, blocked: false });
    assert.equal((await f.call(b, "messages", { coordinate: center })).messages.length, 1);
    await f.call(b, "send", f.sendBody("Wiadomość czytelnika"));
    f.advance(1000); await f.call(b, "block", { requestID: randomUUID(), accountID: a.accountID, blocked: true });
    assert.deepEqual((await f.call(a, "messages", { coordinate: center })).messages.map(row => row.id), [sent.id]);
  } finally { f.close(); }
});

test("final read rechecks moderation, author account, viewer session and expiration", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), body = f.sendBody(); await f.call(a, "send", body);
    let finalize = await f.prepare(b, "messages", { coordinate: center });
    await f.social.hideMessage(a.accountID, body.requestID); assert.equal(finalize().messages.length, 0);
    f.advance(5000); await f.call(a, "send", f.sendBody());
    finalize = await f.prepare(b, "messages", { coordinate: center });
    await f.social.setSuspended(a.accountID, true); assert.equal(finalize().messages.length, 0);
    await f.social.setSuspended(a.accountID, false); f.advance(1000);
    finalize = await f.prepare(b, "messages", { coordinate: center });
    await f.state.disableAccount(a.accountID); assert.equal(finalize().messages.length, 0);
    f.advance(1000); finalize = await f.prepare(b, "messages", { coordinate: center });
    await f.state.revokeAllSessions(b.sessionToken); assert.throws(finalize, code("INVALID_SESSION"));
  } finally { f.close(); }
});

test("125 messages paginate without duplicates, cursor plaintext, new arrivals or exposing distant content", async () => {
  const f = await setup();
  try {
    let a = await f.session(); const ids = [];
    for (let i = 0; i < 125; i++) {
      if (i && i % 50 === 0) a = await f.session();
      ids.push((await f.call(a, "send", f.sendBody("Tekst " + i))).id); f.advance(5000);
    }
    const b = await f.session("reader");
    const distant = await f.call(a, "send", f.sendBody("Distant private content", far));
    const first = await f.call(b, "messages", { coordinate: center });
    assert.equal(first.messages.length, 50); assert.ok(first.cursor); assert.equal(first.messages.some(row => row.id === distant.id), false);
    assert.equal(Buffer.from(first.cursor.slice(3), "base64url").includes(Buffer.from("community-v1-message-")), false);
    f.advance(5000); const newcomer = await f.call(a, "send", f.sendBody("New after cutoff"));
    const second = await f.call(b, "messages", { coordinate: center, cursor: first.cursor }); assert.equal(second.messages.length, 50);
    f.advance(1000); const third = await f.call(b, "messages", { coordinate: center, cursor: second.cursor });
    assert.equal(third.messages.length, 25); assert.equal(third.cursor, null);
    const received = [...third.messages, ...second.messages, ...first.messages].map(row => row.id);
    assert.equal(new Set(received).size, 125); assert.deepEqual(new Set(received), new Set(ids)); assert.equal(received.includes(newcomer.id), false);
    const before = f.model.requests.length;
    await assert.rejects(() => f.call(a, "messages", { coordinate: center, cursor: first.cursor }), code("COMMUNITY_CURSOR"));
    await assert.rejects(() => f.call(b, "messages", { coordinate: far, cursor: first.cursor }), code("COMMUNITY_CURSOR"));
    const tampered = first.cursor.slice(0, -3) + (first.cursor.at(-3) === "A" ? "B" : "A") + first.cursor.slice(-2);
    await assert.rejects(() => f.call(b, "messages", { coordinate: center, cursor: tampered }), code("COMMUNITY_CURSOR"));
    assert.equal(f.model.requests.length, before);
    f.advance(300000); await assert.rejects(() => f.call(b, "messages", { coordinate: center, cursor: first.cursor }), code("COMMUNITY_CURSOR"));
  } finally { f.close(); }
});

test("known message IDs are removed after movement, expiry, deletion or moderation, without accepting another record kind", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), sent = await f.call(a, "send", f.sendBody());
    const moved = await f.call(b, "messages", { coordinate: far, knownIDs: [sent.id] }); assert.deepEqual(moved.removedIDs, [sent.id]);
    f.advance(1000); const prepared = await f.prepare(b, "messages", { coordinate: center, knownIDs: [sent.id] });
    f.model.records.delete(sent.id); // The current prepared record is rechecked against policy, not an impossible synchronous network snapshot.
    await f.beginDeletion(a); assert.deepEqual(prepared().removedIDs, [sent.id]);
    f.advance(1000); assert.deepEqual((await f.call(b, "messages", { coordinate: center, knownIDs: [sent.id] })).removedIDs, [sent.id]);
    await assert.rejects(() => f.call(b, "messages", { coordinate: center, knownIDs: [sent.id.replace("message", "profile")] }), code("COMMUNITY_INPUT"));
  } finally { f.close(); }
});

test("rates, message idempotency, immutable payloads, moderation and profile CAS are enforced by the service", async () => {
  const f = await setup();
  try {
    const a = await f.session(), body = f.sendBody(), first = await f.call(a, "send", body);
    assert.equal((await f.call(a, "send", body)).id, first.id);
    await assert.rejects(() => f.call(a, "send", { ...body, text: "different" }), code("COMMUNITY_STALE"));
    await assert.rejects(() => f.call(a, "send", f.sendBody()), code("COMMUNITY_RATE_LIMITED"));
    for (const text of ["zabij\u200b się", "KILL YOURSELF", "a".repeat(30), "bad\u202etext", "\ud800"]) await assert.rejects(() => f.call(a, "send", f.sendBody(text)), error => error instanceof CommunityError);
    await assert.rejects(() => f.call(a, "send", { ...body, accountID: randomUUID() }), code("COMMUNITY_INPUT"));
    assert.equal((await f.call(a, "profile")).profile, null);
    const created = await f.call(a, "profile/save", { requestID: randomUUID(), name: "Profil", revision: null });
    assert.deepEqual((await f.call(a, "profile")).profile, { name: "Profil", revision: created.revision });
    const changed = await f.call(a, "profile/save", { requestID: randomUUID(), name: "Nowa nazwa", revision: created.revision });
    await assert.rejects(() => f.call(a, "profile/save", { requestID: randomUUID(), name: "Stara edycja", revision: created.revision }), publicCode("PUBLIC_CONFLICT"));
    assert.equal((await f.call(a, "profile")).profile.revision, changed.revision);
    await assert.rejects(() => f.call(a, "block", { requestID: randomUUID(), accountID: a.accountID, blocked: true }), code("COMMUNITY_INPUT"));
  } finally { f.close(); }
});

test("reports require currently readable messages, stay confidential and may quote abusive content", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), message = await f.call(a, "send", f.sendBody());
    const body = { requestID: randomUUID(), messageID: message.id, reason: "Napisał: kill yourself", coordinate: center };
    await assert.rejects(() => f.call(b, "report", { ...body, coordinate: far }), code("COMMUNITY_NOT_FOUND"));
    assert.equal((await f.call(b, "report", body)).accepted, true);
    assert.equal((await f.call(b, "report", body)).accepted, true);
    await assert.rejects(() => f.call(b, "report", { ...body, requestID: randomUUID() }), code("COMMUNITY_RATE_LIMITED"));
    const data = JSON.stringify(await f.call(a, "messages", { coordinate: center })); assert.equal(data.includes(body.reason), false);
    assert.equal(data.includes(b.accountID), false);
    const prepared = f.prepare(b, "report", { ...body, requestID: randomUUID() });
    await assert.rejects(prepared, code("COMMUNITY_RATE_LIMITED"));
  } finally { f.close(); }
});

test("regional capacity exhaustion is an error rather than a false empty or partial result", async () => {
  const f = await setup();
  try {
    const b = await f.session(); let queries = 0;
    f.model.before = call => call.operation === "query" ? (++queries, Response.json({ records: [], continuationMarker: "more" })) : undefined;
    await assert.rejects(() => f.call(b, "nearby", { coordinate: center }), code("COMMUNITY_CAPACITY")); assert.equal(queries, 16);
    queries = 0; await assert.rejects(() => f.call(b, "messages", { coordinate: center }), code("COMMUNITY_CAPACITY")); assert.equal(queries, 16);
  } finally { f.close(); }
});

test("stale/forged indexed candidates are not disclosure authority; exact content and tag must match", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), message = await f.call(a, "send", f.sendBody());
    const saved = structuredClone(f.model.records.get(message.id));
    f.model.before = call => {
      if (call.operation === "query") return Response.json({ records: [{ ...saved, fields: { ownerKey: saved.fields.ownerKey } }] });
      if (call.operation === "lookup") return Response.json({ records: [{ ...saved, fields: { ...saved.fields, text: { type: "STRING", value: "forged" } } }] });
    };
    await assert.rejects(() => f.call(b, "messages", { coordinate: center }), publicCode("PUBLIC_RESPONSE"));
    f.model.before = call => call.operation === "query" ? Response.json({ records: [{ ...saved, recordName: "community-v1-message-" + "f".repeat(64), fields: {} }] }) : undefined;
    f.advance(1000); assert.equal((await f.call(b, "messages", { coordinate: center })).messages.length, 0);
  } finally { f.close(); }
});

test("closed HTTP finalizes after the last checkpoint and rejects forged fields, extra routes, browser origin and disabled feature", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), sent = await f.call(a, "send", f.sendBody()); let enabled = true;
    const handler = createGatewayHTTPHandler({ authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
      community: f.community, isCommunityEnabled: () => enabled, limits: new GatewayLimits(f.storage, { clock: f.clock }), scheduleMaintenance: async () => {},
      isEnabled: () => true, checkpoint: f.checkpoint });
    const http = (action, body, extra = {}) => handler(new Request("https://echoes-authority.internal/v1/community/" + action, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + b.sessionToken, ...extra }, body: JSON.stringify(body) }), hash("network"));
    let blocked = false;
    f.model.afterCheckpoint = async call => {
      if (!blocked && call.operation === "modify") { blocked = true; await f.social.begin({ accountID: a.accountID, kind: "block", logicalID: b.accountID,
        requestID: randomUUID(), payloadHash: "a".repeat(64), active: true }); }
    };
    const response = await http("messages", { coordinate: center, knownIDs: [sent.id] });
    assert.equal(response.status, 200); const body = await response.json(); assert.deepEqual(body.messages, []); assert.deepEqual(body.removedIDs, [sent.id]);
    assert.equal(response.headers.get("Cache-Control"), "no-store"); assert.equal(response.headers.has("Access-Control-Allow-Origin"), false);
    assert.equal((await http("messages", { coordinate: center, accountID: a.accountID })).status, 400);
    assert.equal((await http("records/lookup", {})).status, 404);
    assert.equal((await http("report/read", {})).status, 404);
    assert.equal((await http("config", {}, { Origin: "https://evil.invalid" })).status, 403);
    enabled = false; const before = f.model.checkpointRequests.length;
    assert.equal((await http("config", {})).status, 503); assert.equal(f.model.checkpointRequests.length, before);
  } finally { f.close(); }
});

test("3 km is checked on the server after the wider coarse index query, and expiration is checked again at disclosure", async () => {
  const f = await setup();
  try {
    const a = await f.session(), origin = { latitude: 0, longitude: 0 }, sent = await f.call(a, "send", f.sendBody("Origin", origin));
    f.advance(7199000); const b = await f.session("reader");
    const near = { latitude: 2990 / 6371000 * 180 / Math.PI, longitude: 0 };
    const outside = { latitude: 3010 / 6371000 * 180 / Math.PI, longitude: 0 };
    const finalize = await f.prepare(b, "messages", { coordinate: near, knownIDs: [sent.id] }); assert.equal(finalize().messages.length, 1);
    // A second account has a separate read rate but the same regional policy.
    const c = await f.session("other.reader");
    assert.deepEqual((await f.call(c, "messages", { coordinate: outside, knownIDs: [sent.id] })).removedIDs, [sent.id]);
    f.advance(1000);
    assert.equal(finalize().messages.length, 0); assert.deepEqual(finalize().removedIDs, [sent.id]);
  } finally { f.close(); }
});

test("public presence expires at ten minutes even when a fresh viewer prepared its response beforehand", async () => {
  const f = await setup();
  try {
    const a = await f.session(); await f.call(a, "publish", f.publishBody());
    f.advance(599000); const b = await f.session("reader");
    const finalize = await f.prepare(b, "nearby", { coordinate: center }); assert.equal(finalize().users.length, 1);
    f.advance(1000); assert.deepEqual(finalize().users, []);
    assert.equal(f.model.records.size, 1); // Hidden expiry is explicitly not physical TTL deletion.
  } finally { f.close(); }
});

test("block capacity is bounded and read rates belong to accounts rather than access tokens", async () => {
  const f = await setup();
  try {
    const a = await f.session(), targets = [];
    for (let i = 0; i < 200; i++) {
      const target = randomUUID(); targets.push(target);
      await f.social.begin({ accountID: a.accountID, kind: "block", logicalID: target, requestID: randomUUID(), payloadHash: "a".repeat(64) }); f.advance(1000);
    }
    await assert.rejects(() => f.social.begin({ accountID: a.accountID, kind: "block", logicalID: randomUUID(), requestID: randomUUID(), payloadHash: "a".repeat(64) }), code("COMMUNITY_CAPACITY"));
    await f.social.begin({ accountID: a.accountID, kind: "block", logicalID: targets[0], requestID: randomUUID(), payloadHash: "b".repeat(64), active: false });
    assert.equal(f.social.blocked(a.accountID).length, 199);
    await f.call(a, "nearby", { coordinate: center }); const next = await f.session();
    await assert.rejects(() => f.call(next, "nearby", { coordinate: center }), code("COMMUNITY_RATE_LIMITED"));
    const b = await f.session("reader"); assert.deepEqual((await f.call(b, "nearby", { coordinate: center })).users, []);
  } finally { f.close(); }
});

test("unknown message response retries reconcile exactly one immutable record and preserve original timestamp", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader"), body = f.sendBody(); let lost = false;
    f.model.after = call => { if (!lost && call.operation === "modify" && call.body.operations[0].record.recordType === "EchoesLocalMessageV1") { lost = true; throw new Error("lost"); } };
    await assert.rejects(() => f.call(a, "send", body), publicCode("PUBLIC_UNAVAILABLE"));
    assert.equal((await f.call(b, "messages", { coordinate: center })).messages.length, 0);
    const timestamp = f.clock(); f.advance(5000); const acknowledgement = await f.call(a, "send", body);
    const messages = (await f.call(b, "messages", { coordinate: center })).messages;
    assert.equal(f.model.records.size, 1); assert.equal(messages.length, 1); assert.equal(messages[0].timestamp, timestamp);
    assert.deepEqual(acknowledgement.message, messages[0]);
    assert.deepEqual((await f.call(a, "send", body)).message, messages[0]);
  } finally { f.close(); }
});

test("metadata owner erasure removes only that owner's policy and preserves other owners' blocks", async () => {
  const f = await setup();
  try {
    const a = await f.session(), b = await f.session("reader");
    await f.call(a, "send", f.sendBody());
    await f.call(a, "block", { requestID: randomUUID(), accountID: b.accountID, blocked: true });
    await f.call(b, "block", { requestID: randomUUID(), accountID: a.accountID, blocked: true });
    await assert.rejects(() => f.social.eraseOwner(a.accountID), code("COMMUNITY_STALE"));
    const deletion = await f.beginDeletion(a); await f.erase(deletion); await f.social.eraseOwner(a.accountID);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_intents_v1 WHERE account_id=?").get(a.accountID).n, 0);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM community_accounts_v1 WHERE account_id=?").get(a.accountID).n, 0);
    assert.deepEqual(f.social.blocked(b.accountID), [a.accountID]);
  } finally { f.close(); }
});
