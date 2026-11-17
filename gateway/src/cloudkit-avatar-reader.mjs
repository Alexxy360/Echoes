import { plain, publicUUID, recordIdentity, digest } from "./public-record-schema.mjs";
import { validateAvatarRecord } from "./avatar-record-schema.mjs";
import { inspectAvatarJPEG } from "./avatar-jpeg.mjs";
import { AvatarDownloadError, avatarDownloadHosts, avatarDownloadURL, readAvatarDownload } from "./avatar-protected-download.mjs";
import { communityCoordinate, communityPolicy, distanceMeters } from "./community-domain.mjs";

export const avatarManifestHeader = "X-Echoes-Avatar-Manifest";
const codes = new Set(["AVATAR_READ_INPUT", "AVATAR_READ_NOT_FOUND", "AVATAR_READ_STALE", "AVATAR_READ_UNAVAILABLE", "AVATAR_READ_RESPONSE", "AVATAR_READ_LIMIT"]);
export class AvatarReadError extends Error {
  constructor(code = "AVATAR_READ_UNAVAILABLE") { super("Profile photo could not be loaded."); this.code = codes.has(code) ? code : "AVATAR_READ_UNAVAILABLE"; }
}
/** Internal protected read with one-shot response finalizer. No generic URL/record input, CDN or
 * persisted bytes. Trusted host must keep one instance and apply HTTP admission before prepare().
 */
export class CloudKitAvatarReader {
  #authentication; #community; #policy; #profiles; #registry; #client; #checkpoint; #enabled; #clock; #fetch; #hosts; #timeout; #active = 0;
  constructor({ authentication, communityState, avatarPolicy, profileRepository, registry, client, checkpoint, isEnabled,
    verifiedDownloadHosts = [], fetchImplementation = fetch, clock = Date.now, timeoutMilliseconds = 8000 } = {}) {
    if (typeof authentication?.authorize !== "function" || typeof communityState?.assertActive !== "function" || typeof communityState.visible !== "function" ||
        typeof avatarPolicy?.readPublication !== "function" || typeof avatarPolicy.assertReadPublication !== "function" || typeof profileRepository?.beginRead !== "function" ||
        typeof registry?.readAvatarAssetCommitments !== "function" || typeof client?.lookup !== "function" || typeof checkpoint?.advance !== "function" ||
        typeof isEnabled !== "function" || typeof fetchImplementation !== "function" || typeof clock !== "function" ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000 ||
        !Array.isArray(verifiedDownloadHosts)) throw new AvatarReadError("AVATAR_READ_INPUT");
    this.#authentication = authentication; this.#community = communityState; this.#policy = avatarPolicy; this.#profiles = profileRepository;
    this.#registry = registry; this.#client = client; this.#checkpoint = checkpoint; this.#enabled = isEnabled; this.#clock = clock;
    this.#fetch = fetchImplementation; this.#timeout = timeoutMilliseconds;
    try { this.#hosts = avatarDownloadHosts(verifiedDownloadHosts); } catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
  }
  #now() { let value; try { value = this.#clock(); } catch { throw new AvatarReadError(); }
    if (!Number.isSafeInteger(value) || value < 0) throw new AvatarReadError(); return value; }
  #options(value) {
    if (!plain(value) || Object.keys(value).some(key => !["accessToken", "ownerID", "versionID", "variant", "coordinate", "knownSHA256", "signal"].includes(key)) ||
        [value.ownerID, value.versionID].some(v => typeof v !== "string" || !publicUUID.test(v)) || !["image", "thumbnail"].includes(value.variant) ||
        value.knownSHA256 !== undefined && (typeof value.knownSHA256 !== "string" || !/^[a-f0-9]{64}$/.test(value.knownSHA256)) ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) throw new AvatarReadError("AVATAR_READ_INPUT");
    let coordinate;
    if (value.coordinate !== undefined) { try { coordinate = Object.freeze(communityCoordinate(value.coordinate)); } catch { throw new AvatarReadError("AVATAR_READ_INPUT"); } }
    return Object.freeze({ ...value, coordinate });
  }
  #identity(options, expected) {
    try {
      if (options.signal?.aborted || this.#enabled() !== true) throw new AvatarReadError();
      const identity = this.#authentication.authorize(options.accessToken);
      if (identity && typeof identity.then === "function") { void identity.catch?.(() => {}); throw new AvatarReadError("AVATAR_READ_STALE"); }
      if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || expected !== undefined && identity.accountID !== expected) throw new AvatarReadError("AVATAR_READ_STALE");
      this.#community.assertActive(identity.accountID); return identity;
    } catch (e) { throw e instanceof AvatarReadError ? e : new AvatarReadError("AVATAR_READ_STALE"); }
  }
  #publication(accountID) {
    try { return this.#policy.readPublication(accountID); }
    catch (e) { throw new AvatarReadError(["AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED"].includes(e?.code) ? "AVATAR_READ_NOT_FOUND" : "AVATAR_READ_UNAVAILABLE"); }
  }
  #error(e) {
    if (e instanceof AvatarReadError) return e;
    if (e instanceof AvatarDownloadError) return new AvatarReadError("AVATAR_READ_RESPONSE");
    if (["AVATAR_STALE", "AVATAR_PENDING", "AVATAR_REJECTED"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_NOT_FOUND");
    if (["PUBLIC_RESPONSE", "PUBLIC_SCOPE", "PUBLIC_CONFLICT", "PUBLIC_INPUT"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_RESPONSE");
    if (["PUBLIC_LIMIT", "PUBLIC_THROTTLED"].includes(e?.code)) return new AvatarReadError("AVATAR_READ_LIMIT");
    return new AvatarReadError();
  }
  async prepare(value = {}) {
    const options = this.#options(value), startedAt = this.#now(), expiresAt = startedAt + this.#timeout;
    if (!Number.isSafeInteger(expiresAt)) throw new AvatarReadError();
    if (this.#active >= 4) throw new AvatarReadError("AVATAR_READ_LIMIT");
    this.#active++;
    const controller = new AbortController(); let timer, data, closed = false, settled = false, released = false, rejectCancellation;
    const cancelled = new Promise((_, reject) => { rejectCancellation = reject; });
    const release = () => { if (closed && settled && !released) { released = true; this.#active--; } };
    const dispose = () => { if (closed) return; closed = true; clearTimeout(timer); controller.abort(); options.signal?.removeEventListener("abort", cancel);
      data?.fill(0); data = undefined; release(); };
    const cancel = () => { dispose(); rejectCancellation(new AvatarReadError()); };
    const transport = () => { const now = this.#now(); if (closed || controller.signal.aborted || options.signal?.aborted || this.#enabled() !== true || now < startedAt || now >= expiresAt) throw new AvatarReadError(); };
    try {
      timer = setTimeout(cancel, this.#timeout); options.signal?.addEventListener("abort", cancel, { once: true });
      const work = (async () => {
        let response;
        try {
          transport(); const viewerID = this.#identity(options).accountID, peer = viewerID !== options.ownerID;
          if (peer && !options.coordinate) throw new AvatarReadError("AVATAR_READ_INPUT");
          const publication = this.#publication(options.ownerID);
          if (publication.versionID !== options.versionID) throw new AvatarReadError("AVATAR_READ_NOT_FOUND");
          const check = () => { transport(); this.#identity(options, viewerID); this.#policy.assertReadPublication(publication); };
          const lease = await this.#profiles.beginRead({ accessToken: options.accessToken, signal: controller.signal }); check();
          const [pointer] = await lease.lookup([publication.pointer.recordName], "avatarprofile"); check();
          if (!pointer || pointer.record.recordChangeTag !== publication.pointerTag || pointer.input.versionID !== publication.versionID || pointer.input.generation !== publication.generation) throw new AvatarReadError("AVATAR_READ_NOT_FOUND");
          const [presence] = peer ? await lease.lookup([recordIdentity(options.ownerID, "presence", "singleton").recordName], "presence") : [];
          let commitments;
          const guard = () => {
            check();
            if (!lease.current(pointer) || peer && (!presence || !lease.current(presence) || presence.input.active !== 1 ||
                presence.record.fields.expiresAt.value <= this.#now() || !this.#community.visible(viewerID, presence.context) ||
                distanceMeters(options.coordinate, presence.input) > communityPolicy.radius)) throw new AvatarReadError("AVATAR_READ_NOT_FOUND");
            if (commitments) {
              const current = this.#registry.readAvatarAssetCommitments(publication.avatar);
              if (["image", "thumbnail"].some(v => ["sha256", "byteCount", "fileChecksumHash"].some(k => current[v][k] !== commitments[v][k]))) throw new AvatarReadError("AVATAR_READ_RESPONSE");
            }
          };
          guard();
          const record = (await this.#client.lookup([publication.avatar.recordName], { signal: controller.signal })).get(publication.avatar.recordName); guard();
          if (record?.serverErrorCode === "NOT_FOUND") throw new AvatarReadError("AVATAR_READ_NOT_FOUND");
          if (record?.serverErrorCode) throw new AvatarReadError(record.serverErrorCode === "THROTTLED" ? "AVATAR_READ_LIMIT" : "AVATAR_READ_UNAVAILABLE");
          commitments = this.#registry.readAvatarAssetCommitments(publication.avatar);
          const projection = validateAvatarRecord(record, publication.avatar, publication.descriptor, commitments), manifest = publication.descriptor[options.variant];
          const revalidated = options.knownSHA256 === manifest.sha256;
          if (!revalidated) {
            const url = avatarDownloadURL(projection.assets[options.variant].downloadURL, this.#hosts);
            const request = new Request(url, { method: "GET", redirect: "manual", credentials: "omit", headers: { Accept: "image/jpeg", "Cache-Control": "no-store" } });
            guard(); response = await this.#fetch(request, { signal: controller.signal }); guard();
            data = await readAvatarDownload(response, { url, manifest, signal: controller.signal, check: transport }); guard();
            if (digest(data) !== manifest.sha256) throw new AvatarReadError("AVATAR_READ_RESPONSE");
            const header = inspectAvatarJPEG(data, { maximumBytes: options.variant === "image" ? 256000 : 32000, maximumPixels: options.variant === "image" ? 512 : 128 });
            try { if (header.width !== manifest.width || header.height !== manifest.height || digest(header.bytes) !== manifest.sha256) throw new AvatarReadError("AVATAR_READ_RESPONSE"); }
            finally { header.bytes.fill(0); }
          }
          guard(); await this.#checkpoint.advance({ signal: controller.signal }); guard();
          return () => {
            try {
              guard();
              const headers = new Headers({ "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", [avatarManifestHeader]: JSON.stringify(manifest) });
              if (!revalidated) { headers.set("Content-Type", "image/jpeg"); headers.set("Content-Length", String(manifest.byteCount)); }
              return new Response(revalidated ? null : data.slice(), { status: revalidated ? 204 : 200, headers });
            } catch (e) { throw this.#error(e); } finally { dispose(); }
          };
        } finally {
          if (response?.body && !response.body.locked) void response.body.cancel().catch(() => {});
          settled = true;
          if (closed) { data?.fill(0); data = undefined; }
          release();
        }
      })();
      return await Promise.race([work, cancelled]);
    } catch (e) { dispose(); throw this.#error(e); }
  }
}
