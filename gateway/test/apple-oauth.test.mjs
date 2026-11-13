import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, verify } from "node:crypto";
import { AppleClientSecret, AppleOAuthClient, AppleOAuthError } from "../src/apple-oauth.mjs";

const now = 1794603600000;
const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
const source = () => new AppleClientSecret({ privateKeyPEM: pem, keyID: "TESTKEY123", clock: () => now });
const response = overrides => Response.json({ access_token: "SYNTHETIC-ACCESS", token_type: "Bearer",
  expires_in: 3600, refresh_token: "SYNTHETIC-REFRESH", id_token: "SYNTHETIC-ID", ...overrides });
const safeError = expected => error => error instanceof AppleOAuthError && error.code === expected &&
  error.message === "Apple authorization could not be completed." && error.cause === undefined &&
  !JSON.stringify(error).includes("SYNTHETIC-PRIVATE");

test("client secret has fixed native claims, a five-minute lifetime and independently verified ES256 raw signature", () => {
  const jwt = source().create(), [header, body, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), { alg: "ES256", kid: "TESTKEY123" });
  assert.deepEqual(JSON.parse(Buffer.from(body, "base64url")), { iss: "22YC9RAP4P", iat: now / 1000,
    exp: now / 1000 + 300, aud: "https://appleid.apple.com", sub: "mpvEcho.Echo" });
  const bytes = Buffer.from(signature, "base64url"); assert.equal(bytes.length, 64);
  assert.equal(verify("sha256", Buffer.from(header + "." + body), { key: pair.publicKey, dsaEncoding: "ieee-p1363" }, bytes), true);
  assert.equal(jwt.includes("PRIVATE KEY"), false);
});

test("missing, RSA, wrong-curve, non-PKCS8 and invalid key/clock configurations fail closed", () => {
  const wrong = generateKeyPairSync("ec", { namedCurve: "secp384r1" }).privateKey;
  const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 }).privateKey;
  for (const input of [{}, { privateKeyPEM: pem, keyID: "short" }, { privateKeyPEM: "SYNTHETIC-PRIVATE", keyID: "TESTKEY123" },
    ...[wrong, rsa].map(key => ({ privateKeyPEM: key.export({ type: "pkcs8", format: "pem" }), keyID: "TESTKEY123" })),
    { privateKeyPEM: pair.privateKey.export({ type: "sec1", format: "pem" }), keyID: "TESTKEY123" }]) {
    assert.throws(() => new AppleClientSecret(input), safeError("OAUTH_CONFIGURATION"));
  }
  for (const time of [NaN, -1, 0.5, Infinity]) assert.throws(() =>
    new AppleClientSecret({ privateKeyPEM: pem, keyID: "TESTKEY123", clock: () => time }).create(), safeError("OAUTH_CONFIGURATION"));
});

test("authorization exchange sends only a form to the fixed Apple host without redirects or native redirect_uri", async () => {
  let calls = 0;
  const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async request => {
    calls++; assert.equal(request.url, "https://appleid.apple.com/auth/token"); assert.equal(request.method, "POST");
    assert.equal(request.redirect, "manual"); assert.equal(request.credentials, "omit");
    assert.equal(request.headers.get("Content-Type"), "application/x-www-form-urlencoded");
    assert.equal(request.headers.get("Cache-Control"), "no-store");
    const form = new URLSearchParams(await request.text());
    assert.deepEqual([...form.keys()].sort(), ["client_id", "client_secret", "code", "grant_type"]);
    assert.equal(form.get("code"), "SYNTHETIC+CODE&/=%"); assert.equal(form.get("client_id"), "mpvEcho.Echo");
    assert.equal(form.get("grant_type"), "authorization_code"); assert.equal(form.get("client_secret").split(".").length, 3);
    return response();
  } });
  assert.deepEqual(await client.exchangeAuthorizationCode({ authorizationCode: "SYNTHETIC+CODE&/=%" }), {
    identityToken: "SYNTHETIC-ID", refreshToken: "SYNTHETIC-REFRESH",
  });
  assert.equal(calls, 1);
});

test("refresh validation uses its own grant and accepts an absent or replaced refresh credential", async () => {
  let calls = 0;
  const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async request => {
    const form = new URLSearchParams(await request.text()); calls++;
    assert.equal(form.get("grant_type"), "refresh_token"); assert.equal(form.get("refresh_token"), "SYNTHETIC-OLD");
    assert.equal(form.has("code"), false); assert.equal(form.has("redirect_uri"), false);
    return response({ refresh_token: calls === 1 ? undefined : "SYNTHETIC-ROTATED" });
  } });
  assert.deepEqual(await client.validateRefreshToken("SYNTHETIC-OLD"), { identityToken: "SYNTHETIC-ID" });
  assert.equal((await client.validateRefreshToken("SYNTHETIC-OLD")).refreshToken, "SYNTHETIC-ROTATED");
});

test("revocation sends a refresh hint and accepts only the documented empty 200 acknowledgement", async () => {
  let calls = 0;
  const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async request => {
    calls++; assert.equal(request.url, "https://appleid.apple.com/auth/revoke");
    const form = new URLSearchParams(await request.text()); assert.equal(form.get("token"), "SYNTHETIC-REFRESH");
    assert.equal(form.get("token_type_hint"), "refresh_token"); assert.equal(form.has("code"), false);
    return new Response(null, { status: 200 });
  } });
  assert.equal(await client.revokeRefreshToken("SYNTHETIC-REFRESH"), undefined);
  assert.equal(await client.revokeRefreshToken("SYNTHETIC-REFRESH"), undefined); assert.equal(calls, 2);
  const incorrect = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async () => Response.json({ error: "bad" }) });
  await assert.rejects(() => incorrect.revokeRefreshToken("SYNTHETIC-REFRESH"), safeError("OAUTH_UNAVAILABLE"));
});

test("invalid codes or refresh tokens are rejected before any network request", async () => {
  let calls = 0;
  const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async () => { calls++; return response(); } });
  for (const value of [undefined, "", "with space", "with\nnewline", "ą", "x".repeat(8193)]) {
    await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: value }), safeError("OAUTH_UNAVAILABLE"));
    await assert.rejects(() => client.validateRefreshToken(value), safeError("OAUTH_UNAVAILABLE"));
    await assert.rejects(() => client.revokeRefreshToken(value), safeError("OAUTH_UNAVAILABLE"));
  }
  await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: "x".repeat(2049) }), safeError("OAUTH_UNAVAILABLE"));
  assert.equal(calls, 0);
});

test("provider errors are allowlisted, redacted and never automatically retried", async () => {
  for (const [providerCode, safeCode] of [["invalid_grant", "TOKEN_REJECTED"], ["invalid_client", "OAUTH_CONFIGURATION"],
    ["SYNTHETIC-PRIVATE-CODE", "OAUTH_UNAVAILABLE"]]) {
    let calls = 0;
    const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async () => {
      calls++; return Response.json({ error: providerCode, error_description: "SYNTHETIC-PRIVATE-REFRESH" }, { status: 400 });
    } });
    await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: "SYNTHETIC-PRIVATE-CODE" }), safeError(safeCode));
    assert.equal(calls, 1);
  }
});

test("redirects, non-200 success, invalid JSON/UTF8/shape, missing and oversized tokens fail closed", async () => {
  const cases = [() => Response.redirect("https://attacker.invalid/", 302), () => new Response(null, { status: 204 }),
    () => response({ refresh_token: undefined }), () => response({ token_type: "bearer" }), () => response({ expires_in: 0 }),
    () => response({ expires_in: 86401 }), () => response({ id_token: "x".repeat(12289) }), () => response({ access_token: "bad token" }),
    () => response({ refresh_token: "" }), () => response({ error: "SYNTHETIC-PRIVATE" }),
    () => Response.json([]), () => new Response("{", { headers: { "Content-Type": "application/json" } }),
    () => new Response("{}", { headers: { "Content-Type": "text/html" } }),
    () => new Response(new Uint8Array([0xc3, 0x28]), { headers: { "Content-Type": "application/json" } }),
    () => new Response("x".repeat(65537), { headers: { "Content-Type": "application/json" } }),
    () => new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "65537" } }),
    () => new Response("{}", { headers: { "Content-Type": "application/json", "Content-Length": "-1" } }),
  ];
  for (const makeResponse of cases) {
    let calls = 0; const client = new AppleOAuthClient({ clientSecret: source(), fetchImplementation: async () => { calls++; return makeResponse(); } });
    await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: "SYNTHETIC-CODE" }), safeError("OAUTH_UNAVAILABLE"));
    assert.equal(calls, 1);
  }
});

test("timeouts bound both a stalled fetch and a stalled body, aborting the request without retry", async () => {
  for (const bodyStall of [false, true]) {
    let request, calls = 0;
    const client = new AppleOAuthClient({ clientSecret: source(), timeoutMilliseconds: 15,
      fetchImplementation: async input => {
        request = input; calls++;
        if (!bodyStall) return new Promise(() => {});
        return new Response(new ReadableStream({ start() {} }), { headers: { "Content-Type": "application/json" } });
      } });
    await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: "SYNTHETIC-CODE" }), safeError("OAUTH_UNAVAILABLE"));
    assert.equal(request.signal.aborted, true); assert.equal(calls, 1);
  }
});

test("untrusted transport and signer exception text is suppressed and missing dependencies are rejected", async () => {
  assert.throws(() => new AppleOAuthClient(), safeError("OAUTH_CONFIGURATION"));
  for (const timeoutMilliseconds of [0, 5001, NaN, 2.5]) assert.throws(() =>
    new AppleOAuthClient({ clientSecret: source(), timeoutMilliseconds }), safeError("OAUTH_CONFIGURATION"));
  for (const signerFails of [true, false]) {
    let calls = 0;
    const client = new AppleOAuthClient({ clientSecret: signerFails ? { create() { throw new Error("SYNTHETIC-PRIVATE-KEY"); } } : source(),
      fetchImplementation: async () => { calls++; throw new Error("SYNTHETIC-PRIVATE-URL"); } });
    await assert.rejects(() => client.exchangeAuthorizationCode({ authorizationCode: "SYNTHETIC-CODE" }), safeError("OAUTH_UNAVAILABLE"));
    assert.equal(calls, signerFails ? 0 : 1);
  }
});
