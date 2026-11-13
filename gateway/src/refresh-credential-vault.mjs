import { Buffer } from "node:buffer";
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { base64URLBytes } from "./apple-public-keys.mjs";

export class RefreshCredentialError extends Error {
  constructor() { super("Refresh credential is unavailable."); }
}
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function appleSubjectHash(subject) {
  if (typeof subject !== "string" || !/^[A-Za-z0-9._-]{1,255}$/.test(subject)) throw new RefreshCredentialError();
  return createHash("sha256").update("echoes/apple-subject/v1\0" + subject).digest("hex");
}
function token(value) {
  if (typeof value !== "string" || value.length > 8192 || !/^[\x21-\x7e]+$/.test(value)) throw new RefreshCredentialError();
  return value;
}
function aad({ credentialID, subjectHash } = {}, keyID) {
  if (typeof credentialID !== "string" || !uuid.test(credentialID) ||
      typeof subjectHash !== "string" || !/^[a-f0-9]{64}$/.test(subjectHash)) throw new RefreshCredentialError();
  return Buffer.from(JSON.stringify(["echoes/apple-refresh/v1", "mpvEcho.Echo", credentialID, subjectHash, keyID]));
}

/** Encryption only. Keys come from server secrets; no key material, token or open() result belongs in HTTP/logs. */
export class RefreshCredentialVault {
  #keys = new Map(); #activeKeyID;
  constructor({ activeKeyID, keys } = {}) {
    try {
      if (!keys || typeof keys !== "object" || Array.isArray(keys) || Object.keys(keys).length < 1 ||
          Object.keys(keys).length > 3) throw new Error();
      for (const [id, value] of Object.entries(keys)) {
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(id)) throw new Error();
        const bytes = base64URLBytes(value, 32);
        if (bytes.length !== 32) throw new Error();
        this.#keys.set(id, bytes);
      }
      if (!this.#keys.has(activeKeyID)) throw new Error();
      this.#activeKeyID = activeKeyID;
    } catch { throw new RefreshCredentialError(); }
  }
  seal(refreshToken, context) {
    try {
      const plaintext = token(refreshToken); const iv = randomBytes(12), keyID = this.#activeKeyID;
      const cipher = createCipheriv("aes-256-gcm", this.#keys.get(keyID), iv, { authTagLength: 16 });
      cipher.setAAD(aad(context, keyID));
      const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
      return JSON.stringify({ v: 1, keyID, iv: iv.toString("base64url"),
        ciphertext: ciphertext.toString("base64url"), tag: cipher.getAuthTag().toString("base64url") });
    } catch { throw new RefreshCredentialError(); }
  }
  open(envelope, context) {
    try {
      if (typeof envelope !== "string" || envelope.length > 12000) throw new Error();
      const record = JSON.parse(envelope);
      if (!record || Array.isArray(record) || Object.keys(record).sort().join() !== "ciphertext,iv,keyID,tag,v" ||
          record.v !== 1 || !this.#keys.has(record.keyID)) throw new Error();
      const iv = base64URLBytes(record.iv, 12), tag = base64URLBytes(record.tag, 16);
      if (iv.length !== 12 || tag.length !== 16) throw new Error();
      const decipher = createDecipheriv("aes-256-gcm", this.#keys.get(record.keyID), iv, { authTagLength: 16 });
      decipher.setAAD(aad(context, record.keyID)); decipher.setAuthTag(tag);
      const bytes = Buffer.concat([decipher.update(base64URLBytes(record.ciphertext, 8192)), decipher.final()]);
      return token(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } catch { throw new RefreshCredentialError(); }
  }
  rekey(envelope, context) { return this.seal(this.open(envelope, context), context); }
}
