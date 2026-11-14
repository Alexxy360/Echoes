import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, randomBytes, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthenticationState } from "../src/authentication-state.mjs";
import { AppleLoginCoordinator } from "../src/apple-login.mjs";
import { RefreshCredentialVault, appleSubjectHash } from "../src/refresh-credential-vault.mjs";
import { AppleClientSecret, AppleOAuthClient, AppleOAuthError } from "../src/apple-oauth.mjs";
import { RenewalProofs } from "../src/renewal-proofs.mjs";
import { fixture, hash, start, syntheticCode, syntheticRefresh, codeIs } from "./support/authentication-fixture.mjs";

test("challenge persists only a nonce hash and expires after five minutes", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge();
    const stored = f.db.prepare("SELECT * FROM auth_challenges_v1").get();
    assert.equal(stored.nonce_hash, hash(challenge.nonce));
    assert.equal(JSON.stringify(stored).includes(challenge.nonce), false);
    assert.equal(challenge.expiresAt, start / 1000 + 300);
    f.advance(300000); await assert.rejects(() => f.state.beginVerification(challenge.challengeID), codeIs("INVALID_CHALLENGE"));
  } finally { f.close(); }
});

test("issuance budget and per-challenge verification attempt limits persist in SQLite", async () => {
  const f = fixture();
  try {
    const issued = await Promise.all(Array.from({ length: 5 }, () => f.challenge()));
    await assert.rejects(() => f.challenge(), codeIs("ISSUE_LIMITED"));
    for (let i = 0; i < 5; i++) await f.state.beginVerification(issued[0].challengeID);
    await assert.rejects(() => f.state.beginVerification(issued[0].challengeID), codeIs("INVALID_CHALLENGE"));
    f.advance(300000); await f.challenge();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_issue_budget_v1").get().count, 2);
  } finally { f.close(); }
});

test("real synthetic JWT verification, code identity binding and session creation work together", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); const idToken = f.token(challenge);
    let calls = 0;
    const service = f.coordinator(async input => {
      calls++; assert.deepEqual(input, { authorizationCode: syntheticCode });
      assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
      return idToken;
    });
    const session = await service.login({ challengeID: challenge.challengeID, identityToken: idToken, authorizationCode: syntheticCode });
    assert.equal(calls, 1); assert.equal(session.sessionToken.length, 80);
    assert.equal(session.expiresAt, start / 1000 + 600);
    assert.deepEqual(f.state.authorize(session.sessionToken), { accountID: session.accountID, expiresAt: session.expiresAt });
    const stored = JSON.stringify({ challenges: f.db.prepare("SELECT * FROM auth_challenges_v1").all(),
      sessions: f.db.prepare("SELECT * FROM auth_sessions_v1").all(), accounts: f.db.prepare("SELECT * FROM auth_accounts_v1").all() });
    for (const secret of [session.sessionToken, challenge.nonce, idToken, syntheticCode, "synthetic.user", "PRIVATE-SYNTHETIC@example.invalid"]) {
      assert.equal(stored.includes(secret), false);
    }
    await assert.rejects(() => service.login({ challengeID: challenge.challengeID, identityToken: idToken,
      authorizationCode: syntheticCode }), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 1);
  } finally { f.close(); }
});

test("concurrent requests can exchange the code and mint a session only once", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); const idToken = f.token(challenge);
    let release, started, calls = 0;
    const waiting = new Promise(resolve => { release = resolve; });
    const entered = new Promise(resolve => { started = resolve; });
    const service = f.coordinator(async () => { calls++; started(); await waiting; return idToken; });
    const outcomes = Promise.allSettled(Array.from({ length: 8 }, () => service.login({
      challengeID: challenge.challengeID, identityToken: idToken, authorizationCode: syntheticCode,
    })));
    await entered; assert.equal(calls, 1); release();
    const results = await outcomes;
    assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 1);
    assert.equal(calls, 1);
  } finally { f.close(); }
});

test("invalid identity cannot claim the challenge or invoke code exchange", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); let calls = 0;
    const idToken = f.token(challenge); const service = f.coordinator(async () => { calls++; return idToken; });
    await assert.rejects(() => service.login({ challengeID: challenge.challengeID,
      identityToken: "invalid.token.signature", authorizationCode: syntheticCode }), codeIs("INVALID_IDENTITY"));
    assert.equal(calls, 0); assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "pending");
    await service.login({ challengeID: challenge.challengeID, identityToken: idToken, authorizationCode: syntheticCode });
    assert.equal(calls, 1);
  } finally { f.close(); }
});

test("an exchange token for a different identity cannot create a session", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); const service = f.coordinator(async () => f.token(challenge, "another.user"));
    await assert.rejects(() => service.login({ challengeID: challenge.challengeID,
      identityToken: f.token(challenge), authorizationCode: syntheticCode }), codeIs("INVALID_IDENTITY"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
    const pending = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").get();
    assert.equal(pending.state, "pending"); assert.equal(pending.account_id, null);
    assert.equal(pending.subject_hash, appleSubjectHash("another.user"));
  } finally { f.close(); }
});

test("an unknown exchange outcome never retries the one-use code or exposes its failure details", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); let calls = 0;
    const service = f.coordinator(async () => { calls++; throw new Error("PRIVATE-SYNTHETIC-EXCHANGE"); });
    const input = { challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode };
    await assert.rejects(() => service.login(input), codeIs("EXCHANGE_UNAVAILABLE"));
    await assert.rejects(() => service.login(input), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 1); assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
  } finally { f.close(); }
});

test("claim durability must succeed before external code exchange", async () => {
  let fail = false; const f = fixture({ syncHook: async count => { if (fail && count === 3) throw new Error("PRIVATE-STORAGE"); } });
  try {
    const challenge = await f.challenge(); fail = true; let calls = 0;
    const service = f.coordinator(async () => { calls++; return f.token(challenge); });
    await assert.rejects(() => service.login({ challengeID: challenge.challengeID,
      identityToken: f.token(challenge), authorizationCode: syntheticCode }), codeIs("STATE_UNAVAILABLE"));
    assert.equal(calls, 0);
  } finally { f.close(); }
});

test("failed final durability does not return a token and the challenge cannot be reused", async () => {
  const f = fixture({ syncHook: async count => { if (count === 6) throw new Error("PRIVATE-STORAGE"); } });
  try {
    const challenge = await f.challenge(); let calls = 0;
    const service = f.coordinator(async () => { calls++; return f.token(challenge); });
    const input = { challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode };
    await assert.rejects(() => service.login(input), codeIs("STATE_UNAVAILABLE"));
    await assert.rejects(() => service.login(input), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 1);
    assert.equal(f.db.prepare("SELECT state FROM auth_refresh_credentials_v1").get().state, "bound");
  } finally { f.close(); }
});

test("a failed session insert rolls back account creation and challenge consumption", async () => {
  const f = fixture({ sqlHook: sql => { if (sql.startsWith("INSERT INTO auth_sessions_v1")) throw new Error("PRIVATE-SQL"); } });
  try {
    await assert.rejects(() => f.session(), codeIs("STATE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT state FROM auth_refresh_credentials_v1").get().state, "pending");
  } finally { f.close(); }
});

test("sessions expire at the earlier identity expiry and malformed/substituted tokens are denied", async () => {
  const f = fixture();
  try {
    const session = await f.session("synthetic.user", 30);
    assert.equal(session.expiresAt, start / 1000 + 30);
    for (const token of [undefined, "", session.sessionToken + "x", randomUUID() + session.sessionToken.slice(36),
      session.sessionToken.slice(0, -1) + (session.sessionToken.endsWith("A") ? "B" : "A")]) {
      assert.throws(() => f.state.authorize(token), codeIs("INVALID_SESSION"));
    }
    f.advance(30000); assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
  } finally { f.close(); }
});

test("individual and all-session logout preserve unrelated accounts and allow a fresh login", async () => {
  const f = fixture();
  try {
    const first = await f.session(), second = await f.session(), other = await f.session("another.user");
    assert.equal(first.accountID, second.accountID); assert.notEqual(first.accountID, other.accountID);
    await f.state.revokeSession(first.sessionToken);
    assert.throws(() => f.state.authorize(first.sessionToken), codeIs("INVALID_SESSION"));
    f.state.authorize(second.sessionToken);
    await f.state.revokeAllSessions(second.sessionToken);
    assert.throws(() => f.state.authorize(second.sessionToken), codeIs("INVALID_SESSION"));
    f.state.authorize(other.sessionToken);
    const fresh = await f.session(); assert.equal(fresh.accountID, first.accountID); f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("account disable stops existing sessions and login completing after the disable", async () => {
  const f = fixture();
  try {
    const first = await f.session(); const challenge = await f.challenge(); const idToken = f.token(challenge);
    let started, release;
    const entered = new Promise(resolve => { started = resolve; }); const waiting = new Promise(resolve => { release = resolve; });
    const pending = f.coordinator(async () => { started(); await waiting; return idToken; }).login({
      challengeID: challenge.challengeID, identityToken: idToken, authorizationCode: syntheticCode,
    });
    await entered; await f.state.disableAccount(first.accountID); release();
    await assert.rejects(() => pending, codeIs("ACCOUNT_DISABLED"));
    assert.throws(() => f.state.authorize(first.sessionToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.session(), codeIs("ACCOUNT_DISABLED"));
  } finally { f.close(); }
});

test("five active sessions per account are bounded without deleting another valid session", async () => {
  const f = fixture();
  try {
    const sessions = [];
    for (let i = 0; i < 5; i++) sessions.push(await f.session());
    await assert.rejects(() => f.session(), codeIs("SESSION_LIMITED"));
    for (const session of sessions) f.state.authorize(session.sessionToken);
    await f.state.revokeSession(sessions[0].sessionToken); const fresh = await f.session(); f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("a database reopen preserves claimed challenges, valid sessions and revocations", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-auth-state-")); const path = join(directory, "auth.sqlite");
  let f = fixture({ path });
  try {
    const session = await f.session(); const crash = await f.challenge();
    const expected = await f.state.beginVerification(crash.challengeID); await f.state.claimChallenge(crash.challengeID, expected.expectedNonce);
    f.close(); f = fixture({ path }); f.state.authorize(session.sessionToken);
    await assert.rejects(() => f.state.beginVerification(crash.challengeID), codeIs("INVALID_CHALLENGE"));
    await f.state.revokeAllSessions(session.sessionToken); f.close(); f = fixture({ path });
    assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("expiry cleanup removes a bounded batch and retains durable account identity", async () => {
  const f = fixture();
  try {
    const session = await f.session();
    for (let i = 0; i < 150; i++) f.db.prepare(`INSERT INTO auth_challenges_v1
      (challenge_id,nonce_hash,expires_at,state) VALUES (?,?,?,'pending')`).run(randomUUID(), "0".repeat(64), start - 1);
    await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_challenges_v1 WHERE expires_at<=?").get(start).count, 50);
    f.state.authorize(session.sessionToken); f.advance(600000); await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 1);
  } finally { f.close(); }
});

test("missing transaction/durability or code-exchange dependencies never become a permissive default", () => {
  assert.throws(() => new AuthenticationState({ sql: {} }), codeIs("STATE_UNAVAILABLE"));
  assert.throws(() => new AppleLoginCoordinator({ state: {}, verifier: { verify() {} } }), codeIs("STATE_UNAVAILABLE"));
});

test("the concrete OAuth adapter, JWT verifier, vault and SQLite session work together without exposing credentials", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(), idToken = f.token(challenge);
    const signingPair = generateKeyPairSync("ec", { namedCurve: "prime256v1" }); let calls = 0;
    const client = new AppleOAuthClient({ clientSecret: new AppleClientSecret({
      privateKeyPEM: signingPair.privateKey.export({ type: "pkcs8", format: "pem" }), keyID: "TESTKEY123", clock: f.clock,
    }), fetchImplementation: async request => {
      calls++; const form = new URLSearchParams(await request.text()); assert.equal(form.get("code"), syntheticCode);
      assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
      return Response.json({ access_token: "SYNTHETIC-ACCESS", token_type: "Bearer", expires_in: 3600,
        refresh_token: syntheticRefresh, id_token: idToken });
    } });
    const coordinator = new AppleLoginCoordinator({ state: f.state, verifier: f.verifier, credentialVault: f.vault,
      exchangeAuthorizationCode: input => client.exchangeAuthorizationCode(input) });
    const session = await coordinator.login({ challengeID: challenge.challengeID, identityToken: idToken, authorizationCode: syntheticCode });
    const row = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").get();
    assert.equal(row.state, "bound"); assert.equal(row.account_id, session.accountID); assert.equal(row.credential_id, challenge.challengeID);
    assert.equal(f.vault.open(row.sealed_credential, { credentialID: row.credential_id,
      subjectHash: appleSubjectHash("synthetic.user") }), syntheticRefresh);
    const stored = JSON.stringify(f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").all());
    for (const sensitive of [syntheticRefresh, syntheticCode, idToken, "synthetic.user", session.sessionToken]) assert.equal(stored.includes(sensitive), false);
    assert.deepEqual(Object.keys(session).sort(), ["accountID", "expiresAt", "renewalExpiresAt", "renewalToken", "sessionToken"]);
    assert.equal(calls, 1); f.state.authorize(session.sessionToken);
  } finally { f.close(); }
});

test("a session cannot be completed without the staged credential matching its verified subject", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(); const expected = await f.state.beginVerification(challenge.challengeID);
    await f.state.claimChallenge(challenge.challengeID, expected.expectedNonce);
    const identity = { appleSubject: "synthetic.user", identityExpiresAt: start / 1000 + 3600 };
    await assert.rejects(() => f.state.completeLogin(challenge.challengeID, identity), codeIs("STATE_UNAVAILABLE"));
    await f.state.reserveLoginCredential(challenge.challengeID, identity.appleSubject);
    const sealedCredential = f.vault.seal(syntheticRefresh, { credentialID: challenge.challengeID, subjectHash: appleSubjectHash("another.user") });
    await f.state.stageRefreshCredential(challenge.challengeID, { appleSubject: "another.user", sealedCredential });
    await assert.rejects(() => f.state.completeLogin(challenge.challengeID, identity), codeIs("STATE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT state FROM auth_refresh_credentials_v1").get().state, "pending");
  } finally { f.close(); }
});

test("staging cannot overwrite a credential, use an unclaimed challenge or store a plaintext fallback", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge();
    const sealedCredential = f.vault.seal(syntheticRefresh, { credentialID: challenge.challengeID, subjectHash: appleSubjectHash("synthetic.user") });
    const input = { appleSubject: "synthetic.user", sealedCredential };
    await assert.rejects(() => f.state.stageRefreshCredential(challenge.challengeID, input), codeIs("INVALID_CHALLENGE"));
    const expected = await f.state.beginVerification(challenge.challengeID); await f.state.claimChallenge(challenge.challengeID, expected.expectedNonce);
    await f.state.reserveLoginCredential(challenge.challengeID, input.appleSubject);
    for (const invalid of [syntheticRefresh, "{", "null", JSON.stringify({ v: 1, token: syntheticRefresh })]) {
      await assert.rejects(() => f.state.stageRefreshCredential(challenge.challengeID, { ...input, sealedCredential: invalid }), codeIs("STATE_UNAVAILABLE"));
    }
    await f.state.stageRefreshCredential(challenge.challengeID, input);
    await assert.rejects(() => f.state.stageRefreshCredential(challenge.challengeID, input), codeIs("STATE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT sealed_credential FROM auth_refresh_credentials_v1").get().sealed_credential, sealedCredential);
  } finally { f.close(); }
});

test("credential durability failure suppresses session creation and never replays the consumed code", async () => {
  const f = fixture({ syncHook: async count => { if (count === 5) throw new Error("PRIVATE-CREDENTIAL-STORAGE"); } });
  try {
    const challenge = await f.challenge(); let calls = 0;
    const coordinator = f.coordinator(async () => { calls++; return f.token(challenge); });
    const input = { challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode };
    await assert.rejects(() => coordinator.login(input), codeIs("STATE_UNAVAILABLE"));
    await assert.rejects(() => coordinator.login(input), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 1); assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT state FROM auth_refresh_credentials_v1").get().state, "pending");
  } finally { f.close(); }
});

test("an exchange without a refresh credential or using the obsolete bare-token result cannot mint a session", async () => {
  for (const bareToken of [false, true]) {
    const f = fixture();
    try {
      const challenge = await f.challenge(), idToken = f.token(challenge);
      const coordinator = new AppleLoginCoordinator({ state: f.state, verifier: f.verifier, credentialVault: f.vault,
        exchangeAuthorizationCode: async () => bareToken ? idToken : { identityToken: idToken } });
      await assert.rejects(() => coordinator.login({ challengeID: challenge.challengeID, identityToken: idToken,
        authorizationCode: syntheticCode }), codeIs(bareToken ? "INVALID_IDENTITY" : "STATE_UNAVAILABLE"));
      assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
      assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    } finally { f.close(); }
  }
});

test("expiry during exchange retains the encrypted pending credential without creating a session or blindly revoking Apple", async () => {
  const f = fixture();
  try {
    const challenge = await f.challenge(), idToken = f.token(challenge);
    const coordinator = f.coordinator(async () => {
      f.advance(301000); await f.state.purgeExpired();
      assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
      return f.token(challenge);
    });
    await assert.rejects(() => coordinator.login({ challengeID: challenge.challengeID, identityToken: idToken,
      authorizationCode: syntheticCode }), codeIs("INVALID_CHALLENGE"));
    const row = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").get();
    assert.equal(row.state, "pending"); assert.equal(row.account_id, null);
    assert.equal(f.vault.open(row.sealed_credential, { credentialID: row.credential_id, subjectHash: row.subject_hash }), syntheticRefresh);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
    f.advance(86400000); await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_challenges_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 1);
  } finally { f.close(); }
});

test("a database reopen preserves encrypted credentials and requires the same separately held key", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-auth-vault-")), path = join(directory, "auth.sqlite");
  const credentialVault = new RefreshCredentialVault({ activeKeyID: "test-v1", keys: { "test-v1": randomBytes(32).toString("base64url") } });
  let f = fixture({ path, credentialVault });
  try {
    const session = await f.session(); const before = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").get();
    f.close(); f = fixture({ path, credentialVault });
    const after = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1").get(); assert.deepEqual(after, before);
    f.state.authorize(session.sessionToken);
    const binding = { credentialID: after.credential_id, subjectHash: appleSubjectHash("synthetic.user") };
    assert.equal(f.vault.open(after.sealed_credential, binding), syntheticRefresh);
    const wrongVault = new RefreshCredentialVault({ activeKeyID: "test-v1", keys: { "test-v1": randomBytes(32).toString("base64url") } });
    assert.throws(() => wrongVault.open(after.sealed_credential, binding));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("renewal proofs are separate from access tokens, stored as hashes and have an absolute thirty-day limit", async () => {
  const f = fixture();
  try {
    const session = await f.session();
    assert.ok(session.renewalToken.length <= 120); assert.notEqual(session.sessionToken, session.renewalToken);
    assert.equal(session.renewalExpiresAt, start / 1000 + 30 * 86400);
    assert.throws(() => f.state.authorize(session.renewalToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.renewal().renew(session.sessionToken), codeIs("INVALID_SESSION"));
    const stored = JSON.stringify(f.db.prepare("SELECT * FROM auth_renewal_grants_v1").all());
    assert.equal(stored.includes(session.renewalToken), false); assert.equal(stored.includes(syntheticRefresh), false);
  } finally { f.close(); }
});

test("renewal works after access expiry and cleanup, rotates both proofs, and cannot extend its absolute deadline", async () => {
  const f = fixture();
  try {
    const initial = await f.session(); let calls = 0;
    const service = f.renewal(async () => { calls++; throw new Error("unexpected Apple request"); });
    f.advance(2 * 3600000); await f.state.purgeExpired();
    assert.throws(() => f.state.authorize(initial.sessionToken), codeIs("INVALID_SESSION"));
    const next = await service.renew(initial.renewalToken);
    assert.equal(calls, 0); assert.equal(next.accountID, initial.accountID); assert.equal(next.renewalExpiresAt, initial.renewalExpiresAt);
    assert.notEqual(next.renewalToken, initial.renewalToken); assert.notEqual(next.sessionToken, initial.sessionToken);
    f.state.authorize(next.sessionToken);
    await assert.rejects(() => service.renew(initial.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.throws(() => f.state.authorize(next.sessionToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => service.renew(next.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
  } finally { f.close(); }
});

test("concurrent renewals can rotate one proof only once without making an Apple request", async () => {
  const f = fixture();
  try {
    const session = await f.session(); let release, entered;
    const waiting = new Promise(resolve => { release = resolve; }); const started = new Promise(resolve => { entered = resolve; });
    const complete = f.state.completeRenewal.bind(f.state);
    f.state.completeRenewal = async (...args) => { entered(); await waiting; return complete(...args); };
    const service = f.renewal();
    const pending = Promise.allSettled(Array.from({ length: 8 }, () => service.renew(session.renewalToken)));
    await started; release(); const results = await pending;
    assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_renewal_grants_v1").get().count, 1);
    const next = results.find(result => result.status === "fulfilled").value; f.state.authorize(next.sessionToken);
  } finally { f.close(); }
});

test("Apple is checked at most once per day across two grants of the same account", async () => {
  const f = fixture();
  try {
    const first = await f.session(), second = await f.session(); let calls = 0;
    const service = f.renewal(async refresh => {
      calls++; assert.equal(refresh, syntheticRefresh); return { identityToken: f.token(null) };
    });
    f.advance(86400000);
    const a = await service.renew(first.renewalToken), b = await service.renew(second.renewalToken);
    assert.equal(calls, 1); f.state.authorize(a.sessionToken); f.state.authorize(b.sessionToken);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_credential_reservations_v1").get().count, 0);
    const c = await service.renew(a.renewalToken); assert.equal(calls, 1); f.state.authorize(c.sessionToken);
  } finally { f.close(); }
});

test("a provider check in progress excludes another grant without consuming that other proof", async () => {
  const f = fixture();
  try {
    const a = await f.session(), b = await f.session(); f.advance(86400000);
    let release, entered, calls = 0; const wait = new Promise(resolve => { release = resolve; });
    const started = new Promise(resolve => { entered = resolve; });
    const service = f.renewal(async () => { calls++; entered(); await wait; return { identityToken: f.token(null) }; });
    const pending = service.renew(a.renewalToken); await started;
    await assert.rejects(() => service.renew(b.renewalToken), codeIs("RENEWAL_BUSY"));
    release(); const next = await pending; f.state.authorize(next.sessionToken);
    const other = await service.renew(b.renewalToken); f.state.authorize(other.sessionToken); assert.equal(calls, 1);
  } finally { f.close(); }
});

test("rotated Apple refresh credentials are encrypted under a new binding and used for the next daily check", async () => {
  const f = fixture();
  try {
    const initial = await f.session(); let calls = 0;
    const service = f.renewal(async refresh => {
      calls++; assert.equal(refresh, calls === 1 ? syntheticRefresh : "SYNTHETIC-ROTATED-REFRESH");
      return { identityToken: f.token(null), ...(calls === 1 ? { refreshToken: "SYNTHETIC-ROTATED-REFRESH" } : {}) };
    });
    f.advance(86400000); const next = await service.renew(initial.renewalToken);
    const head = f.db.prepare("SELECT credential_id FROM auth_apple_state_v1").get().credential_id;
    const row = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1 WHERE credential_id=?").get(head);
    assert.notEqual(head, initial.renewalToken.slice(0, 36));
    assert.equal(f.vault.open(row.sealed_credential, { credentialID: head, subjectHash: row.subject_hash }), "SYNTHETIC-ROTATED-REFRESH");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 2);
    assert.equal(JSON.stringify(row).includes("SYNTHETIC-ROTATED-REFRESH"), false);
    f.advance(86400000); const third = await service.renew(next.renewalToken); f.state.authorize(third.sessionToken);
    assert.equal(calls, 2);
  } finally { f.close(); }
});

test("an Apple rejection invalidates this account's existing access and renewal grants but preserves another account", async () => {
  const f = fixture();
  try {
    const a = await f.session(), b = await f.session(); f.advance(86400000 - 120000);
    const recent = await f.renewal().renew(a.renewalToken); f.advance(120000);
    const other = await f.session("another.user");
    const service = f.renewal(async () => { throw new AppleOAuthError("TOKEN_REJECTED"); });
    await assert.rejects(() => service.renew(b.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.throws(() => f.state.authorize(recent.sessionToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.renewal().renew(recent.renewalToken), codeIs("INVALID_SESSION"));
    f.state.authorize(other.sessionToken);
    const fresh = await f.session(); f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("an unknown provider outcome cannot be retried automatically or treated as success", async () => {
  const f = fixture();
  try {
    const first = await f.session(), second = await f.session(); f.advance(86400000); let calls = 0;
    const service = f.renewal(async () => { calls++; throw new Error("SYNTHETIC-PRIVATE-PROVIDER-DETAIL"); });
    await assert.rejects(() => service.renew(first.renewalToken), codeIs("REAUTH_REQUIRED"));
    await assert.rejects(() => service.renew(first.renewalToken), codeIs("REAUTH_REQUIRED"));
    await assert.rejects(() => service.renew(second.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.equal(calls, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_credential_reservations_v1").get().count, 1);
    const fresh = await f.session(); const next = await f.renewal().renew(fresh.renewalToken); f.state.authorize(next.sessionToken);
  } finally { f.close(); }
});

test("a refresh response for another signed identity never changes the account binding", async () => {
  const f = fixture();
  try {
    const session = await f.session(); f.advance(86400000);
    await assert.rejects(() => f.renewal(async () => ({ identityToken: f.token(null, "another.user") })).renew(session.renewalToken),
      codeIs("INVALID_IDENTITY"));
    assert.equal(f.db.prepare("SELECT subject_hash FROM auth_accounts_v1").get().subject_hash, appleSubjectHash("synthetic.user"));
    assert.equal(f.db.prepare("SELECT reauth_required FROM auth_apple_state_v1").get().reauth_required, 1);
  } finally { f.close(); }
});

test("an account block during provider validation cannot be undone by a successful late response", async () => {
  const f = fixture();
  try {
    const session = await f.session(); f.advance(86400000);
    const service = f.renewal(async () => { await f.state.disableAccount(session.accountID); return { identityToken: f.token(null) }; });
    await assert.rejects(() => service.renew(session.renewalToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.session(), codeIs("ACCOUNT_DISABLED"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1 WHERE expires_at>?").get(f.clock()).count, 0);
  } finally { f.close(); }
});

test("a newer interactive login supersedes a late failed provider check without losing the new proof", async () => {
  const f = fixture();
  try {
    const session = await f.session(); f.advance(86400000); let fresh;
    const service = f.renewal(async () => { fresh = await f.session(); throw new AppleOAuthError("TOKEN_REJECTED"); });
    await assert.rejects(() => service.renew(session.renewalToken), codeIs("REAUTH_REQUIRED"));
    f.state.authorize(fresh.sessionToken); const next = await f.renewal().renew(fresh.renewalToken); f.state.authorize(next.sessionToken);
    assert.equal(f.db.prepare("SELECT reauth_required FROM auth_apple_state_v1").get().reauth_required, 0);
  } finally { f.close(); }
});

test("a newer login also prevents a late successful provider response from overwriting its credential", async () => {
  const f = fixture();
  try {
    const old = await f.session(); f.advance(86400000); let fresh;
    const service = f.renewal(async () => {
      fresh = await f.session(); return { identityToken: f.token(null), refreshToken: "SYNTHETIC-STALE-ROTATION" };
    });
    await assert.rejects(() => service.renew(old.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.equal(f.db.prepare("SELECT credential_id FROM auth_apple_state_v1").get().credential_id, fresh.renewalToken.slice(0, 36));
    f.state.authorize(fresh.sessionToken);
  } finally { f.close(); }
});

test("failed lease durability happens before contacting Apple", async () => {
  let fail = false, calls = 0;
  const f = fixture({ syncHook: async () => { if (fail) throw new Error("SYNTHETIC-PRIVATE-STORAGE"); } });
  try {
    const session = await f.session(); f.advance(86400000); fail = true;
    await assert.rejects(() => f.renewal(async () => { calls++; return { identityToken: f.token(null) }; }).renew(session.renewalToken),
      codeIs("STATE_UNAVAILABLE"));
    assert.equal(calls, 0);
  } finally { f.close(); }
});

test("failed rotation durability returns no new tokens and cannot roll back to an old proof", async () => {
  const f = fixture({ syncHook: async count => { if (count === 8) throw new Error("SYNTHETIC-PRIVATE-STORAGE"); } });
  try {
    const session = await f.session();
    await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("STATE_UNAVAILABLE"));
    await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.throws(() => f.state.authorize(session.sessionToken), codeIs("INVALID_SESSION"));
    assert.equal(f.db.prepare("SELECT state FROM auth_renewal_grants_v1").get().state, "replayed");
  } finally { f.close(); }
});

test("a transaction failure during rotation cannot leak a partially valid new access token", async () => {
  let fail = false;
  const f = fixture({ sqlHook: sql => { if (fail && sql.startsWith("INSERT INTO auth_sessions_v1")) throw new Error("PRIVATE-SQL"); } });
  try {
    const session = await f.session(); fail = true;
    await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("STATE_UNAVAILABLE"));
    f.state.authorize(session.sessionToken); // Existing access survives a rolled-back transaction, until its original expiry.
    assert.equal(f.db.prepare("SELECT state FROM auth_renewal_grants_v1").get().state, "uncertain");
    await assert.rejects(() => f.renewal().renew(session.renewalToken), codeIs("REAUTH_REQUIRED"));
  } finally { f.close(); }
});

test("logout via access or an unexpired renewal proof cancels both authorities, including after access cleanup", async () => {
  const f = fixture();
  try {
    const a = await f.session(), b = await f.session(); await f.state.revokeSession(a.sessionToken);
    await assert.rejects(() => f.renewal().renew(a.renewalToken), codeIs("INVALID_SESSION"));
    f.advance(600000); await f.state.purgeExpired(); await f.state.revokeRenewal(b.renewalToken);
    await assert.rejects(() => f.renewal().renew(b.renewalToken), codeIs("INVALID_SESSION"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_renewal_grants_v1").get().count, 0);
  } finally { f.close(); }
});

test("logout during an Apple request cannot be undone by its late completion", async () => {
  const f = fixture();
  try {
    const session = await f.session(); f.advance(86400000);
    await assert.rejects(() => f.renewal(async () => {
      await f.state.revokeRenewal(session.renewalToken);
      return { identityToken: f.token(null), refreshToken: "SYNTHETIC-LATE-ROTATED-REFRESH" };
    }).renew(session.renewalToken), codeIs("INVALID_SESSION"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_renewal_grants_v1").get().count, 0);
    const pending = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1 WHERE state='pending'").get();
    assert.equal(f.vault.open(pending.sealed_credential, { credentialID: pending.credential_id, subjectHash: pending.subject_hash }),
      "SYNTHETIC-LATE-ROTATED-REFRESH");
  } finally { f.close(); }
});

test("a new Apple credential remains encrypted and pending if the final renewal transaction fails", async () => {
  let fail = false;
  const f = fixture({ sqlHook: sql => { if (fail && sql.startsWith("INSERT INTO auth_sessions_v1")) throw new Error("PRIVATE-SQL"); } });
  try {
    const initial = await f.session(); f.advance(86400000); fail = true;
    await assert.rejects(() => f.renewal(async () => ({ identityToken: f.token(null), refreshToken: "SYNTHETIC-PENDING-ROTATION" }))
      .renew(initial.renewalToken), codeIs("STATE_UNAVAILABLE"));
    const row = f.db.prepare("SELECT * FROM auth_refresh_credentials_v1 WHERE state='pending'").get();
    assert.equal(f.vault.open(row.sealed_credential, { credentialID: row.credential_id, subjectHash: row.subject_hash }), "SYNTHETIC-PENDING-ROTATION");
    assert.equal(f.db.prepare("SELECT credential_id FROM auth_apple_state_v1").get().credential_id, initial.renewalToken.slice(0, 36));
  } finally { f.close(); }
});

test("renewal credential durability is confirmed before a new session is issued", async () => {
  const f = fixture({ syncHook: async count => { if (count === 8) throw new Error("PRIVATE-CREDENTIAL-SYNC"); } });
  try {
    const initial = await f.session(); f.advance(86400000);
    await assert.rejects(() => f.renewal(async () => ({ identityToken: f.token(null), refreshToken: "SYNTHETIC-PENDING-ROTATION" }))
      .renew(initial.renewalToken), codeIs("STATE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1 WHERE state='pending'").get().count, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1 WHERE expires_at>?").get(f.clock()).count, 0);
  } finally { f.close(); }
});

test("rotated renewal proofs and Apple ciphertext remain usable after reopening SQLite with the separate vault key", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-renewal-reopen-")), path = join(directory, "auth.sqlite");
  const credentialVault = new RefreshCredentialVault({ activeKeyID: "test", keys: { test: randomBytes(32).toString("base64url") } });
  const renewalProofs = new RenewalProofs({ activeKeyID: "test", keys: { test: randomBytes(32).toString("base64url") } });
  let f = fixture({ path, credentialVault, renewalProofs });
  try {
    const first = await f.session(); f.advance(86400000);
    const next = await f.renewal(async () => ({ identityToken: f.token(null), refreshToken: "SYNTHETIC-REOPENED-REFRESH" })).renew(first.renewalToken);
    f.close(); f = fixture({ path, credentialVault, renewalProofs }); f.advance(2 * 86400000);
    let calls = 0;
    const third = await f.renewal(async refresh => {
      calls++; assert.equal(refresh, "SYNTHETIC-REOPENED-REFRESH"); return { identityToken: f.token(null) };
    }).renew(next.renewalToken);
    assert.equal(calls, 1); f.state.authorize(third.sessionToken);
    await assert.rejects(() => f.renewal().renew(first.renewalToken), codeIs("REAUTH_REQUIRED"));
  } finally { f.close(); rmSync(directory, { recursive: true, force: true }); }
});

test("the daily-check boundary delays a renewal without consuming its proof", async () => {
  const f = fixture();
  try {
    const initial = await f.session(); f.advance(86400000 - 30000); let calls = 0;
    const service = f.renewal(async () => { calls++; return { identityToken: f.token(null) }; });
    await assert.rejects(() => service.renew(initial.renewalToken), codeIs("RENEWAL_BUSY"));
    f.advance(30000); const next = await service.renew(initial.renewalToken);
    assert.equal(calls, 1); f.state.authorize(next.sessionToken);
  } finally { f.close(); }
});

test("replay is detected across several rotations and revokes only that grant family", async () => {
  const f = fixture();
  try {
    const a = await f.session(), sibling = await f.session(); const service = f.renewal();
    const b = await service.renew(a.renewalToken), c = await service.renew(b.renewalToken);
    await assert.rejects(() => service.renew(a.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.throws(() => f.state.authorize(c.sessionToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => service.renew(c.renewalToken), codeIs("REAUTH_REQUIRED"));
    f.state.authorize(sibling.sessionToken); const next = await service.renew(sibling.renewalToken); f.state.authorize(next.sessionToken);
  } finally { f.close(); }
});

test("knowing a grant UUID or changing a counter cannot trigger replay revocation without a valid integrity proof", async () => {
  const f = fixture();
  try {
    const session = await f.session(), parts = session.renewalToken.split(".");
    for (const token of [[parts[0], parts[1], "1", parts[3]].join("."),
      [parts[0], parts[1], parts[2], "A".repeat(43)].join("."),
      [randomUUID(), ...parts.slice(1)].join(".")]) {
      await assert.rejects(() => f.renewal().renew(token), codeIs("INVALID_SESSION"));
    }
    f.state.authorize(session.sessionToken); const next = await f.renewal().renew(session.renewalToken); f.state.authorize(next.sessionToken);
    assert.throws(() => new AuthenticationState(f.storage, { clock: f.clock }), codeIs("STATE_UNAVAILABLE"));
  } finally { f.close(); }
});

test("a stale provider lease after a crash requires fresh authentication rather than resending refresh", async () => {
  const f = fixture();
  try {
    const a = await f.session(), b = await f.session(); f.advance(86400000);
    await f.state.claimRenewal(a.renewalToken); f.advance(60000);
    let calls = 0; const service = f.renewal(async () => { calls++; return { identityToken: f.token(null) }; });
    await assert.rejects(() => service.renew(a.renewalToken), codeIs("REAUTH_REQUIRED"));
    await assert.rejects(() => service.renew(b.renewalToken), codeIs("REAUTH_REQUIRED"));
    assert.equal(calls, 0); assert.equal(f.db.prepare("SELECT reauth_required FROM auth_apple_state_v1").get().reauth_required, 1);
  } finally { f.close(); }
});

test("the thirty-day deadline and individual/all-account logout cannot be bypassed with a renewal proof", async () => {
  const f = fixture();
  try {
    const a = await f.session(), b = await f.session(), other = await f.session("another.user");
    await f.state.revokeAllSessions(a.sessionToken);
    await assert.rejects(() => f.renewal().renew(a.renewalToken), codeIs("INVALID_SESSION"));
    await assert.rejects(() => f.renewal().renew(b.renewalToken), codeIs("INVALID_SESSION"));
    f.state.authorize(other.sessionToken);
    f.advance(30 * 86400000); let calls = 0;
    await assert.rejects(() => f.renewal(async () => { calls++; return { identityToken: f.token(null, "another.user") }; }).renew(other.renewalToken),
      codeIs("INVALID_SESSION")); assert.equal(calls, 0);
  } finally { f.close(); }
});

test("per-subject capacity is reserved before code exchange and does not prevent an existing local renewal", async () => {
  const f = fixture();
  try {
    const session = await f.session(); const subjectHash = appleSubjectHash("synthetic.user");
    for (let i = 0; i < 63; i++) f.db.prepare(`INSERT INTO auth_refresh_credentials_v1
      (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`).run(randomUUID(), subjectHash, "synthetic-ciphertext", start);
    const challenge = await f.challenge(); let calls = 0;
    await assert.rejects(() => f.coordinator(async () => { calls++; return f.token(challenge); }).login({
      challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode,
    }), codeIs("CREDENTIAL_LIMITED"));
    const renewed = await f.renewal().renew(session.renewalToken); f.state.authorize(renewed.sessionToken); assert.equal(calls, 0);
    f.advance(86400000);
    await assert.rejects(() => f.renewal(async () => { calls++; return { identityToken: f.token(null) }; }).renew(renewed.renewalToken),
      codeIs("CREDENTIAL_LIMITED")); assert.equal(calls, 0);
  } finally { f.close(); }
});

test("capacity reservations serialize competing logins without exceeding the subject ceiling", async () => {
  const f = fixture();
  try {
    const subjectHash = appleSubjectHash("synthetic.user");
    for (let i = 0; i < 63; i++) f.db.prepare(`INSERT INTO auth_refresh_credentials_v1
      (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`).run(randomUUID(), subjectHash, "synthetic-ciphertext", start);
    const challenges = [await f.challenge(hash("budget-A")), await f.challenge(hash("budget-B"))]; let calls = 0;
    const results = await Promise.allSettled(challenges.map(challenge => f.coordinator(async () => {
      calls++; return f.token(challenge);
    }).login({ challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode })));
    assert.equal(calls, 1); assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 64);
  } finally { f.close(); }
});

test("global capacity includes live reservations and stops before an Apple request", async () => {
  const f = fixture();
  try {
    for (let i = 0; i < 5000; i++) f.db.prepare(`INSERT INTO auth_credential_reservations_v1
      (reservation_id,subject_hash,expires_at) VALUES (?,?,?)`).run(randomUUID(), hash(String(i)), start + 86400000);
    const challenge = await f.challenge(); let calls = 0;
    await assert.rejects(() => f.coordinator(async () => { calls++; return f.token(challenge); }).login({
      challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode,
    }), codeIs("CREDENTIAL_LIMITED")); assert.equal(calls, 0);
    f.advance(86400000); await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_credential_reservations_v1").get().count, 4900);
  } finally { f.close(); }
});

test("retention removes only a bounded old batch and preserves the current credential while a grant remains valid", async () => {
  const f = fixture();
  try {
    const session = await f.session(); const subjectHash = appleSubjectHash("synthetic.user");
    f.db.prepare("UPDATE auth_refresh_credentials_v1 SET created_at=?").run(start - 31 * 86400000);
    for (let i = 0; i < 150; i++) f.db.prepare(`INSERT INTO auth_refresh_credentials_v1
      (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`).run(randomUUID(), subjectHash, "synthetic-ciphertext", start - 31 * 86400000);
    await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 51);
    const retained = f.db.prepare("SELECT credential_id FROM auth_apple_state_v1").get().credential_id;
    assert.equal(retained, session.renewalToken.slice(0, 36));
    f.advance(30 * 86400000); await f.state.purgeExpired();
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_refresh_credentials_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_apple_state_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 1);
  } finally { f.close(); }
});
