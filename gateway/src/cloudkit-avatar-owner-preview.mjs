import { plain, publicUUID, digest } from "./public-record-schema.mjs";
import { AvatarReadError, avatarManifestHeader } from "./cloudkit-avatar-reader.mjs";
import { validateAvatarRecord } from "./avatar-record-schema.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { AvatarDownloadError, avatarDownloadHosts, avatarDownloadURL, AvatarDownloadScope } from "./avatar-protected-download.mjs";
import { avatarOwnerPreviewInput, avatarSelectionHeader } from "./avatar-owner-preview-http.mjs";

/** Separate owner-only full image read. Never accepts an owner, GPS, URL, cache hash or operator role. */
export class CloudKitAvatarOwnerPreview {
  #authentication; #community; #policy; #registry; #client; #checkpoint; #enabled; #clock; #fetch; #hosts; #timeout; #occupied = false;
  #downloads = new AvatarDownloadScope();
  constructor({ authentication, communityState, avatarPolicy, registry, client, checkpoint, isEnabled,
    verifiedDownloadHosts = [], fetchImplementation = fetch, clock = Date.now, timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" ||
        typeof avatarPolicy?.readApprovedOwnerSelection !== "function" || typeof avatarPolicy.assertApprovedOwnerSelection !== "function" ||
        typeof registry?.readAvatarAssetCommitments !== "function" || typeof client?.lookup !== "function" || typeof client.waitForPendingOperations !== "function" || typeof checkpoint?.advance !== "function" ||
        typeof isEnabled !== "function" || typeof fetchImplementation !== "function" || typeof clock !== "function" ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) throw new AvatarReadError("AVATAR_READ_INPUT");
    this.#authentication = authentication; this.#community = communityState; this.#policy = avatarPolicy; this.#registry = registry;
    this.#client = client; this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#clock = clock; this.#fetch = fetchImplementation; this.#timeout = timeoutMilliseconds;
    try { this.#hosts = avatarDownloadHosts(verifiedDownloadHosts); } catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
  }
  #now() { let now; try { now = this.#clock(); } catch { throw new AvatarReadError(); }
    if (!Number.isSafeInteger(now) || now < 0) throw new AvatarReadError(); return now; }
  #identity(accessToken, expected) {
    try {
      const identity = this.#authentication.authorize(accessToken);
      if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarReadError("AVATAR_READ_STALE"); }
      if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) throw new AvatarReadError("AVATAR_READ_STALE");
      this.#community.assertActive(identity.accountID); return identity.accountID;
    } catch (e) { throw e instanceof AvatarReadError ? e : new AvatarReadError("AVATAR_READ_STALE"); }
  }
  #error(e) {
    if (e instanceof AvatarReadError) return e;
    if (["AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_NOT_FOUND");
    if (e instanceof AvatarDownloadError || ["PUBLIC_RESPONSE", "PUBLIC_SCOPE", "PUBLIC_CONFLICT", "PUBLIC_INPUT"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_RESPONSE");
    if (["PUBLIC_LIMIT", "PUBLIC_THROTTLED"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_LIMIT");
    return new AvatarReadError();
  }
  async prepare(value) {
    if (!plain(value) || Object.keys(value).some(key => !["accessToken", "requestID", "versionID", "generation", "reviewRevision", "signal"].includes(key)) ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) throw new AvatarReadError("AVATAR_READ_INPUT");
    const { accessToken, signal, ...raw } = value, selection = avatarOwnerPreviewInput(raw), started = this.#now(), expires = started + this.#timeout;
    if (!Number.isSafeInteger(expires)) throw new AvatarReadError();
    if (this.#occupied) throw new AvatarReadError("AVATAR_READ_LIMIT");
    let download; try { download = this.#downloads.operation(); } catch (error) { throw this.#error(error); }
    this.#occupied = true;
    let timer, data, closed = false, settled = false, rejectCancellation; const controller = new AbortController();
    const cancellation = new Promise((_, reject) => { rejectCancellation = reject; });
    const release = () => { if (closed && settled) this.#occupied = false; };
    const dispose = () => { if (closed) return; closed = true; clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", cancel); data?.fill(0); data = undefined; release(); };
    const cancel = () => { dispose(); rejectCancellation(new AvatarReadError()); };
    const transport = () => { this.#downloads.check(); const now = this.#now(); if (closed || controller.signal.aborted || signal?.aborted || this.#enabled() !== true || now < started || now >= expires) throw new AvatarReadError(); };
    try {
      timer = setTimeout(cancel, this.#timeout); signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        let response;
        try {
          transport(); const accountID = this.#identity(accessToken), content = this.#policy.readApprovedOwnerSelection(accountID, selection);
          let commitments;
          const revalidate = () => {
            const now = this.#now();
            if (signal?.aborted || this.#enabled() !== true || now < started || now >= expires) throw new AvatarReadError();
            this.#identity(accessToken, accountID); this.#policy.assertApprovedOwnerSelection(content);
            if (commitments) {
              const current = this.#registry.readAvatarAssetCommitments(content.avatar);
              if (["image", "thumbnail"].some(variant => ["sha256", "byteCount", "fileChecksumHash"].some(key => current[variant][key] !== commitments[variant][key]))) throw new AvatarReadError("AVATAR_READ_RESPONSE");
            }
          };
          const check = () => { transport(); revalidate(); };
          check(); const record = (await this.#client.lookup([content.avatar.recordName], { signal: controller.signal })).get(content.avatar.recordName); check();
          if (record?.serverErrorCode) throw new AvatarReadError(record.serverErrorCode === "NOT_FOUND" ? "AVATAR_READ_NOT_FOUND" : record.serverErrorCode === "THROTTLED" ? "AVATAR_READ_LIMIT" : "AVATAR_READ_UNAVAILABLE");
          commitments = this.#registry.readAvatarAssetCommitments(content.avatar);
          const projection = validateAvatarRecord(record, content.avatar, content.descriptor, commitments), manifest = content.descriptor.image;
          const url = avatarDownloadURL(projection.assets.image.downloadURL, this.#hosts);
          const request = new Request(url, { method: "GET", redirect: "manual", credentials: "omit", headers: { Accept: "image/jpeg", "Cache-Control": "no-store" } });
          check(); response = await this.#fetch(request, { signal: controller.signal }); download.adopt(response); check();
          data = await download.read({ url, manifest, signal: controller.signal, check }); check();
          if (digest(data) !== manifest.sha256) throw new AvatarReadError("AVATAR_READ_RESPONSE");
          const jpeg = inspectAvatarJPEG(data, { maximumBytes: 256000, maximumPixels: 512 });
          try { if (jpeg.width !== manifest.width || jpeg.height !== manifest.height || digest(jpeg.bytes) !== manifest.sha256) throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
          finally { jpeg.bytes.fill(0); }
          await this.#checkpoint.advance({ signal: controller.signal }); check();
          return Object.assign(() => {
            try { check(); return new Response(data.slice(), { headers: { "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
              "Content-Type": "image/jpeg", "Content-Length": String(manifest.byteCount), [avatarManifestHeader]: JSON.stringify(manifest),
              [avatarSelectionHeader]: JSON.stringify({ schemaVersion: 1, ...selection }) } }); }
            catch (e) { throw this.#error(e); } finally { dispose(); }
          }, { validate: () => { try { revalidate(); } catch (e) { throw this.#error(e); } } });
        } finally {
          let drained = false;
          try { await download.finish(this.#client); drained = true; }
          finally { settled = drained; if (closed) { data?.fill(0); data = undefined; } release(); }
        }
      })();
      return await Promise.race([work, cancellation]);
    } catch (e) { dispose(); throw this.#error(e); }
  }
}
