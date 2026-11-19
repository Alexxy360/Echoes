import { randomUUID } from "node:crypto";
import { publicFixture, messageInput } from "./public-record-fixture.mjs";
import { CommunityState } from "../../src/community-state.mjs";
import { CommunityReportReview } from "../../src/community-report-review.mjs";
import { CommunityReportReviewState } from "../../src/community-report-review-state.mjs";

export async function reportReviewFixture(t, options = {}) {
  const f = await publicFixture(options); let closed = false; const close = f.close;
  f.close = () => { if (!closed) { closed = true; close(); } }; t.after(() => f.close());
  const operator = await f.session("operator"), reporter = await f.session("reporter"), author = await f.session("author");
  const community = new CommunityState(f.storage, { clock: f.clock }); let enabled = true, role = true, mono = 0;
  const reviews = new CommunityReportReviewState(f.storage, { clock: f.clock });
  const config = { reviews, authentication: f.state, communityState: community, registry: f.registry, repository: f.repository, client: f.client, checkpoint: f.checkpoint,
    clock: f.clock, monotonic: () => mono, isEnabled: () => enabled, isOperator: id => role && id === operator.accountID };
  const review = new CommunityReportReview(config), input = messageInput(author, "PRIVATE-SYNTHETIC-MESSAGE"), message = await f.repository.write(input);
  const context = f.registry.readable(message.recordName, "message");
  const intent = await community.begin({ accountID: author.accountID, kind: "message", logicalID: input.logicalID, requestID: input.requestID, payloadHash: context.payloadHash });
  await community.finish(intent);
  const makeReport = async () => {
    const requestID = randomUUID();
    return f.repository.write({ accessToken: reporter.sessionToken, kind: "report", logicalID: requestID, requestID,
      input: { messageID: message.recordName, reason: "PRIVATE-SYNTHETIC-REPORT" } });
  };
  const report = await makeReport();
  return { ...f, operator, reporter, author, community, reviews, input, message, report, review, config, makeReport,
    enable(value) { enabled = value; }, role(value) { role = value; }, moveMono(value) { mono += value; },
    options(changes) { return { accessToken: operator.sessionToken, ...changes }; },
    async queue(options = {}) { const final = await review.prepareQueue(this.options(options)); return final(); },
    async inspect(options = {}) { const final = await review.prepareInspection(this.options({ reportID: report.recordName, ...options })); return final(); },
  };
}
