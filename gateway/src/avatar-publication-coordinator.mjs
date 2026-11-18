import { AvatarPolicyError } from "./avatar-policy-state.mjs";
import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { normalizedAvatarManifest } from "./avatar-normalizer.mjs";
import { avatarPublicationKeys, validAvatarPublicationIntent } from "./avatar-publication-intent.mjs";

/** Server-only orchestration. Public HTTP/upload admission and operator UI remain separate gates.
 * prepare methods return a synchronous finalizer for the host to call AFTER its last checkpoint.
 */
export class AvatarPublicationCoordinator {
  #state; #authentication; #community; #normalizer; #assets; #profiles; #checkpoint; #enabled; #operator; #withdrawalOnly;
  constructor({ state, authentication, communityState, normalizer, avatarRepository, profileRepository, checkpoint, isEnabled, authorizeOperator, withdrawalOnly = false } = {}) {
    if (["select", "clear", "rememberDescriptor", "staged", "review", "snapshot", "ensureSelectionExpiry"].some(key => typeof state?.[key] !== "function") ||
        typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        typeof withdrawalOnly !== "boolean" || (withdrawalOnly ? normalizer !== undefined || avatarRepository !== undefined || authorizeOperator !== undefined :
          typeof normalizer?.prepare !== "function" || typeof avatarRepository?.stage !== "function" || typeof avatarRepository.recover !== "function") ||
        typeof profileRepository?.writeLatest !== "function" || typeof checkpoint?.verify !== "function" || typeof checkpoint.advance !== "function" ||
        typeof isEnabled !== "function" || authorizeOperator !== undefined && typeof authorizeOperator !== "function") throw new AvatarPolicyError();
    this.#state = state; this.#authentication = authentication; this.#community = communityState; this.#normalizer = normalizer;
    this.#assets = avatarRepository; this.#profiles = profileRepository; this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#operator = authorizeOperator;
    this.#withdrawalOnly = withdrawalOnly;
  }
  #options(value, names) {
    if (!plain(value) || Object.keys(value).some(key => !names.includes(key)) || value.signal !== undefined && !(value.signal instanceof AbortSignal)) throw new AvatarPolicyError("AVATAR_INPUT");
    return Object.freeze({ ...value });
  }
  #identity(options, expectedID) {
    try {
      if (options.signal?.aborted || this.#enabled() !== true) throw new AvatarPolicyError();
      const identity = this.#authentication.authorize(options.accessToken);
      if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expectedID !== undefined && identity.accountID !== expectedID) throw new AvatarPolicyError("AVATAR_STALE");
      this.#community.assertActive(identity.accountID);
      if (options.signal?.aborted || this.#enabled() !== true) throw new AvatarPolicyError(); return identity;
    } catch (e) { throw e instanceof AvatarPolicyError ? e : new AvatarPolicyError("AVATAR_STALE"); }
  }
  #permit(options, intent, publish = false) {
    const identity = this.#identity(options, intent.accountID);
    if (publish) this.#state.assertPublishCurrent(intent); else this.#state.assertCurrent(intent);
    return identity;
  }
  #final(options, intent, publish = false) {
    return () => { this.#permit(options, intent, publish); return this.#state.snapshot(intent.accountID); };
  }
  #error(e) {
    if (e instanceof AvatarPolicyError) return e;
    const mapped = { PUBLIC_PENDING: "AVATAR_PENDING", PUBLIC_CONFLICT: "AVATAR_STALE", PUBLIC_SCOPE: "AVATAR_STALE",
      PUBLIC_INPUT: "AVATAR_INPUT", PUBLIC_ERASED: "AVATAR_STALE", PUBLIC_LIMIT: "AVATAR_RATE" };
    return new AvatarPolicyError(mapped[e?.code]);
  }
  async prepareUpload(value = {}) {
    let bytes;
    try {
      if (this.#withdrawalOnly) throw new AvatarPolicyError("AVATAR_SCOPE");
      const o = this.#options(value, ["accessToken", "signal", "bytes", "versionID", "requestID", "expectedGeneration", "consentVersion"]);
      const credentials = Object.freeze({ accessToken: o.accessToken, signal: o.signal }), { accountID } = this.#identity(credentials);
      if (!(o.bytes instanceof Uint8Array) || typeof SharedArrayBuffer !== "undefined" && o.bytes.buffer instanceof SharedArrayBuffer ||
          o.bytes.byteLength < 1 || o.bytes.byteLength > 256000) throw new AvatarPolicyError("AVATAR_INPUT");
      bytes = new Uint8Array(o.bytes);
      await this.#checkpoint.verify({ signal: o.signal }); this.#identity(credentials, accountID);
      const intent = await this.#state.select({ accountID, requestID: o.requestID, versionID: o.versionID, expectedGeneration: o.expectedGeneration,
        sourceHash: digest(bytes), consentVersion: o.consentVersion });
      const permit = () => this.#permit(credentials, intent);
      permit(); await this.#checkpoint.advance({ signal: o.signal }); permit();
      const handle = await this.#normalizer.prepare({ bytes, versionID: o.versionID, requestID: o.requestID, authorize: permit, signal: o.signal }); permit();
      await this.#state.rememberDescriptor(intent, { requestID: o.requestID, image: normalizedAvatarManifest(handle, "image"), thumbnail: normalizedAvatarManifest(handle, "thumbnail") });
      permit(); await this.#checkpoint.advance({ signal: o.signal }); permit();
      const receipt = await this.#assets.stage({ accessToken: o.accessToken, normalized: handle, requestID: o.requestID, authorizeMutation: permit, signal: o.signal });
      permit(); await this.#state.staged(intent, receipt); permit();
      await this.#checkpoint.advance({ signal: o.signal }); permit();
      return this.#final(credentials, intent);
    } catch (e) { throw this.#error(e); }
    finally { bytes?.fill(0); }
  }
  async prepareRecovery(value = {}) {
    try {
      if (this.#withdrawalOnly) throw new AvatarPolicyError("AVATAR_SCOPE");
      const o = this.#options(value, ["accessToken", "signal", "requestID"]), { accountID } = this.#identity(o);
      await this.#checkpoint.verify({ signal: o.signal }); this.#identity(o, accountID);
      await this.#state.ensureSelectionExpiry(accountID); this.#identity(o, accountID);
      const status = this.#state.snapshot(accountID);
      if (status.status === "expired" && status.requestID === o.requestID) return () => {
        this.#identity(o, accountID); const current = this.#state.snapshot(accountID);
        if (current.status !== "expired" || current.requestID !== status.requestID || current.versionID !== status.versionID || current.generation !== status.generation) throw new AvatarPolicyError("AVATAR_STALE");
        return current;
      };
      const intent = this.#state.intent(accountID, o.requestID), permit = () => this.#permit(o, intent);
      if (intent.kind === "clear") return await this.#writePointer(o, intent);
      const descriptor = this.#state.descriptor(intent);
      const receipt = await this.#assets.recover({ accessToken: o.accessToken, descriptor: {
        image: descriptor.image, thumbnail: descriptor.thumbnail, requestID: descriptor.requestID }, authorizeMutation: permit, signal: o.signal });
      permit(); await this.#state.staged(intent, receipt); permit();
      await this.#checkpoint.advance({ signal: o.signal }); permit();
      return this.#final(o, intent);
    } catch (e) { throw this.#error(e); }
  }
  async #writePointer(options, intent) {
    const publish = intent.kind === "select", lease = publish ? this.#state.publishLease(intent) : intent;
    const permit = () => this.#permit(options, lease, publish); permit();
    const receipt = await this.#profiles.writeLatest({ accessToken: options.accessToken, kind: "avatarprofile", logicalID: "singleton",
      requestID: intent.requestID, input: { versionID: intent.versionID ?? "", generation: intent.generation }, authorizeMutation: permit, signal: options.signal });
    permit(); await this.#state.finish(lease, receipt); permit();
    await this.#checkpoint.advance({ signal: options.signal }); permit();
    return this.#final(options, lease, publish);
  }
  async preparePublish(value = {}) {
    try {
      if (this.#withdrawalOnly) throw new AvatarPolicyError("AVATAR_SCOPE");
      const o = this.#options(value, ["accessToken", "signal", ...avatarPublicationKeys]), { accountID } = this.#identity(o);
      const selected = Object.fromEntries(avatarPublicationKeys.map(key => [key, o[key]]));
      if (!validAvatarPublicationIntent(selected)) throw new AvatarPolicyError("AVATAR_INPUT");
      await this.#checkpoint.verify({ signal: o.signal }); this.#identity(o, accountID);
      const intent = this.#state.intent(accountID, selected.requestID);
      if (intent.versionID !== selected.versionID || intent.generation !== selected.generation) throw new AvatarPolicyError("AVATAR_STALE");
      return await this.#writePointer(o, { ...intent, reviewRevision: selected.reviewRevision });
    } catch (e) { throw this.#error(e); }
  }
  async prepareClear(value = {}) {
    try {
      const o = this.#options(value, ["accessToken", "signal", "requestID", "expectedGeneration"]), { accountID } = this.#identity(o);
      await this.#checkpoint.verify({ signal: o.signal }); this.#identity(o, accountID);
      const intent = await this.#state.clear({ accountID, requestID: o.requestID, expectedGeneration: o.expectedGeneration });
      this.#permit(o, intent); await this.#checkpoint.advance({ signal: o.signal }); this.#permit(o, intent);
      return await this.#writePointer(o, intent);
    } catch (e) { throw this.#error(e); }
  }
  async prepareStatus(value = {}) {
    try {
      const o = this.#options(value, ["accessToken", "signal"]), { accountID } = this.#identity(o);
      await this.#checkpoint.verify({ signal: o.signal }); this.#identity(o, accountID);
      await this.#state.ensureSelectionExpiry(accountID); this.#identity(o, accountID);
      return () => { this.#identity(o, accountID); return this.#state.snapshot(accountID); };
    } catch (e) { throw this.#error(e); }
  }
  #operatorIdentity(signal) {
    try {
      if (signal?.aborted || this.#enabled() !== true || !this.#operator) throw new AvatarPolicyError("AVATAR_SCOPE");
      const identity = this.#operator();
      if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarPolicyError("AVATAR_SCOPE"); }
      if (typeof identity?.operatorID !== "string" || !publicUUID.test(identity.operatorID) || identity.scope !== "avatar-review" ||
          signal?.aborted || this.#enabled() !== true) throw new AvatarPolicyError("AVATAR_SCOPE");
      return identity.operatorID;
    } catch (e) { throw e instanceof AvatarPolicyError ? e : new AvatarPolicyError("AVATAR_SCOPE"); }
  }
  /** Trusted operator adapter only. There is NO public HTTP action minting this authority.
   * Actual review UI/content inspection is an activation prerequisite, not implemented by this hook.
   */
  async prepareReview(value = {}) {
    try {
      if (this.#withdrawalOnly) throw new AvatarPolicyError("AVATAR_SCOPE");
      const o = this.#options(value, ["accountID", "requestID", "decisionID", "expectedRevision", "verdict", "signal"]);
      const reviewerID = this.#operatorIdentity(o.signal);
      await this.#checkpoint.verify({ signal: o.signal });
      if (this.#operatorIdentity(o.signal) !== reviewerID) throw new AvatarPolicyError("AVATAR_SCOPE");
      const result = await this.#state.review({ ...o, reviewerID });
      await this.#checkpoint.advance({ signal: o.signal });
      return () => { if (this.#operatorIdentity(o.signal) !== reviewerID) throw new AvatarPolicyError("AVATAR_SCOPE"); this.#state.assertReviewCurrent(result); return result; };
    } catch (e) { throw this.#error(e); }
  }
}
