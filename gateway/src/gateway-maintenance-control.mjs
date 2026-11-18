import { randomUUID } from "node:crypto";

export class MaintenanceControlError extends Error {
  constructor(code = "MAINTENANCE_UNAVAILABLE", retryAt = null) {
    super("Maintenance could not be completed.");
    this.code = ["MAINTENANCE_LIMITED", "MAINTENANCE_BUSY"].includes(code) ? code : "MAINTENANCE_UNAVAILABLE";
    this.retryAt = retryAt;
  }
}
const lanes = ["deletion", "retention"];
export const maintenanceDailyLimits = Object.freeze({ total: 360, deletion: 180, retention: 180 });

/** Separate from user request quotas. Attempts, including unknown failures, consume capacity. */
export class GatewayMaintenanceBudget {
  #storage; #clock;
  constructor(storage, { clock = Date.now } = {}) {
    if (typeof storage?.sql?.exec !== "function" || typeof storage.transactionSync !== "function" ||
        typeof storage.sync !== "function" || typeof clock !== "function") throw new MaintenanceControlError();
    this.#storage = storage; this.#clock = clock;
    this.#tx(() => {
      storage.sql.exec(`CREATE TABLE IF NOT EXISTS maintenance_daily_v1(day INTEGER PRIMARY KEY,total INTEGER NOT NULL,
        deletion INTEGER NOT NULL,retention INTEGER NOT NULL,last_minute INTEGER NOT NULL)`);
      storage.sql.exec(`CREATE TABLE IF NOT EXISTS maintenance_control_v1(singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        observed_at INTEGER NOT NULL,next_lane TEXT NOT NULL,last_ticket TEXT,last_lane TEXT,last_at INTEGER,last_day INTEGER,last_minute INTEGER)`);
      storage.sql.exec("INSERT OR IGNORE INTO maintenance_control_v1(singleton,observed_at,next_lane) VALUES(1,0,'deletion')");
    });
  }
  #tx(action) { try { return this.#storage.transactionSync(action); } catch (error) { throw error instanceof MaintenanceControlError ? error : new MaintenanceControlError(); } }
  #rows(sql, ...args) { return this.#storage.sql.exec(sql, ...args).toArray(); }
  #now() { let now; try { now = this.#clock(); } catch { throw new MaintenanceControlError(); }
    if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + 86400000)) throw new MaintenanceControlError(); return now; }
  #control() {
    const row = this.#rows("SELECT * FROM maintenance_control_v1 WHERE singleton=1")[0];
    if (!row || !Number.isSafeInteger(row.observed_at) || row.observed_at < 0 || !lanes.includes(row.next_lane)) throw new MaintenanceControlError();
    return row;
  }
  #observe(now) {
    const row = this.#control(); if (now < row.observed_at) throw new MaintenanceControlError();
    this.#storage.sql.exec("UPDATE maintenance_control_v1 SET observed_at=? WHERE singleton=1", now); return row;
  }
  async #sync() { try { await this.#storage.sync(); } catch { throw new MaintenanceControlError(); } }
  preferredLane() { return this.#tx(() => this.#control().next_lane); }
  async consume(lane) {
    if (!lanes.includes(lane)) throw new MaintenanceControlError();
    const now = this.#now(), day = Math.floor(now / 86400000), minute = Math.floor(now / 60000);
    const result = this.#tx(() => {
      this.#observe(now);
      this.#storage.sql.exec("INSERT OR IGNORE INTO maintenance_daily_v1(day,total,deletion,retention,last_minute) VALUES(?,0,0,0,-1)", day);
      const old = this.#rows("SELECT * FROM maintenance_daily_v1 WHERE day=?", day)[0];
      if (![old.total, old.deletion, old.retention].every(Number.isSafeInteger) || old.total !== old.deletion + old.retention ||
          old.total < 0 || old.total > 360 || old.deletion < 0 || old.deletion > 180 || old.retention < 0 || old.retention > 180) throw new MaintenanceControlError();
      if (old.total >= maintenanceDailyLimits.total || old[lane] >= maintenanceDailyLimits[lane]) return new MaintenanceControlError("MAINTENANCE_LIMITED", (day + 1) * 86400000);
      if (!Number.isSafeInteger(old.last_minute) || old.last_minute >= minute) return new MaintenanceControlError("MAINTENANCE_LIMITED", (minute + 1) * 60000);
      this.#storage.sql.exec(`UPDATE maintenance_daily_v1 SET total=total+1,${lane}=${lane}+1,last_minute=? WHERE day=?`, minute, day);
      const ticket = randomUUID();
      this.#storage.sql.exec(`UPDATE maintenance_control_v1 SET next_lane=?,last_ticket=?,last_lane=?,last_at=?,last_day=?,last_minute=? WHERE singleton=1`,
        lane === "deletion" ? "retention" : "deletion", ticket, lane, now, day, minute);
      return Object.freeze({ ticket, lane, at: now, day, minute });
    });
    await this.#sync();
    if (result instanceof MaintenanceControlError) throw result;
    this.assertCurrent(result); return result;
  }
  assertCurrent(permit) {
    this.#tx(() => {
      const row = this.#control(), now = this.#now();
      if (!permit || !lanes.includes(permit.lane) || permit.ticket !== row.last_ticket || permit.lane !== row.last_lane ||
          permit.at !== row.last_at || permit.day !== row.last_day || permit.minute !== row.last_minute ||
          now < row.observed_at || now < permit.at || now >= permit.at + 60000 || Math.floor(now / 86400000) !== permit.day) throw new MaintenanceControlError();
    });
  }
  async purgeExpired() {
    const now = this.#now(), day = Math.floor(now / 86400000);
    this.#tx(() => {
      this.#observe(now);
      this.#storage.sql.exec("DELETE FROM maintenance_daily_v1 WHERE day IN (SELECT day FROM maintenance_daily_v1 WHERE day<? LIMIT 100)", day - 1);
    });
    await this.#sync();
  }
}

/** One provider lane stays occupied until all of its real IO is known to have settled. */
export class MaintenanceProviderWork {
  #drain; #occupied = false;
  constructor(drain) { if (typeof drain !== "function") throw new MaintenanceControlError(); this.#drain = drain; }
  get isOccupied() { return this.#occupied; }
  async run(action) {
    if (typeof action !== "function") throw new MaintenanceControlError();
    if (this.#occupied) throw new MaintenanceControlError("MAINTENANCE_BUSY");
    this.#occupied = true;
    try { return await action(); }
    finally {
      void (async () => { try { await this.#drain(); this.#occupied = false; } catch { /* Remain closed without drain evidence. */ } })();
    }
  }
}
