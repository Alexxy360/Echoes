import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync, verify } from "node:crypto";
import { CloudKitDevelopmentSigner, GatewayConfigurationError } from "../src/cloudkit-request.mjs";

// Ephemeral keys exist only in memory. Tests never contact Apple or Cloudflare.
const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const configuration = {
  container: "iCloud.example.echoes",
  environment: "development",
  keyID: "synthetic-test-key",
  privateKeyPEM: pair.privateKey.export({ type: "pkcs8", format: "pem" }),
};
const now = new Date("2026-11-12T12:00:00.123Z");
const payload = { records: [{ recordName: "synthetic-record" }] };

async function signatureValid(request, bodyOverride, pathOverride) {
  const body = bodyOverride ?? await request.text();
  const path = pathOverride ?? new URL(request.url).pathname;
  const timestamp = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date");
  const digest = createHash("sha256").update(body).digest("base64");
  return verify("sha256", Buffer.from(`${timestamp}:${digest}:${path}`), pair.publicKey,
    Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"));
}

test("signs the exact UTF-8 body, timestamp and fixed CloudKit Development path", async () => {
  const request = new CloudKitDevelopmentSigner(configuration).request("records/lookup", payload, now);
  assert.equal(request.url, "https://api.apple-cloudkit.com/database/1/iCloud.example.echoes/development/public/records/lookup");
  assert.equal(request.method, "POST");
  assert.equal(request.redirect, "manual");
  assert.equal(request.headers.get("Cache-Control"), "no-store");
  assert.equal(request.headers.get("X-Apple-CloudKit-Request-ISO8601Date"), "2026-11-12T12:00:00Z");
  assert.equal(await signatureValid(request), true);
});

test("changing body or path invalidates the signature", async () => {
  const signer = new CloudKitDevelopmentSigner(configuration);
  assert.equal(await signatureValid(signer.request("records/lookup", payload, now), "{}"), false);
  assert.equal(await signatureValid(signer.request("records/lookup", payload, now), undefined,
    "/database/1/iCloud.example.echoes/production/public/records/lookup"), false);
});

test("rejects Production, private databases, traversal and arbitrary destinations", () => {
  for (const environment of ["production", "Development", undefined]) {
    assert.throws(() => new CloudKitDevelopmentSigner({ ...configuration, environment }), GatewayConfigurationError);
  }
  const signer = new CloudKitDevelopmentSigner(configuration);
  for (const path of ["../private/records/query", "https://example.com/", "users/current", "records/query?ckAPIToken=x"]) {
    assert.throws(() => signer.request(path, payload), /Unsupported/);
  }
  for (const container of ["iCloud.*", "iCloud.example/../../private", "https://example.com", "iCloud.example?x=1"]) {
    assert.throws(() => new CloudKitDevelopmentSigner({ ...configuration, container }), GatewayConfigurationError);
  }
});

test("rejects wrong algorithms and redacts invalid secret material", () => {
  const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey.export({ type: "pkcs8", format: "pem" });
  const otherEC = generateKeyPairSync("ec", { namedCurve: "secp384r1" }).privateKey.export({ type: "pkcs8", format: "pem" });
  for (const privateKeyPEM of [rsa, otherEC, "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-INVALID-SECRET", "", undefined]) {
    assert.throws(() => new CloudKitDevelopmentSigner({ ...configuration, privateKeyPEM }), (error) => {
      assert.equal(error.message, "CloudKit Development gateway is not configured.");
      assert.equal(error.cause, undefined);
      assert.equal(error.message.includes("SYNTHETIC-INVALID-SECRET"), false);
      return true;
    });
  }
});

test("bounds UTF-8 body bytes and rejects invalid payload/time", () => {
  const signer = new CloudKitDevelopmentSigner(configuration);
  assert.throws(() => signer.request("records/query", { text: "ą".repeat(32768) }), RangeError);
  for (const value of [undefined, null, [], "{}", 3]) {
    assert.throws(() => signer.request("records/query", value), TypeError);
  }
  assert.throws(() => signer.request("records/query", { value: 1n }), TypeError);
  assert.throws(() => signer.request("records/query", payload, new Date(NaN)), TypeError);
});

test("preserves Unicode and never returns private key material", async () => {
  const request = new CloudKitDevelopmentSigner(configuration).request("records/modify", { text: "Muzyka 🎵 i Łódź" }, now);
  assert.equal(await signatureValid(request.clone()), true);
  const exported = JSON.stringify({ url: request.url, headers: [...request.headers], body: await request.text() });
  assert.equal(exported.includes("PRIVATE KEY"), false);
  assert.equal(exported.includes(configuration.privateKeyPEM), false);
});
