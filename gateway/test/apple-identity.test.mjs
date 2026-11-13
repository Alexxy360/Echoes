import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { AppleIdentityTokenVerifier, AppleIdentityError } from "../src/apple-identity.mjs";
import { ApplePublicKeySource, AppleKeysUnavailable, AppleKeyNotFound, appleKeysURL } from "../src/apple-public-keys.mjs";
import { appleSubjectHash } from "../src/refresh-credential-vault.mjs";

// Synthetic issuer key and claims. These tests never read user tokens or use the network.
const pair = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...pair.publicKey.export({ format: "jwk" }), kid: "synthetic-key", alg: "RS256", use: "sig" };
const timestamp = 1794603600;
const expectedNonce = createHash("sha256").update("synthetic-server-nonce").digest("hex");
const claims = { iss: "https://appleid.apple.com", aud: "mpvEcho.Echo", sub: "synthetic.user",
  iat: timestamp - 10, exp: timestamp + 3600, nonce: expectedNonce,
  email: "private-synthetic@example.invalid", name: "PRIVATE-SYNTHETIC-NAME" };
const header = { alg: "RS256", kid: jwk.kid, typ: "JWT" };
const segment = value => Buffer.from(JSON.stringify(value)).toString("base64url");
function token(body = claims, protectedHeader = header, privateKey = pair.privateKey) {
  const input = segment(protectedHeader) + "." + segment(body);
  return input + "." + sign("RSA-SHA256", Buffer.from(input), privateKey).toString("base64url");
}
function fixture(fetchOverride) {
  let calls = 0;
  const source = new ApplePublicKeySource({ clock: () => timestamp * 1000,
    fetchImplementation: async (request, options) => {
      calls++;
      assert.equal(request.url, appleKeysURL);
      assert.equal(request.method, "GET"); assert.equal(request.redirect, "manual");
      assert.equal(request.headers.get("Authorization"), null);
      assert.ok(options.signal instanceof AbortSignal);
      return fetchOverride ? fetchOverride(request) : Response.json({ keys: [jwk] });
    } });
  return { source, verifier: new AppleIdentityTokenVerifier({ keySource: source, clock: () => timestamp * 1000 }),
    calls: () => calls };
}
async function rejected(verifier, value, nonce = expectedNonce, code = "INVALID_IDENTITY") {
  await assert.rejects(() => verifier.verify(value, { expectedNonce: nonce }), error => {
    assert.ok(error instanceof AppleIdentityError); assert.equal(error.code, code);
    assert.equal(error.message, "Apple identity could not be verified.");
    assert.equal(error.cause, undefined); return true;
  });
}

test("verifies a synthetic Node RSA signature with WebCrypto and exports only the subject/times", async () => {
  const { verifier, calls } = fixture();
  const result = await verifier.verify(token(), { expectedNonce });
  assert.deepEqual(result, { appleSubject: claims.sub, issuedAt: claims.iat, expiresAt: claims.exp });
  assert.ok(Object.isFrozen(result)); assert.equal(calls(), 1);
  assert.equal(JSON.stringify(result).includes(claims.email), false);
  assert.equal(JSON.stringify(result).includes(claims.name), false);
  await verifier.verify(token(), { expectedNonce }); assert.equal(calls(), 1);
  // A verifier alone deliberately does not consume the server's challenge.
});

test("refresh verification binds a signed response to the server subject without inventing a new nonce", async () => {
  const { verifier } = fixture(), expectedSubjectHash = appleSubjectHash(claims.sub);
  const withoutNonce = token({ ...claims, nonce: undefined });
  const result = await verifier.verifyRefresh(withoutNonce, { expectedSubjectHash });
  assert.deepEqual(result, { appleSubject: claims.sub, issuedAt: claims.iat, expiresAt: claims.exp });
  await rejected(verifier, withoutNonce);
  await verifier.verifyRefresh(token(), { expectedSubjectHash });
});

test("refresh cannot select another subject, issuer, audience, algorithm or stale proof", async () => {
  const { verifier } = fixture(), expectedSubjectHash = appleSubjectHash(claims.sub);
  for (const change of [{ sub: "another.user" }, { aud: "another.app" }, { iss: "https://attacker.invalid" },
    { iat: timestamp - 601 }, { exp: timestamp }, { iat: timestamp + 31 }]) {
    await assert.rejects(() => verifier.verifyRefresh(token({ ...claims, nonce: undefined, ...change }), { expectedSubjectHash }),
      error => error instanceof AppleIdentityError && error.code === "INVALID_IDENTITY" && error.cause === undefined);
  }
  await assert.rejects(() => verifier.verifyRefresh(token(claims, { ...header, alg: "HS256" }), { expectedSubjectHash }));
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
  await assert.rejects(() => verifier.verifyRefresh(token(claims, header, other.privateKey), { expectedSubjectHash }));
});

test("refresh verification requires a valid server-side subject hash before fetching keys", async () => {
  const { verifier, calls } = fixture();
  for (const expectedSubjectHash of [undefined, "client.user", "", "a".repeat(63)]) {
    await assert.rejects(() => verifier.verifyRefresh(token(), { expectedSubjectHash }));
  }
  assert.equal(calls(), 0);
});

test("tampered claims or a different signing key cannot impersonate the Apple subject", async () => {
  const { verifier } = fixture();
  const parts = token().split("."); parts[1] = segment({ ...claims, sub: "forged.user" });
  await rejected(verifier, parts.join("."));
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
  await rejected(verifier, token(claims, header, other.privateKey));
});

test("algorithm confusion, URL-bearing/critical headers and unexpected token types are rejected before key fetch", async () => {
  const { verifier, calls } = fixture();
  for (const change of [{ alg: "none" }, { alg: "HS256" }, { alg: "ES256" }, { kid: "../keys" },
    { jku: "https://attacker.invalid/keys" }, { x5u: "https://attacker.invalid/keys" },
    { crit: [] }, { typ: "arbitrary" }]) await rejected(verifier, token(claims, { ...header, ...change }));
  assert.equal(calls(), 0);
});

test("issuer, native audience, authorized party and nonce cannot be selected by the caller", async () => {
  const { verifier, calls } = fixture();
  for (const change of [{ iss: "https://attacker.invalid" }, { aud: "another.app" },
    { aud: ["mpvEcho.Echo", "another.app"] }, { azp: "another.app" }, { nonce: "0".repeat(64) },
    { nonce: undefined }, { sub: "" }, { sub: ["synthetic.user"] }]) {
    await rejected(verifier, token({ ...claims, ...change }));
  }
  await rejected(verifier, token(), "client-selected-nonce"); assert.equal(calls(), 0);
});

test("expired, stale, not-yet-valid and malformed numeric times fail closed", async () => {
  const { verifier, calls } = fixture();
  for (const change of [{ exp: timestamp }, { exp: timestamp - 1 }, { iat: timestamp - 601 },
    { iat: timestamp + 31 }, { iat: String(timestamp) }, { exp: timestamp + 0.5 },
    { nbf: timestamp + 1 }, { nbf: "later" }, { exp: claims.iat }]) {
    await rejected(verifier, token({ ...claims, ...change }));
  }
  assert.equal(calls(), 0);
});

test("malformed/oversized segments, padding and invalid UTF-8 never cause key retrieval", async () => {
  const { verifier, calls } = fixture(); const parts = token().split(".");
  for (const value of [undefined, "", "a.b", "a".repeat(12289),
    parts[0] + "=." + parts[1] + "." + parts[2],
    segment([]) + "." + parts[1] + "." + parts[2],
    parts[0] + "." + Buffer.from([255]).toString("base64url") + "." + parts[2],
    parts[0] + "." + parts[1] + ".AA"]) await rejected(verifier, value);
  assert.equal(calls(), 0);
});

test("JWKS failures are distinguishable from invalid tokens without exposing transport details or claims", async () => {
  const { verifier } = fixture(() => { throw new Error("PRIVATE-SYNTHETIC-TRANSPORT"); });
  await rejected(verifier, token(), expectedNonce, "KEYS_UNAVAILABLE");
});

test("a kid absent from a valid Apple key set is an invalid identity rather than an authentication outage", async () => {
  const { verifier, calls } = fixture();
  await rejected(verifier, token(claims, { ...header, kid: "unknown-key" }));
  assert.equal(calls(), 1);
});

test("JWKS refresh coalesces concurrent lookups and uses an hourly cache", async () => {
  let release; let calls = 0; let now = timestamp * 1000;
  const waiting = new Promise(resolve => { release = resolve; });
  const source = new ApplePublicKeySource({ clock: () => now, fetchImplementation: async () => {
    calls++; await waiting; return Response.json({ keys: [jwk] });
  } });
  const lookups = Array.from({ length: 12 }, () => source.key(jwk.kid));
  assert.equal(calls, 1); release();
  const results = await Promise.all(lookups); assert.ok(results.every(key => key === results[0]));
  now += 3599000; await source.key(jwk.kid); assert.equal(calls, 1);
  now += 2000; await source.key(jwk.kid); assert.equal(calls, 2);
});

test("unknown-kid bursts and failed refreshes cannot repeatedly fetch within one instance's cooldown", async () => {
  let calls = 0; let now = timestamp * 1000;
  const source = new ApplePublicKeySource({ clock: () => now, fetchImplementation: async () => {
    calls++; return Response.json({ keys: [jwk] });
  } });
  await source.key(jwk.kid);
  for (let i = 0; i < 20; i++) await assert.rejects(() => source.key("unknown-" + i), AppleKeyNotFound);
  assert.equal(calls, 1);
  now += 61000; await assert.rejects(() => source.key("unknown-new"), AppleKeyNotFound); assert.equal(calls, 2);
  await source.key(jwk.kid); assert.equal(calls, 2);
});

test("expired keys are not served when refresh fails and rotation can subsequently succeed", async () => {
  let calls = 0; let now = timestamp * 1000; let fail = false; let keys = [jwk];
  const source = new ApplePublicKeySource({ clock: () => now, fetchImplementation: async () => {
    calls++; if (fail) throw new Error("PRIVATE-SYNTHETIC-DETAIL"); return Response.json({ keys });
  } });
  await source.key(jwk.kid); now += 3601000; fail = true;
  await assert.rejects(() => source.key(jwk.kid), AppleKeysUnavailable);
  await assert.rejects(() => source.key(jwk.kid), AppleKeysUnavailable); assert.equal(calls, 2);
  fail = false; now += 61000; keys = [{ ...jwk, kid: "rotated" }];
  await source.key("rotated"); assert.equal(calls, 3);
  await assert.rejects(() => source.key(jwk.kid), AppleKeyNotFound); assert.equal(calls, 3);
});

test("redirects, non-JSON and oversized JWKS responses are rejected without following another host", async () => {
  for (const response of [new Response("", { status: 302, headers: { Location: "https://attacker.invalid" } }),
    new Response("PRIVATE-SYNTHETIC-HTML"), new Response("x".repeat(65537), { headers: { "Content-Type": "application/json" } })]) {
    const { source, calls } = fixture(() => response);
    await assert.rejects(() => source.key(jwk.kid), AppleKeysUnavailable); assert.equal(calls(), 1);
  }
});

test("weak/malformed/private, duplicate, wrong-algorithm and unbounded key sets fail closed", async () => {
  for (const keys of [[{ ...jwk, n: "AA" }], [{ ...jwk, n: jwk.n + "=" }],
    [{ ...jwk, d: "PRIVATE-SYNTHETIC" }], [jwk, jwk], [{ ...jwk, e: "Aw" }],
    [{ ...jwk, alg: "HS256" }], Array.from({ length: 9 }, (_, i) => ({ ...jwk, kid: "key" + i })), []]) {
    const { source } = fixture(() => Response.json({ keys }));
    await assert.rejects(() => source.key(jwk.kid), AppleKeysUnavailable);
  }
});
