import { ModerationRetirementError, moderationRetirementSchema, readModerationRetirement, createModerationRetirement } from "./moderation-decision-retirements.mjs";
import { avatarDescriptor, avatarDescriptorHash } from "./avatar-record-schema.mjs";
import { randomUUID } from "node:crypto";
import { plain, publicUUID, validTag, digest, recordIdentity, inputHash } from "./public-record-schema.mjs";

const codes = new Set(["AVATAR_REPORT_REVIEW_INPUT", "AVATAR_REPORT_REVIEW_SCOPE", "AVATAR_REPORT_REVIEW_STALE", "AVATAR_REPORT_REVIEW_CAPACITY", "AVATAR_REPORT_REVIEW_RESPONSE", "AVATAR_REPORT_REVIEW_UNAVAILABLE"]);
export class AvatarReportReviewError extends Error {
  constructor(code = "AVATAR_REPORT_REVIEW_UNAVAILABLE") { super("Confidential report review could not be completed."); this.code = codes.has(code) ? code : "AVATAR_REPORT_REVIEW_UNAVAILABLE"; }
}
const fail = code => { throw new AvatarReportReviewError(code); };
const id = value => typeof value === "string" && publicUUID.test(value);
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const reportName = value => typeof value === "string" && /^community-v1-avatarreport-[a-f0-9]{64}$/.test(value);
const avatarName = value => typeof value === "string" && /^community-v1-avatar-[a-f0-9]{64}$/.test(value);
const verdicts = new Set(["dismiss", "hide_photo"]);
const reviewerKey = value => digest("echoes/avatar-report-reviewer/v1\0" + value);
const inspectionKey = value => digest("echoes/avatar-report-inspection/v1\0" + value);
const fields = ["reportID", "reportTag", "reportHash", "reportRequestID", "reportExpiresAt", "avatarID", "versionID", "publicationGeneration", "imageSHA256",
  "accountID", "requestID", "reviewRevision", "avatarTag", "avatarHash", "pointerTag"];
const targetFields = ["accountID", "requestID", "reviewRevision", "avatarTag", "avatarHash", "pointerTag"];
function validContent(c) {
  return plain(c) && Object.keys(c).sort().join() === [...fields].sort().join() && reportName(c.reportID) && validTag(c.reportTag) && hash(c.reportHash) &&
    id(c.reportRequestID) && Number.isSafeInteger(c.reportExpiresAt) && c.reportExpiresAt >= 0 && avatarName(c.avatarID) && id(c.versionID) &&
    Number.isSafeInteger(c.publicationGeneration) && c.publicationGeneration > 0 && c.publicationGeneration < Number.MAX_SAFE_INTEGER && hash(c.imageSHA256) &&
    (c.accountID === null ? targetFields.every(k => c[k] === null) : id(c.accountID) && id(c.requestID) && id(c.reviewRevision) &&
      validTag(c.avatarTag) && hash(c.avatarHash) && validTag(c.pointerTag) && recordIdentity(c.accountID, "avatar", c.versionID).recordName === c.avatarID);
}
/** Metadata only. A future trusted coordinator supplies a validated exact publication after protected image IO.
 * A null publication permits dismissal only; it never authorizes hiding a replacement photo. */
export function avatarReportReviewContent(report, publication) {
  const c = { reportID: report.context.recordName, reportTag: report.context.recordTag, reportHash: report.context.payloadHash,
    reportRequestID: report.context.requestID, reportExpiresAt: report.context.startedAt + 2592000000,
    avatarID: report.input.avatarID, versionID: report.input.versionID, publicationGeneration: report.input.publicationGeneration, imageSHA256: report.input.imageSHA256,
    accountID: publication?.accountID ?? null, requestID: publication?.requestID ?? null, reviewRevision: publication?.reviewRevision ?? null,
    avatarTag: publication?.stagedTag ?? null, avatarHash: publication?.payloadHash ?? null, pointerTag: publication?.pointerTag ?? null };
  if (!validContent(c) || publication && (publication.avatar.recordName !== c.avatarID || publication.versionID !== c.versionID ||
      publication.generation !== c.publicationGeneration || publication.descriptor.image.sha256 !== c.imageSHA256 ||
      publication.avatar.recordTag !== c.avatarTag || publication.pointer.recordTag !== c.pointerTag)) fail("AVATAR_REPORT_REVIEW_STALE");
  return Object.freeze(c);
}
export function avatarReportReviewContentHash(c) {
  if (!validContent(c)) fail("AVATAR_REPORT_REVIEW_INPUT");
  return digest(JSON.stringify(fields.map(name => c[name])));
}
const schema = [
  ...moderationRetirementSchema("photo"),
  `CREATE TABLE IF NOT EXISTS avatar_report_inspections_v1(reviewer_key TEXT PRIMARY KEY,session_key TEXT NOT NULL,
    inspection_key TEXT NOT NULL,report_id TEXT NOT NULL,content TEXT NOT NULL,content_hash TEXT NOT NULL,target_owner TEXT,created_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,
    verified INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS avatar_report_inspection_expiry_v1 ON avatar_report_inspections_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS avatar_report_decisions_v1(report_id TEXT PRIMARY KEY,report_tag TEXT NOT NULL,report_hash TEXT NOT NULL,
    content_hash TEXT NOT NULL,reviewer_key TEXT NOT NULL,decision_id TEXT NOT NULL UNIQUE,verdict TEXT NOT NULL,revision TEXT NOT NULL,
    resolved_at INTEGER NOT NULL,expires_at INTEGER NOT NULL,target_owner TEXT)`,
  `CREATE INDEX IF NOT EXISTS avatar_report_decision_expiry_v1 ON avatar_report_decisions_v1(expires_at)`,
  `CREATE TABLE IF NOT EXISTS avatar_report_review_budgets_v1(reviewer_key TEXT PRIMARY KEY,window INTEGER NOT NULL,count INTEGER NOT NULL,expires_at INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS avatar_report_budget_expiry_v1 ON avatar_report_review_budgets_v1(expires_at)`,
];

/** Private metadata only. A decision and its exact photo policy effect share the SAME SQLite transaction. */
export class AvatarReportReviewState {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.transactionSync !== "function" || typeof storage.sync !== "function" || typeof storage.sql?.exec !== "function" || typeof clock !== "function") fail("AVATAR_REPORT_REVIEW_INPUT");
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => { for (const statement of schema) storage.sql.exec(statement); });
  }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (error) { if (error instanceof ModerationRetirementError) throw new AvatarReportReviewError(error.code === "CONFLICT" ? "AVATAR_REPORT_REVIEW_STALE" : error.code === "CAPACITY" ? "AVATAR_REPORT_REVIEW_CAPACITY" : undefined); throw error instanceof AvatarReportReviewError ? error : new AvatarReportReviewError(); } }
  #now() { const n = this.#clock(); if (!Number.isSafeInteger(n) || n < 0) fail(); return n; }
  async #durable() { try { await this.#storage.sync(); } catch { fail(); } }
  #decision(reportID) {
    if (!reportName(reportID)) fail("AVATAR_REPORT_REVIEW_INPUT");
    const row = this.#rows("SELECT * FROM avatar_report_decisions_v1 WHERE report_id=?", reportID)[0];
    if (row && (!validTag(row.report_tag) || ![row.report_hash, row.content_hash, row.reviewer_key].every(hash) ||
        !id(row.decision_id) || !id(row.revision) || row.target_owner !== null && !id(row.target_owner) || !verdicts.has(row.verdict) || !Number.isSafeInteger(row.resolved_at) || row.resolved_at < 0 ||
        !Number.isSafeInteger(row.expires_at) || row.expires_at <= row.resolved_at || row.resolved_at > this.#now())) fail();
    return row;
  }
  #currentReport(c) {
    const row = this.#rows(`SELECT p.*,a.disabled FROM public_records_v1 p JOIN auth_accounts_v1 a ON a.account_id=p.account_id WHERE p.record_name=?`, c.reportID)[0], now = this.#now();
    if (!row || row.kind !== "avatarreport" || row.phase !== "settled" || row.disabled || row.avatar_report_cancel_key !== null || row.request_id !== c.reportRequestID || row.record_tag !== c.reportTag ||
        row.payload_hash !== c.reportHash || row.started_at > now || row.started_at + 2592000000 !== c.reportExpiresAt || c.reportExpiresAt <= now) fail("AVATAR_REPORT_REVIEW_STALE");
    const retention = this.#rows("SELECT state FROM public_retention_v1 WHERE record_name=?", c.reportID)[0];
    if (retention && retention.state !== "pending") fail("AVATAR_REPORT_REVIEW_STALE");
  }
  isOpen(context) {
    return this.#tx(() => {
      try { this.#currentReport({ reportID: context.recordName, reportTag: context.recordTag, reportHash: context.payloadHash,
        reportRequestID: context.requestID, reportExpiresAt: context.startedAt + 2592000000 }); }
      catch (error) { if (error?.code === "AVATAR_REPORT_REVIEW_STALE") return false; throw error; }
      const row = this.#decision(context.recordName);
      if (row && (row.report_tag !== context.recordTag || row.report_hash !== context.payloadHash)) fail("AVATAR_REPORT_REVIEW_STALE");
      return !row;
    });
  }
  #activeReviewer(reviewerID) {
    if (!id(reviewerID)) fail("AVATAR_REPORT_REVIEW_INPUT");
    const actor = this.#rows(`SELECT a.disabled,COALESCE(c.suspended,0) AS suspended FROM auth_accounts_v1 a
      LEFT JOIN community_accounts_v1 c ON c.account_id=a.account_id WHERE a.account_id=?`, reviewerID)[0];
    if (!actor || actor.disabled || actor.suspended) fail("AVATAR_REPORT_REVIEW_SCOPE");
  }
  #receipt(reviewerID, sessionKey, inspectionID, unverified = false) {
    if (!id(reviewerID) || !hash(sessionKey) || !id(inspectionID)) fail("AVATAR_REPORT_REVIEW_INPUT");
    this.#activeReviewer(reviewerID);
    const row = this.#rows("SELECT * FROM avatar_report_inspections_v1 WHERE reviewer_key=?", reviewerKey(reviewerID))[0], now = this.#now();
    if (!row || row.session_key !== sessionKey || row.inspection_key !== inspectionKey(inspectionID) || !unverified && row.verified !== 1 ||
        !Number.isSafeInteger(row.created_at) || row.created_at < 0 || row.created_at > now || !Number.isSafeInteger(row.expires_at) ||
        row.expires_at <= now || row.expires_at > row.created_at + 90000 || typeof row.content !== "string" || row.content.length > 4096) fail("AVATAR_REPORT_REVIEW_STALE");
    let content; try { content = JSON.parse(row.content); } catch { fail(); }
    if (avatarReportReviewContentHash(content) !== row.content_hash || content.reportID !== row.report_id || content.accountID !== row.target_owner || ![0, 1].includes(row.verified)) fail();
    this.#currentReport(content); return { ...row, content: Object.freeze(content) };
  }
  get(reviewerID, sessionKey, inspectionID) { return this.#tx(() => this.#receipt(reviewerID, sessionKey, inspectionID)); }
  /** Trusted coordinator guard during protected IO; this never authorizes a decision. */
  getReserved(reviewerID, sessionKey, inspectionID) { return this.#tx(() => this.#receipt(reviewerID, sessionKey, inspectionID, true)); }
  async reserve(reviewerID, sessionKey, content) {
    if (!id(reviewerID) || !hash(sessionKey)) fail("AVATAR_REPORT_REVIEW_INPUT");
    const contentHash = avatarReportReviewContentHash(content), inspectionID = randomUUID(), key = reviewerKey(reviewerID);
    this.#tx(() => {
      const now = this.#now(), window = Math.floor(now / 60000); this.#activeReviewer(reviewerID); this.#currentReport(content);
      if (this.#decision(content.reportID)) fail("AVATAR_REPORT_REVIEW_STALE");
      const old = this.#rows("SELECT * FROM avatar_report_inspections_v1 WHERE reviewer_key=?", key)[0];
      if (old?.created_at > now || !Number.isSafeInteger(now + 90000)) fail();
      const budget = this.#rows("SELECT * FROM avatar_report_review_budgets_v1 WHERE reviewer_key=?", key)[0], budgetExpiry = (window + 2) * 60000;
      if (!Number.isSafeInteger(budgetExpiry) || budget && (!Number.isSafeInteger(budget.window) || budget.window < 0 || budget.window > window ||
          !Number.isSafeInteger(budget.count) || budget.count < 1 || budget.count > 10 || budget.expires_at !== (budget.window + 2) * 60000)) fail();
      const count = budget?.window === window ? budget.count : 0;
      if (!Number.isSafeInteger(count) || count < 0 || count >= 10) fail("AVATAR_REPORT_REVIEW_CAPACITY");
      this.#storage.sql.exec("DELETE FROM avatar_report_inspections_v1 WHERE expires_at<=?", now);
      this.#storage.sql.exec("DELETE FROM avatar_report_review_budgets_v1 WHERE expires_at<=?", now);
      if (!old && this.#rows("SELECT reviewer_key FROM avatar_report_inspections_v1 LIMIT 256").length >= 256) fail("AVATAR_REPORT_REVIEW_CAPACITY");
      if (!budget && this.#rows("SELECT reviewer_key FROM avatar_report_review_budgets_v1 LIMIT 256").length >= 256) fail("AVATAR_REPORT_REVIEW_CAPACITY");
      this.#storage.sql.exec(`INSERT INTO avatar_report_review_budgets_v1 VALUES(?,?,?,?) ON CONFLICT(reviewer_key) DO UPDATE SET
        window=excluded.window,count=excluded.count,expires_at=excluded.expires_at`, key, window, count + 1, budgetExpiry);
      this.#storage.sql.exec(`INSERT INTO avatar_report_inspections_v1 VALUES(?,?,?,?,?,?,?,?,?,0) ON CONFLICT(reviewer_key) DO UPDATE SET
        session_key=excluded.session_key,inspection_key=excluded.inspection_key,report_id=excluded.report_id,content=excluded.content,content_hash=excluded.content_hash,
        target_owner=excluded.target_owner,created_at=excluded.created_at,expires_at=excluded.expires_at,verified=0`,
      key, sessionKey, inspectionKey(inspectionID), content.reportID, JSON.stringify(content), contentHash, content.accountID, now, Math.min(now + 90000, content.reportExpiresAt));
    });
    await this.#durable(); const row = this.#tx(() => this.#receipt(reviewerID, sessionKey, inspectionID, true));
    return Object.freeze({ inspectionID, expiresAt: row.expires_at, contentHash });
  }
  async confirm(reviewerID, sessionKey, inspectionID) {
    this.#tx(() => { const row = this.#receipt(reviewerID, sessionKey, inspectionID, true);
      this.#storage.sql.exec("UPDATE avatar_report_inspections_v1 SET verified=1 WHERE reviewer_key=?", row.reviewer_key); });
    await this.#durable(); this.get(reviewerID, sessionKey, inspectionID);
  }
  async decide({ reviewerID, sessionKey, inspectionID, decisionID, verdict, content, authorize } = {}) {
    if (!id(decisionID) || !verdicts.has(verdict) || typeof authorize !== "function") fail("AVATAR_REPORT_REVIEW_INPUT");
    const contentHash = avatarReportReviewContentHash(content);
    // Authorization may itself use a transaction. No await separates this synchronous check from our transaction.
    let permitted; try { permitted = authorize(); } catch { fail("AVATAR_REPORT_REVIEW_SCOPE"); }
    if (permitted && typeof permitted.then === "function") { void Promise.resolve(permitted).catch(() => {}); fail("AVATAR_REPORT_REVIEW_SCOPE"); }
    if (permitted !== true) fail("AVATAR_REPORT_REVIEW_SCOPE");
    const result = this.#tx(() => {
      this.#activeReviewer(reviewerID);
      if (readModerationRetirement(this.#storage, "photo", { reviewerKey: reviewerKey(reviewerID), reportID: content.reportID, decisionID, verdict, contentHash }, this.#now())) fail("AVATAR_REPORT_REVIEW_STALE");
      const receipt = this.#receipt(reviewerID, sessionKey, inspectionID);
      if (receipt.content_hash !== contentHash) fail("AVATAR_REPORT_REVIEW_STALE");
      const previous = this.#decision(content.reportID);
      if (previous) {
        if (previous.decision_id !== decisionID || previous.verdict !== verdict || previous.reviewer_key !== reviewerKey(reviewerID) || previous.content_hash !== contentHash) fail("AVATAR_REPORT_REVIEW_STALE");
        return { reportID: content.reportID, decisionID, verdict, contentHash, revision: previous.revision };
      }
      if (this.#rows("SELECT report_id FROM avatar_report_decisions_v1 WHERE decision_id=?", decisionID).length) fail("AVATAR_REPORT_REVIEW_STALE");
      if (this.#rows("SELECT 1 FROM avatar_jobs_v1 WHERE decision_id=? LIMIT 1", decisionID).length) fail("AVATAR_REPORT_REVIEW_STALE");
      const revision = randomUUID(), now = this.#now();
      if (verdict === "hide_photo") {
        if (content.accountID === null) fail("AVATAR_REPORT_REVIEW_STALE");
        const target = this.#rows(`SELECT j.*,p.ready,p.pointer_tag,p.expired_at,p.updated_at,a.disabled,COALESCE(c.suspended,0) AS suspended
          FROM avatar_jobs_v1 j JOIN avatar_profiles_v1 p ON p.account_id=j.account_id AND p.request_id=j.request_id
          AND p.version_id=j.version_id AND p.generation=j.generation JOIN auth_accounts_v1 a ON a.account_id=j.account_id
          LEFT JOIN community_accounts_v1 c ON c.account_id=j.account_id WHERE j.account_id=? AND j.request_id=?`, content.accountID, content.requestID)[0];
        if (!target || target.disabled || target.suspended || target.ready !== 1 || target.expired_at !== null || target.updated_at > now ||
            target.version_id !== content.versionID || target.generation !== content.publicationGeneration || target.consent_version !== 1 ||
            target.staged_tag !== content.avatarTag || target.pointer_tag !== content.pointerTag || target.moderation_state !== "approved" ||
            target.moderation_revision !== content.reviewRevision) fail("AVATAR_REPORT_REVIEW_STALE");
        const raw = JSON.parse(target.descriptor_json);
        const descriptor = avatarDescriptor({ image: raw.image, thumbnail: raw.thumbnail, requestID: raw.requestID }, content.accountID);
        if (JSON.stringify(descriptor) !== target.descriptor_json) fail("AVATAR_REPORT_REVIEW_STALE");
        if (avatarDescriptorHash(descriptor) !== content.avatarHash || descriptor.image.sha256 !== content.imageSHA256 ||
            descriptor.image.versionID !== content.versionID || descriptor.requestID !== content.requestID) fail("AVATAR_REPORT_REVIEW_STALE");
        const pointerID = recordIdentity(content.accountID, "avatarprofile", "singleton").recordName;
        for (const [name, kind, tag, payloadHash] of [[content.avatarID, "avatar", content.avatarTag, content.avatarHash],
          [pointerID, "avatarprofile", content.pointerTag, inputHash({ versionID: content.versionID, generation: content.publicationGeneration })]]) {
          const record = this.#rows(`SELECT * FROM public_records_v1 WHERE record_name=?`, name)[0];
          if (!record || record.kind !== kind || record.phase !== "settled" || record.account_id !== content.accountID ||
              record.request_id !== content.requestID || record.record_tag !== tag || record.payload_hash !== payloadHash) fail("AVATAR_REPORT_REVIEW_STALE");
        }
        if (this.#rows("SELECT 1 FROM avatar_retirements_v1 WHERE record_name=? LIMIT 1", content.avatarID).length) fail("AVATAR_REPORT_REVIEW_STALE");
        this.#storage.sql.exec(`UPDATE avatar_jobs_v1 SET moderation_state='rejected',moderation_revision=?,decision_id=?,decision_expected_revision=?,reviewer_key=?,reviewed_at=?
          WHERE account_id=? AND request_id=?`, revision, decisionID, content.reviewRevision, digest(reviewerID), now, content.accountID, content.requestID);
        this.#storage.sql.exec("UPDATE avatar_profiles_v1 SET ready=0,pointer_tag=NULL WHERE account_id=?", content.accountID);
      }
      this.#storage.sql.exec("INSERT INTO avatar_report_decisions_v1 VALUES(?,?,?,?,?,?,?,?,?,?,?)", content.reportID, content.reportTag, content.reportHash,
        contentHash, reviewerKey(reviewerID), decisionID, verdict, revision, now, content.reportExpiresAt, content.accountID);
      return { reportID: content.reportID, decisionID, verdict, contentHash, revision };
    });
    await this.#durable(); return Object.freeze(result);
  }
  outcome({ reviewerID, reportID, decisionID, verdict, contentHash } = {}) {
    if (!id(reviewerID) || !reportName(reportID) || !id(decisionID) || !verdicts.has(verdict) || !hash(contentHash)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#tx(() => {
      this.#activeReviewer(reviewerID);
      if (readModerationRetirement(this.#storage, "photo", { reviewerKey: reviewerKey(reviewerID), reportID, decisionID, verdict, contentHash }, this.#now()))
        return Object.freeze({ reportID, decisionID, verdict, contentHash, outcome: "retired", revision: null });
      const context = this.#rows("SELECT * FROM public_records_v1 WHERE record_name=? AND phase='settled'", reportID)[0];
      if (!context) fail("AVATAR_REPORT_REVIEW_STALE");
      this.#currentReport({ reportID, reportTag: context.record_tag, reportHash: context.payload_hash, reportRequestID: context.request_id, reportExpiresAt: context.started_at + 2592000000 });
      const row = this.#decision(reportID);
      if (row && (row.report_tag !== context.record_tag || row.report_hash !== context.payload_hash)) fail("AVATAR_REPORT_REVIEW_STALE");
      const matched = row && row.reviewer_key === reviewerKey(reviewerID) && row.decision_id === decisionID && row.verdict === verdict && row.content_hash === contentHash;
      return Object.freeze({ reportID, decisionID, verdict, contentHash, outcome: !row ? "not-applied" : matched ? "confirmed" : "superseded", revision: matched ? row.revision : null });
    });
  }
  async retire({ reviewerID, reportID, decisionID, verdict, contentHash, authorize } = {}) {
    if (!id(reviewerID) || !reportName(reportID) || !id(decisionID) || !verdicts.has(verdict) || !hash(contentHash) || typeof authorize !== "function") fail("AVATAR_REPORT_REVIEW_INPUT");
    let permitted; try { permitted = authorize(); } catch { fail("AVATAR_REPORT_REVIEW_SCOPE"); }
    if (permitted && typeof permitted.then === "function") { void Promise.resolve(permitted).catch(() => {}); fail("AVATAR_REPORT_REVIEW_SCOPE"); }
    if (permitted !== true) fail("AVATAR_REPORT_REVIEW_SCOPE");
    const query = { reviewerKey: reviewerKey(reviewerID), reportID, decisionID, verdict, contentHash };
    const result = this.#tx(() => {
      this.#activeReviewer(reviewerID);
      if (readModerationRetirement(this.#storage, "photo", query, this.#now())) return { reportID, decisionID, verdict, contentHash, outcome: "retired", revision: null };
      const previous = this.#decision(reportID);
      if (previous) {
        const matched = previous.reviewer_key === query.reviewerKey && previous.decision_id === decisionID && previous.verdict === verdict && previous.content_hash === contentHash;
        return { reportID, decisionID, verdict, contentHash, outcome: matched ? "confirmed" : "superseded", revision: matched ? previous.revision : null };
      }
      if (this.#rows("SELECT report_id FROM avatar_report_decisions_v1 WHERE decision_id=?", decisionID).length) fail("AVATAR_REPORT_REVIEW_STALE");
      createModerationRetirement(this.#storage, "photo", query, this.#now());
      return { reportID, decisionID, verdict, contentHash, outcome: "retired", revision: null };
    });
    await this.#durable();
    const latest = this.outcome({ reviewerID, reportID, decisionID, verdict, contentHash });
    if (latest.outcome !== result.outcome || latest.revision !== result.revision) fail("AVATAR_REPORT_REVIEW_STALE");
    return Object.freeze(latest);
  }
  async recover(options) {
    this.outcome(options); await this.#durable(); return this.outcome(options);
  }
}

const maintenanceTables = [["avatar_report_inspections_v1", "reviewer_key", 256], ["avatar_report_decisions_v1", "report_id", 100]];
function maintenanceContext(storage, clock) {
  const now = clock(); if (!Number.isSafeInteger(now) || now < 0) fail();
  const count = storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('avatar_report_inspections_v1','avatar_report_decisions_v1','avatar_report_review_budgets_v1')").toArray().length;
  if (count !== 0 && count !== 3) fail();
  return { now, installed: count === 3 };
}
const joined = table => `${table} x LEFT JOIN public_records_v1 p ON p.record_name=x.report_id
  LEFT JOIN auth_accounts_v1 a ON a.account_id=p.account_id LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name`;
const expired = `x.expires_at<=? OR p.record_name IS NULL OR p.kind!='avatarreport' OR p.phase!='settled' OR p.avatar_report_cancel_key IS NOT NULL OR a.account_id IS NULL OR a.disabled!=0
  OR p.started_at+2592000000<=? OR (r.state IS NOT NULL AND r.state!='pending')`;
/** Bounded local metadata cleanup, including account erasure; never contacts a provider or re-publishes a photo. */
export async function purgeAvatarReportReviews(storage, clock = Date.now) {
  try {
    const { now, installed } = maintenanceContext(storage, clock); if (!installed) return;
    storage.transactionSync(() => {
      for (const [table, key, maximum] of maintenanceTables) storage.sql.exec(`DELETE FROM ${table} WHERE ${key} IN
        (SELECT x.${key} FROM ${joined(table)} WHERE ${expired} ORDER BY x.expires_at,x.${key} LIMIT ${maximum})`, now, now);
      storage.sql.exec("DELETE FROM avatar_report_review_budgets_v1 WHERE expires_at<=?", now);
    });
    await storage.sync();
  } catch { fail(); }
}
export function avatarReportReviewWakeAt(storage, clock = Date.now) {
  try {
    const { now, installed } = maintenanceContext(storage, clock); if (!installed) return null;
    const values = maintenanceTables.map(([table]) => {
      if (storage.sql.exec(`SELECT 1 FROM ${joined(table)} WHERE ${expired} LIMIT 1`, now, now).toArray().length) return now;
      return storage.sql.exec(`SELECT MIN(expires_at) AS value FROM ${table}`).toArray()[0].value;
    });
    values.push(storage.sql.exec("SELECT MIN(expires_at) AS value FROM avatar_report_review_budgets_v1").toArray()[0].value);
    const pending = values.filter(value => value !== null);
    if (pending.some(value => !Number.isSafeInteger(value) || value < 0)) fail();
    return pending.length ? Math.min(...pending) : null;
  } catch { fail(); }
}

/** Called synchronously inside the existing disabled-owner erasure transaction. No provider IO. */
export function eraseAvatarReportReviews(storage, accountID) {
  if (!id(accountID)) fail("AVATAR_REPORT_REVIEW_INPUT");
  const count = storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('avatar_report_inspections_v1','avatar_report_decisions_v1','avatar_report_review_budgets_v1')").toArray().length;
  if (count === 0) return;
  if (count !== 3) fail();
  for (const table of ["avatar_report_inspections_v1", "avatar_report_decisions_v1"]) storage.sql.exec(`DELETE FROM ${table}
    WHERE reviewer_key=? OR target_owner=? OR report_id IN (SELECT record_name FROM public_records_v1 WHERE account_id=? AND kind='avatarreport')`, reviewerKey(accountID), accountID, accountID);
  storage.sql.exec("DELETE FROM avatar_report_review_budgets_v1 WHERE reviewer_key=?", reviewerKey(accountID));
}
