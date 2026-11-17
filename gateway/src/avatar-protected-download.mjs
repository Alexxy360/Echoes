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
  let url; try { url = new URL(value); } catch { throw new AvatarDownloadError(); }
  if (url.protocol !== "https:" || url.port || url.username || url.password || url.hash || url.href !== value || !hosts.has(url.hostname)) throw new AvatarDownloadError();
  return url.href;
}
export async function readAvatarDownload(response, { url, manifest, signal, check }) {
  const length = response?.headers?.get("Content-Length"), encoding = response?.headers?.get("Content-Encoding");
  if (!(response instanceof Response) || response.status !== 200 || response.redirected || response.url && response.url !== url || !response.body ||
      !/^(image\/jpeg|application\/octet-stream)(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") ||
      response.headers.has("Content-Range") || encoding !== null && encoding !== "identity" ||
      length !== null && (!/^\d+$/.test(length) || Number(length) !== manifest.byteCount)) {
    void response?.body?.cancel().catch(() => {}); throw new AvatarDownloadError();
  }
  const reader = response.body.getReader(), parts = []; let size = 0;
  const abort = () => { void reader.cancel().catch(() => {}); }; signal.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      check(); const { value, done } = await reader.read(); if (done) break;
      if (!(value instanceof Uint8Array) || value.byteLength === 0 || parts.length >= 128 || (size += value.byteLength) > manifest.byteCount) throw new AvatarDownloadError();
      parts.push(value.slice());
    }
    check(); if (size !== manifest.byteCount) throw new AvatarDownloadError();
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
    return bytes;
  } finally { signal.removeEventListener("abort", abort); void reader.cancel().catch(() => {}); reader.releaseLock(); for (const part of parts) part.fill(0); }
}
