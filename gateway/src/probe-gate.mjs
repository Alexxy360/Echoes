import { makeDevelopmentProbeContext } from "./cloudkit-probe.mjs";
import { jsonResponse } from "./probe-http.mjs";

/** Uses the SQLite Durable Object API. The UNIQUE key is the cross-request one-shot boundary. */
export async function runReservedProbe(sql, runID, execute, confirmDurableWrite = async () => {}) {
  sql.exec(`CREATE TABLE IF NOT EXISTS development_probe (
    run_id TEXT PRIMARY KEY, status TEXT NOT NULL, context TEXT NOT NULL,
    report TEXT, http_status INTEGER
  )`);
  const context = makeDevelopmentProbeContext();
  context.runIdentifier = runID;
  const claimed = sql.exec(
    "INSERT INTO development_probe (run_id,status,context) VALUES (?,'running',?) ON CONFLICT(run_id) DO NOTHING RETURNING run_id",
    runID, JSON.stringify(context),
  ).toArray().length === 1;
  if (!claimed) {
    const previous = sql.exec("SELECT status,context,report,http_status FROM development_probe WHERE run_id=?", runID).toArray()[0];
    if (!previous) return jsonResponse({ error: "ledger-unavailable" }, 503);
    if (previous.status === "complete") return jsonResponse(JSON.parse(previous.report), previous.http_status);
    const saved = JSON.parse(previous.context);
    return jsonResponse({ state: "running-or-unknown", runIdentifier: runID,
      syntheticRecordName: saved.syntheticRecordName }, 202, { "Retry-After": "3" });
  }
  await confirmDurableWrite();
  // Context is durable before any CloudKit write. An uncertain run never starts a second one.
  let report;
  let status;
  try {
    report = await execute(context);
    status = report.writeSucceeded && report.readBackSucceeded && report.cleanupSucceeded ? 200 : 502;
  } catch {
    report = { runIdentifier: runID, syntheticRecordName: context.syntheticRecordName,
      environment: "Development", errorCode: "EXECUTION_UNKNOWN", cleanupSucceeded: false };
    status = 502;
  }
  sql.exec("UPDATE development_probe SET status='complete',report=?,http_status=? WHERE run_id=?",
    JSON.stringify(report), status, runID);
  await confirmDurableWrite();
  return jsonResponse(report, status);
}
