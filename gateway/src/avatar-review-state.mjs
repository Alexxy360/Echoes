import { randomUUID } from "node:crypto";
import { publicUUID, digest } from "./public-record-schema.mjs";

const codes = new Set(["AVATAR_REVIEW_INPUT", "AVATAR_REVIEW_SCOPE", "AVATAR_REVIEW_STALE", "AVATAR_REVIEW_PENDING", "AVATAR_REVIEW_RESPONSE", "AVATAR_REVIEW_UNAVAILABLE", "AVATAR_REVIEW_RATE", "AVATAR_REVIEW_CAPACITY"]);
export class AvatarReviewError extends Error {
  constructor(code = "AVATAR_REVIEW_UNAVAILABLE") { super("Photo review could not be completed."); this.code = codes.has(code) ? code : "AVATAR_REVIEW_UNAVAILABLE"; }
}
export const avatarReviewerKey = id => digest("echoes/avatar-reviewer/v1\0" + id);
const inspectionKey = id => digest("echoes/avatar-inspection/v1\0" + id);
const uuid = value => { if (typeof value !== "string" || !publicUUID.test(value)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT"); return value; };
export const avatarReviewSchema = Object.freeze([
  `CREATE TABLE IF NOT EXISTS avatar_review_receipts_v1(reviewer_key TEXT PRIMARY KEY,session_key TEXT NOT NULL,
    inspection_key TEXT NOT NULL,account_id TEXT NOT NULL,request_id TEXT NOT NULL,version_id TEXT NOT NULL,
    generation INTEGER NOT NULL,content_hash TEXT NOT NULL,expected_revision TEXT NOT NULL,
    created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,budget_window INTEGER NOT NULL,budget_count INTEGER NOT NULL,
    verified INTEGER NOT NULL DEFAULT 0,decision_id TEXT,verdict TEXT,result_revision TEXT)`,
  `CREATE INDEX IF NOT EXISTS avatar_review_expiry_v1 ON avatar_review_receipts_v1(expires_at)`,
  `CREATE INDEX IF NOT EXISTS avatar_review_owner_v1 ON avatar_review_receipts_v1(account_id)`,
]);
export function avatarReviewContentHash(value) {
  return digest(JSON.stringify([value.accountID, value.requestID, value.versionID, value.generation, value.payloadHash, value.stagedTag]));
}
export async function purgeAvatarReviewReceipts(storage, clock = Date.now) {
  if (!storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='avatar_review_receipts_v1'").toArray().length) return;
  const now = clock(); if (!Number.isSafeInteger(now) || now < 0) throw new AvatarReviewError();
  storage.transactionSync(() => storage.sql.exec(`DELETE FROM avatar_review_receipts_v1 WHERE reviewer_key IN
    (SELECT reviewer_key FROM avatar_review_receipts_v1 WHERE expires_at<=? ORDER BY expires_at LIMIT 256)`, now));
  await storage.sync();
}
/** One short-lived receipt per reviewer, no pixels/URLs/tokens. Starting another inspection replaces
 * the previous receipt, including any unfinished decision. Exact retries reuse decisionID/verdict.
 */
export class AvatarReviewReceipts {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.transactionSync !== "function" || typeof storage.sync !== "function" || typeof storage.sql?.exec !== "function" || typeof clock !== "function") throw new AvatarReviewError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => { for (const sql of avatarReviewSchema) storage.sql.exec(sql); });
  }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (e) { throw e instanceof AvatarReviewError ? e : new AvatarReviewError(); } }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #now() { const value = this.#clock(); if (!Number.isSafeInteger(value) || value < 0) throw new AvatarReviewError(); return value; }
  async #durable() { try { await this.#storage.sync(); } catch { throw new AvatarReviewError(); } }
  #get(reviewerID, sessionKey, inspectionID, unverified = false) {
    uuid(reviewerID); uuid(inspectionID);
    const row = this.#rows("SELECT * FROM avatar_review_receipts_v1 WHERE reviewer_key=?", avatarReviewerKey(reviewerID))[0], now = this.#now();
    if (!row || row.session_key !== sessionKey || row.inspection_key !== inspectionKey(inspectionID) || !unverified && row.verified !== 1 ||
        !Number.isSafeInteger(row.created_at) || !Number.isSafeInteger(row.expires_at) || row.expires_at - row.created_at !== 90000 ||
        row.created_at > now || row.expires_at <= now || !Number.isSafeInteger(row.generation) || row.generation < 1 ||
        !publicUUID.test(row.expected_revision) || !/^[a-f0-9]{64}$/.test(row.content_hash) ||
        (row.decision_id === null ? row.verdict !== null || row.result_revision !== null : !publicUUID.test(row.decision_id) || !["approved", "rejected"].includes(row.verdict)) ||
        row.result_revision !== null && !publicUUID.test(row.result_revision)) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
    return Object.freeze({ ...row });
  }
  get(reviewerID, sessionKey, inspectionID) { return this.#tx(() => this.#get(reviewerID, sessionKey, inspectionID)); }
  async reserve(reviewerID, sessionKey, content) {
    uuid(reviewerID); uuid(content.accountID); uuid(content.requestID); uuid(content.versionID); uuid(content.reviewRevision);
    if (typeof sessionKey !== "string" || !/^[a-f0-9]{64}$/.test(sessionKey)) throw new AvatarReviewError("AVATAR_REVIEW_SCOPE");
    const inspectionID = randomUUID(), key = avatarReviewerKey(reviewerID);
    this.#tx(() => {
      const now = this.#now(), window = Math.floor(now / 60000), old = this.#rows("SELECT * FROM avatar_review_receipts_v1 WHERE reviewer_key=?", key)[0];
      if (!Number.isSafeInteger(now + 90000)) throw new AvatarReviewError();
      if (old?.created_at > now) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
      const count = old?.budget_window === window ? old.budget_count : 0;
      if (!Number.isSafeInteger(count) || count < 0) throw new AvatarReviewError();
      if (count >= 10) throw new AvatarReviewError("AVATAR_REVIEW_RATE");
      this.#storage.sql.exec("DELETE FROM avatar_review_receipts_v1 WHERE expires_at<=?", now);
      if (!old && this.#rows("SELECT reviewer_key FROM avatar_review_receipts_v1 LIMIT 256").length >= 256) throw new AvatarReviewError("AVATAR_REVIEW_CAPACITY");
      this.#storage.sql.exec(`INSERT INTO avatar_review_receipts_v1(reviewer_key,session_key,inspection_key,account_id,request_id,
        version_id,generation,content_hash,expected_revision,created_at,expires_at,budget_window,budget_count)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(reviewer_key) DO UPDATE SET session_key=excluded.session_key,
        inspection_key=excluded.inspection_key,account_id=excluded.account_id,request_id=excluded.request_id,version_id=excluded.version_id,
        generation=excluded.generation,content_hash=excluded.content_hash,expected_revision=excluded.expected_revision,
        created_at=excluded.created_at,expires_at=excluded.expires_at,budget_window=excluded.budget_window,budget_count=excluded.budget_count,
        verified=0,decision_id=NULL,verdict=NULL,result_revision=NULL`, key, sessionKey, inspectionKey(inspectionID), content.accountID, content.requestID,
      content.versionID, content.generation, avatarReviewContentHash(content), content.reviewRevision, now, now + 90000, window, count + 1);
    });
    await this.#durable(); const row = this.#tx(() => this.#get(reviewerID, sessionKey, inspectionID, true));
    return Object.freeze({ inspectionID, expiresAt: row.expires_at });
  }
  async confirm(reviewerID, sessionKey, inspectionID) {
    this.#tx(() => {
      const row = this.#get(reviewerID, sessionKey, inspectionID, true);
      this.#storage.sql.exec("UPDATE avatar_review_receipts_v1 SET verified=1 WHERE reviewer_key=?", row.reviewer_key);
    });
    await this.#durable(); this.get(reviewerID, sessionKey, inspectionID);
  }
  async claim(reviewerID, sessionKey, inspectionID, decisionID, verdict) {
    uuid(decisionID); if (!["approved", "rejected"].includes(verdict)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
    this.#tx(() => {
      const row = this.#get(reviewerID, sessionKey, inspectionID);
      if (row.decision_id !== null && (row.decision_id !== decisionID || row.verdict !== verdict)) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
      this.#storage.sql.exec("UPDATE avatar_review_receipts_v1 SET decision_id=?,verdict=? WHERE reviewer_key=?", decisionID, verdict, row.reviewer_key);
    });
    await this.#durable(); const claimed = this.get(reviewerID, sessionKey, inspectionID);
    if (claimed.decision_id !== decisionID || claimed.verdict !== verdict) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
    return claimed;
  }
  async finish(reviewerID, sessionKey, inspectionID, result) {
    this.#tx(() => {
      const row = this.#get(reviewerID, sessionKey, inspectionID);
      if (row.decision_id !== result.decisionID || row.verdict !== result.verdict || row.account_id !== result.accountID ||
          row.request_id !== result.requestID || row.result_revision !== null && row.result_revision !== result.revision) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
      uuid(result.revision);
      this.#storage.sql.exec("UPDATE avatar_review_receipts_v1 SET result_revision=? WHERE reviewer_key=?", result.revision, row.reviewer_key);
    });
    await this.#durable(); const finished = this.get(reviewerID, sessionKey, inspectionID);
    if (finished.result_revision !== result.revision) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
    return finished;
  }
}
