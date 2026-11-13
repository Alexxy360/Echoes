import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { createHash, generateKeyPairSync, randomUUID, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuthenticationState, AuthenticationStateError } from "../src/authentication-state.mjs";
import { AppleLoginCoordinator } from "../src/apple-login.mjs";
import { AppleIdentityTokenVerifier } from "../src/apple-identity.mjs";
import { ApplePublicKeySource } from "../src/apple-public-keys.mjs";

const hash = value => createHash("sha256").update(value).digest("hex");
const start = 1794603600000;
const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
const publicKey = { ...pair.publicKey.export({ format: "jwk" }), kid: "synthetic-login-key", alg: "RS256", use: "sig" };
const syntheticCode = "SYNTHETIC-PRIVATE-CODE";
function fixture({ path = ":memory:", syncHook = async () => {}, sqlHook = () => {} } = {}) {
  const db = new DatabaseSync(path); let now = start; let syncCount = 0;
  const storage = {
    sql: { exec(sql, ...bindings) {
      sqlHook(sql); const rows = db.prepare(sql).all(...bindings); return { toArray: () => rows };
    } },
    transactionSync(action) {
      db.exec("BEGIN IMMEDIATE");
      try { const result = action(); db.exec("COMMIT"); return result; }
      catch (error) { db.exec("ROLLBACK"); throw error; }
    },
    async sync() { await syncHook(++syncCount); },
  };
  const clock = () => now;
  const state = new AuthenticationState(storage, { clock });
  const keys = new ApplePublicKeySource({ clock, fetchImplementation: async () => Response.json({ keys: [publicKey] }) });
  const verifier = new AppleIdentityTokenVerifier({ keySource: keys, clock });
  const result = { db, state, storage, clock, advance(ms) { now += ms; }, close() { db.close(); },
    token(challenge, subject = "synthetic.user", lifetime = 3600) {
      const header = Buffer.from(JSON.stringify({ kid: publicKey.kid, alg: "RS256" })).toString("base64url");
      const body = Buffer.from(JSON.stringify({ iss: "https://appleid.apple.com", aud: "mpvEcho.Echo",
        sub: subject, nonce: hash(challenge.nonce), iat: Math.floor(now / 1000) - 1,
        exp: Math.floor(now / 1000) + lifetime, email: "PRIVATE-SYNTHETIC@example.invalid" })).toString("base64url");
      return header + "." + body + "." + sign("RSA-SHA256", Buffer.from(header + "." + body), pair.privateKey).toString("base64url");
    },
    coordinator(exchangeAuthorizationCode) { return new AppleLoginCoordinator({ state, verifier, exchangeAuthorizationCode }); },
    async challenge(budget = hash("synthetic-transport-budget")) { return state.issueChallenge(budget); },
    async session(subject = "synthetic.user", lifetime = 3600) {
      const challenge = await state.issueChallenge(hash(randomUUID()));
      const idToken = result.token(challenge, subject, lifetime);
      return result.coordinator(async () => idToken).login({ challengeID: challenge.challengeID,
        identityToken: idToken, authorizationCode: syntheticCode });
    },
  };
  return result;
}
const codeIs = code => error => error instanceof AuthenticationStateError && error.code === code &&
  error.message === "Authentication request could not be completed." && error.cause === undefined;

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
      calls++; assert.equal(input.authorizationCode, syntheticCode); assert.equal(input.expectedNonce, hash(challenge.nonce));
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
  const f = fixture({ syncHook: async count => { if (count === 4) throw new Error("PRIVATE-STORAGE"); } });
  try {
    const challenge = await f.challenge(); let calls = 0;
    const service = f.coordinator(async () => { calls++; return f.token(challenge); });
    const input = { challengeID: challenge.challengeID, identityToken: f.token(challenge), authorizationCode: syntheticCode };
    await assert.rejects(() => service.login(input), codeIs("STATE_UNAVAILABLE"));
    await assert.rejects(() => service.login(input), codeIs("INVALID_CHALLENGE"));
    assert.equal(calls, 1);
  } finally { f.close(); }
});

test("a failed session insert rolls back account creation and challenge consumption", async () => {
  const f = fixture({ sqlHook: sql => { if (sql.startsWith("INSERT INTO auth_sessions_v1")) throw new Error("PRIVATE-SQL"); } });
  try {
    await assert.rejects(() => f.session(), codeIs("STATE_UNAVAILABLE"));
    assert.equal(f.db.prepare("SELECT state FROM auth_challenges_v1").get().state, "claimed");
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_accounts_v1").get().count, 0);
    assert.equal(f.db.prepare("SELECT count(*) AS count FROM auth_sessions_v1").get().count, 0);
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
