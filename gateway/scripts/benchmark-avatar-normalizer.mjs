import { AvatarNormalizer, normalizedAvatarManifest } from "../src/avatar-normalizer.mjs";
import { avatarCodecs, avatarImage } from "../test/support/avatar-image-fixture.mjs";
import { avatarWorker } from "../test/support/workerd-image-harness.mjs";
const ids = { versionID: "64000000-0000-4000-8000-000000000002", requestID: "64000000-0000-4000-8000-000000000003",
  authorize: () => ({ accountID: "64000000-0000-4000-8000-000000000001" }) };
const stats = values => {
  const sorted = [...values].sort((a, b) => a - b);
  return { minimum: sorted[0], median: sorted[Math.floor(sorted.length / 2)], maximum: sorted.at(-1) };
};
const report = { node: process.version, samplesPerCorpus: 20, nodeCorpora: [],
  note: "Local evidence only. Node CPU includes process/background compilation. Fixture encoding preinitializes the Rust encoder. workerd values are HTTP wall time, not hosted CPU, quotas or billing." };
for (const [name, options] of [["gradient256", {}], ["noise512", { width: 512, height: 512, noise: true }]]) {
  const bytes = await avatarImage(options), n = new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => true });
  const rows = []; let manifest;
  for (let i = 0; i < 20; i++) {
    const cpu = process.cpuUsage(), start = performance.now();
    const result = await n.prepare({ ...ids, bytes });
    const used = process.cpuUsage(cpu); rows.push({ wall: performance.now() - start, cpu: (used.user + used.system) / 1000 });
    manifest = normalizedAvatarManifest(result, "image");
  }
  report.nodeCorpora.push({ name, inputBytes: bytes.length, outputBytes: manifest.byteCount, sha256: manifest.sha256,
    first: rows[0], warmedWallMilliseconds: stats(rows.slice(1).map(row => row.wall)), warmedProcessCPUMilliseconds: stats(rows.slice(1).map(row => row.cpu)) });
}
const worker = await avatarWorker();
try {
  const bytes = await avatarImage({ width: 512, height: 512, noise: true }), rows = [];
  for (let i = 0; i < 20; i++) {
    const start = performance.now();
    const response = await fetch(worker.origin, { method: "POST", body: bytes, headers: { Connection: "close" } });
    const result = await response.json();
    if (response.status !== 200 || result.image?.sha256 !== report.nodeCorpora[1].sha256 || !result.sqlAvailable) throw new Error("Local codec benchmark failed");
    rows.push(performance.now() - start);
  }
  report.workerd = { version: worker.version, compatibilityDate: worker.compatibilityDate, sqlite: true, outbound: "denied IPv4/IPv6/Unix",
    firstHTTPWallMilliseconds: rows[0], warmedHTTPWallMilliseconds: stats(rows.slice(1)) };
} finally { await worker.stop(); }
console.log(JSON.stringify(report, null, 2));
