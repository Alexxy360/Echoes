import {test} from 'node:test';import assert from 'node:assert/strict';import{randomUUID}from'node:crypto';
import{fixture}from'./support/authentication-fixture.mjs';import{makeAuthenticationTrialCleanupPlan}from'../scripts/authentication-trial-cleanup-plan.mjs';
async function setup(t){const f=fixture();t.after(()=>f.close());const pair=await f.session();await f.state.revokeAllSessions(pair.sessionToken);const row=f.db.prepare('SELECT a.account_id,a.subject_hash,c.credential_id FROM auth_accounts_v1 a JOIN auth_refresh_credentials_v1 c USING(account_id)').get();const p=makeAuthenticationTrialCleanupPlan({accountID:row.account_id,subjectHash:row.subject_hash,credentialID:row.credential_id});return{f,p};}
const eligible=({f,p})=>f.db.prepare(p.plan.preflight).get().eligible;
const clean=({f,p})=>p.plan.deletes.forEach(sql=>f.db.exec(sql));
const counts=({f,p})=>Object.values(p.plan.checks).map(sql=>f.db.prepare(sql).get().count);

test('exact cleanup executes against the real auth schema, removes only trial rows and supports partial replay',async t=>{
 const x=await setup(t);assert.equal(eligible(x),1);x.p.plan.deletes.slice(0,4).forEach(sql=>x.f.db.exec(sql));assert.equal(eligible(x),1);clean(x);assert.deepEqual(counts(x),Array(8).fill(0));assert.equal(eligible(x),0);clean(x);assert.deepEqual(counts(x),Array(8).fill(0));assert.equal(x.f.db.prepare('SELECT count(*) AS n FROM auth_event_order_v1').get().n,1);
 assert.equal(x.p.plan.executed,false);assert.equal(x.p.plan.networkRequests,0);assert.equal(JSON.stringify(x.p).includes('SYNTHETIC-PRIVATE-REFRESH'),false);
});
test('a second ordinary synthetic account prevents every mutation and preserves both accounts and credentials',async t=>{
 const x=await setup(t);await x.f.session('unrelated.synthetic.user');const before=x.f.db.prepare('SELECT * FROM auth_accounts_v1 ORDER BY account_id').all();const secrets=x.f.db.prepare('SELECT * FROM auth_refresh_credentials_v1 ORDER BY credential_id').all();assert.equal(eligible(x),0);clean(x);assert.deepEqual(x.f.db.prepare('SELECT * FROM auth_accounts_v1 ORDER BY account_id').all(),before);assert.deepEqual(x.f.db.prepare('SELECT * FROM auth_refresh_credentials_v1 ORDER BY credential_id').all(),secrets);
});
test('mismatched identity or credential and unfinished provider work refuse cleanup',async t=>{
 const x=await setup(t);for(const change of [{subjectHash:'f'.repeat(64)},{credentialID:randomUUID()},{accountID:randomUUID()}]){const p=makeAuthenticationTrialCleanupPlan({...x.p.plan.inventory,...change});const y={f:x.f,p};assert.equal(eligible(y),0);clean(y);assert.equal(x.f.db.prepare('SELECT count(*) AS n FROM auth_accounts_v1').get().n,1);}
 x.f.db.prepare('INSERT INTO auth_credential_reservations_v1(reservation_id,subject_hash,expires_at) VALUES(?,?,?)').run(randomUUID(),x.p.plan.inventory.subjectHash,x.f.clock()+1000);assert.equal(eligible(x),0);clean(x);assert.equal(x.f.db.prepare('SELECT count(*) AS n FROM auth_refresh_credentials_v1').get().n,1);
});
test('active session generation and a public registry checkpoint cannot be mistaken for this empty auth-only realm',async t=>{
 const x=await setup(t);x.f.db.exec('UPDATE auth_accounts_v1 SET generation=0');assert.equal(eligible(x),0);clean(x);x.f.db.exec('UPDATE auth_accounts_v1 SET generation=1');x.f.db.exec('CREATE TABLE public_registry_checkpoint_v1(singleton INTEGER)');assert.equal(eligible(x),0);clean(x);assert.equal(x.f.db.prepare('SELECT count(*) AS n FROM auth_accounts_v1').get().n,1);
});
test('SQL injection, extra properties and incomplete inventories are rejected before any SQL exists',()=>{
 const valid={accountID:randomUUID(),credentialID:randomUUID(),subjectHash:'a'.repeat(64)};for(const input of [null,{}, {...valid,accountID:"' OR 1=1 --"},{...valid,subjectHash:"' OR 1=1 --"},{...valid,table:'auth_accounts_v1'}])assert.throws(()=>makeAuthenticationTrialCleanupPlan(input),/Invalid exact authentication trial inventory/);
});
test('partial cleanup cannot turn a substituted credential UUID into permission to delete an unrelated challenge',async t=>{
 const x=await setup(t);const foreign=await x.f.challenge();x.f.db.exec('DELETE FROM auth_refresh_credentials_v1');const p=makeAuthenticationTrialCleanupPlan({...x.p.plan.inventory,credentialID:foreign.challengeID});x.f.db.exec(p.plan.deletes[0]);assert.equal(x.f.db.prepare('SELECT count(*) AS n FROM auth_challenges_v1 WHERE challenge_id=?').get(foreign.challengeID).n,1);
});
