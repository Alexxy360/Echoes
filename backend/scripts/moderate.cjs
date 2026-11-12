/* Run with an operator's Application Default Credentials, never from the iOS app. */
const { initializeApp, applicationDefault } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const args = process.argv.slice(2);
function option(key) {
  const index = args.indexOf(key);
  return index >= 0 ? args[index + 1] : undefined;
}
const project = option("--project"),
  action = option("--action") || "list",
  id = option("--id");
if (!project || !/^[a-z][a-z0-9-]+$/.test(project))
  throw new Error("Pass --project explicitly.");
initializeApp({ projectId: project, credential: applicationDefault() });
const db = getFirestore();
async function main() {
  if (action === "list") {
    const reports = await db
      .collection("communityReports")
      .where("status", "==", "open")
      .limit(100)
      .get();
    for (const report of reports.docs) {
      const data = report.data();
      console.log(
        JSON.stringify({
          reportID: report.id,
          messageID: data.messageID,
          reason: data.reason,
        }),
      );
    }
    return;
  }
  if (!id || !/^[A-Za-z0-9_-]{1,512}$/.test(id))
    throw new Error("Pass a valid --id.");
  if (!args.includes("--apply")) {
    console.log(
      `DRY RUN: ${action} ${id}. Re-run with --apply to change the named project.`,
    );
    return;
  }
  if (action === "hide" || action === "restore") {
    await db
      .doc(`communityMessages/${id}`)
      .update({ moderationStatus: action === "hide" ? "hidden" : "visible" });
  } else if (action === "suspend" || action === "unsuspend") {
    await db
      .doc(`communityAccounts/${id}`)
      .set({ suspended: action === "suspend" }, { merge: true });
    if (action === "suspend") await db.doc(`communityPresence/${id}`).delete();
  } else if (action === "resolve") {
    await db
      .doc(`communityReports/${id}`)
      .update({ status: "resolved", resolvedAt: Timestamp.now() });
  } else {
    throw new Error(
      "Unknown action. Use list, hide, restore, suspend, unsuspend or resolve.",
    );
  }
  console.log("Moderation action completed.");
}
main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
