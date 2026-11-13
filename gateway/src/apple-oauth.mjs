import { Buffer } from "node:buffer";
import { createPrivateKey, sign } from "node:crypto";

const clientID = "mpvEcho.Echo";
const teamID = "22YC9RAP4P";
const origin = "https://appleid.apple.com";
const allowedCodes = new Set(["OAUTH_UNAVAILABLE", "OAUTH_CONFIGURATION", "TOKEN_REJECTED"]);
export class AppleOAuthError extends Error {
  constructor(code = "OAUTH_UNAVAILABLE") {
    super("Apple authorization could not be completed.");
    this.code = allowedCodes.has(code) ? code : "OAUTH_UNAVAILABLE";
  }
}

function opaque(value, maximum) {
  if (typeof value !== "string" || value.length > maximum || !/^[\x21-\x7e]+$/.test(value)) throw new AppleOAuthError();
  return value;
}
const segment = value => Buffer.from(JSON.stringify(value)).toString("base64url");

/** A dedicated Sign in with Apple key is required; the CloudKit S2S key is not this credential. */
export class AppleClientSecret {
  #pem; #keyID; #clock;
  constructor({ privateKeyPEM, keyID, clock = Date.now } = {}) {
    try {
      if (typeof privateKeyPEM !== "string" || privateKeyPEM.length > 4096 ||
          !privateKeyPEM.startsWith("-----BEGIN PRIVATE KEY-----") ||
          typeof keyID !== "string" || !/^[A-Z0-9]{10}$/.test(keyID) || typeof clock !== "function") throw new Error();
      const key = createPrivateKey(privateKeyPEM);
      if (key.asymmetricKeyType !== "ec" || key.asymmetricKeyDetails?.namedCurve !== "prime256v1") throw new Error();
      this.#pem = privateKeyPEM; this.#keyID = keyID; this.#clock = clock;
    } catch { throw new AppleOAuthError("OAUTH_CONFIGURATION"); }
  }
  create() {
    try {
      const millis = this.#clock();
      if (!Number.isSafeInteger(millis) || millis < 0) throw new Error();
      const now = Math.floor(millis / 1000);
      const payload = segment({ alg: "ES256", kid: this.#keyID }) + "." + segment({
        iss: teamID, iat: now, exp: now + 300, aud: origin, sub: clientID,
      });
      // JWT requires raw r||s (P1363), not the DER signature used by CloudKit requests.
      const signature = sign("sha256", Buffer.from(payload), { key: this.#pem, dsaEncoding: "ieee-p1363" });
      if (signature.length !== 64) throw new Error();
      return payload + "." + signature.toString("base64url");
    } catch { throw new AppleOAuthError("OAUTH_CONFIGURATION"); }
  }
}

async function boundedBody(response, signal) {
  const length = response.headers.get("Content-Length");
  if (length !== null && (!/^\d+$/.test(length) || Number(length) > 65536)) {
    await response.body?.cancel(); throw new AppleOAuthError();
  }
  if (!response.body) return "";
  const reader = response.body.getReader(); const chunks = []; let size = 0;
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw new AppleOAuthError();
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 65536) throw new AppleOAuthError();
      chunks.push(value);
    }
  } finally {
    signal.removeEventListener("abort", abort);
    await reader.cancel().catch(() => {}); reader.releaseLock();
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, size));
}

/** Native App ID only: fixed Apple URLs, no redirects and no retries of a one-use code. Server internal. */
export class AppleOAuthClient {
  #secret; #fetch; #timeout;
  constructor({ clientSecret, fetchImplementation = request => fetch(request), timeoutMilliseconds = 5000 } = {}) {
    if (typeof clientSecret?.create !== "function" || typeof fetchImplementation !== "function" ||
        !Number.isInteger(timeoutMilliseconds) || timeoutMilliseconds < 1 || timeoutMilliseconds > 5000) {
      throw new AppleOAuthError("OAUTH_CONFIGURATION");
    }
    this.#secret = clientSecret; this.#fetch = fetchImplementation; this.#timeout = timeoutMilliseconds;
  }
  async #post(path, fields, revoke = false) {
    const controller = new AbortController(); let timer;
    try {
      const form = new URLSearchParams({ client_id: clientID, client_secret: this.#secret.create(), ...fields });
      const request = new Request(origin + path, { method: "POST", redirect: "manual", credentials: "omit",
        headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json", "Cache-Control": "no-store" },
        body: form.toString(), signal: controller.signal });
      const operation = (async () => {
        const response = await this.#fetch(request);
        if (![200, 400].includes(response.status) || response.redirected) {
          await response.body?.cancel(); throw new AppleOAuthError();
        }
        const text = await boundedBody(response, controller.signal);
        if (revoke && response.status === 200 && text === "") return;
        if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "")) throw new AppleOAuthError();
        const body = JSON.parse(text);
        if (!body || typeof body !== "object" || Array.isArray(body)) throw new AppleOAuthError();
        if (response.status === 400) {
          throw new AppleOAuthError(body.error === "invalid_grant" ? "TOKEN_REJECTED" :
            body.error === "invalid_client" ? "OAUTH_CONFIGURATION" : "OAUTH_UNAVAILABLE");
        }
        if (revoke || body.error !== undefined || body.token_type !== "Bearer" ||
            !Number.isSafeInteger(body.expires_in) || body.expires_in < 1 || body.expires_in > 86400) throw new AppleOAuthError();
        opaque(body.access_token, 8192); opaque(body.id_token, 12288);
        // Access tokens are deliberately not exported; refresh and ID tokens remain transient server inputs.
        const result = { identityToken: body.id_token };
        if (body.refresh_token !== undefined) result.refreshToken = opaque(body.refresh_token, 8192);
        if (fields.grant_type === "authorization_code" && !result.refreshToken) throw new AppleOAuthError();
        return Object.freeze(result);
      })();
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(new AppleOAuthError()); }, this.#timeout);
      });
      return await Promise.race([operation, deadline]);
    } catch (error) {
      throw error instanceof AppleOAuthError ? error : new AppleOAuthError();
    } finally { clearTimeout(timer); controller.abort(); }
  }
  exchangeAuthorizationCode({ authorizationCode } = {}) {
    try {
      return this.#post("/auth/token", { code: opaque(authorizationCode, 2048), grant_type: "authorization_code" });
    } catch { return Promise.reject(new AppleOAuthError()); }
  }
  validateRefreshToken(refreshToken) {
    try {
      return this.#post("/auth/token", { refresh_token: opaque(refreshToken, 8192), grant_type: "refresh_token" });
    } catch { return Promise.reject(new AppleOAuthError()); }
  }
  revokeRefreshToken(refreshToken) {
    try {
      return this.#post("/auth/revoke", { token: opaque(refreshToken, 8192), token_type_hint: "refresh_token" }, true);
    } catch { return Promise.reject(new AppleOAuthError()); }
  }
}
