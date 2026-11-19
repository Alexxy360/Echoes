import { writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { photoReportHTTPFixture } from "../test/support/avatar-report-http-fixture.mjs";
const cleanup = [], f = await photoReportHTTPFixture({ after(fn) { cleanup.push(fn); } }, { runtime: true });
try {
  const submit = f.body("submit"), unknown = { requestID: randomUUID() }, responses = {};
  const capture = async (name, response) => { responses[name] = { status: response.status, headers: Object.fromEntries(response.headers), body: await response.text() }; };
  await capture("submit", await f.edge("submit", submit));
  await capture("recover-accepted", await f.edge("recover", { requestID: submit.requestID }));
  await capture("recover-unconfirmed", await f.edge("recover", unknown));
  await capture("scope", await f.edge("recover", unknown, { token: randomUUID() + "." + "a".repeat(43) }));
  await capture("input", await f.edge("submit", { ...submit, generation: 1 }));
  // All values and secrets here are synthetic test fixtures; no service or user data is read.
  const fixture = { synthetic: "owned-local-avatar-report-runtime-v1", now: f.clock(), accountID: f.viewer.accountID, token: f.viewer.sessionToken, submit, unknown, responses };
  const path = new URL("../../EchoesCloudKit/Tests/EchoesCloudKitTests/Fixtures/avatar-report/responses.json", import.meta.url);
  await writeFile(path, JSON.stringify(fixture, null, 2) + "\n");
  console.log(JSON.stringify({ synthetic: fixture.synthetic, responses: Object.keys(responses), output: path.pathname }));
} finally { for (const fn of cleanup.reverse()) await fn(); }
