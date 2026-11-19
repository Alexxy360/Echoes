import { Buffer } from "node:buffer";
import { randomBytes, createHash, createPublicKey, verify } from "node:crypto";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { CloudKitPublicRetentionProcessor } from "../../src/public-retention-processor.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { PublicRegistryCheckpoint, checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";

// Loopback only: actual workerd SQL/signatures/repository; explicit synthetic Apple/accounts.
export async function avatarReportCancellationWorkerdProof(request, storage) {
  const raw = new Uint8Array(await request.arrayBuffer()); if (raw.length > 262144) throw Error("Fixture too large");
  const p = JSON.parse(new TextDecoder().decode(raw));
  if (p.synthetic !== "echoes-owned-local-report-cancellation-v1" || !Number.isSafeInteger(p.now)) throw Error("Synthetic fixture required");
  const clock = () => p.now, renewalProofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
  new AuthenticationState(storage, { clock, renewalProofs }); new PublicRecordRegistry(storage, { clock }); new AccountDeletionState(storage, { clock });
  const tables = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(row => row.name)); let rows = 0;
  storage.transactionSync(() => {
    for (const table of p.tables) {
      if (!tables.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || (rows += table.rows.length) > 10000) throw Error("Unexpected synthetic table");
      const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(row => row.name));
      storage.sql.exec(`DELETE FROM ${table.name}`);
      for (const row of table.rows) {
        const keys = Object.keys(row); if (keys.some(k => !columns.has(k) || !/^[a-z0-9_]+$/.test(k))) throw Error("Unexpected synthetic column");
        storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(k => row[k]));
      }
    }
  }); await storage.sync();
  const records = new Map(p.records.map(record => [record.recordName, record])), publicKey = createPublicKey(p.privateKeyPEM);
  let sequence = 0, reportMutations = 0, lost = false;
  const provider = async req => {
    const url = new URL(req.url), text = await req.text(), body = JSON.parse(text), hash = createHash("sha256").update(text).digest("base64");
    if (url.origin !== "https://api.apple-cloudkit.com" || req.method !== "POST" || req.redirect !== "manual" ||
        !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${hash}:${url.pathname}`), publicKey,
          Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw Error("Synthetic signature mismatch");
    if (url.pathname.endsWith("/records/lookup")) return Response.json({ records: body.records.map(({ recordName }) => {
      const record = structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" });
      if (body.desiredKeys && record.fields) record.fields = Object.fromEntries(Object.entries(record.fields).filter(([key]) => body.desiredKeys.includes(key)));
      return record;
    }) });
    if (!url.pathname.endsWith("/records/modify") || body.operations.length !== 1) throw Error("Unexpected synthetic operation");
    const op = body.operations[0], old = records.get(op.record.recordName);
    if (op.record.recordName !== checkpointRecordName) {
      if (!p.allowedRecordNames.includes(op.record.recordName) || op.record.recordType !== "EchoesAvatarReportV1") throw Error("Unexpected synthetic report identity");
      reportMutations++;
    }
    if (op.operationType === "create" && old) return Response.json({ records: [{ recordName: op.record.recordName, serverErrorCode: "EXISTS" }] });
    if (op.operationType === "replace" && (!old || old.recordChangeTag !== op.record.recordChangeTag)) return Response.json({ records: [{ recordName: op.record.recordName, serverErrorCode: "CONFLICT" }] });
    if (!["create", "replace"].includes(op.operationType)) throw Error("Synthetic operation not allowed");
    const saved = { ...op.record, recordChangeTag: "cancel-workerd-" + ++sequence }; records.set(saved.recordName, saved);
    if (!lost && saved.recordName === p.allowedRecordNames[1]) { lost = true; throw Error("Synthetic lost cancellation ACK"); }
    return Response.json({ records: [saved] });
  };
  const make = () => {
    const registry = new PublicRecordRegistry(storage, { clock }), authentication = new AuthenticationState(storage, { clock, renewalProofs });
    const client = new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-public-v1", privateKeyPEM: p.privateKeyPEM, clock, fetchImplementation: provider, isEnabled: () => true });
    const repository = new CloudKitPublicRepository({ registry, client, authentication, checkpoint: new PublicRegistryCheckpoint({ registry, client }), clock });
    return { registry, client, repository, checkpoint: new PublicRegistryCheckpoint({ registry, client }) };
  };
  const initial = make(), options = requestID => ({ accessToken: p.accessToken, requestID, authorizeMutation: () => true });
  const known = await initial.repository.cancelAvatarReport(options(p.knownRequestID));
  let uncertain = false; try { await initial.repository.cancelAvatarReport(options(p.unknownRequestID)); } catch { uncertain = true; }
  const beforeRecovery = reportMutations, fresh = make();
  const recovery = await fresh.repository.recoverAvatarReport({ accessToken: p.accessToken, requestID: p.unknownRequestID, authorizeRead: () => true });
  const afterRecovery = reportMutations;
  const { recordChangeTag, ...original } = p.original;
  const delayed = (await fresh.client.modify([{ operationType: "create", record: original }])).get(original.recordName);
  await fresh.registry.beginAvatarReportCancellation(p.accountID, p.retentionRequestID);
  await fresh.checkpoint.advance();
  p.now += 30 * 86400000;
  const processor = new CloudKitPublicRetentionProcessor({ registry: fresh.registry, client: fresh.client, checkpoint: fresh.checkpoint, clock, isEnabled: () => true });
  const background = await processor.step(); await fresh.checkpoint.waitForPendingOperations(); await fresh.client.waitForPendingOperations();
  return Response.json({ known, uncertain, recovery, beforeRecovery, afterRecovery, delayedCode: delayed.serverErrorCode, background,
    remainingRetention: storage.sql.exec("SELECT COUNT(*) AS n FROM public_retention_v1").toArray()[0].n,
    records: p.allowedRecordNames.map(name => ({ recordName: name, fields: Object.keys(records.get(name).fields).sort(), erased: records.get(name).fields.erased.value })),
    rows: storage.sql.exec("SELECT phase,request_id,payload_hash,avatar_report_cancel_tag FROM public_records_v1 WHERE kind='avatarreport' ORDER BY record_name").toArray() });
}
