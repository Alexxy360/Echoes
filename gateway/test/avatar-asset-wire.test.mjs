import test from "node:test";
import assert from "node:assert/strict";
import { avatarRecordFixture } from "./support/avatar-record-fixture.mjs";

test("asset create matches Apple's documented value-only Asset field form", async () => {
  const f = await avatarRecordFixture(); let observed = false;
  try {
    f.model.before = call => {
      if (call.operation !== "modify") return;
      const op = call.body.operations.find(op => op.record.recordName === f.name);
      if (!op) return;
      observed = true;
      for (const variant of ["image", "thumbnail"]) {
        const field = op.record.fields[variant];
        if (Object.hasOwn(field, "type")) return Response.json({ serverErrorCode: "BAD_REQUEST", reason: "SYNTHETIC unsupported explicit asset type" }, { status: 400 });
        assert.deepEqual(Object.keys(field), ["value"]);
        assert.equal(field.value.size, f.descriptor[variant].byteCount);
        assert.equal(typeof field.value.receipt, "string");
      }
    };
    const result = await f.make().stage(f.input());
    assert.equal(observed, true); assert.equal(result.status, "staged");
  } finally { f.close(); }
});
test("fetched ASSETID fields observed in CloudKit preserve exact receipt commitments", async () => {
  const f = await avatarRecordFixture();
  try {
    f.setRecordHook(() => {
      for (const record of f.model.records.values()) if (record.recordType === "EchoesAvatarV1") {
        for (const v of ["image", "thumbnail"]) record.fields[v].type = "ASSETID";
      }
    });
    assert.equal((await f.make().stage(f.input())).status, "staged");
  } finally { f.close(); }
});
test("unrecognized fetched asset labels remain rejected by the normal repository", async () => {
  const f = await avatarRecordFixture();
  try {
    f.setRecordHook(() => {
      for (const record of f.model.records.values()) if (record.recordType === "EchoesAvatarV1") record.fields.image.type = "UNKNOWN_ASSET";
    });
    await assert.rejects(f.make().stage(f.input()), error => error.code === "PUBLIC_RESPONSE");
  } finally { f.close(); }
});
