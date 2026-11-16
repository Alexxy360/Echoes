import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarRecordFixture } from "./support/avatar-record-fixture.mjs";
import { publicCode } from "./support/public-record-fixture.mjs";
import { PublicRecordRegistry } from "../src/public-record-registry.mjs";
import { avatarDescriptor, avatarDescriptorHash } from "../src/avatar-record-schema.mjs";

const unavailable = publicCode("PUBLIC_UNAVAILABLE"), pending = publicCode("PUBLIC_PENDING");
const creates = f => f.model.requests.filter(call => call.operation === "modify");

test("real normalized image and thumbnail are staged as one immutable version with a safe receipt and no profile publication", async () => {
  const f = await avatarRecordFixture();
  try {
    const result = await f.make().stage(f.input());
    assert.deepEqual(result, { schemaVersion: 1, ownerID: f.signedIn.accountID, versionID: f.versionID, requestID: f.requestID,
      recordChangeTag: f.model.records.get(f.name).recordChangeTag, status: "staged", image: f.descriptor.image, thumbnail: f.descriptor.thumbnail });
    assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1); assert.equal(f.model.records.size, 1);
    const record = f.model.records.get(f.name);
    assert.equal(record.fields.moderationState.value, "pending"); assert.equal(record.fields.image.value.size, f.descriptor.image.byteCount);
    assert.equal(f.registry.readable(f.name, "avatar").phase, "settled");
    const rows = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").all();
    assert.ok(rows.every(row => row.receipt_envelope === null && /^[a-f0-9]{64}$/.test(row.file_checksum_hash)));
    for (const secret of ["SYNTHETIC-PRIVATE-RECEIPT", "SYNTHETIC-DOWNLOAD", "downloadURL", "wrappingKey", "receipt_envelope"]) {
      assert.equal(JSON.stringify(result).includes(secret), false); assert.equal(JSON.stringify(rows).includes(secret.startsWith("SYNTHETIC") ? secret : "SYNTHETIC-PRIVATE-RECEIPT"), false);
    }
    assert.ok(creates(f).every(call => call.body.operations.every(op => op.operationType === "create")));
  } finally { f.close(); }
});

test("lost CREATE acknowledgement reconciles exact fetched assets after reopening without a second upload or create", async () => {
  const f = await avatarRecordFixture();
  try {
    f.setRecordHook(call => { if (call.operation === "modify") throw new Error("SYNTHETIC lost response"); });
    await assert.rejects(() => f.make().stage(f.input()), unavailable);
    assert.equal(f.model.records.size, 1); assert.equal(f.registry.owned(f.signedIn.accountID, "avatar", f.versionID).phase, "pending");
    f.setRecordHook(undefined);
    const result = await f.reopen().recover(f.recovery());
    assert.equal(result.status, "staged"); assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1 WHERE receipt_envelope IS NOT NULL").get().n, 0);
  } finally { f.close(); }
});

test("restart before CREATE reuses encrypted receipts for both existing uploads without source bytes", async () => {
  const f = await avatarRecordFixture();
  try {
    f.model.before = call => { if (call.operation === "modify") throw new Error("SYNTHETIC before send"); };
    await assert.rejects(() => f.make().stage(f.input()), unavailable);
    const rows = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").all();
    assert.equal(rows.length, 2); assert.ok(rows.every(row => row.phase === "acknowledged" && row.receipt_envelope));
    assert.equal(JSON.stringify(rows).includes("SYNTHETIC-PRIVATE-RECEIPT"), false); assert.equal(f.model.records.size, 0);
    f.model.before = undefined;
    const result = await f.reopen().recover(f.recovery());
    assert.equal(result.status, "staged"); assert.equal(f.assetCalls.length, 4); assert.equal(f.model.records.size, 1);
  } finally { f.close(); }
});

test("known first upload and unstarted thumbnail resume using the same source version without reuploading the image", async () => {
  const f = await avatarRecordFixture();
  try {
    let stop = true;
    const registry = new Proxy(f.registry, { get(target, key) {
      if (key === "claimAvatarTransfer") return (...args) => {
        if (stop && args[1].variant === "thumbnail") throw new Error("SYNTHETIC restart before second claim");
        return target.claimAvatarTransfer(...args);
      };
      const value = target[key]; return typeof value === "function" ? value.bind(target) : value;
    } });
    await assert.rejects(() => f.make(registry).stage(f.input()), unavailable);
    assert.equal(f.assetCalls.length, 2); stop = false;
    assert.equal((await f.reopen().stage(f.input())).status, "staged");
    assert.equal(f.assetCalls.filter(call => call.phase === "upload" && call.variant === "image").length, 1);
    assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("an unknown upload never reissues its grant or uploads and cannot settle a record", async () => {
  const f = await avatarRecordFixture();
  try {
    f.setAssetHook(call => { if (call.phase === "upload") throw new Error("SYNTHETIC unknown upload"); });
    await assert.rejects(() => f.make().stage(f.input()), unavailable);
    f.setAssetHook(undefined);
    await assert.rejects(async () => f.reopen().stage(f.input()), pending);
    await assert.rejects(async () => f.reopen().recover(f.recovery()), pending);
    assert.equal(f.assetCalls.length, 2); assert.equal(creates(f).length, 0); assert.equal(f.model.records.size, 0);
  } finally { f.close(); }
});

test("expired encrypted receipts are cleared and never resurrect an unattached version or free its consumed attempts", async () => {
  const f = await avatarRecordFixture();
  try {
    f.model.before = call => { if (call.operation === "modify") throw new Error("SYNTHETIC before create"); };
    await assert.rejects(() => f.make().stage(f.input()), unavailable); f.model.before = undefined;
    f.advance(120000);
    await assert.rejects(async () => f.reopen().recover(f.recovery()), pending);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1 WHERE receipt_envelope IS NOT NULL").get().n, 0);
    assert.equal(f.assetCalls.length, 4); assert.equal(f.model.records.size, 0);
    await assert.rejects(() => f.make().stage(f.input()), pending);
  } finally { f.close(); }
});

test("a committed version can reconcile after receipt expiry and settle responses remain idempotent", async () => {
  const f = await avatarRecordFixture();
  try {
    f.setRecordHook(call => { if (call.operation === "modify") throw new Error("SYNTHETIC lost result"); });
    await assert.rejects(() => f.make().stage(f.input()), unavailable); f.setRecordHook(undefined); f.advance(120000);
    const result = await f.reopen().recover(f.recovery());
    assert.deepEqual(await f.make().recover(f.recovery()), result);
    assert.deepEqual(await f.make().stage(f.input()), result);
    assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
  } finally { f.close(); }
});

test("a new owner login generation can reconcile old exact receipts while the old session stays rejected", async () => {
  const f = await avatarRecordFixture();
  try {
    f.model.before = call => { if (call.operation === "modify") throw new Error("SYNTHETIC restart"); };
    const old = f.input(); await assert.rejects(() => f.make().stage(old), unavailable); f.model.before = undefined;
    await f.nextLoginGeneration();
    await assert.rejects(async () => f.reopen().stage(old), publicCode("PUBLIC_SCOPE"));
    assert.equal((await f.reopen().recover(f.recovery())).status, "staged"); assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("forged/reordered descriptors are canonicalized but owner, operation, hashes, dimensions and variant substitutions fail", async () => {
  const f = await avatarRecordFixture();
  try {
    await f.make().stage(f.input());
    const reordered = structuredClone(f.descriptor); reordered.image = Object.fromEntries(Object.entries(reordered.image).reverse());
    assert.equal(avatarDescriptorHash(avatarDescriptor(reordered, f.signedIn.accountID)), avatarDescriptorHash(avatarDescriptor(f.descriptor, f.signedIn.accountID)));
    assert.equal((await f.make().recover(f.recovery({ descriptor: reordered }))).status, "staged");
    for (const mutate of [d => { d.requestID = randomUUID(); }, d => { d.image.sha256 = "0".repeat(64); },
      d => { d.image.ownerID = randomUUID(); }, d => { d.thumbnail.width = 127; }, d => { d.image.downloadURL = "https://evil.invalid"; },
      d => { d.image.variant = "thumbnail"; }, d => { d.image.versionID = randomUUID(); }]) {
      const d = structuredClone(f.descriptor); mutate(d);
      await assert.rejects(() => f.make().recover(f.recovery({ descriptor: d })), error => ["PUBLIC_INPUT", "PUBLIC_SCOPE"].includes(error.code));
    }
    assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
  } finally { f.close(); }
});

test("recovery never creates a new reservation or authorizes a forged initial normalized handle", async () => {
  const f = await avatarRecordFixture();
  try {
    await assert.rejects(() => f.make().recover(f.recovery()), publicCode("PUBLIC_SCOPE"));
    await assert.rejects(() => f.make().stage(f.input({ normalized: {} })), publicCode("PUBLIC_SCOPE"));
    await assert.rejects(() => f.make().stage(f.input({ requestID: randomUUID() })), publicCode("PUBLIC_SCOPE"));
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM public_records_v1").get().n, 0); assert.equal(f.assetCalls.length, 0);
  } finally { f.close(); }
});

test("concurrent staging and recovery create one version and never upload any variant twice", async () => {
  const f = await avatarRecordFixture();
  try {
    const results = await Promise.allSettled([f.make().stage(f.input()), f.make().stage(f.input())]);
    assert.ok(results.some(value => value.status === "fulfilled"));
    assert.equal(f.model.records.size, 1); assert.equal(f.assetCalls.length, 4);
    const reopened = f.reopen();
    const recoveries = await Promise.all([reopened.recover(f.recovery()), reopened.recover(f.recovery())]);
    assert.deepEqual(recoveries[0], recoveries[1]); assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("mismatched fetched asset identity, extra fields and record metadata cannot turn a provider echo into a settled receipt", async () => {
  for (const mutate of [r => { r.fields.image.value.fileChecksum = "OTHER"; }, r => { r.fields.thumbnail.value.size++; },
    r => { r.fields.imageSha256.value = "0".repeat(64); }, r => { r.fields.unexpected = { value: "extra" }; },
    r => { delete r.fields.thumbnail; }, r => { r.fields.image.value.extra = "smuggled"; }]) {
    const f = await avatarRecordFixture();
    try {
      let changed = false;
      f.setRecordHook(call => { if (call.operation === "modify" && !changed) { changed = true; mutate(f.model.records.get(f.name)); } });
      await assert.rejects(() => f.make().stage(f.input()), error => ["PUBLIC_RESPONSE", "PUBLIC_CONFLICT"].includes(error.code));
      assert.equal(f.registry.owned(f.signedIn.accountID, "avatar", f.versionID).phase, "pending");
    } finally { f.close(); }
  }
});

test("a settled record that disappears or changes tag cannot trigger a fresh upload or silent replacement", async () => {
  for (const missing of [true, false]) {
    const f = await avatarRecordFixture();
    try {
      await f.make().stage(f.input());
      if (missing) f.model.records.delete(f.name); else f.model.records.get(f.name).recordChangeTag = "changed-outside-version";
      await assert.rejects(async () => f.reopen().recover(f.recovery()), publicCode("PUBLIC_CONFLICT"));
      await assert.rejects(async () => f.reopen().stage(f.input()), publicCode("PUBLIC_CONFLICT"));
      assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
    } finally { f.close(); }
  }
});

test("disable, async/missing/mismatched consent and cancellation stop staging before dispatch", async () => {
  const f = await avatarRecordFixture();
  try {
    for (const authorizeMutation of [undefined, () => {}, () => false, () => ({ accountID: randomUUID() }), async () => ({ accountID: f.signedIn.accountID })]) {
      await assert.rejects(() => f.make().stage(f.input({ authorizeMutation })), error => ["PUBLIC_INPUT", "PUBLIC_SCOPE"].includes(error.code));
    }
    const controller = new AbortController(); controller.abort();
    await assert.rejects(() => f.make().stage(f.input({ signal: controller.signal })), unavailable);
    f.disable(); await assert.rejects(() => f.make().stage(f.input()), unavailable);
    assert.equal(f.assetCalls.length, 0); assert.equal(f.model.requests.length, 0);
  } finally { f.close(); }
});

test("a final policy change during the last checkpoint prevents returning a staged receipt", async () => {
  const f = await avatarRecordFixture();
  try {
    f.model.afterCheckpoint = call => {
      if (call.operation === "modify" && f.db.prepare("SELECT phase FROM public_records_v1").get()?.phase === "settled") f.disable();
    };
    await assert.rejects(() => f.make().stage(f.input()), unavailable);
    assert.equal(f.model.records.size, 1); assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("erasure between CREATE and acknowledgement removes assets/receipts and fences late recovery", async () => {
  const f = await avatarRecordFixture();
  try {
    let ticket;
    f.setRecordHook(async call => {
      if (call.operation === "modify" && !ticket) {
        ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket);
      }
    });
    await assert.rejects(() => f.make().stage(f.input()), publicCode("PUBLIC_SCOPE"));
    const record = f.model.records.get(f.name); assert.equal(record.fields.erased.value, 1);
    assert.equal(record.fields.image, undefined); assert.equal(record.fields.thumbnail, undefined);
    const rows = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").all();
    assert.ok(rows.every(row => row.receipt_envelope === null && row.file_checksum_hash === null && row.phase === "erased"));
    await assert.rejects(async () => f.reopen().recover(f.recovery()), publicCode("PUBLIC_SCOPE"));
  } finally { f.close(); }
});

test("corrupted encrypted receipts, provider commitments and missing metadata fail closed without another upload", async () => {
  for (const sql of ["UPDATE avatar_asset_transfers_v1 SET receipt_envelope='corrupt'", "UPDATE avatar_asset_transfers_v1 SET file_checksum_hash='bad'",
    "UPDATE avatar_asset_transfers_v1 SET file_checksum_hash='" + "0".repeat(64) + "'",
    "UPDATE avatar_asset_transfers_v1 SET receipt_envelope=(SELECT receipt_envelope FROM avatar_asset_transfers_v1 WHERE variant='thumbnail') WHERE variant='image'",
    "DELETE FROM avatar_asset_transfers_v1 WHERE variant='thumbnail'"]) {
    const f = await avatarRecordFixture();
    try {
      f.model.before = call => { if (call.operation === "modify") throw new Error("SYNTHETIC restart"); };
      await assert.rejects(() => f.make().stage(f.input()), unavailable); f.model.before = undefined; f.db.exec(sql);
      await assert.rejects(async () => f.reopen().recover(f.recovery()), error => ["PUBLIC_UNAVAILABLE", "PUBLIC_SCOPE", "PUBLIC_PENDING", "PUBLIC_REGISTRY_UNVERIFIED"].includes(error.code));
      await assert.rejects(() => f.make().stage(f.input()), error => ["PUBLIC_UNAVAILABLE", "PUBLIC_SCOPE", "PUBLIC_PENDING", "PUBLIC_REGISTRY_UNVERIFIED"].includes(error.code));
      assert.equal(f.assetCalls.length, 4); assert.equal(f.model.records.size, 0);
    } finally { f.close(); }
  }
});

test("legacy attempts remain consumed and erasable after additive metadata migration", async () => {
  const f = await avatarRecordFixture();
  try {
    f.model.before = call => { if (call.operation === "modify") throw new Error("SYNTHETIC restart"); };
    await assert.rejects(() => f.make().stage(f.input()), unavailable); f.model.before = undefined;
    f.db.exec("DROP INDEX avatar_receipt_expiry_v1");
    f.db.exec("ALTER TABLE public_records_v1 DROP COLUMN asset_claims");
    for (const column of ["file_checksum_hash", "receipt_envelope", "receipt_expires_at"]) f.db.exec("ALTER TABLE avatar_asset_transfers_v1 DROP COLUMN " + column);
    const registry = new PublicRecordRegistry(f.storage, { clock: f.clock });
    await assert.rejects(() => f.make(registry).recover(f.recovery()), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    const ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket);
    assert.equal(f.model.records.get(f.name).fields.erased.value, 1);
    assert.ok(f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").all().every(row => row.phase === "erased"));
  } finally { f.close(); }
});

test("in-flight CREATE and explicit recovery may race but immutable create prevents duplicate or replaced content", { timeout: 5000 }, async () => {
  const f = await avatarRecordFixture(); let release;
  try {
    let reached;
    const ready = new Promise(resolve => { reached = resolve; }), hold = new Promise(resolve => { release = resolve; });
    let first = true;
    f.model.before = async call => {
      if (call.operation === "modify" && first) { first = false; reached(); await hold; }
    };
    const repository = f.make(), initial = repository.stage(f.input());
    initial.catch(() => {});
    await ready;
    const recovered = await repository.recover(f.recovery());
    release(); const original = await initial;
    assert.deepEqual(original, recovered); assert.equal(f.model.records.size, 1); assert.equal(f.assetCalls.length, 4);
    assert.equal(creates(f).length, 2); assert.ok(creates(f).every(call => call.body.operations[0].operationType === "create"));
  } finally { release?.(); f.close(); }
});

test("erasure fence wins when its CREATE completes before a delayed avatar CREATE", async () => {
  const f = await avatarRecordFixture();
  try {
    let ticket;
    f.model.before = async call => {
      if (call.operation === "modify" && !ticket) { ticket = await f.beginDeletion(f.signedIn); await f.erase(ticket); }
    };
    await assert.rejects(() => f.make().stage(f.input()), publicCode("PUBLIC_SCOPE"));
    const record = f.model.records.get(f.name); assert.equal(record.fields.erased.value, 1);
    assert.deepEqual(Object.keys(record.fields).sort(), ["deletionKey", "erased", "ownerKey", "schemaVersion"]);
    assert.ok(f.db.prepare("SELECT * FROM avatar_asset_transfers_v1").all().every(row => row.phase === "erased" && row.receipt_envelope === null));
    assert.equal(f.assetCalls.length, 4);
  } finally { f.close(); }
});

test("failed settlement durability returns no false receipt and reconciles committed provider data on explicit recovery", async () => {
  let armed = false;
  const f = await avatarRecordFixture({ syncHook: () => {
    if (armed && f.db.prepare("SELECT phase FROM public_records_v1").get()?.phase === "settled") { armed = false; throw new Error("SYNTHETIC disk sync"); }
  } });
  try {
    armed = true; await assert.rejects(() => f.make().stage(f.input()), unavailable);
    assert.equal(f.model.records.size, 1); assert.equal(f.assetCalls.length, 4);
    assert.equal((await f.reopen().recover(f.recovery())).status, "staged");
    assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
  } finally { f.close(); }
});

test("restoring SQLite with older encrypted receipts is rejected against the newer remote checkpoint before any dispatch", async () => {
  const { sqliteSnapshot, restoreSQLite } = await import("./support/sqlite-snapshot.mjs");
  const f = await avatarRecordFixture();
  try {
    let snapshot;
    f.setAssetHook(call => { if (call.phase === "grant" && call.variant === "thumbnail") snapshot = sqliteSnapshot(f.db); });
    await f.make().stage(f.input()); assert.ok(snapshot);
    restoreSQLite(f.storage, snapshot);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM avatar_asset_transfers_v1 WHERE receipt_envelope IS NOT NULL").get().n, 1);
    await assert.rejects(async () => f.reopen().recover(f.recovery()), publicCode("PUBLIC_REGISTRY_UNVERIFIED"));
    assert.equal(f.assetCalls.length, 4); assert.equal(creates(f).length, 1);
  } finally { f.close(); }
});
