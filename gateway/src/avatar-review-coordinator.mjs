import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { validateAvatarRecord } from "./avatar-record-schema.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { AvatarDownloadError, avatarDownloadHosts, avatarDownloadURL, readAvatarDownload } from "./avatar-protected-download.mjs";
import { AvatarReviewError, avatarReviewContentHash } from "./avatar-review-state.mjs";

export const avatarReviewHeader = "X-Echoes-Avatar-Review";
/** Trusted server moderation service. No HTTP route/configuration is installed by this module.
 * One unsettled operation/finalizer per instance; cancelled providers retain the slot until return.
 */
export class AvatarReviewCoordinator {
  #auth; #community; #policy; #receipts; #registry; #client; #checkpoint; #enabled; #operator; #clock; #fetch; #hosts; #timeout; #busy = false;
  constructor({ authentication, communityState, avatarPolicy, receipts, registry, client, checkpoint,
    isEnabled = () => false, isOperator = () => false, clock = Date.now, fetchImplementation = fetch,
    verifiedDownloadHosts = [], timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        ["reviewContent", "assertReviewContent", "reviewQueue", "review", "assertReviewCurrent"].some(k => typeof avatarPolicy?.[k] !== "function") ||
        ["get", "reserve", "confirm", "claim", "finish"].some(k => typeof receipts?.[k] !== "function") ||
        typeof registry?.readAvatarAssetCommitments !== "function" || typeof client?.lookup !== "function" ||
        typeof checkpoint?.verify !== "function" || typeof checkpoint.advance !== "function" ||
        [isEnabled, isOperator, clock, fetchImplementation].some(f => typeof f !== "function") ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
    this.#auth = authentication; this.#community = communityState; this.#policy = avatarPolicy; this.#receipts = receipts;
    this.#registry = registry; this.#client = client; this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#operator = isOperator;
    this.#clock = clock; this.#fetch = fetchImplementation; this.#timeout = timeoutMilliseconds;
    try { this.#hosts = avatarDownloadHosts(verifiedDownloadHosts); } catch { throw new AvatarReviewError("AVATAR_REVIEW_INPUT"); }
  }
  #now() { const n = this.#clock(); if (!Number.isSafeInteger(n) || n < 0) throw new AvatarReviewError(); return n; }
  #options(value, keys) {
    if (!plain(value) || Object.keys(value).some(k => !["accessToken", "signal", ...keys].includes(k)) ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
    for (const key of keys.filter(k => k.endsWith("ID"))) if (typeof value[key] !== "string" || !publicUUID.test(value[key])) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
    return Object.freeze({ ...value });
  }
  #sync(value) { if (value && typeof value.then === "function") { void value.catch?.(() => {}); throw new AvatarReviewError("AVATAR_REVIEW_SCOPE"); } return value; }
  #identity(o, expected) {
    const identity = this.#sync(this.#auth.authorize(o.accessToken));
    if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || this.#sync(this.#operator(identity.accountID)) !== true ||
        typeof o.accessToken !== "string" || expected !== undefined && expected.operatorID !== identity.accountID) throw new AvatarReviewError("AVATAR_REVIEW_SCOPE");
    this.#sync(this.#community.assertActive(identity.accountID));
    const sessionKey = digest("echoes/avatar-review-session/v1\0" + o.accessToken);
    if (expected !== undefined && expected.sessionKey !== sessionKey) throw new AvatarReviewError("AVATAR_REVIEW_SCOPE");
    return Object.freeze({ operatorID: identity.accountID, sessionKey });
  }
  #error(e) {
    if (e instanceof AvatarReviewError) return e;
    if (e instanceof AvatarDownloadError || ["PUBLIC_RESPONSE", "PUBLIC_INPUT", "PUBLIC_SCOPE", "PUBLIC_CONFLICT"].includes(e?.code)) return new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
    if (["AVATAR_STALE", "PUBLIC_ERASED"].includes(e?.code)) return new AvatarReviewError("AVATAR_REVIEW_STALE");
    if (e?.code === "AVATAR_PENDING") return new AvatarReviewError("AVATAR_REVIEW_PENDING");
    if (["PUBLIC_LIMIT", "PUBLIC_THROTTLED"].includes(e?.code)) return new AvatarReviewError("AVATAR_REVIEW_RATE");
    if (e?.code === "INVALID_SESSION" || e?.code === "COMMUNITY_STALE") return new AvatarReviewError("AVATAR_REVIEW_SCOPE");
    return new AvatarReviewError();
  }
  async #prepare(o, action) {
    if (this.#busy) throw new AvatarReviewError("AVATAR_REVIEW_CAPACITY");
    let startedAt; try { startedAt = this.#now(); } catch (e) { throw this.#error(e); }
    const deadline = startedAt + this.#timeout;
    if (!Number.isSafeInteger(deadline)) throw new AvatarReviewError();
    this.#busy = true;
    let closed = false, settled = false, released = false, timer, rejectCancelled;
    const controller = new AbortController();
    const release = () => { if (closed && settled && !released) { released = true; this.#busy = false; } };
    const close = () => { closed = true; clearTimeout(timer); controller.abort(); o.signal?.removeEventListener("abort", cancel); release(); };
    const cancelled = new Promise((_, reject) => { rejectCancelled = reject; });
    const cancel = () => { close(); rejectCancelled(new AvatarReviewError()); };
    const transport = () => {
      const now = this.#now();
      if (closed || controller.signal.aborted || o.signal?.aborted || this.#sync(this.#enabled()) !== true || now < startedAt ||
          !Number.isSafeInteger(deadline) || now >= deadline) throw new AvatarReviewError();
    };
    try {
      timer = setTimeout(cancel, this.#timeout); o.signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        try {
          transport(); const identity = this.#identity(o);
          const check = () => { transport(); this.#identity(o, identity); transport(); };
          const finalize = await action({ identity, check, transport, signal: controller.signal }); check();
          return () => {
            try { check(); return finalize(); } catch (e) { throw this.#error(e); } finally { close(); }
          };
        } finally { settled = true; release(); }
      })();
      return await Promise.race([work, cancelled]);
    } catch (e) { close(); throw this.#error(e); }
  }
  async prepareQueue(value = {}) {
    const o = this.#options(value, []);
    return this.#prepare(o, async ({ check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      const content = this.#policy.reviewQueue();
      await this.#checkpoint.advance({ signal }); check();
      return () => {
        for (const item of content) this.#policy.assertReviewContent(item);
        return Object.freeze({ schemaVersion: 1, items: Object.freeze(content.map(item => Object.freeze({
          accountID: item.accountID, requestID: item.requestID, versionID: item.versionID,
          generation: item.generation, reviewRevision: item.reviewRevision,
        }))) });
      };
    });
  }
  async prepareInspection(value = {}) {
    const o = this.#options(value, ["accountID", "requestID"]);
    return this.#prepare(o, async ({ identity, check, transport, signal }) => {
      let bytes, response;
      try {
        const content = this.#policy.reviewContent(o.accountID, o.requestID), manifest = content.descriptor.image;
        const receipt = await this.#receipts.reserve(identity.operatorID, identity.sessionKey, content); check();
        await this.#checkpoint.verify({ signal }); check(); this.#policy.assertReviewContent(content);
        let commitments;
        const permit = () => {
          check(); this.#policy.assertReviewContent(content);
          if (commitments) {
            const latest = this.#registry.readAvatarAssetCommitments(content.avatar);
            if (["image", "thumbnail"].some(v => ["sha256", "byteCount", "fileChecksumHash"].some(k => latest[v][k] !== commitments[v][k]))) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
          }
        };
        const record = (await this.#client.lookup([content.avatar.recordName], { signal })).get(content.avatar.recordName); permit();
        if (record?.serverErrorCode) throw new AvatarReviewError(record.serverErrorCode === "NOT_FOUND" ? "AVATAR_REVIEW_STALE" : record.serverErrorCode === "THROTTLED" ? "AVATAR_REVIEW_RATE" : undefined);
        commitments = this.#registry.readAvatarAssetCommitments(content.avatar);
        const projection = validateAvatarRecord(record, content.avatar, content.descriptor, commitments);
        const url = avatarDownloadURL(projection.assets.image.downloadURL, this.#hosts);
        permit(); response = await this.#fetch(new Request(url, { method: "GET", redirect: "manual", credentials: "omit",
          headers: { Accept: "image/jpeg", "Cache-Control": "no-store" } }), { signal }); permit();
        bytes = await readAvatarDownload(response, { url, manifest, signal, check: transport }); permit();
        if (digest(bytes) !== manifest.sha256) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE");
        const decoded = inspectAvatarJPEG(bytes, { maximumBytes: 256000, maximumPixels: 512 });
        try { if (decoded.width !== manifest.width || decoded.height !== manifest.height || digest(decoded.bytes) !== manifest.sha256) throw new AvatarReviewError("AVATAR_REVIEW_RESPONSE"); }
        finally { decoded.bytes.fill(0); }
        await this.#receipts.confirm(identity.operatorID, identity.sessionKey, receipt.inspectionID); permit();
        await this.#checkpoint.advance({ signal }); permit();
        const body = bytes; bytes = undefined;
        // Timeout/abandonment also clears the prepared body; no unbounded orphan finalizers.
        const aborted = () => body.fill(0); signal.addEventListener("abort", aborted, { once: true });
        return () => {
          try {
            permit(); this.#receipts.get(identity.operatorID, identity.sessionKey, receipt.inspectionID);
            return new Response(body.slice(), { status: 200, headers: {
              "Content-Type": "image/jpeg", "Content-Length": String(manifest.byteCount), "Cache-Control": "private, no-store",
              "X-Content-Type-Options": "nosniff", "X-Echoes-Avatar-Manifest": JSON.stringify(manifest),
              [avatarReviewHeader]: JSON.stringify({ schemaVersion: 1, ...receipt, requestID: content.requestID,
                generation: content.generation, reviewRevision: content.reviewRevision }),
            } });
          } finally { signal.removeEventListener("abort", aborted); body.fill(0); }
        };
      } finally { bytes?.fill(0); if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {}); }
    });
  }
  async prepareDecision(value = {}) {
    const o = this.#options(value, ["inspectionID", "decisionID", "verdict"]);
    if (!["approved", "rejected"].includes(o.verdict)) throw new AvatarReviewError("AVATAR_REVIEW_INPUT");
    return this.#prepare(o, async ({ identity, check, signal }) => {
      await this.#checkpoint.verify({ signal }); check();
      let receipt = this.#receipts.get(identity.operatorID, identity.sessionKey, o.inspectionID);
      const content = this.#policy.reviewContent(receipt.account_id, receipt.request_id);
      const permit = () => {
        check(); const current = this.#receipts.get(identity.operatorID, identity.sessionKey, o.inspectionID);
        const latest = this.#policy.assertReviewContent(content, { includeRevision: false });
        if (avatarReviewContentHash(latest) !== current.content_hash || current.decision_id === null && latest.reviewRevision !== current.expected_revision ||
            current.decision_id !== null && (current.decision_id !== o.decisionID || current.verdict !== o.verdict)) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
        return current;
      };
      permit(); receipt = await this.#receipts.claim(identity.operatorID, identity.sessionKey, o.inspectionID, o.decisionID, o.verdict); permit();
      const result = await this.#policy.review({ accountID: receipt.account_id, requestID: receipt.request_id,
        decisionID: o.decisionID, expectedRevision: receipt.expected_revision, verdict: o.verdict, reviewerID: identity.operatorID }); permit();
      await this.#receipts.finish(identity.operatorID, identity.sessionKey, o.inspectionID, result); permit();
      await this.#checkpoint.advance({ signal }); permit();
      return () => {
        const current = permit(); this.#policy.assertReviewCurrent(result);
        if (current.result_revision !== result.revision) throw new AvatarReviewError("AVATAR_REVIEW_STALE");
        return Object.freeze({ schemaVersion: 1, inspectionID: o.inspectionID, ...result });
      };
    });
  }
}
