import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { avatarPublicationFixture } from "./avatar-publication-fixture.mjs";
import { CommunityCoordinator } from "../../src/community-coordinator.mjs";
import { CloudKitAvatarReader } from "../../src/cloudkit-avatar-reader.mjs";

export async function avatarReadFixture(options = {}) {
  const f = await avatarPublicationFixture(options), viewer = await f.session("synthetic.reader");
  const coordinate = { latitude: 51.1123456, longitude: 17.0345678 }, downloads = [], controllers = [];
  const community = new CommunityCoordinator({ state: f.social, authentication: f.state, repository: f.repository,
    cursorSecret: randomBytes(32).toString("base64url"), clock: f.clock });
  let enabled = true, downloadHook;
  const callCommunity = async (session, action, body) => {
    const finalize = await community.prepare(action, body, { accessToken: session.sessionToken });
    await f.checkpoint.advance(); return finalize();
  };
  const pending = await f.call("prepareUpload", f.upload());
  await f.call("prepareReview", f.review(pending));
  const photo = await f.call("preparePublish", f.credentials({ requestID: pending.requestID }));
  const presenceBody = (changes = {}) => ({ requestID: randomUUID(), generation: 0, name: "Maja", coordinate, measuredAt: f.clock(), song: "", songID: "", ...changes });
  await callCommunity(f.signedIn, "publish", presenceBody());
  const downloadFetch = async (request, opts) => {
    downloads.push({ request, signal: opts.signal });
    assert.equal(request.method, "GET"); assert.equal(request.redirect, "manual"); assert.equal(request.credentials, "omit");
    assert.deepEqual([...request.headers.keys()].sort(), ["accept", "cache-control"]);
    const override = await downloadHook?.({ request, signal: opts.signal }); if (override) return override;
    const url = new URL(request.url); assert.equal(url.hostname, "synthetic-avatar.icloud-content.com");
    const bytes = f.uploadedBytes.get(url.pathname.slice("/private/".length)); assert.ok(bytes);
    return new Response(bytes.slice(), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length) } });
  };
  const configuration = { authentication: f.state, communityState: f.social, avatarPolicy: f.policy, profileRepository: f.profiles,
    registry: f.registry, client: f.client, checkpoint: f.checkpoint, isEnabled: () => enabled, clock: f.clock,
    verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"], fetchImplementation: downloadFetch };
  const reader = new CloudKitAvatarReader(configuration);
  const input = (changes = {}) => {
    const controller = new AbortController(); controllers.push(controller);
    return { accessToken: viewer.sessionToken, ownerID: f.signedIn.accountID, versionID: photo.versionID,
      variant: "thumbnail", coordinate: { ...coordinate }, signal: controller.signal, ...changes };
  };
  return { ...f, viewer, coordinate, photo, downloads, reader, configuration, input, callCommunity, presenceBody,
    makeReader(changes = {}) { return new CloudKitAvatarReader({ ...configuration, ...changes }); },
    setDownloadHook(value) { downloadHook = value; }, disableReader() { enabled = false; },
    async read(changes = {}, instance = reader) { const finalize = await instance.prepare(input(changes)); await f.checkpoint.advance(); return finalize(); },
    close() { for (const c of controllers) c.abort(); f.close(); } };
}
