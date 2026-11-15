import { PublicRecordError, plain, publicUUID, fieldValues, matchesFields, validTag } from "./public-record-schema.mjs";

export const checkpointRecordName = "community-registry-checkpoint-v1";
export const checkpointRecordType = "EchoesRegistryCheckpointV1";
export function validCheckpoint(value) {
  return plain(value) && Object.keys(value).sort().join("|") === "anchorID|parentAnchorID|registeredCount|registryID|schemaVersion" &&
    value.schemaVersion === 1 && typeof value.registryID === "string" && publicUUID.test(value.registryID) &&
    typeof value.anchorID === "string" && publicUUID.test(value.anchorID) && typeof value.parentAnchorID === "string" &&
    (value.parentAnchorID === "" || publicUUID.test(value.parentAnchorID)) &&
    Number.isInteger(value.registeredCount) && value.registeredCount >= 0 && value.registeredCount <= 10000 &&
    (value.parentAnchorID !== "" || value.registeredCount === 0);
}
export function checkpointFields(value) {
  if (!validCheckpoint(value)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
  return fieldValues(value);
}
export function checkpointRecord(record) {
  if (!plain(record) || record.recordName !== checkpointRecordName || record.recordType !== checkpointRecordType ||
      record.serverErrorCode || !validTag(record.recordChangeTag) || !plain(record.fields)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
  const value = Object.fromEntries(Object.entries(record.fields).map(([key, field]) => [key, field?.value]));
  if (!validCheckpoint(value) || !matchesFields(record.fields, checkpointFields(value))) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
  return Object.freeze({ value: Object.freeze(value), tag: record.recordChangeTag });
}
export function sameCheckpoint(a, b) { return validCheckpoint(a) && validCheckpoint(b) && matchesFields(checkpointFields(a), checkpointFields(b)); }

/** A durable outbox, not a cached count. A missing/forked/rolled-back anchor never bootstraps itself. */
export class PublicRegistryCheckpoint {
  #registry; #client; #tail = Promise.resolve();
  constructor({ registry, client } = {}) {
    if (typeof registry?.checkpointState !== "function" || typeof registry.prepareCheckpoint !== "function" ||
        typeof client?.lookupCheckpoint !== "function" || typeof client.replaceCheckpoint !== "function") throw new PublicRecordError();
    this.#registry = registry; this.#client = client;
  }
  #check(signal) { if (signal?.aborted) throw new PublicRecordError(); }
  #serial(action, signal) {
    const result = this.#tail.then(async () => { this.#check(signal); return action(); });
    this.#tail = result.catch(() => {}); return result;
  }
  async #read(signal) {
    this.#check(signal);
    const record = await this.#client.lookupCheckpoint({ signal });
    this.#check(signal); return checkpointRecord(record);
  }
  async #validated(signal) {
    const remote = await this.#read(signal), local = await this.#registry.checkpointState();
    this.#check(signal);
    if (remote.value.registryID !== local.registryID) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    if (!local.confirmed) {
      if (!sameCheckpoint(remote.value, local.initial) || local.registeredCount !== 0 || local.pending) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
      await this.#registry.confirmInitialCheckpoint(remote); this.#check(signal); return remote;
    }
    if (local.pending && sameCheckpoint(remote.value, local.pending.value)) {
      await this.#registry.confirmPendingCheckpoint(local.pending, remote); this.#check(signal); return remote;
    }
    if (!sameCheckpoint(remote.value, local.confirmed.value) || remote.tag !== local.confirmed.tag) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    return remote;
  }
  async #publish(pending, signal) {
    this.#check(signal);
    let raw = await this.#client.replaceCheckpoint(pending.value, pending.expectedTag, { signal });
    this.#check(signal);
    // A duplicate conditional replace can lose to the original in-flight copy. Reconcile once.
    if (raw?.serverErrorCode === "CONFLICT") raw = await this.#client.lookupCheckpoint({ signal });
    const remote = checkpointRecord(raw);
    this.#check(signal);
    if (!sameCheckpoint(remote.value, pending.value)) throw new PublicRecordError("PUBLIC_REGISTRY_UNVERIFIED");
    await this.#registry.confirmPendingCheckpoint(pending, remote); this.#check(signal); return remote;
  }
  verify({ signal } = {}) { return this.#serial(() => this.#validated(signal), signal); }
  advance({ signal } = {}) {
    return this.#serial(async () => {
      await this.#validated(signal);
      let local = await this.#registry.checkpointState();
      if (local.pending) await this.#publish(local.pending, signal);
      // Always capture a NEW durable point after reconciling an older outbox. Current work may be newer.
      local = await this.#registry.checkpointState(); this.#check(signal);
      const pending = await this.#registry.prepareCheckpoint(local.confirmed);
      return this.#publish(pending, signal);
    }, signal);
  }
}
