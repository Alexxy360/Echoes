import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, createPublicKey, verify, randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { assetTrialCommand, prepareAssetTrial, AssetTrialTransport } from "../scripts/avatar-asset-trial.mjs";
import { publishProtocolPrivateJSON } from "../scripts/community-protocol-files.mjs";
import { digest } from "../src/public-record-schema.mjs";

async function setup(t) {
  const parent = await mkdtemp(join(tmpdir(), "echoes-asset-trial-unit-"));
  t.after(() => rm(parent, { recursive: true, force: true }));
  const { directory, prepared } = await prepareAssetTrial(parent), p = prepared.plan;
  const pair = generateKeyPairSync("ec", { namedCurve: "prime256v1" }), pem = pair.privateKey.export({ type: "pkcs8", format: "pem" });
  const keyRegistration = { keyID: "synthetic-trial-v1", publicKeySHA256: digest(createPublicKey(pair.privateKey).export({ type: "spki", format: "der" })) };
  const permit = { schemaVersion: 1, purpose: p.purpose, scope: p.scope, planSHA256: prepared.sha256, window: { id: randomUUID(), issuedAt: Date.now() - 1000, expiresAt: Date.now() + 60000 },
    ...keyRegistration, identityModel: "individual-owner-administrator-v1" };
  const permitPath = join(directory, "permit.json"), keyPath = join(directory, "key.pem");
  await publishProtocolPrivateJSON(permitPath, permit);
  const { writeFile } = await import("node:fs/promises"); await writeFile(keyPath, pem, { mode: 0o600 });
  const records = new Map(), bytes = new Map(), calls = []; let sequence = 0, hook;
  const fetchImplementation = async (request, options) => {
    assert.ok(options.signal instanceof AbortSignal); assert.equal(request.redirect, "manual"); const u = new URL(request.url);
    let payload;
    if (u.hostname === "api.apple-cloudkit.com") {
      const raw = await request.text(), body = JSON.parse(raw), date = request.headers.get("x-apple-cloudkit-request-iso8601date");
      const sig = request.headers.get("x-apple-cloudkit-request-signaturev1");
      assert.equal(verify("sha256", Buffer.from(date + ":" + Buffer.from(digest(raw), "hex").toString("base64") + ":" + u.pathname), pair.publicKey, Buffer.from(sig, "base64")), true);
      if (u.pathname.endsWith("/assets/upload")) {
        const token = body.tokens[0]; calls.push("grant:" + token.fieldName);
        payload = { tokens: [{ recordName: p.avatarRecordName, fieldName: token.fieldName, url: "https://cws.icloud-content.com:443/" + token.fieldName + "?token=SYNTHETIC-UPLOAD" }] };
      } else if (u.pathname.endsWith("/records/lookup")) {
        calls.push("lookup"); payload = { records: body.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) };
      } else {
        calls.push("modify"); payload = { records: body.operations.map(op => {
          const row = op.record, old = records.get(row.recordName);
          if (op.operationType === "create" && old) return { recordName: row.recordName, serverErrorCode: "EXISTS" };
          if (op.operationType !== "create" && (!old || old.recordChangeTag !== row.recordChangeTag)) return { recordName: row.recordName, serverErrorCode: old ? "CONFLICT" : "NOT_FOUND" };
          if (op.operationType === "delete") { records.delete(row.recordName); return { recordName: row.recordName, deleted: true }; }
          const saved = structuredClone({ ...row, recordChangeTag: String(++sequence) });
          if (saved.recordType === "EchoesAvatarV1") for (const v of ["image", "thumbnail"]) {
            saved.fields[v].value = { fileChecksum: saved.fields[v].value.fileChecksum, size: saved.fields[v].value.size,
              downloadURL: "https://cvws.icloud-content.com/" + v + '/${f}?token=SYNTHETIC-DOWNLOAD' };
          }
          records.set(row.recordName, saved); return structuredClone(saved);
        }) };
      }
    } else {
      assert.equal(request.credentials, "omit"); assert.equal(request.headers.has("authorization"), false);
      assert.ok(![...request.headers.keys()].some(k => k.startsWith("x-apple")));
      const v = u.pathname.split("/")[1];
      if (request.method === "POST") {
        calls.push("upload:" + v); const data = new Uint8Array(await request.arrayBuffer()); bytes.set(v, data);
        assert.equal(digest(data), p.descriptor[v].sha256);
        payload = { singleFile: { size: data.length, fileChecksum: "SYNTHETIC-" + digest(data), receipt: "SYNTHETIC-RECEIPT-" + v } };
      } else {
        calls.push("download:" + v); return await hook?.(request) ?? new Response(bytes.get(v), { headers: { "Content-Type": "image/jpeg" } });
      }
    }
    return await hook?.(request, payload) ?? Response.json(payload);
  };
  return { directory, prepared, p, records, bytes, calls, setHook(value) { hook = value; },
    options: { env: { ECHOES_ALLOW_ASSET_TRIAL_DEV: "1" }, fetchImplementation, keyRegistration },
    args: ["run", directory, prepared.sha256, permitPath, keyPath] };
}
test("asset trial prepares/inspects without network and defaults to disabled", async t => {
  const f = await setup(t); let network = 0;
  const inspected = await assetTrialCommand(["inspect", f.directory, f.prepared.sha256], { fetchImplementation: () => { network++; } });
  assert.equal(inspected.networkRequests, 0); assert.equal(network, 0);
  await assert.rejects(assetTrialCommand(f.args, { env: {} }), e => e.code === "ASSET_TRIAL_DISABLED");
  await assert.rejects(readFile(join(f.directory, "attempt.json")), { code: "ENOENT" });
});
test("asset trial uses production codecs/registry/assets/repository, exact bytes, CAS and two-record cleanup", async t => {
  const f = await setup(t), result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.errorCode, null); assert.equal(result.status, "asset_protocol_verified");
  assert.deepEqual({ ...result.counts, api: 0 }, { api: 0, grants: 2, uploads: 2, downloads: 2 });
  assert.ok(result.counts.api < f.p.limits.apiRequests); assert.equal(f.records.size, 0);
  assert.equal(result.realSessionAuthorizationVerified, false); assert.equal(result.providerPhysicalAssetDeletionVerified, false);
  const count = f.calls.length;
  await assert.rejects(assetTrialCommand(f.args, f.options)); assert.equal(f.calls.length, count);
  const output = await readFile(join(f.directory, "report.json"), "utf8"); assert.ok(!/SYNTHETIC|downloadURL|receipt|privateKey/.test(output));
});
test("upload failure does not retry and conditionally removes its isolated checkpoint", async t => {
  const f = await setup(t); f.setHook(request => request.url.startsWith("https://cws.") ? new Response(null, { status: 503 }) : undefined);
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.protocolSucceeded, false); assert.equal(result.cleanupSucceeded, true);
  assert.equal(result.counts.uploads, 1); assert.equal(f.records.size, 0); assert.equal(f.calls.filter(v => v.startsWith("upload:")).length, 1);
});
test("download mismatch rejects bytes and still removes only its two synthetic records", async t => {
  const f = await setup(t); f.setHook(request => {
    if (request.method !== "GET") return;
    const bytes = f.bytes.get(new URL(request.url).pathname.split("/")[1]).slice(); bytes[30] ^= 1;
    return new Response(bytes, { headers: { "Content-Type": "image/jpeg" } });
  });
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.protocolSucceeded, false); assert.equal(result.cleanupSucceeded, true); assert.equal(f.records.size, 0); assert.equal(result.counts.downloads, 1);
});
test("an existing random record is preserved and no grant/write/upload follows preflight", async t => {
  const f = await setup(t); f.records.set(f.p.avatarRecordName, { recordName: f.p.avatarRecordName, recordType: "EchoesAvatarV1", recordChangeTag: "existing", fields: {} });
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.errorCode, "ASSET_TRIAL_COLLISION"); assert.equal(f.records.size, 1);
  assert.ok(f.calls.every(v => v === "lookup"));
});
test("asset transport rejects global checkpoint, unrelated hosts and unapproved bytes before fetch", async t => {
  const f = await setup(t); let calls = 0;
  const transport = new AssetTrialTransport({ plan: f.p, check() {}, saveIntent: async () => {}, fetchImplementation: async () => { calls++; } });
  const signal = new AbortController().signal;
  const request = new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/records/lookup", { method: "POST", redirect: "manual", body: JSON.stringify({ records: [{ recordName: "community-registry-checkpoint-v1" }] }) });
  await assert.rejects(transport.fetch(request, { signal }));
  for (const host of ["evil.example", "cws.icloud-content.com"]) await assert.rejects(transport.fetch(new Request("https://" + host + "/wrong", { method: "POST", redirect: "manual", credentials: "omit", body: new Uint8Array([1]) }), { signal }));
  assert.equal(calls, 0);
});
test("unknown projected download host is never followed and both records are cleaned", async t => {
  const f = await setup(t); f.setHook((request, payload) => {
    if (request.url.endsWith("/records/lookup")) for (const record of payload.records) if (record.fields?.image) {
      record.fields.image.value.downloadURL = "https://other.icloud-content.com/never-follow?token=SYNTHETIC";
    }
  });
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.protocolSucceeded, false); assert.equal(result.cleanupSucceeded, true); assert.equal(result.counts.downloads, 0); assert.equal(f.records.size, 0);
});
test("malformed bootstrap echo after remote create is reconciled and cleaned", async t => {
  const f = await setup(t); let malformed = false;
  f.setHook((request, payload) => {
    if (!malformed && request.url.endsWith("/records/modify") && payload.records[0]?.recordType === "EchoesRegistryCheckpointV1") {
      malformed = true; return Response.json({ records: [] });
    }
  });
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.protocolSucceeded, false); assert.equal(result.cleanupSucceeded, true); assert.equal(result.counts.uploads, 0); assert.equal(f.records.size, 0);
});
test("a cleanup CAS conflict preserves the changed record and reports incomplete cleanup", async t => {
  const f = await setup(t); let changed = false;
  f.setHook((request, payload) => {
    if (!changed && f.calls.includes("download:thumbnail") && request.url.endsWith("/records/lookup") && payload.records.some(r => r.recordName === f.p.checkpointName)) {
      changed = true; f.records.get(f.p.checkpointName).recordChangeTag = "concurrent-version";
    }
  });
  const result = await assetTrialCommand(f.args, f.options);
  assert.equal(result.protocolSucceeded, true); assert.equal(result.cleanupSucceeded, false); assert.equal(result.status, "incomplete");
  assert.equal(f.records.size, 1); assert.equal(f.records.get(f.p.checkpointName).recordChangeTag, "concurrent-version");
});
test("expired permit and modified inventory cannot start a request or reserve an attempt", async t => {
  const f = await setup(t); const { writeFile } = await import("node:fs/promises");
  const permit = JSON.parse(await readFile(f.args[3], "utf8")); permit.window.expiresAt = Date.now() - 1; permit.window.issuedAt = permit.window.expiresAt - 1000;
  await writeFile(f.args[3], JSON.stringify(permit), { mode: 0o600 });
  await assert.rejects(assetTrialCommand(f.args, f.options), e => e.code === "ASSET_TRIAL_PERMIT");
  const inventory = JSON.parse(await readFile(join(f.directory, "inventory.json"), "utf8")); inventory.plan.uploadHosts.push("other.icloud-content.com");
  await writeFile(join(f.directory, "inventory.json"), JSON.stringify(inventory), { mode: 0o600 });
  await assert.rejects(assetTrialCommand(f.args, f.options), e => e.code === "ASSET_TRIAL_INVENTORY");
  assert.equal(f.calls.length, 0); await assert.rejects(readFile(join(f.directory, "attempt.json")), { code: "ENOENT" });
});
test("late fetch remains retained after cancellation and grant is not repeated", async t => {
  const f = await setup(t); let complete, entered;
  const ready = new Promise(resolve => { entered = resolve; });
  const transport = new AssetTrialTransport({ plan: f.p, check() {}, saveIntent: async () => {}, fetchImplementation: () => { entered(); return new Promise(resolve => { complete = resolve; }); } });
  const controller = new AbortController();
  const request = () => new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload", { method: "POST", redirect: "manual",
    body: JSON.stringify({ tokens: [{ recordName: f.p.avatarRecordName, recordType: "EchoesAvatarV1", fieldName: "image" }] }) });
  const work = transport.fetch(request(), { signal: controller.signal }); await ready; controller.abort();
  await assert.rejects(work); assert.equal(await transport.drain(1), false);
  const next = new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload", { method: "POST", redirect: "manual",
    body: JSON.stringify({ tokens: [{ recordName: f.p.avatarRecordName, recordType: "EchoesAvatarV1", fieldName: "thumbnail" }] }) });
  await assert.rejects(transport.fetch(next, { signal: new AbortController().signal }), e => e.code === "ASSET_TRIAL_PENDING_IO");
  complete(Response.json({ tokens: [] })); assert.equal(await transport.drain(), true);
  await assert.rejects(transport.fetch(request(), { signal: new AbortController().signal })); assert.equal(transport.counts.grants, 1);
});
test("API budget is enforced before the sixty-fifth fetch", async t => {
  const f = await setup(t); let calls = 0;
  const transport = new AssetTrialTransport({ plan: f.p, check() {}, saveIntent: async () => {}, fetchImplementation: async () => { calls++; return Response.json({ records: [] }); } });
  const request = () => new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/records/lookup", { method: "POST", redirect: "manual", body: JSON.stringify({ records: [{ recordName: f.p.avatarRecordName }] }) });
  for (let i = 0; i < 64; i++) await transport.fetch(request(), { signal: new AbortController().signal });
  await assert.rejects(transport.fetch(request(), { signal: new AbortController().signal }));
  assert.equal(calls, 64); assert.equal(transport.counts.api, 64);
});
test("bounded error JSON exposes only closed provider codes and heuristic categories", async t => {
  const f = await setup(t), secret = "SYNTHETIC-SECRET-URL-RECEIPT-REASON";
  for (const [code, reason, expectedCode, category] of [
    ["BAD_REQUEST", "Unknown enum type ASSET " + secret, "BAD_REQUEST", "asset_type"],
    [secret, "Bad asset receipt " + secret, "OTHER", "asset_receipt"],
    ["BAD_REQUEST", "Unknown field " + secret, "BAD_REQUEST", "schema_field"],
    ["BAD_REQUEST", secret, "BAD_REQUEST", "other"],
  ]) {
    const transport = new AssetTrialTransport({ plan: f.p, check() {}, saveIntent: async () => {}, fetchImplementation: async () =>
      Response.json({ serverErrorCode: code, reason, downloadURL: secret, receipt: secret }, { status: 400 }) });
    const request = new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/records/lookup", { method: "POST", redirect: "manual", body: JSON.stringify({ records: [{ recordName: f.p.avatarRecordName }] }) });
    await assert.rejects(transport.fetch(request, { signal: new AbortController().signal }));
    assert.equal(await transport.drain(), true);
    const d = transport.diagnostics; assert.equal(d.httpStatus, 400); assert.equal(d.providerErrorCode, expectedCode); assert.equal(d.providerReasonCategory, category);
    assert.ok(d.decodedBytes > 0); assert.ok(!JSON.stringify(d).includes(secret));
  }
});
test("oversized error JSON stays bounded and never yields provider text", async t => {
  const f = await setup(t);
  const transport = new AssetTrialTransport({ plan: f.p, check() {}, saveIntent: async () => {}, fetchImplementation: async () =>
    Response.json({ serverErrorCode: "BAD_REQUEST", reason: "PRIVATE".repeat(3000) }, { status: 400 }) });
  const request = new Request("https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/records/lookup", { method: "POST", redirect: "manual", body: JSON.stringify({ records: [{ recordName: f.p.avatarRecordName }] }) });
  await assert.rejects(transport.fetch(request, { signal: new AbortController().signal }));
  assert.equal(await transport.drain(), true); assert.ok(!JSON.stringify(transport.diagnostics).includes("PRIVATE"));
  assert.equal(transport.diagnostics.providerErrorCode, undefined);
});
