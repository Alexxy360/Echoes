import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { avatarReviewFixture } from "./support/avatar-review-fixture.mjs";
import { avatarReviewHTTPFixture } from "./support/avatar-review-http-fixture.mjs";
import { AvatarReviewCoordinator } from "../src/avatar-review-coordinator.mjs";
import { avatarReviewInput, avatarReviewResult } from "../src/avatar-review-http.mjs";
import { purgeAvatarReviewRetirements, avatarReviewRetirementWakeAt } from "../src/avatar-review-decision-retirements.mjs";
const table = "avatar_review_decision_retirements_v1";
const selectionKeys = ["accountID", "requestID", "versionID", "generation", "reviewRevision"];
async function setup(t, http = false) {
  const f = http ? await avatarReviewHTTPFixture({ runtime: true }) : await avatarReviewFixture(); t.after(() => f.close());
  const current = f.policy.reviewQueue()[0], item = Object.fromEntries(selectionKeys.map(k => [k, current[k]]));
  const query = changes => ({ ...item, decisionID: randomUUID(), verdict: "rejected", ...changes });
  const state = q => ({ ...q, reviewerID: f.reviewer.accountID });
  const retire = q => f.policy.retireReview({ ...state(q), authorize: () => true });
  const decide = (q, changes = {}) => f.policy.review({ accountID: q.accountID, requestID: q.requestID, expectedRevision: q.reviewRevision,
    decisionID: q.decisionID, verdict: q.verdict, reviewerID: f.reviewer.accountID, ...changes });
  const pending = () => f.db.prepare("SELECT moderation_state FROM avatar_jobs_v1 WHERE account_id=? AND request_id=?").get(item.accountID,item.requestID).moderation_state;
  return { ...f, item, query, state, retire, decide, pending };
}
const json = async response => { const value = await response.json(); assert.equal(response.status, 200, JSON.stringify(value)); return value; };
for (const verdict of ["approved", "rejected"]) test("upload retirement blocks delayed " + verdict + " inside policy transaction while a fresh decision remains possible", async t => {
  const f = await setup(t), q = f.query({ verdict });
  assert.equal(f.policy.reviewOutcome(f.state(q)).outcome,"not-applied");
  assert.equal((await f.retire(q)).outcome,"retired");
  await assert.rejects(f.decide(q), e => e.code === "AVATAR_STALE"); assert.equal(f.pending(),"pending");
  const reopened = f.reopen(); assert.equal(reopened.policy.reviewOutcome(f.state(q)).outcome,"retired");
  const fresh = f.query({ verdict }), result = await f.decide(fresh); assert.equal(result.verdict,verdict);
  assert.equal(f.policy.snapshot(q.accountID).publishedVersionID,null); assert.equal(f.policy.reviewOutcome(f.state(q)).outcome,"retired");
});
test("upload retirement after receipt claim stops the old coordinator before its policy effect", async t => {
  const f = await setup(t), q = f.query(), response = await f.inspect(), receipt = f.reviewMetadata(response); await response.arrayBuffer();
  let entered, release; const reached = new Promise(resolve => { entered = resolve; }), gate = new Promise(resolve => { release = resolve; });
  const old = f.receipts, receipts = Object.fromEntries(["get","reserve","confirm","claim","finish"].map(k => [k,(...args)=>old[k](...args)]));
  receipts.claim = async (...args) => { const result = await old.claim(...args); entered(); await gate; return result; };
  const delayed = f.makeReview({ receipts }), running = f.reviewCall("prepareDecision", f.input({ inspectionID: receipt.inspectionID, decisionID: q.decisionID, verdict: q.verdict }), delayed);
  try {
    await reached;
    const replacement = new AvatarReviewCoordinator(f.configuration);
    assert.equal((await f.reviewCall("prepareRetirement", f.input(q), replacement)).outcome,"retired");
  } finally { release(); }
  await assert.rejects(running, e => e.code === "AVATAR_REVIEW_STALE"); assert.equal(f.pending(),"pending");
});
test("upload retirement preserves a known matching decision and cannot undo it or an existing other verdict", async t => {
  const f = await setup(t), q = f.query({ verdict: "approved" }), result = await f.decide(q);
  assert.deepEqual(await f.retire(q),{ outcome:"confirmed",revision:result.revision });
  assert.equal((await f.retire({ ...q, decisionID: randomUUID() })).outcome,"superseded");
  assert.equal(f.pending(),"approved"); assert.equal(f.policy.snapshot(q.accountID).publishedVersionID,null);
  assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,0);
});
test("upload retirement rejects every rebound field for the same moderator nonce", async t => {
  const f = await setup(t), q = f.query(); await f.retire(q);
  for (const patch of [{accountID:randomUUID()},{requestID:randomUUID()},{versionID:randomUUID()},{generation:q.generation+1},{reviewRevision:randomUUID()},{verdict:"approved"}]) {
    await assert.rejects(f.retire({...q,...patch}), e=>e.code==="AVATAR_STALE");
    assert.throws(()=>f.policy.reviewOutcome(f.state({...q,...patch})),e=>e.code==="AVATAR_STALE");
  }
  assert.equal(f.pending(),"pending");
});
test("upload retirement lost durability ACK keeps the original marker and its deadline", async t => {
  const f = await setup(t), q = f.query(), original = f.storage.sync; let fail=true;
  f.storage.sync = async () => { await original.call(f.storage); if(fail) throw new Error("synthetic lost ACK"); };
  await assert.rejects(f.retire(q), e=>e.code==="AVATAR_UNAVAILABLE");
  const first=f.db.prepare(`SELECT * FROM ${table}`).get();fail=false;f.advance(1000);
  assert.equal((await f.retire(q)).outcome,"retired"); assert.deepEqual(f.db.prepare(`SELECT * FROM ${table}`).get(),first);
  assert.equal(avatarReviewRetirementWakeAt(f.storage,f.clock),first.expires_at);
});
test("upload retirement insert failure rolls back and never promises a barrier", async t => {
  const f = await setup(t), q = f.query();
  f.db.exec(`CREATE TRIGGER fail_upload_retirement BEFORE INSERT ON ${table} BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END`);
  await assert.rejects(f.retire(q), e=>e.code==="AVATAR_UNAVAILABLE"); assert.equal(f.policy.reviewOutcome(f.state(q)).outcome,"not-applied");
  assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,0); assert.equal((await f.decide(q)).verdict,q.verdict);
});
test("upload retirement contains only hashes and nonce and can close an unknown source without a provider lookup", async t => {
  const f = await setup(t), q=f.query({accountID:randomUUID(),requestID:randomUUID(),versionID:randomUUID()}), before=f.downloads.length;
  assert.equal((await f.retire(q)).outcome,"retired");assert.equal(f.downloads.length,before);
  const row=f.db.prepare(`SELECT * FROM ${table}`).get(), text=JSON.stringify(row);
  for(const forbidden of [q.accountID,q.requestID,q.versionID,q.reviewRevision,f.reviewer.accountID,"SYNTHETIC-URL","http","Bearer"]) assert.equal(text.includes(forbidden),false);
  assert.equal(row.decision_id,q.decisionID); assert.equal(row.expires_at-row.retired_at,2592000000);
});
test("upload retirement requires a synchronous fresh guard and fails closed on clock rollback", async t => {
  const f=await setup(t),q=f.query();
  for(const authorize of [()=>false,()=>undefined,()=>1,async()=>true,()=>{throw new Error("synthetic role loss");}])
    await assert.rejects(f.policy.retireReview({...f.state(q),authorize}),e=>e.code==="AVATAR_SCOPE");
  assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,0);await f.retire(q);f.advance(-1);
  assert.throws(()=>f.policy.reviewOutcome(f.state(q)),e=>e.code==="AVATAR_UNAVAILABLE");
});
test("upload retirement scopes the nonce to the reviewer and erasure preserves unrelated owners", async t => {
  const f=await setup(t),q=f.query(),other=await f.session("second-upload-reviewer");await f.retire(q);
  await f.policy.retireReview({...q,reviewerID:other.accountID,authorize:()=>true});
  const unrelated=f.query({accountID:other.accountID,decisionID:randomUUID()});await f.policy.retireReview({...unrelated,reviewerID:other.accountID,authorize:()=>true});
  assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,3);
  f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1 WHERE account_id=?").run(q.accountID);await f.social.eraseOwner(q.accountID);assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,1);
  assert.equal(f.policy.reviewOutcome({...unrelated,reviewerID:other.accountID}).outcome,"retired");
  f.db.prepare("UPDATE auth_accounts_v1 SET disabled=1 WHERE account_id=?").run(other.accountID);await f.social.eraseOwner(other.accountID);assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,0);
});
test("upload retirement enforces per-reviewer and global stored-row bounds", async t => {
  const f=await setup(t),q=f.query();for(let i=0;i<256;i++)await f.retire({...q,decisionID:randomUUID()});
  await assert.rejects(f.retire(q),e=>e.code==="AVATAR_CAPACITY");
  const row=f.db.prepare(`SELECT * FROM ${table} LIMIT 1`).get(),insert=f.db.prepare(`INSERT INTO ${table} VALUES(?,?,?,?,?,?)`);
  f.db.exec("BEGIN");for(let i=256;i<4096;i++)insert.run(i.toString(16).padStart(64,"0"),randomUUID(),row.intent_hash,row.owner_key,row.retired_at,row.expires_at);f.db.exec("COMMIT");
  const other=await f.session("second-upload-moderator");await assert.rejects(f.policy.retireReview({...q,reviewerID:other.accountID,authorize:()=>true}),e=>e.code==="AVATAR_CAPACITY");
});
test("upload retirement expiry cleanup is bounded and a previous ninety-second inspection cannot revive", async t => {
  const f=await setup(t),q=f.query(),response=await f.inspect(),receipt=f.reviewMetadata(response);await response.arrayBuffer();
  for(let i=0;i<102;i++)await f.retire({...q,decisionID:randomUUID()});f.advance(2592000000);
  await purgeAvatarReviewRetirements(f.storage,f.clock);assert.equal(f.db.prepare(`SELECT COUNT(*) n FROM ${table}`).get().n,2);
  await assert.rejects(f.reviewCall("prepareDecision",f.input({inspectionID:receipt.inspectionID,decisionID:q.decisionID,verdict:q.verdict})),e=>e.code==="AVATAR_REVIEW_STALE"||e.code==="AVATAR_REVIEW_SCOPE");
  await purgeAvatarReviewRetirements(f.storage,f.clock);assert.equal(avatarReviewRetirementWakeAt(f.storage,f.clock),null);
});
test("upload retirement HTTP real Runtime seals an inspected attempt and keeps read-only recovery", async t => {
  const f=await setup(t,true),q=f.query(),response=await f.edge("inspect"),receipt=f.reviewMetadata(response);await response.arrayBuffer();
  assert.equal((await json(await f.edge("recover",q))).outcome,"not-applied");
  assert.equal((await json(await f.edge("retire",q))).outcome,"retired");
  assert.equal((await f.edge("decide",{inspectionID:receipt.inspectionID,decisionID:q.decisionID,verdict:q.verdict})).status,409);
  assert.equal((await json(await f.edge("recover",q))).outcome,"retired");assert.equal(f.pending(),"pending");
});
test("upload retirement HTTP denies role and feature before private body or checkpoint", async t => {
  const f=await avatarReviewHTTPFixture();t.after(()=>f.close());const q={accountID:f.signedIn.accountID,requestID:f.pending.requestID,versionID:randomUUID(),generation:1,reviewRevision:randomUUID(),decisionID:randomUUID(),verdict:"rejected"};
  f.setFeature(false);assert.equal((await f.call("retire",q)).status,503);f.setFeature(true);
  assert.equal((await f.call("retire",q,{token:f.signedIn.sessionToken,rawBody:'{"operator":true}'})).status,403);
  assert.equal(f.counts().verifies,0);assert.equal((await f.call("retire",{...q,operator:true})).status,400);
});
test("upload retirement HTTP withholds the ACK when role changes after the final checkpoint", async t => {
  const f=await avatarReviewHTTPFixture();t.after(()=>f.close());const current=f.policy.reviewQueue()[0],q=Object.fromEntries(selectionKeys.map(k=>[k,current[k]]));Object.assign(q,{decisionID:randomUUID(),verdict:"rejected"});
  f.afterLastAdvance(()=>f.operators.clear());assert.equal((await f.call("retire",q)).status,403);
  assert.equal(f.policy.reviewOutcome({...q,reviewerID:f.reviewer.accountID}).outcome,"retired");
});
test("upload retirement wire rejects an unsealed absence and all uncorrelated metadata", async t => {
  const f=await setup(t),q=f.query(),good={schemaVersion:1,...q,outcome:"retired",revision:null};
  assert.deepEqual(avatarReviewInput("retire",q),q);assert.deepEqual(avatarReviewResult("retire",good,q),good);
  for(const patch of [{outcome:"not-applied"},{revision:randomUUID()},{requestID:randomUUID()},{ownerID:randomUUID()}])assert.throws(()=>avatarReviewResult("retire",{...good,...patch},q));
  for(const patch of [{generation:true},{generation:Number.MAX_SAFE_INTEGER},{reviewRevision:"bad"},{operator:true}])assert.throws(()=>avatarReviewInput("retire",{...q,...patch}));
});
