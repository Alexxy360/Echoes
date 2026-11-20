import { purgeModerationRetirements, moderationRetirementWakeAt } from "./moderation-decision-retirements.mjs";
import { purgeAvatarReportReviews, avatarReportReviewWakeAt } from "./avatar-report-review-state.mjs";
import { purgeAuthenticationStorage } from "./authentication-state.mjs";
import { purgeAvatarReviewReceipts } from "./avatar-review-state.mjs";
import { purgeCommunityReportReviews, communityReportReviewWakeAt } from "./community-report-review-state.mjs";
import { GatewayMaintenanceBudget, MaintenanceControlError } from "./gateway-maintenance-control.mjs";
import { expireAvatarTransferReceipts } from "./avatar-retirement-state.mjs";

/** One recurring alarm, bounded local cleanup, and fair rotation over internal deletion jobs. */
export class GatewayMaintenance {
  #storage; #limits; #deletions; #clock; #budget;
  constructor(storage, { limits, deletions, clock = Date.now, budget } = {}) {
    if (typeof storage?.getAlarm !== "function" || typeof storage.setAlarm !== "function" || typeof storage.deleteAlarm !== "function" || typeof storage.sync !== "function" ||
        typeof storage.transactionSync !== "function" || typeof limits?.purgeExpired !== "function" ||
        typeof deletions?.dueDeletionIDs !== "function" || typeof clock !== "function") throw new Error("Maintenance is unavailable.");
    this.#storage = storage; this.#limits = limits; this.#deletions = deletions; this.#clock = clock;
    this.#budget = budget ?? new GatewayMaintenanceBudget(storage, { clock });
    storage.transactionSync(() => {
      storage.sql.exec("CREATE TABLE IF NOT EXISTS gateway_maintenance_v1(id INTEGER PRIMARY KEY,cursor TEXT)");
      storage.sql.exec("INSERT OR IGNORE INTO gateway_maintenance_v1(id,cursor) VALUES (1,NULL)");
    });
  }
  #now() { let now; try { now = this.#clock(); } catch { throw new Error("Maintenance is unavailable."); }
    if (!Number.isSafeInteger(now) || now < 0 || !Number.isSafeInteger(now + 60000)) throw new Error("Maintenance is unavailable."); return now; }
  async schedule() {
    const next = this.#now() + 60000, alarm = await this.#storage.getAlarm();
    if (alarm === null || alarm > next) await this.#storage.setAlarm(next);
    await this.#storage.sync();
  }
  #retentionSchedule(retention) {
    if (!retention) return { dueAt: null, wakeAt: null, needsBackfill: false };
    const value = retention.schedule();
    if (!value || value.dueAt !== null && (!Number.isSafeInteger(value.dueAt) || value.dueAt < 0) ||
        value.wakeAt !== undefined && value.wakeAt !== null && (!Number.isSafeInteger(value.wakeAt) || value.wakeAt < 0) ||
        typeof value.needsBackfill !== "boolean") throw new Error("Maintenance is unavailable.");
    return { ...value, wakeAt: value.wakeAt ?? null };
  }
  async #advanceDeletionCursor(deletionID) {
    this.#storage.transactionSync(() => this.#storage.sql.exec("UPDATE gateway_maintenance_v1 SET cursor=? WHERE id=1", deletionID));
    await this.#storage.sync();
  }
  async alarm({ processor, retention, providerBusy = () => false } = {}) {
    if (typeof providerBusy !== "function" || retention && ["prepare", "schedule", "step"].some(name => typeof retention[name] !== "function")) throw new Error("Maintenance is unavailable.");
    // Schedule first: subsequent errors/retries cannot silently stop periodic retention.
    await this.#storage.setAlarm(this.#now() + 60000); await this.#storage.sync();
    await this.#deletions.expireRevocationSecrets();
    await purgeAuthenticationStorage(this.#storage, this.#clock);
    await purgeAvatarReviewReceipts(this.#storage, this.#clock);
    await purgeModerationRetirements(this.#storage, this.#clock);
    await purgeCommunityReportReviews(this.#storage, this.#clock);
    await purgeAvatarReportReviews(this.#storage, this.#clock);
    this.#storage.transactionSync(() => expireAvatarTransferReceipts(this.#storage, this.#now()));
    await this.#storage.sync();
    await this.#limits.purgeExpired(); await this.#deletions.purgeCompletedReceipts();
    await this.#budget.purgeExpired();
    if (retention) await retention.prepare(); // Bounded local backfill, never provider IO.
    let retentionSchedule = this.#retentionSchedule(retention);
    const cursor = this.#storage.sql.exec("SELECT cursor FROM gateway_maintenance_v1 WHERE id=1").toArray()[0].cursor ?? "";
    const deletionID = this.#deletions.dueDeletionIDs({ afterID: cursor })[0];
    if (deletionID && !processor) {
      await this.#advanceDeletionCursor(deletionID);
      await this.#deletions.finalize(deletionID); // Local reconciliation only; no provider calls while disabled.
    }
    const retry = {}; let failure;
    try {
      const now = this.#now(), preferred = this.#budget.preferredLane();
      const available = [preferred, preferred === "deletion" ? "retention" : "deletion"].filter(lane =>
        lane === "deletion" ? processor && deletionID : retention && retentionSchedule.dueAt !== null && retentionSchedule.dueAt <= now);
      if (providerBusy() === false) for (const lane of available) {
        let permit;
        try { permit = await this.#budget.consume(lane); }
        catch (error) { if (error instanceof MaintenanceControlError && error.code === "MAINTENANCE_LIMITED") { retry[lane] = error.retryAt; continue; } throw error; }
        if (providerBusy() !== false) break;
        if (lane === "deletion") await this.#advanceDeletionCursor(deletionID);
        this.#budget.assertCurrent(permit);
        if (lane === "deletion") await processor.step(deletionID);
        else await retention.step({ maximumRecords: 25 });
        break;
      }
    } catch (error) { failure = error; }
    retentionSchedule = this.#retentionSchedule(retention);
    const timedTables = ["auth_challenges_v1", "auth_sessions_v1", "auth_issue_budget_v1", "auth_renewal_grants_v1",
      "auth_refresh_credentials_v1", "auth_credential_reservations_v1", "gateway_windows_v1", "gateway_daily_v1"];
    if (this.#storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='avatar_review_receipts_v1'").toArray().length) timedTables.push("avatar_review_receipts_v1");
    const timedRows = timedTables.some(table => this.#storage.sql.exec(`SELECT 1 FROM ${table} LIMIT 1`).toArray().length > 0);
    const receipts = this.#storage.sql.exec("SELECT 1 FROM auth_account_deletions_v1 WHERE completed_at IS NOT NULL LIMIT 1").toArray().length > 0;
    const now = this.#now(), candidates = [];
    const retirementWakeAt = moderationRetirementWakeAt(this.#storage, this.#clock);
    if (retirementWakeAt !== null) candidates.push(Math.max(now + 60000, retirementWakeAt));
    const reviewWakeAt = communityReportReviewWakeAt(this.#storage, this.#clock);
    const photoReviewWakeAt = avatarReportReviewWakeAt(this.#storage, this.#clock);
    if (photoReviewWakeAt !== null) candidates.push(Math.max(now + 60000, photoReviewWakeAt));
    if (reviewWakeAt !== null) candidates.push(Math.max(now + 60000, reviewWakeAt));
    if (timedRows || receipts || retentionSchedule.needsBackfill) candidates.push(now + 60000);
    if (processor && this.#deletions.dueDeletionIDs().length) candidates.push(retry.deletion ?? now + 60000);
    if (retentionSchedule.dueAt !== null) candidates.push(retentionSchedule.dueAt > now ? retentionSchedule.dueAt : retry.retention ?? now + 60000);
    if (retentionSchedule.wakeAt !== null) candidates.push(retentionSchedule.wakeAt > now ? retentionSchedule.wakeAt : now + 60000);
    if (!candidates.length) {
      // A later authenticated request/configuration bootstrap schedules work again.
      await this.#storage.deleteAlarm(); await this.#storage.sync();
    } else { await this.#storage.setAlarm(Math.max(now + 1, Math.min(...candidates))); await this.#storage.sync(); }
    if (failure) throw failure;
  }
}
