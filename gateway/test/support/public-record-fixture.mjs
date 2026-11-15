import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, randomBytes, randomUUID, verify } from "node:crypto";
import { fixture, hash } from "./authentication-fixture.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { AccountDeletionCoordinator, AccountDeletionProcessor } from "../../src/account-deletion.mjs";

const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
export function syntheticPublicKeyConfiguration() {
  return { CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: pem };
}
export function publicClient(fetchImplementation, options = {}) {
  return new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-public-v1",
    privateKeyPEM: pem, fetchImplementation, isEnabled: () => true, ...options });
}
/** Explicit protocol model, NOT CloudKit. Indexes are deliberately absent; erasure must use exact IDs. */
export class PublicCloudKitModel {
  records = new Map(); requests = []; sequence = 0;
  before; after;
  async fetch(request, options) {
    const url = new URL(request.url), raw = await request.text(), body = JSON.parse(raw);
    assert.equal(url.origin, "https://api.apple-cloudkit.com");
    assert.match(url.pathname, /^\/database\/1\/iCloud\.mpvEcho\.Echo\/development\/public\/records\/(lookup|modify)$/);
    assert.equal(request.method, "POST"); assert.equal(request.redirect, "manual");
    const timestamp = request.headers.get("X-Apple-CloudKit-Request-ISO8601Date");
    const signature = request.headers.get("X-Apple-CloudKit-Request-SignatureV1");
    const digest = createHash("sha256").update(raw).digest("base64");
    assert.equal(verify("sha256", Buffer.from(`${timestamp}:${digest}:${url.pathname}`), pair.publicKey, Buffer.from(signature, "base64")), true);
    const operation = url.pathname.split("/").at(-1), call = { operation, body, signal: options.signal };
    this.requests.push(call);
    const override = await this.before?.(call);
    if (override) return override;
    const records = operation === "lookup" ? body.records.map(({ recordName }) => {
      const found = this.records.get(recordName);
      if (!found) return { recordName, serverErrorCode: "NOT_FOUND" };
      const record = structuredClone(found);
      if (body.desiredKeys) record.fields = Object.fromEntries(Object.entries(record.fields).filter(([key]) => body.desiredKeys.includes(key)));
      return record;
    }) : body.operations.map(({ operationType, record }) => {
      assert.equal(body.atomic, false);
      assert.ok(["create", "replace"].includes(operationType));
      const old = this.records.get(record.recordName);
      if (operationType === "create" && old) return { recordName: record.recordName, serverErrorCode: "EXISTS" };
      if (operationType === "replace" && (!old || old.recordChangeTag !== record.recordChangeTag)) return {
        recordName: record.recordName, serverErrorCode: old ? "CONFLICT" : "NOT_FOUND" };
      const saved = { recordName: record.recordName, recordType: record.recordType,
        recordChangeTag: String(++this.sequence), fields: structuredClone(record.fields) };
      this.records.set(saved.recordName, saved); return structuredClone(saved);
    });
    const response = Response.json({ records: records.reverse() });
    return await this.after?.({ ...call, response }) ?? response;
  }
}
export function publicFixture(options) {
  const f = fixture(options), model = new PublicCloudKitModel();
  const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
  const client = publicClient((...args) => model.fetch(...args), { clock: f.clock });
  const repository = new CloudKitPublicRepository({ registry, client, authentication: f.state, clock: f.clock });
  const deletions = new AccountDeletionState(f.storage, { clock: f.clock });
  const deleter = new AccountDeletionCoordinator({ authenticationState: f.state, deletionState: deletions, verifier: f.verifier });
  return { ...f, model, registry, client, repository, deletions,
    async beginDeletion(session, subject = "synthetic.user") {
      const challenge = await f.state.issueChallenge(hash(randomUUID()), { purpose: "account_deletion" });
      const deletionID = randomUUID(), statusToken = deletionID + "." + randomBytes(32).toString("base64url");
      const ticket = { challengeID: challenge.challengeID, identityToken: f.token(challenge, subject),
        deletionID, statusToken, expectedAccountID: session.accountID };
      await deleter.request(ticket); return ticket;
    },
    async erase(ticket) {
      const context = await deletions.claimPublicBatch(ticket.deletionID);
      assert.ok(context);
      const receipt = await repository.erasePublicDataBatch({ ...context, maximumRecords: 100 });
      await deletions.completePublicBatch(context, receipt); return receipt;
    },
    processor() { return new AccountDeletionProcessor({ deletionState: deletions, credentialVault: f.vault,
      appleClient: { async revokeRefreshToken() {} }, erasePublicDataBatch: context => repository.erasePublicDataBatch(context) }); },
  };
}
export const publicCode = code => error => error?.code === code && error.message === "Community data operation could not be completed." && error.cause === undefined;
export function profileInput(session, name = "Maja") {
  return { accessToken: session.sessionToken, kind: "profile", logicalID: "singleton", requestID: randomUUID(), input: { name } };
}
export function messageInput(session, text = "Syntetyczna wiadomość") {
  const id = randomUUID();
  return { accessToken: session.sessionToken, kind: "message", logicalID: id, requestID: id,
    input: { name: "Maja", text, latitude: 51.1123456, longitude: 17.0345678 } };
}
