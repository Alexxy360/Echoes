import { PublicRecordError, digest, fieldValues, publicRecordTypes } from "./public-record-schema.mjs";

export const publicRetentionLifetimes = Object.freeze({ presence: 600000, message: 7200000, report: 2592000000 });
export const publicRetentionLeaseMilliseconds = 60000;

/** Only server-owned registry times determine retention. Profiles, blocks and avatars have no TTL. */
export function publicRetentionDeadline(context) {
  if (!context || !Object.hasOwn(publicRecordTypes, context.kind)) throw new PublicRecordError("PUBLIC_SCOPE");
  const lifetime = publicRetentionLifetimes[context.kind];
  if (lifetime === undefined) return null;
  const time = context.kind === "presence" ? context.startedAt : context.createdAt;
  if (!Number.isSafeInteger(time) || time < 0 || !Number.isSafeInteger(time + lifetime)) throw new PublicRecordError();
  return time + lifetime;
}

export function publicRetentionIntentKey(context) {
  if (publicRetentionDeadline(context) === null) throw new PublicRecordError("PUBLIC_SCOPE");
  return digest(JSON.stringify(["echoes/retention-intent/v1", context.recordName, context.accountID,
    context.kind, context.logicalKey, context.requestID, context.payloadHash, context.createdAt, context.startedAt]));
}

/** Content-free record fence; retaining it prevents delayed CREATE/old-tag REPLACE resurrection. */
export function expiredPublicFields(context) {
  return fieldValues({ schemaVersion: 1, ownerKey: context.ownerKey, erased: 1,
    retentionKey: publicRetentionIntentKey(context) });
}

export const publicRetentionSchema = Object.freeze([
  `CREATE TABLE IF NOT EXISTS public_retention_v1(record_name TEXT PRIMARY KEY,intent_key TEXT NOT NULL,
    due_at INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN ('pending','fencing','fenced')),
    lease_id TEXT,lease_at INTEGER,fence_tag TEXT)`,
  `CREATE INDEX IF NOT EXISTS public_retention_due_v1 ON public_retention_v1(state,due_at,record_name)`,
  `CREATE TABLE IF NOT EXISTS public_retention_cursor_v1(singleton INTEGER PRIMARY KEY CHECK(singleton=1),record_name TEXT NOT NULL)`,
  `INSERT OR IGNORE INTO public_retention_cursor_v1(singleton,record_name) VALUES(1,'')`,
]);
