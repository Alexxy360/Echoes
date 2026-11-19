import { PublicRecordError, publicUUID, publicRecordName, recordIdentity, recordIdentityFromKey, validTag } from "./public-record-schema.mjs";
import { randomUUID } from "node:crypto";
import { validCheckpoint, sameCheckpoint } from "./public-registry-checkpoint.mjs";
import { publicRetentionDeadline, publicRetentionIntentKey, publicRetentionLeaseMilliseconds, publicRetentionSchema } from "./public-retention-policy.mjs";
import { avatarReportCancellationKey, avatarReportCancellationFields } from "./avatar-report-cancellation.mjs";
import { avatarRetirementDeadline, backfillAvatarRetirements, needsAvatarRetirementBackfill, expireAvatarTransferReceipts } from "./avatar-retirement-state.mjs";
import { migrateAvatarSelectionExpiry, avatarSelectionExpirySchedule } from "./avatar-selection-expiry.mjs";

const schema = [
  `CREATE TABLE IF NOT EXISTS public_records_v1 (
    record_name TEXT PRIMARY KEY,account_id TEXT NOT NULL,kind TEXT NOT NULL,logical_key TEXT,
    phase TEXT NOT NULL CHECK(phase IN ('pending','settled','erasing','erased')),
    request_id TEXT,payload_hash TEXT,expected_tag TEXT,record_tag TEXT,generation INTEGER NOT NULL,
    created_at INTEGER NOT NULL,started_at INTEGER NOT NULL,asset_claims INTEGER CHECK(asset_claims IS NULL OR asset_claims IN (0,1,2,3)),
    UNIQUE(account_id,kind,logical_key))`,
  `CREATE INDEX IF NOT EXISTS public_record_owner_v1 ON public_records_v1(account_id,phase,record_name)`,
  `CREATE INDEX IF NOT EXISTS public_report_review_v1 ON public_records_v1(record_name) WHERE kind='report' AND phase='settled'`,
  `CREATE TABLE IF NOT EXISTS avatar_asset_transfers_v1 (
    record_name TEXT NOT NULL,variant TEXT NOT NULL CHECK(variant IN ('image','thumbnail')),
    transfer_id TEXT,request_id TEXT,payload_hash TEXT,generation INTEGER,content_sha256 TEXT,byte_count INTEGER,
    phase TEXT NOT NULL CHECK(phase IN ('claimed','acknowledged','erased')),receipt_hash TEXT,file_checksum_hash TEXT,
    receipt_envelope TEXT,receipt_expires_at INTEGER,started_at INTEGER NOT NULL,
    PRIMARY KEY(record_name,variant))`,
  `CREATE TABLE IF NOT EXISTS public_record_counts_v1(scope TEXT PRIMARY KEY,value INTEGER NOT NULL CHECK(value>=0 AND value<=10000))`,
  `CREATE TABLE IF NOT EXISTS public_registry_checkpoint_v1(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    registry_id TEXT NOT NULL,initial_anchor TEXT NOT NULL,confirmed_value TEXT,confirmed_tag TEXT,
    pending_value TEXT,pending_expected_tag TEXT)`,
];
/** Metadata and short-lived encrypted receipts in the SAME private SQLite authority as auth/jobs.
 * No photo pixels, names, text, GPS or plaintext provider receipts in SQL.
 */
export class PublicRecordRegistry {
  #storage; #clock; #registryID;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw new PublicRecordError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => {
      const existed = this.#rows("SELECT name FROM sqlite_master WHERE type='table' AND name='public_records_v1'").length;
      if (existed && !this.#rows("SELECT name FROM sqlite_master WHERE type='table' AND name='avatar_asset_transfers_v1'").length &&
          this.#rows("SELECT record_name FROM public_records_v1 WHERE kind='avatar' LIMIT 1").length) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      for (const statement of [...schema, ...publicRetentionSchema]) storage.sql.exec(statement);
      const cancellationColumns = new Set(this.#rows("PRAGMA table_info(public_records_v1)").map(row => row.name));
      for (const name of ["avatar_report_cancel_key", "avatar_report_cancel_tag"]) {
        if (!cancellationColumns.has(name)) storage.sql.exec(`ALTER TABLE public_records_v1 ADD COLUMN ${name} TEXT`);
      }
      for (const row of this.#rows("SELECT * FROM public_records_v1 WHERE avatar_report_cancel_key IS NOT NULL OR avatar_report_cancel_tag IS NOT NULL")) {
        if (row.kind !== "avatarreport" || !["erasing", "erased"].includes(row.phase) ||
            !/^[a-f0-9]{64}$/.test(row.avatar_report_cancel_key ?? "") ||
            row.avatar_report_cancel_tag !== null && (row.phase !== "erased" || !validTag(row.avatar_report_cancel_tag) || row.record_tag !== row.avatar_report_cancel_tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        if (row.phase === "erasing" && (!publicUUID.test(row.request_id ?? "") ||
            row.avatar_report_cancel_key !== avatarReportCancellationKey(row.account_id, row.request_id) ||
            row.record_name !== recordIdentity(row.account_id, "avatarreport", row.request_id).recordName)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      }
      migrateAvatarSelectionExpiry(storage);
      if (!this.#rows("PRAGMA table_info(public_records_v1)").some(row => row.name === "asset_claims")) {
        // NULL marks legacy avatar attempts: unknown claim history cannot safely authorize new uploads.
        storage.sql.exec("ALTER TABLE public_records_v1 ADD COLUMN asset_claims INTEGER CHECK(asset_claims IS NULL OR asset_claims IN (0,1,2,3))");
      }
      // Existing attempts stay consumed. Legacy acknowledgements cannot prove a file checksum;
      // they remain erasable, but cannot be attached/recovered by the new repository.
      const columns = new Set(this.#rows("PRAGMA table_info(avatar_asset_transfers_v1)").map(row => row.name));
      for (const [name, type] of [["file_checksum_hash", "TEXT"], ["receipt_envelope", "TEXT"], ["receipt_expires_at", "INTEGER"]]) {
        if (!columns.has(name)) storage.sql.exec(`ALTER TABLE avatar_asset_transfers_v1 ADD COLUMN ${name} ${type}`);
      }
      storage.sql.exec("CREATE INDEX IF NOT EXISTS avatar_receipt_expiry_v1 ON avatar_asset_transfers_v1(receipt_expires_at) WHERE receipt_envelope IS NOT NULL");
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
      if (this.#rows(`SELECT t.record_name FROM avatar_asset_transfers_v1 t
        LEFT JOIN public_records_v1 p ON p.record_name=t.record_name WHERE p.record_name IS NULL OR p.kind!='avatar'
        OR (p.phase='erased')!=(t.phase='erased') LIMIT 1`).length) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      if (this.#rows(`SELECT p.record_name FROM public_records_v1 p WHERE p.kind='avatar' AND p.phase!='erased' AND p.asset_claims IS NOT NULL
        AND (((p.asset_claims & 1)!=0)!=EXISTS(SELECT 1 FROM avatar_asset_transfers_v1 t WHERE t.record_name=p.record_name AND t.variant='image')
        OR ((p.asset_claims & 2)!=0)!=EXISTS(SELECT 1 FROM avatar_asset_transfers_v1 t WHERE t.record_name=p.record_name AND t.variant='thumbnail')) LIMIT 1`).length) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
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
  #retentionDeadline(context) {
    return context.kind === "avatar" ? avatarRetirementDeadline(this.#storage, context, this.#now()) : publicRetentionDeadline(context);
  }
  #retention(context) {
    const dueAt = this.#retentionDeadline(context);
    if (dueAt === null) return null;
    const row = this.#rows("SELECT * FROM public_retention_v1 WHERE record_name=?", context.recordName)[0];
    if (row && (row.intent_key !== publicRetentionIntentKey(context) || row.due_at !== dueAt ||
        !["pending", "fencing", "fenced"].includes(row.state) ||
        (row.state === "fencing" ? !publicUUID.test(row.lease_id ?? "") || !Number.isSafeInteger(row.lease_at) || row.lease_at < 0 :
          row.lease_id !== null || row.lease_at !== null) ||
        (row.state === "fenced" ? !validTag(row.fence_tag) || context.kind !== "presence" || context.phase !== "settled" ||
          context.recordTag !== row.fence_tag : row.fence_tag !== null))) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    return row;
  }
  #enqueueRetention(context) {
    const dueAt = this.#retentionDeadline(context);
    if (dueAt === null) return;
    if (context.kind === "avatar") throw new PublicRecordError("PUBLIC_ERASED");
    if (context.startedAt > this.#now() || dueAt <= this.#now()) throw new PublicRecordError("PUBLIC_ERASED");
    this.#storage.sql.exec(`INSERT INTO public_retention_v1(record_name,intent_key,due_at,state) VALUES(?,?,?,'pending')
      ON CONFLICT(record_name) DO UPDATE SET intent_key=excluded.intent_key,due_at=excluded.due_at,
      state='pending',lease_id=NULL,lease_at=NULL,fence_tag=NULL`, context.recordName, publicRetentionIntentKey(context), dueAt);
  }
  #assertRetentionWritable(context, sameRequest = true) {
    const dueAt = this.#retentionDeadline(context);
    if (dueAt === null) return;
    if (context.kind === "avatar") throw new PublicRecordError("PUBLIC_ERASED");
    const row = this.#retention(context);
    if (row?.state === "fencing") throw new PublicRecordError("PUBLIC_PENDING");
    if (sameRequest && (row?.state === "fenced" || context.startedAt > this.#now() || dueAt <= this.#now())) throw new PublicRecordError("PUBLIC_ERASED");
  }
  async reserve({ accountID, kind, logicalID, requestID, payloadHash, expectedTag = null } = {}) {
    const identity = recordIdentity(accountID, kind, logicalID), now = this.#now();
    if (!publicUUID.test(requestID ?? "") || typeof payloadHash !== "string" || !/^[a-f0-9]{64}$/.test(payloadHash) ||
        expectedTag !== null && !validTag(expectedTag) || kind === "avatar" && expectedTag !== null ||
        kind === "avatarreport" && (expectedTag !== null || logicalID !== requestID)) throw new PublicRecordError("PUBLIC_INPUT");
    const result = this.#tx(() => {
      const generation = this.#active(accountID), previous = this.#row(identity.recordName);
      if (previous) {
        const old = this.#context(previous);
        if (["erasing", "erased"].includes(old.phase)) throw new PublicRecordError("PUBLIC_ERASED");
        this.#assertRetentionWritable(old, old.requestID === requestID);
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
          payload_hash,expected_tag,record_tag,generation,created_at,started_at,asset_claims) VALUES(?,?,?,?,'pending',?,?,NULL,NULL,?,?,?,0)`,
        identity.recordName, accountID, kind, identity.logicalKey, requestID, payloadHash, generation, now, now);
      }
      const context = this.#context(this.#row(identity.recordName));
      this.#enqueueRetention(context); return context;
    });
    await this.#durable(); return result;
  }
  #avatarReportCancellation(accountID, requestID, generation = this.#active(accountID)) {
    const identity = recordIdentity(accountID, "avatarreport", requestID), key = avatarReportCancellationKey(accountID, requestID);
    this.#active(accountID, generation);
    const row = this.#row(identity.recordName);
    if (!row || row.avatar_report_cancel_key === null) return null;
    if (row.account_id !== accountID || row.kind !== "avatarreport" || row.avatar_report_cancel_key !== key ||
        !["erasing", "erased"].includes(row.phase) || row.avatar_report_cancel_tag !== null &&
        (row.phase !== "erased" || !validTag(row.avatar_report_cancel_tag) || row.avatar_report_cancel_tag !== row.record_tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    if (row.phase === "erased" && !validTag(row.record_tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    return Object.freeze({ ...identity, requestID, generation, cancellationKey: key,
      cancellationTag: row.avatar_report_cancel_tag, recordTag: row.record_tag,
      state: row.avatar_report_cancel_tag === null ? "pending" : "settled",
      content: row.phase === "erased" ? null : this.#context(row) });
  }
  /** No arbitrary names. The row/count checkpoint permanently reserves the original own nonce. */
  async beginAvatarReportCancellation(accountID, requestID) {
    const identity = recordIdentity(accountID, "avatarreport", requestID), key = avatarReportCancellationKey(accountID, requestID), now = this.#now();
    const result = this.#tx(() => {
      const generation = this.#active(accountID), row = this.#row(identity.recordName);
      if (row) {
        if (row.account_id !== accountID || row.kind !== "avatarreport") throw new PublicRecordError("PUBLIC_SCOPE");
        const known = this.#avatarReportCancellation(accountID, requestID, generation);
        if (known) return known;
        if (row.phase === "erasing") throw new PublicRecordError("PUBLIC_SCOPE");
        if (row.phase === "erased") {
          if (!validTag(row.record_tag)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        } else {
          const current = this.#context(row);
          if (current.logicalKey !== identity.logicalKey || current.requestID !== requestID || current.expectedTag !== null) throw new PublicRecordError("PUBLIC_SCOPE");
          this.#storage.sql.exec("UPDATE public_records_v1 SET phase='erasing' WHERE record_name=?", identity.recordName);
        }
        this.#storage.sql.exec("UPDATE public_records_v1 SET avatar_report_cancel_key=?,avatar_report_cancel_tag=NULL WHERE record_name=?", key, identity.recordName);
      } else {
        const owned = this.#rows("SELECT value FROM public_record_counts_v1 WHERE scope=?", accountID)[0]?.value ?? 0;
        const total = this.#rows("SELECT value FROM public_record_counts_v1 WHERE scope='*'")[0]?.value;
        if (!Number.isSafeInteger(owned) || owned < 0 || !Number.isSafeInteger(total) || total < owned) throw new PublicRecordError();
        if (owned >= 1000 || total >= 10000) throw new PublicRecordError("PUBLIC_LIMIT");
        this.#storage.sql.exec("UPDATE public_record_counts_v1 SET value=value+1 WHERE scope='*'");
        this.#storage.sql.exec("INSERT INTO public_record_counts_v1(scope,value) VALUES(?,1) ON CONFLICT(scope) DO UPDATE SET value=value+1", accountID);
        this.#storage.sql.exec(`INSERT INTO public_records_v1(record_name,account_id,kind,logical_key,phase,request_id,payload_hash,
          expected_tag,record_tag,generation,created_at,started_at,asset_claims,avatar_report_cancel_key,avatar_report_cancel_tag)
          VALUES(?,?,?,?,'erasing',?,?,NULL,NULL,?,?,?,0,?,NULL)`, identity.recordName, accountID, "avatarreport", identity.logicalKey,
          requestID, key, generation, now, now, key);
      }
      const cancellation = this.#avatarReportCancellation(accountID, requestID, generation);
      if (cancellation.content) {
        const context = cancellation.content, dueAt = publicRetentionDeadline(context);
        if (context.createdAt > now) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        // Retention remains armed even if the caller disappears before its fence is confirmed.
        this.#storage.sql.exec(`INSERT INTO public_retention_v1(record_name,intent_key,due_at,state) VALUES(?,?,?,'pending')
          ON CONFLICT(record_name) DO UPDATE SET intent_key=excluded.intent_key,due_at=excluded.due_at,
          state='pending',lease_id=NULL,lease_at=NULL,fence_tag=NULL`, context.recordName, publicRetentionIntentKey(context), dueAt);
      }
      return cancellation;
    });
    await this.#durable(); return result;
  }
  avatarReportCancellation(accountID, requestID) { return this.#tx(() => this.#avatarReportCancellation(accountID, requestID)); }
  assertAvatarReportCancellation(lease) {
    return this.#tx(() => {
      const current = this.#avatarReportCancellation(lease?.accountID, lease?.requestID, lease?.generation);
      if (!current || current.recordName !== lease.recordName || current.cancellationKey !== lease.cancellationKey) throw new PublicRecordError("PUBLIC_SCOPE");
      return current;
    });
  }
  #completeAvatarReportCancellationRecord(name, tag) {
    this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='erased',logical_key=NULL,request_id=NULL,payload_hash=NULL,
      expected_tag=NULL,generation=0,created_at=0,started_at=0,asset_claims=NULL,record_tag=?,avatar_report_cancel_tag=? WHERE record_name=?`, tag, tag, name);
    this.#storage.sql.exec("DELETE FROM public_retention_v1 WHERE record_name=?", name);
  }
  async completeAvatarReportCancellation(lease, tag) {
    if (!validTag(tag)) throw new PublicRecordError("PUBLIC_RESPONSE");
    this.#tx(() => {
      const current = this.#avatarReportCancellation(lease?.accountID, lease?.requestID, lease?.generation);
      if (!current || current.cancellationKey !== lease.cancellationKey || current.recordName !== lease.recordName) throw new PublicRecordError("PUBLIC_SCOPE");
      this.#completeAvatarReportCancellationRecord(current.recordName, tag);
    });
    await this.#durable(); return this.assertAvatarReportCancellation(lease);
  }
  cancellationFenceForErasure(context) {
    return this.#tx(() => {
      const row = this.#row(context?.recordName);
      if (!row || row.avatar_report_cancel_key === null) return null;
      const current = this.#context(row);
      if (current.kind !== "avatarreport" || current.phase !== "erasing" || ["accountID", "requestID", "payloadHash", "startedAt"].some(key => current[key] !== context[key])) throw new PublicRecordError("PUBLIC_SCOPE");
      return avatarReportCancellationFields(current, row.avatar_report_cancel_key);
    });
  }
  #mutation(context) {
    const row = this.#context(this.#row(context?.recordName));
    if (row.accountID !== context.accountID || ["erasing", "erased"].includes(row.phase)) throw new PublicRecordError("PUBLIC_ERASED");
    this.#assertRetentionWritable(row);
    this.#active(row.accountID, context.generation);
    if (row.generation !== context.generation || row.requestID !== context.requestID || row.payloadHash !== context.payloadHash ||
        row.expectedTag !== context.expectedTag) throw new PublicRecordError("PUBLIC_CONFLICT");
    return row;
  }
  assertMutationCurrent(context) { return this.#tx(() => this.#mutation(context)); }
  /** One durable attempt per immutable version/variant, including unknown outcomes. No auto retry. */
  async claimAvatarTransfer(context, { variant, sha256, byteCount } = {}) {
    if (!["image", "thumbnail"].includes(variant) || typeof sha256 !== "string" || !/^[a-f0-9]{64}$/.test(sha256) ||
        !Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > (variant === "image" ? 256000 : 32000)) throw new PublicRecordError("PUBLIC_INPUT");
    const result = this.#tx(() => {
      const current = this.#mutation(context);
      if (current.kind !== "avatar" || current.phase !== "pending" || current.expectedTag !== null) throw new PublicRecordError("PUBLIC_SCOPE");
      const mask = this.#row(current.recordName).asset_claims, bit = variant === "image" ? 1 : 2;
      const exists = this.#rows("SELECT phase FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?", current.recordName, variant).length > 0;
      if (!Number.isInteger(mask) || mask < 0 || mask > 3 || Boolean(mask & bit) !== exists) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      if (exists) throw new PublicRecordError("PUBLIC_PENDING");
      const transferID = randomUUID();
      this.#storage.sql.exec("UPDATE public_records_v1 SET asset_claims=? WHERE record_name=?", mask | bit, current.recordName);
      this.#storage.sql.exec(`INSERT INTO avatar_asset_transfers_v1(record_name,variant,transfer_id,request_id,
        payload_hash,generation,content_sha256,byte_count,phase,receipt_hash,started_at) VALUES(?,?,?,?,?,?,?,?,'claimed',NULL,?)`,
      current.recordName, variant, transferID, current.requestID, current.payloadHash, current.generation, sha256, byteCount, this.#now());
      return Object.freeze({ context: current, variant, transferID, sha256, byteCount });
    });
    await this.#durable(); this.assertAvatarTransferCurrent(result); return result;
  }
  #assetTransfer(lease) {
    const current = this.#mutation(lease?.context);
    if (current.kind !== "avatar" || current.phase !== "pending" || current.expectedTag !== null ||
        !["image", "thumbnail"].includes(lease?.variant) || !publicUUID.test(lease?.transferID ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
    const row = this.#rows("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?", current.recordName, lease.variant)[0];
    if (!row || !["claimed", "acknowledged"].includes(row.phase) || row.transfer_id !== lease.transferID ||
        row.request_id !== current.requestID || row.payload_hash !== current.payloadHash || row.generation !== current.generation ||
        row.content_sha256 !== lease.sha256 || row.byte_count !== lease.byteCount ||
        !/^[a-f0-9]{64}$/.test(row.content_sha256 ?? "") || !Number.isSafeInteger(row.byte_count) || row.byte_count < 1 ||
        row.byte_count > (lease.variant === "image" ? 256000 : 32000) ||
        !Number.isSafeInteger(row.started_at) || row.started_at < current.createdAt ||
        (row.phase === "claimed" ? row.receipt_hash !== null || row.file_checksum_hash !== null :
          !/^[a-f0-9]{64}$/.test(row.receipt_hash ?? "") || !/^[a-f0-9]{64}$/.test(row.file_checksum_hash ?? ""))) throw new PublicRecordError("PUBLIC_SCOPE");
    return row;
  }
  assertAvatarTransferCurrent(lease) { this.#tx(() => this.#assetTransfer(lease)); }
  async acknowledgeAvatarTransfer(lease, receiptHash, fileChecksumHash, { envelope, expiresAt } = {}) {
    const now = this.#now();
    if ([receiptHash, fileChecksumHash].some(value => typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) ||
        typeof envelope !== "string" || envelope.length < 1 || envelope.length > 24000 ||
        !Number.isSafeInteger(expiresAt) || expiresAt <= now || expiresAt > now + 120000) throw new PublicRecordError("PUBLIC_INPUT");
    this.#tx(() => {
      const row = this.#assetTransfer(lease);
      if (row.phase === "acknowledged" && (row.receipt_hash !== receiptHash || row.file_checksum_hash !== fileChecksumHash)) throw new PublicRecordError("PUBLIC_CONFLICT");
      if (row.phase === "acknowledged") return;
      this.#storage.sql.exec(`UPDATE avatar_asset_transfers_v1 SET phase='acknowledged',receipt_hash=?,file_checksum_hash=?,
        receipt_envelope=?,receipt_expires_at=? WHERE record_name=? AND variant=?`, receiptHash, fileChecksumHash, envelope, expiresAt, row.record_name, row.variant);
    });
    await this.#durable(); this.assertAvatarTransferCurrent(lease);
  }
  /** Metadata only. Both completed attempts are required; a new login may reconcile the SAME version.
   * No raw provider receipt/checksum or photo bytes are retained in SQLite.
   */
  avatarTransferStatus(context, variant) {
    return this.#tx(() => {
      const current = this.#mutation(context);
      if (current.kind !== "avatar" || current.expectedTag !== null || !["pending", "settled"].includes(current.phase) ||
          !["image", "thumbnail"].includes(variant)) throw new PublicRecordError("PUBLIC_SCOPE");
      const row = this.#rows("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?", current.recordName, variant)[0];
      const mask = this.#row(current.recordName).asset_claims;
      if (!Number.isInteger(mask) || mask < 0 || mask > 3 || Boolean(mask & (variant === "image" ? 1 : 2)) !== Boolean(row)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      if (!row) return null;
      if (!["claimed", "acknowledged"].includes(row.phase) || row.request_id !== current.requestID || row.payload_hash !== current.payloadHash ||
          !publicUUID.test(row.transfer_id ?? "") || !Number.isSafeInteger(row.generation) || row.generation < 0 || row.generation > current.generation ||
          !Number.isSafeInteger(row.started_at) || row.started_at < current.createdAt || row.started_at > this.#now() ||
          !/^[a-f0-9]{64}$/.test(row.content_sha256 ?? "") ||
          !Number.isSafeInteger(row.byte_count) || row.byte_count < 1 || row.byte_count > (variant === "image" ? 256000 : 32000) ||
          (row.phase === "claimed" ? row.receipt_hash !== null || row.file_checksum_hash !== null || row.receipt_envelope !== null || row.receipt_expires_at !== null :
            [row.receipt_hash, row.file_checksum_hash].some(value => typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)))) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      return Object.freeze({ phase: row.phase, sha256: row.content_sha256, byteCount: row.byte_count, fileChecksumHash: row.file_checksum_hash });
    });
  }
  avatarAssetCommitments(context) {
    const result = {};
    for (const variant of ["image", "thumbnail"]) {
      const value = this.avatarTransferStatus(context, variant);
      if (value?.phase !== "acknowledged") throw new PublicRecordError("PUBLIC_PENDING");
      result[variant] = value;
    }
    return Object.freeze(result);
  }
  /** Read-only access to a settled immutable avatar. Logout/reset must not erase its publication;
   * no mutation lease is renewed on behalf of the author by a reader.
   */
  readAvatarAssetCommitments(context) {
    return this.#tx(() => {
      const current = this.#context(this.#row(context?.recordName)), generation = this.#active(current.accountID);
      if (current.kind !== "avatar" || current.phase !== "settled" ||
          ["accountID", "requestID", "payloadHash", "recordTag"].some(key => current[key] !== context[key]) ||
          this.#row(current.recordName).asset_claims !== 3) throw new PublicRecordError("PUBLIC_SCOPE");
      const result = {};
      for (const variant of ["image", "thumbnail"]) {
        const row = this.#rows("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?", current.recordName, variant)[0];
        if (!row || row.phase !== "acknowledged" || row.request_id !== current.requestID || row.payload_hash !== current.payloadHash ||
            !publicUUID.test(row.transfer_id ?? "") || !Number.isSafeInteger(row.generation) || row.generation < 0 || row.generation > generation ||
            !Number.isSafeInteger(row.started_at) || row.started_at < current.createdAt || row.started_at > this.#now() ||
            [row.content_sha256, row.receipt_hash, row.file_checksum_hash].some(value => typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) ||
            !Number.isSafeInteger(row.byte_count) || row.byte_count < 1 || row.byte_count > (variant === "image" ? 256000 : 32000)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        result[variant] = Object.freeze({ sha256: row.content_sha256, byteCount: row.byte_count, fileChecksumHash: row.file_checksum_hash });
      }
      return Object.freeze(result);
    });
  }
  avatarReceipt(context, variant) {
    const commitment = this.avatarTransferStatus(context, variant);
    if (commitment?.phase !== "acknowledged") throw new PublicRecordError("PUBLIC_PENDING");
    return this.#tx(() => {
      const current = this.#mutation(context), now = this.#now();
      if (current.phase !== "pending" || !["image", "thumbnail"].includes(variant)) throw new PublicRecordError("PUBLIC_SCOPE");
      const row = this.#rows("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?", current.recordName, variant)[0];
      if (typeof row.receipt_envelope !== "string" || row.receipt_envelope.length < 1 || row.receipt_envelope.length > 24000 ||
          !Number.isSafeInteger(row.receipt_expires_at) || row.receipt_expires_at <= now || row.started_at > now ||
          row.receipt_expires_at > row.started_at + 128000) throw new PublicRecordError("PUBLIC_PENDING");
      return Object.freeze({ lease: Object.freeze({ context: current, variant, transferID: row.transfer_id,
        sha256: commitment.sha256, byteCount: commitment.byteCount }), envelope: row.receipt_envelope,
      receiptHash: row.receipt_hash, fileChecksumHash: row.file_checksum_hash, expiresAt: row.receipt_expires_at });
    });
  }
  /** Bounded secret cleanup only; never releases consumed attempts or changes upload identity. */
  async expireAvatarReceipts(maximumRecords = 100) {
    if (!Number.isInteger(maximumRecords) || maximumRecords < 1 || maximumRecords > 100) throw new PublicRecordError("PUBLIC_INPUT");
    const count = this.#tx(() => expireAvatarTransferReceipts(this.#storage, this.#now(), maximumRecords));
    await this.#durable(); return count;
  }
  /** A settled row is necessary for declassification. Unknown or incomplete content stays hidden. */
  readable(name, kind) {
    return this.#tx(() => this.#readable(name, kind));
  }
  #readable(name, kind) {
    const row = this.#row(name);
    if (!row || row.kind !== kind || row.phase !== "settled") return null;
    const context = this.#context(row);
    const dueAt = this.#retentionDeadline(context), retention = this.#retention(context);
    if (context.kind === "avatar" && dueAt !== null) return null;
    if (dueAt !== null && (context.startedAt > this.#now() || dueAt <= this.#now() || retention && retention.state !== "pending")) return null;
    if (!this.#rows("SELECT account_id FROM auth_accounts_v1 WHERE account_id=? AND disabled=0", row.account_id).length) return null;
    return context;
  }
  /** Trusted moderation metadata only. No report contents, provider query, or user-facing route. */
  reviewReportPage(after = null) {
    if (after !== null && (typeof after !== "string" || !/^community-v1-report-[a-f0-9]{64}$/.test(after))) throw new PublicRecordError("PUBLIC_INPUT");
    return this.#tx(() => {
      const now = this.#now(), rows = this.#rows(`SELECT p.record_name FROM public_records_v1 p
        JOIN auth_accounts_v1 a ON a.account_id=p.account_id AND a.disabled=0
        WHERE p.kind='report' AND p.phase='settled' AND p.record_name>? AND p.started_at<=? AND p.started_at>?
        ORDER BY p.record_name LIMIT 21`, after ?? "", now, now - 2592000000);
      const scanned = rows.slice(0, 20), items = scanned.map(row => this.#readable(row.record_name, "report")).filter(Boolean);
      return Object.freeze({ items: Object.freeze(items), after: rows.length > 20 ? scanned.at(-1).record_name : null });
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
    if (!["presence", "block", "avatarprofile"].includes(value?.kind)) throw new PublicRecordError("PUBLIC_INPUT");
    const identity = recordIdentity(value.accountID, value.kind, value.logicalID);
    const old = this.#tx(() => {
      this.#active(value.accountID);
      const row = this.#row(identity.recordName);
      if (!row) return null;
      const context = this.#context(row);
      if (["erasing", "erased"].includes(context.phase)) throw new PublicRecordError("PUBLIC_ERASED");
      this.#assertRetentionWritable(context, context.requestID === value.requestID);
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
      this.#assertRetentionWritable(current, current.requestID === value.requestID);
      this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='pending',request_id=?,payload_hash=?,expected_tag=?,
        generation=?,started_at=? WHERE record_name=?`, value.requestID, value.payloadHash, value.expectedTag,
      this.#active(value.accountID), old.requestID === value.requestID ? old.startedAt : this.#now(), identity.recordName);
      const context = this.#context(this.#row(identity.recordName));
      this.#enqueueRetention(context); return context;
    });
    await this.#durable(); return result;
  }
  async settle(context, recordTag) {
    if (!validTag(recordTag)) throw new PublicRecordError("PUBLIC_RESPONSE");
    this.#tx(() => {
      const row = this.#mutation(context);
      if (row.phase === "settled" && row.recordTag !== recordTag) throw new PublicRecordError("PUBLIC_CONFLICT");
      this.#storage.sql.exec("UPDATE public_records_v1 SET phase='settled',record_tag=? WHERE record_name=?", recordTag, row.recordName);
      if (row.kind === "avatar") this.#storage.sql.exec("UPDATE avatar_asset_transfers_v1 SET receipt_envelope=NULL WHERE record_name=?", row.recordName);
    });
    await this.#durable();
    return this.assertMutationCurrent(context);
  }
  /** Bounded migration from the trusted registry, including attempts with unknown provider outcomes. */
  async backfillRetention(maximumRecords = 100) {
    if (!Number.isInteger(maximumRecords) || maximumRecords < 1 || maximumRecords > 100) throw new PublicRecordError("PUBLIC_INPUT");
    const count = this.#tx(() => {
      backfillAvatarRetirements(this.#storage, this.#now(), maximumRecords);
      const rows = this.#rows(`SELECT p.* FROM public_records_v1 p LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name
        WHERE p.kind IN ('presence','message','report','avatarreport') AND (p.phase IN ('pending','settled') OR (p.kind='avatarreport' AND p.phase='erasing' AND p.avatar_report_cancel_key IS NOT NULL AND p.avatar_report_cancel_tag IS NULL)) AND r.record_name IS NULL
        ORDER BY p.record_name LIMIT ?`, maximumRecords);
      if (rows.length < maximumRecords) rows.push(...this.#rows(`SELECT p.* FROM public_records_v1 p
        JOIN avatar_retirements_v1 a ON a.record_name=p.record_name LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name
        WHERE p.kind='avatar' AND p.phase IN ('pending','settled') AND r.record_name IS NULL
        ORDER BY p.record_name LIMIT ?`, maximumRecords - rows.length));
      for (const row of rows) {
        const context = this.#context(row);
        this.#storage.sql.exec("INSERT INTO public_retention_v1(record_name,intent_key,due_at,state) VALUES(?,?,?,'pending')",
          context.recordName, publicRetentionIntentKey(context), this.#retentionDeadline(context));
      }
      return rows.length;
    });
    await this.#durable(); return count;
  }
  retentionSchedule() {
    return this.#tx(() => {
      const row = this.#rows(`SELECT MIN(CASE WHEN r.state='fencing' THEN MAX(r.due_at,r.lease_at+?) ELSE r.due_at END) AS due_at
        FROM public_retention_v1 r JOIN public_records_v1 p ON p.record_name=r.record_name JOIN auth_accounts_v1 a ON a.account_id=p.account_id
        WHERE a.disabled=0 AND (p.phase IN ('pending','settled') OR (p.kind='avatarreport' AND p.phase='erasing' AND p.avatar_report_cancel_key IS NOT NULL AND p.avatar_report_cancel_tag IS NULL)) AND r.state IN ('pending','fencing')`, publicRetentionLeaseMilliseconds)[0];
      const dueAt = row?.due_at ?? null, wakeAt = avatarSelectionExpirySchedule(this.#storage, this.#now());
      if (dueAt !== null && (!Number.isSafeInteger(dueAt) || dueAt < 0)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      const legacy = this.#rows(`SELECT 1 FROM public_records_v1 p JOIN auth_accounts_v1 a ON a.account_id=p.account_id
        LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name WHERE a.disabled=0
        AND (p.phase IN ('pending','settled') OR (p.kind='avatarreport' AND p.phase='erasing' AND p.avatar_report_cancel_key IS NOT NULL AND p.avatar_report_cancel_tag IS NULL)) AND p.kind IN ('presence','message','report','avatarreport') AND r.record_name IS NULL LIMIT 1`).length > 0;
      return Object.freeze({ dueAt, wakeAt, needsBackfill: legacy || needsAvatarRetirementBackfill(this.#storage) || wakeAt !== null && wakeAt <= this.#now() });
    });
  }
  /** Fair, durable leases. No CloudKit permission or HTTP route is granted by this local API. */
  async claimExpiredRecords(maximumRecords = 25) {
    if (!Number.isInteger(maximumRecords) || maximumRecords < 1 || maximumRecords > 25) throw new PublicRecordError("PUBLIC_INPUT");
    await this.backfillRetention();
    const leases = this.#tx(() => {
      const now = this.#now();
      if (!Number.isSafeInteger(now + publicRetentionLeaseMilliseconds)) throw new PublicRecordError();
      const cursor = this.#rows("SELECT record_name FROM public_retention_cursor_v1 WHERE singleton=1")[0]?.record_name;
      if (typeof cursor !== "string" || cursor !== "" && !publicRecordName.test(cursor)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      const select = after => this.#rows(`SELECT p.* FROM public_records_v1 p JOIN public_retention_v1 r ON r.record_name=p.record_name
        JOIN auth_accounts_v1 a ON a.account_id=p.account_id WHERE a.disabled=0 AND (p.phase IN ('pending','settled') OR (p.kind='avatarreport' AND p.phase='erasing' AND p.avatar_report_cancel_key IS NOT NULL AND p.avatar_report_cancel_tag IS NULL))
        AND r.due_at<=? AND (r.state='pending' OR (r.state='fencing' AND r.lease_at+?<=?))
        AND p.record_name>? ORDER BY p.record_name LIMIT ?`, now, publicRetentionLeaseMilliseconds, now, after, maximumRecords);
      let rows = select(cursor);
      if (!rows.length && cursor !== "") rows = select("");
      const result = rows.map(row => {
        const context = this.#context(row), retention = this.#retention(context);
        if (!retention || context.startedAt > now || this.#retentionDeadline(context) > now) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
        const leaseID = randomUUID();
        this.#storage.sql.exec("UPDATE public_retention_v1 SET state='fencing',lease_id=?,lease_at=?,fence_tag=NULL WHERE record_name=?", leaseID, now, context.recordName);
        return Object.freeze({ context, leaseID, leasedAt: now, expiresAt: now + publicRetentionLeaseMilliseconds,
          ...(row.phase === "erasing" ? { cancellationKey: row.avatar_report_cancel_key } : {}) });
      });
      if (rows.length) this.#storage.sql.exec("UPDATE public_retention_cursor_v1 SET record_name=? WHERE singleton=1", rows.at(-1).record_name);
      return Object.freeze(result);
    });
    await this.#durable();
    for (const lease of leases) this.assertRetentionCurrent(lease);
    return leases;
  }
  #retentionLease(lease) {
    if (!publicRecordName.test(lease?.context?.recordName ?? "") || !publicUUID.test(lease?.leaseID ?? "")) throw new PublicRecordError("PUBLIC_SCOPE");
    const row = this.#row(lease.context.recordName), context = this.#context(row), retention = this.#retention(context), now = this.#now();
    const cancellation = row.kind === "avatarreport" && row.phase === "erasing" && /^[a-f0-9]{64}$/.test(row.avatar_report_cancel_key ?? "") && row.avatar_report_cancel_tag === null;
    this.#active(context.accountID);
    if ((!["pending", "settled"].includes(context.phase) && !cancellation) ||
        (cancellation ? lease.cancellationKey !== row.avatar_report_cancel_key : lease.cancellationKey !== undefined) || !retention || retention.state !== "fencing" ||
        retention.intent_key !== publicRetentionIntentKey(lease.context) || retention.lease_id !== lease.leaseID ||
        retention.lease_at !== lease.leasedAt || lease.expiresAt !== retention.lease_at + publicRetentionLeaseMilliseconds ||
        now < retention.lease_at || now >= lease.expiresAt || retention.due_at > now) throw new PublicRecordError("PUBLIC_SCOPE");
    return context;
  }
  assertRetentionCurrent(lease) { return this.#tx(() => this.#retentionLease(lease)); }
  isConfirmedRetentionFence(context, tag) {
    return this.#tx(() => {
      const current = this.#context(this.#row(context?.recordName));
      this.#active(current.accountID);
      const retention = this.#retention(current);
      return current.kind === "presence" && retention?.state === "fenced" &&
        retention.intent_key === publicRetentionIntentKey(context) && retention.fence_tag === tag;
    });
  }
  /** Caller must first verify exact content-free CloudKit fields and change tag. */
  async completeRetention(lease, recordTag) {
    if (!validTag(recordTag)) throw new PublicRecordError("PUBLIC_RESPONSE");
    this.#tx(() => {
      const context = this.#retentionLease(lease);
      if (context.kind === "presence") {
        // Keep the singleton reusable, but only a fresh intent can replace its confirmed fence.
        this.#storage.sql.exec("UPDATE public_records_v1 SET phase='settled',record_tag=? WHERE record_name=?", recordTag, context.recordName);
        this.#storage.sql.exec("UPDATE public_retention_v1 SET state='fenced',lease_id=NULL,lease_at=NULL,fence_tag=? WHERE record_name=?", recordTag, context.recordName);
      } else if (context.kind === "avatarreport" && lease.cancellationKey !== undefined) {
        this.#completeAvatarReportCancellationRecord(context.recordName, recordTag);
      } else {
        if (context.kind === "avatar") {
          this.#storage.sql.exec("DELETE FROM avatar_asset_transfers_v1 WHERE record_name=?", context.recordName);
          this.#storage.sql.exec("DELETE FROM avatar_review_receipts_v1 WHERE account_id=? AND request_id=?", context.accountID, context.requestID);
          this.#storage.sql.exec("DELETE FROM avatar_jobs_v1 WHERE account_id=? AND request_id=?", context.accountID, context.requestID);
          this.#storage.sql.exec("DELETE FROM avatar_retirements_v1 WHERE record_name=?", context.recordName);
        }
        this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='erased',logical_key=NULL,request_id=NULL,payload_hash=NULL,
          expected_tag=NULL,generation=0,created_at=0,started_at=0,asset_claims=NULL,avatar_report_cancel_key=NULL,avatar_report_cancel_tag=NULL,record_tag=? WHERE record_name=?`, recordTag, context.recordName);
        this.#storage.sql.exec("DELETE FROM public_retention_v1 WHERE record_name=?", context.recordName);
      }
    });
    await this.#durable();
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
      this.#storage.sql.exec("UPDATE public_records_v1 SET avatar_report_cancel_key=NULL,avatar_report_cancel_tag=NULL WHERE record_name IN (SELECT record_name FROM public_records_v1 WHERE account_id=? AND phase='erased' AND (avatar_report_cancel_key IS NOT NULL OR avatar_report_cancel_tag IS NOT NULL) ORDER BY record_name LIMIT 25)", context.accountID);
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
  retentionDeadlineForErasure(context) {
    return this.#tx(() => {
      const current = this.#context(this.#row(context?.recordName));
      if (current.phase !== "erasing" || context.phase !== "erasing" ||
          ["accountID", "kind", "requestID", "payloadHash", "createdAt", "startedAt"].some(key => current[key] !== context[key])) throw new PublicRecordError("PUBLIC_SCOPE");
      return this.#retentionDeadline(current);
    });
  }
  async completeErasure(context, records) {
    if (!(records instanceof Map) || records.size > 25) throw new PublicRecordError("PUBLIC_INPUT");
    this.#tx(() => {
      this.#deletion(context);
      for (const [name, tag] of records) {
        const row = this.#context(this.#row(name));
        if (row.accountID !== context.accountID || row.phase !== "erasing" || !validTag(tag)) throw new PublicRecordError("PUBLIC_SCOPE");
        if (row.kind === "avatar") this.#storage.sql.exec(`UPDATE avatar_asset_transfers_v1 SET phase='erased',
          transfer_id=NULL,request_id=NULL,payload_hash=NULL,generation=NULL,content_sha256=NULL,byte_count=NULL,
          receipt_hash=NULL,file_checksum_hash=NULL,receipt_envelope=NULL,receipt_expires_at=NULL,started_at=0 WHERE record_name=?`, name);
        this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='erased',logical_key=NULL,request_id=NULL,payload_hash=NULL,
          expected_tag=NULL,generation=0,created_at=0,started_at=0,asset_claims=NULL,avatar_report_cancel_key=NULL,avatar_report_cancel_tag=NULL,record_tag=? WHERE record_name=?`, tag, name);
        this.#storage.sql.exec("DELETE FROM public_retention_v1 WHERE record_name=?", name);
        this.#storage.sql.exec("DELETE FROM avatar_retirements_v1 WHERE record_name=?", name);
      }
    });
    await this.#durable();
    return this.#tx(() => {
      this.#deletion(context);
      const remaining = this.#rows("SELECT record_name FROM public_records_v1 WHERE account_id=? AND (phase!='erased' OR avatar_report_cancel_key IS NOT NULL OR avatar_report_cancel_tag IS NOT NULL) LIMIT 1", context.accountID).length > 0;
      return Object.freeze({ accountID: context.accountID, deletionID: context.deletionID, remaining });
    });
  }
}
