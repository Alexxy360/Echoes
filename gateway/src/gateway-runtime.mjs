import { AppleClientSecret, AppleOAuthClient } from "./apple-oauth.mjs";
import { ApplePublicKeySource, base64URLBytes } from "./apple-public-keys.mjs";
import { createPublicKey } from "node:crypto";
import { AppleIdentityTokenVerifier } from "./apple-identity.mjs";
import { AuthenticationState } from "./authentication-state.mjs";
import { AppleLoginCoordinator } from "./apple-login.mjs";
import { RefreshCredentialVault } from "./refresh-credential-vault.mjs";
import { RenewalProofs } from "./renewal-proofs.mjs";
import { SessionRenewalCoordinator } from "./session-renewal.mjs";
import { SessionResetCoordinator } from "./session-reset.mjs";
import { AccountDeletionState } from "./account-deletion-state.mjs";
import { AccountDeletionCoordinator, AccountDeletionProcessor } from "./account-deletion.mjs";
import { GatewayLimits, edgeBudgetHash } from "./gateway-limits.mjs";
import { GatewayMaintenance } from "./gateway-maintenance.mjs";
import { createGatewayHTTPHandler, inspectGatewayRequest, gatewayFailure, gatewayJSON } from "./gateway-http.mjs";
import { CloudKitPublicClient } from "./cloudkit-public-client.mjs";
import { PublicRecordRegistry } from "./public-record-registry.mjs";
import { CloudKitPublicRepository } from "./public-record-repository.mjs";
import { PublicRegistryCheckpoint } from "./public-registry-checkpoint.mjs";
import { CommunityState } from "./community-state.mjs";
import { CommunityCoordinator } from "./community-coordinator.mjs";
import { AvatarPolicyState } from "./avatar-policy-state.mjs";
import { CommunityAvatarReferences } from "./community-avatar-references.mjs";
import { AvatarReadError, CloudKitAvatarReader } from "./cloudkit-avatar-reader.mjs";
import { avatarReadPath, avatarReadInputLimit, avatarDownloadHosts, avatarHTTPDeadline, avatarEdgeResponse, avatarEdgeErrorResponse } from "./gateway-avatar-http.mjs";
import { AvatarReceiptVault } from "./avatar-receipt-vault.mjs";
import { CloudKitAvatarAssets } from "./cloudkit-avatar-assets.mjs";
import { CloudKitAvatarRepository } from "./cloudkit-avatar-repository.mjs";
import { AvatarPublicationCoordinator } from "./avatar-publication-coordinator.mjs";
import { avatarMutationPaths, avatarIntentHeader, avatarMutationHeaders, avatarMutationDeadline,
  avatarMutationAdmission, avatarMutationEdgeResponse, avatarMutationBody } from "./avatar-upload-http.mjs";
import { AvatarReviewCoordinator } from "./avatar-review-coordinator.mjs";
import { CloudKitAvatarOwnerPreview } from "./cloudkit-avatar-owner-preview.mjs";
import { avatarOwnerPreviewPath, avatarOwnerPreviewHeaders, avatarOwnerPreviewInput, avatarOwnerPreviewAdmission, avatarOwnerPreviewEdgeResponse, avatarOwnerPreviewError } from "./avatar-owner-preview-http.mjs";
import { AvatarReviewReceipts } from "./avatar-review-state.mjs";
import { avatarReviewers, avatarReviewPaths, avatarReviewHeaders, avatarReviewAdmission, avatarReviewDeadline, avatarReviewEdgeResponse } from "./avatar-review-http.mjs";

export const authorityName = "echoes-auth-authority-development-v1";
export function activeGatewayConfiguration(env, now = Date.now()) {
  if (!Number.isSafeInteger(now) || now < 0 || env.GATEWAY_ENABLED !== "1" || env.GATEWAY_ENVIRONMENT !== "development" ||
      env.CLOUDKIT_CONTAINER !== "iCloud.mpvEcho.Echo" || env.CLOUDKIT_ENVIRONMENT !== "development" ||
      !["0", "1"].includes(env.ACCOUNT_DELETION_ENABLED) ||
      !["0", "1"].includes(env.PUBLIC_RECORDS_ENABLED ?? "0") ||
      !["0", "1"].includes(env.COMMUNITY_ENABLED ?? "0") ||
      !["0", "1"].includes(env.AVATAR_READ_ENABLED ?? "0") ||
      !["0", "1"].includes(env.AVATAR_OWNER_PREVIEW_ENABLED ?? "0") ||
      env.AVATAR_OWNER_PREVIEW_ENABLED === "1" && env.COMMUNITY_ENABLED !== "1" ||
      !["0", "1"].includes(env.AVATAR_UPLOAD_ENABLED ?? "0") ||
      !["0", "1"].includes(env.AVATAR_REVIEW_ENABLED ?? "0") ||
      env.AVATAR_REVIEW_ENABLED === "1" && env.COMMUNITY_ENABLED !== "1" ||
      env.AVATAR_UPLOAD_ENABLED === "1" && env.COMMUNITY_ENABLED !== "1" ||
      env.AVATAR_READ_ENABLED === "1" && env.COMMUNITY_ENABLED !== "1" ||
      env.COMMUNITY_ENABLED === "1" && env.PUBLIC_RECORDS_ENABLED !== "1" ||
      env.PUBLIC_RECORDS_ENABLED === "1" && env.ACCOUNT_DELETION_ENABLED !== "1" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(env.GATEWAY_EXPIRES_AT ?? "")) return null;
  const deadline = Date.parse(env.GATEWAY_EXPIRES_AT);
  if (!Number.isSafeInteger(deadline) || deadline <= now || deadline > now + 7 * 86400000) return null;
  const canonical = new Date(deadline).toISOString();
  if (env.GATEWAY_EXPIRES_AT !== canonical && env.GATEWAY_EXPIRES_AT !== canonical.replace(".000Z", "Z")) return null;
  let hosts = Object.freeze([]), uploadHosts = Object.freeze([]), reviewers;
  try {
    reviewers = avatarReviewers(env.AVATAR_REVIEWER_IDS_JSON);
    if (env.AVATAR_REVIEW_ENABLED === "1" && reviewers.length === 0) return null;
    if (env.AVATAR_READ_ENABLED === "1" || env.AVATAR_REVIEW_ENABLED === "1" || env.AVATAR_OWNER_PREVIEW_ENABLED === "1") hosts = avatarDownloadHosts(env.AVATAR_DOWNLOAD_HOSTS_JSON);
    if (env.AVATAR_UPLOAD_ENABLED === "1") uploadHosts = avatarDownloadHosts(env.AVATAR_UPLOAD_HOSTS_JSON);
  } catch { return null; }
  return Object.freeze({ deadline, avatarOwnerPreviewEnabled: env.AVATAR_OWNER_PREVIEW_ENABLED === "1", avatarReviewEnabled: env.AVATAR_REVIEW_ENABLED === "1", avatarReviewers: reviewers, avatarReadEnabled: env.AVATAR_READ_ENABLED === "1", avatarDownloadHosts: hosts,
    avatarUploadEnabled: env.AVATAR_UPLOAD_ENABLED === "1", avatarUploadHosts: uploadHosts, deletionEnabled: env.ACCOUNT_DELETION_ENABLED === "1",
    publicRecordsEnabled: env.PUBLIC_RECORDS_ENABLED === "1", communityEnabled: env.COMMUNITY_ENABLED === "1" });
}
function keyMap(json) {
  if (typeof json !== "string" || json.length > 2048) throw new Error();
  const value = JSON.parse(json);
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length < 1 || Object.keys(value).length > 3) throw new Error();
  return value;
}
function hasRegistryCheckpoint(storage) {
  return storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='public_registry_checkpoint_v1'").toArray().length > 0 &&
    storage.sql.exec("SELECT singleton FROM public_registry_checkpoint_v1 WHERE singleton=1").toArray().length > 0;
}

/** Concrete composition for the Development target. No fake Apple exchange, key or data-erasure fallback. */
export function createGatewayRuntime(storage, env, { clock = Date.now, fetchImplementation = (request, options) => fetch(request, options), erasePublicDataBatch, avatarNormalizerFactory } = {}) {
  try {
    const config = activeGatewayConfiguration(env, clock());
    if (!config || (config.deletionEnabled && !config.publicRecordsEnabled && typeof erasePublicDataBatch !== "function")) throw new Error();
    if (!config.publicRecordsEnabled && hasRegistryCheckpoint(storage)) throw new Error();
    if (config.publicRecordsEnabled && createPublicKey(env.CLOUDKIT_PRIVATE_KEY).export({ type: "spki", format: "der" })
      .equals(createPublicKey(env.APPLE_SIGNIN_PRIVATE_KEY).export({ type: "spki", format: "der" }))) throw new Error();
    const refreshKeys = keyMap(env.REFRESH_KEYS_JSON), renewalKeys = keyMap(env.RENEWAL_KEYS_JSON);
    const allSecrets = [...Object.values(refreshKeys), ...Object.values(renewalKeys), env.REQUEST_BUDGET_KEY];
    if (new Set(allSecrets).size !== allSecrets.length || allSecrets.some(value => base64URLBytes(value, 32).length !== 32) ||
        (env.CLOUDKIT_PRIVATE_KEY !== undefined && env.CLOUDKIT_PRIVATE_KEY === env.APPLE_SIGNIN_PRIVATE_KEY)) throw new Error();
    const credentialVault = new RefreshCredentialVault({ activeKeyID: env.REFRESH_ACTIVE_KEY_ID, keys: refreshKeys });
    const renewalProofs = new RenewalProofs({ activeKeyID: env.RENEWAL_ACTIVE_KEY_ID, keys: renewalKeys });
    const clientSecret = new AppleClientSecret({ privateKeyPEM: env.APPLE_SIGNIN_PRIVATE_KEY, keyID: env.APPLE_SIGNIN_KEY_ID, clock });
    let checkpoint;
    const guardedFetch = (...args) => {
      if (!activeGatewayConfiguration(env, clock()) || !checkpoint && hasRegistryCheckpoint(storage)) throw new Error("Gateway is inactive.");
      return fetchImplementation(...args);
    };
    const providerFetch = async (...args) => {
      await checkpoint?.advance({ signal: args[1]?.signal });
      return guardedFetch(...args);
    };
    const apple = new AppleOAuthClient({ clientSecret, fetchImplementation: providerFetch });
    const verifier = new AppleIdentityTokenVerifier({ keySource: new ApplePublicKeySource({ clock, fetchImplementation: providerFetch }), clock });
    const authentication = new AuthenticationState(storage, { clock, renewalProofs });
    let publicRecords, community, communityState, avatarReader, avatarPublication, avatarWithdrawal, avatarReview, avatarOwnerPreview;
    const isAvatarReadEnabled = () => {
      const active = activeGatewayConfiguration(env, clock());
      return active?.avatarReadEnabled === true && active.avatarDownloadHosts.join() === config.avatarDownloadHosts.join();
    };
    const isAvatarOwnerPreviewEnabled = () => {
      const active = activeGatewayConfiguration(env, clock());
      return active?.avatarOwnerPreviewEnabled === true && active.avatarDownloadHosts.join() === config.avatarDownloadHosts.join();
    };
    const isAvatarUploadEnabled = () => {
      const active = activeGatewayConfiguration(env, clock());
      return active?.avatarUploadEnabled === true && active.avatarUploadHosts.join() === config.avatarUploadHosts.join();
    };
    const isAvatarReviewEnabled = () => {
      const active = activeGatewayConfiguration(env, clock());
      return active?.avatarReviewEnabled === true && active.avatarDownloadHosts.join() === config.avatarDownloadHosts.join()
        && active.avatarReviewers.join() === config.avatarReviewers.join();
    };
    const isAvatarReviewer = id => {
      if (!isAvatarReviewEnabled() || !config.avatarReviewers.includes(id)) return false;
      communityState.assertActive(id); return true;
    };
    const isAvatarWithdrawalEnabled = () => isAvatarReadEnabled() || isAvatarUploadEnabled() || isAvatarReviewEnabled() || isAvatarOwnerPreviewEnabled();
    if (config.publicRecordsEnabled) {
      const registry = new PublicRecordRegistry(storage, { clock });
      const client = new CloudKitPublicClient({ container: env.CLOUDKIT_CONTAINER, environment: env.CLOUDKIT_ENVIRONMENT,
        keyID: env.CLOUDKIT_KEY_ID, privateKeyPEM: env.CLOUDKIT_PRIVATE_KEY, clock, fetchImplementation: guardedFetch,
        isEnabled: () => activeGatewayConfiguration(env, clock())?.publicRecordsEnabled === true });
      checkpoint = new PublicRegistryCheckpoint({ registry, client });
      publicRecords = new CloudKitPublicRepository({ authentication, clock, registry, client, checkpoint });
      if (config.communityEnabled || storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='community_accounts_v1'").toArray().length) communityState = new CommunityState(storage, { clock });
      const avatarPolicy = config.avatarReadEnabled || config.avatarUploadEnabled || config.avatarReviewEnabled || config.avatarOwnerPreviewEnabled ? new AvatarPolicyState(storage, { registry, clock }) : undefined;
      if (avatarPolicy) avatarWithdrawal = new AvatarPublicationCoordinator({ state: avatarPolicy, authentication, communityState,
        profileRepository: publicRecords, checkpoint, isEnabled: isAvatarWithdrawalEnabled, withdrawalOnly: true });
      const avatarReferences = config.avatarReadEnabled ? new CommunityAvatarReferences({ avatarPolicy, communityState, clock, isEnabled: isAvatarReadEnabled }) : undefined;
      if (config.communityEnabled) community = new CommunityCoordinator({ state: communityState, authentication, repository: publicRecords, avatarReferences,
        clock, cursorSecret: env.REQUEST_BUDGET_KEY, phrasesJSON: env.COMMUNITY_BLOCKED_PHRASES_JSON ?? "[]", supportURL: env.COMMUNITY_SUPPORT_URL ?? "" });
      if (config.avatarReadEnabled) avatarReader = new CloudKitAvatarReader({ authentication, communityState,
        avatarPolicy, profileRepository: publicRecords, registry, client, checkpoint,
        clock, isEnabled: isAvatarReadEnabled, verifiedDownloadHosts: config.avatarDownloadHosts, fetchImplementation: guardedFetch });
      if (config.avatarOwnerPreviewEnabled) avatarOwnerPreview = new CloudKitAvatarOwnerPreview({ authentication, communityState,
        avatarPolicy, registry, client, checkpoint, clock, isEnabled: isAvatarOwnerPreviewEnabled,
        verifiedDownloadHosts: config.avatarDownloadHosts, fetchImplementation: guardedFetch });
      if (config.avatarReviewEnabled) avatarReview = new AvatarReviewCoordinator({ authentication, communityState,
        avatarPolicy, receipts: new AvatarReviewReceipts(storage, { clock }), registry, client, checkpoint,
        clock, isEnabled: isAvatarReviewEnabled, isOperator: isAvatarReviewer,
        verifiedDownloadHosts: config.avatarDownloadHosts, fetchImplementation: guardedFetch });
      if (config.avatarUploadEnabled) {
        if (typeof avatarNormalizerFactory !== "function") throw new Error();
        const normalizer = avatarNormalizerFactory(isAvatarUploadEnabled);
        const assets = new CloudKitAvatarAssets({ container: env.CLOUDKIT_CONTAINER, environment: env.CLOUDKIT_ENVIRONMENT,
          keyID: env.CLOUDKIT_KEY_ID, privateKeyPEM: env.CLOUDKIT_PRIVATE_KEY, registry, checkpoint, clock,
          receiptVault: new AvatarReceiptVault({ activeKeyID: env.REFRESH_ACTIVE_KEY_ID, keys: refreshKeys }),
          verifiedUploadHosts: config.avatarUploadHosts, isEnabled: isAvatarUploadEnabled, fetchImplementation: guardedFetch });
        const avatars = new CloudKitAvatarRepository({ registry, checkpoint, assets, client, authentication, isEnabled: isAvatarUploadEnabled });
        avatarPublication = new AvatarPublicationCoordinator({ state: avatarPolicy, authentication, communityState, normalizer,
          avatarRepository: avatars, profileRepository: publicRecords, checkpoint, isEnabled: isAvatarUploadEnabled });
      }
    }
    const limits = new GatewayLimits(storage, { clock });
    const deletions = new AccountDeletionState(storage, { clock });
    const localMaintenance = new GatewayMaintenance(storage, { clock, limits, deletions });
    const afterCheckpoint = async action => {
      let result;
      try { result = await action(); }
      catch (error) { await checkpoint?.advance(); throw error; }
      await checkpoint?.advance(); return result;
    };
    const maintenance = checkpoint ? {
      schedule: () => localMaintenance.schedule(),
      alarm: options => activeGatewayConfiguration(env, clock())?.publicRecordsEnabled === true
        ? afterCheckpoint(() => localMaintenance.alarm(options))
        : localMaintenance.alarm({ processor: undefined }),
    } : localMaintenance;
    const login = new AppleLoginCoordinator({ state: authentication, verifier, credentialVault,
      exchangeAuthorizationCode: input => apple.exchangeAuthorizationCode(input) });
    const renewal = new SessionRenewalCoordinator({ state: authentication, verifier, credentialVault, appleClient: apple });
    const sessionReset = new SessionResetCoordinator({ state: authentication, verifier });
    const deletionCoordinator = new AccountDeletionCoordinator({ authenticationState: authentication, deletionState: deletions, verifier });
    const localProcessor = config.deletionEnabled ? new AccountDeletionProcessor({ deletionState: deletions, credentialVault,
      appleClient: apple, erasePublicDataBatch: publicRecords
        ? async context => {
          const receipt = await publicRecords.erasePublicDataBatch(context);
          if (!receipt.remaining && communityState) { await communityState.eraseOwner(context.accountID); await checkpoint.advance(); }
          return receipt;
        } : erasePublicDataBatch }) : undefined;
    const processor = checkpoint ? { step: async deletionID => {
      await checkpoint.verify(); return afterCheckpoint(() => localProcessor.step(deletionID));
    } } : localProcessor;
    const handle = createGatewayHTTPHandler({ authentication, login, renewal, sessionReset, deletions, deletionCoordinator,
      deletionEnabled: config.deletionEnabled, limits, scheduleMaintenance: () => maintenance.schedule(), checkpoint,
      avatarReader, isAvatarReadEnabled, avatarOwnerPreview, isAvatarOwnerPreviewEnabled,
      avatarPublication, isAvatarUploadEnabled, avatarWithdrawal, isAvatarWithdrawalEnabled,
      avatarReview, isAvatarReviewEnabled, isAvatarReviewer, clock,
      community, isCommunityEnabled: () => activeGatewayConfiguration(env, clock())?.communityEnabled === true,
      isEnabled: () => activeGatewayConfiguration(env, clock()) !== null && (checkpoint !== undefined || !hasRegistryCheckpoint(storage)) });
    return Object.freeze({ handle, maintenance, processor, publicRecords });
  } catch { throw new Error("Gateway configuration is unavailable."); }
}

/** Local retention remains callable after activation expires or provider secrets have been removed. */
export function createGatewayLocalMaintenance(storage, { clock = Date.now } = {}) {
  const limits = new GatewayLimits(storage, { clock }), deletions = new AccountDeletionState(storage, { clock });
  return new GatewayMaintenance(storage, { clock, limits, deletions });
}

export function handleAuthorityRequest(request, { runtime, env, objectID, clock = Date.now } = {}) {
  try {
    if (!activeGatewayConfiguration(env, clock()) || !runtime ||
        objectID.toString() !== env.COMMUNITY_AUTHORITY.idFromName(authorityName).toString() ||
        new URL(request.url).hostname !== "echoes-authority.internal" ||
        !/^[a-f0-9]{64}$/.test(request.headers.get("X-Echoes-Request-Budget") ?? "")) throw new Error();
    return runtime.handle(request, request.headers.get("X-Echoes-Request-Budget"));
  } catch { return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503); }
}

/** Thin public edge: only this boundary reads the platform client IP. All accounts use one private authority. */
const claimAvatarMutationEdge = avatarMutationAdmission();
const claimAvatarReviewEdge = avatarReviewAdmission();
const claimAvatarOwnerPreviewEdge = avatarOwnerPreviewAdmission();
export async function forwardGatewayRequest(request, env, { clock = Date.now } = {}) {
  let avatarDeadline, mutationDeadline, mutationAdmission, reviewDeadline, reviewAdmission, reviewAction, reviewRequest, previewDeadline, previewAdmission, previewBytes, previewSelection, previewRequest, isPreview = false;
  try {
    const { path } = inspectGatewayRequest(request);
    if (path === "/health") return gatewayJSON({ status: "ok", mode: "development-gateway" });
    const config = activeGatewayConfiguration(env, clock());
    if (!config) return gatewayJSON({ error: "GATEWAY_DISABLED" }, 503);
    const preview = isPreview = path === avatarOwnerPreviewPath;
    if (preview) {
      if (!config.avatarOwnerPreviewEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      const headers = avatarOwnerPreviewHeaders(request); previewAdmission = claimAvatarOwnerPreviewEdge();
      previewDeadline = avatarHTTPDeadline(request.signal, 15000);
      previewBytes = await previewAdmission.run(previewDeadline, () => avatarMutationBody(request, headers, previewDeadline.signal));
      try { previewSelection = avatarOwnerPreviewInput(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(previewBytes))); }
      catch { throw new AvatarReadError("AVATAR_READ_INPUT"); }
    }
    reviewAction = avatarReviewPaths.get(path);
    if (reviewAction) {
      if (!config.avatarReviewEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      avatarReviewHeaders(request); reviewAdmission = claimAvatarReviewEdge();
      reviewDeadline = avatarReviewDeadline(request.signal, 15000);
    }
    const avatar = path === avatarReadPath;
    const mutation = avatarMutationPaths.get(path);
    const withdrawal = mutation === "status" || mutation === "clear";
    if (mutation) {
      if (!(config.avatarUploadEnabled || withdrawal && (config.avatarReadEnabled || config.avatarReviewEnabled || config.avatarOwnerPreviewEnabled))) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      avatarMutationHeaders(request, mutation);
      mutationAdmission = claimAvatarMutationEdge(mutation);
      mutationDeadline = avatarMutationDeadline(request.signal, 25000);
    }
    if (avatar && !config.avatarReadEnabled) return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
    if (avatar) {
      const length = request.headers.get("Content-Length");
      if (length !== null && (!/^\d{1,7}$/.test(length) || Number(length) > avatarReadInputLimit)) return gatewayJSON({ error: "BODY_TOO_LARGE" }, 413);
      avatarDeadline = avatarHTTPDeadline(request.signal, 15000);
    }
    if (!request.cf || typeof request.cf.colo !== "string" || !/^[A-Z]{3}$/.test(request.cf.colo)) throw new Error();
    const budget = edgeBudgetHash(request.headers.get("CF-Connecting-IP"), env.REQUEST_BUDGET_KEY, clock());
    const headers = new Headers();
    for (const name of ["Content-Type", "Content-Length", "Content-Encoding", "Authorization"]) {
      if (request.headers.has(name)) headers.set(name, request.headers.get(name));
    }
    if (mutation === "upload") headers.set(avatarIntentHeader, request.headers.get(avatarIntentHeader));
    headers.set("X-Echoes-Request-Budget", budget);
    const forwarded = new Request("https://echoes-authority.internal" + path, {
      method: request.method, headers, body: preview ? previewBytes : request.body, redirect: "manual", duplex: "half",
      ...(avatar || mutation || reviewAction || preview ? { signal: avatarDeadline?.signal ?? mutationDeadline?.signal ?? reviewDeadline?.signal ?? previewDeadline.signal } : {}),
    });
    if (reviewAction) reviewRequest = forwarded;
    if (preview) previewRequest = forwarded;
    const id = env.COMMUNITY_AUTHORITY.idFromName(authorityName);
    const fetchAuthority = () => env.COMMUNITY_AUTHORITY.get(id).fetch(forwarded);
    const response = preview ? await previewAdmission.run(previewDeadline, fetchAuthority) : reviewAction ? await reviewAdmission.run(reviewDeadline, fetchAuthority) : mutation ? await mutationAdmission.run(mutationDeadline, fetchAuthority) : avatar ? await avatarDeadline.run(fetchAuthority) : await fetchAuthority();
    if (preview) {
      const enabled = () => { const active = activeGatewayConfiguration(env, clock());
        return active?.avatarOwnerPreviewEnabled === true && active.avatarDownloadHosts.join() === config.avatarDownloadHosts.join(); };
      if (!enabled()) { void response?.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      const result = await previewAdmission.run(previewDeadline, () => avatarOwnerPreviewEdgeResponse(response, previewDeadline, { selection: previewSelection }));
      if (!enabled()) { void result.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      previewDeadline.check(); return result;
    }
    if (reviewAction) {
      const enabled = () => {
        const active = activeGatewayConfiguration(env, clock());
        return active?.avatarReviewEnabled === true && active.avatarDownloadHosts.join() === config.avatarDownloadHosts.join()
          && active.avatarReviewers.join() === config.avatarReviewers.join();
      };
      if (!enabled()) { void response?.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      const result = await reviewAdmission.run(reviewDeadline, () => avatarReviewEdgeResponse(response, reviewAction, reviewDeadline, clock));
      if (!enabled()) { void result.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      reviewDeadline.check(); return result;
    }
    if (mutation) {
      const enabled = () => {
        const current = activeGatewayConfiguration(env, clock());
        return current?.avatarUploadEnabled && current.avatarUploadHosts.join() === config.avatarUploadHosts.join() ||
          withdrawal && current?.avatarReadEnabled && current.avatarDownloadHosts.join() === config.avatarDownloadHosts.join() ||
          withdrawal && current?.avatarOwnerPreviewEnabled && current.avatarDownloadHosts.join() === config.avatarDownloadHosts.join() ||
          withdrawal && current?.avatarReviewEnabled && current.avatarDownloadHosts.join() === config.avatarDownloadHosts.join()
            && current.avatarReviewers.join() === config.avatarReviewers.join();
      };
      if (!enabled()) { void response?.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      const result = await mutationAdmission.run(mutationDeadline, () => avatarMutationEdgeResponse(response, mutationDeadline));
      if (!enabled()) { void result.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503); }
      mutationDeadline.check(); return result;
    }
    if (avatar) {
      const active = activeGatewayConfiguration(env, clock());
      if (!active?.avatarReadEnabled || active.avatarDownloadHosts.join() !== config.avatarDownloadHosts.join()) {
        void response?.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
      }
      {
        const result = [200, 204].includes(response?.status)
          ? await avatarEdgeResponse(response, avatarDeadline) : await avatarEdgeErrorResponse(response, avatarDeadline);
        const latest = activeGatewayConfiguration(env, clock());
        if (!latest?.avatarReadEnabled || latest.avatarDownloadHosts.join() !== config.avatarDownloadHosts.join()) {
          void result.body?.cancel().catch(() => {}); return gatewayJSON({ error: "FEATURE_DISABLED" }, 503);
        }
        avatarDeadline.check(); return result;
      }
    }
    if (!(response instanceof Response) || ![200, 202, 204, 400, 401, 403, 404, 405, 408, 409, 413, 415, 429, 503].includes(response.status) ||
        (response.status !== 204 && !/^application\/json(?:\s*;|$)/i.test(response.headers.get("Content-Type") ?? ""))) throw new Error();
    const safe = new Headers({ "Cache-Control": "no-store", Pragma: "no-cache", "X-Content-Type-Options": "nosniff" });
    if (response.status !== 204) safe.set("Content-Type", "application/json");
    if (/^\d{1,6}$/.test(response.headers.get("Retry-After") ?? "")) safe.set("Retry-After", response.headers.get("Retry-After"));
    if (response.headers.get("Allow") === "POST") safe.set("Allow", "POST");
    return new Response(response.body, { status: response.status, headers: safe });
  } catch (error) { return gatewayFailure(isPreview ? avatarOwnerPreviewError(error) : error); }
  finally {
    previewBytes?.fill(0); previewDeadline?.close(); previewAdmission?.close();
    if (previewRequest?.body && !previewRequest.body.locked) void previewRequest.body.cancel().catch(() => {});
    if (previewDeadline && request.body && !request.body.locked) void request.body.cancel().catch(() => {});
    avatarDeadline?.close(); mutationDeadline?.close(); mutationAdmission?.close(); reviewDeadline?.close(); reviewAdmission?.close();
    if (reviewAction && request.body && !request.body.locked) void request.body.cancel().catch(() => {});
    if (reviewRequest?.body && !reviewRequest.body.locked) void reviewRequest.body.cancel().catch(() => {});
  }
}
