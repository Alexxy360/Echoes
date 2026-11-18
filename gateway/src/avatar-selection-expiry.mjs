import { PublicRecordError, publicUUID, recordIdentity } from "./public-record-schema.mjs";

export const avatarSelectionLifetimeMilliseconds = 7 * 86400000;
const rows = (storage, sql, ...args) => storage.sql.exec(sql, ...args).toArray();
const invalid = () => new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
const id = value => typeof value === "string" && publicUUID.test(value);
const time = value => Number.isSafeInteger(value) && value >= 0 && Number.isSafeInteger(value + avatarSelectionLifetimeMilliseconds);
export function migrateAvatarSelectionExpiry(storage) {
  if (!rows(storage, "SELECT name FROM sqlite_master WHERE type='table' AND name='avatar_profiles_v1'").length) return;
  const columns = new Set(rows(storage, "PRAGMA table_info(avatar_profiles_v1)").map(row => row.name));
  for (const [name, type] of [["expired_at", "INTEGER"], ["expired_review_revision", "TEXT"]]) {
    if (!columns.has(name)) storage.sql.exec(`ALTER TABLE avatar_profiles_v1 ADD COLUMN ${name} ${type}`);
  }
}
/** No TTL for an approved published photo. All deadlines come from trusted server policy metadata. */
export function avatarSelectionDeadline(profile, job, now) {
  if (!profile || profile.version_id === null) return null;
  if (!id(profile.request_id) || !id(profile.version_id) || !Number.isSafeInteger(profile.generation) || profile.generation < 1 ||
      !time(profile.updated_at) || profile.updated_at > now) throw invalid();
  if (profile.expired_at !== null && profile.expired_at !== undefined) {
    if (!time(profile.expired_at) || profile.expired_at < profile.updated_at || profile.expired_at > now ||
        profile.ready !== 0 || !id(profile.expired_review_revision)) throw invalid();
    return profile.expired_at;
  }
  if (profile.expired_review_revision !== null && profile.expired_review_revision !== undefined || !job ||
      job.request_id !== profile.request_id || job.version_id !== profile.version_id || job.generation !== profile.generation ||
      !id(job.moderation_revision) || !["pending", "approved", "rejected"].includes(job.moderation_state) ||
      !time(job.created_at) || job.created_at > now ||
      job.reviewed_at !== null && (!time(job.reviewed_at) || job.reviewed_at < job.created_at || job.reviewed_at > now)) throw invalid();
  if (profile.ready === 1 && job.moderation_state === "approved") return null;
  return (job.reviewed_at ?? job.created_at) + avatarSelectionLifetimeMilliseconds;
}
export function currentAvatarSelection(storage, accountID) {
  const profile = rows(storage, "SELECT * FROM avatar_profiles_v1 WHERE account_id=?", accountID)[0];
  const job = profile?.version_id ? rows(storage, "SELECT * FROM avatar_jobs_v1 WHERE account_id=? AND request_id=?", accountID, profile.request_id)[0] : undefined;
  return { profile, job };
}
function hasPolicy(storage) {
  const count = rows(storage, "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('avatar_profiles_v1','avatar_jobs_v1')").length;
  if (count !== 0 && count !== 2) throw invalid(); return count === 2;
}
const pendingSelections = `FROM avatar_profiles_v1 p JOIN avatar_jobs_v1 j ON j.account_id=p.account_id
  AND j.request_id=p.request_id AND j.version_id=p.version_id AND j.generation=p.generation
  JOIN auth_accounts_v1 a ON a.account_id=p.account_id WHERE a.disabled=0 AND p.expired_at IS NULL
  AND NOT(p.ready=1 AND j.moderation_state='approved')`;
export function avatarSelectionExpirySchedule(storage, now) {
  if (!hasPolicy(storage)) return null;
  const row = rows(storage, `SELECT MIN(COALESCE(j.reviewed_at,j.created_at)) AS first ${pendingSelections}`)[0];
  const orphan = rows(storage, `SELECT MIN(j.created_at) AS first FROM avatar_jobs_v1 j
    JOIN avatar_profiles_v1 p ON p.account_id=j.account_id JOIN auth_accounts_v1 a ON a.account_id=j.account_id
    LEFT JOIN public_records_v1 r ON r.account_id=j.account_id AND r.kind='avatar' AND r.request_id=j.request_id
    WHERE a.disabled=0 AND r.record_name IS NULL AND
      ((p.request_id=j.request_id AND p.version_id=j.version_id AND p.expired_at IS NOT NULL) OR
       (p.request_id!=j.request_id AND (p.version_id IS NULL OR p.version_id!=j.version_id) AND p.generation>j.generation))`)[0];
  const starts = [row.first, orphan.first].filter(value => value !== null);
  if (!starts.length) return null;
  if (starts.some(value => !time(value) || value > now)) throw invalid();
  return Math.min(...starts) + avatarSelectionLifetimeMilliseconds;
}
/** Inside the caller's SQLite transaction. Retiring known records is supplied by the registry layer. */
export function expireAvatarSelections(storage, now, maximum, retire) {
  if (!hasPolicy(storage)) return 0;
  if (!time(now) || !Number.isInteger(maximum) || maximum < 1 || maximum > 100 || typeof retire !== "function") throw invalid();
  const candidates = rows(storage, `SELECT p.account_id ${pendingSelections} AND COALESCE(j.reviewed_at,j.created_at)<=?
    ORDER BY COALESCE(j.reviewed_at,j.created_at),p.account_id LIMIT ?`, now - avatarSelectionLifetimeMilliseconds, maximum);
  for (const { account_id: accountID } of candidates) {
    if (!expireAvatarSelection(storage, accountID, now, retire)) throw invalid();
  }
  return candidates.length;
}
export function expireAvatarSelection(storage, accountID, now, retire) {
  if (!id(accountID) || !time(now) || typeof retire !== "function") throw invalid();
  const { profile, job } = currentAvatarSelection(storage, accountID), deadline = avatarSelectionDeadline(profile, job, now);
  if (deadline === null || deadline > now || profile.expired_at !== null) return false;
  retire(profile, deadline);
  storage.sql.exec("UPDATE avatar_profiles_v1 SET expired_at=?,expired_review_revision=?,ready=0,pointer_tag=NULL WHERE account_id=?",
    deadline, job.moderation_revision, accountID);
  return true;
}
/** Jobs with no reserved record cannot have started asset IO in this adapter. Never remove dangling transfers. */
export function purgeAvatarJobsWithoutRecords(storage, now, maximum = 100) {
  if (!hasPolicy(storage)) return 0;
  if (!time(now) || !Number.isInteger(maximum) || maximum < 1 || maximum > 100) throw invalid();
  const candidates = rows(storage, `SELECT j.* FROM avatar_jobs_v1 j JOIN avatar_profiles_v1 p ON p.account_id=j.account_id
    JOIN auth_accounts_v1 a ON a.account_id=j.account_id
    LEFT JOIN public_records_v1 r ON r.account_id=j.account_id AND r.kind='avatar' AND r.request_id=j.request_id
    WHERE a.disabled=0 AND r.record_name IS NULL AND j.created_at<=? AND
      ((p.request_id=j.request_id AND p.version_id=j.version_id AND p.expired_at IS NOT NULL) OR
       (p.request_id!=j.request_id AND (p.version_id IS NULL OR p.version_id!=j.version_id) AND p.generation>j.generation))
    ORDER BY j.created_at,j.account_id,j.request_id LIMIT ?`, now - avatarSelectionLifetimeMilliseconds, maximum);
  for (const job of candidates) {
    const identity = recordIdentity(job.account_id, "avatar", job.version_id);
    if (rows(storage, "SELECT 1 FROM avatar_asset_transfers_v1 WHERE record_name=? LIMIT 1", identity.recordName).length) throw invalid();
    storage.sql.exec("DELETE FROM avatar_review_receipts_v1 WHERE account_id=? AND request_id=?", job.account_id, job.request_id);
    storage.sql.exec("DELETE FROM avatar_jobs_v1 WHERE account_id=? AND request_id=?", job.account_id, job.request_id);
  }
  return candidates.length;
}
