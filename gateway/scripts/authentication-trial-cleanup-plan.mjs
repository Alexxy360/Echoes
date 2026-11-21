import { digest, plain, publicUUID } from '../src/public-record-schema.mjs';

/** Pure preparation for the single fresh auth-only trial. Never executes SQL or reaches a provider.
 * Stop the client, disable HTTP and revoke Apple's test consent before an operator applies this plan.
 * Values must be obtained from the phone's successful login and the exact private inventory.
 */
export function makeAuthenticationTrialCleanupPlan(input) {
  if (!plain(input) || Object.keys(input).sort().join() !== 'accountID,credentialID,subjectHash' ||
      !publicUUID.test(input.accountID ?? '') || !publicUUID.test(input.credentialID ?? '') ||
      !/^[a-f0-9]{64}$/.test(input.subjectHash ?? '')) throw new Error('Invalid exact authentication trial inventory.');
  const { accountID: a, credentialID: c, subjectHash: s } = input;
  const guard = `(SELECT count(*) FROM auth_accounts_v1)=1
    AND EXISTS(SELECT 1 FROM auth_accounts_v1 WHERE account_id='${a}' AND subject_hash='${s}' AND generation>0 AND disabled=0)
    AND NOT EXISTS(SELECT 1 FROM auth_refresh_credentials_v1 WHERE credential_id!='${c}' OR subject_hash!='${s}' OR account_id IS NOT '${a}' OR state!='bound')
    AND NOT EXISTS(SELECT 1 FROM auth_credential_reservations_v1)
    AND NOT EXISTS(SELECT 1 FROM auth_renewal_grants_v1 WHERE account_id!='${a}' OR lease_id IS NOT NULL)
    AND NOT EXISTS(SELECT 1 FROM auth_sessions_v1 WHERE account_id!='${a}')
    AND NOT EXISTS(SELECT 1 FROM auth_apple_state_v1 WHERE account_id!='${a}' OR check_lease_id IS NOT NULL)
    AND NOT EXISTS(SELECT 1 FROM auth_subject_bans_v1)
    AND NOT EXISTS(SELECT 1 FROM auth_account_deletions_v1)
    AND NOT EXISTS(SELECT 1 FROM auth_deletion_revocations_v1)
    AND NOT EXISTS(SELECT 1 FROM auth_subject_fences_v1)
    AND NOT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='public_registry_checkpoint_v1')`;
  const checks = {
    accounts: `SELECT count(*) AS count FROM auth_accounts_v1 WHERE account_id='${a}' AND subject_hash='${s}';`,
    sessions: `SELECT count(*) AS count FROM auth_sessions_v1 WHERE account_id='${a}';`,
    grants: `SELECT count(*) AS count FROM auth_renewal_grants_v1 WHERE account_id='${a}';`,
    appleState: `SELECT count(*) AS count FROM auth_apple_state_v1 WHERE account_id='${a}';`,
    credentials: `SELECT count(*) AS count FROM auth_refresh_credentials_v1 WHERE subject_hash='${s}';`,
    reservations: `SELECT count(*) AS count FROM auth_credential_reservations_v1 WHERE subject_hash='${s}';`,
    challenge: `SELECT count(*) AS count FROM auth_challenges_v1 WHERE challenge_id='${c}';`,
    resetFence: `SELECT count(*) AS count FROM auth_session_reset_fences_v1 WHERE subject_hash='${s}';`,
  };
  const deletes = [
    ['auth_challenges_v1', `challenge_id='${c}' AND EXISTS(SELECT 1 FROM auth_refresh_credentials_v1 WHERE credential_id='${c}' AND account_id='${a}' AND subject_hash='${s}' AND state='bound')`],
    ['auth_sessions_v1', `account_id='${a}'`],
    ['auth_renewal_grants_v1', `account_id='${a}'`],
    ['auth_apple_state_v1', `account_id='${a}'`],
    ['auth_refresh_credentials_v1', `credential_id='${c}' AND subject_hash='${s}' AND account_id='${a}'`],
    ['auth_session_reset_fences_v1', `subject_hash='${s}'`],
  ].map(([table, predicate]) => `DELETE FROM ${table} WHERE ${predicate} AND (${guard});`);
  const remaining = Object.entries(checks).filter(([name]) => name !== 'accounts')
    .map(([, sql]) => '(' + sql.replace('SELECT count(*) AS count', 'SELECT count(*)').replace(/;$/, '') + ')=0').join(' AND ');
  deletes.push(`DELETE FROM auth_accounts_v1 WHERE account_id='${a}' AND subject_hash='${s}' AND (${guard}) AND ${remaining};`);
  const plan = { schemaVersion: 1, purpose: 'echoes-auth-only-trial-cleanup-v1',
    scope: { target: 'echoes-community-development', namespaceID: 'c56ebf43cfc246edb56e6615987b4c57', objectName: 'echoes-auth-authority-development-v1' },
    inventory: { ...input }, preflight: `SELECT CASE WHEN (${guard}) THEN 1 ELSE 0 END AS eligible;`, deletes, checks,
    prerequisites: ['explicit trial/cleanup approval', 'one account ID observed on the phone', 'private inventory bound to that ID',
      'client stopped and HTTP disabled', 'manual Apple test consent revocation confirmed', 'eligible=1 before each mutation phase'],
    semantics: 'Each statement rechecks scope; Data Studio statements are separate remote calls. A partial cleanup remains pending until every count is zero.',
    notProven: ['Apple OAuth server refresh/revoke', 'historical versions/PITR erasure', 'CloudKit erasure', 'absence of provider IO outside this controlled trial'],
    networkRequests: 0, executed: false };
  return { plan, sha256: digest(JSON.stringify(plan)) };
}
