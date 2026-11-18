import { PublicRecordError, recordIdentity, normalizePublicInput, inputHash, liveFields, erasedFields,
  matchesFields, plain } from "./public-record-schema.mjs";
import { communityPolicy } from "./community-domain.mjs";
import { publicRetentionDeadline, expiredPublicFields } from "./public-retention-policy.mjs";

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
  writeLatest(value) {
    if (!["presence", "block", "avatarprofile"].includes(value?.kind) || typeof value.authorizeMutation !== "function") throw new PublicRecordError("PUBLIC_INPUT");
    return this.#write(value, true);
  }
  write(value) { return this.#write(value, false); }
  async #write({ accessToken, kind, logicalID, requestID, input, expectedTag = null, signal, authorizeMutation = () => {} } = {}, latest) {
    this.#check(signal);
    if (typeof authorizeMutation !== "function") throw new PublicRecordError("PUBLIC_INPUT");
    const permit = () => { this.#check(signal); authorizeMutation(); };
    permit();
    const identity = this.#authorize(accessToken), fields = normalizePublicInput(kind, input, this.#clock());
    if (["message", "report"].includes(kind) && (logicalID !== requestID || expectedTag !== null) ||
        kind === "block" && logicalID !== fields.targetID) throw new PublicRecordError("PUBLIC_INPUT");
    await this.#checkpoint.verify({ signal });
    permit(); this.#authorize(accessToken, identity.accountID);
    if (latest) {
      const known = this.#registry.owned(identity.accountID, kind, logicalID);
      const name = recordIdentity(identity.accountID, kind, logicalID).recordName;
      const found = (await this.#client.lookup([name], { signal })).get(name);
      permit(); this.#authorize(accessToken, identity.accountID);
      if (found?.serverErrorCode === "NOT_FOUND") expectedTag = null;
      else {
        if (found?.serverErrorCode) throw providerFailure(found);
        if (!known) throw new PublicRecordError("PUBLIC_SCOPE");
        checkScope(found, known);
        if (found.fields.erased.value !== 0 && !(kind === "presence" &&
            this.#registry.isConfirmedRetentionFence(known, found.recordChangeTag) &&
            matchesFields(found.fields, expiredPublicFields(known)))) throw new PublicRecordError("PUBLIC_ERASED");
        expectedTag = found.recordChangeTag;
      }
    }
    const context = await this.#registry[latest ? "reserveLatest" : "reserve"]({ accountID: identity.accountID, kind, logicalID,
      requestID, payloadHash: inputHash(fields), expectedTag });
    permit(); this.#authorize(accessToken, context.accountID);
    await this.#checkpoint.advance({ signal });
    permit(); this.#authorize(accessToken, context.accountID);
    const current = this.#registry.assertMutationCurrent(context), expectedFields = liveFields(context, fields);
    if (current.phase === "settled") return this.#receipt(current, expectedFields);
    const operation = { operationType: expectedTag === null ? "create" : "replace", record: {
      recordName: context.recordName, recordType: context.recordType, fields: expectedFields,
      ...(expectedTag === null ? {} : { recordChangeTag: expectedTag }) } };
    let record = (await this.#client.modify([operation], { signal })).get(context.recordName);
    permit(); this.#authorize(accessToken, context.accountID);
    if (["EXISTS", "CONFLICT"].includes(record?.serverErrorCode)) {
      // Explicit retry of the SAME immutable operation may reconcile an already committed write.
      record = (await this.#client.lookup([context.recordName], { signal })).get(context.recordName);
      permit(); this.#authorize(accessToken, context.accountID);
    }
    if (record?.serverErrorCode) throw providerFailure(record);
    checkScope(record, context);
    if (!matchesFields(record.fields, expectedFields)) throw new PublicRecordError("PUBLIC_CONFLICT");
    const saved = await this.#registry.settle(context, record.recordChangeTag);
    await this.#checkpoint.advance({ signal });
    permit(); this.#authorize(accessToken, saved.accountID);
    return this.#receipt(this.#registry.assertMutationCurrent(saved), expectedFields);
  }
  #receipt(context, fields) {
    return Object.freeze({ recordName: context.recordName, recordType: context.recordType,
      recordChangeTag: context.recordTag, fields });
  }
  /** Read lease is request-local. Candidate indexes never authorize disclosure. */
  async beginRead({ accessToken, signal } = {}) {
    const identity = this.#authorize(accessToken); this.#check(signal);
    await this.#checkpoint.verify({ signal });
    const check = () => { this.#check(signal); this.#authorize(accessToken, identity.accountID); };
    check(); let calls = 0;
    const spend = () => { check(); if (++calls > communityPolicy.maximumReadCalls) throw new PublicRecordError("PUBLIC_LIMIT"); };
    const current = item => {
      check(); const row = this.#registry.readable(item.context.recordName, item.context.kind);
      return row && row.requestID === item.context.requestID && row.recordTag === item.record.recordChangeTag && row.payloadHash === item.context.payloadHash;
    };
    return Object.freeze({ accountID: identity.accountID, check, current,
      ownName: (kind, logicalID = "singleton") => recordIdentity(identity.accountID, kind, logicalID).recordName,
      candidates: async options => { spend(); const result = await this.#client.regionalCandidates({ ...options, signal }); check(); return result; },
      lookup: async (names, kind) => {
        if (!Array.isArray(names) || names.length > 25 || new Set(names).size !== names.length) throw new PublicRecordError("PUBLIC_INPUT");
        check(); const contexts = names.map(name => this.#registry.readable(name, kind)).filter(Boolean);
        if (!contexts.length) return [];
        spend(); const found = await this.#client.lookup(contexts.map(row => row.recordName), { signal }); check();
        const result = [];
        for (const context of contexts) {
          const record = found.get(context.recordName);
          if (record?.serverErrorCode === "NOT_FOUND") continue;
          if (record?.serverErrorCode) throw providerFailure(record);
          const item = { record, context };
          if (!current(item)) continue;
          checkScope(record, context);
          if (record.fields.erased.value !== 0) continue;
          item.input = this.#decode(record, context); result.push(item);
        }
        return result;
      },
    });
  }
  #decode(record, context) {
    const values = Object.fromEntries(Object.entries(record.fields).map(([key, field]) => [key, field?.value]));
    const inventories = { profile: ["name"], presence: values.active === 0 ? ["active", "generation"] :
      ["name", "latitude", "longitude", "song", "songID", "generation"], message: ["name", "text", "latitude", "longitude"],
    block: ["targetID", "blocked"], report: ["messageID", "reason"], avatarprofile: ["versionID", "generation"] };
    // Avatar bytes require their separate authorization/validation path; never generic declassification.
    if (!Object.hasOwn(inventories, context.kind)) throw new PublicRecordError("PUBLIC_INPUT");
    const raw = Object.fromEntries(inventories[context.kind].map(key => [key, values[key]]));
    if (context.kind === "presence") { if (values.active === 0) raw.active = false; else raw.measuredAt = this.#clock(); }
    if (context.kind === "block") raw.blocked = values.blocked === 1;
    const input = normalizePublicInput(context.kind, raw, this.#clock());
    // A wrapped adaptive grid is not idempotent at the dateline. Preserve the validated stored
    // coordinates, then authenticate their exact values against the durable original payload hash.
    if (context.kind === "message" || context.kind === "presence" && values.active === 1) {
      input.latitude = raw.latitude; input.longitude = raw.longitude;
    }
    if (inputHash(input) !== context.payloadHash || !matchesFields(record.fields, liveFields(context, input))) throw new PublicRecordError("PUBLIC_RESPONSE");
    return input;
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
          const dueAt = publicRetentionDeadline(row);
          if (found.fields.erased.value === 1 && !matchesFields(found.fields, fields) &&
              !(dueAt !== null && dueAt <= this.#clock() && matchesFields(found.fields, expiredPublicFields(row)))) throw new PublicRecordError("PUBLIC_SCOPE");
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
