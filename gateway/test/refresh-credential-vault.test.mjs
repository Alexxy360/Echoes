import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";
import { RefreshCredentialVault, RefreshCredentialError, appleSubjectHash } from "../src/refresh-credential-vault.mjs";

const first = randomBytes(32).toString("base64url"), second = randomBytes(32).toString("base64url");
const context = () => ({ credentialID: randomUUID(), subjectHash: appleSubjectHash("synthetic.user") });
const vault = (activeKeyID = "v1", keys = { v1: first }) => new RefreshCredentialVault({ activeKeyID, keys });
const plaintext = "SYNTHETIC-PRIVATE-REFRESH";
const safeError = error => error instanceof RefreshCredentialError && error.message === "Refresh credential is unavailable." &&
  error.cause === undefined && !JSON.stringify(error).includes(plaintext);

test("AES-256-GCM roundtrip uses distinct random 96-bit IVs and contains no plaintext credential", () => {
  const store = vault(), binding = context(), a = store.seal(plaintext, binding), b = store.seal(plaintext, binding);
  assert.equal(store.open(a, binding), plaintext); assert.equal(store.open(b, binding), plaintext);
  assert.notEqual(JSON.parse(a).iv, JSON.parse(b).iv); assert.notEqual(a, b);
  assert.equal(Buffer.from(JSON.parse(a).iv, "base64url").length, 12);
  assert.equal(Buffer.from(JSON.parse(a).tag, "base64url").length, 16);
  assert.equal(a.includes(plaintext), false); assert.equal(a.includes(first), false);
});

test("authenticated binding prevents credential swaps across identities or challenges", () => {
  const store = vault(), binding = context(), envelope = store.seal(plaintext, binding);
  for (const replacement of [{ ...binding, credentialID: randomUUID() },
    { ...binding, subjectHash: appleSubjectHash("another.user") }, {}, undefined]) {
    assert.throws(() => store.open(envelope, replacement), safeError);
  }
});

test("tampered ciphertext, IV, authentication tag, metadata, encoding or envelope is rejected", () => {
  const store = vault(), binding = context(), original = JSON.parse(store.seal(plaintext, binding));
  const alter = value => (value[0] === "A" ? "B" : "A") + value.slice(1);
  const mutations = [{ ...original, ciphertext: alter(original.ciphertext) }, { ...original, iv: alter(original.iv) },
    { ...original, tag: alter(original.tag) }, { ...original, v: 2 }, { ...original, keyID: "v2" },
    { ...original, unexpected: "PRIVATE" }, { ...original, tag: "AA" }, { ...original, iv: "AA" },
    { ...original, ciphertext: original.ciphertext + "=" }, { ...original, ciphertext: "A".repeat(12000) }, null, []];
  for (const mutation of mutations) assert.throws(() => store.open(JSON.stringify(mutation), binding), safeError);
  for (const invalid of [undefined, "{", plaintext, "x".repeat(12001)]) assert.throws(() => store.open(invalid, binding), safeError);
});

test("versioned key rotation reads old ciphertext then rekeys it under the active key and same binding", () => {
  const binding = context(), old = vault().seal(plaintext, binding), rotating = vault("v2", { v1: first, v2: second });
  assert.equal(rotating.open(old, binding), plaintext);
  const migrated = rotating.rekey(old, binding); assert.equal(JSON.parse(migrated).keyID, "v2");
  const newOnly = vault("v2", { v2: second }); assert.equal(newOnly.open(migrated, binding), plaintext);
  assert.throws(() => newOnly.open(old, binding), safeError);
  assert.throws(() => vault("v1", { v1: second }).open(old, binding), safeError);
});

test("invalid or absent keys fail closed with no generated default or encryption downgrade", () => {
  for (const input of [{}, { activeKeyID: "v1", keys: {} }, { activeKeyID: "v2", keys: { v1: first } },
    { activeKeyID: "v1", keys: { v1: "bad" } }, { activeKeyID: "v1", keys: { v1: first + "=" } },
    { activeKeyID: "v1", keys: { v1: randomBytes(31).toString("base64url") } },
    { activeKeyID: "v1", keys: { v1: first, v2: second, v3: first, v4: second } }]) {
    assert.throws(() => new RefreshCredentialVault(input), safeError);
  }
});

test("invalid token or binding values are rejected and identity hashes are domain separated", () => {
  const store = vault();
  for (const value of [undefined, "", "with space", "line\nbreak", "ą", "x".repeat(8193)]) {
    assert.throws(() => store.seal(value, context()), safeError);
  }
  assert.equal(appleSubjectHash("synthetic.user").length, 64);
  assert.notEqual(appleSubjectHash("synthetic.user"), appleSubjectHash("Synthetic.user"));
  for (const value of [undefined, "", "bad space", "x".repeat(256)]) assert.throws(() => appleSubjectHash(value), safeError);
  for (const binding of [{}, { credentialID: "client-picked", subjectHash: "a".repeat(64) },
    { credentialID: randomUUID(), subjectHash: "invalid" }]) assert.throws(() => store.seal(plaintext, binding), safeError);
});
