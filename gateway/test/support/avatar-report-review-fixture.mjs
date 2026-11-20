import { AvatarReportReviewCoordinator } from "../../src/avatar-report-review-coordinator.mjs";
import { avatarReportReviewStateFixture } from "./avatar-report-review-state-fixture.mjs";

export async function avatarReportReviewFixture(t, settings = {}) {
  const f = await avatarReportReviewStateFixture(t, settings); let enabled = true, role = true, mono = 0;
  const configuration = { authentication: f.state, communityState: f.social, avatarPolicy: f.policy,
    repository: f.repository, registry: f.registry, client: f.client, reviews: f.reviews, checkpoint: f.checkpoint,
    isEnabled: () => enabled, isOperator: id => role && id === f.operator.accountID, clock: f.clock, monotonic: () => mono,
    verifiedDownloadHosts: ["synthetic-avatar.icloud-content.com"], fetchImplementation: f.configuration.fetchImplementation };
  const review = new AvatarReportReviewCoordinator(configuration), images = [];
  t.after(() => { for (const image of images) image.fill(0); });
  const options = (value = {}) => ({ accessToken: f.operator.sessionToken, ...value });
  return { ...f, review, reviewConfiguration: configuration, options, enable(value) { enabled = value; }, role(value) { role = value; }, moveMono(value) { mono += value; },
    async queue(value = {}, instance = review) { return (await instance.prepareQueue(options(value)))(); },
    async inspection(value = {}, instance = review) {
      const result = (await instance.prepareInspection(options({ reportID: f.report.context.recordName, ...value })))();
      if (result.image) images.push(result.image); return result;
    },
    async decide(inspection, verdict = "hide_photo", decisionID = crypto.randomUUID(), instance = review) {
      const input = { inspectionID: inspection.metadata.inspectionID, decisionID, verdict };
      return { input, result: (await instance.prepareDecision(options(input)))() };
    },
    recoveryInput(inspection, input) { return { reportID: f.report.context.recordName, decisionID: input.decisionID, verdict: input.verdict, contentHash: inspection.metadata.contentHash }; }
  };
}
