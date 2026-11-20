import { avatarReportReviewWorkerdProof } from "./avatar-report-review-workerd-proof.mjs";
import { DurableObject } from "cloudflare:workers";
import { normalizedAvatarManifest } from "../../src/avatar-normalizer.mjs";
import { createWorkerAvatarNormalizer } from "../../src/avatar-codecs-workerd.mjs";
import { AvatarReceiptVault } from "../../src/avatar-receipt-vault.mjs";
import { recordIdentity, digest } from "../../src/public-record-schema.mjs";
import { randomBytes } from "node:crypto";
import { CommunityState } from "../../src/community-state.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";
import { avatarReadWorkerdProof } from "./avatar-read-workerd-proof.mjs";
import { avatarReportCancellationWorkerdProof } from "./avatar-report-cancellation-workerd-proof.mjs";
import { avatarReportWorkerdProof } from "./avatar-report-workerd-proof.mjs";
import { avatarUploadWorkerdProof } from "./avatar-upload-workerd-proof.mjs";
import { createGatewayLocalMaintenance } from "../../src/gateway-runtime.mjs";

// Local integration harness only. No gateway secrets, publication, Apple fetch or user identity.
export class AvatarCodecTestAuthority extends DurableObject {
  #normalizer = createWorkerAvatarNormalizer(() => true);
  async #policyProof() {
    const accountID = "64000000-0000-4000-8000-000000000001";
    const sql = this.ctx.storage.sql;
    sql.exec("CREATE TABLE IF NOT EXISTS auth_accounts_v1(account_id TEXT PRIMARY KEY,generation INTEGER NOT NULL,disabled INTEGER NOT NULL)");
    sql.exec("INSERT OR REPLACE INTO auth_accounts_v1 VALUES(?,0,0)", accountID);
    const social = new CommunityState(this.ctx.storage);
    const registry = new PublicRecordRegistry(this.ctx.storage);
    const policy = new AvatarPolicyState(this.ctx.storage, { registry });
    const selection = await policy.select({ accountID, requestID: "64000000-0000-4000-8000-000000000003",
      versionID: "64000000-0000-4000-8000-000000000002", expectedGeneration: 0, sourceHash: digest("synthetic-policy-only"), consentVersion: 1 });
    await policy.clear({ accountID, requestID: "64000000-0000-4000-8000-000000000004", expectedGeneration: 1 });
    const clearHidden = policy.snapshot(accountID).publishedVersionID === null;
    sql.exec("UPDATE auth_accounts_v1 SET disabled=1 WHERE account_id=?", accountID);
    await social.eraseOwner(accountID);
    const erased = sql.exec("SELECT COUNT(*) AS n FROM avatar_jobs_v1").toArray()[0].n === 0 &&
      sql.exec("SELECT COUNT(*) AS n FROM avatar_profiles_v1").toArray()[0].n === 0;
    sql.exec("DELETE FROM auth_accounts_v1 WHERE account_id=?", accountID);
    return Response.json({ selectedGeneration: selection.generation, clearHidden, erased });
  }
  async alarm() {
    await createGatewayLocalMaintenance(this.ctx.storage).alarm();
  }
  async fetch(request) {
    try {
      if (request.method !== "POST") return new Response(null, { status: 405 });
      if (new URL(request.url).pathname === "/photo-report-review-proof") return await avatarReportReviewWorkerdProof(request, this.ctx.storage);
      if (new URL(request.url).pathname === "/photo-report-cancellation-proof") return await avatarReportCancellationWorkerdProof(request, this.ctx.storage);
      if (new URL(request.url).pathname === "/photo-report-proof") return await avatarReportWorkerdProof(request, this.ctx.storage);
      if (new URL(request.url).pathname === "/read-proof") return await avatarReadWorkerdProof(request, this.ctx.storage);
      if (new URL(request.url).pathname === "/http-proof") return await avatarReadWorkerdProof(request, this.ctx.storage, { http: true });
      if (new URL(request.url).pathname === "/upload-proof") return await avatarUploadWorkerdProof(request, this.ctx.storage);
      if (new URL(request.url).pathname === "/policy") return await this.#policyProof();
      // The fixture server is loopback-only; this is not the production binary intake endpoint.
      const bytes = new Uint8Array(await request.arrayBuffer());
      const result = await this.#normalizer.prepare({ bytes,
        versionID: "64000000-0000-4000-8000-000000000002", requestID: "64000000-0000-4000-8000-000000000003",
        authorize: () => ({ accountID: "64000000-0000-4000-8000-000000000001" }) });
      const sqlAvailable = this.ctx.storage.sql.exec("SELECT 1 AS value").toArray()[0]?.value === 1;
      const vault = new AvatarReceiptVault({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
      const lease = { context: { ...recordIdentity("64000000-0000-4000-8000-000000000001", "avatar", "64000000-0000-4000-8000-000000000002"),
        requestID: "64000000-0000-4000-8000-000000000003", payloadHash: digest("synthetic") },
      transferID: "64000000-0000-4000-8000-000000000004", variant: "image", byteCount: 16, sha256: digest("synthetic-bytes") };
      const envelope = vault.seal({ fileChecksum: "SYNTHETIC-FILE", size: 16, receipt: "SYNTHETIC-RECEIPT" }, lease);
      this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS synthetic_receipts(id TEXT PRIMARY KEY,envelope TEXT NOT NULL)");
      this.ctx.storage.sql.exec("INSERT OR REPLACE INTO synthetic_receipts VALUES('synthetic',?)", envelope);
      const stored = this.ctx.storage.sql.exec("SELECT envelope FROM synthetic_receipts WHERE id='synthetic'").toArray()[0].envelope;
      const receiptCryptoAvailable = vault.open(stored, lease).receipt === "SYNTHETIC-RECEIPT";
      this.ctx.storage.sql.exec("DELETE FROM synthetic_receipts WHERE id='synthetic'");
      return Response.json({ image: normalizedAvatarManifest(result, "image"), thumbnail: normalizedAvatarManifest(result, "thumbnail"), sqlAvailable, receiptCryptoAvailable },
        { headers: { "Cache-Control": "no-store" } });
    } catch (error) { return Response.json({ error: error.code ?? "UNAVAILABLE" }, { status: 400 }); }
  }
}
export default { fetch(request, env) { return env.CODEC.get(env.CODEC.idFromName("synthetic-only")).fetch(request); } };
