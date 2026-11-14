import { randomUUID, timingSafeEqual } from "node:crypto";
import { Buffer } from "node:buffer";
import { AuthenticationStateError } from "./authentication-state.mjs";
import { deletionSchema, deletionTicketHash, deletionUUID } from "./deletion-schema.mjs";

const leaseLifetime = 60000, revocationDeadline = 7 * 86400000, receiptLifetime = 30 * 86400000;
const unavailable = () => new AuthenticationStateError("DELETION_UNAVAILABLE");

/** Same trusted SQLite authority as authentication. Only ticket status/ack are client-facing capabilities. */
export class AccountDeletionState {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw unavailable();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => { for (const statement of deletionSchema) storage.sql.exec(statement); });
  }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch { throw unavailable(); } }
  #rows(sql, ...values) { return this.#storage.sql.exec(sql, ...values).toArray(); }
  #id(value) { if (typeof value !== "string" || !deletionUUID.test(value)) throw unavailable(); }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw unavailable(); return now; }
  async #durable() { try { await this.#storage.sync(); } catch { throw unavailable(); } }
  #job(id) { this.#id(id); const job = this.#rows("SELECT * FROM auth_account_deletions_v1 WHERE deletion_id=?", id)[0]; if (!job) throw unavailable(); return job; }
  #ticket({ deletionID, statusToken } = {}) {
    let hash;
    try { hash = deletionTicketHash(deletionID, statusToken); } catch { throw unavailable(); }
    const row = this.#rows("SELECT * FROM auth_account_deletions_v1 WHERE deletion_id=?", deletionID)[0];
    if (row && !timingSafeEqual(Buffer.from(row.status_hash, "hex"), Buffer.from(hash, "hex"))) throw unavailable();
    return row;
  }
  #status(row) {
    return Object.freeze({ deletionID: row.deletion_id, publicData: row.public_status,
      privateData: row.private_ack ? "device-acknowledged" : "awaiting-device",
      appleAuthorization: row.apple_status, localAccount: row.local_status,
      attentionRequired: row.public_attempts >= 10 && row.public_status !== "deleted",
      completed: row.local_status === "removed" });
  }
  lookupStatus(ticket) { return this.#tx(() => { const row = this.#ticket(ticket); return row ? this.#status(row) : undefined; }); }
  status(ticket) { const status = this.lookupStatus(ticket); if (!status) throw unavailable(); return status; }
  async acknowledgePrivateCleanup(ticket) {
    this.#tx(() => {
      const row = this.#ticket(ticket); if (!row) throw unavailable();
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET private_ack=1 WHERE deletion_id=?", row.deletion_id);
    });
    await this.#durable(); return this.status(ticket);
  }

  /** Internal alarm/operator queue only, never a dispatch accepting arbitrary HTTP method names. */
  dueDeletionIDs() {
    const now = this.#now();
    return this.#tx(() => this.#rows(`SELECT deletion_id FROM auth_account_deletions_v1 WHERE local_status='blocked'
      AND ((public_status!='deleted' AND public_attempts<10 AND public_next_at<=?
        AND (public_lease_id IS NULL OR public_lease_at<=?)) OR apple_status='pending'
        OR (public_status='deleted' AND private_ack=1)) ORDER BY created_at LIMIT 10`, now, now - leaseLifetime)
      .map(row => row.deletion_id));
  }
  async claimPublicBatch(deletionID) {
    const now = this.#now(), leaseID = randomUUID();
    const context = this.#tx(() => {
      const job = this.#job(deletionID);
      if (job.local_status === "removed" || job.public_status === "deleted" || job.public_attempts >= 10 ||
          job.public_next_at > now || (job.public_lease_id && job.public_lease_at + leaseLifetime > now)) return;
      this.#storage.sql.exec(`UPDATE auth_account_deletions_v1 SET public_lease_id=?,public_lease_at=?,
        public_attempts=public_attempts+1 WHERE deletion_id=?`, leaseID, now, deletionID);
      return Object.freeze({ deletionID, leaseID, accountID: job.account_id });
    });
    if (context) await this.#durable(); return context;
  }
  async completePublicBatch(context, receipt) {
    const now = this.#now();
    this.#tx(() => {
      this.#id(context?.leaseID); const job = this.#job(context?.deletionID);
      if (job.public_lease_id !== context.leaseID || job.public_lease_at + leaseLifetime <= now ||
          context.accountID !== job.account_id || receipt?.accountID !== job.account_id ||
          receipt.deletionID !== job.deletion_id || typeof receipt.remaining !== "boolean") throw unavailable();
      const publicStatus = receipt.remaining ? "pending" : now < job.settle_after ? "draining" : "deleted";
      this.#storage.sql.exec(`UPDATE auth_account_deletions_v1 SET public_status=?,public_lease_id=NULL,public_lease_at=NULL,
        public_attempts=0,public_next_at=? WHERE deletion_id=?`, publicStatus,
      receipt.remaining ? now + 1000 : publicStatus === "draining" ? job.settle_after : now, job.deletion_id);
    });
    await this.#durable();
  }
  async failPublicBatch(leaseID) {
    this.#id(leaseID); const now = this.#now();
    this.#tx(() => {
      const job = this.#rows("SELECT * FROM auth_account_deletions_v1 WHERE public_lease_id=?", leaseID)[0];
      if (job) this.#storage.sql.exec(`UPDATE auth_account_deletions_v1 SET public_lease_id=NULL,public_lease_at=NULL,
        public_next_at=? WHERE deletion_id=?`, now + Math.min(3600000, 60000 * 2 ** (job.public_attempts - 1)), job.deletion_id);
    });
    await this.#durable();
  }
  async resumePublicDeletion(deletionID) {
    // Trusted operator recovery after investigating an exhausted data adapter; not a client status action.
    this.#tx(() => { const job = this.#job(deletionID);
      if (job.local_status === "removed") throw unavailable();
      this.#storage.sql.exec(`UPDATE auth_account_deletions_v1 SET public_attempts=0,public_next_at=0,
        public_lease_id=NULL,public_lease_at=NULL WHERE deletion_id=?`, deletionID);
    });
    await this.#durable();
  }

  #liveReservations(subjectHash, now) {
    return this.#rows("SELECT count(*) AS count FROM auth_credential_reservations_v1 WHERE subject_hash=? AND expires_at>?", subjectHash, now)[0].count;
  }
  #reconcileApple(job, now) {
    if (job.apple_status !== "pending") return;
    const credentials = this.#rows("SELECT count(*) AS count FROM auth_refresh_credentials_v1 WHERE subject_hash=?", job.subject_hash)[0].count;
    const unsettled = this.#liveReservations(job.subject_hash, now) > 0 || now < job.settle_after;
    if (now - job.created_at >= revocationDeadline) {
      this.#storage.sql.exec("DELETE FROM auth_refresh_credentials_v1 WHERE subject_hash=?", job.subject_hash);
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET apple_status='manual-required' WHERE deletion_id=?", job.deletion_id);
    } else if (!credentials && !unsettled) {
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET apple_status=? WHERE deletion_id=?",
        job.tokens_processed ? "retained-tokens-processed" : "manual-required", job.deletion_id);
    } else if (credentials && !unsettled && !this.#rows(`SELECT c.credential_id FROM auth_refresh_credentials_v1 c
      LEFT JOIN auth_deletion_revocations_v1 r ON r.credential_id=c.credential_id
      WHERE c.subject_hash=? AND (r.credential_id IS NULL OR r.state!='manual') LIMIT 1`, job.subject_hash).length) {
      this.#storage.sql.exec("DELETE FROM auth_refresh_credentials_v1 WHERE subject_hash=?", job.subject_hash);
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET apple_status='manual-required' WHERE deletion_id=?", job.deletion_id);
    }
  }
  async claimRevocation(deletionID) {
    const now = this.#now(), leaseID = randomUUID();
    const context = this.#tx(() => {
      let job = this.#job(deletionID); if (job.local_status === "removed" || job.apple_status !== "pending") return;
      this.#storage.sql.exec(`INSERT OR IGNORE INTO auth_deletion_revocations_v1(credential_id,deletion_id)
        SELECT credential_id,? FROM auth_refresh_credentials_v1 WHERE subject_hash=? LIMIT 100`, deletionID, job.subject_hash);
      // A process crash can leave the fifth attempt leased without a failure callback.
      this.#storage.sql.exec(`UPDATE auth_deletion_revocations_v1 SET state='manual',lease_id=NULL,lease_at=NULL
        WHERE deletion_id=? AND attempts>=5 AND state='leased' AND lease_at<=?`, deletionID, now - leaseLifetime);
      this.#reconcileApple(job, now); job = this.#job(deletionID); if (job.apple_status !== "pending") return;
      const row = this.#rows(`SELECT r.*,c.subject_hash,c.sealed_credential FROM auth_deletion_revocations_v1 r
        JOIN auth_refresh_credentials_v1 c ON c.credential_id=r.credential_id WHERE r.deletion_id=?
        AND r.attempts<5 AND r.next_at<=? AND (r.state='pending' OR (r.state='leased' AND r.lease_at<=?))
        ORDER BY c.created_at LIMIT 1`, deletionID, now, now - leaseLifetime)[0];
      if (!row) return;
      this.#storage.sql.exec(`UPDATE auth_deletion_revocations_v1 SET state='leased',attempts=attempts+1,lease_id=?,lease_at=?
        WHERE credential_id=?`, leaseID, now, row.credential_id);
      return Object.freeze({ deletionID, leaseID, credentialID: row.credential_id, subjectHash: row.subject_hash,
        sealedCredential: row.sealed_credential });
    });
    await this.#durable(); return context;
  }
  async completeRevocation(context) {
    const now = this.#now();
    this.#tx(() => {
      this.#id(context?.leaseID); const job = this.#job(context?.deletionID);
      const task = this.#rows("SELECT * FROM auth_deletion_revocations_v1 WHERE lease_id=? AND state='leased'", context.leaseID)[0];
      if (!task || task.deletion_id !== job.deletion_id || task.credential_id !== context.credentialID || task.lease_at + leaseLifetime <= now) throw unavailable();
      this.#storage.sql.exec("DELETE FROM auth_refresh_credentials_v1 WHERE credential_id=? AND subject_hash=?", task.credential_id, job.subject_hash);
      this.#storage.sql.exec("UPDATE auth_deletion_revocations_v1 SET state='done',lease_id=NULL,lease_at=NULL WHERE credential_id=?", task.credential_id);
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET tokens_processed=tokens_processed+1 WHERE deletion_id=?", job.deletion_id);
    });
    await this.#durable();
  }
  async failRevocation(leaseID, { permanent = false } = {}) {
    this.#id(leaseID); const now = this.#now();
    this.#tx(() => {
      const task = this.#rows("SELECT * FROM auth_deletion_revocations_v1 WHERE lease_id=? AND state='leased'", leaseID)[0];
      if (!task) return;
      this.#storage.sql.exec(`UPDATE auth_deletion_revocations_v1 SET state=?,lease_id=NULL,lease_at=NULL,next_at=? WHERE credential_id=?`,
        permanent || task.attempts >= 5 ? "manual" : "pending", now + 60000 * 2 ** (task.attempts - 1), task.credential_id);
    });
    await this.#durable();
  }
  async finalize(deletionID) {
    const now = this.#now(); let finished = false;
    this.#tx(() => {
      let job = this.#job(deletionID); if (job.local_status === "removed") { finished = true; return; }
      this.#reconcileApple(job, now); job = this.#job(deletionID);
      if (job.public_status !== "deleted" || !job.private_ack || job.apple_status === "pending" ||
          now < job.settle_after || this.#liveReservations(job.subject_hash, now)) return;
      for (const table of ["auth_sessions_v1", "auth_renewal_grants_v1", "auth_apple_state_v1"]) {
        this.#storage.sql.exec(`DELETE FROM ${table} WHERE account_id=?`, job.account_id);
      }
      this.#storage.sql.exec("DELETE FROM auth_refresh_credentials_v1 WHERE subject_hash=?", job.subject_hash);
      this.#storage.sql.exec("DELETE FROM auth_credential_reservations_v1 WHERE subject_hash=?", job.subject_hash);
      this.#storage.sql.exec("DELETE FROM auth_accounts_v1 WHERE account_id=? AND subject_hash=?", job.account_id, job.subject_hash);
      this.#storage.sql.exec("DELETE FROM auth_deletion_revocations_v1 WHERE deletion_id=?", deletionID);
      this.#storage.sql.exec("UPDATE auth_account_deletions_v1 SET local_status='removed',completed_at=? WHERE deletion_id=?", now, deletionID);
      finished = true;
    });
    await this.#durable(); return finished;
  }
  async purgeCompletedReceipts() {
    const now = this.#now();
    this.#tx(() => {
      this.#storage.sql.exec(`DELETE FROM auth_account_deletions_v1 WHERE deletion_id IN
        (SELECT deletion_id FROM auth_account_deletions_v1 WHERE completed_at<=? LIMIT 100)`, now - receiptLifetime);
      this.#storage.sql.exec(`DELETE FROM auth_subject_fences_v1 WHERE subject_hash IN
        (SELECT f.subject_hash FROM auth_subject_fences_v1 f WHERE not_before<=? AND NOT EXISTS
          (SELECT 1 FROM auth_account_deletions_v1 d WHERE d.subject_hash=f.subject_hash AND d.local_status='blocked') LIMIT 100)`, now - receiptLifetime);
    });
    await this.#durable();
  }
}
