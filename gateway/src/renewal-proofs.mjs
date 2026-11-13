import { Buffer } from "node:buffer";
import { createHmac, timingSafeEqual } from "node:crypto";
import { base64URLBytes } from "./apple-public-keys.mjs";

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const keyName = /^[A-Za-z0-9_-]{1,16}$/;
export class RenewalProofError extends Error {
  constructor() { super("Renewal proof is unavailable."); }
}

/** Integrity-protected grant + sequence; authorization/expiry/replay decisions still require durable state. */
export class RenewalProofs {
  #keys = new Map(); #active;
  constructor({ activeKeyID, keys } = {}) {
    try {
      if (!keys || typeof keys !== "object" || Array.isArray(keys) || Object.keys(keys).length < 1 ||
          Object.keys(keys).length > 3) throw new Error();
      for (const [id, value] of Object.entries(keys)) {
        if (!keyName.test(id)) throw new Error();
        const bytes = base64URLBytes(value, 32);
        if (bytes.length !== 32) throw new Error();
        this.#keys.set(id, bytes);
      }
      if (!this.#keys.has(activeKeyID)) throw new Error();
      this.#active = activeKeyID;
    } catch { throw new RenewalProofError(); }
  }
  #mac(prefix, keyID) {
    const key = this.#keys.get(keyID);
    if (!key) throw new RenewalProofError();
    return createHmac("sha256", key).update("echoes/native-renewal/v1\0mpvEcho.Echo\0" + prefix).digest();
  }
  create(grantID, sequence = 0, keyID = this.#active) {
    try {
      if (typeof grantID !== "string" || !uuid.test(grantID) || !Number.isSafeInteger(sequence) ||
          sequence < 0 || sequence > 2147483647 || typeof keyID !== "string" || !keyName.test(keyID)) throw new Error();
      const prefix = grantID + "." + keyID + "." + sequence;
      return prefix + "." + this.#mac(prefix, keyID).toString("base64url");
    } catch { throw new RenewalProofError(); }
  }
  verify(token) {
    try {
      if (typeof token !== "string" || token.length > 120) throw new Error();
      const parts = token.split(".");
      if (parts.length !== 4 || !uuid.test(parts[0]) || !keyName.test(parts[1]) || !/^\d{1,10}$/.test(parts[2])) throw new Error();
      const sequence = Number(parts[2]);
      if (String(sequence) !== parts[2] || sequence > 2147483647) throw new Error();
      const supplied = base64URLBytes(parts[3], 32), expected = this.#mac(parts.slice(0, 3).join("."), parts[1]);
      if (supplied.length !== 32 || !timingSafeEqual(supplied, expected)) throw new Error();
      return Object.freeze({ grantID: parts[0], keyID: parts[1], sequence });
    } catch { throw new RenewalProofError(); }
  }
}
