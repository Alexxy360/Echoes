// Non-secret metadata for the first SQLite deployment through Cloudflare's official upload API.
// Generates JSON only: it never reads credentials, performs network I/O, or activates the probe.
const metadata = {
  main_module: "worker.js",
  compatibility_date: "2026-11-13",
  compatibility_flags: ["nodejs_compat"],
  bindings: [
    { name: "PROBE_ENABLED", type: "plain_text", text: "0" },
    { name: "PROBE_LOCAL_CHECK_ONLY", type: "plain_text", text: "0" },
    { name: "CLOUDKIT_CONTAINER", type: "plain_text", text: "iCloud.mpvEcho.Echo" },
    { name: "CLOUDKIT_ENVIRONMENT", type: "plain_text", text: "development" },
    { name: "PROBE_RUN_ID", type: "plain_text", text: "" },
    { name: "PROBE_EXPIRES_AT", type: "plain_text", text: "" },
    { name: "DEVELOPMENT_PROBE", type: "durable_object_namespace", class_name: "DevelopmentProbe" },
  ],
  migrations: { new_tag: "v1", new_sqlite_classes: ["DevelopmentProbe"] },
  observability: { enabled: false },
};
process.stdout.write(JSON.stringify(metadata, null, 2) + "\n");
