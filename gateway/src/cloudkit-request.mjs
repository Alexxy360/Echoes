import { Buffer } from "node:buffer";
import { createHash, createPrivateKey, sign } from "node:crypto";

const operations = new Set(["records/lookup", "records/query", "records/modify"]);
const maximumBodyBytes = 64 * 1024;

export class GatewayConfigurationError extends Error {
  constructor() { super("CloudKit Development gateway is not configured."); }
}

/** Server-only primitive. Never expose it as an HTTP signing endpoint or generic proxy. */
export class CloudKitDevelopmentSigner {
  #keyPEM;
  #keyID;
  #path;

  constructor({ container, environment, keyID, privateKeyPEM } = {}) {
    if (environment !== "development" ||
        typeof container !== "string" ||
        !/^iCloud\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*$/.test(container) ||
        typeof keyID !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(keyID) ||
        typeof privateKeyPEM !== "string" ||
        !privateKeyPEM.startsWith("-----BEGIN PRIVATE KEY-----")) {
      throw new GatewayConfigurationError();
    }
    try {
      const key = createPrivateKey(privateKeyPEM);
      if (key.asymmetricKeyType !== "ec" ||
          key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
        throw new GatewayConfigurationError();
      }
      // Validate the algorithm once, then use the documented PEM input for Workers sign().
      // Some Workers runtimes reject a KeyObject nested inside options.key.
      this.#keyPEM = privateKeyPEM;
    } catch { throw new GatewayConfigurationError(); }
    this.#keyID = keyID;
    this.#path = `/database/1/${container}/development/public/`;
  }

  /** Input comes from trusted service logic after authentication/authorization, never raw client JSON. */
  request(operation, payload, date = new Date(), onDiagnosticStage) {
    onDiagnosticStage?.("validation");
    if (!operations.has(operation)) throw new TypeError("Unsupported CloudKit operation.");
    if (!(date instanceof Date) || !Number.isFinite(date.getTime())) {
      throw new TypeError("Invalid request time.");
    }
    if (!payload || Object.getPrototypeOf(payload) !== Object.prototype) {
      throw new TypeError("A JSON request object is required.");
    }
    let body;
    onDiagnosticStage?.("serialization");
    try { body = JSON.stringify(payload); }
    catch { throw new TypeError("Invalid JSON request."); }
    if (Buffer.byteLength(body, "utf8") > maximumBodyBytes) {
      throw new RangeError("CloudKit request exceeds the gateway limit.");
    }
    const path = this.#path + operation;
    const timestamp = date.toISOString().replace(/\.\d{3}Z$/, "Z");
    onDiagnosticStage?.("digest");
    const digest = createHash("sha256").update(body, "utf8").digest("base64");
    const message = `${timestamp}:${digest}:${path}`;
    onDiagnosticStage?.("signature");
    const signature = sign("sha256", Buffer.from(message, "utf8"), {
      key: this.#keyPEM, dsaEncoding: "der",
    }).toString("base64");
    onDiagnosticStage?.("request-construction");
    return new Request("https://api.apple-cloudkit.com" + path, {
      method: "POST",
      // Workers rejects redirect:"error" before sending. Manual mode never forwards signed headers.
      // The caller rejects non-2xx responses rather than following Location.
      redirect: "manual",
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
        "X-Apple-CloudKit-Request-KeyID": this.#keyID,
        "X-Apple-CloudKit-Request-ISO8601Date": timestamp,
        "X-Apple-CloudKit-Request-SignatureV1": signature,
      },
      body,
    });
  }
}
