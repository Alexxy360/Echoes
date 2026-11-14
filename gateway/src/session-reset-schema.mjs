// A global transaction order separates requests even in the same millisecond. One fence/account,
// retained until account erasure; not a time-based deletion fence or a provider revocation receipt.
export const sessionResetSchema = [
  `CREATE TABLE IF NOT EXISTS auth_event_order_v1(singleton INTEGER PRIMARY KEY CHECK(singleton=1),value INTEGER NOT NULL)`,
  `INSERT OR IGNORE INTO auth_event_order_v1(singleton,value) VALUES (1,0)`,
  `CREATE TABLE IF NOT EXISTS auth_session_reset_fences_v1(subject_hash TEXT PRIMARY KEY,challenge_order INTEGER NOT NULL)`,
];
