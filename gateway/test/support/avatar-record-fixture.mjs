import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { publicFixture, syntheticPublicKeyConfiguration, syntheticAvatarReceiptVault } from "./public-record-fixture.mjs";
import { avatarCodecs, avatarImage } from "./avatar-image-fixture.mjs";
import { AvatarNormalizer, normalizedAvatarManifest } from "../../src/avatar-normalizer.mjs";
import { CloudKitAvatarAssets } from "../../src/cloudkit-avatar-assets.mjs";
import { CloudKitAvatarRepository } from "../../src/cloudkit-avatar-repository.mjs";
import { PublicRecordRegistry } from "../../src/public-record-registry.mjs";
import { PublicRegistryCheckpoint } from "../../src/public-registry-checkpoint.mjs";
import { digest, recordIdentity } from "../../src/public-record-schema.mjs";

/** Actual Wasm/SQLite/checkpoint/signatures with explicitly synthetic Apple assets and identity. */
export async function avatarRecordFixture(options = {}) {
  const f = await publicFixture(options), versionID = randomUUID(), requestID = randomUUID();
  let session = await f.session(), enabled = true, assetHook, recordHook;
  const normalized = await new AvatarNormalizer({ ...await avatarCodecs(), isEnabled: () => true }).prepare({
    bytes: await avatarImage(), versionID, requestID, authorize: () => f.state.authorize(session.sessionToken) });
  const descriptor = { requestID, image: normalizedAvatarManifest(normalized, "image"), thumbnail: normalizedAvatarManifest(normalized, "thumbnail") };
  const name = recordIdentity(session.accountID, "avatar", versionID).recordName, assetCalls = [], grants = new Map();
  const key = syntheticPublicKeyConfiguration();
  const fetchImplementation = async (request, requestOptions) => {
    const url = new URL(request.url), phase = url.hostname === "api.apple-cloudkit.com" ? "grant" : "upload";
    let variant, payload;
    if (phase === "grant") {
      assert.equal(url.pathname, "/database/1/iCloud.mpvEcho.Echo/development/public/assets/upload");
      const body = await request.clone().json(); assert.equal(body.tokens.length, 1);
      assert.equal(body.tokens[0].recordName, name); assert.equal(body.tokens[0].recordType, "EchoesAvatarV1");
      variant = body.tokens[0].fieldName; assert.ok(["image", "thumbnail"].includes(variant));
      const uploadURL = "https://synthetic-avatar.icloud-content.com/upload/" + variant;
      grants.set(uploadURL, variant);
      payload = { tokens: [{ recordName: name, fieldName: variant, url: uploadURL }] };
    } else {
      variant = grants.get(request.url); assert.ok(variant);
      const bytes = new Uint8Array(await request.clone().arrayBuffer());
      assert.equal(digest(bytes), descriptor[variant].sha256);
      assert.deepEqual([...request.headers.keys()].sort(), ["cache-control", "content-type"]);
      payload = { singleFile: { fileChecksum: "SYNTHETIC-CHECKSUM-" + digest(bytes), size: bytes.length,
        receipt: "SYNTHETIC-PRIVATE-RECEIPT-" + variant } };
    }
    const call = { phase, variant, request, signal: requestOptions.signal }; assetCalls.push(call);
    const override = await assetHook?.(call);
    return override ?? Response.json(payload);
  };
  f.model.after = async call => {
    // Model the fetch representation, which is different from the upload receipt.
    for (const record of f.model.records.values()) for (const variant of ["image", "thumbnail"]) {
      const value = record.fields[variant]?.value;
      if (value?.receipt) record.fields[variant].value = { fileChecksum: value.fileChecksum, size: value.size,
        downloadURL: "https://synthetic-avatar.icloud-content.com/private/" + variant + "?token=SYNTHETIC-DOWNLOAD" };
    }
    return await recordHook?.(call);
  };
  const make = (registry = f.registry) => {
    const checkpoint = registry === f.registry ? f.checkpoint : new PublicRegistryCheckpoint({ registry, client: f.client });
    const assets = new CloudKitAvatarAssets({ container: "iCloud.mpvEcho.Echo", environment: "development",
      keyID: key.CLOUDKIT_KEY_ID, privateKeyPEM: key.CLOUDKIT_PRIVATE_KEY, registry, checkpoint,
      receiptVault: syntheticAvatarReceiptVault(), clock: f.clock, isEnabled: () => enabled,
      verifiedUploadHosts: ["synthetic-avatar.icloud-content.com"], fetchImplementation });
    return new CloudKitAvatarRepository({ registry, checkpoint, assets, client: f.client, authentication: f.state, isEnabled: () => enabled });
  };
  return { ...f, versionID, requestID, normalized, descriptor, name, assetCalls, make,
    get signedIn() { return session; },
    input(changes = {}) { return { accessToken: session.sessionToken, normalized, requestID,
      authorizeMutation: () => f.state.authorize(session.sessionToken), ...changes }; },
    recovery(changes = {}) { return { accessToken: session.sessionToken, descriptor: structuredClone(descriptor),
      authorizeMutation: () => f.state.authorize(session.sessionToken), ...changes }; },
    setAssetHook(value) { assetHook = value; }, setRecordHook(value) { recordHook = value; }, disable() { enabled = false; },
    reopen() { return make(new PublicRecordRegistry(f.storage, { clock: f.clock })); },
    async nextLoginGeneration() {
      f.db.prepare("UPDATE auth_accounts_v1 SET generation=generation+1 WHERE account_id=?").run(session.accountID);
      session = await f.session(); return session;
    } };
}
