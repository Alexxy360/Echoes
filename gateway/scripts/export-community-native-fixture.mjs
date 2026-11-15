import assert from "node:assert/strict";
import { writeFile, mkdir } from "node:fs/promises";
import { randomBytes, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { publicFixture } from "../test/support/public-record-fixture.mjs";
import { hash } from "../test/support/authentication-fixture.mjs";
import { CommunityState } from "../src/community-state.mjs";
import { CommunityCoordinator } from "../src/community-coordinator.mjs";
import { createGatewayHTTPHandler } from "../src/gateway-http.mjs";
import { GatewayLimits } from "../src/gateway-limits.mjs";

// Offline, owned synthetic SQLite and signed protocol model only. Never exports any token or key.
const f = await publicFixture();
try {
  const a = await f.session(), b = await f.session("synthetic.reader"), coordinate = { latitude: 51.1123456, longitude: 17.0345678 };
  const community = new CommunityCoordinator({ state: new CommunityState(f.storage, { clock: f.clock }), authentication: f.state,
    repository: f.repository, cursorSecret: randomBytes(32).toString("base64url"), clock: f.clock });
  const handle = createGatewayHTTPHandler({ authentication: f.state, login: { login() {} }, renewal: { renew() {} }, sessionReset: { reset() {} },
    community, isCommunityEnabled: () => true, limits: new GatewayLimits(f.storage, { clock: f.clock }), checkpoint: f.checkpoint,
    scheduleMaintenance: async () => {}, isEnabled: () => true });
  const cases = [];
  async function run(action, body, session = a) {
    const response = await handle(new Request("https://echoes-authority.internal/v1/community/" + action, { method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + session.sessionToken }, body: JSON.stringify(body) }), hash(randomUUID()));
    assert.equal(response.status, 200);
    const value = await response.json(); cases.push({ action, request: body, response: value }); return value;
  }
  await run("config", {}); await run("visibility", {});
  await run("publish", { requestID: randomUUID(), name: "Maja", coordinate, song: "Echoes", songID: "1234", generation: 0, measuredAt: f.clock() });
  await run("nearby", { coordinate }, b);
  const sent = await run("send", { requestID: randomUUID(), name: "Maja", text: "Żółć i muzyka 🎵", coordinate });
  await run("messages", { coordinate, cursor: null, knownIDs: [sent.id] }, b);
  await run("report", { requestID: randomUUID(), messageID: sent.id, reason: "Sprawdź treść", coordinate }, b);
  await run("block/state", { accountID: b.accountID });
  await run("block", { requestID: randomUUID(), accountID: b.accountID, blocked: true, generation: 0 });
  await run("blocked", {});
  await run("profile", {});
  await run("profile/save", { requestID: randomUUID(), name: "Maja", revision: null });
  await run("profile", {});
  await run("stop", { requestID: randomUUID(), generation: 0 });
  const destination = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/", import.meta.url);
  await mkdir(destination, { recursive: true });
  const data = JSON.stringify({ version: 1, source: "Offline concrete gateway HTTP/coordinator/SQLite with signed synthetic CloudKit model; not provider acceptance", cases }, null, 2) + "\n";
  assert.ok(!data.includes(a.sessionToken) && !data.includes(b.sessionToken) && !data.includes("PRIVATE KEY"));
  await writeFile(new URL("community-roundtrip.json", destination), data);
  process.stdout.write(JSON.stringify({ cases: cases.length, path: fileURLToPath(new URL("community-roundtrip.json", destination)), realProviderCalls: 0 }) + "\n");
} finally { f.close(); }
