import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";
import { avatarPublicationFixture } from "./support/avatar-publication-fixture.mjs";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { validAvatarPublicationIntent } from "../src/avatar-publication-intent.mjs";
import { avatarMutationInput } from "../src/avatar-upload-http.mjs";

const code = value => error => error?.code === value;
const selected = () => ({ requestID: randomUUID(), versionID: randomUUID(), generation: 1, reviewRevision: randomUUID(), consentVersion: 1 });
async function approved(f) {
  const staged = await f.call("prepareUpload", f.upload());
  await f.call("prepareReview", f.review(staged));
  return f.policy.snapshot(f.signedIn.accountID);
}

test("publication input binds one closed image, generation, review revision and explicit consent", () => {
  const value = selected();
  assert.deepEqual(avatarMutationInput("publish", value), value);
  for (const field of Object.keys(value)) {
    const missing = { ...value }; delete missing[field];
    assert.equal(validAvatarPublicationIntent(missing), false);
    assert.throws(() => avatarMutationInput("publish", missing), code("AVATAR_INPUT"));
  }
  for (const changes of [{ accountID: randomUUID() }, { receipt: "private" }, { consentVersion: 0 }, { consentVersion: true },
    { generation: 0 }, { generation: -1 }, { generation: 1.5 }, { generation: Number.MAX_SAFE_INTEGER },
    { generation: "1" }, { versionID: "bad" }, { reviewRevision: "ABCDEF00-0000-4000-8000-000000000001" }]) {
    assert.equal(validAvatarPublicationIntent({ ...value, ...changes }), false);
    assert.throws(() => avatarMutationInput("publish", { ...value, ...changes }), code("AVATAR_INPUT"));
  }
});

test("request-only publication is rejected by concrete runtime rather than upgraded to latest approval", async () => {
  const f = await avatarUploadHTTPFixture({ runtime: true });
  try {
    const upload = await f.edge("upload"); assert.equal(upload.status, 200);
    const staged = await upload.json();
    const finalize = await f.coordinator.prepareReview(f.review(staged));
    await f.checkpoint.advance(); finalize();
    const value = f.body("publish"), response = await f.edge("publish", {}, { rawBody: JSON.stringify({ requestID: value.requestID }) });
    assert.equal(response.status, 400); assert.equal((await response.json()).error, "AVATAR_INPUT");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "approved");
  } finally { f.close(); }
});

test("old approved revision cannot publish after a second approval of the same image", async () => {
  const f = await avatarPublicationFixture();
  try {
    const first = await approved(f), choice = f.publication(first), assetCalls = f.assetCalls.length;
    await f.call("prepareReview", f.review(first));
    const latest = f.policy.snapshot(f.signedIn.accountID);
    assert.notEqual(latest.reviewRevision, choice.reviewRevision);
    await assert.rejects(() => f.call("preparePublish", f.credentials(choice)), code("AVATAR_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
    const published = await f.call("preparePublish", f.credentials(f.publication(latest)));
    assert.equal(published.status, "published"); assert.equal(published.versionID, choice.versionID);
    assert.equal(f.assetCalls.length, assetCalls);
  } finally { f.close(); }
});

test("a mismatched request, version or generation cannot write the owner's pointer", async () => {
  const f = await avatarPublicationFixture();
  try {
    const choice = f.publication(await approved(f));
    for (const changes of [{ requestID: randomUUID() }, { versionID: randomUUID() }, { generation: choice.generation + 1 }]) {
      await assert.rejects(() => f.call("preparePublish", f.credentials({ ...choice, ...changes })), code("AVATAR_STALE"));
      assert.ok(!f.registry.owned(f.signedIn.accountID, "avatarprofile", "singleton"));
      assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "approved");
    }
  } finally { f.close(); }
});

test("an approval changed during checkpoint verification cannot silently replace the user's choice", async () => {
  const f = await avatarPublicationFixture();
  try {
    const first = await approved(f), choice = f.publication(first);
    const verify = f.checkpoint.verify.bind(f.checkpoint); let changed = false;
    f.checkpoint.verify = async options => {
      await verify(options);
      if (!changed) { changed = true; await f.call("prepareReview", f.review(first)); }
    };
    await assert.rejects(() => f.call("preparePublish", f.credentials(choice)), code("AVATAR_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "approved");
    assert.notEqual(f.policy.snapshot(f.signedIn.accountID).reviewRevision, choice.reviewRevision);
  } finally { f.close(); }
});

test("reapproval hides a published image until a new exact author choice, without new JPEG uploads", async () => {
  const f = await avatarPublicationFixture();
  try {
    const initial = await approved(f), choice = f.publication(initial), assets = f.assetCalls.length;
    await f.call("preparePublish", f.credentials(choice));
    await f.call("prepareReview", f.review(initial));
    const current = f.policy.snapshot(f.signedIn.accountID);
    assert.equal(current.status, "approved"); assert.equal(current.publishedVersionID, null);
    await assert.rejects(() => f.call("preparePublish", f.credentials(choice)), code("AVATAR_STALE"));
    assert.equal((await f.call("preparePublish", f.credentials(f.publication(current)), f.reopen())).status, "published");
    assert.equal(f.assetCalls.length, assets);
  } finally { f.close(); }
});

test("a publication result cannot claim success after a later moderation decision", async () => {
  const f = await avatarPublicationFixture();
  try {
    const current = await approved(f);
    const finalize = await f.coordinator.preparePublish(f.credentials(f.publication(current)));
    await f.call("prepareReview", f.review(current, "rejected"));
    assert.throws(finalize, code("AVATAR_STALE"));
    assert.equal(f.policy.snapshot(f.signedIn.accountID).status, "rejected");
    assert.equal(f.policy.snapshot(f.signedIn.accountID).publishedVersionID, null);
  } finally { f.close(); }
});

test("retrying the same exact choice is idempotent and never retransmits image assets", async () => {
  const f = await avatarPublicationFixture();
  try {
    const choice = f.credentials(f.publication(await approved(f))), count = f.assetCalls.length;
    const first = await f.call("preparePublish", choice);
    assert.deepEqual(await f.call("preparePublish", choice, f.reopen()), first);
    assert.equal(f.assetCalls.length, count);
  } finally { f.close(); }
});
