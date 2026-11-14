import { purgeAuthenticationStorage } from "./authentication-state.mjs";

/** One recurring alarm, bounded local cleanup, and fair rotation over internal deletion jobs. */
export class GatewayMaintenance {
  #storage; #limits; #deletions; #clock;
  constructor(storage, { limits, deletions, clock = Date.now } = {}) {
    if (typeof storage?.getAlarm !== "function" || typeof storage.setAlarm !== "function" || typeof storage.deleteAlarm !== "function" || typeof storage.sync !== "function" ||
        typeof storage.transactionSync !== "function" || typeof limits?.purgeExpired !== "function" ||
        typeof deletions?.dueDeletionIDs !== "function" || typeof clock !== "function") throw new Error("Maintenance is unavailable.");
    this.#storage = storage; this.#limits = limits; this.#deletions = deletions; this.#clock = clock;
    storage.transactionSync(() => {
      storage.sql.exec("CREATE TABLE IF NOT EXISTS gateway_maintenance_v1(id INTEGER PRIMARY KEY,cursor TEXT)");
      storage.sql.exec("INSERT OR IGNORE INTO gateway_maintenance_v1(id,cursor) VALUES (1,NULL)");
    });
  }
  #now() { const now = this.#clock(); if (!Number.isSafeInteger(now) || now < 0) throw new Error("Maintenance is unavailable."); return now; }
  async schedule() {
    const next = this.#now() + 60000, alarm = await this.#storage.getAlarm();
    if (alarm === null || alarm > next) await this.#storage.setAlarm(next);
    await this.#storage.sync();
  }
  async alarm({ processor } = {}) {
    // Schedule first: subsequent errors/retries cannot silently stop periodic retention.
    await this.#storage.setAlarm(this.#now() + 60000); await this.#storage.sync();
    await this.#deletions.expireRevocationSecrets();
    await purgeAuthenticationStorage(this.#storage, this.#clock);
    await this.#limits.purgeExpired(); await this.#deletions.purgeCompletedReceipts();
    const cursor = this.#storage.sql.exec("SELECT cursor FROM gateway_maintenance_v1 WHERE id=1").toArray()[0].cursor ?? "";
    const deletionID = this.#deletions.dueDeletionIDs({ afterID: cursor })[0];
    if (deletionID) {
      this.#storage.transactionSync(() => this.#storage.sql.exec("UPDATE gateway_maintenance_v1 SET cursor=? WHERE id=1", deletionID));
      await this.#storage.sync();
      if (processor) await processor.step(deletionID);
      else await this.#deletions.finalize(deletionID); // Local reconciliation only; no provider calls while disabled.
    }
    const timedTables = ["auth_challenges_v1", "auth_sessions_v1", "auth_issue_budget_v1", "auth_renewal_grants_v1",
      "auth_refresh_credentials_v1", "auth_credential_reservations_v1", "gateway_windows_v1", "gateway_daily_v1"];
    const timedRows = timedTables.some(table => this.#storage.sql.exec(`SELECT 1 FROM ${table} LIMIT 1`).toArray().length > 0);
    const receipts = this.#storage.sql.exec("SELECT 1 FROM auth_account_deletions_v1 WHERE completed_at IS NOT NULL LIMIT 1").toArray().length > 0;
    if (!timedRows && !receipts && !(processor && this.#deletions.dueDeletionIDs().length)) {
      // A later authenticated request/configuration bootstrap schedules work again.
      await this.#storage.deleteAlarm(); await this.#storage.sync();
    }
  }
}
