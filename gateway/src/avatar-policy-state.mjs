import { AvatarReviewRetirementError, avatarReviewRetirementSchema, readAvatarReviewRetirement, createAvatarReviewRetirement, eraseAvatarReviewRetirements } from "./avatar-review-decision-retirements.mjs";
import { randomUUID } from "node:crypto";
import { plain, publicUUID, digest, inputHash, validTag, recordIdentity } from "./public-record-schema.mjs";
import { avatarDescriptor, avatarDescriptorHash } from "./avatar-record-schema.mjs";
import { avatarReviewSchema, avatarReviewerKey } from "./avatar-review-state.mjs";
import { markAvatarRetired } from "./avatar-retirement-state.mjs";
import { avatarSelectionDeadline, avatarSelectionLifetimeMilliseconds, migrateAvatarSelectionExpiry, expireAvatarSelection } from "./avatar-selection-expiry.mjs";

const codes = new Set(["AVATAR_INPUT", "AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED", "AVATAR_RATE", "AVATAR_CAPACITY", "AVATAR_SCOPE", "AVATAR_UNAVAILABLE"]);
export class AvatarPolicyError extends Error {
  constructor(code = "AVATAR_UNAVAILABLE") { super("Profile photo operation could not be completed."); this.code = codes.has(code) ? code : "AVATAR_UNAVAILABLE"; }
}
const uuid = value => { if (typeof value !== "string" || !publicUUID.test(value)) throw new AvatarPolicyError("AVATAR_INPUT"); return value; };
export const avatarPolicySchema = Object.freeze([
  ...avatarReviewSchema,
  ...avatarReviewRetirementSchema,
  `CREATE TABLE IF NOT EXISTS avatar_profiles_v1(account_id TEXT PRIMARY KEY,generation INTEGER NOT NULL DEFAULT 0,
    request_id TEXT,version_id TEXT,ready INTEGER NOT NULL DEFAULT 0,pointer_tag TEXT,
    upload_window INTEGER,upload_count INTEGER NOT NULL DEFAULT 0,updated_at INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS avatar_jobs_v1(account_id TEXT NOT NULL,request_id TEXT NOT NULL,version_id TEXT NOT NULL,
    generation INTEGER NOT NULL,source_hash TEXT NOT NULL,consent_version INTEGER NOT NULL,
    descriptor_json TEXT,staged_tag TEXT,moderation_state TEXT NOT NULL CHECK(moderation_state IN ('pending','approved','rejected')),
    moderation_revision TEXT NOT NULL,decision_id TEXT,decision_expected_revision TEXT,reviewer_key TEXT,
    created_at INTEGER NOT NULL,reviewed_at INTEGER,PRIMARY KEY(account_id,request_id),UNIQUE(account_id,version_id))`,
  `CREATE INDEX IF NOT EXISTS avatar_review_queue_v1 ON avatar_jobs_v1(moderation_state,created_at,account_id,request_id)`,
]);
/** Called inside the same disabled-owner transaction as the other community policy tables. */
export function eraseAvatarPolicy(storage, accountID) {
  eraseAvatarReviewRetirements(storage, accountID);
  storage.sql.exec("DELETE FROM avatar_review_receipts_v1 WHERE account_id=? OR reviewer_key=?", accountID, avatarReviewerKey(accountID));
  storage.sql.exec("DELETE FROM avatar_jobs_v1 WHERE account_id=?", accountID);
  storage.sql.exec("DELETE FROM avatar_profiles_v1 WHERE account_id=?", accountID);
}
/** Consent and photo visibility metadata only. No pixels, provider receipts, URLs or public names. */
export class AvatarPolicyState {
  #storage; #registry; #clock;
  constructor(storage, { registry, clock = Date.now } = {}) {
    if (typeof storage?.transactionSync !== "function" || typeof storage.sync !== "function" || typeof storage.sql?.exec !== "function" ||
        typeof registry?.owned !== "function" || typeof registry.readable !== "function" || typeof clock !== "function") throw new AvatarPolicyError();
    this.#storage = storage; this.#registry = registry; this.#clock = clock;
    this.#tx(() => {
      if (!this.#rows("SELECT name FROM sqlite_master WHERE type='table' AND name='community_accounts_v1'").length) throw new AvatarPolicyError();
      for (const sql of avatarPolicySchema) storage.sql.exec(sql);
      migrateAvatarSelectionExpiry(storage);
    });
  }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (e) { if (e instanceof AvatarReviewRetirementError) throw new AvatarPolicyError(e.code === "CONFLICT" ? "AVATAR_STALE" : e.code === "CAPACITY" ? "AVATAR_CAPACITY" : undefined); throw e instanceof AvatarPolicyError ? e : new AvatarPolicyError(); } }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  async #durable() { try { await this.#storage.sync(); } catch { throw new AvatarPolicyError(); } }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new AvatarPolicyError(); return now; }
  #active(accountID) {
    uuid(accountID);
    const row = this.#rows(`SELECT a.disabled,c.suspended FROM auth_accounts_v1 a LEFT JOIN community_accounts_v1 c
      ON c.account_id=a.account_id WHERE a.account_id=?`, accountID)[0];
    if (!row || row.disabled || row.suspended) throw new AvatarPolicyError("AVATAR_STALE");
  }
  #profile(accountID) { return this.#rows("SELECT * FROM avatar_profiles_v1 WHERE account_id=?", accountID)[0]; }
  #job(accountID, requestID) { return this.#rows("SELECT * FROM avatar_jobs_v1 WHERE account_id=? AND request_id=?", accountID, requestID)[0]; }
  #lease(accountID) {
    const row = this.#profile(accountID);
    if (!row || !Number.isSafeInteger(row.generation) || row.generation < 1 || !publicUUID.test(row.request_id ?? "")) throw new AvatarPolicyError("AVATAR_STALE");
    const deadline = avatarSelectionDeadline(row, row.version_id === null ? undefined : this.#job(accountID, row.request_id), this.#now());
    if (deadline !== null && deadline <= this.#now()) throw new AvatarPolicyError("AVATAR_STALE");
    return Object.freeze({ accountID, requestID: row.request_id, generation: row.generation, versionID: row.version_id,
      kind: row.version_id === null ? "clear" : "select" });
  }
  #current(intent) {
    if (!plain(intent)) throw new AvatarPolicyError("AVATAR_INPUT");
    this.#active(intent.accountID);
    const current = this.#lease(intent.accountID);
    if (["requestID", "generation", "versionID", "kind"].some(key => current[key] !== intent[key])) throw new AvatarPolicyError("AVATAR_STALE");
    if (current.kind === "select") {
      const job = this.#job(current.accountID, current.requestID);
      if (!job || job.generation !== current.generation || job.version_id !== current.versionID || job.consent_version !== 1) throw new AvatarPolicyError("AVATAR_STALE");
    }
    return current;
  }
  assertCurrent(intent) { return this.#tx(() => this.#current(intent)); }
  intent(accountID, requestID) { uuid(requestID); return this.#tx(() => { this.#active(accountID); const value = this.#lease(accountID); if (value.requestID !== requestID) throw new AvatarPolicyError("AVATAR_STALE"); return value; }); }
  async select({ accountID, requestID, versionID, expectedGeneration, sourceHash, consentVersion } = {}) {
    uuid(requestID); uuid(versionID);
    if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 0 || expectedGeneration >= Number.MAX_SAFE_INTEGER ||
        typeof sourceHash !== "string" || !/^[a-f0-9]{64}$/.test(sourceHash) || consentVersion !== 1) throw new AvatarPolicyError("AVATAR_INPUT");
    const result = this.#tx(() => {
      this.#active(accountID); const now = this.#now(), profile = this.#profile(accountID), old = this.#job(accountID, requestID);
      if (old) {
        if (old.version_id !== versionID || old.source_hash !== sourceHash || old.generation !== expectedGeneration + 1) throw new AvatarPolicyError("AVATAR_STALE");
        return this.#current({ accountID, requestID, versionID, generation: old.generation, kind: "select" });
      }
      if ((profile?.generation ?? 0) !== expectedGeneration || profile?.request_id === requestID ||
          this.#rows("SELECT request_id FROM avatar_jobs_v1 WHERE account_id=? AND version_id=?", accountID, versionID).length) throw new AvatarPolicyError("AVATAR_STALE");
      if (this.#rows("SELECT request_id FROM avatar_jobs_v1 WHERE account_id=? LIMIT 1000", accountID).length >= 1000) throw new AvatarPolicyError("AVATAR_CAPACITY");
      const window = Math.floor(now / 600000) * 600000, count = profile?.upload_window === window ? profile.upload_count : 0;
      if (profile?.updated_at > now) throw new AvatarPolicyError();
      if (count >= 3) throw new AvatarPolicyError("AVATAR_RATE");
      const deadline = avatarSelectionDeadline(profile, profile?.version_id ? this.#job(accountID, profile.request_id) : undefined, now);
      markAvatarRetired(this.#storage, profile, deadline !== null && deadline <= now ? deadline : now);
      this.#storage.sql.exec(`INSERT INTO avatar_profiles_v1(account_id,generation,request_id,version_id,ready,pointer_tag,upload_window,upload_count,updated_at)
        VALUES(?,?,?,?,0,NULL,?,?,?) ON CONFLICT(account_id) DO UPDATE SET generation=excluded.generation,request_id=excluded.request_id,
        version_id=excluded.version_id,ready=0,pointer_tag=NULL,expired_at=NULL,expired_review_revision=NULL,upload_window=excluded.upload_window,upload_count=excluded.upload_count,updated_at=excluded.updated_at`,
      accountID, expectedGeneration + 1, requestID, versionID, window, count + 1, now);
      this.#storage.sql.exec(`INSERT INTO avatar_jobs_v1(account_id,request_id,version_id,generation,source_hash,consent_version,
        moderation_state,moderation_revision,created_at) VALUES(?,?,?,?,?,1,'pending',?,?)`, accountID, requestID, versionID, expectedGeneration + 1, sourceHash, randomUUID(), now);
      return this.#lease(accountID);
    });
    await this.#durable(); this.assertCurrent(result); return result;
  }
  async clear({ accountID, requestID, expectedGeneration } = {}) {
    uuid(requestID);
    if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 0 || expectedGeneration >= Number.MAX_SAFE_INTEGER) throw new AvatarPolicyError("AVATAR_INPUT");
    const result = this.#tx(() => {
      this.#active(accountID); const profile = this.#profile(accountID), now = this.#now();
      if (profile?.request_id === requestID && profile.version_id === null && profile.generation === expectedGeneration + 1) return this.#lease(accountID);
      if ((profile?.generation ?? 0) !== expectedGeneration || profile?.request_id === requestID || this.#job(accountID, requestID)) throw new AvatarPolicyError("AVATAR_STALE");
      if (profile?.updated_at > now) throw new AvatarPolicyError();
      const deadline = avatarSelectionDeadline(profile, profile?.version_id ? this.#job(accountID, profile.request_id) : undefined, now);
      markAvatarRetired(this.#storage, profile, deadline !== null && deadline <= now ? deadline : now);
      // Clear has no upload rate/capacity gate and never resets the selection budget.
      this.#storage.sql.exec(`INSERT INTO avatar_profiles_v1(account_id,generation,request_id,version_id,ready,pointer_tag,updated_at)
        VALUES(?,?,?,NULL,0,NULL,?) ON CONFLICT(account_id) DO UPDATE SET generation=excluded.generation,request_id=excluded.request_id,
        version_id=NULL,ready=0,pointer_tag=NULL,expired_at=NULL,expired_review_revision=NULL,updated_at=excluded.updated_at`, accountID, expectedGeneration + 1, requestID, now);
      return this.#lease(accountID);
    });
    await this.#durable(); this.assertCurrent(result); return result;
  }
  async rememberDescriptor(intent, raw) {
    const descriptor = avatarDescriptor(raw, intent.accountID), json = JSON.stringify(descriptor);
    this.#tx(() => {
      this.#current(intent); if (intent.kind !== "select" || descriptor.image.versionID !== intent.versionID || descriptor.requestID !== intent.requestID) throw new AvatarPolicyError("AVATAR_STALE");
      const job = this.#job(intent.accountID, intent.requestID);
      if (job.descriptor_json !== null && job.descriptor_json !== json) throw new AvatarPolicyError("AVATAR_STALE");
      this.#storage.sql.exec("UPDATE avatar_jobs_v1 SET descriptor_json=? WHERE account_id=? AND request_id=?", json, intent.accountID, intent.requestID);
    });
    await this.#durable(); this.assertCurrent(intent); return descriptor;
  }
  #descriptor(intent) {
    this.#current(intent); const value = this.#job(intent.accountID, intent.requestID)?.descriptor_json;
    if (typeof value !== "string" || value.length > 2048) throw new AvatarPolicyError("AVATAR_PENDING");
    const parsed = JSON.parse(value);
    const descriptor = avatarDescriptor({ image: parsed.image, thumbnail: parsed.thumbnail, requestID: parsed.requestID }, intent.accountID);
    if (JSON.stringify(descriptor) !== value || descriptor.image.versionID !== intent.versionID || descriptor.requestID !== intent.requestID) throw new AvatarPolicyError("AVATAR_STALE");
    return descriptor;
  }
  descriptor(intent) { return this.#tx(() => this.#descriptor(intent)); }
  async staged(intent, receipt) {
    const descriptor = this.descriptor(intent), context = this.#registry.owned(intent.accountID, "avatar", intent.versionID);
    this.#tx(() => {
      this.#current(intent);
      if (context?.phase !== "settled" || context.requestID !== intent.requestID || context.payloadHash !== avatarDescriptorHash(descriptor) ||
          context.recordTag !== receipt?.recordChangeTag || receipt.status !== "staged" || receipt.ownerID !== intent.accountID || receipt.versionID !== intent.versionID ||
          receipt.requestID !== intent.requestID || !validTag(receipt.recordChangeTag)) throw new AvatarPolicyError("AVATAR_STALE");
      const job = this.#job(intent.accountID, intent.requestID);
      if (job.staged_tag !== null && job.staged_tag !== receipt.recordChangeTag) throw new AvatarPolicyError("AVATAR_STALE");
      this.#storage.sql.exec("UPDATE avatar_jobs_v1 SET staged_tag=? WHERE account_id=? AND request_id=?", receipt.recordChangeTag, intent.accountID, intent.requestID);
    });
    await this.#durable(); this.assertCurrent(intent);
  }
  /** Staged immutable content for trusted moderation, never a viewer grant. */
  reviewContent(accountID, requestID) {
    uuid(requestID);
    const value = this.#tx(() => {
      this.#active(accountID); const intent = this.#lease(accountID);
      if (intent.kind !== "select" || intent.requestID !== requestID) throw new AvatarPolicyError("AVATAR_STALE");
      const job = this.#job(accountID, requestID), descriptor = this.#descriptor(intent);
      if (!validTag(job.staged_tag)) throw new AvatarPolicyError("AVATAR_PENDING");
      return { ...intent, reviewRevision: job.moderation_revision, stagedTag: job.staged_tag,
        payloadHash: avatarDescriptorHash(descriptor), descriptor };
    });
    const avatar = this.#registry.readable(recordIdentity(accountID, "avatar", value.versionID).recordName, "avatar");
    if (!avatar || avatar.requestID !== requestID || avatar.recordTag !== value.stagedTag || avatar.payloadHash !== value.payloadHash) throw new AvatarPolicyError("AVATAR_STALE");
    return Object.freeze({ ...value, avatar });
  }
  assertReviewContent(value, { includeRevision = true } = {}) {
    const current = this.reviewContent(value?.accountID, value?.requestID);
    if (["versionID", "generation", "payloadHash", "stagedTag", ...(includeRevision ? ["reviewRevision"] : [])].some(key => current[key] !== value[key])) throw new AvatarPolicyError("AVATAR_STALE");
    return current;
  }
  /** Own approved selection, including staged/ready=0 content. Not a peer or moderator grant. */
  readApprovedOwnerSelection(accountID, selection) {
    const current = this.reviewContent(accountID, selection?.requestID);
    if (["requestID", "versionID", "generation", "reviewRevision"].some(key => current[key] !== selection?.[key])) throw new AvatarPolicyError("AVATAR_STALE");
    this.publishLease(current); // Reuse approval, generation and current-intent barriers; no pointer write.
    return current;
  }
  assertApprovedOwnerSelection(value) {
    const current = this.readApprovedOwnerSelection(value?.accountID, value);
    if (["payloadHash", "stagedTag"].some(key => current[key] !== value[key])) throw new AvatarPolicyError("AVATAR_STALE");
    return current;
  }
  reviewQueue() {
    return this.#tx(() => this.#rows(`SELECT j.account_id,j.request_id FROM avatar_jobs_v1 j
      JOIN avatar_profiles_v1 p ON p.account_id=j.account_id AND p.request_id=j.request_id AND p.version_id=j.version_id AND p.generation=j.generation
      JOIN auth_accounts_v1 a ON a.account_id=j.account_id LEFT JOIN community_accounts_v1 c ON c.account_id=j.account_id
      WHERE j.moderation_state='pending' AND j.staged_tag IS NOT NULL AND a.disabled=0 AND COALESCE(c.suspended,0)=0
      AND p.expired_at IS NULL AND j.created_at>?
      ORDER BY j.created_at,j.account_id,j.request_id LIMIT 20`, this.#now() - avatarSelectionLifetimeMilliseconds)).map(row => this.reviewContent(row.account_id, row.request_id));
  }
  async review({ accountID, requestID, decisionID, expectedRevision, verdict, reviewerID } = {}) {
    uuid(requestID); uuid(decisionID); uuid(expectedRevision); uuid(reviewerID);
    if (!["approved", "rejected"].includes(verdict)) throw new AvatarPolicyError("AVATAR_INPUT");
    const result = this.#tx(() => {
      this.#active(accountID); const intent = this.#lease(accountID); if (intent.requestID !== requestID || intent.kind !== "select") throw new AvatarPolicyError("AVATAR_STALE");
      const job = this.#job(accountID, requestID); this.#descriptor(intent);
      if (!validTag(job.staged_tag)) throw new AvatarPolicyError("AVATAR_PENDING");
      if (readAvatarReviewRetirement(this.#storage, { accountID, requestID, versionID: job.version_id, generation: job.generation,
        reviewRevision: expectedRevision, decisionID, verdict, reviewerID }, this.#now())) throw new AvatarPolicyError("AVATAR_STALE");
      if (job.decision_id === decisionID) {
        if (job.decision_expected_revision !== expectedRevision || job.moderation_state !== verdict || job.reviewer_key !== digest(reviewerID)) throw new AvatarPolicyError("AVATAR_STALE");
      } else {
        if (job.moderation_revision !== expectedRevision) throw new AvatarPolicyError("AVATAR_STALE");
        this.#storage.sql.exec(`UPDATE avatar_jobs_v1 SET moderation_state=?,moderation_revision=?,decision_id=?,decision_expected_revision=?,reviewer_key=?,reviewed_at=?
          WHERE account_id=? AND request_id=?`, verdict, randomUUID(), decisionID, expectedRevision, digest(reviewerID), this.#now(), accountID, requestID);
        this.#storage.sql.exec("UPDATE avatar_profiles_v1 SET ready=0,pointer_tag=NULL WHERE account_id=?", accountID);
      }
      const latest = this.#job(accountID, requestID);
      return Object.freeze({ accountID, requestID, decisionID, revision: latest.moderation_revision, verdict: latest.moderation_state });
    });
    await this.#durable(); this.assertReviewCurrent(result); return result;
  }
  assertReviewCurrent(value) { this.#tx(() => { this.#active(value.accountID); const job = this.#job(value.accountID, value.requestID), profile = this.#lease(value.accountID);
    if (profile.requestID !== value.requestID || job?.decision_id !== value.decisionID || job.moderation_revision !== value.revision || job.moderation_state !== value.verdict) throw new AvatarPolicyError("AVATAR_STALE"); }); }
  /** Read-only recovery of an exact durable decision, never a renewed inspection or mutation.
   * A missing/replaced/deleted current selection cannot prove the historical outcome. */
  reviewOutcome(query) { return this.#tx(() => this.#reviewOutcome(query)); }
  #reviewOutcome({ accountID, requestID, versionID, generation, reviewRevision, decisionID, verdict, reviewerID } = {}) {
    for (const value of [accountID, requestID, versionID, reviewRevision, decisionID, reviewerID]) uuid(value);
    if (!Number.isSafeInteger(generation) || generation < 1 || generation >= Number.MAX_SAFE_INTEGER ||
        !["approved", "rejected"].includes(verdict)) throw new AvatarPolicyError("AVATAR_INPUT");
    if (readAvatarReviewRetirement(this.#storage, { accountID, requestID, versionID, generation, reviewRevision, decisionID, verdict, reviewerID }, this.#now()))
      return Object.freeze({ outcome: "retired", revision: null });
    {
      const unknown = Object.freeze({ outcome: "superseded", revision: null });
      let current;
      try { this.#active(accountID); current = this.#lease(accountID); }
      catch (e) { if (e.code === "AVATAR_STALE") return unknown; throw e; }
      if (current.kind !== "select" || current.requestID !== requestID || current.versionID !== versionID || current.generation !== generation) return unknown;
      const job = this.#job(accountID, requestID);
      if (!job || job.version_id !== versionID || job.generation !== generation || !validTag(job.staged_tag)) return unknown;
      if (!publicUUID.test(job.moderation_revision ?? "")) throw new AvatarPolicyError();
      if (job.decision_id === decisionID) {
        if (job.decision_expected_revision !== reviewRevision || job.moderation_state !== verdict ||
            job.reviewer_key !== digest(reviewerID) || job.moderation_revision === reviewRevision) return unknown;
        return Object.freeze({ outcome: "confirmed", revision: job.moderation_revision });
      }
      return job.moderation_revision === reviewRevision
        ? Object.freeze({ outcome: "not-applied", revision: null }) : unknown;
    }
  }
  /** Explicit own-nonce closure. Never publishes, rejects a whole job, or undoes a known decision. */
  async retireReview({ accountID, requestID, versionID, generation, reviewRevision, decisionID, verdict, reviewerID, authorize } = {}) {
    if (typeof authorize !== "function") throw new AvatarPolicyError("AVATAR_INPUT");
    let permitted; try { permitted = authorize(); } catch { throw new AvatarPolicyError("AVATAR_SCOPE"); }
    if (permitted && typeof permitted.then === "function") { void Promise.resolve(permitted).catch(() => {}); throw new AvatarPolicyError("AVATAR_SCOPE"); }
    if (permitted !== true) throw new AvatarPolicyError("AVATAR_SCOPE");
    const query = { accountID, requestID, versionID, generation, reviewRevision, decisionID, verdict, reviewerID };
    const result = this.#tx(() => {
      // This endpoint uses a verified ordinary moderator session; legacy internal review grants remain separate.
      this.#active(reviewerID);
      const known = this.#reviewOutcome(query);
      if (["confirmed", "retired"].includes(known.outcome)) return known;
      const job = this.#job(accountID, requestID);
      if (known.outcome === "superseded" && job?.decision_id && job.version_id === versionID && job.generation === generation && job.decision_expected_revision === reviewRevision) return known;
      createAvatarReviewRetirement(this.#storage, query, this.#now());
      return Object.freeze({ outcome: "retired", revision: null });
    });
    await this.#durable();
    const latest = this.reviewOutcome(query);
    if (latest.outcome !== result.outcome || latest.revision !== result.revision) throw new AvatarPolicyError("AVATAR_STALE");
    return latest;
  }
  #publishLease(intent) {
    this.#current(intent); if (intent.kind !== "select") throw new AvatarPolicyError("AVATAR_STALE");
    const job = this.#job(intent.accountID, intent.requestID), descriptor = this.#descriptor(intent);
    if (intent.reviewRevision !== undefined && intent.reviewRevision !== job.moderation_revision) throw new AvatarPolicyError("AVATAR_STALE");
    if (!validTag(job.staged_tag) || job.moderation_state === "pending") throw new AvatarPolicyError("AVATAR_PENDING");
    if (job.moderation_state !== "approved") throw new AvatarPolicyError("AVATAR_REJECTED");
    return Object.freeze({ ...intent, reviewRevision: job.moderation_revision, payloadHash: avatarDescriptorHash(descriptor), stagedTag: job.staged_tag });
  }
  publishLease(intent) { return this.#tx(() => this.#publishLease(intent)); }
  assertPublishCurrent(lease) { return this.#tx(() => { const current = this.#publishLease(lease);
    if (["reviewRevision", "payloadHash", "stagedTag"].some(key => current[key] !== lease[key])) throw new AvatarPolicyError("AVATAR_STALE"); return current; }); }
  async finish(intent, receipt) {
    const pointer = this.#registry.owned(intent.accountID, "avatarprofile", "singleton");
    this.#tx(() => {
      this.#current(intent); if (intent.kind === "select") {
        const current = this.#publishLease(intent); if (current.reviewRevision !== intent.reviewRevision) throw new AvatarPolicyError("AVATAR_STALE");
      }
      if (pointer?.phase !== "settled" || pointer.requestID !== intent.requestID || pointer.recordTag !== receipt?.recordChangeTag ||
          pointer.payloadHash !== inputHash({ versionID: intent.versionID ?? "", generation: intent.generation })) throw new AvatarPolicyError("AVATAR_STALE");
      this.#storage.sql.exec("UPDATE avatar_profiles_v1 SET ready=1,pointer_tag=? WHERE account_id=?", pointer.recordTag, intent.accountID);
    });
    await this.#durable(); this.assertCurrent(intent); if (intent.kind === "select") this.assertPublishCurrent(intent);
  }
  /** Internal author-publication proof only. The caller still must authorize the viewer/area. */
  readPublication(accountID) {
    const value = this.#tx(() => {
      this.#active(accountID); const profile = this.#profile(accountID);
      if (!profile?.ready || profile.version_id === null) throw new AvatarPolicyError("AVATAR_STALE");
      const lease = this.#publishLease(this.#lease(accountID));
      return { ...lease, descriptor: this.#descriptor(lease), pointerTag: profile.pointer_tag };
    });
    const avatar = this.#registry.readable(recordIdentity(accountID, "avatar", value.versionID).recordName, "avatar");
    const pointer = this.#registry.readable(recordIdentity(accountID, "avatarprofile", "singleton").recordName, "avatarprofile");
    if (!avatar || !pointer || avatar.requestID !== value.requestID || avatar.recordTag !== value.stagedTag || avatar.payloadHash !== value.payloadHash ||
        pointer.requestID !== value.requestID || pointer.recordTag !== value.pointerTag ||
        pointer.payloadHash !== inputHash({ versionID: value.versionID, generation: value.generation })) throw new AvatarPolicyError("AVATAR_STALE");
    return Object.freeze({ ...value, avatar, pointer });
  }
  assertReadPublication(value) {
    const current = this.readPublication(value?.accountID);
    if (["requestID", "versionID", "generation", "reviewRevision", "payloadHash", "stagedTag", "pointerTag"].some(key => current[key] !== value[key])) throw new AvatarPolicyError("AVATAR_STALE");
    return current;
  }
  async ensureSelectionExpiry(accountID) {
    this.#tx(() => {
      this.#active(accountID);
      expireAvatarSelection(this.#storage, accountID, this.#now(), (profile, deadline) => markAvatarRetired(this.#storage, profile, deadline));
    });
    await this.#durable();
  }
  snapshot(accountID, { allowUnpersistedExpiry = false } = {}) { return this.#tx(() => {
    this.#active(accountID); const p = this.#profile(accountID);
    if (!p) return Object.freeze({ generation: 0, requestID: null, versionID: null, publishedVersionID: null, status: "none", reviewRevision: null });
    const job = p.version_id === null ? null : this.#job(accountID, p.request_id);
    const deadline = avatarSelectionDeadline(p, job, this.#now());
    if (deadline !== null && deadline <= this.#now()) {
      if (!allowUnpersistedExpiry && p.expired_at === null) throw new AvatarPolicyError("AVATAR_PENDING");
      return Object.freeze({ generation: p.generation, requestID: p.request_id,
        versionID: p.version_id, publishedVersionID: null, status: "expired", reviewRevision: p.expired_review_revision ?? job.moderation_revision });
    }
    if (p.version_id !== null && !job) throw new AvatarPolicyError();
    const published = !!p.ready && job?.moderation_state === "approved";
    return Object.freeze({ generation: p.generation, requestID: p.request_id, versionID: p.version_id, publishedVersionID: published ? p.version_id : null,
      status: !job ? p.ready ? "none" : "clearing" : !job.staged_tag ? "uploading" : published ? "published" :
        job.moderation_state === "pending" ? "pending-review" : job.moderation_state, reviewRevision: job?.moderation_revision ?? null });
  }); }
}
