/** No network, storage, or returned signature. Uses only a server-configured diagnostic UUID. */
export function inspectDevelopmentRuntime(signer, runID) {
  let phase = "validation";
  try {
    const request = signer.request("records/lookup", {
      records: [{ recordName: "gateway-probe-" + runID }], desiredKeys: ["schemaVersion"],
    }, new Date(), (value) => { phase = value; });
    const signaturePresent = Boolean(request.headers.get("X-Apple-CloudKit-Request-SignatureV1"));
    return { mode: "local-runtime-check", requestConstructed: true, signaturePresent,
      networkRequests: 0, cloudKitWrites: 0 };
  } catch (error) {
    const allowedNames = new Set(["TypeError", "RangeError", "NotSupportedError", "InvalidAccessError"]);
    const allowedCodes = new Set(["ERR_INVALID_ARG_TYPE", "ERR_INVALID_THIS", "ERR_NOT_IMPLEMENTED"]);
    const knownArgument = ["options.key", "options.dsaEncoding", "key", "data", "algorithm"].find(
      value => typeof error?.message === "string" && error.message.includes(value));
    return { mode: "local-runtime-check", requestConstructed: false, networkRequests: 0, cloudKitWrites: 0,
      errorName: allowedNames.has(error?.name) ? error.name : "RuntimeError",
      phase, errorArgument: knownArgument ?? "unknown",
      errorCode: allowedCodes.has(error?.code) ? error.code : "REQUEST_CONSTRUCTION_FAILED" };
  }
}
