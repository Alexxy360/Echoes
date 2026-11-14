import { createHash } from "node:crypto";
import { base64URLBytes } from "./apple-public-keys.mjs";

export const deletionUUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function deletionTicketHash(deletionID, token) {
  if (typeof deletionID !== "string" || !deletionUUID.test(deletionID) || typeof token !== "string" ||
      token.length !== 80 || token.slice(0, 37) !== deletionID + "." || base64URLBytes(token.slice(37), 32).length !== 32) {
    throw new Error("Deletion ticket is invalid.");
  }
  return createHash("sha256").update("echoes/deletion-status/v1\0" + token).digest("hex");
}
export const deletionSchema = [
  `CREATE TABLE IF NOT EXISTS auth_account_deletions_v1 (
    deletion_id TEXT PRIMARY KEY,status_hash TEXT NOT NULL,account_id TEXT NOT NULL,subject_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,settle_after INTEGER NOT NULL,public_status TEXT NOT NULL DEFAULT 'pending',
    private_ack INTEGER NOT NULL DEFAULT 0,apple_status TEXT NOT NULL DEFAULT 'pending',local_status TEXT NOT NULL DEFAULT 'blocked',
    public_lease_id TEXT,public_lease_at INTEGER,public_attempts INTEGER NOT NULL DEFAULT 0,
    public_next_at INTEGER NOT NULL DEFAULT 0,tokens_processed INTEGER NOT NULL DEFAULT 0,completed_at INTEGER)`,
  `CREATE UNIQUE INDEX IF NOT EXISTS auth_deletion_active_account_v1 ON auth_account_deletions_v1(account_id)
    WHERE local_status='blocked'`,
  `CREATE INDEX IF NOT EXISTS auth_deletion_subject_v1 ON auth_account_deletions_v1(subject_hash,local_status)`,
  `CREATE INDEX IF NOT EXISTS auth_deletion_completed_v1 ON auth_account_deletions_v1(completed_at)`,
  `CREATE TABLE IF NOT EXISTS auth_subject_fences_v1 (subject_hash TEXT PRIMARY KEY,not_before INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS auth_deletion_revocations_v1 (
    credential_id TEXT PRIMARY KEY,deletion_id TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,lease_id TEXT,lease_at INTEGER,next_at INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS auth_deletion_revoke_job_v1 ON auth_deletion_revocations_v1(deletion_id,state,next_at)`,
  `CREATE INDEX IF NOT EXISTS auth_deletion_revoke_lease_v1 ON auth_deletion_revocations_v1(lease_id)`,
];
