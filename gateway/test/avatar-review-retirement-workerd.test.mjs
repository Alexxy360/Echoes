import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync } from "node:crypto";
import { avatarUploadHTTPFixture } from "./support/avatar-upload-http-fixture.mjs";
import { avatarWorker } from "./support/workerd-image-harness.mjs";
import { sqliteSnapshot } from "./support/sqlite-snapshot.mjs";
import { syntheticPublicKeyConfiguration } from "./support/public-record-fixture.mjs";

test("actual local workerd fences an upload decision through HTTP after Runtime recreation and permits a newly inspected decision", { timeout: 30000 }, async () => {
  const f = await avatarUploadHTTPFixture(); let worker;
  try {
    f.advance(Math.max(0,Date.now()-f.clock()));const author=await f.relogin();worker=await avatarWorker();
    const input={synthetic:"echoes-owned-upload-http-v1",review:true,retirement:true,now:f.clock(),token:author.sessionToken,
      intent:f.body("upload"),source:Buffer.from(f.sourceBytes).toString("base64"),tables:sqliteSnapshot(f.db),
      records:[...f.model.records.values(),...f.model.controls.values()],privateKeyPEM:syntheticPublicKeyConfiguration().CLOUDKIT_PRIVATE_KEY,
      signInPrivateKeyPEM:generateKeyPairSync("ec",{namedCurve:"prime256v1"}).privateKey.export({type:"pkcs8",format:"pem"})};
    const response=await fetch(new URL("/upload-proof",worker.origin),{method:"POST",headers:{"Content-Type":"application/json",Connection:"close"},body:JSON.stringify(input)});
    const body=await response.json();assert.equal(response.status,200,JSON.stringify(body));
    assert.deepEqual(body.retirementProof,{sealed:true,recoveredAfterRuntimeRecreation:true,lateRejected:true,oldEffectAbsent:true,sameDecisionID:true});
    assert.equal(body.review.approved,true);assert.equal(body.review.notPublished,true);assert.equal(body.review.exactReplay,true);
    assert.equal(body.downloads,2);assert.equal(body.uploads,2);assert.doesNotMatch(JSON.stringify(body),/sessionToken|SYNTHETIC-PRIVATE|downloadURL|https:/);
  }finally{if(worker)await worker.stop();f.close();}
});
