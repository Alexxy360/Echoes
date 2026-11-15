import { CommunityError, communityUUID } from "./community-domain.mjs";

const schema = [
  `CREATE TABLE IF NOT EXISTS community_accounts_v1(account_id TEXT PRIMARY KEY,generation INTEGER NOT NULL DEFAULT 0,
    suspended INTEGER NOT NULL DEFAULT 0,presence_at INTEGER,send_at INTEGER,nearby_at INTEGER,messages_at INTEGER,block_at INTEGER,report_at INTEGER)`,
  `CREATE TABLE IF NOT EXISTS community_intents_v1(account_id TEXT NOT NULL,kind TEXT NOT NULL,logical_id TEXT NOT NULL,
    request_id TEXT NOT NULL,payload_hash TEXT NOT NULL,ready INTEGER NOT NULL,active INTEGER NOT NULL,
    generation INTEGER NOT NULL,hidden INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(account_id,kind,logical_id))`,
  `CREATE INDEX IF NOT EXISTS community_incoming_blocks_v1 ON community_intents_v1(kind,logical_id,active,account_id)`,
  `CREATE INDEX IF NOT EXISTS community_mutation_v1 ON community_intents_v1(account_id,kind,request_id)`,
];
/** Private policy projection only. Never stores public names, messages, song metadata or GPS. */
export class CommunityState {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.transactionSync !== "function" || typeof storage?.sync !== "function" || typeof storage?.sql?.exec !== "function") throw new CommunityError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => { for (const sql of schema) storage.sql.exec(sql); });
  }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (error) { throw error instanceof CommunityError ? error : new CommunityError(); } }
  async #durable() { try { await this.#storage.sync(); } catch { throw new CommunityError(); } }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new CommunityError(); return now; }
  #account(accountID) {
    communityUUID(accountID);
    if (!this.#rows("SELECT account_id FROM auth_accounts_v1 WHERE account_id=? AND disabled=0", accountID).length) throw new CommunityError("COMMUNITY_STALE");
    const account = this.#rows("SELECT * FROM community_accounts_v1 WHERE account_id=?", accountID)[0];
    if (account?.suspended) throw new CommunityError("COMMUNITY_STALE");
    return account ?? { account_id: accountID, generation: 0 };
  }
  #ensure(accountID) {
    this.#account(accountID);
    this.#storage.sql.exec("INSERT OR IGNORE INTO community_accounts_v1(account_id) VALUES(?)", accountID);
  }
  #row(accountID, kind, logicalID) { return this.#rows("SELECT * FROM community_intents_v1 WHERE account_id=? AND kind=? AND logical_id=?", accountID, kind, logicalID)[0]; }
  #rate(accountID, kind, delay) {
    const columns = { presence: "presence_at", message: "send_at", nearby: "nearby_at", messages: "messages_at", block: "block_at", report: "report_at" };
    const column = columns[kind]; if (!column) throw new CommunityError();
    const now = this.#now(), previous = this.#rows(`SELECT ${column} AS time FROM community_accounts_v1 WHERE account_id=?`, accountID)[0]?.time;
    if (previous !== null && previous !== undefined && previous + delay > now) throw new CommunityError("COMMUNITY_RATE_LIMITED");
    this.#storage.sql.exec(`UPDATE community_accounts_v1 SET ${column}=? WHERE account_id=?`, now, accountID);
  }
  visibility(accountID) { return this.#tx(() => ({ generation: this.#account(accountID).generation })); }
  assertActive(accountID) { this.#tx(() => this.#account(accountID)); }
  async admitRead(accountID, kind) {
    if (!["nearby", "messages"].includes(kind)) throw new CommunityError();
    this.#tx(() => { this.#ensure(accountID); this.#rate(accountID, kind, kind === "nearby" ? 3000 : 1000); });
    await this.#durable(); this.assertActive(accountID);
  }
  async begin({ accountID, kind, logicalID, requestID, payloadHash, generation, active = true }) {
    communityUUID(requestID);
    if (!["presence", "message", "block", "report"].includes(kind) || typeof logicalID !== "string" || logicalID.length > 100 ||
        !/^[a-f0-9]{64}$/.test(payloadHash ?? "") || typeof active !== "boolean") throw new CommunityError("COMMUNITY_INPUT");
    const intent = this.#tx(() => {
      this.#ensure(accountID); const account = this.#account(accountID), old = this.#row(accountID, kind, logicalID);
      if (kind === "presence" && (generation !== account.generation || !Number.isSafeInteger(generation))) throw new CommunityError("COMMUNITY_STALE");
      if (old?.request_id === requestID) {
        if (old.payload_hash !== payloadHash || old.active !== Number(active)) throw new CommunityError("COMMUNITY_STALE");
        return old;
      }
      this.#rate(accountID, kind, { presence: 5000, message: 5000, block: 1000, report: 10000 }[kind]);
      if (kind === "block") {
        communityUUID(logicalID);
        if (logicalID === accountID) throw new CommunityError("COMMUNITY_INPUT");
        // Target existence is deliberately not exposed by block/unblock.
        if (active && !old?.active && this.#rows("SELECT logical_id FROM community_intents_v1 WHERE account_id=? AND kind='block' AND active=1 LIMIT 200", accountID).length >= 200) throw new CommunityError("COMMUNITY_CAPACITY");
      }
      if (!old && this.#rows("SELECT logical_id FROM community_intents_v1 WHERE account_id=? LIMIT 1000", accountID).length >= 1000) throw new CommunityError("COMMUNITY_CAPACITY");
      this.#storage.sql.exec(`INSERT INTO community_intents_v1(account_id,kind,logical_id,request_id,payload_hash,ready,active,generation)
        VALUES(?,?,?,?,?,0,?,?) ON CONFLICT(account_id,kind,logical_id) DO UPDATE SET request_id=excluded.request_id,
        payload_hash=excluded.payload_hash,ready=0,active=excluded.active,generation=excluded.generation`,
      accountID, kind, logicalID, requestID, payloadHash, Number(active), account.generation);
      return this.#row(accountID, kind, logicalID);
    });
    await this.#durable(); this.assertCurrent(intent); return intent;
  }
  async stop(accountID, requestID, generation, payloadHash) {
    communityUUID(requestID);
    const intent = this.#tx(() => {
      this.#ensure(accountID); const account = this.#account(accountID), old = this.#row(accountID, "presence", "singleton");
      if (old?.request_id === requestID && old.active === 0) {
        if (generation + 1 !== old.generation) throw new CommunityError("COMMUNITY_STALE"); return old;
      }
      if (!Number.isSafeInteger(generation) || generation !== account.generation || generation >= Number.MAX_SAFE_INTEGER) throw new CommunityError("COMMUNITY_STALE");
      this.#storage.sql.exec("UPDATE community_accounts_v1 SET generation=generation+1 WHERE account_id=?", accountID);
      this.#storage.sql.exec(`INSERT INTO community_intents_v1(account_id,kind,logical_id,request_id,payload_hash,ready,active,generation)
        VALUES(?,'presence','singleton',?,?,0,0,?) ON CONFLICT(account_id,kind,logical_id) DO UPDATE SET request_id=excluded.request_id,
        payload_hash=excluded.payload_hash,ready=0,active=0,generation=excluded.generation`, accountID, requestID, payloadHash, generation + 1);
      return this.#row(accountID, "presence", "singleton");
    });
    await this.#durable(); this.assertCurrent(intent); return intent;
  }
  assertCurrent(intent) {
    return this.#tx(() => {
      const account = this.#account(intent.account_id), row = this.#row(intent.account_id, intent.kind, intent.logical_id);
      if (!row || row.request_id !== intent.request_id || row.payload_hash !== intent.payload_hash ||
          intent.kind === "presence" && (row.generation !== account.generation || row.generation !== intent.generation)) throw new CommunityError("COMMUNITY_STALE");
      return row;
    });
  }
  async finish(intent) {
    this.#tx(() => { this.#account(intent.account_id); const row = this.#row(intent.account_id, intent.kind, intent.logical_id);
      if (!row || row.request_id !== intent.request_id || row.payload_hash !== intent.payload_hash ||
          intent.kind === "presence" && this.#account(intent.account_id).generation !== intent.generation) throw new CommunityError("COMMUNITY_STALE");
      this.#storage.sql.exec("UPDATE community_intents_v1 SET ready=1 WHERE account_id=? AND kind=? AND logical_id=? AND request_id=?", intent.account_id, intent.kind, intent.logical_id, intent.request_id);
    });
    await this.#durable(); this.assertCurrent(intent);
  }
  visible(viewerID, context) {
    return this.#tx(() => {
      this.#account(viewerID);
      const author = this.#rows(`SELECT a.disabled,c.suspended,c.generation FROM auth_accounts_v1 a
        LEFT JOIN community_accounts_v1 c ON c.account_id=a.account_id WHERE a.account_id=?`, context.accountID)[0];
      if (!author || author.disabled || author.suspended) return false;
      if (this.#rows(`SELECT account_id FROM community_intents_v1 WHERE kind='block' AND active=1 AND
        ((account_id=? AND logical_id=?) OR (account_id=? AND logical_id=?)) LIMIT 1`, viewerID, context.accountID, context.accountID, viewerID).length) return false;
      const row = this.#rows(`SELECT * FROM community_intents_v1 WHERE account_id=? AND kind=? AND request_id=?`, context.accountID, context.kind, context.requestID)[0];
      return !!row && !!row.ready && !!row.active && !row.hidden && row.payload_hash === context.payloadHash &&
        (context.kind !== "presence" || row.generation === author.generation);
    });
  }
  blocked(accountID) { return this.#tx(() => { this.#account(accountID); return this.#rows("SELECT logical_id FROM community_intents_v1 WHERE account_id=? AND kind='block' AND active=1 ORDER BY logical_id LIMIT 200", accountID).map(row => row.logical_id); }); }
  /** Trusted operator hooks only. No moderation authority is exposed through public HTTP. */
  async hideMessage(accountID, requestID) { this.#tx(() => this.#storage.sql.exec("UPDATE community_intents_v1 SET hidden=1 WHERE account_id=? AND kind='message' AND request_id=?", accountID, requestID)); await this.#durable(); }
  async setSuspended(accountID, suspended) {
    communityUUID(accountID); if (typeof suspended !== "boolean") throw new CommunityError();
    this.#tx(() => this.#storage.sql.exec("INSERT INTO community_accounts_v1(account_id,suspended) VALUES(?,?) ON CONFLICT(account_id) DO UPDATE SET suspended=excluded.suspended", accountID, Number(suspended))); await this.#durable();
  }
  async eraseOwner(accountID) {
    communityUUID(accountID);
    this.#tx(() => {
      if (!this.#rows("SELECT account_id FROM auth_accounts_v1 WHERE account_id=? AND disabled=1", accountID).length) throw new CommunityError("COMMUNITY_STALE");
      this.#storage.sql.exec("DELETE FROM community_intents_v1 WHERE account_id=?", accountID);
      this.#storage.sql.exec("DELETE FROM community_accounts_v1 WHERE account_id=?", accountID);
    }); await this.#durable();
  }
}
