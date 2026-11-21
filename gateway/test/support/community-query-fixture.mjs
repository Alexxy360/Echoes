import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { CommunityProtocolModel } from "./community-protocol-fixture.mjs";
import { distanceMeters } from "../../src/community-geo.mjs";
import { makeCommunityQueryPlan } from "../../scripts/community-query-plan.mjs";
import { CommunityQueryJournal } from "../../scripts/community-query-journal.mjs";
import { runCommunityQuery } from "../../scripts/community-query-runner.mjs";

/** Synthetic filtering/continuation, not acceptance of Apple's planner or eventual indexes. */
export class CommunityQueryModel extends CommunityProtocolModel {
  apply(operation, payload) {
    if (operation !== "records/query") return super.apply(operation, payload);
    const { query, resultsLimit, continuationMarker } = payload;
    let rows = [...this.records.values()].filter(row => row.recordType === query.recordType && query.filterBy.every(filter => {
      if (filter.systemFieldName === "recordName") return filter.fieldValue.value.some(ref => ref.recordName === row.recordName);
      const actual = row.fields[filter.fieldName]?.value, expected = filter.fieldValue.value;
      switch (filter.comparator) {
      case "NEAR": return actual !== undefined && distanceMeters(actual, expected) <= filter.distance;
      case "EQUALS": return actual === expected;
      case "GREATER_THAN": return actual > expected;
      case "LESS_THAN_OR_EQUALS": return actual <= expected;
      default: throw new Error("Unexpected synthetic comparator.");
      }
    }));
    rows.sort((a, b) => {
      for (const { fieldName, ascending } of query.sortBy) {
        const x = a.fields[fieldName].value, y = b.fields[fieldName].value;
        if (x !== y) return (x < y ? -1 : 1) * (ascending ? 1 : -1);
      }
      return 0;
    });
    const offset = continuationMarker === undefined ? 0 : Number(continuationMarker);
    const more = offset + resultsLimit < rows.length;
    return { records: rows.slice(offset, offset + resultsLimit).map(row => ({ ...structuredClone(row),
      fields: Object.fromEntries(payload.desiredKeys.map(key => [key, structuredClone(row.fields[key])])) })),
    ...(more ? { continuationMarker: String(offset + resultsLimit) } : {}) };
  }
}
export async function queryFixture(t) {
  const root = await mkdtemp(join(tmpdir(), "echoes-query-test-")), prepared = makeCommunityQueryPlan();
  const journal = await CommunityQueryJournal.create(root, prepared);
  let wall = prepared.plan.seed.startedAt, mono = 0;
  const f = { root, prepared, journal, model: new CommunityQueryModel(), report: null,
    clock: () => wall, monotonic: () => mono,
    advance(ms) { wall += ms; mono += ms; }, moveWall(ms) { wall += ms; }, moveMono(ms) { mono += ms; },
    window(mode = "full") { return { id: randomUUID(), issuedAt: wall, expiresAt: wall + 60000, mode }; },
    async run(options = {}) {
      return f.report = await runCommunityQuery({ journal: f.journal, transport: f.model, window: f.window(),
        clock: f.clock, monotonic: f.monotonic, isAuthorized: () => true, ...options });
    },
    async reopen() { const directory = f.journal.directory; f.journal.close(); f.journal = await CommunityQueryJournal.open(directory, prepared.sha256); },
  };
  t.after(async () => { f.model.drainFault = false; await f.report?.waitForSafeRelease(); f.journal.close(); await rm(root, { recursive: true, force: true }); });
  return f;
}
