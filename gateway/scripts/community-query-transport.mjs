import { plain, validTag } from "../src/public-record-schema.mjs";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { communityQueryPayload, queryCanonical, verifyCommunityQueryPlan } from "./community-query-plan.mjs";
import { CommunityProtocolError } from "./community-protocol-runner.mjs";

const signRequest = CloudKitDevelopmentSigner.prototype.request;
const fail = code => { throw new CommunityProtocolError(code); };
const keys = (value, expected) => plain(value) && Object.keys(value).sort().join() === [...expected].sort().join();
function exactFields(actual, expected) {
  if (!keys(actual, Object.keys(expected))) return false;
  return Object.entries(expected).every(([name, field]) => keys(actual[name], ["type", "value"]) && actual[name].type === field.type &&
    (field.type === "LOCATION" ? keys(actual[name].value, ["latitude", "longitude"]) &&
      actual[name].value.latitude === field.value.latitude && actual[name].value.longitude === field.value.longitude : actual[name].value === field.value));
}

/** Fixed Development/public transport for one reviewed twelve-record query inventory. Never an HTTP endpoint/proxy. */
export class CommunityQueryTransport {
  #plan; #items; #signer; #fetch; #enabled; #clock; #pending = new Set(); #unsafeDrain = false;
  constructor({ prepared, signer, fetchImplementation = fetch, isEnabled = () => false, clock = Date.now } = {}) {
    const verified = verifyCommunityQueryPlan(prepared?.plan, prepared?.sha256);
    if (!(signer instanceof CloudKitDevelopmentSigner) || typeof fetchImplementation !== "function" || typeof isEnabled !== "function" || typeof clock !== "function") fail("PROTOCOL_SCOPE");
    this.#plan = verified.plan; this.#items = new Map(verified.plan.records.map(item => [item.recordName, item]));
    this.#signer = signer; this.#fetch = fetchImplementation; this.#enabled = isEnabled; this.#clock = clock;
  }
  #check(signal) {
    if (this.#unsafeDrain) fail("PROTOCOL_DRAIN");
    if (signal?.aborted) fail("PROTOCOL_CANCELLED");
    try { if (this.#enabled() !== true) fail("PROTOCOL_DENIED"); }
    catch { fail("PROTOCOL_DENIED"); }
  }
  #validate(operation, payload) {
    let names;
    if (operation === "records/query") {
      const kind = this.#plan.records.find(item => item.recordType === payload?.query?.recordType)?.kind;
      try {
        if (queryCanonical(payload) !== queryCanonical(communityQueryPayload(this.#plan, kind, payload.continuationMarker ?? null))) fail("PROTOCOL_SCOPE");
      } catch { fail("PROTOCOL_SCOPE"); }
      return;
    }
    if (operation === "records/lookup") {
      if (!keys(payload, ["records"]) || !Array.isArray(payload.records) || payload.records.length < 1 || payload.records.length > 12 ||
          payload.records.some(row => !keys(row, ["recordName"]))) fail("PROTOCOL_SCOPE");
      names = payload.records.map(row => row.recordName);
    } else if (operation === "records/modify") {
      if (!keys(payload, ["atomic", "operations"]) || payload.atomic !== false || !Array.isArray(payload.operations) ||
          payload.operations.length < 1 || payload.operations.length > 12) fail("PROTOCOL_SCOPE");
      const kinds = new Set(); names = [];
      for (const operation of payload.operations) {
        if (!keys(operation, ["operationType", "record"]) || !["create", "delete"].includes(operation.operationType)) fail("PROTOCOL_SCOPE");
        const { record, operationType } = operation, item = this.#items.get(record?.recordName); kinds.add(operationType);
        if (!item || !keys(record, ["recordName", "recordType", ...(operationType !== "delete" ? ["fields"] : []), ...(operationType !== "create" ? ["recordChangeTag"] : [])]) ||
            record.recordType !== item.recordType || operationType !== "create" && !validTag(record.recordChangeTag) ||
            operationType !== "delete" && !exactFields(record.fields, item.initial)) fail("PROTOCOL_SCOPE");
        names.push(record.recordName);
      }
      if (kinds.size !== 1) fail("PROTOCOL_SCOPE");
    } else fail("PROTOCOL_SCOPE");
    if (!names.length || names.length > 12 || new Set(names).size !== names.length || names.some(name => !this.#items.has(name))) fail("PROTOCOL_SCOPE");
  }
  async #cancel(target) {
    try { await target?.cancel(); } catch { this.#unsafeDrain = true; }
  }
  async #json(response, signal) {
    if (!(response instanceof Response)) fail("PROTOCOL_RESPONSE");
    let reader, cancellation, abort;
    try {
      this.#check(signal);
      if (!response.ok || response.redirected || !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? "") || !response.body) fail("PROTOCOL_RESPONSE");
      const length = response.headers.get("Content-Length");
      if (length !== null && (!/^\d+$/.test(length) || Number(length) > 65536)) fail("PROTOCOL_RESPONSE");
      reader = response.body.getReader();
      const cancel = () => cancellation ??= this.#cancel(reader);
      abort = () => { void cancel(); }; signal.addEventListener("abort", abort, { once: true });
      const parts = []; let total = 0;
      while (true) {
        this.#check(signal);
        const { value, done } = await reader.read(); if (done) break;
        if (!(value instanceof Uint8Array) || parts.length >= 1024 || (total += value.byteLength) > 65536) fail("PROTOCOL_RESPONSE");
        parts.push(value);
      }
      this.#check(signal);
      const bytes = new Uint8Array(total); let offset = 0;
      for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
      return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    } finally {
      if (reader) {
        signal.removeEventListener("abort", abort);
        cancellation ??= this.#cancel(reader); await cancellation; reader.releaseLock();
      } else await this.#cancel(response.body);
    }
  }
  async #perform(operation, payload, parent) {
    const controller = new AbortController(), abort = () => controller.abort();
    parent?.addEventListener("abort", abort, { once: true }); if (parent?.aborted) controller.abort();
    const timer = setTimeout(abort, 8000);
    try {
      this.#check(controller.signal);
      const request = signRequest.call(this.#signer, operation, payload, new Date(this.#clock()));
      if (!(request instanceof Request) || request.method !== "POST" || request.redirect !== "manual" ||
          request.url !== "https://api.apple-cloudkit.com/database/1/iCloud.mpvEcho.Echo/development/public/" + operation) fail("PROTOCOL_SCOPE");
      this.#check(controller.signal);
      const response = await this.#fetch(request, { signal: controller.signal });
      const body = await this.#json(response, controller.signal); this.#check(controller.signal); return body;
    } catch (error) { throw error instanceof CommunityProtocolError ? error : new CommunityProtocolError("PROTOCOL_RESPONSE"); }
    finally { clearTimeout(timer); parent?.removeEventListener("abort", abort); controller.abort(); }
  }
  async request(operation, payload, { signal } = {}) {
    this.#check(signal); this.#validate(operation, payload);
    if (this.#pending.size) fail("PROTOCOL_LIMIT");
    const actual = this.#perform(operation, structuredClone(payload), signal); this.#pending.add(actual);
    void actual.then(() => this.#pending.delete(actual), () => this.#pending.delete(actual));
    return actual;
  }
  async waitForPendingOperations() {
    await Promise.allSettled([...this.#pending]);
    if (this.#unsafeDrain) fail("PROTOCOL_DRAIN");
  }
}
