import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { RenewalProofs, RenewalProofError } from "../src/renewal-proofs.mjs";

const key = randomBytes(32).toString("base64url"), otherKey = randomBytes(32).toString("base64url");
const proofs = () => new RenewalProofs({ activeKeyID: "v1", keys: { v1: key } });
const safeError = error => error instanceof RenewalProofError && error.message === "Renewal proof is unavailable." && error.cause === undefined;

test("renewal proof integrity is independently verified by WebCrypto HMAC and binds the grant, key and counter", async () => {
  const store = proofs(), grantID = randomUUID(), token = store.create(grantID, 7), parts = token.split(".");
  assert.deepEqual(store.verify(token), { grantID, keyID: "v1", sequence: 7 });
  const imported = await crypto.subtle.importKey("raw", Buffer.from(key, "base64url"), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  assert.equal(await crypto.subtle.verify("HMAC", imported, Buffer.from(parts[3], "base64url"),
    Buffer.from("echoes/native-renewal/v1\0mpvEcho.Echo\0" + parts.slice(0, 3).join("."))), true);
  for (const changed of [[randomUUID(), ...parts.slice(1)], [parts[0], "v2", ...parts.slice(2)],
    [...parts.slice(0, 2), "8", parts[3]], [...parts.slice(0, 3), (parts[3][0] === "A" ? "B" : "A") + parts[3].slice(1)]]) {
    assert.throws(() => store.verify(changed.join(".")), safeError);
  }
});

test("noncanonical counters, malformed encodings, wrong purpose and excessive inputs fail closed", () => {
  const store = proofs(), token = store.create(randomUUID(), 7), parts = token.split(".");
  for (const value of [undefined, "", token + ".extra", token + "=", "x".repeat(121),
    parts.slice(0, 2).join(".") + ".07." + parts[3], parts.slice(0, 2).join(".") + ".-1." + parts[3],
    parts[0] + "." + "A".repeat(43), parts.slice(0, 3).join(".") + ".AA"]) assert.throws(() => store.verify(value), safeError);
  for (const sequence of [-1, 0.5, NaN, 2147483648]) assert.throws(() => store.create(randomUUID(), sequence), safeError);
  assert.throws(() => store.create("client-selected-id"), safeError);
});

test("key version rotation preserves old grants only while their dedicated integrity key remains available", () => {
  const grantID = randomUUID(), old = proofs().create(grantID);
  const rotated = new RenewalProofs({ activeKeyID: "v2", keys: { v1: key, v2: otherKey } });
  assert.equal(rotated.verify(old).keyID, "v1");
  assert.equal(rotated.verify(rotated.create(grantID, 1, "v1")).sequence, 1);
  assert.equal(rotated.verify(rotated.create(randomUUID())).keyID, "v2");
  assert.throws(() => new RenewalProofs({ activeKeyID: "v2", keys: { v2: otherKey } }).verify(old), safeError);
});

test("there is no generated default, weak key or plaintext fallback for integrity configuration", () => {
  for (const value of [{}, { activeKeyID: "v1", keys: {} }, { activeKeyID: "missing", keys: { v1: key } },
    { activeKeyID: "v1", keys: { v1: key + "=" } }, { activeKeyID: "v1", keys: { v1: "short" } },
    { activeKeyID: "v1", keys: { v1: key, v2: key, v3: key, v4: key } }]) assert.throws(() => new RenewalProofs(value), safeError);
});
