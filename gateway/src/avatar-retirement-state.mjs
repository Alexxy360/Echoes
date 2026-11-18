import { PublicRecordError, publicUUID, recordIdentity } from "./public-record-schema.mjs";
import { avatarSelectionDeadline, currentAvatarSelection, expireAvatarSelections, purgeAvatarJobsWithoutRecords } from "./avatar-selection-expiry.mjs";

export const avatarRetirementGraceMilliseconds = 86400000;
export const avatarRetirementSchema = Object.freeze([
  `CREATE TABLE IF NOT EXISTS avatar_retirements_v1(record_name TEXT PRIMARY KEY,account_id TEXT NOT NULL,
    request_id TEXT NOT NULL,version_id TEXT NOT NULL,retired_at INTEGER NOT NULL CHECK(retired_at>=0))`,
  `CREATE INDEX IF NOT EXISTS avatar_retirement_owner_v1 ON avatar_retirements_v1(account_id,request_id)`,
]);
const rows = (storage, sql, ...args) => storage.sql.exec(sql, ...args).toArray();
const unavailable = () => new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
const validTime = time => Number.isSafeInteger(time) && time >= 0 && Number.isSafeInteger(time + avatarRetirementGraceMilliseconds);
function hasPolicy(storage) {
  const names = rows(storage, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('avatar_jobs_v1','avatar_profiles_v1')");
  if (names.length !== 0 && names.length !== 2) throw unavailable();
  return names.length === 2;
}

/** Same transaction as select/clear. No provider IO or arbitrary asset URL, and no deadline renewal. */
export function markAvatarRetired(storage, selection, retiredAt) {
  if (selection?.version_id === null || selection === undefined) return;
  const { account_id: accountID, request_id: requestID, version_id: versionID } = selection;
  if (![accountID, requestID, versionID].every(value => typeof value === "string" && publicUUID.test(value)) || !validTime(retiredAt)) throw unavailable();
  const identity = recordIdentity(accountID, "avatar", versionID);
  const record = rows(storage, "SELECT * FROM public_records_v1 WHERE record_name=?", identity.recordName)[0];
  // An upload cannot start provider IO before its registry reservation. No reservation means no known asset to retire.
  if (!record || record.phase === "erased") return;
  if (record.account_id !== accountID || record.request_id !== requestID || record.kind !== "avatar" ||
      !["pending", "settled"].includes(record.phase) || !Number.isSafeInteger(record.started_at) || record.started_at < 0 || record.started_at > retiredAt) throw unavailable();
  storage.sql.exec("INSERT OR IGNORE INTO avatar_retirements_v1(record_name,account_id,request_id,version_id,retired_at) VALUES(?,?,?,?,?)",
    identity.recordName, accountID, requestID, versionID, retiredAt);
  const saved = rows(storage, "SELECT * FROM avatar_retirements_v1 WHERE record_name=?", identity.recordName)[0];
  if (saved.account_id !== accountID || saved.request_id !== requestID || saved.version_id !== versionID ||
      !validTime(saved.retired_at) || saved.retired_at < record.started_at || saved.retired_at > retiredAt) throw unavailable();
}

/** Revalidate against the current selection at every lease boundary, including after provider IO. */
export function avatarRetirementDeadline(storage, context, now) {
  const row = rows(storage, "SELECT * FROM avatar_retirements_v1 WHERE record_name=?", context.recordName)[0];
  if (!row) {
    if (!hasPolicy(storage)) return null;
    const { profile, job } = currentAvatarSelection(storage, context.accountID);
    if (profile?.request_id !== context.requestID || profile?.version_id === null || profile?.version_id === undefined ||
        recordIdentity(context.accountID, "avatar", profile.version_id).recordName !== context.recordName) return null;
    const deadline = avatarSelectionDeadline(profile, job, now);
    return deadline !== null && deadline <= now ? deadline + avatarRetirementGraceMilliseconds : null;
  }
  if (context.kind !== "avatar" || row.account_id !== context.accountID || row.request_id !== context.requestID ||
      typeof row.version_id !== "string" || !publicUUID.test(row.version_id) ||
      recordIdentity(context.accountID, "avatar", row.version_id).recordName !== context.recordName ||
      !validTime(row.retired_at) || row.retired_at < context.startedAt || row.retired_at > now || !hasPolicy(storage)) throw unavailable();
  const { profile: current, job } = currentAvatarSelection(storage, context.accountID);
  const same = current?.request_id === row.request_id || current?.version_id === row.version_id;
  if (same && (current?.request_id !== row.request_id || current?.version_id !== row.version_id ||
      avatarSelectionDeadline(current, job, now) !== row.retired_at || row.retired_at > now)) throw unavailable();
  if (!current ||
      typeof current.request_id !== "string" || !publicUUID.test(current.request_id) ||
      current.version_id !== null && (typeof current.version_id !== "string" || !publicUUID.test(current.version_id)) ||
      !Number.isSafeInteger(current.generation) || current.generation < 1 ||
      !Number.isSafeInteger(current.updated_at) || !same && current.updated_at < row.retired_at || current.updated_at > now) throw unavailable();
  return row.retired_at + avatarRetirementGraceMilliseconds;
}

const historical = `FROM avatar_jobs_v1 j JOIN avatar_profiles_v1 p ON p.account_id=j.account_id
  JOIN public_records_v1 r ON r.account_id=j.account_id AND r.kind='avatar' AND r.request_id=j.request_id
  JOIN auth_accounts_v1 a ON a.account_id=j.account_id LEFT JOIN avatar_retirements_v1 t ON t.record_name=r.record_name
  WHERE a.disabled=0 AND r.phase IN ('pending','settled') AND j.request_id!=p.request_id AND (p.version_id IS NULL OR j.version_id!=p.version_id)
  AND j.generation<p.generation AND t.record_name IS NULL`;
export function backfillAvatarRetirements(storage, now, maximum = 100) {
  if (!hasPolicy(storage)) return 0;
  if (!validTime(now) || !Number.isInteger(maximum) || maximum < 1 || maximum > 100) throw unavailable();
  const expired = expireAvatarSelections(storage, now, maximum, (profile, deadline) => markAvatarRetired(storage, profile, deadline));
  purgeAvatarJobsWithoutRecords(storage, now, maximum);
  const candidates = rows(storage, `SELECT j.account_id,j.request_id,j.version_id,p.updated_at ${historical}
    ORDER BY j.account_id,j.request_id LIMIT ?`, maximum - expired);
  for (const row of candidates) {
    if (!validTime(row.updated_at) || row.updated_at > now) throw unavailable();
    markAvatarRetired(storage, row, row.updated_at);
  }
  return expired + candidates.length;
}
export function needsAvatarRetirementBackfill(storage) {
  if (rows(storage, `SELECT 1 FROM avatar_retirements_v1 t JOIN public_records_v1 p ON p.record_name=t.record_name
      JOIN auth_accounts_v1 a ON a.account_id=p.account_id LEFT JOIN public_retention_v1 r ON r.record_name=p.record_name
      WHERE a.disabled=0 AND p.phase IN ('pending','settled') AND r.record_name IS NULL LIMIT 1`).length) return true;
  return hasPolicy(storage) && rows(storage, `SELECT 1 ${historical} LIMIT 1`).length > 0;
}

/** Local-only, inside the caller's transaction; never refunds an upload attempt or exposes a receipt. */
export function expireAvatarTransferReceipts(storage, now, maximum = 100) {
  if (!Number.isSafeInteger(now) || now < 0 || !Number.isInteger(maximum) || maximum < 1 || maximum > 100) throw unavailable();
  if (!rows(storage, "SELECT name FROM sqlite_master WHERE type='table' AND name='avatar_asset_transfers_v1'").length) return 0;
  const columns = new Set(rows(storage, "PRAGMA table_info(avatar_asset_transfers_v1)").map(row => row.name));
  if (!columns.has("receipt_envelope")) return 0; // Older schema has no encrypted receipts to purge; no provider migration is needed.
  if (!["receipt_expires_at", "record_name", "variant"].every(column => columns.has(column))) throw unavailable();
  const expired = rows(storage, `SELECT record_name,variant FROM avatar_asset_transfers_v1
    WHERE receipt_envelope IS NOT NULL AND receipt_expires_at<=? ORDER BY receipt_expires_at LIMIT ?`, now, maximum);
  for (const row of expired) storage.sql.exec("UPDATE avatar_asset_transfers_v1 SET receipt_envelope=NULL WHERE record_name=? AND variant=?", row.record_name, row.variant);
  return expired.length;
}
