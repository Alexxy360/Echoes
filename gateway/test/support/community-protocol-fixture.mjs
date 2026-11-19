import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { makeCommunityProtocolPlan } from "../../scripts/community-protocol-plan.mjs";
import { CommunityProtocolJournal } from "../../scripts/community-protocol-journal.mjs";
import { runCommunityProtocol } from "../../scripts/community-protocol-runner.mjs";

export function barrier() { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; }
/** Explicitly synthetic decoded CloudKit protocol, not Apple or an HTTP transport. */
export class CommunityProtocolModel {
  records = new Map(); calls = []; before; after; nullFields = false; drainFault = false;
  #pending = new Set(); #sequence = 0;
  async request(operation, payload, options) {
    const call = { operation, payload: structuredClone(payload), signal: options.signal }; this.calls.push(call);
    const actual = (async () => {
      const override = await this.before?.(call); if (override !== undefined) return override;
      const body = this.apply(operation, payload);
      return await this.after?.(call, body) ?? body;
    })();
    this.#pending.add(actual);
    try { return await actual; } finally { this.#pending.delete(actual); }
  }
  async waitForPendingOperations() {
    await Promise.allSettled([...this.#pending]);
    if (this.drainFault) throw new Error("SYNTHETIC-PRIVATE-DRAIN");
  }
  apply(operation, payload) {
    if (operation === "records/lookup") return { records: payload.records.map(({ recordName }) =>
      structuredClone(this.records.get(recordName) ?? { recordName, serverErrorCode: "NOT_FOUND" })) };
    if (operation !== "records/modify") throw new Error("Unexpected synthetic operation.");
    return { records: payload.operations.map(({ operationType, record }) => {
      const previous = this.records.get(record.recordName), error = serverErrorCode => ({ recordName: record.recordName, serverErrorCode });
      if (operationType === "create" && previous) return error("EXISTS");
      if (operationType !== "create" && !previous) return error("NOT_FOUND");
      if (operationType !== "create" && previous.recordChangeTag !== record.recordChangeTag) return error("CONFLICT");
      if (operationType === "delete") { this.records.delete(record.recordName); return { recordName: record.recordName, deleted: true }; }
      if (!["create", "replace"].includes(operationType)) throw new Error("Unconditional mutation forbidden.");
      const fields = structuredClone(record.fields);
      if (this.nullFields && previous) for (const [key, value] of Object.entries(previous.fields)) if (!(key in fields)) fields[key] = { type: value.type, value: null };
      const saved = { recordName: record.recordName, recordType: record.recordType, recordChangeTag: "probe-" + ++this.#sequence, fields };
      this.records.set(record.recordName, saved); return structuredClone(saved);
    }) };
  }
}
export async function protocolFixture(t) {
  const root = await mkdtemp(join(tmpdir(), "echoes-protocol-test-"));
  const prepared = makeCommunityProtocolPlan(), journal = await CommunityProtocolJournal.create(root, prepared);
  let wall = prepared.plan.seed.startedAt, mono = 0;
  const f = { root, prepared, journal, model: new CommunityProtocolModel(), report: null, running: null,
    clock: () => wall, monotonic: () => mono, advance(ms) { wall += ms; mono += ms; }, moveWall(ms) { wall += ms; }, moveMono(ms) { mono += ms; },
    window(mode = "full", duration = 60000) { return { id: randomUUID(), issuedAt: wall, expiresAt: wall + duration, mode }; },
    async run(options = {}) {
      const running = runCommunityProtocol({ journal: f.journal, transport: f.model, window: f.window(), isAuthorized: () => true,
        clock: f.clock, monotonic: f.monotonic, ...options });
      f.running = running;
      try { return f.report = await running; } finally { f.running = null; }
    },
    async reopen() { const directory = f.journal.directory; f.journal.close(); f.journal = await CommunityProtocolJournal.open(directory, prepared.sha256); },
  };
  t.after(async () => {
    f.model.drainFault = false;
    if (f.running) await f.running.catch(() => {});
    await f.report?.waitForSafeRelease(); f.journal.close(); await rm(root, { recursive: true, force: true });
  });
  return f;
}
