import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";
import { base64URLBytes } from "./apple-public-keys.mjs";
import { approximateLocation, distanceMeters } from "./community-geo.mjs";

export { approximateLocation, distanceMeters };
export const communityPolicy = Object.freeze({ radius: 3000, queryRadius: 3500, pageSize: 50, queryPage: 25,
  maximumPages: 16, maximumReadCalls: 40, maximumKnown: 200, cursorLifetime: 300000 });
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export const messageName = /^community-v1-message-[a-f0-9]{64}$/;
const errors = new Set(["COMMUNITY_INPUT", "COMMUNITY_STALE", "COMMUNITY_NOT_FOUND", "COMMUNITY_RATE_LIMITED",
  "COMMUNITY_CAPACITY", "COMMUNITY_TEXT_REJECTED", "COMMUNITY_UNAVAILABLE", "COMMUNITY_CURSOR"]);
export class CommunityError extends Error {
  constructor(code = "COMMUNITY_UNAVAILABLE") { super("Community request could not be completed."); this.code = errors.has(code) ? code : "COMMUNITY_UNAVAILABLE"; }
}
export function objectFields(value, required, optional = []) {
  if (!value || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype ||
      required.some(key => !Object.hasOwn(value, key)) || Object.keys(value).some(key => !required.includes(key) && !optional.includes(key))) throw new CommunityError("COMMUNITY_INPUT");
  return value;
}
export function communityUUID(value) { if (typeof value !== "string" || !uuid.test(value)) throw new CommunityError("COMMUNITY_INPUT"); return value; }
export function communityText(value, limit) {
  if (typeof value !== "string" || !value.isWellFormed()) throw new CommunityError("COMMUNITY_INPUT");
  const result = value.normalize("NFC").trim();
  if (!result.length || result.length > limit || /[\x00-\x08\x0b-\x1f\x7f\u202a-\u202e\u2066-\u2069]/u.test(result)) throw new CommunityError("COMMUNITY_INPUT");
  return result;
}
export function communityCoordinate(value) {
  objectFields(value, ["latitude", "longitude"]);
  if (typeof value.latitude !== "number" || typeof value.longitude !== "number" || !Number.isFinite(value.latitude) ||
      !Number.isFinite(value.longitude) || Math.abs(value.latitude) > 90 || Math.abs(value.longitude) > 180) throw new CommunityError("COMMUNITY_INPUT");
  return { latitude: value.latitude, longitude: value.longitude };
}
export function communityArea(coordinate) { return JSON.stringify(approximateLocation(coordinate)); }
export function moderationPhrases(json = "[]") {
  try {
    if (typeof json !== "string" || json.length > 4096) throw new Error();
    const values = JSON.parse(json);
    if (!Array.isArray(values) || values.length > 100 || values.some(value => typeof value !== "string" || !value.length || value.length > 80)) throw new Error();
    return Object.freeze(["kill yourself", "zabij się", "zabij sie", ...values].map(value => value.normalize("NFKC").toLowerCase()));
  } catch { throw new CommunityError(); }
}
export function moderateText(value, phrases) {
  const normalized = value.normalize("NFKC").replace(/[\u200b-\u200d\ufeff]/g, "").toLowerCase();
  if (phrases.some(phrase => normalized.includes(phrase)) || /(.)\1{29}/u.test(normalized)) throw new CommunityError("COMMUNITY_TEXT_REJECTED");
}
export function supportAddress(value = "") {
  if (value === "") return null;
  try {
    if (typeof value !== "string" || value.length > 2048 || /[\x00-\x20\x7f]/u.test(value)) throw new Error();
    const url = new URL(value);
    if (url.username || url.password || url.hash || !(url.protocol === "https:" && url.hostname || url.protocol === "mailto:" && /^[^@?]+@[^@?]+$/.test(url.pathname))) throw new Error();
    return url.href;
  } catch { throw new CommunityError(); }
}
export function laterMessage(a, b) { return b.timestamp - a.timestamp || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0); }
export function beforeCursor(item, last) { return !last || item.timestamp < last.timestamp || item.timestamp === last.timestamp && item.id < last.id; }

/** Encrypted, purpose-derived cursor: filtered/out-of-area record IDs and provider tokens stay opaque. */
export class CommunityCursor {
  #key; #clock;
  constructor(secret, { clock = Date.now } = {}) {
    try { const key = base64URLBytes(secret, 32); if (key.length !== 32) throw new Error();
      this.#key = createHmac("sha256", key).update("echoes/community-cursor-key/v1").digest();
    } catch { throw new CommunityError(); }
    this.#clock = clock;
  }
  #validate(value, accountID, area) {
    objectFields(value, ["version", "accountID", "area", "cutoff", "expires", "marker", "pending", "exhausted", "last"]);
    const now = this.#clock();
    if (value.version !== 1 || value.accountID !== accountID || value.area !== area || !Number.isSafeInteger(value.cutoff) ||
        value.cutoff > now + 5000 || !Number.isSafeInteger(value.expires) || value.expires <= now || value.expires > value.cutoff + communityPolicy.cursorLifetime ||
        typeof value.exhausted !== "boolean" || (value.marker !== null && (typeof value.marker !== "string" || !value.marker.length || value.marker.length > 8192)) ||
        !Array.isArray(value.pending) || value.pending.length > 25 || new Set(value.pending).size !== value.pending.length || value.pending.some(id => typeof id !== "string" || !messageName.test(id)) ||
        (value.last !== null && (!value.last || typeof value.last.id !== "string" || !messageName.test(value.last.id) || !Number.isSafeInteger(value.last.timestamp) || value.last.timestamp > value.cutoff))) throw new CommunityError("COMMUNITY_CURSOR");
    return value;
  }
  initial(accountID, coordinate) {
    const now = this.#clock(); return { version: 1, accountID, area: communityArea(coordinate), cutoff: now,
      expires: now + communityPolicy.cursorLifetime, marker: null, pending: [], exhausted: false, last: null };
  }
  seal(value) {
    this.#validate(value, value.accountID, value.area);
    const nonce = randomBytes(12), cipher = createCipheriv("aes-256-gcm", this.#key, nonce);
    cipher.setAAD(Buffer.from("echoes/community-cursor/v1"));
    const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
    const result = "v1." + Buffer.concat([nonce, encrypted, cipher.getAuthTag()]).toString("base64url");
    if (result.length > 20000) throw new CommunityError("COMMUNITY_CAPACITY"); return result;
  }
  open(token, accountID, coordinate) {
    try {
      if (typeof token !== "string" || token.length > 20000 || !/^v1\.[A-Za-z0-9_-]+$/.test(token)) throw new Error();
      const bytes = Buffer.from(token.slice(3), "base64url");
      if (bytes.length < 29 || bytes.toString("base64url") !== token.slice(3)) throw new Error();
      const decipher = createDecipheriv("aes-256-gcm", this.#key, bytes.subarray(0, 12));
      decipher.setAAD(Buffer.from("echoes/community-cursor/v1")); decipher.setAuthTag(bytes.subarray(-16));
      const clear = Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]);
      return this.#validate(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(clear)), accountID, communityArea(coordinate));
    } catch { throw new CommunityError("COMMUNITY_CURSOR"); }
  }
}
