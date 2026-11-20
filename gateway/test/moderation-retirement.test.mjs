import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { reportReviewFixture } from "./support/community-report-review-fixture.mjs";
import { avatarReportReviewFixture } from "./support/avatar-report-review-fixture.mjs";
import { purgeModerationRetirements, moderationRetirementWakeAt } from "../src/moderation-decision-retirements.mjs";
import { digest } from "../src/public-record-schema.mjs";
const barrier = () => { let release; const promise = new Promise(r => { release = r; }); return { promise, release }; };
async function setup(t, domain, options = {}) {
  const photo = domain === "photo", f = await (photo ? avatarReportReviewFixture(t, options) : reportReviewFixture(t, options));
  const metadata = photo ? (await f.inspection()).metadata : await f.inspect();
  const verdict = photo ? "hide_photo" : "hide_message", table = (photo ? "avatar" : "community") + "_report_decision_retirements_v1";
  const query = (changes = {}) => ({ reportID: metadata.reportID, decisionID: randomUUID(), verdict, contentHash: metadata.contentHash, ...changes });
  return { ...f, metadata, table, query, photo,
    retire: q => f.review.prepareRetirement(f.options(q)).then(final => final()),
    recover: q => f.review.prepareRecovery(f.options(q)).then(final => final()),
    decide: q => f.review.prepareDecision(f.options({ inspectionID: metadata.inspectionID, decisionID: q.decisionID, verdict: q.verdict })).then(final => final()),
    rows: () => f.storage.sql.exec(`SELECT * FROM ${table}`).toArray(),
    effect: () => photo ? f.policy.snapshot(f.signedIn.accountID).status === "rejected" : f.storage.sql.exec("SELECT hidden FROM community_intents_v1 WHERE kind='message' AND account_id=?", f.author.accountID).toArray()[0].hidden === 1,
    communityPolicy: photo ? f.social : f.community, reporterIdentity: photo ? f.viewer : f.reporter,
    operatorSubject: photo ? "synthetic.photo.report.operator" : "operator", reporterSubject: photo ? "synthetic.reader" : "reporter"
  };
}
for (const domain of ["message", "photo"]) {
  test(domain + " retirement seals an own delayed decision without closing its report or hiding content", async t => {
    const f = await setup(t, domain), q = f.query();
    assert.equal((await f.recover(q)).outcome, "not-applied"); assert.equal(f.rows().length, 0);
    assert.equal((await f.retire(q)).outcome, "retired"); assert.equal((await f.recover(q)).outcome, "retired");
    await assert.rejects(f.decide(q), e => e.code.endsWith("_STALE")); assert.equal(f.effect(), false);
    const next = f.photo ? (await f.inspection()).metadata : await f.inspect();
    const result = (await f.review.prepareDecision(f.options({ inspectionID: next.inspectionID, decisionID: randomUUID(), verdict: q.verdict })))();
    assert.equal(result.verdict, q.verdict); assert.equal(f.effect(), true);
  });
  test(domain + " retirement of an already known decision reports history and never undoes the effect", async t => {
    const f = await setup(t, domain), q = f.query(), decision = await f.decide(q), retired = await f.retire(q);
    assert.equal(retired.outcome, "confirmed"); assert.equal(retired.revision, decision.revision); assert.equal(f.effect(), true); assert.equal(f.rows().length, 0);
    assert.equal((await f.retire(f.query())).outcome, "superseded"); assert.equal(f.effect(), true);
  });
  test(domain + " retirement cannot be rebound to another verdict, report or content hash", async t => {
    const f = await setup(t, domain), q = f.query(); await f.retire(q);
    for (const patch of [{ verdict: "dismiss" }, { contentHash: "a".repeat(64) }, { reportID: (f.photo ? "community-v1-avatarreport-" : "community-v1-report-") + "a".repeat(64) }]) {
      await assert.rejects(f.retire({ ...q, ...patch }), e => e.code.endsWith("_STALE"));
      await assert.rejects(f.recover({ ...q, ...patch }), e => e.code.endsWith("_STALE"));
    }
    assert.equal(f.rows().length, 1); assert.equal(f.effect(), false);
  });
  test(domain + " lost retirement ACK recovers only original metadata and retry does not extend its deadline", async t => {
    let lose = false;
    const f = await setup(t, domain, { sqlHook: sql => { if (sql.startsWith("INSERT INTO ") && sql.includes("_decision_retirements_v1 VALUES")) lose = true; }, syncHook: async () => { if (lose) { lose = false; throw Error("PRIVATE-LOST-ACK"); } } }), q = f.query();
    await assert.rejects(f.retire(q), e => e.code.endsWith("_UNAVAILABLE")); const first = f.rows()[0];
    assert.equal((await f.recover(q)).outcome, "retired"); f.advance(1000); assert.equal((await f.retire(q)).outcome, "retired");
    assert.equal(f.rows()[0].expires_at, first.expires_at); assert.equal(f.rows().length, 1); await assert.rejects(f.decide(q), e => e.code.endsWith("_STALE"));
  });
  test(domain + " failed retirement transaction never falsely seals a still-permitted original decision", async t => {
    let armed = false; const f = await setup(t, domain, { sqlHook: sql => { if (armed && sql.startsWith("INSERT INTO ") && sql.includes("_decision_retirements_v1 VALUES")) throw Error("PRIVATE-SQL"); } }), q = f.query();
    armed = true; await assert.rejects(f.retire(q), e => e.code.endsWith("_UNAVAILABLE")); armed = false;
    assert.equal(f.rows().length, 0); assert.equal((await f.recover(q)).outcome, "not-applied"); await f.decide(q); assert.equal(f.effect(), true);
  });
  test(domain + " retirement racing a paused old lookup prevents its later same-transaction policy mutation", async t => {
    const f = await setup(t, domain), q = f.query(), entered = barrier(), release = barrier(); let held = false;
    f.model.before = async call => { if (!held && call.operation === "lookup" && call.body.records.some(r => r.recordName === q.reportID)) { held = true; entered.release(); await release.promise; } };
    const delayed = f.decide(q).catch(e => e); await entered.promise;
    const sealed = await f.reviews.retire({ reviewerID: f.operator.accountID, ...q, authorize: () => true }); assert.equal(sealed.outcome, "retired");
    release.release(); assert.ok((await delayed).code.endsWith("_STALE")); f.model.before = undefined; assert.equal(f.effect(), false);
  });
  test(domain + " another reviewer cannot retire the original reviewer nonce", async t => {
    const f = await setup(t, domain), q = f.query(), other = await f.session("other.retirement.operator");
    assert.equal((await f.reviews.retire({ reviewerID: other.accountID, ...q, authorize: () => true })).outcome, "retired");
    await f.decide(q); assert.equal(f.effect(), true); assert.equal((await f.recover(q)).outcome, "confirmed");
  });
  test(domain + " retirement of unknown metadata does not read a report or store text, report IDs or tokens", async t => {
    const f = await setup(t, domain), q = f.query({ reportID: (f.photo ? "community-v1-avatarreport-" : "community-v1-report-") + "a".repeat(64) }), before = f.model.requests.length;
    assert.equal((await f.retire(q)).outcome, "retired"); assert.equal(f.model.requests.length, before);
    const raw = JSON.stringify(f.rows()); for (const value of [q.reportID, q.contentHash, f.operator.accountID, "PRIVATE", "reason", "coordinate", "accessToken"]) assert.equal(raw.includes(value), false);
    assert.equal((await f.recover(q)).outcome, "retired");
  });
  test(domain + " retirement per-reviewer capacity and global capacity fail closed", async t => {
    const f = await setup(t, domain), q = f.query();
    for (let i = 0; i < 256; i++) await f.reviews.retire({ reviewerID: f.operator.accountID, ...q, decisionID: randomUUID(), authorize: () => true });
    await assert.rejects(f.retire(q), e => e.code.endsWith("_CAPACITY"));
    const row = f.rows()[0]; f.storage.transactionSync(() => {
      for (let i = 256; i < 4096; i++) f.storage.sql.exec(`INSERT INTO ${f.table} VALUES(?,?,?,?,?,?)`, digest("synthetic-capacity-" + i), randomUUID(), row.intent_hash, row.report_owner_key, row.retired_at, row.expires_at);
    });
    const other = await f.session("other.capacity.operator");
    await assert.rejects(f.reviews.retire({ reviewerID: other.accountID, ...q, authorize: () => true }), e => e.code.endsWith("_CAPACITY"));
    assert.equal(f.rows().length, 4096); assert.equal(f.effect(), false);
  });
  test(domain + " reviewer and report-owner erasure preserve unrelated retirement markers", async t => {
    const f = await setup(t, domain), q = f.query(), other = await f.session("other.erasure.operator"); await f.retire(q);
    await f.reviews.retire({ reviewerID: other.accountID, ...f.query(), authorize: () => true });
    await f.beginDeletion(f.operator, f.operatorSubject); await f.communityPolicy.eraseOwner(f.operator.accountID); assert.equal(f.rows().length, 1);
    await f.beginDeletion(f.reporterIdentity, f.reporterSubject); await f.communityPolicy.eraseOwner(f.reporterIdentity.accountID); assert.equal(f.rows().length, 0);
  });
  test(domain + " retirement expiry and bounded local cleanup do not revive an old inspection", async t => {
    const f = await setup(t, domain), q = f.query(); await f.retire(q); f.advance(30 * 86400000);
    assert.equal(moderationRetirementWakeAt(f.storage, f.clock), f.clock()); await purgeModerationRetirements(f.storage, f.clock); assert.equal(f.rows().length, 0);
    const key = digest((f.photo ? "echoes/avatar-report-review-session/v1\0" : "echoes/report-review-session/v1\0") + f.operator.sessionToken);
    assert.throws(() => f.reviews.get(f.operator.accountID, key, f.metadata.inspectionID), e => e.code.endsWith("_STALE"));
  });
  test(domain + " retirement requires synchronous true and rejects rollback without losing its durable barrier", async t => {
    const f = await setup(t, domain), q = f.query();
    for (const authorize of [() => undefined, () => false, () => 1, async () => true]) await assert.rejects(f.reviews.retire({ reviewerID: f.operator.accountID, ...q, authorize }), e => e.code.endsWith("_SCOPE"));
    await f.retire(q); f.advance(-1); assert.throws(() => f.reviews.outcome({ reviewerID: f.operator.accountID, ...q }), e => e.code.endsWith("_UNAVAILABLE")); f.advance(1);
    assert.equal((await f.recover(q)).outcome, "retired"); await assert.rejects(f.decide(q), e => e.code.endsWith("_STALE"));
  });
}
