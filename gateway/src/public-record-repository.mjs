import { PublicRecordError, recordIdentity, normalizePublicInput, inputHash, liveFields, erasedFields,
  matchesFields, plain } from "./public-record-schema.mjs";

function providerFailure(record) {
  if (["EXISTS", "CONFLICT", "NOT_FOUND"].includes(record?.serverErrorCode)) return new PublicRecordError("PUBLIC_CONFLICT");
  return new PublicRecordError(record?.serverErrorCode === "THROTTLED" ? "PUBLIC_THROTTLED" : "PUBLIC_UNAVAILABLE");
}
function checkScope(record, context) {
  if (!plain(record) || record.recordName !== context.recordName || record.recordType !== context.recordType ||
      record.fields?.schemaVersion?.value !== 1 || record.fields?.ownerKey?.value !== context.ownerKey ||
      ![0, 1].includes(record.fields?.erased?.value)) throw new PublicRecordError("PUBLIC_SCOPE");
}
/** Only trusted coordinators call this repository. No arbitrary-record HTTP methods are exposed. */
export class CloudKitPublicRepository {
  #registry; #client; #authentication; #clock; #checkpoint;
  constructor({ registry, client, authentication, checkpoint, clock = Date.now } = {}) {
    if (typeof registry?.reserve !== "function" || typeof client?.modify !== "function" || typeof client.lookup !== "function" ||
        typeof authentication?.authorize !== "function" || typeof checkpoint?.verify !== "function" ||
        typeof checkpoint.advance !== "function" || typeof clock !== "function") throw new PublicRecordError();
    this.#registry = registry; this.#client = client; this.#authentication = authentication; this.#clock = clock; this.#checkpoint = checkpoint;
  }
  prepareBootstrap() { return this.#registry.prepareBootstrap(); }
  #check(signal) { if (signal?.aborted) throw new PublicRecordError(); }
  #authorize(accessToken, expectedID) {
    const identity = this.#authentication.authorize(accessToken);
    if (expectedID !== undefined && identity.accountID !== expectedID) throw new PublicRecordError("PUBLIC_SCOPE");
    return identity;
  }
  async write({ accessToken, kind, logicalID, requestID, input, expectedTag = null, signal } = {}) {
    this.#check(signal);
    const identity = this.#authorize(accessToken), fields = normalizePublicInput(kind, input, this.#clock());
    if (["message", "report"].includes(kind) && (logicalID !== requestID || expectedTag !== null) ||
        kind === "block" && logicalID !== fields.targetID) throw new PublicRecordError("PUBLIC_INPUT");
    await this.#checkpoint.verify({ signal });
    const context = await this.#registry.reserve({ accountID: identity.accountID, kind, logicalID,
      requestID, payloadHash: inputHash(fields), expectedTag });
    this.#check(signal); this.#authorize(accessToken, context.accountID);
    await this.#checkpoint.advance({ signal });
    this.#check(signal); this.#authorize(accessToken, context.accountID);
    const current = this.#registry.assertMutationCurrent(context), expectedFields = liveFields(context, fields);
    if (current.phase === "settled") return this.#receipt(current, expectedFields);
    const operation = { operationType: expectedTag === null ? "create" : "replace", record: {
      recordName: context.recordName, recordType: context.recordType, fields: expectedFields,
      ...(expectedTag === null ? {} : { recordChangeTag: expectedTag }) } };
    let record = (await this.#client.modify([operation], { signal })).get(context.recordName);
    this.#check(signal);
    if (["EXISTS", "CONFLICT"].includes(record?.serverErrorCode)) {
      // Explicit retry of the SAME immutable operation may reconcile an already committed write.
      record = (await this.#client.lookup([context.recordName], { signal })).get(context.recordName);
    }
    if (record?.serverErrorCode) throw providerFailure(record);
    checkScope(record, context);
    if (!matchesFields(record.fields, expectedFields)) throw new PublicRecordError("PUBLIC_CONFLICT");
    const saved = await this.#registry.settle(context, record.recordChangeTag);
    await this.#checkpoint.advance({ signal });
    this.#check(signal); this.#authorize(accessToken, saved.accountID);
    return this.#receipt(this.#registry.assertMutationCurrent(saved), expectedFields);
  }
  #receipt(context, fields) {
    return Object.freeze({ recordName: context.recordName, recordType: context.recordType,
      recordChangeTag: context.recordTag, fields });
  }
  async erasePublicDataBatch({ accountID, deletionID, leaseID, maximumRecords = 100, signal } = {}) {
    const context = { accountID, deletionID, leaseID };
    this.#check(signal);
    await this.#checkpoint.verify({ signal });
    const batch = await this.#registry.erasureBatch(context, maximumRecords);
    await this.#checkpoint.advance({ signal });
    this.#check(signal);
    const succeeded = new Map(), operations = [];
    if (batch.length) {
      const records = await this.#client.lookup(batch.map(row => row.recordName), { metadataOnly: true, signal });
      this.#check(signal); this.#registry.assertErasureCurrent(context);
      for (const row of batch) {
        const found = records.get(row.recordName), fields = erasedFields(row, deletionID);
        if (found?.serverErrorCode === "NOT_FOUND") {
          // Fence a reserved-but-not-yet-visible CREATE before declaring its content erased.
          operations.push({ operationType: "create", record: { recordName: row.recordName, recordType: row.recordType, fields } });
        } else {
          if (found?.serverErrorCode) throw providerFailure(found);
          checkScope(found, row);
          if (found.fields.erased.value === 1 && !matchesFields(found.fields, fields)) throw new PublicRecordError("PUBLIC_SCOPE");
          // Replace even an existing fence: metadata-only lookup cannot prove absence of extra content.
          operations.push({ operationType: "replace", record: { recordName: row.recordName,
            recordType: row.recordType, recordChangeTag: found.recordChangeTag, fields } });
        }
      }
    }
    let failure;
    if (operations.length) {
      const results = await this.#client.modify(operations, { signal });
      this.#check(signal); this.#registry.assertErasureCurrent(context);
      for (const operation of operations) {
        const result = results.get(operation.record.recordName);
        if (result?.serverErrorCode) { failure ??= providerFailure(result); continue; }
        const row = batch.find(item => item.recordName === result?.recordName);
        if (!row) throw new PublicRecordError("PUBLIC_RESPONSE");
        checkScope(result, row);
        if (!matchesFields(result.fields, erasedFields(row, deletionID))) throw new PublicRecordError("PUBLIC_RESPONSE");
        succeeded.set(row.recordName, result.recordChangeTag);
      }
    }
    const receipt = await this.#registry.completeErasure(context, succeeded);
    await this.#checkpoint.advance({ signal });
    this.#registry.assertErasureCurrent(context);
    this.#check(signal);
    if (failure) throw failure;
    return receipt;
  }
}
