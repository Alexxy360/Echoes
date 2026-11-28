import { PublicRecordError, plain, publicUUID } from "./public-record-schema.mjs";
import { normalizedAvatarManifest, normalizedAvatarUpload, normalizedAvatarPayloadHash } from "./avatar-normalizer.mjs";
import { avatarDescriptor, avatarDescriptorHash, avatarMetadata, validateAvatarRecord } from "./avatar-record-schema.mjs";

function failure(record) {
  return new PublicRecordError(["EXISTS", "CONFLICT", "NOT_FOUND"].includes(record?.serverErrorCode) ? "PUBLIC_CONFLICT" :
    record?.serverErrorCode === "THROTTLED" ? "PUBLIC_THROTTLED" : "PUBLIC_UNAVAILABLE");
}
/** Internal immutable version staging, NOT profile publication or a generic HTTP/asset proxy.
 * Trust boundary: a real normalized handle for initial writes; exact existing commitments for recovery.
 */
export class CloudKitAvatarRepository {
  #registry; #client; #assets; #checkpoint; #authentication; #enabled;
  constructor({ registry, client, assets, checkpoint, authentication, isEnabled } = {}) {
    if (["reserve", "owned", "assertMutationCurrent", "avatarAssetCommitments", "avatarTransferStatus", "settle", "expireAvatarReceipts"].some(key => typeof registry?.[key] !== "function") ||
        typeof client?.lookup !== "function" || typeof client.modify !== "function" || typeof assets?.upload !== "function" ||
        typeof assets.resumedRecordField !== "function" || typeof checkpoint?.verify !== "function" || typeof checkpoint.advance !== "function" ||
        typeof authentication?.authorize !== "function" || typeof isEnabled !== "function") throw new PublicRecordError("PUBLIC_INPUT");
    this.#registry = registry; this.#client = client; this.#assets = assets; this.#checkpoint = checkpoint;
    this.#authentication = authentication; this.#enabled = isEnabled;
  }
  #options(value, names) {
    if (!plain(value) || Object.keys(value).some(key => !names.includes(key)) || typeof value.authorizeMutation !== "function" ||
        value.signal !== undefined && !(value.signal instanceof AbortSignal)) throw new PublicRecordError("PUBLIC_INPUT");
    return Object.freeze({ ...value });
  }
  #permit(options, expectedID) {
    if (options.signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
    try {
      const identity = this.#authentication.authorize(options.accessToken), policy = options.authorizeMutation();
      if (policy && typeof policy.then === "function") { void policy.catch?.(() => {}); throw new PublicRecordError("PUBLIC_SCOPE"); }
      if (typeof identity?.accountID !== "string" || !publicUUID.test(identity.accountID) || policy?.accountID !== identity.accountID ||
          expectedID !== undefined && identity.accountID !== expectedID ||
          this.#authentication.authorize(options.accessToken).accountID !== identity.accountID) throw new PublicRecordError("PUBLIC_SCOPE");
      if (options.signal?.aborted || this.#enabled() !== true) throw new PublicRecordError();
      return identity;
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError("PUBLIC_SCOPE"); }
  }
  #current(options, context) {
    this.#permit(options, context.accountID);
    return this.#registry.assertMutationCurrent(context);
  }
  #commitments(context, descriptor) {
    const values = this.#registry.avatarAssetCommitments(context);
    for (const variant of ["image", "thumbnail"]) {
      if (values[variant].sha256 !== descriptor[variant].sha256 || values[variant].byteCount !== descriptor[variant].byteCount) throw new PublicRecordError("PUBLIC_SCOPE");
    }
    return values;
  }
  #record(record, context, descriptor) {
    return validateAvatarRecord(record, context, descriptor, this.#commitments(context, descriptor)).tag;
  }
  async #lookup(options, context, descriptor) {
    this.#current(options, context);
    const record = (await this.#client.lookup([context.recordName], { signal: options.signal })).get(context.recordName);
    const current = this.#current(options, context);
    if (record?.serverErrorCode === "NOT_FOUND") return null;
    if (record?.serverErrorCode) throw failure(record);
    return this.#record(record, current, descriptor);
  }
  async #complete(options, context, descriptor, tag) {
    this.#current(options, context); this.#commitments(context, descriptor);
    const settled = await this.#registry.settle(context, tag);
    this.#current(options, settled);
    await this.#checkpoint.advance({ signal: options.signal });
    const final = this.#current(options, settled);
    if (final.phase !== "settled" || final.recordTag !== tag) throw new PublicRecordError("PUBLIC_CONFLICT");
    return Object.freeze({ schemaVersion: 1, ownerID: context.accountID, versionID: descriptor.image.versionID,
      requestID: descriptor.requestID, recordChangeTag: tag, status: "staged", image: descriptor.image, thumbnail: descriptor.thumbnail });
  }
  async #create(options, context, descriptor) {
    this.#current(options, context); this.#commitments(context, descriptor);
    // Reconfirm the durable boundary BEFORE exposing receipts to the record builder.
    await this.#checkpoint.advance({ signal: options.signal }); this.#current(options, context);
    const authorizeMutation = () => this.#permit(options, context.accountID);
    const fields = avatarMetadata(context, descriptor);
    for (const variant of ["image", "thumbnail"]) {
      const field = this.#assets.resumedRecordField({ context, variant, authorizeMutation, signal: options.signal });
      // Apple's upload example uses a value-only Asset dictionary. Keep our internal ASSET
      // marker out of the optional Web Services wire-type enum; the installed schema defines it.
      fields[variant] = { value: field.value };
    }
    this.#current(options, context);
    const response = (await this.#client.modify([{ operationType: "create", record: {
      recordName: context.recordName, recordType: context.recordType, fields } }], { signal: options.signal })).get(context.recordName);
    this.#current(options, context);
    if (response?.serverErrorCode && !["EXISTS", "CONFLICT"].includes(response.serverErrorCode)) throw failure(response);
    // A modify echo may contain upload receipts instead of fetched Asset dictionaries.
    // Always confirm an exact fetched record before settling or returning a safe receipt.
    const tag = await this.#lookup(options, context, descriptor);
    if (tag === null) throw new PublicRecordError("PUBLIC_PENDING");
    return this.#complete(options, context, descriptor, tag);
  }
  async #prepare(options, descriptor, accountID, recover) {
    await this.#checkpoint.verify({ signal: options.signal }); this.#permit(options, accountID);
    if (recover) {
      const known = this.#registry.owned(accountID, "avatar", descriptor.image.versionID);
      if (!known || known.requestID !== descriptor.requestID || known.payloadHash !== avatarDescriptorHash(descriptor) || known.expectedTag !== null) throw new PublicRecordError("PUBLIC_SCOPE");
    }
    const context = await this.#registry.reserve({ accountID, kind: "avatar", logicalID: descriptor.image.versionID,
      requestID: descriptor.requestID, payloadHash: avatarDescriptorHash(descriptor) });
    this.#current(options, context);
    await this.#registry.expireAvatarReceipts(); this.#current(options, context);
    await this.#checkpoint.advance({ signal: options.signal }); this.#current(options, context);
    return context;
  }
  async stage(value = {}) {
    try {
      const options = this.#options(value, ["accessToken", "normalized", "requestID", "authorizeMutation", "signal"]);
      const { accountID } = this.#permit(options);
      const descriptor = avatarDescriptor({ image: normalizedAvatarManifest(options.normalized, "image"),
        thumbnail: normalizedAvatarManifest(options.normalized, "thumbnail"), requestID: options.requestID }, accountID);
      if (avatarDescriptorHash(descriptor) !== normalizedAvatarPayloadHash(options.normalized)) throw new PublicRecordError("PUBLIC_SCOPE");
      const context = await this.#prepare(options, descriptor, accountID, false);
      const tag = await this.#lookup(options, context, descriptor);
      if (tag !== null) return await this.#complete(options, context, descriptor, tag);
      if (context.phase === "settled") throw new PublicRecordError("PUBLIC_CONFLICT");
      const missing = [];
      for (const variant of ["image", "thumbnail"]) {
        const status = this.#registry.avatarTransferStatus(context, variant);
        if (!status) { missing.push(variant); continue; }
        if (status.phase !== "acknowledged") throw new PublicRecordError("PUBLIC_PENDING");
        if (status.sha256 !== descriptor[variant].sha256 || status.byteCount !== descriptor[variant].byteCount) throw new PublicRecordError("PUBLIC_SCOPE");
        this.#assets.resumedRecordField({ context, variant, authorizeMutation: () => this.#permit(options, accountID), signal: options.signal });
      }
      for (const variant of missing) {
        this.#current(options, context);
        await this.#assets.upload({ context, variant, ...normalizedAvatarUpload(options.normalized, context, variant),
          authorizeMutation: () => this.#permit(options, accountID), signal: options.signal });
        this.#current(options, context);
      }
      return await this.#create(options, context, descriptor);
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
  async recover(value = {}) {
    try {
      const options = this.#options(value, ["accessToken", "descriptor", "authorizeMutation", "signal"]);
      const { accountID } = this.#permit(options), descriptor = avatarDescriptor(options.descriptor, accountID);
      const context = await this.#prepare(options, descriptor, accountID, true);
      const tag = await this.#lookup(options, context, descriptor);
      if (tag !== null) return await this.#complete(options, context, descriptor, tag);
      if (context.phase === "settled") throw new PublicRecordError("PUBLIC_CONFLICT");
      // Only the already acknowledged, unexpired encrypted receipts may retry CREATE.
      // No source bytes, new reservation, grant, upload, replace or force operation here.
      return await this.#create(options, context, descriptor);
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
  }
}
