import { DurableObject } from "cloudflare:workers";
import { randomBytes, randomUUID, createHash, createPublicKey, verify } from "node:crypto";
import { Buffer } from "node:buffer";
import { AuthenticationState } from "../../src/authentication-state.mjs";
import { AccountDeletionState } from "../../src/account-deletion-state.mjs";
import { RenewalProofs } from "../../src/renewal-proofs.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { checkpointRecordName } from "../../src/public-registry-checkpoint.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { CommunityReportReviewState } from "../../src/community-report-review-state.mjs";
import { GatewayLimits } from "../../src/gateway-limits.mjs";
import { GatewayMaintenance } from "../../src/gateway-maintenance.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";

/** Test-only loopback entry; outbound network is denied. Platform identity and Apple/accounts are synthetic. */
export class ReportProofAuthority extends DurableObject {
  async alarm() { await this.ctx.storage.deleteAlarm(); }
  async fetch(request) {
    try {
      if (request.method !== "POST" || new URL(request.url).pathname !== "/report-proof") return new Response(null, { status: 404 });
      const bytes = new Uint8Array(await request.arrayBuffer()); if (bytes.byteLength > 524288) throw new Error();
      const p = JSON.parse(new TextDecoder().decode(bytes));
      if (p.synthetic !== "echoes-owned-report-http-proof-v1" || !Number.isSafeInteger(p.now) || !Array.isArray(p.tables) || !Array.isArray(p.records)) throw new Error();
      const storage = this.ctx.storage, clock = () => p.now, secret = () => randomBytes(32).toString("base64url");
      new AuthenticationState(storage, { clock, renewalProofs: new RenewalProofs({ activeKeyID: "synthetic", keys: { synthetic: secret() } }) });
      new PublicRecordRegistry(storage, { clock }); new CommunityState(storage, { clock }); new CommunityReportReviewState(storage, { clock });
      const deletions = new AccountDeletionState(storage, { clock }), limits = new GatewayLimits(storage, { clock });
      new GatewayMaintenance(storage, { clock, limits, deletions });
      const allowed = new Set(storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").toArray().map(row => row.name));
      let count = 0;
      storage.transactionSync(() => {
        for (const table of p.tables) {
          if (!allowed.has(table.name) || !/^[a-z0-9_]+$/.test(table.name) || !Array.isArray(table.rows) || (count += table.rows.length) > 10000) throw new Error();
          const columns = new Set(storage.sql.exec(`PRAGMA table_info(${table.name})`).toArray().map(row => row.name));
          storage.sql.exec(`DELETE FROM ${table.name}`);
          for (const row of table.rows) {
            const keys = Object.keys(row); if (!keys.length || keys.some(key => !columns.has(key) || !/^[a-z0-9_]+$/.test(key))) throw new Error();
            storage.sql.exec(`INSERT INTO ${table.name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(key => row[key]));
          }
        }
      });
      await storage.sync();
      const records = new Map(p.records.map(record => [record.recordName, record]));
      const known = new Set(storage.sql.exec("SELECT record_name FROM public_records_v1").toArray().map(row => row.record_name)); known.add(checkpointRecordName);
      let signatures = 0, sequence = 0;
      const publicKey = createPublicKey(p.privateKeyPEM);
      const provider = async req => {
        const url = new URL(req.url), raw = await req.text(), input = JSON.parse(raw);
        if (url.origin !== "https://api.apple-cloudkit.com" || req.method !== "POST" || req.redirect !== "manual" ||
            !/^\/database\/1\/iCloud\.mpvEcho\.Echo\/development\/public\/records\/(lookup|modify)$/.test(url.pathname) ||
            !verify("sha256", Buffer.from(`${req.headers.get("X-Apple-CloudKit-Request-ISO8601Date")}:${createHash("sha256").update(raw).digest("base64")}:${url.pathname}`),
              publicKey, Buffer.from(req.headers.get("X-Apple-CloudKit-Request-SignatureV1"), "base64"))) throw new Error();
        signatures++;
        if (url.pathname.endsWith("/lookup")) {
          if (!input.records.length || input.records.length > 25 || input.records.some(row => !known.has(row.recordName))) throw new Error();
          return Response.json({ records: input.records.map(({ recordName }) => structuredClone(records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) });
        }
        if (input.atomic !== false || input.operations.length !== 1 || input.operations[0].record.recordName !== checkpointRecordName) throw new Error();
        return Response.json({ records: input.operations.map(({ operationType, record }) => {
          const old = records.get(record.recordName);
          if (operationType !== "replace" || !old || old.recordChangeTag !== record.recordChangeTag) return { recordName: record.recordName, serverErrorCode: "CONFLICT" };
          const saved = { ...record, recordChangeTag: "report-workerd-" + ++sequence }; records.set(record.recordName, saved); return saved;
        }) });
      };
      const env = { GATEWAY_ENABLED: "1", GATEWAY_ENVIRONMENT: "development", GATEWAY_EXPIRES_AT: new Date(p.now + 3600000).toISOString(),
        ACCOUNT_DELETION_ENABLED: "1", PUBLIC_RECORDS_ENABLED: "1", COMMUNITY_ENABLED: "1", REPORT_REVIEW_ENABLED: "1", REPORT_REVIEWER_IDS_JSON: JSON.stringify([p.operatorID]),
        CLOUDKIT_CONTAINER: "iCloud.mpvEcho.Echo", CLOUDKIT_ENVIRONMENT: "development", CLOUDKIT_KEY_ID: "synthetic-public-v1", CLOUDKIT_PRIVATE_KEY: p.privateKeyPEM,
        APPLE_SIGNIN_KEY_ID: "TESTKEY123", APPLE_SIGNIN_PRIVATE_KEY: p.signInPrivateKeyPEM, REQUEST_BUDGET_KEY: secret(), REFRESH_ACTIVE_KEY_ID: "v1", RENEWAL_ACTIVE_KEY_ID: "v1",
        REFRESH_KEYS_JSON: JSON.stringify({ v1: secret() }), RENEWAL_KEYS_JSON: JSON.stringify({ v1: secret() }) };
      let runtime = createGatewayRuntime(storage, env, { clock, fetchImplementation: provider });
      const objectID = this.ctx.id;
      env.COMMUNITY_AUTHORITY = { idFromName(name) { if (name !== authorityName) throw new Error(); return objectID; },
        get() { return { fetch: req => handleAuthorityRequest(req, { runtime, env, objectID, clock }) }; } };
      const call = async (action, body, token = p.token) => {
        const req = new Request("https://synthetic-reports.invalid/v1/moderation/reports/" + action, { method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer " + token, "CF-Connecting-IP": "192.0.2.17" }, body: JSON.stringify(body) });
        Object.defineProperty(req, "cf", { value: { colo: "WAW" } });
        const response = await forwardGatewayRequest(req, env, { clock }); return { status: response.status, body: await response.json(), headers: response.headers };
      };
      const queue = await call("queue", { after: null }); if (queue.status !== 200 || queue.body.items[0]?.reportID !== p.reportID) throw new Error("queue");
      const inspection = await call("inspect", { reportID: p.reportID }); if (inspection.status !== 200 || !inspection.body.message) throw new Error("inspect");
      const intent = { inspectionID: inspection.body.inspectionID, decisionID: randomUUID(), verdict: "hide_message" };
      const result = await call("decide", intent); if (result.status !== 200) throw new Error("decide");
      runtime = createGatewayRuntime(storage, env, { clock, fetchImplementation: provider }); // Fresh Runtime, same actual DO SQLite.
      const recovered = await call("recover", { reportID: p.reportID, decisionID: intent.decisionID, verdict: intent.verdict, contentHash: inspection.body.contentHash });
      const hidden = storage.sql.exec("SELECT hidden FROM community_intents_v1 WHERE account_id=? AND kind='message'", p.authorID).toArray()[0]?.hidden === 1;
      const closed = await call("queue", { after: null }), denied = await call("queue", { after: null }, p.authorToken);
      env.REPORT_REVIEW_ENABLED = "0"; const disabled = await call("queue", { after: null });
      const privateSQL = JSON.stringify(storage.sql.exec("SELECT * FROM community_report_inspections_v1").toArray()) + JSON.stringify(storage.sql.exec("SELECT * FROM community_report_decisions_v1").toArray());
      const noContentsInSQL = !privateSQL.includes(inspection.body.reason) && !privateSQL.includes(inspection.body.message.text) && !privateSQL.includes(p.token);
      await storage.deleteAlarm(); await storage.sync();
      return Response.json({ actualSQL: true, hidden, closed: closed.status === 200 && closed.body.items.length === 0,
        confirmedAfterNewRuntime: recovered.status === 200 && recovered.body.outcome === "confirmed" && recovered.body.revision === result.body.revision,
        ordinaryDenied: denied.status === 403, disabled: disabled.status === 503, noContentsInSQL,
        privateNoStore: inspection.headers.get("Cache-Control") === "no-store", signatures });
    } catch { return Response.json({ error: "SYNTHETIC_REPORT_PROOF_FAILED" }, { status: 400 }); }
  }
}
export default { fetch(request, env) { return env.REPORTS.get(env.REPORTS.idFromName("synthetic-report-only")).fetch(request); } };
