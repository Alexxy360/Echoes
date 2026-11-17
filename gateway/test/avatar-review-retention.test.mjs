import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { avatarReviewFixture } from "./support/avatar-review-fixture.mjs";
import { AvatarReviewReceipts } from "../src/avatar-review-state.mjs";
import { GatewayMaintenance } from "../src/gateway-maintenance.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";

test("file-backed receipts are recovered through a new SQLite connection and coordinator", async () => {
  const directory = mkdtempSync(join(tmpdir(), "echoes-review-sqlite-")), path = join(directory, "state.sqlite");
  const f = await avatarReviewFixture({ path }); let connection;
  try {
    const response = await f.inspect(), metadata = f.reviewMetadata(response);
    connection = new DatabaseSync(path);
    const storage = { sql: { exec(sql, ...args) { const rows = connection.prepare(sql).all(...args); return { toArray: () => rows }; } },
      transactionSync(action) { connection.exec("BEGIN IMMEDIATE"); try { const r = action(); connection.exec("COMMIT"); return r; } catch (e) { connection.exec("ROLLBACK"); throw e; } }, async sync() {} };
    const receipts = new AvatarReviewReceipts(storage, { clock: f.clock });
    const result = await f.reviewCall("prepareDecision", f.input({ inspectionID: metadata.inspectionID,
      decisionID: randomUUID(), verdict: "rejected" }), f.makeReview({ receipts }));
    assert.equal(result.verdict, "rejected"); assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
    assert.equal(connection.prepare("SELECT result_revision FROM avatar_review_receipts_v1").get().result_revision, result.revision);
  } finally { connection?.close(); f.close(); rmSync(directory, { recursive: true }); }
});

test("existing maintenance purges expired inspection rows while review is disabled", async () => {
  const f = await avatarReviewFixture(); let alarm = null;
  try {
    await f.inspect(); f.disableReview(); f.advance(90000);
    const storage = { ...f.storage, async getAlarm() { return alarm; }, async setAlarm(value) { alarm = value; }, async deleteAlarm() { alarm = null; } };
    const maintenance = new GatewayMaintenance(storage, { clock: f.clock, limits: new GatewayLimits(f.storage, { clock: f.clock }), deletions: f.deletions });
    const before = f.downloads.length; await maintenance.alarm();
    assert.equal(f.db.prepare("SELECT COUNT(*) n FROM avatar_review_receipts_v1").get().n, 0);
    assert.equal(f.downloads.length, before);
  } finally { f.close(); }
});
