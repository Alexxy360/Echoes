import { mkdtemp, mkdir, writeFile, copyFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { build } from "esbuild";
const require = createRequire(import.meta.url), runtime = require("workerd");

export async function avatarWorker({ communityEntry = false, retentionEntry = false } = {}) {
  if (communityEntry && retentionEntry) throw new Error("Choose one synthetic worker entry");
  const directory = await mkdtemp(join(tmpdir(), "echoes-codec-workerd-"));
  let child, stderr = "";
  const stop = async () => {
    if (child && child.exitCode === null && child.signalCode === null) {
      const stopped = once(child, "exit"); child.kill("SIGTERM");
      const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
      try { await stopped; } finally { clearTimeout(timer); }
    }
    await rm(directory, { recursive: true, force: true });
  };
  try {
    const bundle = join(directory, "entry.mjs");
    await mkdir(join(directory, "state"));
    const entry = retentionEntry ? "./public-retention-worker.mjs" : communityEntry ? "./community-disabled-worker.mjs" : "./avatar-normalizer-worker.mjs";
    const objectClass = retentionEntry ? "RetentionProofAuthority" : communityEntry ? "CommunityAuthority" : "AvatarCodecTestAuthority";
    const objectBinding = retentionEntry ? "RETENTION" : communityEntry ? "COMMUNITY_AUTHORITY" : "CODEC";
    await build({ entryPoints: [new URL(entry, import.meta.url).pathname], outfile: bundle,
      bundle: true, format: "esm", platform: "node", target: "es2022", external: ["node:*", "cloudflare:*"],
      plugins: [{ name: "static-avatar-wasm", setup(builder) {
        builder.onResolve({ filter: /\.wasm$/ }, args => {
          const name = args.path === "@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm" ? "jpeg_decoder.wasm" :
            args.path === "jpeg-encoder-wasm/jpeg_encoder_bg.wasm" ? "jpeg_encoder.wasm" : undefined;
          if (!name) throw new Error("Unexpected Wasm dependency in local harness");
          return { path: name, external: true };
        });
      } }],
      logLevel: "silent", legalComments: "linked" });
    await copyFile(new URL("../../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm", import.meta.url), join(directory, "decoder.wasm"));
    await copyFile(new URL("../../node_modules/jpeg-encoder-wasm/pkg/esm/jpeg_encoder_bg.wasm", import.meta.url), join(directory, "encoder.wasm"));
    await writeFile(join(directory, "config.capnp"), `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
 services = [
  (name = "codec", worker = (
   modules = [
    (name = "entry.mjs", esModule = embed "entry.mjs"),
    (name = "jpeg_decoder.wasm", wasm = embed "decoder.wasm"),
    (name = "jpeg_encoder.wasm", wasm = embed "encoder.wasm")
   ], compatibilityDate = "2026-07-30", compatibilityFlags = ["nodejs_compat", "enable_request_signal"],
   globalOutbound = "deny", bindings = [(name = "${objectBinding}", durableObjectNamespace = "${objectClass}")],
   durableObjectNamespaces = [(className = "${objectClass}", uniqueKey = "echoes-synthetic-codec-test", enableSql = true)],
   durableObjectStorage = (localDisk = "storage")
  )),
  (name = "storage", disk = (path = ${JSON.stringify(join(directory, "state"))}, writable = true)),
  (name = "deny", network = (allow = [], deny = ["0.0.0.0/0", "::/0", "unix"]))
 ], sockets = [(name = "http", address = "127.0.0.1:0", http = (), service = "codec")]
);
`);
    child = spawn(runtime.default, ["serve", join(directory, "config.capnp"), "--experimental", "--control-fd=3"], { stdio: ["ignore", "ignore", "pipe", "pipe"] });
    child.stderr.on("data", bytes => { stderr = (stderr + bytes.toString()).slice(-8000); });
    let buffer = "";
    const port = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("workerd startup timeout: " + stderr)), 15000);
      const finish = action => value => { clearTimeout(timer); action(value); };
      child.once("error", finish(reject));
      child.once("exit", finish(() => reject(new Error("workerd startup exit: " + stderr))));
      child.stdio[3].on("data", bytes => {
        buffer += bytes.toString();
        while (buffer.includes("\n")) {
          const at = buffer.indexOf("\n"), line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
          try {
            const message = JSON.parse(line);
            if (message.event === "listen" && Number.isInteger(message.port) && message.port > 0 && message.port < 65536) finish(resolve)(message.port);
          } catch (error) { finish(reject)(error); }
        }
      });
    });
    return { origin: "http://127.0.0.1:" + port, directory, stop, version: runtime.version, compatibilityDate: runtime.compatibilityDate };
  } catch (error) { await stop(); throw error; }
}
