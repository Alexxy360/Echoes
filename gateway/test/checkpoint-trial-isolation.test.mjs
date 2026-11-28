import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { fixture } from "./support/authentication-fixture.mjs";
import { publicClient } from "./support/public-record-fixture.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint, checkpointRecord, checkpointRecordName } from "../src/public-registry-checkpoint.mjs";

test("isolated checkpoint uses the real registry and conditional client protocol without the global name", async () => {
  const f = fixture(), name = "community-registry-checkpoint-trial-v1-" + randomUUID(), calls = []; let saved, sequence = 0;
  try {
    const client = publicClient(async request => {
      const body = await request.json(); calls.push(body);
      let record;
      if (request.url.endsWith("/lookup")) { assert.deepEqual(body.records, [{ recordName: name }]); record = structuredClone(saved); }
      else {
        const op = body.operations[0]; assert.equal(op.record.recordName, name);
        if (op.operationType === "replace" && op.record.recordChangeTag !== saved.recordChangeTag) record = { recordName: name, serverErrorCode: "CONFLICT" };
        else { saved = { ...op.record, recordChangeTag: String(++sequence) }; record = structuredClone(saved); }
      }
      return Response.json({ records: [record] });
    }, { checkpointName: name });
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock }), checkpoint = new PublicRegistryCheckpoint({ registry, client });
    await client.createCheckpointForBootstrap(await registry.prepareBootstrap()); await checkpoint.verify();
    const before = await registry.checkpointState(); await checkpoint.advance(); await checkpoint.verify();
    const conflict = await client.replaceCheckpoint({ ...before.confirmed.value, parentAnchorID: before.confirmed.value.anchorID, anchorID: randomUUID() }, before.confirmed.tag);
    assert.equal(conflict.serverErrorCode, "CONFLICT");
    assert.equal(checkpointRecord(saved, name).value.registryID, before.registryID);
    assert.throws(() => checkpointRecord(saved));
    assert.throws(() => checkpointRecord(saved, "community-registry-checkpoint-trial-v1-" + randomUUID()));
    assert.ok(!JSON.stringify(calls).includes('"recordName":"' + checkpointRecordName + '"'));
  } finally { f.close(); }
});
test("checkpoint configuration accepts only the default or an exact trial UUID", () => {
  assert.equal(publicClient(async () => {}).checkpointRecordName, checkpointRecordName);
  for (const name of ["other", "../checkpoint", "community-registry-checkpoint-trial-v1-", "community-registry-checkpoint-trial-v1-*", null, {}]) {
    assert.throws(() => publicClient(async () => {}, { checkpointName: name }));
  }
});
