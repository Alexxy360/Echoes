import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appleSubjectHash } from "./refresh-credential-vault.mjs";

const challengeLifetime = 5 * 60 * 1000;
const sessionLifetime = 10 * 60 * 1000;
const issueWindow = 5 * 60 * 1000;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const digest = value => createHash("sha256").update(value).digest("hex");
const codes = new Set(["STATE_UNAVAILABLE", "INVALID_CHALLENGE", "ISSUE_LIMITED", "INVALID_SESSION",
  "ACCOUNT_DISABLED", "SESSION_LIMITED", "INVALID_IDENTITY", "KEYS_UNAVAILABLE", "EXCHANGE_UNAVAILABLE"]);
export class AuthenticationStateError extends Error {
  constructor(code = "STATE_UNAVAILABLE") {
    super("Authentication request could not be completed.");
    this.code = codes.has(code) ? code : "STATE_UNAVAILABLE";
  }
}

const schema = [
  `CREATE TABLE IF NOT EXISTS auth_challenges_v1 (
    challenge_id TEXT PRIMARY KEY, nonce_hash TEXT NOT NULL, expires_at INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','claimed','consumed')),
    verification_attempts INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS auth_challenge_expiry_v1 ON auth_challenges_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS auth_issue_budget_v1 (
    budget_hash TEXT NOT NULL, window_start INTEGER NOT NULL, count INTEGER NOT NULL,
    PRIMARY KEY(budget_hash,window_start))`,
  `CREATE INDEX IF NOT EXISTS auth_budget_expiry_v1 ON auth_issue_budget_v1(window_start)`,
  `CREATE TABLE IF NOT EXISTS auth_accounts_v1 (
    account_id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL UNIQUE,
    generation INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS auth_sessions_v1 (
    token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL, generation INTEGER NOT NULL,
    expires_at INTEGER NOT NULL, challenge_id TEXT NOT NULL UNIQUE)`,
  `CREATE INDEX IF NOT EXISTS auth_session_expiry_v1 ON auth_sessions_v1(expires_at)`,
  `CREATE INDEX IF NOT EXISTS auth_session_account_v1 ON auth_sessions_v1(account_id,expires_at)`,
  `CREATE TABLE IF NOT EXISTS auth_refresh_credentials_v1 (
    credential_id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL, sealed_credential TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','bound')), account_id TEXT, created_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS auth_credential_account_v1 ON auth_refresh_credentials_v1(account_id)`,
];

/** Server-internal store. Requires synchronous transactions and explicit durability; no HTTP interface. */
export class AuthenticationState {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw new AuthenticationStateError();
    this.#storage = storage; this.#clock = clock;
    this.#transaction(() => { for (const statement of schema) this.#storage.sql.exec(statement); });
  }
  #now() {
    const now = this.#clock();
    if (!Number.isSafeInteger(now) || now < 0) throw new AuthenticationStateError();
    return now;
  }
  #transaction(action) {
    try { return this.#storage.transactionSync(action); }
    catch (error) { throw error instanceof AuthenticationStateError ? error : new AuthenticationStateError(); }
  }
  #rows(query, ...values) { return this.#storage.sql.exec(query, ...values).toArray(); }
  async #durable() {
    try { await this.#storage.sync(); } catch { throw new AuthenticationStateError(); }
  }
  #challengeID(value) { if (typeof value !== "string" || !uuid.test(value)) throw new AuthenticationStateError("INVALID_CHALLENGE"); }
  #tokenHash(token) {
    if (typeof token !== "string" || token.length !== 80 || !uuid.test(token.slice(0, 36)) ||
        token[36] !== "." || !/^[A-Za-z0-9_-]{43}$/.test(token.slice(37))) {
      throw new AuthenticationStateError("INVALID_SESSION");
    }
    return digest("echoes/session/v1\0" + token);
  }
  #activeSession(tokenHash, now) {
    const row = this.#rows(`SELECT s.account_id,s.expires_at FROM auth_sessions_v1 s
      JOIN auth_accounts_v1 a ON a.account_id=s.account_id
      WHERE s.token_hash=? AND s.expires_at>? AND s.generation=a.generation AND a.disabled=0`, tokenHash, now)[0];
    if (!row) throw new AuthenticationStateError("INVALID_SESSION");
    return Object.freeze({ accountID: row.account_id, expiresAt: Math.floor(row.expires_at / 1000) });
  }

  async issueChallenge(serverBudgetHash) {
    // The transport must derive this key from trusted context and route equal budgets to the same store.
    // Never accept the budget key from client JSON or an untrusted forwarding header.
    if (typeof serverBudgetHash !== "string" || !/^[a-f0-9]{64}$/.test(serverBudgetHash)) throw new AuthenticationStateError();
    const now = this.#now(), windowStart = Math.floor(now / issueWindow) * issueWindow;
    const challengeID = randomUUID(), nonce = randomBytes(32).toString("base64url");
    const expiresAt = now + challengeLifetime;
    this.#transaction(() => {
      const allowed = this.#rows(`INSERT INTO auth_issue_budget_v1(budget_hash,window_start,count) VALUES (?,?,1)
        ON CONFLICT(budget_hash,window_start) DO UPDATE SET count=count+1 WHERE count<5 RETURNING count`, serverBudgetHash, windowStart);
      if (!allowed.length) throw new AuthenticationStateError("ISSUE_LIMITED");
      this.#storage.sql.exec(`INSERT INTO auth_challenges_v1(challenge_id,nonce_hash,expires_at,state)
        VALUES (?,?,?,'pending')`, challengeID, digest(nonce), expiresAt);
    });
    await this.#durable();
    return Object.freeze({ challengeID, nonce, expiresAt: Math.floor(expiresAt / 1000) });
  }

  async beginVerification(challengeID) {
    this.#challengeID(challengeID); const now = this.#now();
    const row = this.#transaction(() => this.#rows(`UPDATE auth_challenges_v1
      SET verification_attempts=verification_attempts+1
      WHERE challenge_id=? AND state='pending' AND expires_at>? AND verification_attempts<5
      RETURNING nonce_hash`, challengeID, now)[0]);
    if (!row) throw new AuthenticationStateError("INVALID_CHALLENGE");
    await this.#durable();
    return Object.freeze({ expectedNonce: row.nonce_hash });
  }

  async claimChallenge(challengeID, expectedNonce) {
    this.#challengeID(challengeID); const now = this.#now();
    if (typeof expectedNonce !== "string" || !/^[a-f0-9]{64}$/.test(expectedNonce)) throw new AuthenticationStateError("INVALID_CHALLENGE");
    const claimed = this.#transaction(() => this.#rows(`UPDATE auth_challenges_v1 SET state='claimed'
      WHERE challenge_id=? AND nonce_hash=? AND state='pending' AND expires_at>? AND verification_attempts BETWEEN 1 AND 5
      RETURNING challenge_id`, challengeID, expectedNonce, now).length === 1);
    if (!claimed) throw new AuthenticationStateError("INVALID_CHALLENGE");
    // Must finish before a one-use authorization code is sent to Apple's token endpoint.
    await this.#durable();
  }

  async completeLogin(challengeID, { appleSubject, identityExpiresAt } = {}) {
    this.#challengeID(challengeID); const now = this.#now();
    if (typeof appleSubject !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(appleSubject) ||
        !Number.isSafeInteger(identityExpiresAt) || identityExpiresAt * 1000 <= now ||
        !Number.isSafeInteger(identityExpiresAt * 1000)) throw new AuthenticationStateError("INVALID_IDENTITY");
    const expiresAt = Math.min(now + sessionLifetime, identityExpiresAt * 1000);
    const sessionToken = challengeID + "." + randomBytes(32).toString("base64url");
    const tokenHash = this.#tokenHash(sessionToken), subjectHash = appleSubjectHash(appleSubject);
    const accountID = this.#transaction(() => {
      const row = this.#rows(`UPDATE auth_challenges_v1 SET state='consumed'
        WHERE challenge_id=? AND state='claimed' AND expires_at>? RETURNING challenge_id`, challengeID, now)[0];
      if (!row) throw new AuthenticationStateError("INVALID_CHALLENGE");
      this.#storage.sql.exec(`INSERT INTO auth_accounts_v1(account_id,subject_hash) VALUES (?,?)
        ON CONFLICT(subject_hash) DO NOTHING`, randomUUID(), subjectHash);
      const account = this.#rows("SELECT account_id,generation,disabled FROM auth_accounts_v1 WHERE subject_hash=?", subjectHash)[0];
      if (!account || account.disabled) throw new AuthenticationStateError("ACCOUNT_DISABLED");
      const count = this.#rows(`SELECT count(*) AS count FROM auth_sessions_v1
        WHERE account_id=? AND generation=? AND expires_at>?`, account.account_id, account.generation, now)[0].count;
      if (count >= 5) throw new AuthenticationStateError("SESSION_LIMITED");
      const bound = this.#rows(`UPDATE auth_refresh_credentials_v1 SET state='bound',account_id=?
        WHERE credential_id=? AND subject_hash=? AND state='pending' RETURNING credential_id`,
      account.account_id, challengeID, subjectHash);
      if (bound.length !== 1) throw new AuthenticationStateError();
      this.#storage.sql.exec(`INSERT INTO auth_sessions_v1(token_hash,account_id,generation,expires_at,challenge_id)
        VALUES (?,?,?,?,?)`, tokenHash, account.account_id, account.generation, expiresAt, challengeID);
      return account.account_id;
    });
    await this.#durable();
    return Object.freeze({ sessionToken, accountID, expiresAt: Math.floor(expiresAt / 1000) });
  }

  /** Only a verified Apple exchange may supply this ciphertext. Never expose this method through RPC/HTTP. */
  async stageRefreshCredential(challengeID, { appleSubject, sealedCredential } = {}) {
    this.#challengeID(challengeID); const now = this.#now();
    try {
      if (typeof sealedCredential !== "string" || sealedCredential.length > 12000) throw new Error();
      const envelope = JSON.parse(sealedCredential);
      if (!envelope || envelope.v !== 1 || Object.keys(envelope).sort().join() !== "ciphertext,iv,keyID,tag,v") throw new Error();
      const subjectHash = appleSubjectHash(appleSubject);
      this.#transaction(() => {
        const claimed = this.#rows("SELECT state FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
        if (claimed?.state !== "claimed") throw new AuthenticationStateError("INVALID_CHALLENGE");
        this.#storage.sql.exec(`INSERT INTO auth_refresh_credentials_v1
          (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`,
        challengeID, subjectHash, sealedCredential, now);
      });
      // Pending rows are not discarded on error; no session is issued by this step.
      await this.#durable();
    } catch (error) { throw error instanceof AuthenticationStateError ? error : new AuthenticationStateError(); }
  }

  authorize(sessionToken) {
    const hash = this.#tokenHash(sessionToken), now = this.#now();
    return this.#transaction(() => this.#activeSession(hash, now));
  }

  async revokeSession(sessionToken) {
    const hash = this.#tokenHash(sessionToken);
    this.#transaction(() => this.#storage.sql.exec("DELETE FROM auth_sessions_v1 WHERE token_hash=?", hash));
    await this.#durable();
  }

  async revokeAllSessions(sessionToken) {
    const hash = this.#tokenHash(sessionToken), now = this.#now();
    this.#transaction(() => {
      const active = this.#activeSession(hash, now);
      this.#storage.sql.exec("UPDATE auth_accounts_v1 SET generation=generation+1 WHERE account_id=?", active.accountID);
    });
    await this.#durable();
  }

  /** Trusted operator only. Disabling prevents both existing sessions and new session issuance. */
  async disableAccount(accountID) {
    if (typeof accountID !== "string" || !uuid.test(accountID)) throw new AuthenticationStateError();
    this.#transaction(() => this.#storage.sql.exec(`UPDATE auth_accounts_v1 SET disabled=1,generation=generation+1
      WHERE account_id=?`, accountID));
    await this.#durable();
  }

  async purgeExpired() {
    const now = this.#now();
    this.#transaction(() => {
      this.#storage.sql.exec(`DELETE FROM auth_challenges_v1 WHERE challenge_id IN
        (SELECT challenge_id FROM auth_challenges_v1 WHERE expires_at<=?
          AND (state!='claimed' OR expires_at<=?) LIMIT 100)`, now, now - 86400000);
      this.#storage.sql.exec(`DELETE FROM auth_sessions_v1 WHERE token_hash IN
        (SELECT token_hash FROM auth_sessions_v1 WHERE expires_at<=? LIMIT 100)`, now);
      this.#storage.sql.exec(`DELETE FROM auth_issue_budget_v1 WHERE (budget_hash,window_start) IN
        (SELECT budget_hash,window_start FROM auth_issue_budget_v1 WHERE window_start<=? LIMIT 100)`, now - issueWindow);
    });
    await this.#durable();
  }
}
