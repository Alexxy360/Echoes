import { PublicRecordError, publicUUID, recordIdentity, recordIdentityFromKey, validTag } from "./public-record-schema.mjs";
import { randomUUID } from "node:crypto";
import { validCheckpoint, sameCheckpoint } from "./public-registry-checkpoint.mjs";

const schema = [
  `CREATE TABLE IF NOT EXISTS public_records_v1 (
    record_name TEXT PRIMARY KEY,account_id TEXT NOT NULL,kind TEXT NOT NULL,logical_key TEXT,
    phase TEXT NOT NULL CHECK(phase IN ('pending','settled','erasing','erased')),
    request_id TEXT,payload_hash TEXT,expected_tag TEXT,record_tag TEXT,generation INTEGER NOT NULL,
    created_at INTEGER NOT NULL,started_at INTEGER NOT NULL,asset_claims INTEGER CHECK(asset_claims IS NULL OR asset_claims IN (0,1,2,3)),
    UNIQUE(account_id,kind,logical_key))`,
  `CREATE INDEX IF NOT EXISTS public_record_owner_v1 ON public_records_v1(account_id,phase,record_name)`,
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
      for (const statement of schema) storage.sql.exec(statement);
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
  async reserve({ accountID, kind, logicalID, requestID, payloadHash, expectedTag = null } = {}) {
    const identity = recordIdentity(accountID, kind, logicalID), now = this.#now();
    if (!publicUUID.test(requestID ?? "") || typeof payloadHash !== "string" || !/^[a-f0-9]{64}$/.test(payloadHash) ||
        expectedTag !== null && !validTag(expectedTag) || kind === "avatar" && expectedTag !== null) throw new PublicRecordError("PUBLIC_INPUT");
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
          payload_hash,expected_tag,record_tag,generation,created_at,started_at,asset_claims) VALUES(?,?,?,?,'pending',?,?,NULL,NULL,?,?,?,0)`,
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
    const count = this.#tx(() => {
      const rows = this.#rows(`SELECT record_name,variant FROM avatar_asset_transfers_v1
        WHERE receipt_envelope IS NOT NULL AND receipt_expires_at<=? ORDER BY receipt_expires_at LIMIT ?`, this.#now(), maximumRecords);
      for (const row of rows) this.#storage.sql.exec("UPDATE avatar_asset_transfers_v1 SET receipt_envelope=NULL WHERE record_name=? AND variant=?", row.record_name, row.variant);
      return rows.length;
    });
    await this.#durable(); return count;
  }
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
    if (!["presence", "block", "avatarprofile"].includes(value?.kind)) throw new PublicRecordError("PUBLIC_INPUT");
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
      if (row.kind === "avatar") this.#storage.sql.exec("UPDATE avatar_asset_transfers_v1 SET receipt_envelope=NULL WHERE record_name=?", row.recordName);
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
        if (row.kind === "avatar") this.#storage.sql.exec(`UPDATE avatar_asset_transfers_v1 SET phase='erased',
          transfer_id=NULL,request_id=NULL,payload_hash=NULL,generation=NULL,content_sha256=NULL,byte_count=NULL,
          receipt_hash=NULL,file_checksum_hash=NULL,receipt_envelope=NULL,receipt_expires_at=NULL,started_at=0 WHERE record_name=?`, name);
        this.#storage.sql.exec(`UPDATE public_records_v1 SET phase='erased',logical_key=NULL,request_id=NULL,payload_hash=NULL,
          expected_tag=NULL,generation=0,created_at=0,started_at=0,asset_claims=NULL,record_tag=? WHERE record_name=?`, tag, name);
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
