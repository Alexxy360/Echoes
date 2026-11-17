import assert from "node:assert/strict";
import { avatarPublicationFixture } from "./avatar-publication-fixture.mjs";
import { AvatarReviewCoordinator, avatarReviewHeader } from "../../src/avatar-review-coordinator.mjs";
import { AvatarReviewReceipts } from "../../src/avatar-review-state.mjs";

export async function avatarReviewFixture(options = {}) {
  const f = await avatarPublicationFixture(options), reviewer = await f.session("synthetic.moderator");
  const pending = await f.call("prepareUpload", f.upload()), downloads = [], controllers = [];
  const operators = new Set([reviewer.accountID]); let enabled = true, downloadHook;
  const receipts = new AvatarReviewReceipts(f.storage, { clock: f.clock });
  const configuration = { authentication: f.state, communityState: f.social, avatarPolicy: f.policy, receipts,
    registry: f.registry, client: f.client, checkpoint: f.checkpoint, clock: f.clock, isEnabled: () => enabled,
    isOperator: id => operators.has(id), verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"],
    fetchImplementation: async (request, context) => {
      downloads.push({ request, signal: context.signal });
      assert.equal(request.method, "GET"); assert.equal(request.redirect, "manual"); assert.equal(request.credentials, "omit");
      assert.deepEqual([...request.headers.keys()].sort(), ["accept", "cache-control"]);
      const override = await downloadHook?.({ request, signal: context.signal }); if (override) return override;
      const url = new URL(request.url); assert.equal(url.hostname, "synthetic-avatar.icloud-content.com");
      const bytes = f.uploadedBytes.get(url.pathname.slice("/private/".length)); assert.ok(bytes);
      return new Response(bytes.slice(), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(bytes.length) } });
    } };
  const coordinator = new AvatarReviewCoordinator(configuration);
  const input = (changes = {}) => {
    const controller = new AbortController(); controllers.push(controller);
    return { accessToken: reviewer.sessionToken, signal: controller.signal, ...changes };
  };
  const inspection = (changes = {}) => input({ accountID: f.signedIn.accountID, requestID: pending.requestID, ...changes });
  return { ...f, pending, reviewer, receipts, coordinator, configuration, downloads, operators, input, inspection,
    cancel(input) { const c = controllers.find(c => c.signal === input.signal); assert.ok(c); c.abort(); },
    disableReview() { enabled = false; }, setDownloadHook(value) { downloadHook = value; },
    makeReview(changes = {}) { return new AvatarReviewCoordinator({ ...configuration, ...changes }); },
    async reviewCall(method, body, instance = coordinator) {
      const finalize = await instance[method](body); await f.checkpoint.advance(); return finalize();
    },
    async inspect(changes = {}) { return this.reviewCall("prepareInspection", inspection(changes)); },
    reviewMetadata(response) { return JSON.parse(response.headers.get(avatarReviewHeader)); },
    close() { for (const c of controllers) c.abort(); f.close(); },
  };
}
