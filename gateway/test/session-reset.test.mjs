import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { DatabaseSync } from "node:sqlite";
import { SessionResetCoordinator } from "../src/session-reset.mjs";
import { appleSubjectHash } from "../src/refresh-credential-vault.mjs";
import { fixture, hash, syntheticCode, codeIs } from "./support/authentication-fixture.mjs";

function setup(options) {
  const f = fixture(options);
  const coordinator = new SessionResetCoordinator({ state: f.state, verifier: f.verifier });
  return { ...f, reset: input => coordinator.reset(input),
    async resetInput(subject = "synthetic.user", expectedAccountID) {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "session_reset" });
      return { challengeID: challenge.challengeID, identityToken: f.token(challenge, subject),
        ...(expectedAccountID !== undefined ? { expectedAccountID } : {}) };
    },
  };
}

test("five lost grants can be reset with fresh Apple proof without another code exchange or new account", async () => {
  const f = setup();
  try {
    const sessions = [];
    for (let i = 0; i < 5; i++) sessions.push(await f.session());
    const other = await f.session("other.user");
    const challenge = await f.challenge(); let exchanges = 0;
    await assert.rejects(() => f.coordinator(async () => { exchanges++; return f.token(challenge); }).login({
      challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode,
    }), codeIs("SESSION_LIMITED"));
    assert.equal(exchanges, 0);
    const credentials = f.db.prepare("SELECT count(*) AS n FROM auth_refresh_credentials_v1").get().n;
    assert.equal(await f.reset(await f.resetInput()), undefined);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_refresh_credentials_v1").get().n, credentials);
    for (const session of sessions) {
      assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
      await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("INVALID_SESSION"));
    }
    f.state.authorize(other.sessionToken);
    const fresh = await f.session(); // Clock has not advanced: order, not milliseconds, distinguishes it.
    assert.equal(fresh.accountID, sessions[0].accountID);
    f.state.authorize(fresh.sessionToken);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_session_reset_fences_v1").get().n, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_accounts_v1").get().n, 2);
  } finally { f.close(); }
});

test("login/deletion challenge purposes and mismatched or invalid JWTs cannot reset sessions", async () => {
  const f = setup();
  try {
    const session = await f.session();
    for (const purpose of ["login", "account_deletion"]) {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose });
      await assert.rejects(() => f.reset({ challengeID: challenge.challengeID, identityToken: f.token(challenge) }), codeIs("INVALID_CHALLENGE"));
    }
    const input = await f.resetInput(), unrelated = await f.challenge(hash(randomUUID()));
    await assert.rejects(() => f.reset({ ...input, identityToken: f.token(unrelated) }), codeIs("INVALID_IDENTITY"));
    await assert.rejects(() => f.reset({ ...input, identityToken: "bad.jwt.signature" }), codeIs("INVALID_IDENTITY"));
    f.state.authorize(session.sessionToken);
  } finally { f.close(); }
});

test("expected account is a check rather than an owner selector; missing accounts are not fabricated", async () => {
  const f = setup();
  try {
    const a = await f.session(), b = await f.session("other.user");
    await assert.rejects(() => f.resetInput("synthetic.user", b.accountID).then(f.reset), codeIs("INVALID_IDENTITY"));
    await assert.rejects(() => f.resetInput("not.registered").then(f.reset), codeIs("NO_ACCOUNT"));
    f.state.authorize(a.sessionToken); f.state.authorize(b.sessionToken);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_accounts_v1").get().n, 2);
  } finally { f.close(); }
});

test("an operator ban and an active deletion cannot be bypassed by session recovery", async () => {
  const f = setup();
  try {
    const session = await f.session();
    await f.state.disableAccount(session.accountID);
    await assert.rejects(() => f.resetInput().then(f.reset), codeIs("ACCOUNT_DISABLED"));
    assert.equal(f.db.prepare("SELECT disabled FROM auth_accounts_v1 WHERE account_id=?").get(session.accountID).disabled, 1);
    // A real active job takes precedence over an operator disable, without clearing either marker.
    f.db.prepare(`INSERT INTO auth_account_deletions_v1(deletion_id,status_hash,account_id,subject_hash,created_at,settle_after)
      VALUES (?,?,?,?,?,?)`).run(randomUUID(), hash("ticket"), session.accountID,
      f.db.prepare("SELECT subject_hash FROM auth_accounts_v1 WHERE account_id=?").get(session.accountID).subject_hash, f.clock(), f.clock() + 60000);
    await assert.rejects(() => f.resetInput().then(f.reset), codeIs("DELETION_IN_PROGRESS"));
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_subject_bans_v1").get().n, 1);
  } finally { f.close(); }
});

test("an earlier pending login cannot resurrect access after reset or poison a later login", async () => {
  const f = setup(); let release;
  try {
    const session = await f.session(), challenge = await f.challenge(hash(randomUUID()));
    const token = f.token(challenge);
    const login = f.coordinator(() => new Promise(resolve => { release = () => resolve(token); })).login({
      challengeID: challenge.challengeID, identityToken: token, authorizationCode: syntheticCode,
    });
    while (!release) await new Promise(resolve => setImmediate(resolve));
    await f.reset(await f.resetInput());
    const fresh = await f.session();
    release(); await assert.rejects(() => login, codeIs("REAUTH_REQUIRED"));
    assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
    f.state.authorize(fresh.sessionToken);
    assert.equal(f.db.prepare("SELECT state FROM auth_refresh_credentials_v1 WHERE credential_id=?").get(challenge.challengeID).state, "pending");
  } finally { release?.(); f.close(); }
});

test("an in-flight provider renewal cannot survive reset or mark a later login as requiring reauthentication", async () => {
  const f = setup(); let release;
  try {
    const session = await f.session(); f.advance(86400000);
    const renewal = f.renewal(() => new Promise(resolve => { release = () => resolve({
      identityToken: f.token(null), refreshToken: "SYNTHETIC-ROTATED-REFRESH",
    }); })).renew(session.renewalToken);
    while (!release) await new Promise(resolve => setImmediate(resolve));
    await f.reset(await f.resetInput()); const fresh = await f.session();
    release(); await assert.rejects(() => renewal, codeIs("INVALID_SESSION"));
    const next = await f.renewal().renew(fresh.renewalToken); f.state.authorize(next.sessionToken);
    assert.equal(f.db.prepare("SELECT reauth_required FROM auth_apple_state_v1 WHERE account_id=?").get(fresh.accountID).reauth_required, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_refresh_credentials_v1").get().n, 3);
  } finally { release?.(); f.close(); }
});

test("older reset proofs and consumed reset requests cannot revoke a newly created grant", async () => {
  const f = setup();
  try {
    await f.session(); const old = await f.resetInput(), current = await f.resetInput();
    await f.reset(current); const fresh = await f.session();
    await assert.rejects(() => f.reset(old), codeIs("REAUTH_REQUIRED"));
    await assert.rejects(() => f.reset(current), codeIs("INVALID_CHALLENGE"));
    f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("logout-all also fences login requests that had not completed yet", async () => {
  const f = setup();
  try {
    const session = await f.session(), old = await f.challenge(hash(randomUUID()));
    await f.state.revokeAllSessions(session.sessionToken);
    let exchanges = 0;
    await assert.rejects(() => f.coordinator(async () => { exchanges++; return f.token(old); }).login({
      challengeID: old.challengeID, identityToken: f.token(old), authorizationCode: syntheticCode,
    }), codeIs("REAUTH_REQUIRED"));
    assert.equal(exchanges, 0);
    f.state.authorize((await f.session()).sessionToken);
  } finally { f.close(); }
});

test("transaction failure rolls back generation, challenge consumption, fence and order atomically", async () => {
  const f = setup({ sqlHook: sql => { if (sql.startsWith("INSERT INTO auth_session_reset_fences_v1")) throw new Error("PRIVATE-RESET-SQL"); } });
  try {
    const session = await f.session(), input = await f.resetInput();
    const order = f.db.prepare("SELECT value FROM auth_event_order_v1").get().value;
    await assert.rejects(() => f.reset(input), codeIs("STATE_UNAVAILABLE"));
    f.state.authorize(session.sessionToken);
    assert.equal(f.db.prepare("SELECT value FROM auth_event_order_v1").get().value, order);
    assert.equal(f.db.prepare("SELECT count(*) AS n FROM auth_session_reset_fences_v1").get().n, 0);
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1 WHERE challenge_id=?").get(input.challengeID).state, "claimed");
  } finally { f.close(); }
});

test("lost durability response never restores old access or allows a consumed reset to affect new sessions", async () => {
  let armed = false;
  const f = setup({ sqlHook: sql => { if (sql.startsWith("INSERT INTO auth_session_reset_fences_v1")) armed = true; },
    syncHook: async () => { if (armed) throw new Error("PRIVATE-RESET-SYNC"); } });
  try {
    const old = await f.session(), input = await f.resetInput();
    await assert.rejects(() => f.reset(input), codeIs("STATE_UNAVAILABLE")); armed = false;
    assert.throws(() => f.state.authorize(old.sessionToken), codeIs("INVALID_SESSION"));
    const fresh = await f.session();
    await assert.rejects(() => f.reset(input), codeIs("INVALID_CHALLENGE"));
    f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("reset order and account identity survive a SQLite reopen at the same clock instant", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-session-reset-")), path = join(directory, "state.sqlite");
  let f = setup({ path });
  try {
    const session = await f.session(), old = await f.challenge(hash(randomUUID()));
    await f.reset(await f.resetInput()); const credentialVault = f.vault, renewalProofs = f.proofs;
    f.close(); f = setup({ path, credentialVault, renewalProofs });
    assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.coordinator(async () => f.token(old)).login({ challengeID: old.challengeID,
      identityToken: f.token(old), authorizationCode: syntheticCode }), codeIs("REAUTH_REQUIRED"));
    const fresh = await f.session(); assert.equal(fresh.accountID, session.accountID);
    f.state.authorize(fresh.sessionToken);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("reset fails safely if its signed identity expires before commit", async () => {
  const f = setup();
  try {
    const session = await f.session();
    const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "session_reset" });
    const coordinator = new SessionResetCoordinator({ state: f.state, verifier: { async verify(token, context) {
      const result = await f.verifier.verify(token, context); f.advance(2000); return result;
    } } });
    await assert.rejects(() => coordinator.reset({ challengeID: challenge.challengeID, identityToken: f.token(challenge, "synthetic.user", 1) }),
      codeIs("INVALID_IDENTITY"));
    f.state.authorize(session.sessionToken);
  } finally { f.close(); }
});

test("upgrading a pre-order store fences legacy logins after an earlier logout-all without changing the account ID", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-reset-upgrade-")), path = join(directory, "state.sqlite");
  const old = new DatabaseSync(path), accountID = randomUUID(), challengeID = randomUUID(), nonce = "synthetic-legacy-nonce";
  old.exec(`CREATE TABLE auth_challenges_v1(challenge_id TEXT PRIMARY KEY,nonce_hash TEXT NOT NULL,
    expires_at INTEGER NOT NULL,state TEXT NOT NULL,verification_attempts INTEGER NOT NULL DEFAULT 0,purpose TEXT NOT NULL DEFAULT 'login');
    CREATE TABLE auth_accounts_v1(account_id TEXT PRIMARY KEY,subject_hash TEXT NOT NULL UNIQUE,generation INTEGER NOT NULL DEFAULT 0,disabled INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE auth_schema_migrations_v1(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL);
    INSERT INTO auth_schema_migrations_v1 VALUES ('challenge-purpose-v1',0);`);
  old.prepare("INSERT INTO auth_accounts_v1(account_id,subject_hash,generation) VALUES (?,?,1)")
    .run(accountID, appleSubjectHash("synthetic.user"));
  // The same clock as the fixture, to verify that no timestamp trick is needed for the new login.
  old.prepare("INSERT INTO auth_challenges_v1(challenge_id,nonce_hash,expires_at,state) VALUES (?,?,?,'pending')")
    .run(challengeID, hash(nonce), 1794603600000 + 300000); old.close();
  const f = setup({ path });
  try {
    let exchanges = 0;
    await assert.rejects(() => f.coordinator(async () => { exchanges++; return "unused"; }).login({ challengeID,
      identityToken: f.token({ nonce }), authorizationCode: syntheticCode }), codeIs("REAUTH_REQUIRED"));
    assert.equal(exchanges, 0);
    const fresh = await f.session(); assert.equal(fresh.accountID, accountID); f.state.authorize(fresh.sessionToken);
    assert.equal(f.db.prepare("SELECT generation FROM auth_accounts_v1").get().generation, 1);
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});
