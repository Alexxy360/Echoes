import { createPrivateKey, createPublicKey } from "node:crypto";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { plain, digest } from "../src/public-record-schema.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { makeCommunityQueryPlan, verifyCommunityQueryPlan } from "./community-query-plan.mjs";
import { CommunityQueryJournal, ProtocolJournalError } from "./community-query-journal.mjs";
import { isCommunityProtocolWindow, CommunityProtocolError } from "./community-protocol-runner.mjs";
import { runCommunityQuery } from "./community-query-runner.mjs";
import { CommunityQueryTransport } from "./community-query-transport.mjs";
import { CommunityProtocolCLIError, readProtocolPrivateFile, ensureProtocolParent, publishProtocolPrivateJSON, requireProtocolFileAbsent } from "./community-protocol-files.mjs";

const fail = code => { throw new CommunityProtocolCLIError(code); };
const keys = (value, expected) => plain(value) && Object.keys(value).sort().join() === [...expected].sort().join();
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const keyID = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
const parse = file => { try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(file.bytes)); } catch { fail("CLI_CONFIGURATION"); } };
// Public registration metadata, verified against the old PUBLIC SPKI. Never accept an operator typo as a different retired key.
export const retiredDiagnosticKey = Object.freeze({
  keyID: "0663e7ddc1124c0522589f5db7d0786c19f80c35ac158199db561f6e79a80919",
  publicKeySHA256: "8c42a2a2bcfc81ebff8ef0838923f84654ccf8dc8401777d9c26f51766e68b11",
});

/** An operator attestation binds separately obtained approval; this file cannot prove consent or Apple revocation. */
export function verifyCommunityQueryPermit(value, prepared, mode, now) {
  const expected = ["schemaVersion", "purpose", "scope", "planSHA256", "window", "keyID", "publicKeySHA256", "retiredKeyID", "retiredPublicKeySHA256", "identityModel"];
  if (!keys(value, expected) || value.schemaVersion !== 1 || value.purpose !== "echoes-community-query-development-v1" ||
      value.identityModel !== "individual-owner-administrator-v1" || value.planSHA256 !== prepared.sha256 ||
      !keys(value.scope, Object.keys(prepared.plan.scope)) || Object.keys(prepared.plan.scope).some(name => value.scope[name] !== prepared.plan.scope[name]) ||
      !isCommunityProtocolWindow(value.window) || value.window.mode !== mode || !Number.isSafeInteger(now) || now < value.window.issuedAt || now >= value.window.expiresAt ||
      !keyID(value.keyID) || value.retiredKeyID !== retiredDiagnosticKey.keyID || value.keyID === value.retiredKeyID ||
      !hash(value.publicKeySHA256) || value.retiredPublicKeySHA256 !== retiredDiagnosticKey.publicKeySHA256 ||
      value.publicKeySHA256 === value.retiredPublicKeySHA256) fail("CLI_PERMIT");
  return structuredClone(value);
}

function inventory(directory, snapshot) {
  const value = parse(readProtocolPrivateFile(join(directory, "inventory.json"), 65536));
  if (!keys(value, ["plan", "sha256"])) fail("CLI_INVENTORY");
  try { verifyCommunityQueryPlan(value.plan, value.sha256); } catch { fail("CLI_INVENTORY"); }
  if (value.sha256 !== snapshot.sha256) fail("CLI_INVENTORY");
  return { plan: snapshot.plan, sha256: snapshot.sha256 };
}

/** No arguments activate a service. Only run/cleanup with explicit opt-in and a private bound permit can reach HTTP. */
export async function communityQueryCommand(args, { env = process.env, clock = Date.now, monotonic = () => performance.now(),
  fetchImplementation = fetch, signal, onActivation = () => {} } = {}) {
  let journal, report, engineEntered = false, watcher, removeAbort;
  try {
    if (!Array.isArray(args) || args.some(value => typeof value !== "string")) fail("CLI_USAGE");
    const [command, directory, sha256, permitPath, keyPath] = args;
    if (command === "prepare" && args.length === 2) {
      await ensureProtocolParent(directory);
      const prepared = makeCommunityQueryPlan(); journal = await CommunityQueryJournal.create(directory, prepared);
      await publishProtocolPrivateJSON(join(journal.directory, "inventory.json"), prepared);
      return { exitCode: 0, status: "prepared", directory: journal.directory, planSHA256: prepared.sha256, scope: prepared.plan.scope,
        records: prepared.plan.records.map(({ recordName, recordType }) => ({ recordName, recordType })), networkRequests: 0, windowActivated: false };
    }
    if (!(command === "inspect" && args.length === 3 || ["run", "cleanup"].includes(command) && args.length === 5) || !hash(sha256)) fail("CLI_USAGE");
    if (command !== "inspect" && env.ECHOES_ALLOW_COMMUNITY_QUERY_DEV !== "1") fail("CLI_DISABLED");
    journal = await CommunityQueryJournal.open(directory, sha256);
    const snapshot = journal.snapshot(), prepared = inventory(directory, snapshot);
    if (command === "inspect") return { exitCode: 0, status: "inspected", planSHA256: sha256, scope: prepared.plan.scope,
      revision: snapshot.revision, state: snapshot.state, networkRequests: 0, windowActivated: false };
    const original = readProtocolPrivateFile(permitPath, 8192);
    const permit = verifyCommunityQueryPermit(parse(original), prepared, command === "run" ? "full" : "cleanup", clock());
    if (command === "run" && snapshot.state !== null || command === "cleanup" && (!snapshot.state ||
        !Array.isArray(snapshot.state.windowIDs) || snapshot.state.windowIDs.includes(permit.window.id))) fail("CLI_RECOVERY");
    const privateKey = readProtocolPrivateFile(keyPath, 8192);
    let signer;
    try {
      const pem = new TextDecoder("utf-8", { fatal: true }).decode(privateKey.bytes), key = createPrivateKey(pem);
      if (digest(createPublicKey(key).export({ type: "spki", format: "der" })) !== permit.publicKeySHA256) fail("CLI_KEY");
      signer = new CloudKitDevelopmentSigner({ container: prepared.plan.scope.container, environment: "development", keyID: permit.keyID, privateKeyPEM: pem });
    } catch { fail("CLI_KEY"); } finally { privateKey.bytes.fill(0); }
    const controller = new AbortController();
    const authorized = () => {
      try {
        if (signal?.aborted || controller.signal.aborted || env.ECHOES_ALLOW_COMMUNITY_QUERY_DEV !== "1") return false;
        const current = readProtocolPrivateFile(permitPath, 8192), now = clock();
        return current.sha256 === original.sha256 && current.identity === original.identity && Number.isSafeInteger(now) &&
          now >= permit.window.issuedAt && now < permit.window.expiresAt;
      } catch { return false; }
    };
    if (!authorized()) fail("CLI_PERMIT");
    const abort = () => controller.abort(); signal?.addEventListener("abort", abort, { once: true });
    removeAbort = () => signal?.removeEventListener("abort", abort);
    watcher = setInterval(() => { if (!authorized()) controller.abort(); }, 250); watcher.unref();
    requireProtocolFileAbsent(join(directory, "report-" + permit.window.id + ".json"));
    // Complete no-overwrite reservation before any request. A reserved window is never reused, even after a crash.
    await publishProtocolPrivateJSON(join(directory, "attempt-" + permit.window.id + ".json"),
      { schemaVersion: 1, planSHA256: sha256, window: permit.window, keyID: permit.keyID, publicKeySHA256: permit.publicKeySHA256 });
    onActivation({ ...permit.window });
    const transport = new CommunityQueryTransport({ prepared, signer, fetchImplementation, clock, isEnabled: authorized });
    engineEntered = true;
    report = await runCommunityQuery({ journal, transport, window: permit.window, isAuthorized: authorized, clock, monotonic, signal: controller.signal });
    const accepted = report.storageHealthy && report.cleanupSucceeded && !report.pendingIO && report.pendingRecordNames.length === 0 &&
      report.skippedExistingRecordNames.length === 0 && (command === "cleanup" || report.protocolSucceeded);
    const result = { schemaVersion: 1, exitCode: accepted ? 0 : 3, status: accepted ? command === "cleanup" ? "cleanup_verified" : "protocol_verified" : "incomplete",
      scope: prepared.plan.scope, window: permit.window, ...report };
    await publishProtocolPrivateJSON(join(directory, "report-" + permit.window.id + ".json"), result);
    if (report.pendingIO) Object.defineProperty(result, "waitForSafeRelease", { value: async () => { await report.waitForSafeRelease(); journal.close(); } });
    return result;
  } catch (error) {
    const safe = error instanceof CommunityProtocolCLIError || error instanceof ProtocolJournalError || error instanceof CommunityProtocolError ? error : new CommunityProtocolCLIError();
    safe.protocolMayHaveStarted = engineEntered; throw safe;
  } finally {
    clearInterval(watcher); removeAbort?.();
    if (!engineEntered || report && !report.pendingIO) journal?.close();
  }
}

async function main() {
  const controller = new AbortController(), abort = () => controller.abort(); let watchdog;
  process.on("SIGINT", abort); process.on("SIGTERM", abort);
  try {
    const result = await communityQueryCommand(process.argv.slice(2), { signal: controller.signal, onActivation(window) {
      // Stop only this CLI process after the approved window plus a bounded drain grace. This is not proof of remote absence.
      watchdog = setTimeout(() => { process.stderr.write('{"status":"incomplete","errorCode":"CLI_DRAIN_DEADLINE"}\n'); process.exit(3); },
        Math.max(0, window.expiresAt - Date.now()) + 8000);
    } });
    process.stdout.write(JSON.stringify(result) + "\n"); process.exit(result.exitCode);
  } catch (error) {
    process.stderr.write(JSON.stringify({ status: error.protocolMayHaveStarted ? "incomplete" : "refused", errorCode: error.code ?? "CLI_CONFIGURATION" }) + "\n");
    process.exit(error.protocolMayHaveStarted ? 3 : 2);
  } finally { clearTimeout(watchdog); process.off("SIGINT", abort); process.off("SIGTERM", abort); }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
