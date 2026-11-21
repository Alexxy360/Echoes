import { randomUUID } from "node:crypto";
import { plain, publicUUID, digest, recordIdentity, normalizePublicInput, inputHash, liveFields } from "../src/public-record-schema.mjs";
import { communityPolicy } from "../src/community-domain.mjs";

export const queryCanonical = value => JSON.stringify(value && typeof value === "object" ? Array.isArray(value) ?
  value.map(item => JSON.parse(queryCanonical(item))) : Object.fromEntries(Object.keys(value).sort().map(key =>
    [key, JSON.parse(queryCanonical(value[key]))])) : value);
const freeze = value => {
  if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
};

/** Disposable synthetic inventory. No filesystem, key, network or runtime activation. */
export function makeCommunityQueryPlan(seed = { runID: randomUUID(), startedAt: Date.now() }) {
  if (!plain(seed) || Object.keys(seed).sort().join() !== "runID,startedAt" || !publicUUID.test(seed.runID ?? "") ||
      !Number.isSafeInteger(seed.startedAt) || seed.startedAt < 7200001 || seed.startedAt > Number.MAX_SAFE_INTEGER - 7201000) {
    throw new Error("Invalid synthetic query plan seed.");
  }
  const id = label => {
    const h = digest("echoes/community-query-plan/v1\0" + seed.runID + "\0" + label).slice(0, 32);
    return [h.slice(0, 8), h.slice(8, 12), h.slice(12, 16), h.slice(16, 20), h.slice(20)].join("-");
  };
  const records = ["presence", "message"].flatMap(kind => ["tie-a", "tie-b", "older", "far", "expired",
    kind === "presence" ? "inactive" : "future"].map(scenario => {
    const accountID = id(kind + "/account/" + scenario), requestID = id(kind + "/request/" + scenario);
    const at = seed.startedAt + (scenario === "future" ? 1000 : scenario === "expired" ?
      -(kind === "presence" ? 600001 : 7200001) : scenario === "older" ? -2000 : -1000);
    const input = normalizePublicInput(kind, scenario === "inactive" ? { active: false, generation: 0 } : {
      name: "Query " + seed.runID.slice(0, 8), latitude: scenario === "far" ? 1 : 0, longitude: scenario === "far" ? 1 : 0,
      ...(kind === "message" ? { text: "Synthetic query " + scenario + " " + seed.runID } :
        { song: "", songID: "", generation: 0, measuredAt: at }),
    }, at);
    const context = { ...recordIdentity(accountID, kind, kind === "presence" ? "singleton" : requestID), requestID,
      createdAt: at, startedAt: at, payloadHash: inputHash(input) };
    return { kind, scenario, recordType: context.recordType, recordName: context.recordName, initial: liveFields(context, input) };
  }));
  const expected = Object.fromEntries(["presence", "message"].map(kind => [kind, records.filter(row => row.kind === kind &&
    ["tie-a", "tie-b", "older"].includes(row.scenario)).sort((a, b) => {
    const key = kind === "presence" ? "updatedAt" : "createdAt";
    return b.initial[key].value - a.initial[key].value || (a.recordName < b.recordName ? 1 : -1);
  }).map(row => row.recordName)]));
  const plan = freeze({ schemaVersion: 1, purpose: "echoes-community-query-development-v1",
    scope: { team: "22YC9RAP4P", container: "iCloud.mpvEcho.Echo", environment: "development", database: "public",
      reviewedSchemaSHA256: "495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543" },
    seed: { ...seed }, records, expected, query: { center: { latitude: 0, longitude: 0 }, cutoff: seed.startedAt,
      radius: communityPolicy.queryRadius, resultsLimit: 2, maximumPagesPerKind: 6 },
    constraints: { maximumRecords: 12, maximumBatchCalls: 32, maximumWindowMilliseconds: 1800000,
      exactInventoryFilter: true, createOnce: true, freshTagDeleteOnly: true, assets: false, activation: false } });
  return { plan, sha256: digest(queryCanonical(plan)) };
}

export function verifyCommunityQueryPlan(plan, sha256) {
  if (!plain(plan) || !/^[a-f0-9]{64}$/.test(sha256 ?? "")) throw new Error("Invalid query plan.");
  const prepared = makeCommunityQueryPlan(plan.seed);
  if (prepared.sha256 !== sha256 || queryCanonical(plan) !== queryCanonical(prepared.plan)) throw new Error("Query inventory changed.");
  return prepared;
}

/** Every continuation repeats the full predicate, including all six exact owned references. */
export function communityQueryPayload(plan, kind, marker = null) {
  if (!["presence", "message"].includes(kind) || marker !== null &&
      (typeof marker !== "string" || !marker.length || marker.length > 8192)) throw new Error("Invalid query cursor.");
  const filterBy = [
    { fieldName: "location", comparator: "NEAR", fieldValue: { type: "LOCATION", value: plan.query.center }, distance: plan.query.radius },
    { fieldName: "erased", comparator: "EQUALS", fieldValue: { type: "INT64", value: 0 } },
    { fieldName: "expiresAt", comparator: "GREATER_THAN", fieldValue: { type: "INT64", value: plan.query.cutoff } },
    kind === "presence" ? { fieldName: "active", comparator: "EQUALS", fieldValue: { type: "INT64", value: 1 } } :
      { fieldName: "createdAt", comparator: "LESS_THAN_OR_EQUALS", fieldValue: { type: "INT64", value: plan.query.cutoff } },
    { systemFieldName: "recordName", comparator: "IN", fieldValue: { type: "REFERENCE_LIST",
      value: plan.records.filter(row => row.kind === kind).map(row => ({ recordName: row.recordName })) } },
  ];
  return { query: { recordType: plan.records.find(row => row.kind === kind).recordType, filterBy,
    sortBy: [{ fieldName: kind === "presence" ? "updatedAt" : "createdAt", ascending: false }, { fieldName: "recordSortKey", ascending: false }] },
    resultsLimit: plan.query.resultsLimit, desiredKeys: ["ownerKey"], ...(marker === null ? {} : { continuationMarker: marker }) };
}

/** Strict page accumulator: no unexpected ID/field, duplicate, order drift, cycle or unbounded empty pages. */
export class CommunityQueryPages {
  #plan; #kind; #names = []; #markers = new Set(); #pages = 0; #done = false;
  constructor(prepared, kind) {
    this.#plan = verifyCommunityQueryPlan(prepared?.plan, prepared?.sha256).plan;
    if (!["presence", "message"].includes(kind)) throw new Error("Invalid query kind.");
    this.#kind = kind;
  }
  accept(body) {
    const fail = () => { throw new Error("Incomplete or invalid synthetic query result."); };
    if (this.#done || !plain(body) || Object.keys(body).some(key => !["records", "continuationMarker"].includes(key)) ||
        !Array.isArray(body.records) || body.records.length > 2 || ++this.#pages > this.#plan.query.maximumPagesPerKind) fail();
    const names = [...this.#names];
    for (const row of body.records) {
      const item = this.#plan.records.find(item => item.recordName === row?.recordName && item.kind === this.#kind);
      if (!plain(row) || !item || row.serverErrorCode || row.deleted || row.recordType !== item.recordType ||
          !plain(row.fields) || Object.keys(row.fields).join() !== "ownerKey" || !plain(row.fields.ownerKey) ||
          Object.keys(row.fields.ownerKey).some(key => !["type", "value"].includes(key)) ||
          row.fields.ownerKey.value !== item.initial.ownerKey.value ||
          row.fields.ownerKey.type !== undefined && row.fields.ownerKey.type !== "STRING") fail();
      names.push(row.recordName);
    }
    const expected = this.#plan.expected[this.#kind];
    if (names.length > expected.length || names.some((name, index) => name !== expected[index])) fail();
    const marker = body.continuationMarker ?? null;
    if (marker !== null && (typeof marker !== "string" || !marker.length || marker.length > 8192 ||
        this.#markers.has(marker) || this.#pages >= this.#plan.query.maximumPagesPerKind)) fail();
    if (marker === null && (names.length !== expected.length || this.#pages < 2)) fail();
    this.#names = names;
    if (marker === null) this.#done = true; else this.#markers.add(marker);
    return { marker, complete: this.#done, pages: this.#pages, recordNames: [...names] };
  }
}
