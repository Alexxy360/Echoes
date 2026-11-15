import { PublicRecordError, publicUUID, recordIdentity, recordIdentityFromKey, validTag } from "./public-record-schema.mjs";

const schema = [
  `CREATE TABLE IF NOT EXISTS public_records_v1 (
    record_name TEXT PRIMARY KEY,account_id TEXT NOT NULL,kind TEXT NOT NULL,logical_key TEXT,
    phase TEXT NOT NULL CHECK(phase IN ('pending','settled','erasing','erased')),
    request_id TEXT,payload_hash TEXT,expected_tag TEXT,record_tag TEXT,generation INTEGER NOT NULL,
    created_at INTEGER NOT NULL,started_at INTEGER NOT NULL,
    UNIQUE(account_id,kind,logical_key))`,
  `CREATE INDEX IF NOT EXISTS public_record_owner_v1 ON public_records_v1(account_id,phase,record_name)`,
  `CREATE TABLE IF NOT EXISTS public_record_counts_v1(scope TEXT PRIMARY KEY,value INTEGER NOT NULL CHECK(value>=0 AND value<=10000))`,
];
/** Metadata only, in the SAME private SQLite authority as auth/jobs. No names, text or GPS in SQL. */
export class PublicRecordRegistry {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw new PublicRecordError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => {
      for (const statement of schema) storage.sql.exec(statement);
      if (!this.#rows("SELECT scope FROM public_record_counts_v1 WHERE scope='*'").length) {
        storage.sql.exec("INSERT INTO public_record_counts_v1(scope,value) SELECT '*',COUNT(*) FROM public_records_v1");
        storage.sql.exec("INSERT INTO public_record_counts_v1(scope,value) SELECT account_id,COUNT(*) FROM public_records_v1 GROUP BY account_id");
      }
    });
  }
  #tx(action) {
    try { return this.#storage.transactionSync(action); }
    catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new PublicRecordError(); return now; }
  async #durable() { try { await this.#storage.sync(); } catch { throw new PublicRecordError(); } }
  #active(accountID, generation) {
    const row = this.#rows("SELECT generation FROM auth_accounts_v1 WHERE account_id=? AND disabled=0", accountID)[0];
    if (!row || !Number.isSafeInteger(row.generation) || (generation !== undefined && row.generation !== generation)) throw new PublicRecordError("PUBLIC_SCOPE");
    return row.generation;
  }
  #row(name) { return this.#rows("SELECT * FROM public_records_v1 WHERE record_name=?", name)[0]; }
  #context(row) {
    if (!row) throw new PublicRecordError("PUBLIC_SCOPE");
    if (row.phase === "erased") throw new PublicRecordError("PUBLIC_ERASED");
    const identity = recordIdentityFromKey(row.account_id, row.kind, row.logical_key);
    if (identity.recordName !== row.record_name || !Number.isSafeInteger(row.generation) || row.generation < 0 ||
        !Number.isSafeInteger(row.created_at) || row.created_at < 0 || !Number.isSafeInteger(row.started_at) || row.started_at < row.created_at ||
        !["pending", "settled", "erasing", "erased"].includes(row.phase) ||
        row.phase !== "erased" && (!publicUUID.test(row.request_id ?? "") || !/^[a-f0-9]{64}$/.test(row.payload_hash ?? "")) ||
        row.expected_tag !== null && !validTag(row.expected_tag) || row.record_tag !== null && !validTag(row.record_tag) ||
        ["settled", "erased"].includes(row.phase) && !validTag(row.record_tag)) throw new PublicRecordError();
    return Object.freeze({ ...identity, phase: row.phase, requestID: row.request_id, payloadHash: row.payload_hash,
      expectedTag: row.expected_tag, recordTag: row.record_tag, generation: row.generation,
      createdAt: row.created_at, startedAt: row.started_at });
  }
  async reserve({ accountID, kind, logicalID, requestID, payloadHash, expectedTag = null } = {}) {
    const identity = recordIdentity(accountID, kind, logicalID), now = this.#now();
    if (!publicUUID.test(requestID ?? "") || typeof payloadHash !== "string" || !/^[a-f0-9]{64}$/.test(payloadHash) ||
        expectedTag !== null && !validTag(expectedTag)) throw new PublicRecordError("PUBLIC_INPUT");
    const result = this.#tx(() => {
      const generation = this.#active(accountID), previous = this.#row(identity.recordName);
      if (previous) {
        const old = this.#context(previous);
        if (["erasing", "erased"].includes(old.phase)) throw new PublicRecordError("PUBLIC_ERASED");
        if (old.requestID === requestID) {
          if (old.payloadHash !== payloadHash || old.expectedTag !== expectedTag) throw new PublicRecordError("PUBLIC_CONFLICT");
          this.#storage.sql.exec("UPDATE public_records_v1 SET generation=? WHERE record_name=?", generation, identity.recordName);
          return this.#context(this.#row(identity.recordName));
        }
        if (old.phase === "pending") throw new PublicRecordError("PUBLIC_PENDING");
        if (old.recordTag !== expectedTag) throw new PublicRecordError("PUBLIC_CONFLICT");
        this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='pending',request_id=?,payload_hash=?,expected_tag=?,
          generation=?,started_at=? WHERE record_name=?`, requestID, payloadHash, expectedTag, generation, now, identity.recordName);
      } else {
        if (expectedTag !== null) throw new PublicRecordError("PUBLIC_CONFLICT");
        // Conservative limits of the controlled Development target, including retained fences.
        const owned = this.#rows("SELECT value FROM public_record_counts_v1 WHERE scope=?", accountID)[0]?.value ?? 0;
        const total = this.#rows("SELECT value FROM public_record_counts_v1 WHERE scope='*'")[0]?.value;
        if (!Number.isSafeInteger(owned) || owned < 0 || !Number.isSafeInteger(total) || total < owned) throw new PublicRecordError();
        if (owned >= 1000 || total >= 10000) throw new PublicRecordError("PUBLIC_LIMIT");
        this.#storage.sql.exec("UPDATE public_record_counts_v1 SET value=value+1 WHERE scope='*'");
        this.#storage.sql.exec(`INSERT INTO public_record_counts_v1(scope,value) VALUES(?,1)
          ON CONFLICT(scope) DO UPDATE SET value=value+1`, accountID);
        this.#storage.sql.exec(`INSERT INTO public_records_v1(record_name,account_id,kind,logical_key,phase,request_id,
          payload_hash,expected_tag,record_tag,generation,created_at,started_at) VALUES(?,?,?,?,'pending',?,?,NULL,NULL,?,?,?)`,
        identity.recordName, accountID, kind, identity.logicalKey, requestID, payloadHash, generation, now, now);
      }
      return this.#context(this.#row(identity.recordName));
    });
    await this.#durable(); return result;
  }
  #mutation(context) {
    const row = this.#context(this.#row(context?.recordName));
    if (row.accountID !== context.accountID || ["erasing", "erased"].includes(row.phase)) throw new PublicRecordError("PUBLIC_ERASED");
    this.#active(row.accountID, context.generation);
    if (row.generation !== context.generation || row.requestID !== context.requestID || row.payloadHash !== context.payloadHash ||
        row.expectedTag !== context.expectedTag) throw new PublicRecordError("PUBLIC_CONFLICT");
    return row;
  }
  assertMutationCurrent(context) { return this.#tx(() => this.#mutation(context)); }
  async settle(context, recordTag) {
    if (!validTag(recordTag)) throw new PublicRecordError("PUBLIC_RESPONSE");
    this.#tx(() => {
      const row = this.#mutation(context);
      if (row.phase === "settled" && row.recordTag !== recordTag) throw new PublicRecordError("PUBLIC_CONFLICT");
      this.#storage.sql.exec("UPDATE public_records_v1 SET phase='settled',record_tag=? WHERE record_name=?", recordTag, row.recordName);
    });
    await this.#durable();
    return this.assertMutationCurrent(context);
  }
  #deletion(context) {
    if (!publicUUID.test(context?.accountID ?? "") || !publicUUID.test(context?.deletionID ?? "") ||
        !publicUUID.test(context?.leaseID ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
    const job = this.#rows(`SELECT d.account_id,d.public_lease_id,d.public_lease_at FROM auth_account_deletions_v1 d
      JOIN auth_accounts_v1 a ON a.account_id=d.account_id WHERE d.deletion_id=? AND d.local_status='blocked'
      AND d.public_status!='deleted' AND a.disabled=1`, context.deletionID)[0];
    const now = this.#now();
    if (!job || job.account_id !== context.accountID || job.public_lease_id !== context.leaseID ||
        !Number.isSafeInteger(job.public_lease_at) || job.public_lease_at > now || job.public_lease_at + 60000 <= now) throw new PublicRecordError("PUBLIC_SCOPE");
  }
  async erasureBatch(context, maximumRecords) {
    if (!Number.isInteger(maximumRecords) || maximumRecords < 1 || maximumRecords > 100) throw new PublicRecordError("PUBLIC_INPUT");
    const records = this.#tx(() => {
      this.#deletion(context);
      const rows = this.#rows(`SELECT * FROM public_records_v1 WHERE account_id=? AND phase!='erased'
        ORDER BY record_name LIMIT ?`, context.accountID, Math.min(25, maximumRecords));
      for (const row of rows) {
        this.#context(row);
        this.#storage.sql.exec("UPDATE public_records_v1 SET phase='erasing' WHERE record_name=?", row.record_name);
      }
      return rows.map(row => this.#context({ ...row, phase: "erasing" }));
    });
    await this.#durable(); this.assertErasureCurrent(context); return records;
  }
  assertErasureCurrent(context) { this.#tx(() => this.#deletion(context)); }
  async completeErasure(context, records) {
    if (!(records instanceof Map) || records.size > 25) throw new PublicRecordError("PUBLIC_INPUT");
    this.#tx(() => {
      this.#deletion(context);
      for (const [name, tag] of records) {
        const row = this.#context(this.#row(name));
        if (row.accountID !== context.accountID || row.phase !== "erasing" || !validTag(tag)) throw new PublicRecordError("PUBLIC_SCOPE");
        this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='erased',logical_key=NULL,request_id=NULL,payload_hash=NULL,
          expected_tag=NULL,generation=0,created_at=0,started_at=0,record_tag=? WHERE record_name=?`, tag, name);
      }
    });
    await this.#durable();
    return this.#tx(() => {
      this.#deletion(context);
      const remaining = this.#rows("SELECT record_name FROM public_records_v1 WHERE account_id=? AND phase!='erased' LIMIT 1", context.accountID).length > 0;
      return Object.freeze({ accountID: context.accountID, deletionID: context.deletionID, remaining });
    });
  }
}
