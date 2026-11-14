import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { AccountDeletionState } from "../src/account-deletion-state.mjs";
import { AccountDeletionCoordinator, AccountDeletionProcessor } from "../src/account-deletion.mjs";
import { fixture, hash, codeIs, syntheticCode } from "./support/authentication-fixture.mjs";

function setup(options) {
  const f = fixture(options), deletions = new AccountDeletionState(f.storage, { clock: f.clock });
  const coordinator = new AccountDeletionCoordinator({ authenticationState: f.state, deletionState: deletions, verifier: f.verifier });
  return { ...f, deletions, coordinator, login: f.coordinator,
    async proof(subject = "synthetic.user", expectedAccountID, purpose = "deletion_recovery") {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose });
      return { challengeID: challenge.challengeID, identityToken: f.token(challenge, subject), expectedAccountID };
    },
    async start(subject = "synthetic.user", expectedAccountID) {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "account_deletion" });
      const deletionID = randomUUID(), statusToken = deletionID + "." + randomBytes(32).toString("base64url");
      const ticket = { deletionID, statusToken };
      const status = await coordinator.request({ ...ticket, challengeID: challenge.challengeID, identityToken: f.token(challenge, subject), expectedAccountID });
      return { ticket, status };
    },
    async finish(ticket) {
      const processor = new AccountDeletionProcessor({ deletionState: deletions, credentialVault: f.vault,
        appleClient: { async revokeRefreshToken() {} }, erasePublicDataBatch: async context => ({ ...context, remaining: false }) });
      await deletions.acknowledgePrivateCleanup(ticket); f.advance(60001);
      assert.equal(await processor.step(ticket.deletionID), true);
    },
  };
}

test("fresh proof recovers the same owner job with a rotated narrow capability and preserves all progress and leases", async () => {
  const f = setup();
  try {
    const own = await f.session(), other = await f.session("another.user"), { ticket } = await f.start();
    const lease = await f.deletions.claimPublicBatch(ticket.deletionID);
    await f.deletions.acknowledgePrivateCleanup(ticket);
    const before = f.db.prepare("SELECT * FROM auth_account_deletions_v1").get();
    const recovered = await f.coordinator.recover(await f.proof("synthetic.user", own.accountID));
    assert.equal(recovered.deletionID, ticket.deletionID); assert.equal(recovered.accountID, own.accountID);
    assert.equal(recovered.privateData, "device-acknowledged"); assert.notEqual(recovered.statusToken, ticket.statusToken);
    const after = f.db.prepare("SELECT * FROM auth_account_deletions_v1").get();
    for (const key of Object.keys(before).filter(key => !["status_hash", "recovery_order"].includes(key))) assert.equal(after[key], before[key], key);
    assert.equal(after.public_lease_id, lease.leaseID); assert.equal(after.status_hash.includes(recovered.statusToken), false);
    assert.throws(() => f.deletions.status(ticket), codeIs("DELETION_UNAVAILABLE"));
    await assert.rejects(() => f.deletions.acknowledgePrivateCleanup(ticket), codeIs("DELETION_UNAVAILABLE"));
    for (const field of ["sessionToken", "renewalToken", "subjectHash", "appleSubject", "sealedCredential"]) assert.equal(Object.hasOwn(recovered, field), false);
    assert.throws(() => f.state.authorize(own.sessionToken), codeIs("INVALID_SESSION")); f.state.authorize(other.sessionToken);
    await f.deletions.completePublicBatch(lease, { ...lease, remaining: false });
  } finally { f.close(); }
});

test("a proof issued before deletion cannot recover it and a fresh proof works in the same millisecond", async () => {
  const f = setup();
  try {
    await f.session(); const old = await f.proof(), { ticket } = await f.start();
    await assert.rejects(() => f.coordinator.recover(old), codeIs("INVALID_CHALLENGE"));
    f.deletions.status(ticket);
    const recovered = await f.coordinator.recover(await f.proof()); assert.equal(recovered.deletionID, ticket.deletionID);
  } finally { f.close(); }
});

test("only one of concurrent outstanding proofs can rotate a job and an older proof cannot revoke its replacement", async () => {
  const f = setup();
  try {
    await f.session(); await f.start(); const a = await f.proof(), b = await f.proof();
    const results = await Promise.allSettled([f.coordinator.recover(a), f.coordinator.recover(b)]);
    assert.equal(results.filter(x => x.status === "fulfilled").length, 1);
    const current = results.find(x => x.status === "fulfilled").value; f.deletions.status(current);
    const loser = results.find(x => x.status === "rejected"); assert.equal(loser.reason.code, "INVALID_CHALLENGE");
    const latest = await f.coordinator.recover(await f.proof()); f.deletions.status(latest);
    assert.throws(() => f.deletions.status(current), codeIs("DELETION_UNAVAILABLE"));
    await assert.rejects(() => f.coordinator.recover(a), codeIs("INVALID_CHALLENGE"));
  } finally { f.close(); }
});

test("recovery purposes are separate from login, reset and deletion and cannot start a job", async () => {
  const f = setup();
  try {
    await f.session(); const { ticket } = await f.start();
    for (const purpose of ["login", "account_deletion", "session_reset"]) {
      await assert.rejects(async () => f.coordinator.recover(await f.proof("synthetic.user", undefined, purpose)), codeIs("INVALID_CHALLENGE"));
    }
    const proof = await f.proof();
    await assert.rejects(() => f.coordinator.request({ ...proof, deletionID: randomUUID(), statusToken: ticket.statusToken }), codeIs("DELETION_UNAVAILABLE"));
    const freshID = randomUUID();
    await assert.rejects(() => f.coordinator.request({ ...proof, deletionID: freshID, statusToken: freshID + "." + randomBytes(32).toString("base64url") }), codeIs("INVALID_CHALLENGE"));
    let exchanges = 0;
    await assert.rejects(() => f.login(async () => { exchanges++; return "unused"; }).login({
      ...proof, authorizationCode: syntheticCode }), codeIs("INVALID_CHALLENGE"));
    assert.equal(exchanges, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 1);
    f.deletions.status(ticket);
  } finally { f.close(); }
});

test("fresh owner proof cannot select another subject/account and absence never fabricates a deletion", async () => {
  const f = setup();
  try {
    const own = await f.session(), other = await f.session("another.user"), { ticket } = await f.start();
    await assert.rejects(async () => f.coordinator.recover(await f.proof("synthetic.user", other.accountID)), codeIs("INVALID_IDENTITY"));
    await assert.rejects(async () => f.coordinator.recover(await f.proof("another.user", own.accountID)), codeIs("NO_DELETION"));
    await assert.rejects(async () => f.coordinator.recover(await f.proof("never.registered")), codeIs("NO_DELETION"));
    const proof = await f.proof();
    await assert.rejects(() => f.coordinator.recover({ ...proof, identityToken: proof.identityToken.slice(0, -10) + "invalid-signature" }), codeIs("INVALID_IDENTITY"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 1);
    f.deletions.status(ticket); f.state.authorize(other.sessionToken);
  } finally { f.close(); }
});

test("operator ban and full credential capacity do not prevent narrow deletion recovery or restore a session", async () => {
  const f = setup();
  try {
    const own = await f.session(); await f.state.disableAccount(own.accountID); await f.start();
    for (let i = 0; i < 5000; i++) f.db.prepare("INSERT INTO auth_credential_reservations_v1(reservation_id,subject_hash,expires_at) VALUES (?,?,?)")
      .run(randomUUID(), hash(String(i)), f.clock() + 86400000);
    const recovered = await f.coordinator.recover(await f.proof()); assert.equal(recovered.accountID, own.accountID);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_subject_bans_v1").get().count, 1);
    assert.equal(f.db.prepare("SELECT disabled FROM auth_accounts_v1").get().disabled, 1);
    assert.throws(() => f.state.authorize(own.sessionToken), codeIs("INVALID_SESSION"));
  } finally { f.close(); }
});

test("a new deletion request for an active owner job explicitly requires recovery instead of creating a duplicate", async () => {
  const f = setup();
  try {
    await f.session(); const { ticket } = await f.start();
    await assert.rejects(() => f.start(), codeIs("DELETION_IN_PROGRESS"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 1);
    f.deletions.status(ticket);
  } finally { f.close(); }
});

test("lost durability acknowledgement returns no capability and the next explicit fresh proof safely recovers", async () => {
  let armed = false, failOnce = true;
  const f = setup({ sqlHook: sql => { if (sql.startsWith("UPDATE auth_account_deletions_v1 SET status_hash=")) armed = true; },
    syncHook: async () => { if (armed && failOnce) { failOnce = false; throw new Error("PRIVATE-RECOVERY-SYNC"); } } });
  try {
    await f.session(); const { ticket } = await f.start(), proof = await f.proof();
    await assert.rejects(() => f.coordinator.recover(proof), codeIs("STATE_UNAVAILABLE")); armed = false;
    assert.throws(() => f.deletions.status(ticket), codeIs("DELETION_UNAVAILABLE"));
    await assert.rejects(() => f.coordinator.recover(proof), codeIs("INVALID_CHALLENGE"));
    const recovered = await f.coordinator.recover(await f.proof()); f.deletions.status(recovered);
    assert.equal(recovered.deletionID, ticket.deletionID);
  } finally { f.close(); }
});

test("a recovery transaction failure keeps the previous ticket and does not consume or partially rotate the job", async () => {
  let armed = false;
  const f = setup({ sqlHook: sql => { if (armed && sql.startsWith("UPDATE auth_account_deletions_v1 SET status_hash=")) throw new Error("PRIVATE-RECOVERY-SQL"); } });
  try {
    await f.session(); const { ticket } = await f.start(), proof = await f.proof(); armed = true;
    await assert.rejects(() => f.coordinator.recover(proof), codeIs("STATE_UNAVAILABLE")); armed = false;
    f.deletions.status(ticket);
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1 WHERE challenge_id=?").get(proof.challengeID).state, "claimed");
    const recovered = await f.coordinator.recover(await f.proof()); f.deletions.status(recovered);
  } finally { f.close(); }
});

test("completed receipt recovery is bound to the old account and never mutates a newly created account", async () => {
  const f = setup();
  try {
    const own = await f.session(), { ticket } = await f.start(); await f.finish(ticket);
    const fresh = await f.session(); assert.notEqual(fresh.accountID, own.accountID);
    const recovered = await f.coordinator.recover(await f.proof());
    assert.equal(recovered.completed, true); assert.equal(recovered.accountID, own.accountID);
    await assert.rejects(async () => f.coordinator.recover(await f.proof("synthetic.user", fresh.accountID)), codeIs("INVALID_IDENTITY"));
    f.deletions.status(recovered); f.state.authorize(fresh.sessionToken);
    f.advance(30 * 86400000 + 1);
    await assert.rejects(async () => f.coordinator.recover(await f.proof()), codeIs("NO_DELETION"));
  } finally { f.close(); }
});

test("recovery capability, guard order and unchanged job identity survive SQLite reopen and one-time legacy migration", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-deletion-recovery-")), path = join(directory, "state.sqlite");
  let f = setup({ path });
  try {
    const own = await f.session(), { ticket } = await f.start(), recovered = await f.coordinator.recover(await f.proof());
    const old = await f.proof(); f.close(); f = setup({ path });
    assert.equal(f.deletions.status(recovered).accountID, own.accountID);
    assert.throws(() => f.deletions.status(ticket), codeIs("DELETION_UNAVAILABLE"));
    f.db.exec("ALTER TABLE auth_account_deletions_v1 DROP COLUMN recovery_order");
    f.db.exec("DELETE FROM auth_schema_migrations_v1 WHERE name='deletion-recovery-order-v1'");
    f.close(); f = setup({ path });
    f.deletions.status(recovered);
    await assert.rejects(() => f.coordinator.recover(old), codeIs("INVALID_CHALLENGE"));
    const latest = await f.coordinator.recover(await f.proof());
    assert.equal(latest.deletionID, ticket.deletionID); assert.equal(latest.accountID, own.accountID);
    f.close(); f = setup({ path }); f.deletions.status(latest);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_schema_migrations_v1 WHERE name='deletion-recovery-order-v1'").get().count, 1);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("an identity that expires during verification cannot rotate the deletion capability", async () => {
  const f = setup();
  try {
    await f.session(); const { ticket } = await f.start();
    const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "deletion_recovery" });
    const coordinator = new AccountDeletionCoordinator({ authenticationState: f.state, deletionState: f.deletions,
      verifier: { async verify(token, context) { const identity = await f.verifier.verify(token, context); f.advance(2000); return identity; } } });
    await assert.rejects(() => coordinator.recover({ challengeID: challenge.challengeID, identityToken: f.token(challenge, "synthetic.user", 1) }), codeIs("INVALID_IDENTITY"));
    f.deletions.status(ticket);
  } finally { f.close(); }
});
