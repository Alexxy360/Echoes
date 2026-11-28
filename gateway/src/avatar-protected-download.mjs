import { normalizeHTTPSAssetAuthority } from "./cloudkit-asset-url.mjs";

/** Only provider-projected URLs, never request JSON. Shared by publication reads and moderation. */
export class AvatarDownloadError extends Error {
  constructor() { super("Photo content could not be loaded."); this.code = "AVATAR_DOWNLOAD_RESPONSE"; }
}
export function avatarDownloadHosts(value) {
  const domains = ["icloud-content.com", "icloud.com", "apple-cloudkit.com"];
  if (!Array.isArray(value) || value.length < 1 || value.length > 8 || new Set(value).size !== value.length ||
      value.some(host => typeof host !== "string" || host.length > 253 || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(host) ||
        !domains.some(domain => host.endsWith("." + domain)))) throw new AvatarDownloadError();
  return new Set(value);
}
export function avatarDownloadURL(value, hosts) {
  if (typeof value !== "string" || value.length > 8192 || /[^\x21-\x7e]/.test(value)) throw new AvatarDownloadError();
  // CloudKit documents a filename placeholder. Expand one entire terminal path segment only;
  // never replace bytes in the signed query, authority or any caller-provided filename.
  if (value.includes("${f}")) {
    const query = value.indexOf("?"), path = query < 0 ? value : value.slice(0, query);
    if (value.split("${f}").length !== 2 || !path.endsWith("/${f}")) throw new AvatarDownloadError();
    value = value.replace("${f}", "avatar.jpg");
  }
  let url; try { url = new URL(value); } catch { throw new AvatarDownloadError(); }
  if (url.protocol !== "https:" || url.port || url.username || url.password || value.includes("#") || url.href !== normalizeHTTPSAssetAuthority(value) || !hosts.has(url.hostname)) throw new AvatarDownloadError();
  return url.href;
}
/** One scope per retained reader/coordinator. Unknown drain closes admission until recreation. */
export class AvatarDownloadScope {
  #unsafe = false;
  check() { if (this.#unsafe) throw new AvatarDownloadError(); }
  operation() { this.check(); return new AvatarDownloadOperation(() => { this.#unsafe = true; }); }
}
/** Own the exact response as soon as fetch returns, including after caller cancellation. */
class AvatarDownloadOperation {
  #response; #reader; #cancellation; #draining; #finishing; #unsafe;
  constructor(unsafe) { this.#unsafe = unsafe; }
  adopt(response) {
    if (!(response instanceof Response) || this.#response !== undefined) throw new AvatarDownloadError();
    this.#response = response;
  }
  #cancel() {
    return this.#cancellation ??= Promise.resolve().then(() => (this.#reader ?? this.#response?.body)?.cancel())
      .catch(() => { this.#unsafe(); throw new AvatarDownloadError(); });
  }
  drain() {
    return this.#draining ??= (async () => {
      try {
        if (!this.#reader && this.#response?.body?.locked) throw new AvatarDownloadError();
        await this.#cancel();
        this.#reader?.releaseLock();
      } catch { this.#unsafe(); throw new AvatarDownloadError(); }
    })();
  }
  /** Also await the concrete CloudKit client's actual late fetch/body/cancel work. */
  finish(client) {
    return this.#finishing ??= (async () => {
      const results = await Promise.allSettled([this.drain(), Promise.resolve().then(() => client.waitForPendingOperations())]);
      if (results.some(result => result.status === "rejected")) { this.#unsafe(); throw new AvatarDownloadError(); }
    })();
  }
  async read({ url, manifest, signal, check }) {
    const response = this.#response, parts = []; let size = 0, bytes;
    const abort = () => { void this.#cancel().catch(() => {}); };
    try {
      const length = response?.headers?.get("Content-Length"), encoding = response?.headers?.get("Content-Encoding");
      if (!(response instanceof Response) || response.status !== 200 || response.redirected || response.url && response.url !== url || !response.body ||
          !/^(image\/jpeg|application\/octet-stream)(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") ||
          response.headers.has("Content-Range") || encoding !== null && encoding !== "identity" ||
          length !== null && (!/^\d+$/.test(length) || Number(length) !== manifest.byteCount)) throw new AvatarDownloadError();
      this.#reader = response.body.getReader();
      signal.addEventListener("abort", abort, { once: true });
      while (true) {
        check(); const { value, done } = await this.#reader.read(); if (done) break;
        if (!(value instanceof Uint8Array) || value.byteLength === 0 || parts.length >= 128 || (size += value.byteLength) > manifest.byteCount) throw new AvatarDownloadError();
        parts.push(value.slice());
      }
      check(); if (size !== manifest.byteCount) throw new AvatarDownloadError();
      bytes = new Uint8Array(size); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
      await this.drain(); check(); return bytes;
    } catch (error) { bytes?.fill(0); throw error; }
    finally {
      signal.removeEventListener("abort", abort);
      for (const part of parts) part.fill(0);
      try { await this.drain(); } catch (error) { bytes?.fill(0); throw error; }
    }
  }
}
