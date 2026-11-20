import { randomBytes, randomUUID, createPublicKey, createHash, verify } from "node:crypto";
import { Buffer } from "node:buffer";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint, checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { AvatarReportReviewState } from "../../src/avatar-report-review-state.mjs";
import { AvatarReportReviewCoordinator } from "../../src/avatar-report-review-coordinator.mjs";
import { digest } from "../../src/public-record-schema.mjs";

// Explicit local model with outbound denied by workerd harness. Not an Apple/Cloudflare deployment.
export async function avatarReportReviewWorkerdProof(request, storage) {
  const bytes = new Uint8Array(await request.arrayBuffer()); if (bytes.length > 1048576) throw Error("Fixture too large");
  const p = JSON.parse(new TextDecoder().decode(bytes));
  if (p.synthetic !== "echoes-owned-photo-report-review-v1" || !Number.isSafeInteger(p.now)) throw Error("Synthetic fixture required");
  const clock = () => p.now, proofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
  new AuthenticationState(storage, { clock, renewalProofs: proofs }); new CommunityState(storage, { clock }); new PublicRecordRegistry(storage, { clock });
  new AvatarReportReviewState(storage, { clock });
  const allowed = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(r => r.name)); let restored = 0;
  storage.transactionSync(() => {
    for (const table of p.tables) {
      if (!allowed.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || (restored += table.rows.length) > 10000) throw Error("Unexpected synthetic table");
      const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(x => x.name));
      storage.sql.exec(`DELETE FROM ${table.name}`);
      for (const row of table.rows) {
        const keys = Object.keys(row); if (keys.some(k => !columns.has(k) || !/^[a-z0-9_]+$/.test(k))) throw Error("Unexpected synthetic column");
        storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(k => row[k]));
      }
    }
  }); await storage.sync();
  const records = new Map(p.records.map(r => [r.recordName, r])), key = createPublicKey(p.privateKeyPEM), assets = new Map(p.assets.map(([name, value]) => [name, new Uint8Array(Buffer.from(value, "base64"))]));
  let signatures = 0, downloads = 0, sequence = 0, role = true;
  const provider = async request => {
    const url = new URL(request.url), raw = await request.text(), body = JSON.parse(raw), hash = createHash("sha256").update(raw).digest("base64");
    if (url.origin !== "https://api.apple-cloudkit.com" || request.method !== "POST" || request.redirect !== "manual" ||
        !verify("sha256", Buffer.from(`${request.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${hash}:${url.pathname}`), key,
          Buffer.from(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw Error("Synthetic signature mismatch");
    signatures++;
    if (url.pathname.endsWith("/records/lookup")) return Response.json({ records: body.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) });
    if (!url.pathname.endsWith("/records/modify") || body.operations.length !== 1) throw Error("Unexpected synthetic provider operation");
    const operation = body.operations[0], old = records.get(checkpointRecordName);
    if (operation.record.recordName !== checkpointRecordName || operation.operationType !== "replace" || operation.record.recordChangeTag !== old.recordChangeTag) throw Error("Only exact checkpoint replacement permitted");
    const record = { ...operation.record, recordChangeTag: "photo-report-review-checkpoint-" + ++sequence }; records.set(record.recordName, record);
    return Response.json({ records: [record] });
  };
  const authentication = new AuthenticationState(storage, { clock, renewalProofs: proofs }), communityState = new CommunityState(storage, { clock });
  const registry = new PublicRecordRegistry(storage, { clock }), avatarPolicy = new AvatarPolicyState(storage, { registry, clock });
  const client = new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-public-v1", privateKeyPEM: p.privateKeyPEM,
    fetchImplementation: provider, isEnabled: () => true, clock });
  const checkpoint = new PublicRegistryCheckpoint({ registry, client }), repository = new CloudKitPublicRepository({ registry, client, checkpoint, authentication, clock });
  const configuration = { authentication, communityState, avatarPolicy, registry, repository, client, checkpoint, clock,
    isEnabled: () => true, isOperator: id => role && id === p.operatorID, verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"],
    fetchImplementation: async request => {
      const url = new URL(request.url), image = assets.get(url.pathname.slice("/private/".length));
      if (url.hostname !== "synthetic-avatar.icloud-content.com" || request.method !== "GET" || request.redirect !== "manual" || request.credentials !== undefined && request.credentials !== "omit" || [...request.headers.keys()].sort().join() !== "accept,cache-control" || !image) throw Error("Unexpected synthetic asset request");
      downloads++; return new Response(image.slice(), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(image.length) } });
    } };
  let coordinator = new AvatarReportReviewCoordinator({ ...configuration, reviews: new AvatarReportReviewState(storage, { clock }) });
  const options = body => ({ accessToken: p.operatorToken, ...body }); let ordinaryDenied = false, revoked = false;
  try { await coordinator.prepareQueue({ accessToken: p.foreignToken }); } catch (e) { ordinaryDenied = e.code === "AVATAR_REPORT_REVIEW_SCOPE"; }
  const finalQueue = await coordinator.prepareQueue(options({})); role = false;
  try { finalQueue(); } catch (e) { revoked = e.code === "AVATAR_REPORT_REVIEW_SCOPE"; } role = true;
  const queue = (await coordinator.prepareQueue(options({})))();
  const inspection = (await coordinator.prepareInspection(options({ reportID: p.reportID })))();
  const exactImage = digest(inspection.image) === p.imageSHA256 && inspection.metadata.reason === p.reason && inspection.metadata.photo.versionID === p.versionID;
  inspection.image.fill(0);
  const input = { inspectionID: inspection.metadata.inspectionID, decisionID: randomUUID(), verdict: "hide_photo" };
  const first = (await coordinator.prepareDecision(options(input)))(); // Simulate dropping this reply after durable work.
  const exactReplay = JSON.stringify((await coordinator.prepareDecision(options(input)))()) === JSON.stringify(first);
  coordinator = new AvatarReportReviewCoordinator({ ...configuration, reviews: new AvatarReportReviewState(storage, { clock }) });
  p.now += 90001;
  const recovered = (await coordinator.prepareRecovery(options({ reportID: p.reportID, decisionID: input.decisionID, verdict: input.verdict, contentHash: inspection.metadata.contentHash })))();
  const remaining = (await coordinator.prepareQueue(options({})))(), current = avatarPolicy.snapshot(p.authorID);
  return Response.json({ ordinaryDenied, revoked, queued: queue.items.length, exactImage, exactReplay, rejected: current.status === "rejected",
    confirmedAfterRecreationAndExpiry: recovered.outcome === "confirmed" && recovered.revision === first.revision,
    closedQueue: remaining.items.length === 0, downloads, signatures, actualSQL: storage.sql.exec("SELECT COUNT(*) AS n FROM avatar_report_decisions_v1").toArray()[0].n === 1 });
}
