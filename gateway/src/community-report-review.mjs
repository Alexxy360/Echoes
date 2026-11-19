import { plain, publicUUID, digest } from "./public-record-schema.mjs";

const reportName = /^community-v1-report-[a-f0-9]{64}$/;
const messageName = /^community-v1-message-[a-f0-9]{64}$/;
const codes = new Set(["REPORT_REVIEW_INPUT", "REPORT_REVIEW_SCOPE", "REPORT_REVIEW_STALE", "REPORT_REVIEW_CAPACITY", "REPORT_REVIEW_UNAVAILABLE"]);
export class CommunityReportReviewError extends Error {
  constructor(code = "REPORT_REVIEW_UNAVAILABLE") { super("Confidential report review could not be completed."); this.code = codes.has(code) ? code : "REPORT_REVIEW_UNAVAILABLE"; }
}
const fail = code => { throw new CommunityReportReviewError(code); };
const sync = value => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail("REPORT_REVIEW_SCOPE"); } return value; };

/** Trusted, read-only moderation boundary. Separate operator predicate; no installed HTTP/runtime activation. */
export class CommunityReportReview {
  #authentication; #community; #registry; #repository; #client; #checkpoint; #enabled; #operator; #clock; #monotonic; #timeout; #busy = false;
  constructor({ authentication, communityState, registry, repository, client, checkpoint, isEnabled = () => false, isOperator = () => false,
    clock = Date.now, monotonic = () => performance.now(), timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        typeof registry?.reviewReportPage !== "function" || typeof registry?.readable !== "function" || typeof repository?.beginRead !== "function" || typeof client?.waitForPendingOperations !== "function" ||
        ["verify", "advance"].some(name => typeof checkpoint?.[name] !== "function") ||
        [isEnabled, isOperator, clock, monotonic].some(value => typeof value !== "function") ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) fail("REPORT_REVIEW_INPUT");
    this.#authentication = authentication; this.#community = communityState; this.#registry = registry; this.#repository = repository; this.#client = client;
    this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#operator = isOperator; this.#clock = clock; this.#monotonic = monotonic; this.#timeout = timeoutMilliseconds;
  }
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
          const result = await action({ check, signal: controller.signal }); check(); prepared = result;
        } finally { await this.#client.waitForPendingOperations(); settled = true; release(); }
      })();
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
        return row?.recordTag === item.recordTag && row.payloadHash === item.payloadHash && row.requestID === item.requestID;
      }).map(item => ({ reportID: item.recordName, createdAt: item.createdAt, expiresAt: item.startedAt + 2592000000 })), after: page.after });
    });
  }
  async prepareInspection(value) {
    const o = this.#options(value, ["reportID"]);
    if (typeof o.reportID !== "string" || !reportName.test(o.reportID)) fail("REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ check, signal }) => {
      const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
      const [report] = await lease.lookup([o.reportID], "report"); check();
      if (!report || !lease.current(report) || !messageName.test(report.input.messageID)) fail("REPORT_REVIEW_STALE");
      const [message] = await lease.lookup([report.input.messageID], "message"); check();
      await this.#checkpoint.advance({ signal }); check();
      return () => {
        if (!lease.current(report)) fail("REPORT_REVIEW_STALE");
        const current = message && lease.current(message) && message.record.fields.expiresAt.value > this.#clock();
        return { schemaVersion: 1, reportID: report.context.recordName, createdAt: report.context.createdAt,
          expiresAt: report.context.startedAt + 2592000000, reason: report.input.reason, messageID: report.input.messageID,
          message: current ? { authorID: message.context.accountID, name: message.input.name, text: message.input.text,
            createdAt: message.context.createdAt, expiresAt: message.record.fields.expiresAt.value } : null };
      };
    });
  }
}
