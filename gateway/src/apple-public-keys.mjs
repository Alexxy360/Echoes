import { Buffer } from "node:buffer";

export const appleKeysURL = "https://appleid.apple.com/auth/keys";
export class AppleKeysUnavailable extends Error {
  constructor() { super("Apple verification keys are unavailable."); }
}
export class AppleKeyNotFound extends Error {
  constructor() { super("Apple verification key was not found."); }
}

export function base64URLBytes(value, maximumBytes) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value) ||
      value.length > Math.ceil(maximumBytes * 4 / 3)) throw new TypeError("Invalid encoding.");
  const bytes = Buffer.from(value, "base64url");
  if (bytes.length > maximumBytes || bytes.toString("base64url") !== value) throw new TypeError("Invalid encoding.");
  return bytes;
}

async function readKeySet(response) {
  if (!response.ok || !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") || !response.body) {
    await response.body?.cancel(); throw new AppleKeysUnavailable();
  }
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 65536) throw new AppleKeysUnavailable();
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const value of chunks) { bytes.set(value, offset); offset += value.length; }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

/** Public keys only. No tokens, user identifiers, arbitrary URLs or developer secrets are sent. */
export class ApplePublicKeySource {
  #fetch; #clock; #subtle;
  #keys = new Map(); #expiresAt = 0; #nextFetchAt = 0; #pending;

  constructor({ fetchImplementation = (request, options) => fetch(request, options),
    clock = Date.now, subtle = globalThis.crypto.subtle } = {}) {
    this.#fetch = fetchImplementation; this.#clock = clock; this.#subtle = subtle;
  }

  async key(kid) {
    if (typeof kid !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(kid)) throw new AppleKeysUnavailable();
    let now = this.#clock();
    if (now < this.#expiresAt && this.#keys.has(kid)) return this.#keys.get(kid);
    if (!this.#pending && now >= this.#nextFetchAt) {
      // Per-instance cooldown, including failures and attacker-chosen unknown kids.
      // An HTTP authentication endpoint additionally needs a durable request limit.
      this.#nextFetchAt = now + 60000;
      this.#pending = this.#refresh(now).finally(() => { this.#pending = undefined; });
    }
    if (!this.#pending) {
      if (now < this.#expiresAt) throw new AppleKeyNotFound();
      throw new AppleKeysUnavailable();
    }
    await this.#pending;
    now = this.#clock();
    if (now >= this.#expiresAt) throw new AppleKeysUnavailable();
    if (!this.#keys.has(kid)) throw new AppleKeyNotFound();
    return this.#keys.get(kid);
  }

  async #refresh(startedAt) {
    try {
      const response = await this.#fetch(new Request(appleKeysURL, {
        redirect: "manual", headers: { Accept: "application/json" },
      }), { signal: AbortSignal.timeout(5000) });
      const body = await readKeySet(response);
      if (!Array.isArray(body?.keys) || body.keys.length < 1 || body.keys.length > 8) throw new AppleKeysUnavailable();
      const keys = new Map();
      for (const jwk of body.keys) {
        // Apple OIDC discovery advertises RS256. Never derive the allowed algorithm from a JWT.
        if (jwk?.kty !== "RSA" || jwk.alg !== "RS256" || jwk.use !== "sig") continue;
        if (typeof jwk.kid !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(jwk.kid) || keys.has(jwk.kid) ||
            jwk.e !== "AQAB" || jwk.d !== undefined) throw new AppleKeysUnavailable();
        const modulus = base64URLBytes(jwk.n, 512);
        if (modulus.length < 256 || !(modulus[0] & 0x80)) throw new AppleKeysUnavailable();
        const key = await this.#subtle.importKey("jwk", {
          kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true,
        }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
        keys.set(jwk.kid, key);
      }
      if (!keys.size) throw new AppleKeysUnavailable();
      this.#keys = keys; this.#expiresAt = startedAt + 3600000;
    } catch { throw new AppleKeysUnavailable(); }
  }
}
