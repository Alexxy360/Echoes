import { randomUUID } from "node:crypto";
import { plain, publicUUID, validTag, digest } from "./public-record-schema.mjs";

const codes = new Set(["REPORT_REVIEW_INPUT", "REPORT_REVIEW_SCOPE", "REPORT_REVIEW_STALE", "REPORT_REVIEW_CAPACITY", "REPORT_REVIEW_RESPONSE", "REPORT_REVIEW_UNAVAILABLE"]);
export class CommunityReportReviewError extends Error {
  constructor(code = "REPORT_REVIEW_UNAVAILABLE") { super("Confidential report review could not be completed."); this.code = codes.has(code) ? code : "REPORT_REVIEW_UNAVAILABLE"; }
}
const fail = code => { throw new CommunityReportReviewError(code); };
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const reportName = value => typeof value === "string" && /^community-v1-report-[a-f0-9]{64}$/.test(value);
const messageName = value => typeof value === "string" && /^community-v1-message-[a-f0-9]{64}$/.test(value);
const verdicts = new Set(["dismiss", "hide_message"]);
const reviewerKey = value => digest("echoes/report-reviewer/v1\0" + value);
const inspectionKey = value => digest("echoes/report-inspection/v1\0" + value);
const fields = ["reportID", "reportTag", "reportHash", "reportRequestID", "reportExpiresAt", "messageID", "messageTag", "messageHash", "messageAccountID", "messageRequestID", "messageExpiresAt"];
function validContent(c) {
  return plain(c) && Object.keys(c).sort().join() === [...fields].sort().join() && reportName(c.reportID) && validTag(c.reportTag) && hash(c.reportHash) &&
    id(c.reportRequestID) && Number.isSafeInteger(c.reportExpiresAt) && c.reportExpiresAt >= 0 && messageName(c.messageID) &&
    (c.messageTag === null ? [c.messageHash, c.messageAccountID, c.messageRequestID, c.messageExpiresAt].every(v => v === null) :
      validTag(c.messageTag) && hash(c.messageHash) && id(c.messageAccountID) && id(c.messageRequestID) && Number.isSafeInteger(c.messageExpiresAt) && c.messageExpiresAt >= 0);
}
export function reportReviewContent(report, message) {
  const c = { reportID: report.context.recordName, reportTag: report.context.recordTag, reportHash: report.context.payloadHash,
    reportRequestID: report.context.requestID, reportExpiresAt: report.context.startedAt + 2592000000, messageID: report.input.messageID,
    messageTag: message?.context.recordTag ?? null, messageHash: message?.context.payloadHash ?? null,
    messageAccountID: message?.context.accountID ?? null, messageRequestID: message?.context.requestID ?? null,
    messageExpiresAt: message?.record.fields.expiresAt.value ?? null };
  if (!validContent(c) || message && message.context.recordName !== c.messageID) fail("REPORT_REVIEW_STALE");
  return Object.freeze(c);
}
export function reportReviewContentHash(c) {
  if (!validContent(c)) fail("REPORT_REVIEW_INPUT");
  return digest(JSON.stringify(fields.map(name => c[name])));
}
const schema = [
  `CREATE TABLE IF NOT EXISTS community_report_inspections_v1(reviewer_key TEXT PRIMARY KEY,session_key TEXT NOT NULL,
    inspection_key TEXT NOT NULL,report_id TEXT NOT NULL,content TEXT NOT NULL,content_hash TEXT NOT NULL,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,
    verified INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS community_report_inspection_expiry_v1 ON community_report_inspections_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS community_report_decisions_v1(report_id TEXT PRIMARY KEY,report_tag TEXT NOT NULL,report_hash TEXT NOT NULL,
    content_hash TEXT NOT NULL,reviewer_key TEXT NOT NULL,decision_id TEXT NOT NULL UNIQUE,verdict TEXT NOT NULL,revision TEXT NOT NULL,
    resolved_at INTEGER NOT NULL,expires_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS community_report_decision_expiry_v1 ON community_report_decisions_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS community_report_review_budgets_v1(reviewer_key TEXT PRIMARY KEY,window INTEGER NOT NULL,count INTEGER NOT NULL,expires_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS community_report_budget_expiry_v1 ON community_report_review_budgets_v1(expires_at)`,
];

/** Private metadata only. A decision and its exact message policy effect share the SAME SQLite transaction. */
export class CommunityReportReviewState {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.transactionSync !== "function" || typeof storage.sync !== "function" || typeof storage.sql?.exec !== "function" || typeof clock !== "function") fail("REPORT_REVIEW_INPUT");
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => { for (const statement of schema) storage.sql.exec(statement); });
  }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (error) { throw error instanceof CommunityReportReviewError ? error : new CommunityReportReviewError(); } }
  #now() { const n = this.#clock(); if (!Number.isSafeInteger(n) || n < 0) fail(); return n; }
  async #durable() { try { await this.#storage.sync(); } catch { fail(); } }
  #decision(reportID) {
    if (!reportName(reportID)) fail("REPORT_REVIEW_INPUT");
    const row = this.#rows("SELECT * FROM community_report_decisions_v1 WHERE report_id=?", reportID)[0];
    if (row && (!validTag(row.report_tag) || ![row.report_hash, row.content_hash, row.reviewer_key].every(hash) ||
        !id(row.decision_id) || !id(row.revision) || !verdicts.has(row.verdict) || !Number.isSafeInteger(row.resolved_at) || row.resolved_at < 0 ||
        !Number.isSafeInteger(row.expires_at) || row.expires_at <= row.resolved_at || row.resolved_at > this.#now())) fail();
    return row;
  }
  #currentReport(c) {
    const row = this.#rows(`SELECT p.*,a.disabled FROM public_records_v1 p JOIN auth_accounts_v1 a ON a.account_id=p.account_id WHERE p.record_name=?`, c.reportID)[0], now = this.#now();
    if (!row || row.kind !== "report" || row.phase !== "settled" || row.disabled || row.request_id !== c.reportRequestID || row.record_tag !== c.reportTag ||
        row.payload_hash !== c.reportHash || row.started_at > now || row.started_at + 2592000000 !== c.reportExpiresAt || c.reportExpiresAt <= now) fail("REPORT_REVIEW_STALE");
    const retention = this.#rows("SELECT state FROM public_retention_v1 WHERE record_name=?", c.reportID)[0];
    if (retention && retention.state !== "pending") fail("REPORT_REVIEW_STALE");
  }
  isOpen(context) {
    return this.#tx(() => { const row = this.#decision(context.recordName);
      if (row && (row.report_tag !== context.recordTag || row.report_hash !== context.payloadHash)) fail("REPORT_REVIEW_STALE");
      return !row;
    });
  }
  #receipt(reviewerID, sessionKey, inspectionID, unverified = false) {
    if (!id(reviewerID) || !hash(sessionKey) || !id(inspectionID)) fail("REPORT_REVIEW_INPUT");
    const row = this.#rows("SELECT * FROM community_report_inspections_v1 WHERE reviewer_key=?", reviewerKey(reviewerID))[0], now = this.#now();
    if (!row || row.session_key !== sessionKey || row.inspection_key !== inspectionKey(inspectionID) || !unverified && row.verified !== 1 ||
        !Number.isSafeInteger(row.created_at) || row.created_at < 0 || row.created_at > now || !Number.isSafeInteger(row.expires_at) ||
        row.expires_at <= now || row.expires_at > row.created_at + 90000 || typeof row.content !== "string" || row.content.length > 4096) fail("REPORT_REVIEW_STALE");
    let content; try { content = JSON.parse(row.content); } catch { fail(); }
    if (reportReviewContentHash(content) !== row.content_hash || content.reportID !== row.report_id) fail();
    this.#currentReport(content); return { ...row, content: Object.freeze(content) };
  }
  get(reviewerID, sessionKey, inspectionID) { return this.#tx(() => this.#receipt(reviewerID, sessionKey, inspectionID)); }
  async reserve(reviewerID, sessionKey, content) {
    if (!id(reviewerID) || !hash(sessionKey)) fail("REPORT_REVIEW_INPUT");
    const contentHash = reportReviewContentHash(content), inspectionID = randomUUID(), key = reviewerKey(reviewerID);
    this.#tx(() => {
      const now = this.#now(), window = Math.floor(now / 60000); this.#currentReport(content);
      if (this.#decision(content.reportID)) fail("REPORT_REVIEW_STALE");
      const old = this.#rows("SELECT * FROM community_report_inspections_v1 WHERE reviewer_key=?", key)[0];
      if (old?.created_at > now || !Number.isSafeInteger(now + 90000)) fail();
      const budget = this.#rows("SELECT * FROM community_report_review_budgets_v1 WHERE reviewer_key=?", key)[0], budgetExpiry = (window + 2) * 60000;
      if (!Number.isSafeInteger(budgetExpiry) || budget && (!Number.isSafeInteger(budget.window) || budget.window < 0 || budget.window > window ||
          !Number.isSafeInteger(budget.count) || budget.count < 1 || budget.count > 10 || budget.expires_at !== (budget.window + 2) * 60000)) fail();
      const count = budget?.window === window ? budget.count : 0;
      if (!Number.isSafeInteger(count) || count < 0 || count >= 10) fail("REPORT_REVIEW_CAPACITY");
      this.#storage.sql.exec("DELETE FROM community_report_inspections_v1 WHERE expires_at<=?", now);
      this.#storage.sql.exec("DELETE FROM community_report_review_budgets_v1 WHERE expires_at<=?", now);
      if (!old && this.#rows("SELECT reviewer_key FROM community_report_inspections_v1 LIMIT 256").length >= 256) fail("REPORT_REVIEW_CAPACITY");
      if (!budget && this.#rows("SELECT reviewer_key FROM community_report_review_budgets_v1 LIMIT 256").length >= 256) fail("REPORT_REVIEW_CAPACITY");
      this.#storage.sql.exec(`INSERT INTO community_report_review_budgets_v1 VALUES(?,?,?,?) ON CONFLICT(reviewer_key) DO UPDATE SET
        window=excluded.window,count=excluded.count,expires_at=excluded.expires_at`, key, window, count + 1, budgetExpiry);
      this.#storage.sql.exec(`INSERT INTO community_report_inspections_v1 VALUES(?,?,?,?,?,?,?,?,0) ON CONFLICT(reviewer_key) DO UPDATE SET
        session_key=excluded.session_key,inspection_key=excluded.inspection_key,report_id=excluded.report_id,content=excluded.content,content_hash=excluded.content_hash,
        created_at=excluded.created_at,expires_at=excluded.expires_at,verified=0`,
      key, sessionKey, inspectionKey(inspectionID), content.reportID, JSON.stringify(content), contentHash, now, Math.min(now + 90000, content.reportExpiresAt));
    });
    await this.#durable(); const row = this.#tx(() => this.#receipt(reviewerID, sessionKey, inspectionID, true));
    return Object.freeze({ inspectionID, expiresAt: row.expires_at, contentHash });
  }
  async confirm(reviewerID, sessionKey, inspectionID) {
    this.#tx(() => { const row = this.#receipt(reviewerID, sessionKey, inspectionID, true);
      this.#storage.sql.exec("UPDATE community_report_inspections_v1 SET verified=1 WHERE reviewer_key=?", row.reviewer_key); });
    await this.#durable(); this.get(reviewerID, sessionKey, inspectionID);
  }
  async decide({ reviewerID, sessionKey, inspectionID, decisionID, verdict, content, authorize } = {}) {
    if (!id(decisionID) || !verdicts.has(verdict) || typeof authorize !== "function") fail("REPORT_REVIEW_INPUT");
    const contentHash = reportReviewContentHash(content);
    // Authorization may itself use a transaction. No await separates this synchronous check from our transaction.
    const permitted = authorize();
    if (permitted && typeof permitted.then === "function") { void Promise.resolve(permitted).catch(() => {}); fail("REPORT_REVIEW_SCOPE"); }
    if (permitted !== true) fail("REPORT_REVIEW_SCOPE");
    const result = this.#tx(() => {
      const receipt = this.#receipt(reviewerID, sessionKey, inspectionID);
      if (receipt.content_hash !== contentHash) fail("REPORT_REVIEW_STALE");
      const previous = this.#decision(content.reportID);
      if (previous) {
        if (previous.decision_id !== decisionID || previous.verdict !== verdict || previous.reviewer_key !== reviewerKey(reviewerID) || previous.content_hash !== contentHash) fail("REPORT_REVIEW_STALE");
        return { reportID: content.reportID, decisionID, verdict, contentHash, revision: previous.revision };
      }
      if (this.#rows("SELECT report_id FROM community_report_decisions_v1 WHERE decision_id=?", decisionID).length) fail("REPORT_REVIEW_STALE");
      if (verdict === "hide_message") {
        if (content.messageTag === null || content.messageExpiresAt <= this.#now()) fail("REPORT_REVIEW_STALE");
        const target = this.#rows(`SELECT p.*,a.disabled,r.state AS retention_state FROM public_records_v1 p
          JOIN auth_accounts_v1 a ON a.account_id=p.account_id LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name
          WHERE p.record_name=?`, content.messageID)[0];
        if (!target || target.kind !== "message" || target.phase !== "settled" || target.disabled || target.record_tag !== content.messageTag ||
            target.payload_hash !== content.messageHash || target.request_id !== content.messageRequestID || target.account_id !== content.messageAccountID ||
            target.created_at + 7200000 !== content.messageExpiresAt || target.retention_state !== null && target.retention_state !== "pending") fail("REPORT_REVIEW_STALE");
        const policy = this.#rows("SELECT * FROM community_intents_v1 WHERE account_id=? AND kind='message' AND logical_id=? AND request_id=?", content.messageAccountID, content.messageRequestID, content.messageRequestID)[0];
        if (!policy || policy.payload_hash !== content.messageHash || policy.ready !== 1 || policy.active !== 1) fail("REPORT_REVIEW_STALE");
        this.#storage.sql.exec("UPDATE community_intents_v1 SET hidden=1 WHERE account_id=? AND kind='message' AND logical_id=? AND request_id=?", content.messageAccountID, content.messageRequestID, content.messageRequestID);
      }
      const revision = randomUUID(), now = this.#now();
      this.#storage.sql.exec("INSERT INTO community_report_decisions_v1 VALUES(?,?,?,?,?,?,?,?,?,?)", content.reportID, content.reportTag, content.reportHash,
        contentHash, reviewerKey(reviewerID), decisionID, verdict, revision, now, content.reportExpiresAt);
      return { reportID: content.reportID, decisionID, verdict, contentHash, revision };
    });
    await this.#durable(); return Object.freeze(result);
  }
  outcome({ reviewerID, reportID, decisionID, verdict, contentHash } = {}) {
    if (!id(reviewerID) || !reportName(reportID) || !id(decisionID) || !verdicts.has(verdict) || !hash(contentHash)) fail("REPORT_REVIEW_INPUT");
    return this.#tx(() => {
      const context = this.#rows("SELECT * FROM public_records_v1 WHERE record_name=? AND phase='settled'", reportID)[0];
      if (!context) fail("REPORT_REVIEW_STALE");
      this.#currentReport({ reportID, reportTag: context.record_tag, reportHash: context.payload_hash, reportRequestID: context.request_id, reportExpiresAt: context.started_at + 2592000000 });
      const row = this.#decision(reportID);
      if (row && (row.report_tag !== context.record_tag || row.report_hash !== context.payload_hash)) fail("REPORT_REVIEW_STALE");
      const matched = row && row.reviewer_key === reviewerKey(reviewerID) && row.decision_id === decisionID && row.verdict === verdict && row.content_hash === contentHash;
      return Object.freeze({ reportID, decisionID, verdict, contentHash, outcome: !row ? "not-applied" : matched ? "confirmed" : "superseded", revision: matched ? row.revision : null });
    });
  }
  async recover(options) {
    this.outcome(options); await this.#durable(); return this.outcome(options);
  }
}

const maintenanceTables = [["community_report_inspections_v1", "reviewer_key", 256], ["community_report_decisions_v1", "report_id", 100]];
function maintenanceContext(storage, clock) {
  const now = clock(); if (!Number.isSafeInteger(now) || now < 0) fail();
  const count = storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('community_report_inspections_v1','community_report_decisions_v1','community_report_review_budgets_v1')").toArray().length;
  if (count !== 0 && count !== 3) fail();
  return { now, installed: count === 3 };
}
const joined = table => `${table} x LEFT JOIN public_records_v1 p ON p.record_name=x.report_id
  LEFT JOIN auth_accounts_v1 a ON a.account_id=p.account_id LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name`;
const expired = `x.expires_at<=? OR p.record_name IS NULL OR p.kind!='report' OR p.phase!='settled' OR a.account_id IS NULL OR a.disabled!=0
  OR p.started_at+2592000000<=? OR (r.state IS NOT NULL AND r.state!='pending')`;
/** Bounded local metadata cleanup, including account erasure; never contacts a provider or unhides a message. */
export async function purgeCommunityReportReviews(storage, clock = Date.now) {
  try {
    const { now, installed } = maintenanceContext(storage, clock); if (!installed) return;
    storage.transactionSync(() => {
      for (const [table, key, maximum] of maintenanceTables) storage.sql.exec(`DELETE FROM ${table} WHERE ${key} IN
        (SELECT x.${key} FROM ${joined(table)} WHERE ${expired} ORDER BY x.expires_at,x.${key} LIMIT ${maximum})`, now, now);
      storage.sql.exec("DELETE FROM community_report_review_budgets_v1 WHERE expires_at<=?", now);
    });
    await storage.sync();
  } catch { fail(); }
}
export function communityReportReviewWakeAt(storage, clock = Date.now) {
  try {
    const { now, installed } = maintenanceContext(storage, clock); if (!installed) return null;
    const values = maintenanceTables.map(([table]) => {
      if (storage.sql.exec(`SELECT 1 FROM ${joined(table)} WHERE ${expired} LIMIT 1`, now, now).toArray().length) return now;
      return storage.sql.exec(`SELECT MIN(expires_at) AS value FROM ${table}`).toArray()[0].value;
    });
    values.push(storage.sql.exec("SELECT MIN(expires_at) AS value FROM community_report_review_budgets_v1").toArray()[0].value);
    const pending = values.filter(value => value !== null);
    if (pending.some(value => !Number.isSafeInteger(value) || value < 0)) fail();
    return pending.length ? Math.min(...pending) : null;
  } catch { fail(); }
}
