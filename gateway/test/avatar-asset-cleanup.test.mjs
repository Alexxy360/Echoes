import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { avatarRecordFixture } from "./support/avatar-record-fixture.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";
import { avatarDescriptor } from "../src/avatar-record-schema.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { digest } from "../src/public-record-schema.mjs";
import { queryCanonical } from "../scripts/community-query-plan.mjs";
import { runAssetCleanup } from "../scripts/avatar-asset-cleanup.mjs";

async function setup(t) {
  const f = await avatarRecordFixture(); t.after(() => f.close()); await f.make().stage(f.input());
  const state = await f.registry.checkpointState(), runID = randomUUID(), checkpointName = "community-registry-checkpoint-trial-v1-" + runID;
  const plan = { purpose: "echoes-avatar-assets-development-v1", runID, accountID: f.signedIn.accountID, versionID: f.versionID, requestID: f.requestID,
    scope: { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development", database: "public" },
    avatarRecordName: f.name, checkpointName, initialCheckpoint: state.initial, descriptor: avatarDescriptor(f.descriptor, f.signedIn.accountID) };
  const context = f.registry.owned(plan.accountID, "avatar", plan.versionID), records = new Map();
  const avatar = structuredClone(f.model.records.get(f.name)); for (const v of ["image", "thumbnail"]) avatar.fields[v].type = "ASSETID";
  records.set(f.name, avatar); records.set(checkpointName, { ...structuredClone([...f.model.controls.values()][0]), recordName: checkpointName });
  const expected = { prepared: { plan, sha256: digest(queryCanonical(plan)) }, context, commitments: f.registry.avatarAssetCommitments(context), checkpoint: state.confirmed.value };
  const key = syntheticPublicKeyConfiguration(), signer = new CloudKitDevelopmentSigner({ container: plan.scope.container, environment: "development", keyID: key.CLOUDKIT_KEY_ID, privateKeyPEM: key.CLOUDKIT_PRIVATE_KEY });
  const calls = [], intents = []; let conflict = false;
  const fetchImplementation = async request => {
    assert.equal(request.url.startsWith("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/records/"), true);
    const body = await request.json(); calls.push(body); const names = body.records?.map(r => r.recordName) ?? body.operations.map(o => o.record.recordName);
    assert.ok(names.every(n => [f.name, checkpointName].includes(n)));
    if (body.records) return Response.json({ records: names.map(n => structuredClone(records.get(n) ?? { recordName: n, serverErrorCode: "NOT_FOUND" })) });
    return Response.json({ records: body.operations.map(op => {
      assert.equal(op.operationType, "delete"); const old = records.get(op.record.recordName);
      if (conflict && op.record.recordName === f.name) old.recordChangeTag = "concurrent-version";
      if (old.recordChangeTag !== op.record.recordChangeTag) return { recordName: old.recordName, serverErrorCode: "CONFLICT" };
      records.delete(old.recordName); return { recordName: old.recordName, deleted: true };
    }) });
  };
  return { expected, records, calls, intents, conflict() { conflict = true; }, options: { expected, signer, fetchImplementation, isAuthorized: () => true, saveIntent: async value => { intents.push(value); } } };
}
test("cleanup validates immutable ownership/checksums despite an optional wire label, then conditionally deletes only two records", async t => {
  const f = await setup(t), result = await runAssetCleanup(f.options);
  assert.equal(result.cleanupSucceeded, true); assert.equal(result.requests, 3); assert.equal(result.deleteAcknowledgements, 2);
  assert.deepEqual(result.assetFieldTypes, { image: "ASSETID", thumbnail: "ASSETID" }); assert.equal(f.records.size, 0);
  assert.equal(result.uploads, 0); assert.equal(result.downloads, 0); assert.equal(result.creates, 0); assert.equal(f.intents.length, 3);
  assert.ok(!/downloadURL|SYNTHETIC-PRIVATE|receipt/.test(JSON.stringify(result)));
});
test("checksum mismatch prevents every delete and leaves both records intact", async t => {
  const f = await setup(t); f.records.get(f.expected.context.recordName).fields.image.value.fileChecksum = "WRONG-CHECKSUM";
  const result = await runAssetCleanup(f.options); assert.equal(result.cleanupSucceeded, false); assert.equal(f.calls.length, 1); assert.equal(f.records.size, 2);
});
test("foreign checkpoint state prevents every delete", async t => {
  const f = await setup(t); f.records.get(f.expected.prepared.plan.checkpointName).fields.registryID.value = randomUUID();
  const result = await runAssetCleanup(f.options); assert.equal(result.cleanupSucceeded, false); assert.equal(f.calls.length, 1); assert.equal(f.records.size, 2);
});
test("conditional delete conflict is reported without force or retry", async t => {
  const f = await setup(t); f.conflict(); const result = await runAssetCleanup(f.options);
  assert.equal(result.cleanupSucceeded, false); assert.equal(result.requests, 3); assert.equal(result.deleteAcknowledgements, 1); assert.equal(f.records.size, 1);
});
test("cleanup defaults to disabled before any fetch or durable reservation", async t => {
  const f = await setup(t); const options = { ...f.options }; delete options.isAuthorized;
  const result = await runAssetCleanup(options); assert.equal(result.cleanupSucceeded, false); assert.equal(result.requests, 0); assert.equal(f.calls.length, 0); assert.equal(f.intents.length, 0);
});
