import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createHash } from "node:crypto";
import { bundleCommunityDevelopment } from "../scripts/bundle-community-development.mjs";
const runtime = createRequire(import.meta.url)("workerd");

test("actual inactive deployment bundle loads its static Wasm modules in workerd and refuses community operations", async t => {
  const parent = await mkdtemp(join(tmpdir(), "echoes-deployment-proof-"));
  let child;
  t.after(async () => {
    if (child && child.exitCode === null && child.signalCode === null) {
      const done = once(child, "exit"); child.kill("SIGTERM");
      const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
      try { await done; } finally { clearTimeout(timer); }
    }
    await rm(parent, { recursive: true, force: true });
  });
  const report = await bundleCommunityDevelopment(parent), directory = report.directory;
  for (const [name, expected] of Object.entries(report.files)) {
    const bytes = await readFile(join(directory, name));
    assert.equal(bytes.length, expected.bytes);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), expected.sha256);
  }
  const metadata = JSON.parse(await readFile(join(directory, "metadata.json"), "utf8"));
  assert.equal(report.inactive, true); assert.equal(report.deployed, false);
  assert.equal(metadata.main_module, "index.mjs");
  assert.deepEqual(metadata.migrations, { new_tag: "community-v1", new_sqlite_classes: ["CommunityAuthority"] });
  assert.equal(metadata.bindings.some(item => item.type === "secret_text"), false);
  assert.equal(metadata.bindings.find(item => item.name === "GATEWAY_ENABLED").text, "0");
  await mkdir(join(directory, "state"));
  // Only model the platform's HTTPS URL. The packaged production module is unchanged.
  await writeFile(join(directory, "verify.mjs"), 'import worker from "./index.mjs"; export { CommunityAuthority } from "./index.mjs"; export default { fetch(request, env, ctx) { const url = new URL(request.url); return worker.fetch(new Request("https://synthetic-disabled.invalid" + url.pathname + url.search, request), env, ctx); } };');
  await writeFile(join(directory, "verify.capnp"), `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (services = [
 (name = "worker", worker = (modules = [
  (name = "verify.mjs", esModule = embed "verify.mjs"),
  (name = "index.mjs", esModule = embed "index.mjs"),
  (name = "jpeg_decoder.wasm", wasm = embed "jpeg_decoder.wasm"),
  (name = "jpeg_encoder.wasm", wasm = embed "jpeg_encoder.wasm")
 ], compatibilityDate = "2026-07-30", compatibilityFlags = ["nodejs_compat", "enable_request_signal"], globalOutbound = "deny",
 bindings = [(name = "COMMUNITY_AUTHORITY", durableObjectNamespace = "CommunityAuthority")],
 durableObjectNamespaces = [(className = "CommunityAuthority", uniqueKey = "echoes-deployment-proof", enableSql = true)],
 durableObjectStorage = (localDisk = "storage"))),
 (name = "storage", disk = (path = ${JSON.stringify(join(directory, "state"))}, writable = true)),
 (name = "deny", network = (allow = [], deny = ["0.0.0.0/0", "::/0", "unix"]))
], sockets = [(name = "http", address = "127.0.0.1:0", http = (), service = "worker")]);`);
  child = spawn(runtime.default, ["serve", join(directory, "verify.capnp"), "--experimental", "--control-fd=3"], { stdio: ["ignore", "ignore", "pipe", "pipe"] });
  let stderr = "", control = "";
  child.stderr.on("data", bytes => { stderr = (stderr + bytes.toString()).slice(-4000); });
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("local workerd did not start: " + stderr)), 15000);
    child.once("error", error => { clearTimeout(timer); reject(error); });
    child.once("exit", () => { clearTimeout(timer); reject(new Error("local workerd exited: " + stderr)); });
    child.stdio[3].on("data", bytes => { control += bytes; while (control.includes("\n")) { const at = control.indexOf("\n"), line = control.slice(0, at); control = control.slice(at + 1); try { const value = JSON.parse(line); if (value.event === "listen" && Number.isInteger(value.port) && value.port > 0 && value.port < 65536) { clearTimeout(timer); resolve(value.port); } } catch (error) { clearTimeout(timer); reject(error); } } });
  });
  const origin = "http://127.0.0.1:" + port;
  const health = await fetch(origin + "/health"); assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { protocolVersion: 1, status: "ok", mode: "development-gateway" });
  const denied = await fetch(origin + "/v1/community/nearby", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
  assert.equal(denied.status, 503); assert.deepEqual(await denied.json(), { protocolVersion: 1, error: "GATEWAY_DISABLED" });
});
