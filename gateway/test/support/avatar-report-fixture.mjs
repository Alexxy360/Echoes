import { randomUUID } from "node:crypto";
import { avatarReadFixture } from "./avatar-read-fixture.mjs";
import { AvatarReportCoordinator } from "../../src/avatar-report-coordinator.mjs";

export async function avatarReportFixture(settings = {}) {
  const f = await avatarReadFixture(settings); let enabled = true, readable = true, cancellable = false;
  const configuration = { authentication: f.state, communityState: f.social, avatarPolicy: f.policy,
    repository: f.repository, registry: f.registry, client: f.client, checkpoint: f.checkpoint,
    clock: f.clock, isEnabled: () => enabled, canSubmit: () => readable, canCancel: () => cancellable };
  const reports = new AvatarReportCoordinator(configuration);
  const input = (changes = {}) => ({ accessToken: f.viewer.sessionToken, requestID: randomUUID(), ownerID: f.signedIn.accountID,
    versionID: f.photo.versionID, reason: "PRIVATE_SYNTHETIC_PHOTO_REASON", coordinate: { ...f.coordinate }, ...changes });
  return { ...f, reports, reportConfiguration: configuration, reportInput: input,
    disableReports() { enabled = false; }, setReportsReadable(value) { readable = value; }, setReportsCancellable(value) { cancellable = value; },
    makeReports(changes = {}) { return new AvatarReportCoordinator({ ...configuration, ...changes }); },
    async submit(changes = {}, instance = reports) {
      const finalize = await instance.prepareSubmit(input(changes)); await f.checkpoint.advance(); return finalize();
    },
    async cancel(requestID, instance = reports) {
      const finalize = await instance.prepareCancellation({ accessToken: f.viewer.sessionToken, requestID }); await f.checkpoint.advance(); return finalize();
    },
    async recover(requestID, instance = reports) {
      const finalize = await instance.prepareRecovery({ accessToken: f.viewer.sessionToken, requestID }); await f.checkpoint.advance(); return finalize();
    }
  };
}
