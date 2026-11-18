import { DurableObject } from "cloudflare:workers";
import { randomBytes, randomUUID, createHash, createPublicKey, verify } from "node:crypto";
import { Buffer } from "node:buffer";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { CloudKitPublicClient } from "../../src/cloudkit-public-client.mjs";
import { PublicRegistryCheckpoint, checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { CloudKitPublicRetentionProcessor } from "../../src/public-retention-processor.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { GatewayMaintenance } from "../../src/gateway-maintenance.mjs";
import { createGatewayRuntime } from "../../src/gateway-runtime.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";

/** Loopback-only proof. Outbound networking is denied by the harness; all provider data is synthetic. */
export class RetentionProofAuthority extends DurableObject {
  #runtime; #inspect; #deliveries = 0;
  async alarm() {
    this.#deliveries++;
    try {
      if (!this.#runtime || !this.#inspect) throw new Error("Missing synthetic alarm fixture");
      await this.#runtime.maintenance.alarm({ processor: this.#runtime.processor });
      await new Promise(resolve => setTimeout(resolve, 0));
      await this.ctx.storage.put("maintenance-proof-result", { ...await this.#inspect(), deliveries: this.#deliveries });
    } catch { await this.ctx.storage.put("maintenance-proof-result", { error: "SYNTHETIC_ALARM_FAILED", deliveries: this.#deliveries }); }
  }
  async fetch(request) {
    try {
      const path = new URL(request.url).pathname;
      if (request.method === "GET" && path === "/maintenance-status") return Response.json(await this.ctx.storage.get("maintenance-proof-result") ?? { pending: true });
      if (request.method !== "POST" || !["/retention-proof", "/maintenance-start"].includes(path)) return new Response(null, { status: 404 });
      const bytes = new Uint8Array(await request.arrayBuffer());
      if (bytes.length > 524288) throw new Error("Synthetic input limit");
      const p = JSON.parse(new TextDecoder().decode(bytes));
      if (p.synthetic !== "echoes-owned-local-retention-proof-v1" || !Number.isSafeInteger(p.now) ||
          !Array.isArray(p.tables) || !Array.isArray(p.records) || !Array.isArray(p.expiredNames) || p.expiredNames.length !== 3) throw new Error("Synthetic fixture required");
      const storage = this.ctx.storage, clock = () => p.now;
      const proofs = new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: randomBytes(32).toString("base64url") } });
      new AuthenticationState(storage, { clock, renewalProofs: proofs });
      const deletions = new AccountDeletionState(storage, { clock });
      const initialRegistry = new PublicRecordRegistry(storage, { clock });
      new CommunityState(storage, { clock }); new AvatarPolicyState(storage, { registry: initialRegistry, clock });
      const limits = new GatewayLimits(storage, { clock }); new GatewayMaintenance(storage, { clock, limits, deletions });
      const allowed = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(r => r.name));
      let rowCount = 0;
      storage.transactionSync(() => {
        for (const table of p.tables) {
          if (!allowed.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || !Array.isArray(table.rows) || (rowCount += table.rows.length) > 10000) throw new Error("Synthetic table limit");
          const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(r => r.name));
          storage.sql.exec(`DELETE FROM ${table.name}`);
          for (const row of table.rows) {
            const keys = Object.keys(row);
            if (keys.some(k => !columns.has(k) || !/^[a-z0-9_]+$/.test(k))) throw new Error("Synthetic column limit");
            storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(k => row[k]));
          }
        }
      });
      await storage.sync();
      const registry = new PublicRecordRegistry(storage, { clock });
      const authentication = new AuthenticationState(storage, { clock, renewalProofs: proofs });
      const records = new Map(p.records.map(r => [r.recordName, r]));
      const known = new Set(storage.sql.exec("SELECT record_name FROM public_records_v1").toArray().map(r => r.record_name));
      known.add(checkpointRecordName);
      let sequence = 0, signatures = 0, metadataOnly = 0;
      const key = createPublicKey(p.privateKeyPEM);
      const provider = async req => {
        const url = new URL(req.url), raw = await req.text(), body = JSON.parse(raw);
        if (url.origin !== "https://api.apple-cloudkit.com" || req.method !== "POST" || req.redirect !== "manual" ||
            !/^\/database\/1\/iCloud\.mpvEcho\.Echo\/development\/public\/records\/(lookup|modify)$/.test(url.pathname) ||
            !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${createHash("sha256").update(raw).digest("base64")}:${url.pathname}`),
              key, Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw new Error("Synthetic signature scope");
        signatures++;
        if (url.pathname.endsWith("/lookup")) {
          if (body.records.some(r => !known.has(r.recordName))) throw new Error("Unknown synthetic lookup");
          if (body.desiredKeys) {
            if (body.desiredKeys.join() !== "schemaVersion,ownerKey,erased,deletionKey,retentionKey") throw new Error("Synthetic metadata inventory");
            metadataOnly++;
          }
          return Response.json({ records: body.records.map(({ recordName }) => {
            const record = structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" });
            if (record.fields && body.desiredKeys) record.fields = Object.fromEntries(Object.entries(record.fields).filter(([k]) => body.desiredKeys.includes(k)));
            return record;
          }).reverse() });
        }
        if (body.atomic !== false || body.operations.length < 1 || body.operations.length > 25) throw new Error("Synthetic batch limit");
        return Response.json({ records: body.operations.map(op => {
          const record = op.record, old = records.get(record.recordName);
          if (!known.has(record.recordName) || !["create", "replace"].includes(op.operationType)) throw new Error("Synthetic modify scope");
          if (op.operationType === "create" && old) return { recordName: record.recordName, serverErrorCode: "EXISTS" };
          if (op.operationType === "replace" && (!old || old.recordChangeTag !== record.recordChangeTag)) return { recordName: record.recordName, serverErrorCode: "CONFLICT" };
          const result = { recordName: record.recordName, recordType: record.recordType,
            recordChangeTag: "workerd-retention-" + ++sequence, fields: structuredClone(record.fields) };
          records.set(record.recordName, result); return structuredClone(result);
        }).reverse() });
      };
      if (path === "/maintenance-start") {
        // Actual native workerd alarm delivery. The synthetic provider closure remains in this instance;
        // this proves alarm/Runtime composition, not eviction recovery or hosted Cloudflare acceptance.
        this.#runtime = createGatewayRuntime(storage, p.env, { clock, fetchImplementation: provider });
        this.#inspect = async () => ({
          emptyFences: p.expiredNames.every(name => {
            const record = records.get(name);
            return record?.fields.erased.value === 1 && Object.keys(record.fields).sort().join() === "erased,ownerKey,retentionKey,schemaVersion";
          }),
          erased: storage.sql.exec("SELECT count(*) n FROM public_records_v1 WHERE phase='erased'").toArray()[0].n,
          profilePreserved: records.get(p.profileName)?.fields.name?.value === "Trwały profil",
          budget: storage.sql.exec("SELECT total,deletion,retention FROM maintenance_daily_v1").toArray(),
          nextAlarm: await storage.getAlarm(), signatures, metadataOnly,
        });
        await storage.delete("maintenance-proof-result");
        await this.#runtime.maintenance.schedule();
        await storage.setAlarm(Date.now() + 25); // Test-only acceleration of the first delivery, no manual alarm call.
        await storage.sync();
        return Response.json({ scheduled: true }, { status: 202 });
      }
      const client = new CloudKitPublicClient({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: "synthetic-public-v1",
        privateKeyPEM: p.privateKeyPEM, fetchImplementation: provider, isEnabled: () => true, clock });
      const checkpoint = new PublicRegistryCheckpoint({ registry, client });
      const processor = new CloudKitPublicRetentionProcessor({ registry, client, checkpoint, clock, isEnabled: () => true });
      const result = await processor.step();
      const emptyFences = p.expiredNames.every(name => {
        const r = records.get(name);
        return r?.fields.erased.value === 1 && Object.keys(r.fields).sort().join() === "erased,ownerKey,retentionKey,schemaVersion";
      });
      const erased = storage.sql.exec("SELECT count(*) n FROM public_records_v1 WHERE phase='erased'").toArray()[0].n;
      const repository = new CloudKitPublicRepository({ registry, client, checkpoint, authentication, clock });
      let retryCode;
      try {
        await repository.writeLatest({ accessToken: p.sessionToken, kind: "presence", logicalID: "singleton", requestID: p.oldPresenceRequestID,
          input: { ...p.presenceInput, measuredAt: p.now }, authorizeMutation() {} });
      } catch (error) { retryCode = error.code; }
      const restored = await repository.writeLatest({ accessToken: p.sessionToken, kind: "presence", logicalID: "singleton", requestID: randomUUID(),
        input: { ...p.presenceInput, name: "Syntetyczna nowa obecność", measuredAt: p.now }, authorizeMutation() {} });
      await checkpoint.waitForPendingOperations(); await client.waitForPendingOperations();
      await new Promise(resolve => setTimeout(resolve, 0));
      return Response.json({ processed: result.processed, emptyFences, erased, retryCode, metadataOnly, signatures,
        presenceRestored: restored.fields.erased.value === 0 && registry.readable(restored.recordName, "presence") !== null,
        profilePreserved: records.get(p.profileName)?.fields.name?.value === "Trwały profil",
        avatarTransfersRemaining: p.retiredAvatarName ? storage.sql.exec("SELECT count(*) n FROM avatar_asset_transfers_v1 WHERE record_name=?", p.retiredAvatarName).toArray()[0].n : null,
        currentAvatarPreserved: p.currentAvatarName ? records.get(p.currentAvatarName)?.fields.image?.type === "ASSET" &&
          records.get(p.currentAvatarName)?.fields.thumbnail?.type === "ASSET" && registry.readable(p.currentAvatarName, "avatar") !== null : null,
        expiredSelectionRetained: p.expiredAvatarAccountID ? new AvatarPolicyState(storage, { registry, clock }).snapshot(p.expiredAvatarAccountID).status === "expired" : null,
        occupiedAfterDrain: processor.isOccupied }, { headers: { "Cache-Control": "no-store" } });
    } catch (error) { return Response.json({ error: error.code ?? "SYNTHETIC_PROOF_FAILED" }, { status: 400 }); }
  }
}
export default { fetch(request, env) { return env.RETENTION.get(env.RETENTION.idFromName("synthetic-retention-only")).fetch(request); } };
