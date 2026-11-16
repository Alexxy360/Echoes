// Concrete offline runtime/HTTP/policy/SQL -> native response and JPEG fixture.
// Synthetic accounts, unregistered ephemeral keys and modeled Apple only; no real service IO.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { avatarHTTPFixture } from "../test/support/avatar-http-fixture.mjs";
const f = await avatarHTTPFixture({ runtime: true });
try {
  const cases = [];
  async function run(phase, action, body, session) {
    const response = await f.authority.handle(new Request("https://echoes-authority.internal/v1/community/" + action, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + session.sessionToken }, body: JSON.stringify(body)
    }), "a".repeat(64));
    assert.equal(response.status, 200);
    const value = await response.json();
    if (phase) cases.push({ phase, action, request: body, response: value });
    return value;
  }
  await run(null, "profile/save", { requestID: randomUUID(), name: "Maja", revision: null }, f.signedIn);
  await run(null, "send", { requestID: randomUUID(), name: "Maja", text: "Zdjęcie i muzyka 🎵", coordinate: f.coordinate }, f.signedIn);
  const image = await f.edge(); assert.equal(image.status, 200);
  const bytes = new Uint8Array(await image.arrayBuffer()), manifest = JSON.parse(image.headers.get("X-Echoes-Avatar-Manifest"));
  const hit = await f.edge({ knownSHA256: manifest.sha256 }); assert.equal(hit.status, 204);
  for (const phase of ["published", "cleared", "disabled"]) {
    if (phase === "cleared") {
      const finalize = await f.coordinator.prepareClear(f.credentials({ requestID: randomUUID(), expectedGeneration: f.policy.snapshot(f.signedIn.accountID).generation }));
      await f.checkpoint.advance(); finalize(); f.advance(3000);
    }
    if (phase === "disabled") { f.env.AVATAR_READ_ENABLED = "0"; f.advance(3000); }
    const profile = await run(phase, "profile", {}, f.signedIn);
    const nearby = await run(phase, "nearby", { coordinate: f.coordinate }, f.viewer);
    const messages = await run(phase, "messages", { coordinate: f.coordinate, cursor: null, knownIDs: [] }, f.viewer);
    for (const value of [profile.profile, nearby.users[0], messages.messages[0]]) {
      assert.ok(value);
      if (phase === "disabled") assert.equal(Object.hasOwn(value, "avatarVersionID"), false);
      else assert.equal(value.avatarVersionID, phase === "published" ? f.photo.versionID : null);
    }
  }
  const payload = JSON.stringify({ schemaVersion: 1, source: "Concrete local gateway runtime/HTTP/SQLite/policy; synthetic Apple/accounts/keys; real Wasm JPEG", ownerID: f.signedIn.accountID,
    versionID: f.photo.versionID, cases, downloaded: { status: image.status, headers: Object.fromEntries(image.headers) },
    revalidated: { status: hit.status, headers: Object.fromEntries(hit.headers) } }, null, 2) + "\n";
  for (const secret of [f.signedIn.sessionToken, f.viewer.sessionToken, "downloadURL", "SYNTHETIC-PRIVATE", "PRIVATE KEY", "receipt"]) assert.equal(payload.includes(secret), false);
  const destination = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/community-avatar/", import.meta.url);
  await mkdir(destination, { recursive: true });
  await writeFile(new URL("responses.json", destination), payload);
  await writeFile(new URL("thumbnail.jpg", destination), bytes);
  process.stdout.write(JSON.stringify({ cases: cases.length, thumbnailBytes: bytes.length, providerCalls: "modeled only", realUserData: false }) + "\n");
} finally { f.close(); }
