import { Buffer } from "node:buffer";
import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from "node:crypto";
import { base64URLBytes } from "./apple-public-keys.mjs";
import { PublicRecordError, plain, publicUUID, recordIdentityFromKey } from "./public-record-schema.mjs";

const opaque = value => typeof value === "string" && /^[\x21-\x7e]{1,8192}$/.test(value);
export function avatarReceipt(value, byteCount) {
  const required = ["fileChecksum", "size", "receipt"], optional = ["referenceChecksum", "wrappingKey"];
  if (!Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > 256000 || !plain(value) || required.some(key => !Object.hasOwn(value, key)) ||
      Object.keys(value).some(key => ![...required, ...optional].includes(key)) || value.size !== byteCount ||
      [...required.filter(key => key !== "size"), ...optional.filter(key => Object.hasOwn(value, key))].some(key => !opaque(value[key]))) throw new PublicRecordError("PUBLIC_RESPONSE");
  const result = Object.freeze(Object.fromEntries([...required, ...optional].filter(key => Object.hasOwn(value, key)).map(key => [key, value[key]])));
  if (JSON.stringify(result).length > 16384) throw new PublicRecordError("PUBLIC_RESPONSE");
  return result;
}
function aad(lease, keyID) {
  const c = lease?.context;
  if (!c || c.kind !== "avatar" || !["image", "thumbnail"].includes(lease.variant) ||
      !publicUUID.test(lease.transferID ?? "") || !publicUUID.test(c.requestID ?? "") ||
      !/^[a-f0-9]{64}$/.test(c.payloadHash ?? "") || !/^[a-f0-9]{64}$/.test(lease.sha256 ?? "") ||
      !Number.isSafeInteger(lease.byteCount) || lease.byteCount < 1 || lease.byteCount > (lease.variant === "image" ? 256000 : 32000) ||
      recordIdentityFromKey(c.accountID, "avatar", c.logicalKey).recordName !== c.recordName || c.recordType !== "EchoesAvatarV1") throw new PublicRecordError("PUBLIC_SCOPE");
  // Authorization generation intentionally excluded: a new owner login may recover the same attempt.
  return Buffer.from(JSON.stringify(["echoes/avatar-receipt/v1", "iCloud.mpvEcho.Echo", "development", "public",
    c.accountID, c.recordName, c.requestID, c.payloadHash, lease.transferID, lease.variant, lease.sha256, lease.byteCount, keyID]));
}
/** Private short-lived receipt envelopes. Same server keyring can be reused through purpose-separated
 * HKDF; no raw key, plaintext receipt or open() result belongs in HTTP, logs or registry metadata.
 */
export class AvatarReceiptVault {
  #keys = new Map(); #activeKeyID;
  constructor({ activeKeyID, keys } = {}) {
    try {
      if (!plain(keys) || Object.keys(keys).length < 1 || Object.keys(keys).length > 3) throw new Error();
      for (const [id, value] of Object.entries(keys)) {
        if (!/^[A-Za-z0-9_-]{1,32}$/.test(id)) throw new Error();
        const master = base64URLBytes(value, 32);
        if (master.length !== 32) throw new Error();
        try { this.#keys.set(id, Buffer.from(hkdfSync("sha256", master, "echoes/avatar-receipt/v1", "iCloud.mpvEcho.Echo/development/public/" + id, 32))); }
        finally { master.fill(0); }
      }
      if (!this.#keys.has(activeKeyID)) throw new Error(); this.#activeKeyID = activeKeyID;
    } catch { throw new PublicRecordError(); }
  }
  seal(value, lease) {
    try {
      const plaintext = Buffer.from(JSON.stringify(avatarReceipt(value, lease?.byteCount))), iv = randomBytes(12), keyID = this.#activeKeyID;
      try {
        const cipher = createCipheriv("aes-256-gcm", this.#keys.get(keyID), iv, { authTagLength: 16 });
        cipher.setAAD(aad(lease, keyID));
        const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
        return JSON.stringify({ v: 1, keyID, iv: iv.toString("base64url"), ciphertext: ciphertext.toString("base64url"), tag: cipher.getAuthTag().toString("base64url") });
      } finally { plaintext.fill(0); }
    } catch { throw new PublicRecordError(); }
  }
  open(envelope, lease) {
    try {
      if (typeof envelope !== "string" || envelope.length > 24000) throw new Error();
      const record = JSON.parse(envelope);
      if (!plain(record) || Object.keys(record).sort().join() !== "ciphertext,iv,keyID,tag,v" || record.v !== 1 || !this.#keys.has(record.keyID)) throw new Error();
      const iv = base64URLBytes(record.iv, 12), tag = base64URLBytes(record.tag, 16);
      if (iv.length !== 12 || tag.length !== 16) throw new Error();
      const decipher = createDecipheriv("aes-256-gcm", this.#keys.get(record.keyID), iv, { authTagLength: 16 });
      decipher.setAAD(aad(lease, record.keyID)); decipher.setAuthTag(tag);
      const parts = [];
      try {
        parts.push(decipher.update(base64URLBytes(record.ciphertext, 16384))); parts.push(decipher.final());
        const plaintext = Buffer.concat(parts);
        try { return avatarReceipt(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext)), lease.byteCount); }
        finally { plaintext.fill(0); }
      } finally { for (const part of parts) part.fill(0); }
    } catch { throw new PublicRecordError(); }
  }
}
