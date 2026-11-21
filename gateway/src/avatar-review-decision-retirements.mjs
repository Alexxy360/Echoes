import { plain, publicUUID, digest } from "./public-record-schema.mjs";
const lifetime = 30 * 86400000;
const table = "avatar_review_decision_retirements_v1";
export class AvatarReviewRetirementError extends Error {
  constructor(code = "UNAVAILABLE") { super("Upload review attempt could not be closed."); this.code = ["INPUT", "CONFLICT", "CAPACITY"].includes(code) ? code : "UNAVAILABLE"; }
}
const fail = code => { throw new AvatarReviewRetirementError(code); };
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const rows = (storage, sql, ...args) => storage.sql.exec(sql, ...args).toArray();
const time = now => { if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + lifetime)) fail(); return now; };
const reviewerKey = value => { if (!id(value)) fail("INPUT"); return digest("echoes/upload-review-retirement/reviewer/v1\0" + value); };
const ownerKey = value => { if (!id(value)) fail("INPUT"); return digest("echoes/upload-review-retirement/owner/v1\0" + value); };
function identity(query) {
  const fields = ["reviewerID", "accountID", "requestID", "versionID", "generation", "reviewRevision", "decisionID", "verdict"];
  if (!plain(query) || Object.keys(query).sort().join() !== [...fields].sort().join() ||
      fields.filter(k => k.endsWith("ID") || k === "reviewRevision").some(k => !id(query[k])) ||
      !Number.isSafeInteger(query.generation) || query.generation < 1 || query.generation >= Number.MAX_SAFE_INTEGER || !["approved", "rejected"].includes(query.verdict)) fail("INPUT");
  return { reviewer: reviewerKey(query.reviewerID), owner: ownerKey(query.accountID),
    intent: digest(JSON.stringify(["echoes/upload-review-retirement/v1", ...fields.map(k => query[k])])) };
}
export const avatarReviewRetirementSchema = Object.freeze([
  `CREATE TABLE IF NOT EXISTS ${table}(reviewer_key TEXT NOT NULL,decision_id TEXT NOT NULL,intent_hash TEXT NOT NULL,
    owner_key TEXT NOT NULL,retired_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,PRIMARY KEY(reviewer_key,decision_id))`,
  `CREATE INDEX IF NOT EXISTS ${table}_expiry ON ${table}(expires_at)`,
  `CREATE INDEX IF NOT EXISTS ${table}_owner ON ${table}(owner_key)`
]);
/** Synchronous only. The caller MUST hold the SAME transaction as the eventual review mutation. */
export function readAvatarReviewRetirement(storage, query, now) {
  const expected = identity(query); time(now);
  const row = rows(storage, `SELECT * FROM ${table} WHERE reviewer_key=? AND decision_id=?`, expected.reviewer, query.decisionID)[0];
  if (!row) return null;
  if (!hash(row.intent_hash) || !hash(row.owner_key) || !Number.isSafeInteger(row.retired_at) || row.retired_at < 0 || row.retired_at > now ||
      !Number.isSafeInteger(row.expires_at) || row.expires_at !== row.retired_at + lifetime) fail();
  if (row.intent_hash !== expected.intent || row.owner_key !== expected.owner) fail("CONFLICT");
  return row.expires_at > now ? Object.freeze({ retiredAt: row.retired_at, expiresAt: row.expires_at }) : null;
}
export function createAvatarReviewRetirement(storage, query, now) {
  const expected = identity(query); time(now); const old = readAvatarReviewRetirement(storage, query, now); if (old) return old;
  storage.sql.exec(`DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE expires_at<=? ORDER BY expires_at LIMIT 100)`, now);
  storage.sql.exec(`DELETE FROM ${table} WHERE reviewer_key=? AND decision_id=? AND expires_at<=?`, expected.reviewer, query.decisionID, now);
  if (rows(storage, `SELECT COUNT(*) AS n FROM ${table} WHERE reviewer_key=?`, expected.reviewer)[0].n >= 256 || rows(storage, `SELECT COUNT(*) AS n FROM ${table}`)[0].n >= 4096) fail("CAPACITY");
  storage.sql.exec(`INSERT INTO ${table} VALUES(?,?,?,?,?,?)`, expected.reviewer, query.decisionID, expected.intent, expected.owner, now, now + lifetime);
  return readAvatarReviewRetirement(storage, query, now);
}
const installed = storage => rows(storage, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", table).length === 1;
export async function purgeAvatarReviewRetirements(storage, clock = Date.now) {
  const now = time(clock()); if (!installed(storage)) return;
  storage.transactionSync(() => storage.sql.exec(`DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE expires_at<=? ORDER BY expires_at LIMIT 100)`, now));
  await storage.sync();
}
export function avatarReviewRetirementWakeAt(storage, clock = Date.now) {
  const now = time(clock()); if (!installed(storage)) return null;
  const n = rows(storage, `SELECT MIN(expires_at) AS n FROM ${table}`)[0].n;
  if (n === null) return null; if (!Number.isSafeInteger(n) || n < 0) fail(); return Math.max(now, n);
}
/** Existing disabled-owner erasure transaction. No account IDs or images are retained. */
export function eraseAvatarReviewRetirements(storage, accountID) {
  const reviewer = reviewerKey(accountID), owner = ownerKey(accountID); if (!installed(storage)) return;
  storage.sql.exec(`DELETE FROM ${table} WHERE reviewer_key=? OR owner_key=?`, reviewer, owner);
}
