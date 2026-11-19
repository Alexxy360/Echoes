import { plain, publicUUID, recordIdentity, normalizePublicInput, inputHash } from "./public-record-schema.mjs";
import { communityPolicy, distanceMeters } from "./community-domain.mjs";
import { validateAvatarRecord } from "./avatar-record-schema.mjs";
import { AvatarReportError, avatarReportInput, avatarReportFail as fail } from "./avatar-report-domain.mjs";
const sync = value => {
  if (value && typeof value.then === "function") { void Promise.resolve(value).catch(() => {}); fail(); }
  return value;
};

/** Protected intake for the exact published version. Reporting never changes publication/moderation. */
export class AvatarReportCoordinator {
  #authentication; #community; #policy; #repository; #registry; #client; #checkpoint; #enabled; #canSubmit; #canCancel; #clock; #mono; #timeout;
  #busy = false; #unsafe = false; #pending = new Set();
  constructor({ authentication, communityState, avatarPolicy, repository, registry, client, checkpoint,
    isEnabled = () => false, canSubmit = () => false, canCancel = () => false, clock = Date.now, monotonic = () => performance.now(), timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || ["assertActive", "visible", "begin", "finish", "assertCurrent", "avatarReportIntent", "cancelAvatarReportIntent"].some(key => typeof communityState?.[key] !== "function") ||
        ["readPublication", "assertReadPublication"].some(key => typeof avatarPolicy?.[key] !== "function") ||
        ["beginRead", "write", "recoverAvatarReport", "cancelAvatarReport"].some(key => typeof repository?.[key] !== "function") ||
        ["owned", "readable", "readAvatarAssetCommitments", "avatarReportCancellation", "assertAvatarReportCancellation"].some(key => typeof registry?.[key] !== "function") ||
        ["lookup", "waitForPendingOperations"].some(key => typeof client?.[key] !== "function") ||
        ["advance", "verify"].some(key => typeof checkpoint?.[key] !== "function") ||
        [isEnabled, canSubmit, canCancel, clock, monotonic].some(value => typeof value !== "function") ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) fail("AVATAR_REPORT_INPUT");
    this.#authentication = authentication; this.#community = communityState; this.#policy = avatarPolicy; this.#repository = repository;
    this.#registry = registry; this.#client = client; this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#canSubmit = canSubmit; this.#canCancel = canCancel;
    this.#clock = clock; this.#mono = monotonic; this.#timeout = timeoutMilliseconds;
  }
  get isOccupied() { return this.#busy; }
  async waitForPendingOperations() { await Promise.allSettled([...this.#pending]); if (this.#unsafe) fail(); }
  #options(action, value) {
    if (!plain(value) || typeof value.accessToken !== "string" || value.accessToken.length < 1 || value.accessToken.length > 1024 ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) fail("AVATAR_REPORT_INPUT");
    const { accessToken, signal, ...body } = value;
    return { accessToken, signal, body: avatarReportInput(action, body) };
  }
  #identity(o, expected) {
    try {
      const identity = sync(this.#authentication.authorize(o.accessToken));
      if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) fail("AVATAR_REPORT_SCOPE");
      sync(this.#community.assertActive(identity.accountID)); return identity.accountID;
    } catch { fail("AVATAR_REPORT_SCOPE"); }
  }
  #error(error) {
    if (error instanceof AvatarReportError) return error;
    if (["INVALID_SESSION", "ACCOUNT_DISABLED", "DELETION_IN_PROGRESS"].includes(error?.code)) return new AvatarReportError("AVATAR_REPORT_SCOPE");
    if (["AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED"].includes(error?.code)) return new AvatarReportError("AVATAR_REPORT_NOT_FOUND");
    if (["COMMUNITY_RATE_LIMITED", "COMMUNITY_CAPACITY", "PUBLIC_LIMIT"].includes(error?.code)) return new AvatarReportError("AVATAR_REPORT_LIMIT");
    if (["COMMUNITY_STALE", "PUBLIC_CONFLICT", "PUBLIC_ERASED", "PUBLIC_PENDING"].includes(error?.code)) return new AvatarReportError("AVATAR_REPORT_CONFLICT");
    if (["PUBLIC_SCOPE", "PUBLIC_RESPONSE", "PUBLIC_INPUT"].includes(error?.code)) return new AvatarReportError("AVATAR_REPORT_RESPONSE");
    return new AvatarReportError();
  }
  async #prepare(o, mode, action) {
    if (this.#busy) fail("AVATAR_REPORT_LIMIT"); this.#busy = true;
    let closed = false, settled = false, released = false, timer, rejectCancelled, result, identity, floorWall, floorMono;
    const controller = new AbortController();
    const release = () => { if (closed && settled && !released) { released = true; this.#busy = false; } };
    const close = () => { closed = true; result = undefined; clearTimeout(timer); controller.abort(); o.signal?.removeEventListener("abort", cancel); release(); };
    const cancel = () => { close(); rejectCancelled(new AvatarReportError()); };
    const cancelled = new Promise((_, reject) => { rejectCancelled = reject; });
    try {
      const started = floorWall = this.#clock(), mono = floorMono = this.#mono();
      if (!Number.isSafeInteger(started) || started < 0 || !Number.isFinite(mono) || mono < 0) fail();
      const transport = () => {
        const now = this.#clock(), tick = this.#mono();
        if (closed || this.#unsafe || controller.signal.aborted || o.signal?.aborted || sync(this.#enabled()) !== true || mode === "submit" && sync(this.#canSubmit()) !== true || mode === "cancel" && sync(this.#canCancel()) !== true ||
            !Number.isSafeInteger(now) || now < floorWall || !Number.isFinite(tick) || tick < floorMono || now - started >= this.#timeout || tick - mono >= this.#timeout) fail();
        floorWall = now; floorMono = tick;
      };
      timer = setTimeout(cancel, this.#timeout); o.signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        try {
          transport(); identity = this.#identity(o);
          const check = () => { transport(); this.#identity(o, identity); transport(); return true; };
          result = await action({ accountID: identity, check, signal: controller.signal }); check();
        } finally {
          try { await this.#client.waitForPendingOperations(); settled = true; release(); }
          catch { this.#unsafe = true; fail(); }
        }
      })();
      this.#pending.add(work); void work.then(() => this.#pending.delete(work), () => this.#pending.delete(work));
      await Promise.race([work, cancelled]);
      return () => { try { transport(); this.#identity(o, identity); return result(); } catch (error) { throw this.#error(error); } finally { close(); } };
    } catch (error) { close(); if (!timer) { settled = true; release(); } throw this.#error(error); }
  }
  async prepareSubmit(value) {
    const o = this.#options("submit", value), input = o.body;
    return this.#prepare(o, "submit", async ({ accountID, check, signal }) => {
      if (input.ownerID === accountID) fail("AVATAR_REPORT_INPUT");
      const publication = this.#policy.readPublication(input.ownerID);
      if (publication.versionID !== input.versionID) fail("AVATAR_REPORT_NOT_FOUND");
      const lease = await this.#repository.beginRead({ accessToken: o.accessToken, signal }); check();
      const [pointer] = await lease.lookup([publication.pointer.recordName], "avatarprofile"); check();
      const [presence] = await lease.lookup([recordIdentity(input.ownerID, "presence", "singleton").recordName], "presence"); check();
      let commitments;
      const permit = () => {
        check(); this.#policy.assertReadPublication(publication);
        if (!pointer || pointer.context.accountID !== input.ownerID || pointer.context.kind !== "avatarprofile" || !lease.current(pointer) ||
            pointer.record.recordChangeTag !== publication.pointerTag || pointer.input.versionID !== publication.versionID || pointer.input.generation !== publication.generation ||
            !presence || presence.context.accountID !== input.ownerID || presence.context.kind !== "presence" || !lease.current(presence) ||
            presence.input.active !== 1 || presence.record.fields.expiresAt.value <= this.#clock() || !this.#community.visible(accountID, presence.context) ||
            distanceMeters(input.coordinate, presence.input) > communityPolicy.radius) fail("AVATAR_REPORT_NOT_FOUND");
        if (commitments) {
          const fresh = this.#registry.readAvatarAssetCommitments(publication.avatar);
          if (["image", "thumbnail"].some(variant => ["sha256", "byteCount", "fileChecksumHash"].some(key => fresh[variant][key] !== commitments[variant][key]))) fail("AVATAR_REPORT_RESPONSE");
        }
        return true;
      };
      permit();
      const record = (await this.#client.lookup([publication.avatar.recordName], { signal })).get(publication.avatar.recordName); permit();
      if (record?.serverErrorCode) fail(record.serverErrorCode === "NOT_FOUND" ? "AVATAR_REPORT_NOT_FOUND" : undefined);
      commitments = this.#registry.readAvatarAssetCommitments(publication.avatar);
      validateAvatarRecord(record, publication.avatar, publication.descriptor, commitments); permit();
      const fields = normalizePublicInput("avatarreport", { avatarID: publication.avatar.recordName, versionID: publication.versionID,
        publicationGeneration: publication.generation, imageSHA256: publication.descriptor.image.sha256, reason: input.reason }, this.#clock());
      const intent = await this.#community.begin({ accountID, kind: "avatarreport", logicalID: input.requestID, requestID: input.requestID, payloadHash: inputHash(fields) }); permit();
      let report;
      const guard = () => {
        permit(); this.#community.assertCurrent(intent);
        if (report) {
          const current = this.#registry.readable(report.recordName, "avatarreport");
          if (!current || current.recordTag !== report.recordTag || current.payloadHash !== report.payloadHash || current.requestID !== input.requestID) fail("AVATAR_REPORT_CONFLICT");
        }
        return true;
      };
      const saved = await this.#repository.write({ accessToken: o.accessToken, kind: "avatarreport", logicalID: input.requestID,
        requestID: input.requestID, input: fields, signal, authorizeMutation: guard });
      report = this.#registry.owned(accountID, "avatarreport", input.requestID);
      if (!report || report.phase !== "settled" || report.recordName !== saved.recordName || report.recordTag !== saved.recordChangeTag || report.payloadHash !== inputHash(fields)) fail("AVATAR_REPORT_RESPONSE");
      guard();
      await this.#community.finish(intent); guard(); await this.#checkpoint.advance({ signal }); guard();
      return () => { guard(); return { schemaVersion: 1, requestID: input.requestID, reportID: saved.recordName, outcome: "accepted" }; };
    });
  }
  #confirmedCancellation(accountID, requestID, reportID) {
    const lease = this.#registry.avatarReportCancellation(accountID, requestID);
    if (!lease || lease.recordName !== reportID || lease.state !== "settled" || !lease.cancellationTag || lease.cancellationTag !== lease.recordTag) fail("AVATAR_REPORT_RESPONSE");
    this.#assertCancellation(lease); return lease;
  }
  #assertCancellation(lease) {
    const current = this.#registry.assertAvatarReportCancellation(lease);
    if (current.state !== "settled" || current.cancellationTag !== lease.cancellationTag || current.recordTag !== lease.recordTag) fail("AVATAR_REPORT_CONFLICT");
  }
  async prepareCancellation(value) {
    const o = this.#options("cancel", value), input = o.body;
    return this.#prepare(o, "cancel", async ({ accountID, check, signal }) => {
      const saved = await this.#repository.cancelAvatarReport({ accessToken: o.accessToken, requestID: input.requestID, signal, authorizeMutation: check }); check();
      if (saved.outcome !== "cancelled") fail("AVATAR_REPORT_RESPONSE");
      const lease = this.#confirmedCancellation(accountID, input.requestID, saved.reportID);
      const current = () => { check(); this.#assertCancellation(lease); };
      await this.#community.cancelAvatarReportIntent(accountID, input.requestID); current();
      await this.#checkpoint.advance({ signal }); current();
      return () => { current(); return { ...saved, requestID: input.requestID }; };
    });
  }
  async prepareRecovery(value) {
    const o = this.#options("recover", value), input = o.body;
    return this.#prepare(o, "recover", async ({ accountID, check, signal }) => {
      const saved = await this.#repository.recoverAvatarReport({ accessToken: o.accessToken, requestID: input.requestID, signal, authorizeRead: check }); check();
      let context, cancellation;
      if (saved.outcome === "cancelled") {
        cancellation = this.#confirmedCancellation(accountID, input.requestID, saved.reportID);
        await this.#community.cancelAvatarReportIntent(accountID, input.requestID); check();
      }
      if (saved.outcome === "accepted") {
        context = this.#registry.owned(accountID, "avatarreport", input.requestID);
        const intent = this.#community.avatarReportIntent(accountID, input.requestID);
        if (!context || !intent || intent.payload_hash !== context.payloadHash) fail("AVATAR_REPORT_CONFLICT");
        await this.#community.finish(intent); check();
      }
      const current = () => {
        check();
        if (cancellation) this.#assertCancellation(cancellation);
        if (context) {
          const latest = this.#registry.readable(context.recordName, "avatarreport");
          if (!latest || latest.payloadHash !== context.payloadHash || latest.recordTag !== context.recordTag || latest.requestID !== input.requestID) fail("AVATAR_REPORT_CONFLICT");
        }
      };
      await this.#checkpoint.advance({ signal }); current();
      return () => { current(); return { ...saved, requestID: input.requestID }; };
    });
  }
}
