import { PublicRecordError, plain, matchesFields, fieldValues, validTag } from "./public-record-schema.mjs";
import { avatarReportCancellationFields } from "./avatar-report-cancellation.mjs";
import { expiredPublicFields } from "./public-retention-policy.mjs";

function fenceFields(lease) {
  return lease.cancellationKey === undefined ? expiredPublicFields(lease.context) : avatarReportCancellationFields(lease.context, lease.cancellationKey);
}
function providerFailure(record) {
  return new PublicRecordError(["EXISTS", "CONFLICT", "NOT_FOUND"].includes(record?.serverErrorCode) ? "PUBLIC_CONFLICT" :
    record?.serverErrorCode === "THROTTLED" ? "PUBLIC_THROTTLED" : "PUBLIC_UNAVAILABLE");
}
function recordsFor(value, leases) {
  if (!(value instanceof Map) || value.size !== leases.length || [...value.keys()].some(name =>
    !leases.some(lease => lease.context.recordName === name)) || [...value].some(([name, record]) =>
      !plain(record) || record.recordName !== name)) throw new PublicRecordError("PUBLIC_RESPONSE");
  return value;
}
function scopedRecord(record, context) {
  if (!plain(record) || record.recordName !== context.recordName || record.recordType !== context.recordType ||
      !validTag(record.recordChangeTag) || !plain(record.fields) || record.deleted) throw new PublicRecordError("PUBLIC_SCOPE");
}

/** Internal only, disabled by default. Erases content through exact CAS fences, never arbitrary names. */
export class CloudKitPublicRetentionProcessor {
  #registry; #client; #checkpoint; #enabled; #clock; #timeout; #occupied = false;
  constructor({ registry, client, checkpoint, isEnabled = () => false, clock = Date.now, timeoutMilliseconds = 8000 } = {}) {
    if (["claimExpiredRecords", "assertRetentionCurrent", "completeRetention"].some(name => typeof registry?.[name] !== "function") ||
        ["lookup", "modify", "waitForPendingOperations"].some(name => typeof client?.[name] !== "function") ||
        ["verify", "advance", "waitForPendingOperations"].some(name => typeof checkpoint?.[name] !== "function") ||
        typeof isEnabled !== "function" || typeof clock !== "function" || !Number.isInteger(timeoutMilliseconds) ||
        timeoutMilliseconds < 1 || timeoutMilliseconds > 8000) throw new PublicRecordError("PUBLIC_INPUT");
    this.#registry = registry; this.#client = client; this.#checkpoint = checkpoint;
    this.#enabled = isEnabled; this.#clock = clock; this.#timeout = timeoutMilliseconds;
  }
  get isOccupied() { return this.#occupied; }
  #now() { let now; try { now = this.#clock(); } catch { throw new PublicRecordError(); }
    if (!Number.isSafeInteger(now) || now < 0) throw new PublicRecordError(); return now; }
  async step(options = {}) {
    if (!plain(options) || Object.keys(options).some(key => !["maximumRecords", "signal"].includes(key)) ||
        options.signal !== undefined && !(options.signal instanceof AbortSignal)) throw new PublicRecordError("PUBLIC_INPUT");
    const { maximumRecords = 25, signal } = options;
    if (!Number.isInteger(maximumRecords) || maximumRecords < 1 || maximumRecords > 25) throw new PublicRecordError("PUBLIC_INPUT");
    if (this.#occupied) throw new PublicRecordError("PUBLIC_LIMIT");
    const started = this.#now(), expires = started + this.#timeout;
    if (!Number.isSafeInteger(expires)) throw new PublicRecordError();
    this.#occupied = true;
    let closed = false, settled = false, draining = false, workStarted = false, timer, rejectCancellation;
    const controller = new AbortController(), cancellation = new Promise((_, reject) => { rejectCancellation = reject; });
    const release = () => {
      if (!closed || !settled || draining) return;
      draining = true;
      void (async () => {
        try {
          await this.#checkpoint.waitForPendingOperations();
          await this.#client.waitForPendingOperations();
          this.#occupied = false;
        } catch { /* Missing drain evidence keeps this instance closed to more work. */ }
      })();
    };
    const dispose = () => { closed = true; clearTimeout(timer); controller.abort(); signal?.removeEventListener("abort", cancel); release(); };
    const cancel = () => { dispose(); rejectCancellation(new PublicRecordError()); };
    const check = () => {
      const now = this.#now();
      if (closed || controller.signal.aborted || signal?.aborted || this.#enabled() !== true || now < started || now >= expires) throw new PublicRecordError();
    };
    const current = lease => { check(); return this.#registry.assertRetentionCurrent(lease); };
    try {
      check(); timer = setTimeout(cancel, this.#timeout); signal?.addEventListener("abort", cancel, { once: true });
      workStarted = true;
      const work = (async () => {
        await this.#checkpoint.verify({ signal: controller.signal }); check();
        const leases = await this.#registry.claimExpiredRecords(maximumRecords); check();
        if (!Array.isArray(leases) || leases.length > maximumRecords || new Set(leases.map(lease => lease?.context?.recordName)).size !== leases.length) throw new PublicRecordError("PUBLIC_RESPONSE");
        leases.forEach(current);
        await this.#checkpoint.advance({ signal: controller.signal }); check(); leases.forEach(current);
        if (!leases.length) return Object.freeze({ processed: 0 });
        const found = recordsFor(await this.#client.lookup(leases.map(lease => lease.context.recordName),
          { metadataOnly: true, signal: controller.signal }), leases);
        check(); leases.forEach(current);
        const operations = leases.map(lease => {
          const context = current(lease), record = found.get(context.recordName), fields = fenceFields(lease);
          if (record?.serverErrorCode === "NOT_FOUND") return { operationType: "create", record: {
            recordName: context.recordName, recordType: context.recordType, fields } };
          if (record?.serverErrorCode) throw providerFailure(record);
          scopedRecord(record, context);
          const liveMetadata = fieldValues({ schemaVersion: 1, ownerKey: context.ownerKey, erased: 0 });
          if (!matchesFields(record.fields, liveMetadata) && !matchesFields(record.fields, fields) &&
              !(lease.cancellationKey !== undefined && matchesFields(record.fields, expiredPublicFields(context)))) throw new PublicRecordError("PUBLIC_SCOPE");
          return { operationType: "replace", record: { recordName: context.recordName,
            recordType: context.recordType, recordChangeTag: record.recordChangeTag, fields } };
        });
        check(); leases.forEach(current);
        const results = recordsFor(await this.#client.modify(operations, { signal: controller.signal }), leases);
        check(); leases.forEach(current);
        let failure; const verified = [];
        for (const lease of leases) {
          const context = current(lease), record = results.get(context.recordName);
          if (record?.serverErrorCode) { failure ??= providerFailure(record); continue; }
          scopedRecord(record, context);
          if (!matchesFields(record.fields, fenceFields(lease))) throw new PublicRecordError("PUBLIC_RESPONSE");
          verified.push({ lease, tag: record.recordChangeTag });
        }
        for (const { lease, tag } of verified) {
          current(lease); await this.#registry.completeRetention(lease, tag); check();
        }
        await this.#checkpoint.advance({ signal: controller.signal }); check();
        if (failure) throw failure;
        return Object.freeze({ processed: verified.length });
      })();
      void work.then(() => { settled = true; release(); }, () => { settled = true; release(); });
      return await Promise.race([work, cancellation]);
    } catch (error) { throw error instanceof PublicRecordError ? error : new PublicRecordError(); }
    finally { dispose(); if (!workStarted) { settled = true; release(); } }
  }
}
