import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { publicFixture, syntheticPublicKeyConfiguration, syntheticAvatarReceiptVault } from "./public-record-fixture.mjs";
import { avatarCodecs, avatarImage } from "./avatar-image-fixture.mjs";
import { AvatarNormalizer } from "../../src/avatar-normalizer.mjs";
import { CloudKitAvatarAssets } from "../../src/cloudkit-avatar-assets.mjs";
import { CloudKitAvatarRepository } from "../../src/cloudkit-avatar-repository.mjs";
import { CloudKitPublicRepository } from "../../src/public-record-repository.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint } from "../../src/public-registry-checkpoint.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { AvatarPolicyState } from "../../src/avatar-policy-state.mjs";
import { AvatarPublicationCoordinator } from "../../src/avatar-publication-coordinator.mjs";
import { digest } from "../../src/public-record-schema.mjs";

export async function avatarPublicationFixture(options = {}) {
  const f = await publicFixture(options), social = new CommunityState(f.storage, { clock: f.clock }), sourceBytes = await avatarImage();
  let session = await f.session(), enabled = true, operatorEnabled = true, assetHook, recordHook;
  const operatorID = randomUUID(), key = syntheticPublicKeyConfiguration(), grants = new Map(), assetCalls = [], uploadedBytes = new Map();
  const normalizer = new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => enabled });
  const assetFetch = async (request, opts) => {
    const phase = new URL(request.url).hostname === "api.apple-cloudkit.com" ? "grant" : "upload";
    let recordName, variant, payload;
    if (phase === "grant") {
      const body = await request.clone().json(); assert.equal(body.tokens.length, 1);
      ({ recordName, fieldName: variant } = body.tokens[0]); assert.equal(body.tokens[0].recordType, "EchoesAvatarV1");
      const url = "https://synthetic-avatar.icloud-content.com/upload/" + recordName + "/" + variant;
      grants.set(url, { recordName, variant }); payload = { tokens: [{ recordName, fieldName: variant, url }] };
    } else {
      ({ recordName, variant } = grants.get(request.url));
      const bytes = new Uint8Array(await request.clone().arrayBuffer());
      const transfer = f.db.prepare("SELECT * FROM avatar_asset_transfers_v1 WHERE record_name=? AND variant=?").get(recordName, variant);
      assert.equal(transfer.phase, "claimed"); assert.equal(transfer.content_sha256, digest(bytes));
      uploadedBytes.set(recordName + "/" + variant, bytes.slice());
      assert.deepEqual([...request.headers.keys()].sort(), ["cache-control", "content-type"]);
      payload = { singleFile: { fileChecksum: "SYNTHETIC-CHECKSUM-" + digest(bytes), size: bytes.length, receipt: "SYNTHETIC-PRIVATE-" + variant } };
    }
    const call = { phase, recordName, variant, request, signal: opts.signal }; assetCalls.push(call);
    return await assetHook?.(call) ?? Response.json(payload);
  };
  f.model.after = async call => {
    for (const record of f.model.records.values()) for (const variant of ["image", "thumbnail"]) {
      const v = record.fields[variant]?.value;
      if (v?.receipt) record.fields[variant].value = { fileChecksum: v.fileChecksum, size: v.size,
        downloadURL: "https://synthetic-avatar.icloud-content.com/private/" + record.recordName + "/" + variant + "?SYNTHETIC-URL" };
    }
    return await recordHook?.(call);
  };
  const make = (settings = {}) => {
    const registry = settings.registry ?? f.registry, checkpoint = registry === f.registry ? f.checkpoint : new PublicRegistryCheckpoint({ registry, client: f.client });
    const policy = new AvatarPolicyState(f.storage, { registry, clock: f.clock });
    const assets = new CloudKitAvatarAssets({ container: "iCloud.mpvEcho.Echo", environment: "development", keyID: key.CLOUDKIT_KEY_ID,
      privateKeyPEM: key.CLOUDKIT_PRIVATE_KEY, registry, checkpoint, clock: f.clock, receiptVault: syntheticAvatarReceiptVault(),
      verifiedUploadHosts: ["synthetic-avatar.icloud-content.com"], isEnabled: () => enabled, fetchImplementation: assetFetch });
    const avatars = new CloudKitAvatarRepository({ registry, checkpoint, assets, client: f.client, authentication: f.state, isEnabled: () => enabled });
    const profiles = new CloudKitPublicRepository({ registry, checkpoint, client: f.client, authentication: f.state, clock: f.clock });
    const coordinator = new AvatarPublicationCoordinator({ state: policy, authentication: f.state, communityState: social, normalizer,
      avatarRepository: avatars, profileRepository: profiles, checkpoint, isEnabled: () => enabled,
      authorizeOperator: Object.hasOwn(settings, "authorizeOperator") ? settings.authorizeOperator : () => operatorEnabled ? { operatorID, scope: "avatar-review" } : undefined });
    return { policy, coordinator, registry, checkpoint, profiles };
  };
  const initial = make();
  return { ...f, ...initial, social, sourceBytes, assetCalls, uploadedBytes, make, operatorID,
    get signedIn() { return session; },
    upload(changes = {}) { return { accessToken: session.sessionToken, requestID: randomUUID(), versionID: randomUUID(), bytes: sourceBytes,
      expectedGeneration: initial.policy.snapshot(session.accountID).generation, consentVersion: 1, ...changes }; },
    credentials(changes = {}) { return { accessToken: session.sessionToken, ...changes }; },
    review(status, verdict = "approved", changes = {}) { return { accountID: session.accountID, requestID: status.requestID, expectedRevision: status.reviewRevision, decisionID: randomUUID(), verdict, ...changes }; },
    async call(method, body, instance = initial) { const finalize = await instance.coordinator[method](body); await instance.checkpoint.advance(); return finalize(); },
    reopen() { return make({ registry: new PublicRecordRegistry(f.storage, { clock: f.clock }) }); },
    setAssetHook(value) { assetHook = value; }, setRecordHook(value) { recordHook = value; }, disable() { enabled = false; }, disableOperator() { operatorEnabled = false; },
    async erase(ticket) { const receipt = await f.erase(ticket); if (!receipt.remaining) { await social.eraseOwner(session.accountID); await f.checkpoint.advance(); } return receipt; },
    async relogin() { session = await f.session(); return session; },
    async nextLoginGeneration() { f.db.prepare("UPDATE auth_accounts_v1 SET generation=generation+1 WHERE account_id=?").run(session.accountID); session = await f.session(); return session; } };
}
