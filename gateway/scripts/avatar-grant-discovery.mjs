import { createPrivateKey, createPublicKey, randomUUID } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { plain, publicUUID, digest, recordIdentity } from "../src/public-record-schema.mjs";
import { queryCanonical } from "./community-query-plan.mjs";
import { readProtocolPrivateFile, ensureProtocolParent, publishProtocolPrivateJSON, requireProtocolFileAbsent } from "./community-protocol-files.mjs";

const codes = new Set(["GRANT_CONFIGURATION", "GRANT_DISABLED", "GRANT_INVENTORY", "GRANT_PERMIT", "GRANT_KEY", "GRANT_WINDOW",
  "GRANT_CLOCK", "GRANT_CANCELLED", "GRANT_RESPONSE", "GRANT_IO", "GRANT_PRIVATE_FILE"]);
export class AvatarGrantDiscoveryError extends Error {
  constructor(code = "GRANT_CONFIGURATION") { super("Development asset grant discovery refused or incomplete."); this.code = codes.has(code) ? code : "GRANT_CONFIGURATION"; }
}
const fail = code => { throw new AvatarGrantDiscoveryError(code); };
// Permanently retired diagnostic identity, not an activation/deployment credential.
const retiredDiagnosticKey = Object.freeze({
  keyID: "0663e7ddc1124c0522589f5db7d0786c19f80c35ac158199db561f6e79a80919",
  publicKeySHA256: "8c42a2a2bcfc81ebff8ef0838923f84654ccf8dc8401777d9c26f51766e68b11",
});
const keys = (value, names) => plain(value) && Object.keys(value).sort().join() === [...names].sort().join();
const hash = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const readJSON = (path, limit) => {
  try { const file = readProtocolPrivateFile(path, limit); return { ...file, value: JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(file.bytes)) }; }
  catch { fail("GRANT_PRIVATE_FILE"); }
};
const uuid = (runID, label) => {
  const h = digest("echoes/avatar-grant-discovery/v1\0" + runID + "\0" + label).slice(0, 32);
  return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join("-");
};

export function makeAvatarGrantDiscovery(runID = randomUUID()) {
  if (!publicUUID.test(runID ?? "")) fail("GRANT_INVENTORY");
  const identity = recordIdentity(uuid(runID, "account"), "avatar", uuid(runID, "version"));
  const plan = { schemaVersion: 1, purpose: "echoes-avatar-grant-discovery-development-v1", runID,
    scope: { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development", database: "public",
      reviewedSchemaSHA256: "495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543" },
    request: { tokens: ["image", "thumbnail"].map(fieldName => ({ recordName: identity.recordName, recordType: identity.recordType, fieldName })) },
    limits: { requests: 1, responseBytes: 16384, chunks: 64, milliseconds: 8000, maximumWindowMilliseconds: 1800000 },
    uploads: false, recordWrites: false, followReturnedURLs: false };
  return { plan, sha256: digest(queryCanonical(plan)) };
}
export function verifyAvatarGrantDiscovery(prepared) {
  if (!keys(prepared, ["plan", "sha256"]) || !hash(prepared.sha256)) fail("GRANT_INVENTORY");
  const expected = makeAvatarGrantDiscovery(prepared.plan?.runID);
  if (expected.sha256 !== prepared.sha256 || queryCanonical(expected.plan) !== queryCanonical(prepared.plan)) fail("GRANT_INVENTORY");
  return expected;
}

/** A sanitized result only. Provider URLs are never returned, persisted, opened or logged. */
export function discoveredAvatarUploadHosts(prepared, body) {
  const { plan } = verifyAvatarGrantDiscovery(prepared);
  if (!keys(body, ["tokens"]) || !Array.isArray(body.tokens) || body.tokens.length !== 2) fail("GRANT_RESPONSE");
  const found = new Map();
  for (const token of body.tokens) {
    if (!keys(token, ["recordName", "fieldName", "url"]) || token.recordName !== plan.request.tokens[0].recordName ||
        !["image", "thumbnail"].includes(token.fieldName) || found.has(token.fieldName) || typeof token.url !== "string" ||
        token.url.length > 8192 || /[^\x21-\x7e]/.test(token.url)) fail("GRANT_RESPONSE");
    let url; try { url = new URL(token.url); } catch { fail("GRANT_RESPONSE"); }
    if (url.protocol !== "https:" || url.port || url.username || url.password || url.hash || url.href !== token.url ||
        url.hostname.length > 253 || !/^[a-z0-9]+(?:[.-][a-z0-9]+)*$/.test(url.hostname) ||
        !["icloud-content.com", "icloud.com", "apple-cloudkit.com"].some(domain => url.hostname.endsWith("." + domain))) fail("GRANT_RESPONSE");
    found.set(token.fieldName, url.hostname);
  }
  return { fields: Object.fromEntries(["image", "thumbnail"].map(field => [field, found.get(field)])),
    exactHosts: [...new Set(found.values())].sort(), uploadRequests: 0, recordWrites: 0 };
}

async function boundedGrantJSON(response, signal, check) {
  let reader, cancellation, abort;
  try {
    check();
    if (!(response instanceof Response) || response.status !== 200 || response.redirected ||
        !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") || !response.body) fail("GRANT_RESPONSE");
    const length = response.headers.get("Content-Length");
    if (length !== null && (!/^\d+$/.test(length) || Number(length) > 16384)) fail("GRANT_RESPONSE");
    reader = response.body.getReader();
    const cancel = () => cancellation ??= reader.cancel();
    abort = () => { void cancel().catch(() => {}); }; signal.addEventListener("abort", abort, { once: true });
    const parts = []; let size = 0;
    while (true) {
      check(); const { value, done } = await reader.read(); if (done) break;
      if (!(value instanceof Uint8Array) || parts.length >= 64 || (size += value.byteLength) > 16384) fail("GRANT_RESPONSE");
      parts.push(value);
    }
    check(); if (length !== null && Number(length) !== size) fail("GRANT_RESPONSE");
    const bytes = new Uint8Array(size); let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); } catch { fail("GRANT_RESPONSE"); }
  } finally {
    if (reader) { signal.removeEventListener("abort", abort); try { await (cancellation ?? reader.cancel()); } finally { reader.releaseLock(); } }
    else if (response?.body) await response.body.cancel();
  }
}

/** Local operator tool. Never a server endpoint, uploader or general CloudKit client. */
export async function avatarGrantDiscoveryCommand(args, { env = process.env, clock = Date.now, monotonic = () => performance.now(),
  fetchImplementation = fetch, signal, onActivation = () => {} } = {}) {
  let mayHaveStarted = false, watcher, timer, removeAbort;
  try {
    if (!Array.isArray(args) || args.some(value => typeof value !== "string")) fail();
    const [command, directory, sha256, permitPath, keyPath] = args;
    if (command === "prepare" && args.length === 2) {
      await ensureProtocolParent(directory);
      const runDirectory = await mkdtemp(join(directory, "echoes-avatar-grants-")), prepared = makeAvatarGrantDiscovery();
      await publishProtocolPrivateJSON(join(runDirectory, "inventory.json"), prepared);
      return { status: "prepared", exitCode: 0, directory: runDirectory, planSHA256: prepared.sha256, scope: prepared.plan.scope,
        tokens: 2, networkRequests: 0, uploads: false, recordWrites: false };
    }
    if (!(command === "inspect" && args.length === 3 || command === "run" && args.length === 5) || !hash(sha256)) fail();
    if (command === "run" && env.ECHOES_ALLOW_ASSET_GRANTS_DEV !== "1") fail("GRANT_DISABLED");
    await ensureProtocolParent(directory);
    const prepared = verifyAvatarGrantDiscovery(readJSON(join(directory, "inventory.json"), 8192).value);
    if (prepared.sha256 !== sha256) fail("GRANT_INVENTORY");
    if (command === "inspect") return { status: "inspected", exitCode: 0, planSHA256: sha256, scope: prepared.plan.scope,
      tokens: 2, networkRequests: 0, uploads: false, recordWrites: false };
    const original = readJSON(permitPath, 8192), permit = original.value, now = clock(), firstMono = monotonic();
    if (!keys(permit, ["schemaVersion", "purpose", "planSHA256", "scope", "window", "keyID", "publicKeySHA256", "identityModel"]) ||
        permit.schemaVersion !== 1 || permit.purpose !== prepared.plan.purpose || permit.planSHA256 !== sha256 ||
        queryCanonical(permit.scope) !== queryCanonical(prepared.plan.scope) || permit.identityModel !== "individual-owner-administrator-v1" ||
        !keys(permit.window, ["id", "issuedAt", "expiresAt"]) || !publicUUID.test(permit.window.id ?? "") ||
        !Number.isSafeInteger(now) || !Number.isFinite(firstMono) || !Number.isSafeInteger(permit.window.issuedAt) || permit.window.issuedAt < 0 ||
        !Number.isSafeInteger(permit.window.expiresAt) || permit.window.expiresAt <= permit.window.issuedAt ||
        permit.window.expiresAt - permit.window.issuedAt > 1800000 || now < permit.window.issuedAt || now >= permit.window.expiresAt ||
        typeof permit.keyID !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(permit.keyID) || permit.keyID === retiredDiagnosticKey.keyID ||
        !hash(permit.publicKeySHA256) || permit.publicKeySHA256 === retiredDiagnosticKey.publicKeySHA256) fail("GRANT_PERMIT");
    let signer; const privateKey = readProtocolPrivateFile(keyPath, 8192);
    try {
      const pem = new TextDecoder("utf-8", { fatal: true }).decode(privateKey.bytes), key = createPrivateKey(pem);
      if (digest(createPublicKey(key).export({ type: "spki", format: "der" })) !== permit.publicKeySHA256) fail("GRANT_KEY");
      signer = new CloudKitDevelopmentSigner({ container: prepared.plan.scope.container, environment: "development", keyID: permit.keyID, privateKeyPEM: pem });
    } catch { fail("GRANT_KEY"); } finally { privateKey.bytes.fill(0); }
    const controller = new AbortController(), abort = () => controller.abort(); let floorWall = now, floorMono = firstMono;
    const check = () => {
      if (signal?.aborted || controller.signal.aborted) fail("GRANT_CANCELLED");
      const wall = clock(), mono = monotonic();
      if (!Number.isSafeInteger(wall) || !Number.isFinite(mono) || wall < floorWall || mono < floorMono) fail("GRANT_CLOCK");
      floorWall = wall; floorMono = mono;
      if (wall >= permit.window.expiresAt || mono - firstMono >= permit.window.expiresAt - now) fail("GRANT_WINDOW");
      const current = readProtocolPrivateFile(permitPath, 8192);
      if (env.ECHOES_ALLOW_ASSET_GRANTS_DEV !== "1" || current.sha256 !== original.sha256 || current.identity !== original.identity) fail("GRANT_PERMIT");
    };
    check(); requireProtocolFileAbsent(join(directory, "report.json"));
    // One reservation for this inventory, independent of window ID. It is never reset or reused.
    await publishProtocolPrivateJSON(join(directory, "attempt.json"), { schemaVersion: 1, planSHA256: sha256,
      window: permit.window, keyID: permit.keyID, publicKeySHA256: permit.publicKeySHA256 });
    signal?.addEventListener("abort", abort, { once: true }); removeAbort = () => signal?.removeEventListener("abort", abort);
    watcher = setInterval(() => { try { check(); } catch { controller.abort(); } }, 250); watcher.unref();
    mayHaveStarted = true; onActivation(permit.window); check();
    timer = setTimeout(abort, Math.min(8000, permit.window.expiresAt - floorWall));
    const operationMono = monotonic(), operationWall = clock();
    const transportCheck = () => { check(); if (clock() - operationWall >= 8000 || monotonic() - operationMono >= 8000) fail("GRANT_CANCELLED"); };
    const request = signer.request("assets/upload", prepared.plan.request, new Date(floorWall));
    if (request.url !== "https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload" ||
        request.method !== "POST" || request.redirect !== "manual") fail();
    transportCheck();
    const response = await fetchImplementation(request, { signal: controller.signal });
    const body = await boundedGrantJSON(response, controller.signal, transportCheck); transportCheck();
    const result = { status: "hosts_discovered", exitCode: 0, planSHA256: sha256, scope: prepared.plan.scope, window: permit.window,
      networkRequests: 1, ...discoveredAvatarUploadHosts(prepared, body) };
    await publishProtocolPrivateJSON(join(directory, "report.json"), result);
    return result;
  } catch (error) {
    const safe = error instanceof AvatarGrantDiscoveryError ? error : new AvatarGrantDiscoveryError(mayHaveStarted ? "GRANT_IO" : "GRANT_PRIVATE_FILE");
    safe.requestMayHaveStarted = mayHaveStarted; throw safe;
  } finally { clearInterval(watcher); clearTimeout(timer); removeAbort?.(); }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const controller = new AbortController(), abort = () => controller.abort(); let watchdog;
  process.on("SIGINT", abort); process.on("SIGTERM", abort);
  try {
    const result = await avatarGrantDiscoveryCommand(process.argv.slice(2), { signal: controller.signal, onActivation(window) {
      watchdog = setTimeout(() => { process.stderr.write('{"status":"incomplete","errorCode":"GRANT_CANCELLED"}\n'); process.exit(3); },
        Math.max(0, Math.min(8000, window.expiresAt - Date.now())) + 8000);
    } });
    process.stdout.write(JSON.stringify(result) + "\n"); process.exit(result.exitCode);
  } catch (error) {
    process.stderr.write(JSON.stringify({ status: error.requestMayHaveStarted ? "incomplete" : "refused", errorCode: error.code }) + "\n");
    process.exit(error.requestMayHaveStarted ? 3 : 2);
  } finally { clearTimeout(watchdog); process.off("SIGINT", abort); process.off("SIGTERM", abort); }
}
