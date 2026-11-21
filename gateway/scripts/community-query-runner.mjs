import { CommunityProtocolError, isCommunityProtocolWindow } from "./community-protocol-runner.mjs";
import { CommunityQueryPages, communityQueryPayload, verifyCommunityQueryPlan } from "./community-query-plan.mjs";
import { plain, publicUUID, matchesFields, validTag } from "../src/public-record-schema.mjs";

const remoteCodes = new Set(["NOT_FOUND", "EXISTS", "CONFLICT", "ACCESS_DENIED", "AUTHENTICATION_FAILED", "AUTHENTICATION_REQUIRED",
  "THROTTLED", "QUOTA_EXCEEDED", "BAD_REQUEST", "INTERNAL_ERROR", "TRY_AGAIN_LATER"]);
const rejectedCreates = new Set(["ACCESS_DENIED", "AUTHENTICATION_FAILED", "AUTHENTICATION_REQUIRED", "BAD_REQUEST", "THROTTLED", "QUOTA_EXCEEDED", "NOT_FOUND"]);
const statuses = new Set(["unattempted", "pending", "owned", "collision", "rejected", "absent"]);
const phases = new Set(["prepared", "preflight_pending", "create_pending", "initial_read_pending", "query_pending", "cleanup_read_pending", "delete_pending", "absence_read_pending", "settled", "cleanup_pending"]);
const pinnedRuns = new Map();
const safeCodes = new Set(["PROTOCOL_DENIED", "PROTOCOL_WINDOW", "PROTOCOL_CLOCK", "PROTOCOL_CANCELLED", "PROTOCOL_TIMEOUT",
  "PROTOCOL_LIMIT", "PROTOCOL_RESPONSE", "PROTOCOL_EXISTING", "PROTOCOL_REJECTED", "PROTOCOL_RECOVERY", "PROTOCOL_SCOPE",
  "JOURNAL_FAILED", "JOURNAL_SCOPE", "JOURNAL_BUSY", "PROTOCOL_FAILED", "PROTOCOL_DRAIN"]);
const safe = error => safeCodes.has(error?.code) ? error.code : "PROTOCOL_FAILED";
const fail = code => { throw new CommunityProtocolError(code); };
const finished = row => ["unattempted", "collision", "rejected", "absent"].includes(row.status);
function sameRecord(record, item, fields) {
  return plain(record) && !record.serverErrorCode && !record.deleted && record.recordName === item.recordName &&
    record.recordType === item.recordType && validTag(record.recordChangeTag) && matchesFields(record.fields, fields);
}
function records(body, names) {
  if (!plain(body) || body.serverErrorCode || !Array.isArray(body.records) || body.records.length !== names.length) fail("PROTOCOL_RESPONSE");
  const result = new Map();
  for (const row of body.records) {
    if (!plain(row) || !names.includes(row.recordName) || result.has(row.recordName) ||
        row.serverErrorCode !== undefined && !remoteCodes.has(row.serverErrorCode)) fail("PROTOCOL_RESPONSE");
    result.set(row.recordName, row);
  }
  return result;
}
function validState(state, plan) {
  return plain(state) && state.version === 1 && Number.isInteger(state.callsTotal) && state.callsTotal >= 0 && state.callsTotal <= 256 &&
    phases.has(state.phase) && (state.errorCode === null || safeCodes.has(state.errorCode)) &&
    (state.cleanupWarning === undefined || safeCodes.has(state.cleanupWarning)) &&
    (state.unsafeCreateResponse === undefined || typeof state.unsafeCreateResponse === "boolean") &&
    Number.isInteger(state.windowCalls) && state.windowCalls >= 0 && state.windowCalls <= 32 && state.windowCalls <= state.callsTotal && isCommunityProtocolWindow(state.window) &&
    Array.isArray(state.windowIDs) && state.windowIDs.length <= 8 && new Set(state.windowIDs).size === state.windowIDs.length &&
    state.windowIDs.every(id => publicUUID.test(id)) && state.windowIDs.includes(state.window.id) &&
    state.callsTotal <= state.windowIDs.length * 32 && Number.isSafeInteger(state.lastWall) && state.lastWall >= 0 && typeof state.createAttempted === "boolean" &&
    typeof state.protocolPassed === "boolean" && typeof state.cleanupComplete === "boolean" &&
    Array.isArray(state.records) && state.records.length === 12 && state.records.every((row, index) => plain(row) &&
      row.recordName === plan.records[index].recordName && statuses.has(row.status) && typeof row.confirmedCreated === "boolean" &&
      (row.tag === null || validTag(row.tag)) && (row.initialTag === null || validTag(row.initialTag)) &&
      (row.status !== "owned" || row.confirmedCreated && validTag(row.tag))) &&
    (!state.protocolPassed || state.createAttempted && state.records.every(row => row.confirmedCreated && validTag(row.initialTag))) &&
    (!state.cleanupComplete || state.records.every(finished));
}

/** Twelve-record query engine. Restarts are cleanup-only; a failed query is never retried. */
export async function runCommunityQuery({ journal, transport, window, isAuthorized = () => false, clock = Date.now,
  monotonic = () => performance.now(), signal, callMilliseconds = 8000 } = {}) {
  if (typeof journal?.snapshot !== "function" || typeof journal.write !== "function" || typeof journal.beginRun !== "function" || typeof journal.endRun !== "function" || typeof transport?.request !== "function" ||
      typeof transport.waitForPendingOperations !== "function" || !isCommunityProtocolWindow(window) || typeof isAuthorized !== "function" ||
      typeof clock !== "function" || typeof monotonic !== "function" || !Number.isInteger(callMilliseconds) || callMilliseconds < 1 || callMilliseconds > 8000) fail("PROTOCOL_SCOPE");
  const snapshot = journal.snapshot(), { plan, sha256 } = snapshot;
  try { verifyCommunityQueryPlan(plan, sha256); } catch { fail("JOURNAL_SCOPE"); }
  let state = snapshot.state, storageFailed = false, drainFailed = false, drainVerified = false;
  if (state !== null && !validState(state, plan)) fail("JOURNAL_SCOPE");
  if (state && window.mode !== "cleanup" || !state && window.mode !== "full") fail("PROTOCOL_RECOVERY");
  if (state && (state.windowIDs.includes(window.id) || state.windowIDs.length >= 8)) fail("PROTOCOL_RECOVERY");
  const firstWall = clock(), firstMono = monotonic();
  if (!Number.isSafeInteger(firstWall) || !Number.isFinite(firstMono) || firstWall < (state?.lastWall ?? window.issuedAt)) fail("PROTOCOL_CLOCK");
  const monotonicBudget = window.expiresAt - firstWall; let floorWall = firstWall, floorMono = firstMono;
  function permit() {
    const wall = clock(), mono = monotonic();
    if (!Number.isSafeInteger(wall) || !Number.isFinite(mono) || wall < floorWall || mono < floorMono) fail("PROTOCOL_CLOCK");
    floorWall = wall; floorMono = mono;
    if (signal?.aborted) fail("PROTOCOL_CANCELLED");
    if (wall < window.issuedAt || wall >= window.expiresAt || mono - firstMono >= monotonicBudget) fail("PROTOCOL_WINDOW");
    if (isAuthorized({ planSHA256: sha256, window: { ...window } }) !== true) fail("PROTOCOL_DENIED");
    return { wall, remaining: Math.min(window.expiresAt - wall, monotonicBudget - (mono - firstMono)) };
  }
  permit();
  if (!state) state = { version: 1, phase: "prepared", callsTotal: 0, windowCalls: 0, window: { ...window }, windowIDs: [window.id],
    lastWall: firstWall, createAttempted: false, protocolPassed: false, cleanupComplete: false, errorCode: null,
    records: plan.records.map(item => ({ recordName: item.recordName, status: "unattempted", confirmedCreated: false, tag: null, initialTag: null })) };
  else { state.window = { ...window }; state.windowIDs.push(window.id); state.windowCalls = 0; state.cleanupComplete = false; }
  function persist() {
    if (storageFailed) fail("JOURNAL_FAILED");
    state.lastWall = floorWall;
    try { journal.write(structuredClone(state)); } catch { storageFailed = true; fail("JOURNAL_FAILED"); }
  }
  const runToken = journal.beginRun();
  try { persist(); } catch (error) { journal.endRun(runToken); throw error; }
  const pending = new Set();
  async function drain() {
    drainVerified = false;
    await Promise.allSettled([...pending]);
    try { await transport.waitForPendingOperations(); drainVerified = true; } catch { drainFailed = true; fail("PROTOCOL_DRAIN"); }
  }
  async function send(operation, payload, phase) {
    const { wall } = permit();
    if (state.windowCalls >= 32 || state.callsTotal >= 256 || storageFailed || drainFailed) fail("PROTOCOL_LIMIT");
    const names = operation === "records/query" ? null : operation === "records/lookup" ? payload.records.map(row => row.recordName) : payload.operations.map(row => row.record.recordName);
    if (names !== null && (!names.length || names.length > 12 || new Set(names).size !== names.length || names.some(name => !plan.records.some(item => item.recordName === name)))) fail("PROTOCOL_SCOPE");
    state.phase = phase; state.windowCalls++; state.callsTotal++; state.lastWall = wall; persist();
    const { remaining } = permit(); // A durable commit may consume most of the remaining permission window.
    const controller = new AbortController(); let rejectAbort;
    const cancelled = new Promise((_, reject) => { rejectAbort = reject; });
    const cancel = () => { controller.abort(); rejectAbort(new CommunityProtocolError("PROTOCOL_CANCELLED")); };
    signal?.addEventListener("abort", cancel, { once: true });
    const timer = setTimeout(() => { controller.abort(); rejectAbort(new CommunityProtocolError("PROTOCOL_TIMEOUT")); }, Math.min(callMilliseconds, remaining));
    const actual = Promise.resolve().then(() => { permit(); return transport.request(operation, structuredClone(payload), { signal: controller.signal }); });
    pending.add(actual); void actual.then(() => pending.delete(actual), () => pending.delete(actual));
    try {
      const result = await Promise.race([actual, cancelled]);
      // Even a malformed partial create response must never cause deletion of an explicit EXISTS.
      if (phase === "create_pending" && plain(result) && Array.isArray(result.records)) {
        if (result.records.length > 32) state.unsafeCreateResponse = true;
        else for (const row of result.records) if (plain(row) && row.serverErrorCode === "EXISTS") {
          const known = state.records.find(item => item.recordName === row.recordName);
          if (known) known.status = "collision";
        }
        persist();
      }
      permit(); return names === null ? result : records(result, names);
    } finally { clearTimeout(timer); signal?.removeEventListener("abort", cancel); controller.abort(); }
  }
  const lookup = (items, phase) => send("records/lookup", { records: items.map(item => ({ recordName: item.recordName })) }, phase);
  const modify = (items, operationType, fields, tags, phase) => send("records/modify", { atomic: false, operations: items.map(item => ({ operationType,
    record: { recordName: item.recordName, recordType: item.recordType, ...(fields ? { fields: item[fields] } : {}),
      ...(tags ? { recordChangeTag: tags.get(item.recordName) } : {}) } })) }, phase);
  async function protocol() {
    const absent = await lookup(plan.records, "preflight_pending");
    if ([...absent.values()].some(row => !row.serverErrorCode)) fail("PROTOCOL_EXISTING");
    if ([...absent.values()].some(row => row.serverErrorCode !== "NOT_FOUND")) fail("PROTOCOL_REJECTED");
    state.createAttempted = true; state.records.forEach(row => row.status = "pending");
    const created = await modify(plan.records, "create", "initial", null, "create_pending");
    for (const [index, item] of plan.records.entries()) {
      const row = state.records[index], result = created.get(item.recordName);
      if (result.serverErrorCode === "EXISTS") row.status = "collision";
      else if (rejectedCreates.has(result.serverErrorCode)) row.status = "rejected";
      else if (sameRecord(result, item, item.initial)) Object.assign(row, { status: "owned", confirmedCreated: true, tag: result.recordChangeTag, initialTag: result.recordChangeTag });
    }
    persist(); if (state.records.some(row => row.status !== "owned")) fail("PROTOCOL_REJECTED");
    const initial = await lookup(plan.records, "initial_read_pending");
    for (const [index, item] of plan.records.entries()) if (!sameRecord(initial.get(item.recordName), item, item.initial) || initial.get(item.recordName).recordChangeTag !== state.records[index].tag) fail("PROTOCOL_RESPONSE");
    state.queryEvidence = {};
    for (const kind of ["presence", "message"]) {
      const pages = new CommunityQueryPages({ plan, sha256 }, kind);
      let marker = null;
      do {
        const result = await send("records/query", communityQueryPayload(plan, kind, marker), "query_pending");
        let accepted;
        try { accepted = pages.accept(result); } catch { fail("PROTOCOL_RESPONSE"); }
        marker = accepted.marker;
        state.queryEvidence[kind] = { pages: accepted.pages, recordNames: accepted.recordNames, complete: accepted.complete };
        persist();
      } while (marker !== null);
    }
    state.protocolPassed = true; persist();
  }
  async function cleanup() {
    const eligible = plan.records.filter((_, index) => !finished(state.records[index]) &&
      (!state.unsafeCreateResponse || state.records[index].confirmedCreated));
    if (!eligible.length) return;
    const found = await lookup(eligible, "cleanup_read_pending"), ready = [], freshTags = new Map();
    for (const item of eligible) {
      const row = state.records[plan.records.indexOf(item)], result = found.get(item.recordName);
      if (result.serverErrorCode === "NOT_FOUND") {
        // A missing record after an UNKNOWN create may still be created later. Keep it pending.
        if (row.confirmedCreated) row.status = "absent";
        continue;
      }
      if (sameRecord(result, item, item.initial)) {
        Object.assign(row, { status: "owned", confirmedCreated: true, tag: result.recordChangeTag });
        ready.push(item); freshTags.set(item.recordName, result.recordChangeTag);
      } else { row.status = "pending"; row.tag = null; }
    }
    persist(); if (!ready.length) return;
    try {
      const deleted = await modify(ready, "delete", null, freshTags, "delete_pending");
      if ([...deleted.values()].some(row => row.deleted !== true && row.serverErrorCode !== "NOT_FOUND")) state.cleanupWarning = "PROTOCOL_REJECTED";
    } catch (error) { state.cleanupWarning = safe(error); }
    await drain();
    const absent = await lookup(ready, "absence_read_pending");
    for (const item of ready) {
      const row = state.records[plan.records.indexOf(item)];
      row.status = absent.get(item.recordName).serverErrorCode === "NOT_FOUND" ? "absent" : "pending";
    }
    persist();
  }
  try { if (window.mode === "full") await protocol(); }
  catch (error) { state.errorCode = safe(error); }
  try { await drain(); if (!storageFailed && !drainFailed && state.createAttempted) await cleanup(); }
  catch (error) { state.cleanupWarning = safe(error); }
  await drain().catch(() => {});
  state.cleanupComplete = state.records.every(finished); state.phase = state.cleanupComplete ? "settled" : "cleanup_pending";
  try { persist(); } catch { /* A volatile completion is never reported as durable success. */ }
  let durable; try { durable = journal.snapshot().state; } catch { storageFailed = true; }
  const report = { planSHA256: sha256, protocolSucceeded: !storageFailed && durable?.protocolPassed === true,
    cleanupSucceeded: !storageFailed && !drainFailed && durable?.cleanupComplete === true,
    storageHealthy: !storageFailed, callsTotal: durable?.callsTotal ?? state.callsTotal, windowCalls: durable?.windowCalls ?? state.windowCalls,
    queryEvidence: durable?.queryEvidence ?? null,
    errorCode: storageFailed ? "JOURNAL_FAILED" : durable?.errorCode ?? state.errorCode,
    cleanupWarning: durable?.cleanupWarning ?? state.cleanupWarning ?? null,
    pendingRecordNames: (durable?.records ?? state.records).filter(row => !finished(row)).map(row => row.recordName),
    skippedExistingRecordNames: (durable?.records ?? state.records).filter(row => row.status === "collision").map(row => row.recordName),
    pendingIO: !drainVerified };
  let released = false;
  const release = async () => {
    if (released) return;
    if (!drainVerified) await drain();
    journal.endRun(runToken); pinnedRuns.delete(journal); released = true;
  };
  if (drainVerified) await release(); else pinnedRuns.set(journal, release);
  // No new network operation: this only rechecks completion of already-dispatched IO.
  Object.defineProperty(report, "waitForSafeRelease", { value: release, enumerable: false });
  return report;
}
