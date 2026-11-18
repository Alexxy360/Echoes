import assert from "node:assert/strict";
import { avatarHTTPFixture } from "./avatar-http-fixture.mjs";
import { CloudKitAvatarOwnerPreview } from "../../src/cloudkit-avatar-owner-preview.mjs";
import { createGatewayHTTPHandler } from "../../src/gateway-http.mjs";
import { createGatewayRuntime, forwardGatewayRequest, handleAuthorityRequest, authorityName } from "../../src/gateway-runtime.mjs";
import { avatarOwnerPreviewPath } from "../../src/avatar-owner-preview-http.mjs";

export async function avatarOwnerPreviewFixture({ runtime = false, ...settings } = {}) {
  const f = await avatarHTTPFixture();
  // Reapproval removes ready/pointer publication. Only the staged approved asset remains readable to its owner.
  const reviewed = await f.coordinator.prepareReview(f.review(f.policy.snapshot(f.signedIn.accountID)));
  await f.checkpoint.advance(); reviewed();
  const current = f.policy.snapshot(f.signedIn.accountID);
  assert.equal(current.status, "approved"); assert.equal(current.publishedVersionID, null);
  let feature = true, prepared = false, afterAdvance;
  const counts = { prepares: 0, finalChecks: 0, verifies: 0, accounts: 0, budgets: 0 };
  const preview = new CloudKitAvatarOwnerPreview({ ...f.configuration, isEnabled: () => feature });
  const deps = { ...f.dependencies,
    isAvatarOwnerPreviewEnabled: () => feature,
    avatarOwnerPreview: { async prepare(input) { counts.prepares++; const final = await preview.prepare(input); prepared = true;
      return Object.assign(() => final(), { validate() { counts.finalChecks++; return final.validate(); } }); } },
    limits: { async consume(...args) { counts.budgets++; return f.limits.consume(...args); },
      async consumeAvatarRead(...args) { counts.accounts++; return f.limits.consumeAvatarRead(...args); } },
    checkpoint: { async verify(...args) { counts.verifies++; return f.checkpoint.verify(...args); },
      async advance(...args) { await f.checkpoint.advance(...args); if (prepared) await afterAdvance?.(); } }, ...settings };
  f.env.AVATAR_READ_ENABLED = "0"; f.env.AVATAR_OWNER_PREVIEW_ENABLED = "1";
  const options = { clock: f.clock, fetchImplementation: f.provider };
  const authority = runtime ? createGatewayRuntime(f.storage, f.env, options) : { handle: createGatewayHTTPHandler(deps) };
  const id = { toString: () => "synthetic-owner-preview-authority" }, forwarded = [];
  f.env.COMMUNITY_AUTHORITY = { idFromName(name) { assert.equal(name, authorityName); return id; }, get(object) {
    assert.equal(object, id); return { fetch(request) { forwarded.push(request); return handleAuthorityRequest(request, { runtime: authority, env: f.env, objectID: id, clock: f.clock }); } };
  } };
  const body = (changes = {}) => ({ requestID: current.requestID, versionID: current.versionID, generation: current.generation, reviewRevision: current.reviewRevision, ...changes });
  const request = (changes = {}, options = {}) => {
    const raw = options.rawBody ?? JSON.stringify(body(changes));
    return new Request("https://echoes-authority.internal" + avatarOwnerPreviewPath, { method: options.method ?? "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + (options.token ?? f.signedIn.sessionToken), ...options.headers }, body: raw,
      ...(raw instanceof ReadableStream ? { duplex: "half" } : {}), ...(options.signal ? { signal: options.signal } : {}) });
  };
  return { ...f, current, preview, dependencies: deps, authority, forwarded, body, request,
    selection(changes = {}) { return { ...body(changes), accessToken: f.signedIn.sessionToken }; },
    call(changes = {}, options = {}) { prepared = false; return authority.handle(request(changes, options), options.budget ?? "e".repeat(64)); },
    edge(changes = {}, options = {}) { const r = request(changes, { ...options, headers: { "CF-Connecting-IP": "192.0.2.17", ...options.headers } });
      Object.defineProperty(r, "cf", { value: { colo: "WAW" } }); return forwardGatewayRequest(r, f.env, { clock: f.clock }); },
    setFeature(value) { feature = value; }, afterPreviewAdvance(action) { afterAdvance = action; }, counts() { return { ...counts }; }
  };
}
