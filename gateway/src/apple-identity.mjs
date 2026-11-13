import { Buffer } from "node:buffer";
import { timingSafeEqual } from "node:crypto";
import { ApplePublicKeySource, AppleKeysUnavailable, base64URLBytes } from "./apple-public-keys.mjs";
import { appleSubjectHash } from "./refresh-credential-vault.mjs";

const issuer = "https://appleid.apple.com";
const audience = "mpvEcho.Echo"; // Verified native App ID; never take audience from HTTP input.
export class AppleIdentityError extends Error {
  constructor(code = "INVALID_IDENTITY") {
    super("Apple identity could not be verified."); this.code = code;
  }
}

function objectSegment(value, limit) {
  const decoded = new TextDecoder("utf-8", { fatal: true }).decode(base64URLBytes(value, limit));
  const object = JSON.parse(decoded);
  if (!object || Array.isArray(object) || typeof object !== "object") throw new AppleIdentityError();
  return object;
}

/** Cryptographic verification only: callers still need an expiring, atomically consumed server challenge. */
export class AppleIdentityTokenVerifier {
  #keys; #clock; #subtle;
  constructor({ keySource = new ApplePublicKeySource(), clock = Date.now,
    subtle = globalThis.crypto.subtle } = {}) {
    this.#keys = keySource; this.#clock = clock; this.#subtle = subtle;
  }

  verify(token, { expectedNonce } = {}) { return this.#verify(token, { expectedNonce }, false); }

  /** Only for a server-initiated refresh response; no nonce is invented and no client subject is trusted. */
  verifyRefresh(token, { expectedSubjectHash } = {}) { return this.#verify(token, { expectedSubjectHash }, true); }

  async #verify(token, { expectedNonce, expectedSubjectHash }, refresh) {
    try {
      // expectedNonce is the SHA-256 value retained in the server's challenge store, not client JSON.
      if ((refresh ? typeof expectedSubjectHash !== "string" || !/^[a-f0-9]{64}$/.test(expectedSubjectHash) :
          typeof expectedNonce !== "string" || !/^[a-f0-9]{64}$/.test(expectedNonce)) ||
          typeof token !== "string" || token.length > 12288) throw new AppleIdentityError();
      const parts = token.split(".");
      if (parts.length !== 3) throw new AppleIdentityError();
      const header = objectSegment(parts[0], 1024);
      if (header.alg !== "RS256" || typeof header.kid !== "string" ||
          !/^[A-Za-z0-9_-]{1,128}$/.test(header.kid) ||
          (header.typ !== undefined && header.typ !== "JWT") ||
          Object.keys(header).some(key => !["alg", "kid", "typ"].includes(key))) throw new AppleIdentityError();
      const claims = objectSegment(parts[1], 8192);
      const millis = this.#clock(), now = Math.floor(millis / 1000);
      if (!Number.isSafeInteger(millis) || millis < 0 || claims.iss !== issuer || claims.aud !== audience ||
          (claims.azp !== undefined && claims.azp !== audience) ||
          typeof claims.sub !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(claims.sub) ||
          !Number.isSafeInteger(claims.iat) || claims.iat < now - 600 || claims.iat > now + 30 ||
          !Number.isSafeInteger(claims.exp) || claims.exp <= now || claims.exp <= claims.iat ||
          (claims.nbf !== undefined && (!Number.isSafeInteger(claims.nbf) || claims.nbf > now)) ||
          (!refresh && (typeof claims.nonce !== "string" || !/^[a-f0-9]{64}$/.test(claims.nonce) ||
            !timingSafeEqual(Buffer.from(claims.nonce, "ascii"), Buffer.from(expectedNonce, "ascii"))))) {
        throw new AppleIdentityError();
      }
      const signature = base64URLBytes(parts[2], 512);
      if (signature.length < 256) throw new AppleIdentityError();
      const key = await this.#keys.key(header.kid);
      const valid = await this.#subtle.verify("RSASSA-PKCS1-v1_5", key, signature,
        new TextEncoder().encode(parts[0] + "." + parts[1]));
      if (!valid) throw new AppleIdentityError();
      if (refresh && !timingSafeEqual(Buffer.from(appleSubjectHash(claims.sub), "ascii"),
        Buffer.from(expectedSubjectHash, "ascii"))) throw new AppleIdentityError();
      // No email/name/private relay fields are exported to session logic or logs.
      return Object.freeze({ appleSubject: claims.sub, issuedAt: claims.iat, expiresAt: claims.exp });
    } catch (error) {
      throw new AppleIdentityError(error instanceof AppleKeysUnavailable ? "KEYS_UNAVAILABLE" : "INVALID_IDENTITY");
    }
  }
}
