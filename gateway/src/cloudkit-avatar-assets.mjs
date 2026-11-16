import { createHash } from "node:crypto";
import { CloudKitDevelopmentSigner } from "./cloudkit-request.mjs";
import { PublicRecordError, plain, publicRecordName, publicRecordTypes, publicUUID } from "./public-record-schema.mjs";
import { avatarReceipt } from "./avatar-receipt-vault.mjs";

const responseLimit = 16 * 1024;
const appleDomains = ["icloud-content.com", "icloud.com", "apple-cloudkit.com"];
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
const exact = (value, names) => plain(value) && Object.keys(value).sort().join("|") === [...names].sort().join("|");
class UploadedAvatarAsset {
  toJSON() { return "<uploaded-avatar-asset>"; }
  toString() { return "<uploaded-avatar-asset>"; }
}

/** Internal Development/public upload primitive, NEVER an HTTP proxy or a JPEG validator.
 * The coordinator must supply a reserved immutable avatar and freshly enforce session/consent.
 * Runtime integration stays disabled until server normalization, moderation and provider acceptance.
 */
export class CloudKitAvatarAssets {
  #signer; #fetch; #registry; #checkpoint; #enabled; #clock; #timeout; #hosts; #vault; #handles = new WeakMap();
  constructor({ container, environment, keyID, privateKeyPEM, registry, checkpoint, receiptVault,
    verifiedUploadHosts = [], fetchImplementation = fetch, isEnabled, clock = Date.now, timeoutMilliseconds = 8000 } = {}) {
    if (container !== "iCloud.mpvEcho.Echo" || environment !== "development" ||
        typeof registry?.claimAvatarTransfer !== "function" || typeof registry.assertAvatarTransferCurrent !== "function" ||
        typeof registry.acknowledgeAvatarTransfer !== "function" || typeof registry.avatarReceipt !== "function" ||
        typeof receiptVault?.seal !== "function" || typeof receiptVault.open !== "function" || typeof checkpoint?.verify !== "function" ||
        typeof checkpoint.advance !== "function" || typeof fetchImplementation !== "function" || typeof isEnabled !== "function" ||
        typeof clock !== "function" || !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 8000 ||
        !Array.isArray(verifiedUploadHosts) || verifiedUploadHosts.length < 1 || verifiedUploadHosts.length > 8 ||
        new Set(verifiedUploadHosts).size !== verifiedUploadHosts.length || verifiedUploadHosts.some(host =>
          typeof host !== "string" || host.length > 253 || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(host) ||
          !appleDomains.some(domain => host.endsWith("." + domain)))) throw new PublicRecordError("PUBLIC_INPUT");
    try { this.#signer = new CloudKitDevelopmentSigner({ container, environment, keyID, privateKeyPEM }); }
    catch { throw new PublicRecordError(); }
    this.#registry = registry; this.#checkpoint = checkpoint; this.#fetch = fetchImplementation;
    this.#enabled = isEnabled; this.#clock = clock; this.#timeout = timeoutMilliseconds;
    this.#vault = receiptVault;
    this.#hosts = new Set(verifiedUploadHosts);
  }
  #now() {
    let now;
    try { now = this.#clock(); } catch { throw new PublicRecordError(); }
    if (!Number.isSafeInteger(now) || now < 0) throw new PublicRecordError();
    return now;
  }
  #check(signal, authorize, lease, accountID = lease?.context.accountID) {
    if (signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
    const result = authorize();
    if (signal?.aborted || this.#enabled() !== true) {
      void result?.catch?.(() => {}); throw new PublicRecordError();
    }
    if (typeof accountID !== "string" || !publicUUID.test(accountID) || result?.accountID !== accountID || result && typeof result.then === "function") {
      void result?.catch?.(() => {}); throw new PublicRecordError("PUBLIC_SCOPE");
    }
    if (lease) this.#registry.assertAvatarTransferCurrent(lease);
    if (signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
  }
  #url(value) {
    if (typeof value !== "string" || value.length > 8192 || /[^\x21-\x7e]/.test(value)) throw new PublicRecordError("PUBLIC_RESPONSE");
    let url;
    try { url = new URL(value); } catch { throw new PublicRecordError("PUBLIC_RESPONSE"); }
    if (url.protocol !== "https:" || url.port || url.username || url.password || url.hash || url.href !== value ||
        !this.#hosts.has(url.hostname)) throw new PublicRecordError("PUBLIC_RESPONSE");
    return url.href;
  }
  async #json(response, signal, check) {
    if (!(response instanceof Response) || !response.ok) {
      await response?.body?.cancel().catch(() => {});
      throw new PublicRecordError(response?.status === 429 ? "PUBLIC_THROTTLED" : "PUBLIC_UNAVAILABLE");
    }
    const length = response.headers.get("Content-Length");
    if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") || !response.body ||
        length !== null && (!/^\d+$/.test(length) || Number(length) > responseLimit)) {
      await response.body?.cancel().catch(() => {}); throw new PublicRecordError("PUBLIC_RESPONSE");
    }
    const reader = response.body.getReader(), parts = []; let size = 0;
    const abort = () => { void reader.cancel().catch(() => {}); };
    signal.addEventListener("abort", abort, { once: true });
    try {
      while (true) {
        check();
        const { value, done } = await reader.read();
        if (done) break;
        if (!(value instanceof Uint8Array) || value.byteLength === 0 || parts.length >= 64 ||
            (size += value.byteLength) > responseLimit) throw new PublicRecordError("PUBLIC_RESPONSE");
        parts.push(value.slice());
      }
      check();
      if (length !== null && size !== Number(length)) throw new PublicRecordError("PUBLIC_RESPONSE");
      const bytes = new Uint8Array(size); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } finally {
      signal.removeEventListener("abort", abort); await reader.cancel().catch(() => {}); reader.releaseLock();
    }
  }
  #receipt(body, size) {
    if (!exact(body, ["singleFile"])) throw new PublicRecordError("PUBLIC_RESPONSE");
    return avatarReceipt(body.singleFile, size);
  }
  async upload({ context, variant, bytes, sha256, authorizeMutation, signal } = {}) {
    if (typeof authorizeMutation !== "function" || context?.kind !== "avatar" || context.recordType !== publicRecordTypes.avatar ||
        !publicRecordName.test(context.recordName ?? "") || !context.recordName.startsWith("community-v1-avatar-") ||
        !["image", "thumbnail"].includes(variant) || !(bytes instanceof Uint8Array) ||
        typeof SharedArrayBuffer !== "undefined" && bytes.buffer instanceof SharedArrayBuffer || bytes.byteLength < 1 ||
        bytes.byteLength > (variant === "image" ? 256000 : 32000) || typeof sha256 !== "string" || !/^[a-f0-9]{64}$/.test(sha256)) throw new PublicRecordError("PUBLIC_INPUT");
    const snapshot = new Uint8Array(bytes);
    if (digest(snapshot) !== sha256) throw new PublicRecordError("PUBLIC_INPUT");
    const startedAt = this.#now(), deadline = startedAt + this.#timeout;
    const controller = new AbortController(); let timer, rejectCancellation, lease;
    const cancelled = new Promise((_, reject) => { rejectCancellation = reject; });
    const abort = () => { controller.abort(); rejectCancellation(new PublicRecordError()); };
    signal?.addEventListener("abort", abort, { once: true });
    const transportCheck = () => {
      const now = this.#now();
      if (signal?.aborted || controller.signal.aborted || this.#enabled() !== true || now < startedAt || now >= deadline) throw new PublicRecordError();
    };
    const check = () => {
      transportCheck();
      this.#check(controller.signal, authorizeMutation, lease, context.accountID);
      transportCheck();
    };
    try {
      timer = setTimeout(abort, this.#timeout);
      const work = Promise.resolve().then(async () => {
        check();
        await this.#checkpoint.verify({ signal: controller.signal }); check();
        lease = await this.#registry.claimAvatarTransfer(context, { variant, sha256, byteCount: snapshot.byteLength }); check();
        await this.#checkpoint.advance({ signal: controller.signal }); check();
        const request = this.#signer.request("assets/upload", { tokens: [{ recordName: context.recordName,
          recordType: publicRecordTypes.avatar, fieldName: variant }] }, new Date(this.#now()));
        check();
        const grants = await this.#json(await this.#fetch(request, { signal: controller.signal }), controller.signal, transportCheck); check();
        if (!exact(grants, ["tokens"]) || !Array.isArray(grants.tokens) || grants.tokens.length !== 1 ||
            !exact(grants.tokens[0], ["recordName", "fieldName", "url"]) || grants.tokens[0].recordName !== context.recordName ||
            grants.tokens[0].fieldName !== variant) throw new PublicRecordError("PUBLIC_RESPONSE");
        const url = this.#url(grants.tokens[0].url);
        // Fresh Request: never forward S2S signature, bearer, cookies or Location to the asset host.
        const upload = new Request(url, { method: "POST", redirect: "manual", credentials: "omit",
          headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" }, body: snapshot });
        check();
        const body = await this.#json(await this.#fetch(upload, { signal: controller.signal }), controller.signal, transportCheck); check();
        const receipt = this.#receipt(body, snapshot.byteLength);
        const envelope = this.#vault.seal(receipt, lease), expiresAt = this.#now() + 120000;
        await this.#registry.acknowledgeAvatarTransfer(lease, digest(JSON.stringify(receipt)), digest(receipt.fileChecksum), { envelope, expiresAt }); check();
        await this.#checkpoint.advance({ signal: controller.signal }); check();
        const handle = Object.freeze(new UploadedAvatarAsset());
        this.#handles.set(handle, { receipt, lease, createdAt: this.#now() });
        return handle;
      });
      return await Promise.race([work, cancelled]);
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
    finally { clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", abort); }
  }
  /** Explicit restart recovery only. No grant or upload is repeated, and no caller supplies receipt. */
  resumedRecordField({ context, variant, authorizeMutation, signal } = {}) {
    try {
      if (typeof authorizeMutation !== "function") throw new PublicRecordError("PUBLIC_INPUT");
      this.#check(signal, authorizeMutation, undefined, context?.accountID);
      const stored = this.#registry.avatarReceipt(context, variant), receipt = this.#vault.open(stored.envelope, stored.lease);
      if (digest(JSON.stringify(receipt)) !== stored.receiptHash || digest(receipt.fileChecksum) !== stored.fileChecksumHash) throw new PublicRecordError("PUBLIC_SCOPE");
      this.#check(signal, authorizeMutation, undefined, context?.accountID);
      const current = this.#registry.avatarReceipt(context, variant);
      if (current.envelope !== stored.envelope || current.receiptHash !== stored.receiptHash) throw new PublicRecordError("PUBLIC_SCOPE");
      return { type: "ASSET", value: { ...receipt } };
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
  /** Trusted record builder only. No raw handle/receipt may enter an HTTP response or logs. */
  recordField(handle, { context, variant, authorizeMutation, signal } = {}) {
    try {
      const value = this.#handles.get(handle), now = this.#now();
      if (!value || typeof authorizeMutation !== "function" || now < value.createdAt || now >= value.createdAt + 120000) throw new PublicRecordError("PUBLIC_SCOPE");
      if (value.lease.variant !== variant || !context || ["recordName", "requestID", "payloadHash", "generation"].some(key =>
        context[key] !== value.lease.context[key])) throw new PublicRecordError("PUBLIC_SCOPE");
      this.#check(signal, authorizeMutation, value.lease);
      this.#registry.assertMutationCurrent(context);
      return { type: "ASSET", value: { ...value.receipt } };
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
}
