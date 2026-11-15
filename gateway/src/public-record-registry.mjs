import { PublicRecordError, publicUUID, recordIdentity, recordIdentityFromKey, validTag } from "./public-record-schema.mjs";
import { randomUUID } from "node:crypto";
import { validCheckpoint, sameCheckpoint } from "./public-registry-checkpoint.mjs";

const schema = [
  `CREATE TABLE IF NOT EXISTS public_records_v1 (
    record_name TEXT PRIMARY KEY,account_id TEXT NOT NULL,kind TEXT NOT NULL,logical_key TEXT,
    phase TEXT NOT NULL CHECK(phase IN ('pending','settled','erasing','erased')),
    request_id TEXT,payload_hash TEXT,expected_tag TEXT,record_tag TEXT,generation INTEGER NOT NULL,
    created_at INTEGER NOT NULL,started_at INTEGER NOT NULL,
    UNIQUE(account_id,kind,logical_key))`,
  `CREATE INDEX IF NOT EXISTS public_record_owner_v1 ON public_records_v1(account_id,phase,record_name)`,
  `CREATE TABLE IF NOT EXISTS public_record_counts_v1(scope TEXT PRIMARY KEY,value INTEGER NOT NULL CHECK(value>=0 AND value<=10000))`,
  `CREATE TABLE IF NOT EXISTS public_registry_checkpoint_v1(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    registry_id TEXT NOT NULL,initial_anchor TEXT NOT NULL,confirmed_value TEXT,confirmed_tag TEXT,
    pending_value TEXT,pending_expected_tag TEXT)`,
];
/** Metadata only, in the SAME private SQLite authority as auth/jobs. No names, text or GPS in SQL. */
export class PublicRecordRegistry {
  #storage; #clock; #registryID;
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
      if (!this.#rows("SELECT singleton FROM public_registry_checkpoint_v1 WHERE singleton=1").length) {
        if (this.#rows("SELECT record_name FROM public_records_v1 LIMIT 1").length) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        storage.sql.exec("INSERT INTO public_registry_checkpoint_v1(singleton,registry_id,initial_anchor) VALUES(1,?,?)", randomUUID(), randomUUID());
      }
      this.#registryID = this.#rows("SELECT registry_id FROM public_registry_checkpoint_v1 WHERE singleton=1")[0].registry_id;
      // Validate once at open. PITR restores the whole SQLite database at an instance restart.
      const rows = this.#rows("SELECT account_id,COUNT(*) AS n FROM public_records_v1 GROUP BY account_id");
      const counts = new Map(this.#rows("SELECT scope,value FROM public_record_counts_v1").map(row => [row.scope, row.value]));
      if (rows.reduce((n, row) => n + row.n, 0) !== counts.get("*") || rows.some(row => counts.get(row.account_id) !== row.n) ||
          counts.size !== rows.length + 1) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      this.#checkpointState();
    });
  }
  #tx(action) {
    try { return this.#storage.transactionSync(action); }
    catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new PublicRecordError(); return now; }
  async #durable() { try { await this.#storage.sync(); } catch { throw new PublicRecordError(); } }
  #checkpointState() {
    const row = this.#rows("SELECT * FROM public_registry_checkpoint_v1 WHERE singleton=1")[0];
    const count = this.#rows("SELECT value FROM public_record_counts_v1 WHERE scope='*'")[0]?.value;
    if (!row || row.registry_id !== this.#registryID || !publicUUID.test(row.registry_id ?? "") ||
        !publicUUID.test(row.initial_anchor ?? "") || !Number.isInteger(count) || count < 0 || count > 10000) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    const initial = { schemaVersion: 1, registryID: row.registry_id, anchorID: row.initial_anchor, parentAnchorID: "", registeredCount: 0 };
    const decode = value => {
      if (typeof value !== "string" || value.length > 2048) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      const parsed = JSON.parse(value);
      if (!validCheckpoint(parsed) || parsed.registryID !== row.registry_id || parsed.registeredCount > count) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      return Object.freeze(parsed);
    };
    const confirmed = row.confirmed_value === null && row.confirmed_tag === null ? null :
      { value: decode(row.confirmed_value), tag: row.confirmed_tag };
    const pending = row.pending_value === null && row.pending_expected_tag === null ? null :
      { value: decode(row.pending_value), expectedTag: row.pending_expected_tag };
    if (confirmed && !validTag(confirmed.tag) || pending && (!confirmed || !validTag(pending.expectedTag) ||
        pending.expectedTag !== confirmed.tag || pending.value.parentAnchorID !== confirmed.value.anchorID ||
        pending.value.anchorID === confirmed.value.anchorID || pending.value.registeredCount < confirmed.value.registeredCount)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    return Object.freeze({ registryID: row.registry_id, initial: Object.freeze(initial), confirmed, pending, registeredCount: count });
  }
  async checkpointState() { const state = this.#tx(() => this.#checkpointState()); await this.#durable(); return state; }
  /** Trusted operator preparation ONLY; runtime never creates a missing remote record. */
  async prepareBootstrap() {
    const state = await this.checkpointState();
    if (state.confirmed || state.pending || state.registeredCount !== 0) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    return state.initial;
  }
  async confirmInitialCheckpoint(remote) {
    this.#tx(() => {
      const state = this.#checkpointState();
      if (state.confirmed || state.pending || state.registeredCount !== 0 || !sameCheckpoint(remote?.value, state.initial) ||
          !validTag(remote?.tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      this.#storage.sql.exec("UPDATE public_registry_checkpoint_v1 SET confirmed_value=?,confirmed_tag=? WHERE singleton=1", JSON.stringify(remote.value), remote.tag);
    });
    await this.#durable();
  }
  async prepareCheckpoint(expected) {
    const pending = this.#tx(() => {
      const state = this.#checkpointState();
      if (!state.confirmed || state.pending || !sameCheckpoint(expected?.value, state.confirmed.value) || expected.tag !== state.confirmed.tag) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      const value = { schemaVersion: 1, registryID: state.registryID, anchorID: randomUUID(),
        parentAnchorID: state.confirmed.value.anchorID, registeredCount: state.registeredCount };
      this.#storage.sql.exec("UPDATE public_registry_checkpoint_v1 SET pending_value=?,pending_expected_tag=? WHERE singleton=1", JSON.stringify(value), state.confirmed.tag);
      return Object.freeze({ value: Object.freeze(value), expectedTag: state.confirmed.tag });
    });
    await this.#durable(); return pending;
  }
  async confirmPendingCheckpoint(expected, remote) {
    this.#tx(() => {
      const state = this.#checkpointState();
      if (!state.pending || !sameCheckpoint(expected?.value, state.pending.value) || expected.expectedTag !== state.pending.expectedTag ||
          !sameCheckpoint(remote?.value, state.pending.value) || !validTag(remote?.tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      this.#storage.sql.exec(`UPDATE public_registry_checkpoint_v1 SET confirmed_value=?,confirmed_tag=?,
        pending_value=NULL,pending_expected_tag=NULL WHERE singleton=1`, JSON.stringify(remote.value), remote.tag);
    });
    await this.#durable();
  }
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
  /** A settled row is necessary for declassification. Unknown or incomplete content stays hidden. */
  readable(name, kind) {
    return this.#tx(() => {
      const row = this.#row(name);
      if (!row || row.kind !== kind || row.phase !== "settled") return null;
      const context = this.#context(row);
      if (!this.#rows("SELECT account_id FROM auth_accounts_v1 WHERE account_id=? AND disabled=0", row.account_id).length) return null;
      return context;
    });
  }
  owned(accountID, kind, logicalID) {
    return this.#tx(() => {
      this.#active(accountID);
      const row = this.#row(recordIdentity(accountID, kind, logicalID).recordName);
      return row ? this.#context(row) : null;
    });
  }
  /** Trusted latest-intent slots only. Immutable content and profiles keep strict explicit CAS. */
  async reserveLatest(value) {
    if (!["presence", "block"].includes(value?.kind)) throw new PublicRecordError("PUBLIC_INPUT");
    const identity = recordIdentity(value.accountID, value.kind, value.logicalID);
    const old = this.#tx(() => {
      this.#active(value.accountID);
      const row = this.#row(identity.recordName);
      if (!row) return null;
      const context = this.#context(row);
      if (["erasing", "erased"].includes(context.phase)) throw new PublicRecordError("PUBLIC_ERASED");
      if (context.requestID === value.requestID && context.payloadHash !== value.payloadHash) throw new PublicRecordError("PUBLIC_CONFLICT");
      return context;
    });
    if (!old) return this.reserve(value);
    if (!publicUUID.test(value.requestID ?? "") || !/^[a-f0-9]{64}$/.test(value.payloadHash ?? "") ||
        value.expectedTag !== null && !validTag(value.expectedTag)) throw new PublicRecordError("PUBLIC_INPUT");
    const result = this.#tx(() => {
      const current = this.#context(this.#row(identity.recordName));
      if (["erasing", "erased"].includes(current.phase) || current.requestID !== old.requestID || current.payloadHash !== old.payloadHash ||
          current.expectedTag !== old.expectedTag || current.recordTag !== old.recordTag) throw new PublicRecordError("PUBLIC_CONFLICT");
      this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='pending',request_id=?,payload_hash=?,expected_tag=?,
        generation=?,started_at=? WHERE record_name=?`, value.requestID, value.payloadHash, value.expectedTag,
      this.#active(value.accountID), old.requestID === value.requestID ? old.startedAt : this.#now(), identity.recordName);
      return this.#context(this.#row(identity.recordName));
    });
    await this.#durable(); return result;
  }
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
