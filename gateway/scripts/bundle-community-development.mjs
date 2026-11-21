import { readFile, writeFile, copyFile, mkdtemp, readdir } from "node:fs/promises";
import { join, isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { build } from "esbuild";

const root = new URL("../", import.meta.url);
const wasm = new Map([
  ["@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm", { name: "jpeg_decoder.wasm", source: "node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm" }],
  ["jpeg-encoder-wasm/jpeg_encoder_bg.wasm", { name: "jpeg_encoder.wasm", source: "node_modules/jpeg-encoder-wasm/pkg/esm/jpeg_encoder_bg.wasm" }],
]);
/** Build the actual entry point, never the synthetic test entry. No credentials or network. */
export async function bundleCommunityDevelopment(parent) {
  if (typeof parent !== "string" || !isAbsolute(parent)) throw new Error("Absolute output parent required");
  const config = JSON.parse(await readFile(new URL("wrangler.community.jsonc", root), "utf8"));
  if (config.name !== "echoes-community-development" || config.main !== "src/community-worker.mjs" ||
      config.workers_dev !== false || config.preview_urls !== false || config.observability?.enabled !== false ||
      config.vars.GATEWAY_ENVIRONMENT !== "development" || config.vars.CLOUDKIT_ENVIRONMENT !== "development" ||
      Object.entries(config.vars).some(([name, value]) => typeof value !== "string" || name.endsWith("_ENABLED") && value !== "0")) {
    throw new Error("Only the reviewed inactive Development target can be packaged");
  }
  const directory = await mkdtemp(join(parent, "echoes-community-bundle-"));
  await build({ entryPoints: [fileURLToPath(new URL(config.main, root))], outfile: join(directory, "index.mjs"),
    bundle: true, format: "esm", platform: "node", target: "es2022", external: ["node:*", "cloudflare:*"],
    legalComments: "linked", logLevel: "silent", plugins: [{ name: "reviewed-static-avatar-wasm", setup(builder) {
      builder.onResolve({ filter: /\.wasm$/ }, args => {
        const asset = wasm.get(args.path);
        if (!asset) throw new Error("Unreviewed Wasm dependency");
        return { path: "./" + asset.name, external: true };
      });
    } }],
  });
  for (const asset of wasm.values()) await copyFile(new URL(asset.source, root), join(directory, asset.name));
  const noticeFiles = ["node_modules/@jsquash/jpeg/LICENSE", "node_modules/@jsquash/jpeg/codec/LICENSE.codec.md",
    "node_modules/jpeg-encoder-wasm/LICENSE-IJG", "node_modules/jpeg-encoder-wasm/LICENSE-APACHE", "node_modules/jpeg-encoder-wasm/LICENSE-MIT"];
  const notices = await Promise.all(noticeFiles.map(async name => name + "\n\n" + await readFile(new URL(name, root), "utf8")));
  await writeFile(join(directory, "THIRD_PARTY_NOTICES.txt"), notices.join("\n\n"));
  const metadata = { main_module: "index.mjs", compatibility_date: config.compatibility_date,
    compatibility_flags: config.compatibility_flags,
    bindings: [...Object.entries(config.vars).map(([name, text]) => ({ name, type: "plain_text", text })),
      { name: "COMMUNITY_AUTHORITY", type: "durable_object_namespace", class_name: "CommunityAuthority" }],
    migrations: { new_tag: "community-v1", new_sqlite_classes: ["CommunityAuthority"] }, observability: { enabled: false } };
  await writeFile(join(directory, "metadata.json"), JSON.stringify(metadata, null, 2) + "\n");
  const files = {};
  for (const name of (await readdir(directory)).sort()) {
    const bytes = await readFile(join(directory, name));
    files[name] = { bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
  }
  const report = { target: config.name, directory, inactive: true, deployed: false, networkRequests: 0,
    ordinaryAppCutover: false, modules: ["index.mjs", "jpeg_decoder.wasm", "jpeg_encoder.wasm"], files };
  await writeFile(join(directory, "manifest.json"), JSON.stringify(report, null, 2) + "\n");
  return report;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3) throw new Error("Provide an existing absolute output parent; packaging never deploys");
  console.log(JSON.stringify(await bundleCommunityDevelopment(process.argv[2]), null, 2));
}
