import { createHash, randomBytes, randomUUID } from "node:crypto";
import { appleSubjectHash } from "./refresh-credential-vault.mjs";
import { deletionSchema, deletionTicketHash, deletionUUID } from "./deletion-schema.mjs";

const challengeLifetime = 5 * 60 * 1000;
const sessionLifetime = 10 * 60 * 1000;
const renewalLifetime = 30 * 86400000;
const providerCheckInterval = 86400000;
const operationLifetime = 60000;
const issueWindow = 5 * 60 * 1000;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const digest = value => createHash("sha256").update(value).digest("hex");
const codes = new Set(["STATE_UNAVAILABLE", "INVALID_CHALLENGE", "ISSUE_LIMITED", "INVALID_SESSION",
  "ACCOUNT_DISABLED", "SESSION_LIMITED", "INVALID_IDENTITY", "KEYS_UNAVAILABLE", "EXCHANGE_UNAVAILABLE",
  "REAUTH_REQUIRED", "RENEWAL_BUSY", "CREDENTIAL_LIMITED", "DELETION_UNAVAILABLE", "DELETION_IN_PROGRESS", "NO_ACCOUNT"]);
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
  `CREATE TABLE IF NOT EXISTS auth_schema_migrations_v1(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS auth_challenge_expiry_v1 ON auth_challenges_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS auth_issue_budget_v1 (
    budget_hash TEXT NOT NULL, window_start INTEGER NOT NULL, count INTEGER NOT NULL,
    PRIMARY KEY(budget_hash,window_start))`,
  `CREATE INDEX IF NOT EXISTS auth_budget_expiry_v1 ON auth_issue_budget_v1(window_start)`,
  `CREATE TABLE IF NOT EXISTS auth_accounts_v1 (
    account_id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL UNIQUE,
    generation INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS auth_account_disabled_v1 ON auth_accounts_v1(disabled)`,
  `CREATE TABLE IF NOT EXISTS auth_subject_bans_v1 (subject_hash TEXT PRIMARY KEY,created_at INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS auth_sessions_v1 (
    token_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL, generation INTEGER NOT NULL,
    expires_at INTEGER NOT NULL, challenge_id TEXT NOT NULL UNIQUE)`,
  `CREATE INDEX IF NOT EXISTS auth_session_expiry_v1 ON auth_sessions_v1(expires_at)`,
  `CREATE INDEX IF NOT EXISTS auth_session_account_v1 ON auth_sessions_v1(account_id,expires_at)`,
  `CREATE TABLE IF NOT EXISTS auth_refresh_credentials_v1 (
    credential_id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL, sealed_credential TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','bound')), account_id TEXT, created_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS auth_credential_account_v1 ON auth_refresh_credentials_v1(account_id)`,
  `CREATE INDEX IF NOT EXISTS auth_credential_subject_v1 ON auth_refresh_credentials_v1(subject_hash,created_at)`,
  `CREATE INDEX IF NOT EXISTS auth_credential_expiry_v1 ON auth_refresh_credentials_v1(created_at)`,
  `CREATE TABLE IF NOT EXISTS auth_credential_reservations_v1 (
    reservation_id TEXT PRIMARY KEY, subject_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, credential_id TEXT)`,
  `CREATE INDEX IF NOT EXISTS auth_reservation_expiry_v1 ON auth_credential_reservations_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS auth_renewal_grants_v1 (
    grant_id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, account_id TEXT NOT NULL,
    generation INTEGER NOT NULL, expires_at INTEGER NOT NULL, state TEXT NOT NULL,
    lease_id TEXT, lease_started_at INTEGER, provider_revision INTEGER,
    needs_apple_check INTEGER, replacement_credential_id TEXT, proof_key_id TEXT NOT NULL, proof_sequence INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS auth_renewal_account_v1 ON auth_renewal_grants_v1(account_id,generation,expires_at)`,
  `CREATE INDEX IF NOT EXISTS auth_renewal_lease_v1 ON auth_renewal_grants_v1(lease_id)`,
  `CREATE TABLE IF NOT EXISTS auth_apple_state_v1 (
    account_id TEXT PRIMARY KEY, credential_id TEXT NOT NULL, verified_at INTEGER NOT NULL,
    revision INTEGER NOT NULL, check_lease_id TEXT, check_started_at INTEGER,
    reauth_required INTEGER NOT NULL DEFAULT 0)`,
  ...deletionSchema,
];

/** Server-internal store. Requires synchronous transactions and explicit durability; no HTTP interface. */
export class AuthenticationState {
  #storage; #clock; #renewalProofs;
  constructor(storage, { clock = Date.now, renewalProofs } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function" ||
        typeof renewalProofs?.create !== "function" || typeof renewalProofs.verify !== "function") throw new AuthenticationStateError();
    this.#storage = storage; this.#clock = clock; this.#renewalProofs = renewalProofs;
    this.#transaction(() => {
      for (const statement of schema) this.#storage.sql.exec(statement);
      // Keep the original challenge CREATE stable. This migration also upgrades an existing CK-02g store.
      if (!this.#rows("SELECT name FROM auth_schema_migrations_v1 WHERE name='challenge-purpose-v1'").length) {
        this.#storage.sql.exec("ALTER TABLE auth_challenges_v1 ADD COLUMN purpose TEXT NOT NULL DEFAULT 'login'");
        this.#storage.sql.exec("INSERT INTO auth_schema_migrations_v1(name,applied_at) VALUES ('challenge-purpose-v1',?)", this.#now());
      }
      // Legacy operator blocks survive erasure; a deletion's temporary disable must never become a ban.
      this.#storage.sql.exec(`INSERT OR IGNORE INTO auth_subject_bans_v1(subject_hash,created_at)
        SELECT a.subject_hash,? FROM auth_accounts_v1 a WHERE a.disabled=1 AND NOT EXISTS
          (SELECT 1 FROM auth_account_deletions_v1 d WHERE d.account_id=a.account_id AND d.local_status='blocked')`, this.#now());
    });
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
  #tokenHash(token, purpose = "session") {
    if (typeof token !== "string" || token.length !== 80 || !uuid.test(token.slice(0, 36)) ||
        token[36] !== "." || !/^[A-Za-z0-9_-]{43}$/.test(token.slice(37))) {
      throw new AuthenticationStateError("INVALID_SESSION");
    }
    return digest("echoes/" + purpose + "/v1\0" + token);
  }
  #activeSession(tokenHash, now) {
    const row = this.#rows(`SELECT s.account_id,s.expires_at FROM auth_sessions_v1 s
      JOIN auth_accounts_v1 a ON a.account_id=s.account_id
      WHERE s.token_hash=? AND s.expires_at>? AND s.generation=a.generation AND a.disabled=0`, tokenHash, now)[0];
    if (!row) throw new AuthenticationStateError("INVALID_SESSION");
    return Object.freeze({ accountID: row.account_id, expiresAt: Math.floor(row.expires_at / 1000) });
  }

  async issueChallenge(serverBudgetHash, { purpose = "login" } = {}) {
    // The transport must derive this key from trusted context and route equal budgets to the same store.
    // Never accept the budget key from client JSON or an untrusted forwarding header.
    if (typeof serverBudgetHash !== "string" || !/^[a-f0-9]{64}$/.test(serverBudgetHash) ||
        !["login", "account_deletion"].includes(purpose)) throw new AuthenticationStateError();
    const now = this.#now(), windowStart = Math.floor(now / issueWindow) * issueWindow;
    const challengeID = randomUUID(), nonce = randomBytes(32).toString("base64url");
    const expiresAt = now + challengeLifetime;
    this.#transaction(() => {
      const allowed = this.#rows(`INSERT INTO auth_issue_budget_v1(budget_hash,window_start,count) VALUES (?,?,1)
        ON CONFLICT(budget_hash,window_start) DO UPDATE SET count=count+1 WHERE count<5 RETURNING count`, serverBudgetHash, windowStart);
      if (!allowed.length) throw new AuthenticationStateError("ISSUE_LIMITED");
      this.#storage.sql.exec(`INSERT INTO auth_challenges_v1(challenge_id,nonce_hash,expires_at,state,purpose)
        VALUES (?,?,?,'pending',?)`, challengeID, digest(nonce), expiresAt, purpose);
    });
    await this.#durable();
    return Object.freeze({ challengeID, nonce, expiresAt: Math.floor(expiresAt / 1000) });
  }

  async beginVerification(challengeID, { purpose = "login" } = {}) {
    this.#challengeID(challengeID); const now = this.#now();
    if (!["login", "account_deletion"].includes(purpose)) throw new AuthenticationStateError();
    const row = this.#transaction(() => this.#rows(`UPDATE auth_challenges_v1
      SET verification_attempts=verification_attempts+1
      WHERE challenge_id=? AND purpose=? AND state='pending' AND expires_at>? AND verification_attempts<5
      RETURNING nonce_hash`, challengeID, purpose, now)[0]);
    if (!row) throw new AuthenticationStateError("INVALID_CHALLENGE");
    await this.#durable();
    return Object.freeze({ expectedNonce: row.nonce_hash });
  }

  async claimChallenge(challengeID, expectedNonce, { purpose = "login" } = {}) {
    this.#challengeID(challengeID); const now = this.#now();
    if (typeof expectedNonce !== "string" || !/^[a-f0-9]{64}$/.test(expectedNonce) ||
        !["login", "account_deletion"].includes(purpose)) throw new AuthenticationStateError("INVALID_CHALLENGE");
    const claimed = this.#transaction(() => this.#rows(`UPDATE auth_challenges_v1 SET state='claimed'
      WHERE challenge_id=? AND nonce_hash=? AND purpose=? AND state='pending' AND expires_at>? AND verification_attempts BETWEEN 1 AND 5
      RETURNING challenge_id`, challengeID, expectedNonce, purpose, now).length === 1);
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
    const renewalToken = this.#renewalProofs.create(challengeID);
    const renewalProof = this.#renewalProofs.verify(renewalToken);
    const renewalExpiresAt = now + renewalLifetime;
    const tokenHash = this.#tokenHash(sessionToken), subjectHash = appleSubjectHash(appleSubject);
    const accountID = this.#transaction(() => {
      this.#requireFreshChallengeEpoch(challengeID, subjectHash);
      if (this.#rows("SELECT subject_hash FROM auth_subject_bans_v1 WHERE subject_hash=?", subjectHash).length) {
        throw new AuthenticationStateError("ACCOUNT_DISABLED");
      }
      const row = this.#rows(`UPDATE auth_challenges_v1 SET state='consumed'
        WHERE challenge_id=? AND purpose='login' AND state='claimed' AND expires_at>? RETURNING challenge_id`, challengeID, now)[0];
      if (!row) throw new AuthenticationStateError("INVALID_CHALLENGE");
      this.#storage.sql.exec(`INSERT INTO auth_accounts_v1(account_id,subject_hash) VALUES (?,?)
        ON CONFLICT(subject_hash) DO NOTHING`, randomUUID(), subjectHash);
      const account = this.#rows("SELECT account_id,generation,disabled FROM auth_accounts_v1 WHERE subject_hash=?", subjectHash)[0];
      if (!account || account.disabled) throw new AuthenticationStateError("ACCOUNT_DISABLED");
      const count = this.#rows(`SELECT count(*) AS count FROM auth_renewal_grants_v1
        WHERE account_id=? AND generation=? AND expires_at>? AND (state='active'
          OR (state='claimed' AND lease_started_at>?))`, account.account_id, account.generation, now, now - operationLifetime)[0].count;
      if (count >= 5) throw new AuthenticationStateError("SESSION_LIMITED");
      const bound = this.#rows(`UPDATE auth_refresh_credentials_v1 SET state='bound',account_id=?
        WHERE credential_id=? AND subject_hash=? AND state='pending' RETURNING credential_id`,
      account.account_id, challengeID, subjectHash);
      if (bound.length !== 1) throw new AuthenticationStateError();
      this.#storage.sql.exec(`INSERT INTO auth_sessions_v1(token_hash,account_id,generation,expires_at,challenge_id)
        VALUES (?,?,?,?,?)`, tokenHash, account.account_id, account.generation, expiresAt, challengeID);
      this.#storage.sql.exec(`INSERT INTO auth_renewal_grants_v1
        (grant_id,token_hash,account_id,generation,expires_at,state,proof_key_id,proof_sequence) VALUES (?,?,?,?,?,'active',?,0)`,
      challengeID, digest("echoes/renewal/v1\0" + renewalToken), account.account_id, account.generation, renewalExpiresAt, renewalProof.keyID);
      // New interactive proof supersedes an older in-flight provider check, never a block/generation change.
      this.#storage.sql.exec(`INSERT INTO auth_apple_state_v1(account_id,credential_id,verified_at,revision)
        VALUES (?,?,?,1) ON CONFLICT(account_id) DO UPDATE SET credential_id=excluded.credential_id,
        verified_at=excluded.verified_at,revision=revision+1,check_lease_id=NULL,check_started_at=NULL,reauth_required=0`,
      account.account_id, challengeID, now);
      return account.account_id;
    });
    await this.#durable();
    return Object.freeze({ sessionToken, renewalToken, accountID, expiresAt: Math.floor(expiresAt / 1000),
      renewalExpiresAt: Math.floor(renewalExpiresAt / 1000) });
  }

  #reserveCredential(reservationID, subjectHash, now, credentialID = reservationID) {
    const total = this.#rows(`SELECT (SELECT count(*) FROM auth_refresh_credentials_v1) +
      (SELECT count(*) FROM auth_credential_reservations_v1 WHERE expires_at>?) AS count`, now)[0].count;
    const perSubject = this.#rows(`SELECT (SELECT count(*) FROM auth_refresh_credentials_v1 WHERE subject_hash=?) +
      (SELECT count(*) FROM auth_credential_reservations_v1 WHERE subject_hash=? AND expires_at>?) AS count`,
    subjectHash, subjectHash, now)[0].count;
    if (total >= 5000 || perSubject >= 64) throw new AuthenticationStateError("CREDENTIAL_LIMITED");
    this.#storage.sql.exec(`INSERT INTO auth_credential_reservations_v1(reservation_id,subject_hash,expires_at,credential_id)
      VALUES (?,?,?,?)`, reservationID, subjectHash, now + 86400000, credentialID);
  }

  async reserveLoginCredential(challengeID, appleSubject) {
    return this.#reserveLoginCredential(challengeID, appleSubject);
  }

  #requireFreshChallengeEpoch(challengeID, subjectHash) {
    const challenge = this.#rows("SELECT expires_at FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
    const fence = this.#rows("SELECT not_before FROM auth_subject_fences_v1 WHERE subject_hash=?", subjectHash)[0];
    if (!challenge || (fence && challenge.expires_at - challengeLifetime <= fence.not_before)) {
      throw new AuthenticationStateError("REAUTH_REQUIRED");
    }
  }

  #rejectLateCredentialAfterDeletion(subjectHash) {
    if (this.#rows("SELECT subject_hash FROM auth_subject_fences_v1 WHERE subject_hash=?", subjectHash).length &&
        !this.#rows("SELECT deletion_id FROM auth_account_deletions_v1 WHERE subject_hash=? AND local_status='blocked'", subjectHash).length) {
      throw new AuthenticationStateError("REAUTH_REQUIRED");
    }
  }

  async #reserveLoginCredential(challengeID, appleSubject) {
    this.#challengeID(challengeID); const now = this.#now();
    let subjectHash;
    try { subjectHash = appleSubjectHash(appleSubject); } catch { throw new AuthenticationStateError("INVALID_IDENTITY"); }
    this.#transaction(() => {
      const row = this.#rows("SELECT state,expires_at,purpose FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
      if (row?.state !== "claimed" || row.purpose !== "login" || row.expires_at <= now) throw new AuthenticationStateError("INVALID_CHALLENGE");
      this.#requireFreshChallengeEpoch(challengeID, subjectHash);
      if (this.#rows("SELECT deletion_id FROM auth_account_deletions_v1 WHERE subject_hash=? AND local_status='blocked'", subjectHash).length) {
        throw new AuthenticationStateError("DELETION_IN_PROGRESS");
      }
      if (this.#rows("SELECT subject_hash FROM auth_subject_bans_v1 WHERE subject_hash=?", subjectHash).length) {
        throw new AuthenticationStateError("ACCOUNT_DISABLED");
      }
      const account = this.#rows("SELECT disabled FROM auth_accounts_v1 WHERE subject_hash=?", subjectHash)[0];
      if (account?.disabled) throw new AuthenticationStateError("ACCOUNT_DISABLED");
      this.#reserveCredential(challengeID, subjectHash, now);
    });
    await this.#durable();
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
        const challenge = this.#rows("SELECT expires_at FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
        const fence = this.#rows("SELECT not_before FROM auth_subject_fences_v1 WHERE subject_hash=?", subjectHash)[0];
        if (fence && challenge && challenge.expires_at - challengeLifetime <= fence.not_before) {
          this.#rejectLateCredentialAfterDeletion(subjectHash);
        }
        const claimed = this.#rows("SELECT state FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
        if (claimed?.state !== "claimed") throw new AuthenticationStateError("INVALID_CHALLENGE");
        if (!this.#rows("SELECT reservation_id FROM auth_credential_reservations_v1 WHERE reservation_id=? AND expires_at>?",
          challengeID, now).length) throw new AuthenticationStateError();
        // A mismatched but signed exchange is retained pending, subject to the same per-subject ceiling.
        if (this.#rows(`SELECT (SELECT count(*) FROM auth_refresh_credentials_v1 WHERE subject_hash=?) +
          (SELECT count(*) FROM auth_credential_reservations_v1 WHERE subject_hash=? AND reservation_id!=? AND expires_at>?) AS count`,
        subjectHash, subjectHash, challengeID, now)[0].count >= 64) {
          throw new AuthenticationStateError("CREDENTIAL_LIMITED");
        }
        this.#storage.sql.exec(`INSERT INTO auth_refresh_credentials_v1
          (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`,
        challengeID, subjectHash, sealedCredential, now);
        this.#storage.sql.exec("DELETE FROM auth_credential_reservations_v1 WHERE reservation_id=?", challengeID);
      });
      // Pending rows are not discarded on error; no session is issued by this step.
      await this.#durable();
    } catch (error) { throw error instanceof AuthenticationStateError ? error : new AuthenticationStateError(); }
  }

  authorize(sessionToken) {
    const hash = this.#tokenHash(sessionToken), now = this.#now();
    return this.#transaction(() => this.#activeSession(hash, now));
  }

  /** Only the fresh, verified Apple deletion flow may call this, including for a blocked account. */
  async startVerifiedDeletion(challengeID, { appleSubject, identityExpiresAt, deletionID, statusToken, expectedAccountID } = {}) {
    this.#challengeID(challengeID); const now = this.#now(); let statusHash, subjectHash;
    if (!Number.isSafeInteger(identityExpiresAt) || !Number.isSafeInteger(identityExpiresAt * 1000) ||
        identityExpiresAt * 1000 <= now) throw new AuthenticationStateError("INVALID_IDENTITY");
    try {
      statusHash = deletionTicketHash(deletionID, statusToken); subjectHash = appleSubjectHash(appleSubject);
      if (expectedAccountID !== undefined && (typeof expectedAccountID !== "string" || !deletionUUID.test(expectedAccountID))) throw new Error();
    } catch { throw new AuthenticationStateError("DELETION_UNAVAILABLE"); }
    this.#transaction(() => {
      this.#requireFreshChallengeEpoch(challengeID, subjectHash);
      const challenge = this.#rows("SELECT state,expires_at,purpose FROM auth_challenges_v1 WHERE challenge_id=?", challengeID)[0];
      if (challenge?.state !== "claimed" || challenge.purpose !== "account_deletion" || challenge.expires_at <= now) {
        throw new AuthenticationStateError("INVALID_CHALLENGE");
      }
      const account = this.#rows("SELECT account_id FROM auth_accounts_v1 WHERE subject_hash=?", subjectHash)[0];
      if (!account) throw new AuthenticationStateError("NO_ACCOUNT");
      if (expectedAccountID !== undefined && expectedAccountID !== account.account_id) throw new AuthenticationStateError("INVALID_IDENTITY");
      this.#storage.sql.exec(`INSERT INTO auth_account_deletions_v1
        (deletion_id,status_hash,account_id,subject_hash,created_at,settle_after) VALUES (?,?,?,?,?,?)`,
      deletionID, statusHash, account.account_id, subjectHash, now, now + operationLifetime);
      this.#storage.sql.exec(`INSERT INTO auth_subject_fences_v1(subject_hash,not_before) VALUES (?,?)
        ON CONFLICT(subject_hash) DO UPDATE SET not_before=MAX(not_before,excluded.not_before)`, subjectHash, now);
      this.#storage.sql.exec("UPDATE auth_accounts_v1 SET disabled=1,generation=generation+1 WHERE account_id=?", account.account_id);
      this.#storage.sql.exec("UPDATE auth_challenges_v1 SET state='consumed' WHERE challenge_id=?", challengeID);
    });
    await this.#durable();
  }

  async revokeSession(sessionToken) {
    const hash = this.#tokenHash(sessionToken);
    this.#transaction(() => {
      const session = this.#rows("SELECT challenge_id FROM auth_sessions_v1 WHERE token_hash=?", hash)[0];
      if (session) this.#storage.sql.exec("DELETE FROM auth_renewal_grants_v1 WHERE grant_id=?", session.challenge_id);
      this.#storage.sql.exec("DELETE FROM auth_sessions_v1 WHERE token_hash=?", hash);
    });
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
    const now = this.#now();
    this.#transaction(() => {
      const account = this.#rows("SELECT subject_hash FROM auth_accounts_v1 WHERE account_id=?", accountID)[0];
      if (account) this.#storage.sql.exec("INSERT OR IGNORE INTO auth_subject_bans_v1(subject_hash,created_at) VALUES (?,?)", account.subject_hash, now);
      this.#storage.sql.exec("UPDATE auth_accounts_v1 SET disabled=1,generation=generation+1 WHERE account_id=?", accountID);
    });
    await this.#durable();
  }

  #renewalGrant(token, now) {
    let proof;
    try { proof = this.#renewalProofs.verify(token); } catch { throw new AuthenticationStateError("INVALID_SESSION"); }
    const row = this.#rows(`SELECT g.*,a.subject_hash FROM auth_renewal_grants_v1 g
      JOIN auth_accounts_v1 a ON a.account_id=g.account_id WHERE g.grant_id=? AND g.expires_at>?
      AND g.generation=a.generation AND a.disabled=0`, proof.grantID, now)[0];
    if (!row || proof.keyID !== row.proof_key_id || proof.sequence > row.proof_sequence ||
        (proof.sequence === row.proof_sequence && digest("echoes/renewal/v1\0" + token) !== row.token_hash)) {
      throw new AuthenticationStateError("INVALID_SESSION");
    }
    return { ...row, presentedSequence: proof.sequence };
  }

  /** Returns private server context, not an HTTP response. One lease is durable before any Apple request. */
  async claimRenewal(renewalToken) {
    const now = this.#now(), leaseID = randomUUID();
    const result = this.#transaction(() => {
      const grant = this.#renewalGrant(renewalToken, now);
      if (grant.presentedSequence < grant.proof_sequence) {
        this.#storage.sql.exec("UPDATE auth_renewal_grants_v1 SET state='replayed' WHERE grant_id=?", grant.grant_id);
        this.#storage.sql.exec("DELETE FROM auth_sessions_v1 WHERE challenge_id=?", grant.grant_id);
        return { error: "REAUTH_REQUIRED" };
      }
      if (grant.state !== "active") throw new AuthenticationStateError(grant.state === "claimed" &&
        grant.lease_started_at + operationLifetime > now ? "RENEWAL_BUSY" : "REAUTH_REQUIRED");
      const apple = this.#rows("SELECT * FROM auth_apple_state_v1 WHERE account_id=?", grant.account_id)[0];
      if (!apple || apple.reauth_required) throw new AuthenticationStateError("REAUTH_REQUIRED");
      const needsAppleCheck = now - apple.verified_at >= providerCheckInterval;
      // Avoid consuming a proof just before the daily boundary while its operation is still in flight.
      if (!needsAppleCheck && apple.verified_at + providerCheckInterval - now <= operationLifetime) {
        throw new AuthenticationStateError("RENEWAL_BUSY");
      }
      if (needsAppleCheck && apple.check_lease_id) {
        if (apple.check_started_at + operationLifetime > now) throw new AuthenticationStateError("RENEWAL_BUSY");
        this.#storage.sql.exec("UPDATE auth_apple_state_v1 SET reauth_required=1 WHERE account_id=?", grant.account_id);
        return { error: "REAUTH_REQUIRED" };
      }
      const credential = this.#rows(`SELECT * FROM auth_refresh_credentials_v1
        WHERE credential_id=? AND account_id=? AND subject_hash=? AND state='bound'`,
      apple.credential_id, grant.account_id, grant.subject_hash)[0];
      if (!credential) throw new AuthenticationStateError("REAUTH_REQUIRED");
      const replacementID = needsAppleCheck ? randomUUID() : null;
      if (needsAppleCheck) {
        this.#reserveCredential(leaseID, grant.subject_hash, now, replacementID);
        this.#storage.sql.exec(`UPDATE auth_apple_state_v1 SET check_lease_id=?,check_started_at=?
          WHERE account_id=?`, leaseID, now, grant.account_id);
      }
      this.#storage.sql.exec(`UPDATE auth_renewal_grants_v1 SET state='claimed',lease_id=?,lease_started_at=?,
        provider_revision=?,needs_apple_check=?,replacement_credential_id=? WHERE grant_id=?`,
      leaseID, now, apple.revision, needsAppleCheck ? 1 : 0, replacementID, grant.grant_id);
      return Object.freeze({ leaseID, needsAppleCheck, subjectHash: grant.subject_hash,
        ...(needsAppleCheck ? { credentialID: credential.credential_id, sealedCredential: credential.sealed_credential,
          replacementCredentialID: replacementID } : {}) });
    });
    await this.#durable();
    if (result.error) throw new AuthenticationStateError(result.error);
    return result;
  }

  /** Preserve a newly rotated Apple token even if logout/new login makes the original renewal obsolete. */
  async stageRenewalCredential(leaseID, { appleSubject, sealedCredential } = {}) {
    if (typeof leaseID !== "string" || !uuid.test(leaseID)) throw new AuthenticationStateError();
    const now = this.#now();
    this.#transaction(() => {
      const reservation = this.#rows(`SELECT * FROM auth_credential_reservations_v1
        WHERE reservation_id=? AND expires_at>?`, leaseID, now)[0];
      if (!reservation || !uuid.test(reservation.credential_id ?? "") || appleSubjectHash(appleSubject) !== reservation.subject_hash ||
          typeof sealedCredential !== "string" || sealedCredential.length > 12000) throw new AuthenticationStateError();
      const fence = this.#rows("SELECT not_before FROM auth_subject_fences_v1 WHERE subject_hash=?", reservation.subject_hash)[0];
      if (fence && reservation.expires_at - 86400000 <= fence.not_before) this.#rejectLateCredentialAfterDeletion(reservation.subject_hash);
      const envelope = JSON.parse(sealedCredential);
      if (!envelope || envelope.v !== 1 || Object.keys(envelope).sort().join() !== "ciphertext,iv,keyID,tag,v") throw new AuthenticationStateError();
      this.#storage.sql.exec(`INSERT INTO auth_refresh_credentials_v1
        (credential_id,subject_hash,sealed_credential,state,created_at) VALUES (?,?,?,'pending',?)`,
      reservation.credential_id, reservation.subject_hash, sealedCredential, now);
      this.#storage.sql.exec("DELETE FROM auth_credential_reservations_v1 WHERE reservation_id=?", leaseID);
    });
    await this.#durable();
  }

  async completeRenewal(leaseID, { appleSubject, identityExpiresAt, replacementStaged = false } = {}) {
    if (typeof leaseID !== "string" || !uuid.test(leaseID)) throw new AuthenticationStateError("INVALID_SESSION");
    const now = this.#now();
    const result = this.#transaction(() => {
      const grant = this.#rows(`SELECT g.*,a.subject_hash FROM auth_renewal_grants_v1 g
        JOIN auth_accounts_v1 a ON a.account_id=g.account_id WHERE g.lease_id=? AND g.state='claimed'
        AND g.lease_started_at>? AND g.expires_at>? AND g.generation=a.generation AND a.disabled=0`,
      leaseID, now - operationLifetime, now)[0];
      if (!grant) throw new AuthenticationStateError("INVALID_SESSION");
      const apple = this.#rows("SELECT * FROM auth_apple_state_v1 WHERE account_id=?", grant.account_id)[0];
      if (!apple || apple.reauth_required || apple.revision !== grant.provider_revision) throw new AuthenticationStateError("REAUTH_REQUIRED");
      let expiresAt = Math.min(now + sessionLifetime, grant.expires_at);
      if (grant.needs_apple_check) {
        if (apple.check_lease_id !== leaseID || appleSubjectHash(appleSubject) !== grant.subject_hash ||
            !Number.isSafeInteger(identityExpiresAt) || !Number.isSafeInteger(identityExpiresAt * 1000) ||
            identityExpiresAt * 1000 <= now) throw new AuthenticationStateError("INVALID_IDENTITY");
        expiresAt = Math.min(expiresAt, identityExpiresAt * 1000);
        let credentialID = apple.credential_id;
        if (replacementStaged === true) {
          credentialID = grant.replacement_credential_id;
          const bound = this.#rows(`UPDATE auth_refresh_credentials_v1 SET state='bound',account_id=?
            WHERE credential_id=? AND subject_hash=? AND state='pending' RETURNING credential_id`,
          grant.account_id, credentialID, grant.subject_hash);
          if (bound.length !== 1) throw new AuthenticationStateError();
        } else if (replacementStaged !== false) throw new AuthenticationStateError();
        this.#storage.sql.exec(`UPDATE auth_apple_state_v1 SET credential_id=?,verified_at=?,revision=revision+1,
          check_lease_id=NULL,check_started_at=NULL WHERE account_id=?`, credentialID, now, grant.account_id);
        this.#storage.sql.exec("DELETE FROM auth_credential_reservations_v1 WHERE reservation_id=?", leaseID);
      } else if (appleSubject !== undefined || identityExpiresAt !== undefined || replacementStaged !== false ||
          now - apple.verified_at >= providerCheckInterval) {
        throw new AuthenticationStateError("REAUTH_REQUIRED");
      }
      const sessionToken = grant.grant_id + "." + randomBytes(32).toString("base64url");
      const renewalToken = this.#renewalProofs.create(grant.grant_id, grant.proof_sequence + 1, grant.proof_key_id);
      this.#storage.sql.exec(`INSERT INTO auth_sessions_v1(token_hash,account_id,generation,expires_at,challenge_id)
        VALUES (?,?,?,?,?) ON CONFLICT(challenge_id) DO UPDATE SET token_hash=excluded.token_hash,expires_at=excluded.expires_at`,
      this.#tokenHash(sessionToken), grant.account_id, grant.generation, expiresAt, grant.grant_id);
      this.#storage.sql.exec(`UPDATE auth_renewal_grants_v1 SET token_hash=?,state='active',lease_id=NULL,
        lease_started_at=NULL,provider_revision=NULL,needs_apple_check=NULL,replacement_credential_id=NULL,
        proof_sequence=proof_sequence+1 WHERE grant_id=?`,
      digest("echoes/renewal/v1\0" + renewalToken), grant.grant_id);
      return Object.freeze({ sessionToken, renewalToken, accountID: grant.account_id,
        expiresAt: Math.floor(expiresAt / 1000), renewalExpiresAt: Math.floor(grant.expires_at / 1000) });
    });
    await this.#durable(); return result;
  }

  async failRenewal(leaseID, { providerRejected = false } = {}) {
    if (typeof leaseID !== "string" || !uuid.test(leaseID)) throw new AuthenticationStateError();
    this.#transaction(() => {
      const grant = this.#rows("SELECT * FROM auth_renewal_grants_v1 WHERE lease_id=? AND state='claimed'", leaseID)[0];
      if (!grant) return; // A completed rotation is never undone after a late error/failed sync.
      this.#storage.sql.exec("UPDATE auth_renewal_grants_v1 SET state='uncertain' WHERE lease_id=?", leaseID);
      if (grant.needs_apple_check) {
        const changed = this.#rows(`UPDATE auth_apple_state_v1 SET reauth_required=1,check_lease_id=NULL,check_started_at=NULL
          WHERE account_id=? AND revision=? AND check_lease_id=? RETURNING account_id`,
        grant.account_id, grant.provider_revision, leaseID);
        if (providerRejected && changed.length) this.#storage.sql.exec(
          "UPDATE auth_accounts_v1 SET generation=generation+1 WHERE account_id=?", grant.account_id);
      }
      // Capacity remains reserved for unknown external outcomes until bounded expiry cleanup.
    });
    await this.#durable();
  }

  async revokeRenewal(renewalToken) {
    const now = this.#now();
    this.#transaction(() => {
      const grant = this.#renewalGrant(renewalToken, now);
      this.#storage.sql.exec("DELETE FROM auth_renewal_grants_v1 WHERE grant_id=?", grant.grant_id);
      this.#storage.sql.exec("DELETE FROM auth_sessions_v1 WHERE challenge_id=?", grant.grant_id);
    });
    await this.#durable();
  }

  async purgeExpired() { return purgeAuthenticationStorage(this.#storage, this.#clock); }
}


/** Local retention does not require provider keys or renewal secrets. */
export async function purgeAuthenticationStorage(storage, clock = Date.now) {
  const now = clock();
  if (!Number.isSafeInteger(now) || now < 0 || typeof storage?.transactionSync !== "function" ||
      typeof storage.sql?.exec !== "function" || typeof storage.sync !== "function") throw new AuthenticationStateError();
  try {
    storage.transactionSync(() => {
      storage.sql.exec(`DELETE FROM auth_challenges_v1 WHERE challenge_id IN
        (SELECT challenge_id FROM auth_challenges_v1 WHERE expires_at<=?
          AND (state!='claimed' OR expires_at<=?) LIMIT 100)`, now, now - 86400000);
      storage.sql.exec(`DELETE FROM auth_sessions_v1 WHERE token_hash IN
        (SELECT token_hash FROM auth_sessions_v1 WHERE expires_at<=? LIMIT 100)`, now);
      storage.sql.exec(`DELETE FROM auth_issue_budget_v1 WHERE (budget_hash,window_start) IN
        (SELECT budget_hash,window_start FROM auth_issue_budget_v1 WHERE window_start<=? LIMIT 100)`, now - issueWindow);
      storage.sql.exec(`DELETE FROM auth_renewal_grants_v1 WHERE grant_id IN
        (SELECT grant_id FROM auth_renewal_grants_v1 g WHERE expires_at<=? OR NOT EXISTS
          (SELECT 1 FROM auth_accounts_v1 a WHERE a.account_id=g.account_id AND a.generation=g.generation AND a.disabled=0) LIMIT 100)`, now);
      storage.sql.exec(`DELETE FROM auth_credential_reservations_v1 WHERE reservation_id IN
        (SELECT reservation_id FROM auth_credential_reservations_v1 WHERE expires_at<=? LIMIT 100)`, now);
      // Retention is local erasure, not a claim that Apple's authorization was revoked.
      storage.sql.exec(`DELETE FROM auth_refresh_credentials_v1 WHERE credential_id IN
        (SELECT c.credential_id FROM auth_refresh_credentials_v1 c WHERE c.created_at<=? AND
          NOT EXISTS (SELECT 1 FROM auth_account_deletions_v1 d WHERE d.subject_hash=c.subject_hash AND d.apple_status='pending') AND
          (NOT EXISTS (SELECT 1 FROM auth_apple_state_v1 p WHERE p.credential_id=c.credential_id) OR
           NOT EXISTS (SELECT 1 FROM auth_renewal_grants_v1 g JOIN auth_accounts_v1 a ON a.account_id=g.account_id
             WHERE g.account_id=c.account_id AND g.generation=a.generation AND a.disabled=0 AND g.expires_at>?)) LIMIT 100)`,
      now - renewalLifetime, now);
      storage.sql.exec(`DELETE FROM auth_apple_state_v1 WHERE account_id IN
        (SELECT p.account_id FROM auth_apple_state_v1 p WHERE NOT EXISTS
          (SELECT 1 FROM auth_refresh_credentials_v1 c WHERE c.credential_id=p.credential_id) LIMIT 100)`);
    });
    await storage.sync();
  } catch { throw new AuthenticationStateError(); }
}
