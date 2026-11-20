import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { validateAvatarRecord } from "./avatar-record-schema.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { AvatarDownloadError, AvatarDownloadScope, avatarDownloadHosts, avatarDownloadURL } from "./avatar-protected-download.mjs";
import { AvatarReportReviewError, avatarReportReviewContent, avatarReportReviewContentHash } from "./avatar-report-review-state.mjs";

const fail = code => { throw new AvatarReportReviewError(code); };
const id = value => typeof value === "string" && publicUUID.test(value);
const reportID = value => typeof value === "string" && /^community-v1-avatarreport-[a-f0-9]{64}$/.test(value);
const sync = value => { if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail("AVATAR_REPORT_REVIEW_SCOPE"); } return value; };
const absent = error => ["AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED"].includes(error?.code);

/** Trusted inner coordinator only. No routes, grants, secrets or activation installed here.
 * Inspection finalizer transfers one bounded image copy to its trusted caller; caller must consume/clear it.
 */
export class AvatarReportReviewCoordinator {
  #auth; #community; #policy; #repository; #registry; #client; #reviews; #checkpoint; #enabled; #operator; #clock; #mono; #timeout; #fetch; #hosts;
  #busy = false; #unsafe = false; #pending = new Set(); #downloads = new AvatarDownloadScope();
  constructor({ authentication, communityState, avatarPolicy, repository, registry, client, reviews, checkpoint,
    isEnabled = () => false, isOperator = () => false, clock = Date.now, monotonic = () => performance.now(),
    timeoutMilliseconds = 8000, fetchImplementation = fetch, verifiedDownloadHosts = [] } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        ["readPublication", "assertReadPublication"].some(k => typeof avatarPolicy?.[k] !== "function") || typeof repository?.beginRead !== "function" ||
        ["readable", "reviewAvatarReportPage", "readAvatarAssetCommitments"].some(k => typeof registry?.[k] !== "function") ||
        ["lookup", "waitForPendingOperations"].some(k => typeof client?.[k] !== "function") ||
        ["isOpen", "reserve", "getReserved", "confirm", "get", "decide", "retire", "recover", "outcome"].some(k => typeof reviews?.[k] !== "function") ||
        ["verify", "advance"].some(k => typeof checkpoint?.[k] !== "function") ||
        [isEnabled, isOperator, clock, monotonic, fetchImplementation].some(f => typeof f !== "function") ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) fail("AVATAR_REPORT_REVIEW_INPUT");
    this.#auth = authentication; this.#community = communityState; this.#policy = avatarPolicy; this.#repository = repository;
    this.#registry = registry; this.#client = client; this.#reviews = reviews; this.#checkpoint = checkpoint; this.#enabled = isEnabled;
    this.#operator = isOperator; this.#clock = clock; this.#mono = monotonic; this.#timeout = timeoutMilliseconds; this.#fetch = fetchImplementation;
    try { this.#hosts = avatarDownloadHosts(verifiedDownloadHosts); } catch { fail("AVATAR_REPORT_REVIEW_INPUT"); }
  }
  get isOccupied() { return this.#busy; }
  async waitForPendingOperations() {
    try { await Promise.allSettled([...this.#pending]); if (this.#unsafe) fail(); this.#downloads.check(); }
    catch (error) { throw this.#error(error); }
  }
  #options(value, keys) {
    if (!plain(value) || Object.keys(value).some(k => !["accessToken", "signal", ...keys].includes(k)) ||
        typeof value.accessToken !== "string" || value.accessToken.length < 1 || value.accessToken.length > 1024 ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return Object.freeze({ ...value });
  }
  #identity(o, expected) {
    const identity = sync(this.#auth.authorize(o.accessToken));
    if (!id(identity?.accountID) || sync(this.#operator(identity.accountID)) !== true) fail("AVATAR_REPORT_REVIEW_SCOPE");
    sync(this.#community.assertActive(identity.accountID));
    const result = { reviewerID: identity.accountID, sessionKey: digest("echoes/avatar-report-review-session/v1\0" + o.accessToken) };
    if (expected && (expected.reviewerID !== result.reviewerID || expected.sessionKey !== result.sessionKey)) fail("AVATAR_REPORT_REVIEW_SCOPE");
    return result;
  }
  #error(error) {
    if (error instanceof AvatarReportReviewError) return error;
    if (error instanceof AvatarDownloadError || ["PUBLIC_RESPONSE", "PUBLIC_SCOPE", "PUBLIC_INPUT", "PUBLIC_CONFLICT"].includes(error?.code)) return new AvatarReportReviewError("AVATAR_REPORT_REVIEW_RESPONSE");
    if (absent(error) || error?.code === "PUBLIC_ERASED") return new AvatarReportReviewError("AVATAR_REPORT_REVIEW_STALE");
    if (["INVALID_SESSION", "COMMUNITY_STALE", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS"].includes(error?.code)) return new AvatarReportReviewError("AVATAR_REPORT_REVIEW_SCOPE");
    return new AvatarReportReviewError();
  }
  async #prepare(o, action) {
    if (this.#busy) fail("AVATAR_REPORT_REVIEW_CAPACITY");
    this.#busy = true;
    let closed = false, settled = false, released = false, timer, rejectCancelled, prepared, identity, download;
    const controller = new AbortController();
    const release = () => { if (closed && settled && !released) { released = true; this.#busy = false; } };
    const close = () => { closed = true; prepared = undefined; clearTimeout(timer); controller.abort(); o.signal?.removeEventListener("abort", cancel); release(); };
    const cancel = () => { close(); rejectCancelled(new AvatarReportReviewError()); };
    const cancelled = new Promise((_, reject) => { rejectCancelled = reject; });
    try {
      const started = this.#clock(), tick = this.#mono(); let wallFloor = started, monoFloor = tick;
      if (!Number.isSafeInteger(started) || started < 0 || !Number.isFinite(tick) || tick < 0) fail();
      download = this.#downloads.operation();
      const transport = () => {
        const now = this.#clock(), mono = this.#mono(); this.#downloads.check();
        if (closed || this.#unsafe || controller.signal.aborted || o.signal?.aborted || sync(this.#enabled()) !== true ||
            !Number.isSafeInteger(now) || now < wallFloor || !Number.isFinite(mono) || mono < monoFloor ||
            now - started >= this.#timeout || mono - tick >= this.#timeout) fail();
        wallFloor = now; monoFloor = mono;
      };
      timer = setTimeout(cancel, this.#timeout); o.signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        try {
          transport(); identity = this.#identity(o);
          const check = () => { transport(); this.#identity(o, identity); transport(); return true; };
          prepared = await action({ identity, check, signal: controller.signal, download }); check();
        } finally {
          try { await download.finish(this.#client); settled = true; release(); }
          catch { this.#unsafe = true; fail(); }
        }
      })();
      this.#pending.add(work); void work.then(() => this.#pending.delete(work), () => this.#pending.delete(work));
      await Promise.race([work, cancelled]);
      return () => { try { transport(); this.#identity(o, identity); return prepared(); } catch (error) { throw this.#error(error); } finally { close(); } };
    } catch (error) { close(); if (!timer) { settled = true; release(); } throw this.#error(error); }
  }
  #publication(report) {
    const avatar = this.#registry.readable(report.input.avatarID, "avatar"); if (!avatar) return null;
    let current; try { current = this.#policy.readPublication(avatar.accountID); } catch (error) { if (absent(error)) return null; throw error; }
    return current.avatar.recordName === report.input.avatarID && current.versionID === report.input.versionID &&
      current.generation === report.input.publicationGeneration && current.descriptor.image.sha256 === report.input.imageSHA256 ? current : null;
  }
  async prepareQueue(value) {
    const o = this.#options(value, ["after"]);
    if (o.after !== undefined && o.after !== null && !reportID(o.after)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ check, signal }) => {
      await this.#checkpoint.verify({ signal }); check(); const page = this.#registry.reviewAvatarReportPage(o.after ?? null);
      await this.#checkpoint.advance({ signal }); check();
      return () => ({ schemaVersion: 1, items: page.items.filter(item => {
        const row = this.#registry.readable(item.recordName, "avatarreport");
        return row?.recordTag === item.recordTag && row.payloadHash === item.payloadHash && row.requestID === item.requestID && this.#reviews.isOpen(row);
      }).map(item => ({ reportID: item.recordName, createdAt: item.createdAt, expiresAt: item.startedAt + 2592000000 })), after: page.after });
    });
  }
  async prepareInspection(value) {
    const o = this.#options(value, ["reportID"]); if (!reportID(o.reportID)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal, download }) => {
      let bytes;
      try {
        const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
        const [report] = await lease.lookup([o.reportID], "avatarreport"); check();
        if (!report || !lease.current(report) || !this.#reviews.isOpen(report.context)) fail("AVATAR_REPORT_REVIEW_STALE");
        const publication = this.#publication(report);
        let content = avatarReportReviewContent(report, publication), receipt, commitments, pointer;
        const permit = () => {
          check();
          if (!lease.current(report) || !this.#reviews.isOpen(report.context)) fail("AVATAR_REPORT_REVIEW_STALE");
          if (publication) this.#policy.assertReadPublication(publication);
          else if (this.#publication(report) !== null) fail("AVATAR_REPORT_REVIEW_STALE");
          if (receipt && this.#reviews.getReserved(identity.reviewerID, identity.sessionKey, receipt.inspectionID).content_hash !== avatarReportReviewContentHash(content)) fail("AVATAR_REPORT_REVIEW_STALE");
          if (pointer && (!lease.current(pointer) || pointer.input.versionID !== publication.versionID || pointer.input.generation !== publication.generation || pointer.record.recordChangeTag !== publication.pointerTag)) fail("AVATAR_REPORT_REVIEW_STALE");
          if (commitments) {
            const latest = this.#registry.readAvatarAssetCommitments(publication.avatar);
            if (["image", "thumbnail"].some(v => ["sha256", "byteCount", "fileChecksumHash"].some(k => latest[v][k] !== commitments[v][k]))) fail("AVATAR_REPORT_REVIEW_RESPONSE");
          }
          return true;
        };
        // Report metadata was read above. Reserve before avatar lookup/CDN costs and invalidate the prior receipt.
        receipt = await this.#reviews.reserve(identity.reviewerID, identity.sessionKey, content); permit();
        if (publication) {
          [pointer] = await lease.lookup([publication.pointer.recordName], "avatarprofile"); permit();
          if (!pointer) fail("AVATAR_REPORT_REVIEW_STALE");
          const record = (await this.#client.lookup([publication.avatar.recordName], { signal })).get(publication.avatar.recordName); permit();
          let missing = record?.serverErrorCode === "NOT_FOUND";
          if (!missing) {
            if (record?.serverErrorCode) fail();
            commitments = this.#registry.readAvatarAssetCommitments(publication.avatar);
            const projection = validateAvatarRecord(record, publication.avatar, publication.descriptor, commitments);
            const url = avatarDownloadURL(projection.assets.image.downloadURL, this.#hosts); permit();
            const response = await this.#fetch(new Request(url, { method: "GET", redirect: "manual", credentials: "omit", headers: { Accept: "image/jpeg", "Cache-Control": "no-store" } }), { signal });
            download.adopt(response); permit();
            missing = [404, 410].includes(response.status) && !response.redirected && (!response.url || response.url === url);
            if (missing) { await download.drain(); permit(); }
            else {
              const manifest = publication.descriptor.image;
              bytes = await download.read({ url, manifest, signal, check: permit }); permit();
              if (digest(bytes) !== manifest.sha256) fail("AVATAR_REPORT_REVIEW_RESPONSE");
              const decoded = inspectAvatarJPEG(bytes, { maximumBytes: 256000, maximumPixels: 512 });
              try { if (decoded.width !== manifest.width || decoded.height !== manifest.height || digest(decoded.bytes) !== manifest.sha256) fail("AVATAR_REPORT_REVIEW_RESPONSE"); }
              finally { decoded.bytes.fill(0); }
            }
          }
          if (missing) {
            // A NEW dismiss-only receipt replaces the unverified image receipt. No old ID is upgraded/downgraded.
            content = avatarReportReviewContent(report, null);
            receipt = await this.#reviews.reserve(identity.reviewerID, identity.sessionKey, content); permit();
          }
        }
        await this.#reviews.confirm(identity.reviewerID, identity.sessionKey, receipt.inspectionID); permit();
        await this.#checkpoint.advance({ signal }); permit();
        const body = bytes; bytes = undefined;
        const aborted = () => body?.fill(0); signal.addEventListener("abort", aborted, { once: true });
        return () => {
          try {
            permit(); this.#reviews.get(identity.reviewerID, identity.sessionKey, receipt.inspectionID);
            return Object.freeze({ metadata: Object.freeze({ schemaVersion: 1, inspectionID: receipt.inspectionID,
              inspectionExpiresAt: receipt.expiresAt, contentHash: receipt.contentHash, reportID: report.context.recordName,
              createdAt: report.context.createdAt, expiresAt: report.context.startedAt + 2592000000, reason: report.input.reason,
              photo: body ? Object.freeze({ ownerID: publication.accountID, versionID: publication.versionID,
                publicationGeneration: publication.generation, manifest: publication.descriptor.image }) : null }), image: body?.slice() ?? null });
          } finally { signal.removeEventListener("abort", aborted); body?.fill(0); }
        };
      } finally { bytes?.fill(0); }
    });
  }
  async prepareDecision(value) {
    const o = this.#options(value, ["inspectionID", "decisionID", "verdict"]);
    if (![o.inspectionID, o.decisionID].every(id) || !["dismiss", "hide_photo"].includes(o.verdict)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      const receipt = this.#reviews.get(identity.reviewerID, identity.sessionKey, o.inspectionID), content = receipt.content;
      const query = { reviewerID: identity.reviewerID, reportID: content.reportID, decisionID: o.decisionID, verdict: o.verdict, contentHash: receipt.content_hash };
      const previous = this.#reviews.outcome(query); let result;
      if (!["not-applied", "confirmed"].includes(previous.outcome)) fail("AVATAR_REPORT_REVIEW_STALE");
      if (previous.outcome === "confirmed") {
        await this.#checkpoint.verify({ signal }); check();
        result = { reportID: content.reportID, decisionID: o.decisionID, verdict: o.verdict, contentHash: receipt.content_hash, revision: previous.revision };
      } else {
        const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
        const [report] = await lease.lookup([content.reportID], "avatarreport"); check();
        if (!report || !lease.current(report)) fail("AVATAR_REPORT_REVIEW_STALE");
        const authorize = () => {
          check(); this.#reviews.get(identity.reviewerID, identity.sessionKey, o.inspectionID);
          if (!lease.current(report)) fail("AVATAR_REPORT_REVIEW_STALE");
          // Missing provider pixels allow dismissal despite a still-valid metadata publication.
          const current = avatarReportReviewContent(report, content.accountID === null ? null : this.#publication(report));
          if (avatarReportReviewContentHash(current) !== receipt.content_hash) fail("AVATAR_REPORT_REVIEW_STALE");
          return true;
        };
        authorize();
        try { result = await this.#reviews.decide({ reviewerID: identity.reviewerID, sessionKey: identity.sessionKey,
          inspectionID: o.inspectionID, decisionID: o.decisionID, verdict: o.verdict, content, authorize }); }
        catch (error) { check(); await this.#checkpoint.advance({ signal }); throw error; }
        check();
      }
      await this.#checkpoint.advance({ signal }); check();
      return () => {
        const current = this.#reviews.outcome(query);
        if (current.outcome !== "confirmed" || current.revision !== result.revision) fail("AVATAR_REPORT_REVIEW_STALE");
        return { schemaVersion: 1, inspectionID: o.inspectionID, ...result };
      };
    });
  }
  async prepareRetirement(value) {
    const keys = ["reportID", "decisionID", "verdict", "contentHash"], o = this.#options(value, keys);
    if (!reportID(o.reportID) || !id(o.decisionID) || !["dismiss", "hide_photo"].includes(o.verdict) || typeof o.contentHash !== "string" || !/^[a-f0-9]{64}$/.test(o.contentHash)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      const query = { reviewerID: identity.reviewerID, ...Object.fromEntries(keys.map(k => [k, o[k]])) };
      let result;
      try { result = await this.#reviews.retire({ ...query, authorize: () => { check(); return true; } }); }
      catch (error) { check(); await this.#checkpoint.advance({ signal }); throw error; }
      check(); await this.#checkpoint.advance({ signal }); check();
      return () => {
        const latest = this.#reviews.outcome(query);
        if (!["retired", "confirmed", "superseded"].includes(latest.outcome) || latest.outcome !== result.outcome || latest.revision !== result.revision) fail("AVATAR_REPORT_REVIEW_STALE");
        return { schemaVersion: 1, ...latest };
      };
    });
  }
  async prepareRecovery(value) {
    const keys = ["reportID", "decisionID", "verdict", "contentHash"], o = this.#options(value, keys);
    if (!reportID(o.reportID) || !id(o.decisionID) || !["dismiss", "hide_photo"].includes(o.verdict) || typeof o.contentHash !== "string" || !/^[a-f0-9]{64}$/.test(o.contentHash)) fail("AVATAR_REPORT_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      const query = { reviewerID: identity.reviewerID, ...Object.fromEntries(keys.map(k => [k, o[k]])) };
      const result = await this.#reviews.recover(query); check(); await this.#checkpoint.advance({ signal }); check();
      return () => {
        const latest = this.#reviews.outcome(query);
        if (latest.outcome !== result.outcome || latest.revision !== result.revision) fail("AVATAR_REPORT_REVIEW_STALE");
        return { schemaVersion: 1, ...latest };
      };
    });
  }
}
