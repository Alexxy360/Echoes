/** Normalize only equivalent HTTPS authority spellings, never the provider path or signed query.
 * Callers still enforce their exact host allowlist, HTTPS, port, credentials and fragment guards.
 */
export function normalizeHTTPSAssetAuthority(value) {
  return value.replace(/^https:\/\/([a-z0-9.-]+)(?::443)?(?=\/)/i,
    (_match, host) => "https://" + host.toLowerCase());
}
