import { randomUUID } from "node:crypto";
import { setImmediate as tick } from "node:timers/promises";
import { publicFixture, messageInput } from "./public-record-fixture.mjs";
import { CloudKitPublicRetentionProcessor } from "../../src/public-retention-processor.mjs";

export async function retentionFixture(options = {}) {
  const f = await publicFixture(options), session = await f.session();
  let enabled = true, activeSession = session;
  const configuration = { registry: f.registry, client: f.client, checkpoint: f.checkpoint,
    clock: f.clock, isEnabled: () => enabled };
  const processor = new CloudKitPublicRetentionProcessor(configuration);
  const presenceInput = (changes = {}) => ({ accessToken: activeSession.sessionToken, kind: "presence", logicalID: "singleton",
    requestID: randomUUID(), input: { name: "Maja", latitude: 51.1123456, longitude: 17.0345678,
      song: "Synthetic song", songID: "123", generation: 0, measuredAt: f.clock() }, authorizeMutation() {}, ...changes });
  return { ...f, session, processor, configuration, presenceInput,
    disable() { enabled = false; },
    async refreshSession() { activeSession = await f.session(); return activeSession; },
    makeProcessor(changes = {}) { return new CloudKitPublicRetentionProcessor({ ...configuration, ...changes }); },
    async message(text) { const input = messageInput(session, text); return { input, record: await f.repository.write(input) }; },
    async presence() { const input = presenceInput(); return { input, record: await f.repository.writeLatest(input) }; },
    async step(changes, instance = processor) { const result = await instance.step(changes); await tick(); return result; },
  };
}
