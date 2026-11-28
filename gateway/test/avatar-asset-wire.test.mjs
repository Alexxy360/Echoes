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
