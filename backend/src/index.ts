import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { setGlobalOptions } from "firebase-functions/v2";
import {
  CallableRequest,
  HttpsError,
  onCall,
} from "firebase-functions/v2/https";
import { logger } from "firebase-functions";
import { InvalidInput } from "./domain";
import { CommunityService } from "./service";

initializeApp();
setGlobalOptions({
  region: "europe-west1",
  maxInstances: 5,
  memory: "256MiB",
  timeoutSeconds: 30,
});
const service = new CommunityService(getFirestore());

function endpoint(
  action: (uid: string, data: unknown) => Promise<Record<string, unknown>>,
) {
  return onCall(
    { enforceAppCheck: process.env.FUNCTIONS_EMULATOR !== "true" },
    async (request: CallableRequest) => {
      if (!request.auth?.uid)
        throw new HttpsError("unauthenticated", "Zaloguj się ponownie.");
      if (request.rawRequest.rawBody.length > 65_536)
        throw new HttpsError("invalid-argument", "Żądanie jest zbyt duże.");
      try {
        return {
          ...(await action(request.auth.uid, request.data)),
          serverTime: Date.now(),
        };
      } catch (error) {
        if (error instanceof HttpsError) throw error;
        if (error instanceof InvalidInput)
          throw new HttpsError("invalid-argument", error.message);
        // Never log request payloads, locations, names or message bodies.
        logger.error("community_operation_failed", {
          type: error instanceof Error ? error.name : "unknown",
        });
        throw new HttpsError(
          "internal",
          "Nie udało się wykonać operacji. Spróbuj ponownie.",
        );
      }
    },
  );
}

export const communityConfig = endpoint((uid) => service.configuration(uid));
export const communityVisibility = endpoint((uid) => service.visibility(uid));
export const communityPublish = endpoint((uid, data) =>
  service.publish(uid, data),
);
export const communityStopSharing = endpoint((uid) => service.stopSharing(uid));
export const communityNearby = endpoint((uid, data) =>
  service.nearby(uid, data),
);
export const communityMessages = endpoint((uid, data) =>
  service.messages(uid, data),
);
export const communitySend = endpoint((uid, data) => service.send(uid, data));
export const communityBlock = endpoint((uid, data) => service.block(uid, data));
export const communityBlockedUsers = endpoint((uid) =>
  service.blockedUsers(uid),
);
export const communityReport = endpoint((uid, data) =>
  service.report(uid, data),
);
export const communityDeleteOwnData = endpoint((uid) =>
  service.deleteOwnData(uid),
);
