import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { randomBytes, randomUUID, generateKeyPairSync } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AccountDeletionState } from "../src/account-deletion-state.mjs";
import { AccountDeletionCoordinator, AccountDeletionProcessor } from "../src/account-deletion.mjs";
import { AppleClientSecret, AppleOAuthClient } from "../src/apple-oauth.mjs";
import { appleSubjectHash } from "../src/refresh-credential-vault.mjs";
import { fixture, hash, start, syntheticRefresh, syntheticCode, codeIs } from "./support/authentication-fixture.mjs";

function setup(options) {
  const f = fixture(options), deletions = new AccountDeletionState(f.storage, { clock: f.clock });
  const coordinator = new AccountDeletionCoordinator({ authenticationState: f.state, deletionState: deletions, verifier: f.verifier });
  const records = new Map(), revoked = [];
  const erase = async context => {
    assert.equal(context.signal.aborted, false);
    const own = records.get(context.accountID) ?? []; own.splice(0, context.maximumRecords);
    return { accountID: context.accountID, deletionID: context.deletionID, remaining: own.length > 0 };
  };
  return { ...f, deletions, deleter: coordinator, records, revoked,
    async input(subject = "synthetic.user", expectedAccountID) {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "account_deletion" });
      const deletionID = randomUUID(), statusToken = deletionID + "." + randomBytes(32).toString("base64url");
      return { challengeID: challenge.challengeID, identityToken: f.token(challenge, subject), deletionID, statusToken, expectedAccountID };
    },
    processor({ erasePublicDataBatch = erase, revokeRefreshToken = async token => { revoked.push(token); }, ...rest } = {}) {
      return new AccountDeletionProcessor({ deletionState: deletions, credentialVault: f.vault,
        appleClient: { revokeRefreshToken }, erasePublicDataBatch, ...rest });
    },
    async finish(input, processor) {
      await deletions.acknowledgePrivateCleanup(input);
      for (let i = 0; i < 10; i++) {
        const done = await processor.step(input.deletionID); if (done) return deletions.status(input);
        f.advance(60001);
      }
      throw new Error("Synthetic deletion did not finish.");
    },
  };
}

test("fresh purpose-bound proof blocks all own sessions immediately and returns only a narrow deletion status", async () => {
  const f = setup();
  try {
    const a = await f.session(), b = await f.session(), other = await f.session("another.user");
    const input = await f.input("synthetic.user", a.accountID), status = await f.deleter.request(input);
    assert.equal(status.completed, false); assert.equal(status.localAccount, "blocked");
    for (const session of [a, b]) {
      assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
      await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("INVALID_SESSION"));
    }
    f.state.authorize(other.sessionToken);
    const serialized = JSON.stringify(status);
    for (const secret of [a.accountID, "synthetic.user", input.statusToken, syntheticRefresh, input.identityToken]) assert.equal(serialized.includes(secret), false);
    assert.equal(f.db.prepare("SELECT status_hash FROM auth_account_deletions_v1").get().status_hash.includes(input.statusToken), false);
  } finally { f.close(); }
});

test("a login token cannot be repurposed for deletion and a deletion challenge cannot be used for login", async () => {
  const f = setup();
  try {
    const session = await f.session(), login = await f.challenge(), input = await f.input(); let calls = 0;
    await assert.rejects(() => f.deleter.request({ ...input, challengeID: login.challengeID, identityToken: f.token(login) }), codeIs("INVALID_CHALLENGE"));
    await assert.rejects(() => f.deleter.request({ ...input, identityToken: "invalid.token.signature" }), codeIs("INVALID_IDENTITY"));
    await assert.rejects(() => f.deleter.request({ ...input, identityToken: f.token(login) }), codeIs("INVALID_IDENTITY"));
    await assert.rejects(() => f.coordinator(async () => { calls++; return "unused"; }).login({ challengeID: input.challengeID, identityToken: input.identityToken,
      authorizationCode: syntheticCode }), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 0); f.state.authorize(session.sessionToken);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 0);
  } finally { f.close(); }
});

test("expected-account input cannot select another owner and a missing application account is never fabricated", async () => {
  const f = setup();
  try {
    const a = await f.session(), b = await f.session("another.user");
    await assert.rejects(async () => f.deleter.request(await f.input("synthetic.user", b.accountID)), codeIs("INVALID_IDENTITY"));
    await assert.rejects(async () => f.deleter.request(await f.input("not.registered")), codeIs("NO_ACCOUNT"));
    f.state.authorize(a.sessionToken); f.state.authorize(b.sessionToken);
  } finally { f.close(); }
});

test("blocked accounts and full credential capacity do not prevent fresh owner-authorized deletion", async () => {
  const f = setup();
  try {
    const session = await f.session(); await f.state.disableAccount(session.accountID);
    for (let i = 0; i < 5000; i++) f.db.prepare(`INSERT INTO auth_credential_reservations_v1
      (reservation_id,subject_hash,expires_at) VALUES (?,?,?)`).run(randomUUID(), hash(String(i)), start + 86400000);
    const status = await f.deleter.request(await f.input()); assert.equal(status.localAccount, "blocked");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 1);
  } finally { f.close(); }
});

test("the persisted client ticket recovers a lost request response without another proof or duplicate job", async () => {
  const f = setup({ syncHook: async count => { if (count === 10) throw new Error("PRIVATE-REQUEST-SYNC"); } });
  try {
    await f.session(); const input = await f.input();
    await assert.rejects(() => f.deleter.request(input), codeIs("STATE_UNAVAILABLE"));
    const retry = await f.deleter.request({ deletionID: input.deletionID, statusToken: input.statusToken });
    assert.equal(retry.localAccount, "blocked");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 1);
    await assert.rejects(() => f.deleter.request({ ...input, statusToken: input.deletionID + "." + randomBytes(32).toString("base64url") }),
      codeIs("DELETION_UNAVAILABLE"));
  } finally { f.close(); }
});

test("failure of the request transaction rolls back account disable, fence and job creation together", async () => {
  const f = setup({ sqlHook: sql => { if (sql.startsWith("INSERT INTO auth_subject_fences_v1")) throw new Error("PRIVATE-SQL"); } });
  try {
    const session = await f.session(), input = await f.input();
    await assert.rejects(() => f.deleter.request(input), codeIs("STATE_UNAVAILABLE"));
    f.state.authorize(session.sessionToken);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_subject_fences_v1").get().count, 0);
  } finally { f.close(); }
});

test("bounded public batches erase more than 100 own records, preserve another owner, and wait for device acknowledgement", async () => {
  const f = setup();
  try {
    const own = await f.session(), other = await f.session("another.user");
    f.records.set(own.accountID, Array.from({ length: 205 }, (_, i) => i)); f.records.set(other.accountID, ["other-owned-record"]);
    const input = await f.input(); await f.deleter.request(input); const processor = f.processor();
    await processor.step(input.deletionID); assert.equal(f.records.get(own.accountID).length, 105);
    f.advance(1000); await processor.step(input.deletionID); assert.equal(f.records.get(own.accountID).length, 5);
    f.advance(60001); assert.equal(await processor.step(input.deletionID), false);
    assert.equal(f.records.get(own.accountID).length, 0); assert.equal(f.deletions.status(input).privateData, "awaiting-device");
    assert.deepEqual(f.records.get(other.accountID), ["other-owned-record"]); f.state.authorize(other.sessionToken);
    const status = await f.finish(input, processor); assert.equal(status.completed, true);
    assert.equal(status.appleAuthorization, "retained-tokens-processed");
    assert.equal(f.db.prepare("SELECT account_id FROM auth_accounts_v1 WHERE account_id=?").get(own.accountID), undefined);
  } finally { f.close(); }
});

test("an initial empty scan is rechecked after the drain window before deletion can complete", async () => {
  const f = setup();
  try {
    const session = await f.session(), input = await f.input(); await f.deleter.request(input);
    await f.deletions.acknowledgePrivateCleanup(input); const processor = f.processor();
    assert.equal(await processor.step(input.deletionID), false); assert.equal(f.deletions.status(input).publicData, "draining");
    f.records.set(session.accountID, ["synthetic-late-owned-write"]); f.advance(60001);
    assert.equal(await processor.step(input.deletionID), true); assert.equal(f.records.get(session.accountID).length, 0);
  } finally { f.close(); }
});

test("missing adapter, wrong-owner receipt and partial acknowledgement never produce a fabricated data-erasure success", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input); f.advance(60001);
    assert.throws(() => new AccountDeletionProcessor({ deletionState: f.deletions, credentialVault: f.vault,
      appleClient: { revokeRefreshToken() {} } }), codeIs("DELETION_UNAVAILABLE"));
    for (const wrong of [context => ({ ...context, accountID: randomUUID(), remaining: false }),
      context => ({ ...context, deletionID: randomUUID(), remaining: false }), context => ({ ...context, remaining: undefined })]) {
      await f.processor({ erasePublicDataBatch: async context => wrong(context) }).step(input.deletionID);
      assert.equal(f.deletions.status(input).publicData, "pending"); assert.equal(f.deletions.status(input).completed, false);
      f.advance(3600001);
    }
  } finally { f.close(); }
});

test("lease durability must succeed before either public erasure or token revocation leaves the process", async () => {
  let fail = false, calls = 0; const f = setup({ syncHook: async () => { if (fail) throw new Error("PRIVATE-SYNC"); } });
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input); fail = true;
    const processor = f.processor({ erasePublicDataBatch: async context => { calls++; return { ...context, remaining: false }; },
      revokeRefreshToken: async () => { calls++; } });
    await assert.rejects(() => processor.step(input.deletionID), codeIs("DELETION_UNAVAILABLE")); assert.equal(calls, 0);
    fail = false; f.advance(60001);
    const data = await f.deletions.claimPublicBatch(input.deletionID); await f.deletions.completePublicBatch(data, { ...data, remaining: false });
    fail = true; await assert.rejects(() => processor.step(input.deletionID), codeIs("DELETION_UNAVAILABLE")); assert.equal(calls, 0);
  } finally { f.close(); }
});

test("a public adapter timeout is bounded, aborts its signal and leaves data pending", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input); let signal;
    await f.processor({ eraseTimeoutMilliseconds: 15, erasePublicDataBatch: async context => {
      signal = context.signal; return new Promise(() => {});
    } }).step(input.deletionID);
    assert.equal(signal.aborted, true); assert.equal(f.deletions.status(input).publicData, "pending");
    assert.equal(f.deletions.status(input).completed, false);
  } finally { f.close(); }
});

test("an unknown revocation outcome retains ciphertext and retries the documented idempotent endpoint with backoff", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input); let calls = 0;
    const key = generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ type: "pkcs8", format: "pem" });
    const apple = new AppleOAuthClient({ clientSecret: new AppleClientSecret({ privateKeyPEM: key, keyID: "TESTKEY123", clock: f.clock }),
      fetchImplementation: async request => {
        calls++; assert.equal(request.url, "https://appleid.apple.com/auth/revoke");
        assert.equal(new URLSearchParams(await request.text()).get("token"), syntheticRefresh);
        if (calls === 1) throw new Error("PRIVATE-PROVIDER-DETAIL");
        return new Response(null, { status: 200 });
      } });
    const processor = f.processor({ revokeRefreshToken: token => apple.revokeRefreshToken(token) });
    await processor.step(input.deletionID); assert.equal(calls, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 1);
    await processor.step(input.deletionID); assert.equal(calls, 1);
    f.advance(60001); const result = await f.finish(input, processor); assert.equal(calls, 2); assert.equal(result.completed, true);
    assert.equal(JSON.stringify(result).includes("PRIVATE-PROVIDER"), false);
  } finally { f.close(); }
});

test("five failed revocations finish application erasure with explicit manual Apple action instead of claiming revocation", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input); await f.deletions.acknowledgePrivateCleanup(input);
    let calls = 0; const processor = f.processor({ revokeRefreshToken: async () => { calls++; throw new Error("PRIVATE-PROVIDER"); } });
    for (let i = 0; i < 5; i++) { await processor.step(input.deletionID); f.advance(3600001); }
    const status = f.deletions.status(input); assert.equal(calls, 5); assert.equal(status.completed, true);
    assert.equal(status.appleAuthorization, "manual-required");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
  } finally { f.close(); }
});

test("missing tokens or an unavailable vault never block data erasure and are reported as requiring manual Apple cleanup", async () => {
  for (const missing of [true, false]) {
    const f = setup();
    try {
      await f.session(); if (missing) f.db.prepare("DELETE FROM auth_refresh_credentials_v1").run();
      else f.db.prepare("UPDATE auth_refresh_credentials_v1 SET sealed_credential=?").run("invalid-ciphertext");
      const input = await f.input(); await f.deleter.request(input);
      const result = await f.finish(input, f.processor());
      assert.equal(result.completed, true); assert.equal(result.appleAuthorization, "manual-required"); assert.equal(f.revoked.length, 0);
    } finally { f.close(); }
  }
});

test("stale public and revocation completions cannot acknowledge a newer worker lease", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input);
    const oldData = await f.deletions.claimPublicBatch(input.deletionID), oldKey = await f.deletions.claimRevocation(input.deletionID);
    f.advance(60001);
    const newData = await f.deletions.claimPublicBatch(input.deletionID), newKey = await f.deletions.claimRevocation(input.deletionID);
    await assert.rejects(() => f.deletions.completePublicBatch(oldData, { ...oldData, remaining: false }), codeIs("DELETION_UNAVAILABLE"));
    await assert.rejects(() => f.deletions.completeRevocation(oldKey), codeIs("DELETION_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 1);
    await f.deletions.completePublicBatch(newData, { ...newData, remaining: false }); await f.deletions.completeRevocation(newKey);
    await f.deletions.acknowledgePrivateCleanup(input); assert.equal(await f.deletions.finalize(input.deletionID), true);
  } finally { f.close(); }
});

test("an authorization already in flight cannot revive the account and its late credential is included in revocation", async () => {
  const f = setup();
  try {
    const initial = await f.session(), challenge = await f.challenge(hash(randomUUID())); let release, entered;
    const wait = new Promise(resolve => { release = resolve; }), started = new Promise(resolve => { entered = resolve; });
    const pending = f.coordinator(async () => { entered(); await wait; return f.token(challenge); }).login({
      challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode });
    await started; f.advance(1); const input = await f.input(); await f.deleter.request(input);
    await f.deletions.acknowledgePrivateCleanup(input); const processor = f.processor();
    await processor.step(input.deletionID); f.advance(60001); assert.equal(await processor.step(input.deletionID), false);
    release(); await assert.rejects(() => pending, codeIs("REAUTH_REQUIRED"));
    assert.equal(await processor.step(input.deletionID), true); assert.equal(f.revoked.length, 2);
    assert.throws(() => f.state.authorize(initial.sessionToken), codeIs("INVALID_SESSION"));
  } finally { f.close(); }
});

test("deletion fences reject old challenges after completion while a fresh signup gets a new internal account", async () => {
  const f = setup();
  try {
    const initial = await f.session(), old = await f.challenge(hash(randomUUID()));
    const expected = await f.state.beginVerification(old.challengeID); await f.state.claimChallenge(old.challengeID, expected.expectedNonce);
    f.advance(1); const input = await f.input(); await f.deleter.request(input); await f.finish(input, f.processor());
    await assert.rejects(() => f.state.completeLogin(old.challengeID, { appleSubject: "synthetic.user", identityExpiresAt: Math.floor(f.clock() / 1000) + 3600 }),
      codeIs("REAUTH_REQUIRED"));
    const fresh = await f.session(); assert.notEqual(fresh.accountID, initial.accountID); f.state.authorize(fresh.sessionToken);
    assert.equal(await f.deletions.finalize(input.deletionID), true); f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("pending revocations are protected from ordinary retention, but a seven-day deadline erases secrets with a manual warning", async () => {
  const f = setup();
  try {
    await f.session(); const subjectHash = appleSubjectHash("synthetic.user");
    f.db.prepare(`INSERT INTO auth_refresh_credentials_v1(credential_id,subject_hash,sealed_credential,state,created_at)
      VALUES (?,?,?,'pending',?)`).run(randomUUID(), subjectHash, "old-unknown-ciphertext", start - 31 * 86400000);
    const input = await f.input(); await f.deleter.request(input); await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 2);
    f.advance(7 * 86400000); await f.processor({ erasePublicDataBatch: async () => { throw new Error("PRIVATE-DATA-ERROR"); } }).step(input.deletionID);
    const status = f.deletions.status(input); assert.equal(status.appleAuthorization, "manual-required"); assert.equal(status.completed, false);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
    assert.equal(status.publicData, "pending");
  } finally { f.close(); }
});

test("exhausted public deletion needs explicit operator recovery and is never treated as finished", async () => {
  const f = setup();
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input);
    const processor = f.processor({ erasePublicDataBatch: async () => { throw new Error("PRIVATE-DATA-ERROR"); } });
    for (let i = 0; i < 10; i++) { await processor.step(input.deletionID); f.advance(3600001); }
    assert.equal(f.deletions.status(input).attentionRequired, true); assert.equal(f.deletions.status(input).completed, false);
    assert.equal(f.deletions.dueDeletionIDs().includes(input.deletionID), false);
    await f.deletions.resumePublicDeletion(input.deletionID);
    assert.equal(f.deletions.dueDeletionIDs().includes(input.deletionID), true);
    assert.equal((await f.finish(input, f.processor())).completed, true);
  } finally { f.close(); }
});

test("deletion state and narrow recovery tickets survive SQLite reopen without storing raw credentials", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-deletion-")), path = join(directory, "state.sqlite");
  let f = setup({ path });
  try {
    await f.session(); const input = await f.input(); await f.deleter.request(input);
    const credentialVault = f.vault, renewalProofs = f.proofs; f.close(); f = setup({ path, credentialVault, renewalProofs });
    assert.equal(f.deletions.status(input).localAccount, "blocked");
    const result = await f.finish(input, f.processor()); assert.equal(result.completed, true);
    const fresh = await f.session(); f.state.authorize(fresh.sessionToken);
    const rows = JSON.stringify(f.db.prepare("SELECT * FROM auth_account_deletions_v1").all());
    assert.equal(rows.includes(input.statusToken), false); assert.equal(rows.includes(syntheticRefresh), false);
    f.advance(30 * 86400000); await f.deletions.purgeCompletedReceipts();
    await assert.rejects(async () => f.deletions.status(input), codeIs("DELETION_UNAVAILABLE"));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("an existing pre-purpose SQLite store is migrated atomically and old challenges remain login-only", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-auth-migration-")), path = join(directory, "state.sqlite");
  const legacy = new DatabaseSync(path), challengeID = randomUUID();
  legacy.exec(`CREATE TABLE auth_challenges_v1(challenge_id TEXT PRIMARY KEY,nonce_hash TEXT NOT NULL,
    expires_at INTEGER NOT NULL,state TEXT NOT NULL,verification_attempts INTEGER NOT NULL DEFAULT 0)`);
  legacy.exec(`CREATE TABLE auth_accounts_v1(account_id TEXT PRIMARY KEY,subject_hash TEXT NOT NULL UNIQUE,
    generation INTEGER NOT NULL DEFAULT 0,disabled INTEGER NOT NULL DEFAULT 0)`);
  legacy.prepare("INSERT INTO auth_accounts_v1(account_id,subject_hash,disabled) VALUES (?,?,1)")
    .run(randomUUID(), appleSubjectHash("legacy.blocked"));
  legacy.prepare("INSERT INTO auth_challenges_v1(challenge_id,nonce_hash,expires_at,state) VALUES (?,?,?,'pending')")
    .run(challengeID, hash("legacy-nonce"), start + 300000); legacy.close();
  let f = setup({ path });
  try {
    await assert.rejects(() => f.state.beginVerification(challengeID, { purpose: "account_deletion" }), codeIs("INVALID_CHALLENGE"));
    assert.equal((await f.state.beginVerification(challengeID)).expectedNonce, hash("legacy-nonce"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_schema_migrations_v1").get().count, 1);
    await assert.rejects(() => f.session("legacy.blocked"), codeIs("ACCOUNT_DISABLED"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_subject_bans_v1").get().count, 1);
    f.close(); f = setup({ path });
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_schema_migrations_v1").get().count, 1);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("a proof that expires during verification cannot commit a deletion", async () => {
  const f = setup();
  try {
    const session = await f.session(), challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "account_deletion" });
    const input = await f.input(); input.challengeID = challenge.challengeID; input.identityToken = f.token(challenge, "synthetic.user", 1);
    const deleter = new AccountDeletionCoordinator({ authenticationState: f.state, deletionState: f.deletions,
      verifier: { async verify(...args) { const identity = await f.verifier.verify(...args); f.advance(2000); return identity; } } });
    await assert.rejects(() => deleter.request(input), codeIs("INVALID_IDENTITY"));
    f.state.authorize(session.sessionToken); assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_account_deletions_v1").get().count, 0);
  } finally { f.close(); }
});

test("deleting an operator-blocked account does not erase the moderation barrier and permit a new signup", async () => {
  const f = setup();
  try {
    const account = await f.session(); await f.state.disableAccount(account.accountID);
    const input = await f.input(); await f.deleter.request(input); await f.finish(input, f.processor());
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_subject_bans_v1").get().count, 1);
    await assert.rejects(() => f.session(), codeIs("ACCOUNT_DISABLED"));
  } finally { f.close(); }
});
