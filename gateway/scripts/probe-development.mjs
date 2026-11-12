import { readFile } from "node:fs/promises";
import { CloudKitDevelopmentSigner } from "../src/cloudkit-request.mjs";
import { probeCloudKitDevelopment } from "../src/cloudkit-probe.mjs";

// Intentionally explicit opt-in. Merely running tests or importing helpers never contacts Apple.
if (process.env.ECHOES_ALLOW_SYNTHETIC_DEV_PROBE !== "1") {
  console.error("Synthetic Development probe is disabled; obtain approval and set the explicit opt-in.");
  process.exitCode = 2;
} else {
  try {
    const signer = new CloudKitDevelopmentSigner({
      container: "iCloud.mpvEcho.Echo", environment: "development",
      keyID: process.env.ECHOES_CK_DEV_KEY_ID,
      privateKeyPEM: await readFile(process.env.ECHOES_CK_DEV_KEY_FILE, "utf8"),
    });
    const report = await probeCloudKitDevelopment(signer);
    console.log(JSON.stringify(report, null, 2));
    if (!report.writeSucceeded || !report.readBackSucceeded || !report.cleanupSucceeded) process.exitCode = 1;
  } catch {
    console.error("Development probe configuration failed; no secret material is included in this message.");
    process.exitCode = 2;
  }
}
