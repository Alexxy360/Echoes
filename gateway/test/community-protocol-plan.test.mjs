import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { makeCommunityProtocolPlan, verifyCommunityProtocolPlan } from "../scripts/community-protocol-plan.mjs";
import { inspectSchema } from "../scripts/prepare-community-schema.mjs";
import { checkpointRecordName, validCheckpoint } from "../src/public-registry-checkpoint.mjs";

const installed = inspectSchema(await readFile(new URL("../schema/development-installed-20261119.ckdb", import.meta.url), "utf8"));
const seed = () => ({ runID: randomUUID(), accountID: randomUUID(), startedAt: 1795040000000 });

test("eight synthetic records fit the actually installed types without assets, external coordinates or the real checkpoint", () => {
  const { plan } = makeCommunityProtocolPlan(seed());
  assert.equal(plan.records.length, 8); assert.equal(new Set(plan.records.map(record => record.recordName)).size, 8);
  assert.equal(plan.scope.environment, "development"); assert.equal(plan.scope.database, "public");
  for (const record of plan.records) {
    assert.notEqual(record.recordName, checkpointRecordName);
    const type = installed.types.find(type => type.name === record.recordType); assert.ok(type);
    for (const fields of [record.initial, record.replaced]) for (const [name, field] of Object.entries(fields)) {
      assert.equal(type.fields[name]?.type, field.type, record.kind + "." + name);
      assert.notEqual(field.type, "ASSET");
    }
    if (record.initial.location) assert.deepEqual(record.initial.location.value, { latitude: 0, longitude: 0 });
  }
  assert.match(plan.records.find(record => record.kind === "checkpoint").recordName, /^community-protocol-checkpoint-v1-/);
});

test("replacement inventory removes content and ties the four retention fences to distinct exact intents", () => {
  const { plan } = makeCommunityProtocolPlan(seed()), retained = [], keys = [];
  for (const record of plan.records) {
    if (record.kind === "checkpoint") {
      assert.ok(validCheckpoint(Object.fromEntries(Object.entries(record.replaced).map(([key, field]) => [key, field.value]))));
      assert.equal(record.replaced.registryID.value, record.initial.registryID.value);
      assert.equal(record.replaced.parentAnchorID.value, record.initial.anchorID.value); continue;
    }
    assert.equal(record.replaced.erased.value, 1);
    assert.deepEqual(Object.keys(record.replaced).sort(), ["erased", "ownerKey", record.replaced.retentionKey ? "retentionKey" : "deletionKey", "schemaVersion"].sort());
    if (record.replaced.retentionKey) { retained.push(record.kind); keys.push(record.replaced.retentionKey.value); assert.notEqual(record.replaced.retentionKey.value, record.initial.payloadHash.value); }
  }
  assert.deepEqual(retained, ["presence", "message", "report", "avatar"]);
  assert.equal(new Set(keys).size, 4);
});

test("reviewed inventory can be restored exactly but rejects changed scope, fields, names, hash or extra options", () => {
  const { plan, sha256 } = makeCommunityProtocolPlan(seed());
  assert.deepEqual(verifyCommunityProtocolPlan(JSON.parse(JSON.stringify(plan)), sha256).plan, plan);
  for (const mutate of [p => p.scope.environment = "production", p => p.records[0].recordName = checkpointRecordName,
    p => p.records[0].initial.name.value = "changed", p => p.constraints.forceDelete = true, p => p.extra = "unreviewed"]) {
    const changed = structuredClone(plan); mutate(changed); assert.throws(() => verifyCommunityProtocolPlan(changed, sha256));
  }
  assert.throws(() => verifyCommunityProtocolPlan(plan, "0".repeat(64)));
});

test("fresh seeds generate disjoint inventories and malformed or overflowing seeds are refused", () => {
  const first = makeCommunityProtocolPlan(seed()), second = makeCommunityProtocolPlan(seed());
  assert.notEqual(first.sha256, second.sha256);
  const names = new Set(first.plan.records.map(record => record.recordName));
  assert.ok(second.plan.records.every(record => !names.has(record.recordName)));
  for (const bad of [{ ...seed(), extra: true }, { ...seed(), startedAt: -1 }, { ...seed(), startedAt: Number.MAX_SAFE_INTEGER },
    { ...seed(), runID: "arbitrary-record" }]) assert.throws(() => makeCommunityProtocolPlan(bad));
});
