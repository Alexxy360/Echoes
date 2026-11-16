import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID, randomBytes } from "node:crypto";
import { AvatarReceiptVault } from "../src/avatar-receipt-vault.mjs";
import { RefreshCredentialVault } from "../src/refresh-credential-vault.mjs";
import { recordIdentity, digest } from "../src/public-record-schema.mjs";
import { publicCode } from "./support/public-record-fixture.mjs";
const keys = { a: randomBytes(32).toString("base64url"), b: randomBytes(32).toString("base64url") };
const lease = { context: { ...recordIdentity(randomUUID(), "avatar", randomUUID()), requestID: randomUUID(), payloadHash: digest("synthetic-normalized"), generation: 0 },
  transferID: randomUUID(), variant: "image", sha256: digest("synthetic-bytes"), byteCount: 16 };
const receipt = { fileChecksum: "SYNTHETIC-FILE", size: 16, receipt: "SYNTHETIC-PRIVATE-RECEIPT", referenceChecksum: "SYNTHETIC-REFERENCE", wrappingKey: "SYNTHETIC-KEY" };
const vault = (activeKeyID = "a", keyring = keys) => new AvatarReceiptVault({ activeKeyID, keys: keyring });

test("avatar receipt encryption uses random authenticated envelopes and exposes no plaintext", () => {
  const v = vault(), a = v.seal(receipt, lease), b = v.seal(receipt, lease);
  assert.notEqual(a, b); assert.deepEqual(vault().open(a, lease), receipt);
  for (const value of Object.values(receipt).filter(v => typeof v === "string")) assert.equal(a.includes(value), false);
  assert.equal(a.includes(keys.a), false);
});

test("receipt AAD binds owner, version, request, upload attempt, variant, content hash and size", () => {
  const v = vault(), envelope = v.seal(receipt, lease);
  for (const other of [{ ...lease, transferID: randomUUID() }, { ...lease, variant: "thumbnail" }, { ...lease, sha256: digest("other") },
    { ...lease, byteCount: 17 }, { ...lease, context: { ...lease.context, requestID: randomUUID() } },
    { ...lease, context: { ...lease.context, payloadHash: digest("other") } },
    { ...lease, context: { ...lease.context, ...recordIdentity(randomUUID(), "avatar", randomUUID()) } }]) {
    assert.throws(() => v.open(envelope, other), publicCode("PUBLIC_UNAVAILABLE"));
  }
  // A new owner login is enforced by the registry/session, not by changing encrypted intent identity.
  assert.deepEqual(v.open(envelope, { ...lease, context: { ...lease.context, generation: 1 } }), receipt);
});

test("rotation reads the retained key and refuses removed or relabeled key IDs", () => {
  const old = vault().seal(receipt, lease), rotated = vault("b");
  assert.deepEqual(rotated.open(old, lease), receipt);
  const newer = rotated.seal(receipt, lease); assert.equal(JSON.parse(newer).keyID, "b");
  assert.throws(() => vault("b", { b: keys.b }).open(old, lease), publicCode("PUBLIC_UNAVAILABLE"));
  const altered = JSON.parse(newer); altered.keyID = "a";
  assert.throws(() => rotated.open(JSON.stringify(altered), lease), publicCode("PUBLIC_UNAVAILABLE"));
});

test("same root keyring cannot decrypt across avatar receipts and Apple refresh credentials", () => {
  const a = vault(), refresh = new RefreshCredentialVault({ activeKeyID: "a", keys });
  const context = { credentialID: randomUUID(), subjectHash: digest("synthetic-subject") };
  const wrapped = refresh.seal("SYNTHETIC-REFRESH-TOKEN", context);
  assert.throws(() => a.open(wrapped, lease), publicCode("PUBLIC_UNAVAILABLE"));
  assert.throws(() => refresh.open(a.seal(receipt, lease), context), error => error.message === "Refresh credential is unavailable.");
});

test("tampered, noncanonical or oversized envelopes and invalid receipt dictionaries return redacted errors", () => {
  const v = vault(), original = v.seal(receipt, lease), damaged = JSON.parse(original);
  damaged.tag = randomBytes(16).toString("base64url");
  for (const value of ["x".repeat(24001), "{}", "not JSON", JSON.stringify(damaged), original.replace('"v":1', '"v":2'), original.replace('"v":1', '"extra":1,"v":1')]) {
    assert.throws(() => v.open(value, lease), publicCode("PUBLIC_UNAVAILABLE"));
  }
  for (const value of [{ ...receipt, downloadURL: "https://evil.invalid" }, { ...receipt, size: 17 }, { ...receipt, receipt: "" }, { ...receipt, fileChecksum: "x".repeat(8193) }]) {
    assert.throws(() => v.seal(value, lease), publicCode("PUBLIC_UNAVAILABLE"));
  }
});

test("missing, invalid or excessive encryption keys fail closed", () => {
  for (const options of [{}, { activeKeyID: "a", keys: {} }, { activeKeyID: "a", keys: { a: "not base64" } },
    { activeKeyID: "missing", keys }, { activeKeyID: "a", keys: { ...keys, c: keys.a, d: keys.b } }]) {
    assert.throws(() => new AvatarReceiptVault(options), publicCode("PUBLIC_UNAVAILABLE"));
  }
});
