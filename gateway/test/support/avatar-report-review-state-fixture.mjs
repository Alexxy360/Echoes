import { randomUUID } from "node:crypto";
import { avatarReportFixture } from "./avatar-report-fixture.mjs";
import { AvatarReportReviewState, avatarReportReviewContent } from "../../src/avatar-report-review-state.mjs";
import { digest } from "../../src/public-record-schema.mjs";

export async function avatarReportReviewStateFixture(t, options = {}) {
  const f = await avatarReportFixture(options); t.after(() => f.close());
  const operator = await f.session("synthetic.photo.report.operator"), sessionKey = digest("synthetic-operator-session"), submitted = await f.submit();
  const lease = await f.repository.beginRead({ accessToken: operator.sessionToken });
  const [report] = await lease.lookup([submitted.reportID], "avatarreport"), publication = f.policy.readPublication(f.signedIn.accountID);
  const content = avatarReportReviewContent(report, publication), reviews = new AvatarReportReviewState(f.storage, { clock: f.clock });
  const optionsFor = (receipt, verdict = "hide_photo", changes = {}) => ({ reviewerID: operator.accountID, sessionKey,
    inspectionID: receipt.inspectionID, decisionID: randomUUID(), verdict, content, authorize: () => true, ...changes });
  return { ...f, operator, sessionKey, submitted, lease, report, publication, content, reviews, optionsFor,
    async inspect(value = content, reviewerID = operator.accountID, key = sessionKey) {
      const receipt = await reviews.reserve(reviewerID, key, value); await reviews.confirm(reviewerID, key, receipt.inspectionID); return receipt;
    },
    async makeReport() {
      const requestID = randomUUID(); return f.repository.write({ accessToken: f.viewer.sessionToken, kind: "avatarreport", logicalID: requestID, requestID,
        input: { ...report.input }, authorizeMutation: () => true });
    }
  };
}
