import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { CommunityReportReviewError, reportReviewContent, reportReviewContentHash } from "./community-report-review-state.mjs";
export { CommunityReportReviewError } from "./community-report-review-state.mjs";

const reportName = /^community-v1-report-[a-f0-9]{64}$/;
const messageName = /^community-v1-message-[a-f0-9]{64}$/;
const fail = code => { throw new CommunityReportReviewError(code); };
const sync = value => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail("REPORT_REVIEW_SCOPE"); } return value; };

/** Trusted moderation boundary. Separate operator predicate; no installed HTTP/runtime activation. */
export class CommunityReportReview {
  #pending = new Set();
  #authentication; #community; #registry; #repository; #client; #reviews; #checkpoint; #enabled; #operator; #clock; #monotonic; #timeout; #busy = false;
  constructor({ authentication, communityState, registry, repository, client, reviews, checkpoint, isEnabled = () => false, isOperator = () => false,
    clock = Date.now, monotonic = () => performance.now(), timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        typeof registry?.reviewReportPage !== "function" || typeof registry?.readable !== "function" || typeof repository?.beginRead !== "function" || typeof client?.waitForPendingOperations !== "function" ||
        ["isOpen", "reserve", "confirm", "get", "decide", "recover", "outcome"].some(name => typeof reviews?.[name] !== "function") ||
        ["verify", "advance"].some(name => typeof checkpoint?.[name] !== "function") ||
        [isEnabled, isOperator, clock, monotonic].some(value => typeof value !== "function") ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) fail("REPORT_REVIEW_INPUT");
    this.#authentication = authentication; this.#community = communityState; this.#registry = registry; this.#repository = repository; this.#client = client;
    this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#operator = isOperator; this.#clock = clock; this.#monotonic = monotonic; this.#timeout = timeoutMilliseconds;
    this.#reviews = reviews;
  }
  get isOccupied() { return this.#busy; }
  async waitForPendingOperations() { await Promise.allSettled([...this.#pending]); }
  #options(value, keys) {
    if (!plain(value) || Object.keys(value).some(key => !["accessToken", "signal", ...keys].includes(key)) ||
        typeof value.accessToken !== "string" || value.accessToken.length < 1 || value.accessToken.length > 1024 ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) fail("REPORT_REVIEW_INPUT");
    return Object.freeze({ ...value });
  }
  #identity(o, expected) {
    const identity = sync(this.#authentication.authorize(o.accessToken));
    if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || sync(this.#operator(identity.accountID)) !== true) fail("REPORT_REVIEW_SCOPE");
    sync(this.#community.assertActive(identity.accountID));
    const current = { accountID: identity.accountID, sessionKey: digest("echoes/report-review-session/v1\0" + o.accessToken) };
    if (expected && (expected.accountID !== current.accountID || expected.sessionKey !== current.sessionKey)) fail("REPORT_REVIEW_SCOPE");
    return current;
  }
  #error(error) {
    if (error instanceof CommunityReportReviewError) return error;
    if (["INVALID_SESSION", "COMMUNITY_STALE", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS"].includes(error?.code)) return new CommunityReportReviewError("REPORT_REVIEW_SCOPE");
    return new CommunityReportReviewError();
  }
  async #prepare(o, action) {
    if (this.#busy) fail("REPORT_REVIEW_CAPACITY");
    this.#busy = true;
    let closed = false, settled = false, released = false, prepared, identity, timer, rejectCancelled, floorWall, floorMono;
    const controller = new AbortController();
    const release = () => { if (closed && settled && !released) { released = true; this.#busy = false; } };
    const close = () => { closed = true; prepared = undefined; clearTimeout(timer); controller.abort(); o.signal?.removeEventListener("abort", cancel); release(); };
    const cancel = () => { close(); rejectCancelled(new CommunityReportReviewError()); };
    const cancelled = new Promise((_, reject) => { rejectCancelled = reject; });
    try {
      const startedAt = floorWall = this.#clock(), startedMono = floorMono = this.#monotonic();
      const transport = () => {
        const wall = this.#clock(), mono = this.#monotonic();
        if (closed || controller.signal.aborted || o.signal?.aborted || sync(this.#enabled()) !== true ||
            !Number.isSafeInteger(wall) || wall < 0 || !Number.isFinite(mono) || wall < floorWall || mono < floorMono ||
            wall - startedAt >= this.#timeout || mono - startedMono >= this.#timeout) fail();
        floorWall = wall; floorMono = mono;
      };
      if (!Number.isSafeInteger(startedAt) || startedAt < 0 || !Number.isFinite(startedMono)) fail();
      timer = setTimeout(cancel, this.#timeout); o.signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        try {
          transport(); identity = this.#identity(o);
          const check = () => { transport(); this.#identity(o, identity); transport(); };
          const result = await action({ identity, check, signal: controller.signal }); check(); prepared = result;
        } finally { await this.#client.waitForPendingOperations(); settled = true; release(); }
      })();
      this.#pending.add(work); void work.then(() => this.#pending.delete(work), () => this.#pending.delete(work));
      await Promise.race([work, cancelled]);
      return () => { try { transport(); this.#identity(o, identity); return prepared(); } catch (error) { throw this.#error(error); } finally { close(); } };
    } catch (error) { close(); if (!timer) { settled = true; release(); } throw this.#error(error); }
  }
  async prepareQueue(value) {
    const o = this.#options(value, ["after"]);
    if (o.after !== undefined && o.after !== null && (typeof o.after !== "string" || !reportName.test(o.after))) fail("REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      const page = this.#registry.reviewReportPage(o.after ?? null); check();
      await this.#checkpoint.advance({ signal }); check();
      return () => ({ schemaVersion: 1, items: page.items.filter(item => {
        const row = this.#registry.readable(item.recordName, "report");
        return row?.recordTag === item.recordTag && row.payloadHash === item.payloadHash && row.requestID === item.requestID && this.#reviews.isOpen(row);
      }).map(item => ({ reportID: item.recordName, createdAt: item.createdAt, expiresAt: item.startedAt + 2592000000 })), after: page.after });
    });
  }
  async prepareInspection(value) {
    const o = this.#options(value, ["reportID"]);
    if (typeof o.reportID !== "string" || !reportName.test(o.reportID)) fail("REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
      const [report] = await lease.lookup([o.reportID], "report"); check();
      if (!report || !lease.current(report) || !messageName.test(report.input.messageID)) fail("REPORT_REVIEW_STALE");
      const [message] = await lease.lookup([report.input.messageID], "message"); check();
      if (!this.#reviews.isOpen(report.context)) fail("REPORT_REVIEW_STALE");
      const content = reportReviewContent(report, message && lease.current(message) ? message : null);
      const receipt = await this.#reviews.reserve(identity.accountID, identity.sessionKey, content); check();
      await this.#reviews.confirm(identity.accountID, identity.sessionKey, receipt.inspectionID); check();
      await this.#checkpoint.advance({ signal }); check();
      return () => {
        this.#reviews.get(identity.accountID, identity.sessionKey, receipt.inspectionID);
        if (!lease.current(report) || !this.#reviews.isOpen(report.context)) fail("REPORT_REVIEW_STALE");
        const current = message && lease.current(message) && message.record.fields.expiresAt.value > this.#clock();
        return { schemaVersion: 1, inspectionID: receipt.inspectionID, inspectionExpiresAt: receipt.expiresAt, contentHash: receipt.contentHash,
          reportID: report.context.recordName, createdAt: report.context.createdAt,
          expiresAt: report.context.startedAt + 2592000000, reason: report.input.reason, messageID: report.input.messageID,
          message: current ? { authorID: message.context.accountID, name: message.input.name, text: message.input.text,
            createdAt: message.context.createdAt, expiresAt: message.record.fields.expiresAt.value } : null };
      };
    });
  }
  async prepareDecision(value) {
    const o = this.#options(value, ["inspectionID", "decisionID", "verdict"]);
    if (![o.inspectionID, o.decisionID].every(v => typeof v === "string" && publicUUID.test(v)) || !["dismiss", "hide_message"].includes(o.verdict)) fail("REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      const receipt = this.#reviews.get(identity.accountID, identity.sessionKey, o.inspectionID);
      const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
      const [report] = await lease.lookup([receipt.content.reportID], "report"); check();
      if (!report || !lease.current(report)) fail("REPORT_REVIEW_STALE");
      const [message] = await lease.lookup([report.input.messageID], "message"); check();
      const content = reportReviewContent(report, message && lease.current(message) ? message : null);
      if (reportReviewContentHash(content) !== receipt.content_hash) fail("REPORT_REVIEW_STALE");
      const authorize = () => { check(); if (!lease.current(report) || message && !lease.current(message)) fail("REPORT_REVIEW_STALE"); return true; };
      let result;
      try { result = await this.#reviews.decide({ reviewerID: identity.accountID, sessionKey: identity.sessionKey,
        inspectionID: o.inspectionID, decisionID: o.decisionID, verdict: o.verdict, content, authorize }); }
      catch (error) { check(); await this.#checkpoint.advance({ signal }); throw error; }
      check(); await this.#checkpoint.advance({ signal }); check();
      const query = { reviewerID: identity.accountID, reportID: content.reportID, decisionID: o.decisionID, verdict: o.verdict, contentHash: receipt.content_hash };
      return () => {
        const outcome = this.#reviews.outcome(query);
        if (outcome.outcome !== "confirmed" || outcome.revision !== result.revision) fail("REPORT_REVIEW_STALE");
        return { schemaVersion: 1, inspectionID: o.inspectionID, ...result };
      };
    });
  }
  async prepareRecovery(value) {
    const keys = ["reportID", "decisionID", "verdict", "contentHash"], o = this.#options(value, keys);
    if (!reportName.test(o.reportID ?? "") || !publicUUID.test(o.decisionID ?? "") || !["dismiss", "hide_message"].includes(o.verdict) ||
        typeof o.contentHash !== "string" || !/^[a-f0-9]{64}$/.test(o.contentHash)) fail("REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      const query = { ...Object.fromEntries(keys.map(k => [k, o[k]])), reviewerID: identity.accountID };
      const result = await this.#reviews.recover(query); check();
      await this.#checkpoint.advance({ signal }); check();
      return () => { const latest = this.#reviews.outcome(query);
        if (latest.outcome !== result.outcome || latest.revision !== result.revision) fail("REPORT_REVIEW_STALE");
        return { schemaVersion: 1, ...latest };
      };
    });
  }
}
