import { plain, publicUUID, digest } from "./public-record-schema.mjs";
const lifetime = 30 * 86400000;
const definitions = Object.freeze({
  message: { table: "community_report_decision_retirements_v1", kind: "report", name: /^community-v1-report-[a-f0-9]{64}$/, verdicts: ["dismiss", "hide_message"] },
  photo: { table: "avatar_report_decision_retirements_v1", kind: "avatarreport", name: /^community-v1-avatarreport-[a-f0-9]{64}$/, verdicts: ["dismiss", "hide_photo"] }
});
export class ModerationRetirementError extends Error {
  constructor(code = "UNAVAILABLE") { super("Moderator attempt could not be closed."); this.code = ["INPUT", "CONFLICT", "CAPACITY"].includes(code) ? code : "UNAVAILABLE"; }
}
const fail = code => { throw new ModerationRetirementError(code); };
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const domain = key => { if (!Object.hasOwn(definitions, key)) fail("INPUT"); return definitions[key]; };
const rows = (storage, sql, ...args) => storage.sql.exec(sql, ...args).toArray();
const time = now => { if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + lifetime)) fail(); return now; };
const reportOwnerKey = accountID => { if (!id(accountID)) fail(); return digest("echoes/moderation-report-owner/v1\0" + accountID); };
function intentHash(key, query) {
  const d = domain(key);
  if (!plain(query) || Object.keys(query).sort().join() !== "contentHash,decisionID,reportID,reviewerKey,verdict" ||
      !hash(query.reviewerKey) || !id(query.decisionID) || typeof query.reportID !== "string" || !d.name.test(query.reportID) || !hash(query.contentHash) || !d.verdicts.includes(query.verdict)) fail("INPUT");
  return digest(JSON.stringify(["echoes/moderation-retirement/v1", key, query.reviewerKey, query.decisionID, query.reportID, query.contentHash, query.verdict]));
}
export function moderationRetirementSchema(key) {
  const { table } = domain(key);
  return Object.freeze([
    `CREATE TABLE IF NOT EXISTS ${table}(reviewer_key TEXT NOT NULL,decision_id TEXT NOT NULL,intent_hash TEXT NOT NULL,
      report_owner_key TEXT,retired_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,PRIMARY KEY(reviewer_key,decision_id))`,
    `CREATE INDEX IF NOT EXISTS ${table}_expiry ON ${table}(expires_at)`,
    `CREATE INDEX IF NOT EXISTS ${table}_report_owner ON ${table}(report_owner_key)`
  ]);
}
/** Synchronous helpers: caller MUST own the SAME transaction as a decision/policy mutation. No provider IO. */
export function readModerationRetirement(storage, key, query, now) {
  const expected = intentHash(key, query), { table } = domain(key); time(now);
  const row = rows(storage, `SELECT * FROM ${table} WHERE reviewer_key=? AND decision_id=?`, query.reviewerKey, query.decisionID)[0];
  if (!row) return null;
  if (!hash(row.intent_hash) || row.report_owner_key !== null && !hash(row.report_owner_key) ||
      !Number.isSafeInteger(row.retired_at) || row.retired_at < 0 || row.retired_at > now ||
      !Number.isSafeInteger(row.expires_at) || row.expires_at !== row.retired_at + lifetime) fail();
  if (row.intent_hash !== expected) fail("CONFLICT");
  return row.expires_at > now ? Object.freeze({ retiredAt: row.retired_at, expiresAt: row.expires_at }) : null;
}
export function createModerationRetirement(storage, key, query, now) {
  const expected = intentHash(key, query), { table, kind } = domain(key); time(now);
  const old = readModerationRetirement(storage, key, query, now); if (old) return old;
  storage.sql.exec(`DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE expires_at<=? ORDER BY expires_at LIMIT 100)`, now);
  storage.sql.exec(`DELETE FROM ${table} WHERE reviewer_key=? AND decision_id=? AND expires_at<=?`, query.reviewerKey, query.decisionID, now);
  if (rows(storage, `SELECT COUNT(*) AS n FROM ${table} WHERE reviewer_key=?`, query.reviewerKey)[0].n >= 256 || rows(storage, `SELECT COUNT(*) AS n FROM ${table}`)[0].n >= 4096) fail("CAPACITY");
  const owner = rows(storage, "SELECT account_id,kind FROM public_records_v1 WHERE record_name=?", query.reportID)[0];
  if (owner && owner.kind !== kind) fail();
  storage.sql.exec(`INSERT INTO ${table} VALUES(?,?,?,?,?,?)`, query.reviewerKey, query.decisionID, expected, owner ? reportOwnerKey(owner.account_id) : null, now, now + lifetime);
  return readModerationRetirement(storage, key, query, now);
}
const installed = (storage, key) => rows(storage, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", domain(key).table).length === 1;
export async function purgeModerationRetirements(storage, clock = Date.now) {
  const now = time(clock());
  storage.transactionSync(() => { for (const key of Object.keys(definitions)) if (installed(storage, key)) {
    const { table } = domain(key);
    storage.sql.exec(`DELETE FROM ${table} WHERE rowid IN (SELECT rowid FROM ${table} WHERE expires_at<=? ORDER BY expires_at LIMIT 100)`, now);
  } }); await storage.sync();
}
export function moderationRetirementWakeAt(storage, clock = Date.now) {
  const now = time(clock()), deadlines = [];
  for (const key of Object.keys(definitions)) if (installed(storage, key)) {
    const n = rows(storage, `SELECT MIN(expires_at) AS n FROM ${domain(key).table}`)[0].n;
    if (n !== null) { if (!Number.isSafeInteger(n) || n < 0) fail(); deadlines.push(Math.max(now, n)); }
  }
  return deadlines.length ? Math.min(...deadlines) : null;
}
/** Existing disabled-owner transaction. Minimal unknown-report markers have no source-owner mapping. */
export function eraseModerationRetirements(storage, accountID) {
  if (!id(accountID)) fail("INPUT");
  for (const key of Object.keys(definitions)) if (installed(storage, key)) {
    const reviewerKey = digest((key === "message" ? "echoes/report-reviewer/v1\0" : "echoes/avatar-report-reviewer/v1\0") + accountID);
    storage.sql.exec(`DELETE FROM ${domain(key).table} WHERE reviewer_key=? OR report_owner_key=?`, reviewerKey, reportOwnerKey(accountID));
  }
}
