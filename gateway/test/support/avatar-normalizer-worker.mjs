import { DurableObject } from "cloudflare:workers";
import { normalizedAvatarManifest } from "../../src/avatar-normalizer.mjs";
import { createWorkerAvatarNormalizer } from "../../src/avatar-codecs-workerd.mjs";
import { AvatarReceiptVault } from "../../src/avatar-receipt-vault.mjs";
import { recordIdentity, digest } from "../../src/public-record-schema.mjs";
import { randomBytes } from "node:crypto";

// Local integration harness only. No gateway secrets, publication, Apple fetch or user identity.
export class AvatarCodecTestAuthority extends DurableObject {
  #normalizer = createWorkerAvatarNormalizer(() => true);
  async fetch(request) {
    try {
      if (request.method !== "POST") return new Response(null, { status: 405 });
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
