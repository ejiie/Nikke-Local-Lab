"use strict";
// Entire browser network is synthetic. Never contacts a real API or UAC runner.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const editor = path.resolve(process.argv[2] || path.join(__dirname, "../src/NikkeLocalLab.Admin.Api/wwwroot/editor"));
const output = path.resolve(process.argv[3] || path.join(__dirname, "../artifacts/user-validation-browser"));
const weaknesses = ["fire", "water", "wind", "electric", "iron"];
const hash = "a".repeat(64);
const delivery = { schemaVersion: 1, contractId: "nll/user-validation-delivery-view/v1", seasonNumber: 29,
  statusCode: "awaiting_game_validation", bindingSha256: hash, actualGameAcceptanceClaimed: false,
  selections: weaknesses.map((weaknessCode, i) => ({ weaknessCode, assessmentUid: `20000000-0000-0000-0000-${String(i+1).padStart(12,"0")}`, entrySha256: String(i+1).repeat(64) })) };
const seasons = Array.from({length:34},(_,index)=>index+1).map(seasonNumber => ({ seasonNumber, displayName: `합성 보스 ${seasonNumber}`, defaultWeaknessCode: "iron",
  processingStatusCode: seasonNumber === 26 ? "processed" : seasonNumber === 29 ? "awaiting_game_validation" : "unprocessed", failureCode: null, imageUrl: null }));
(async () => {
  fs.mkdirSync(output,{recursive:true});
  const browser = await chromium.launch({headless:true});
  const errors=[], posts=[];
  try {
    const page = await browser.newPage({viewport:{width:1440,height:1100}});
    const states = new Map();
    page.on("pageerror", e=>errors.push(e.message));
    await page.route("**/*",async route=>{
      const request=route.request(),url=new URL(request.url());
      assert.equal(url.origin,"http://127.0.0.1:18788");
      const name=url.pathname.slice("/editor/".length);
      if(url.pathname.startsWith("/editor/") && ["","index.html","editor.js","editor.css","boss-seasons.js","user-validation.js"].includes(name))
        return route.fulfill({path:path.join(editor,name||"index.html"),contentType:name.endsWith(".js")?"text/javascript":name.endsWith(".css")?"text/css":"text/html"});
      let payload={};
      if(url.pathname.endsWith("/boss-seasons")) payload={schemaVersion:1,contractId:"nll/boss-season-catalog-view/v1",statusCode:"ready",catalogSha256:hash,maximumKnownSeason:34,currentSeasonStatusCode:"unresolved",seasons};
      else if(url.pathname.endsWith("/boss-onboarding-jobs")) payload=[];
      else if(url.pathname.endsWith("/boss-user-validation/29")) payload=delivery;
      else if(url.pathname.includes("/boss-user-validation/29/")) {
        const weaknessCode=url.pathname.split("/").at(-1);
        payload={schemaVersion:1,contractId:"nll/user-validation-action/v1",seasonNumber:29,weaknessCode,statusCode:"prepared",actualGameAcceptanceClaimed:false,...states.get(weaknessCode)};
      } else if(url.pathname.endsWith("/boss-user-validation-actions")) {
        assert.equal(request.method(),"POST"); const body=request.postDataJSON();posts.push(body);
        assert.equal(body.mode,"Start"); assert.equal(body.bindingSha256,hash);
        assert.equal(body.entrySha256,delivery.selections.find(s=>s.weaknessCode===body.weaknessCode).entrySha256);
        payload={schemaVersion:1,contractId:"nll/user-validation-action/v1",...body,statusCode:"uac_cancelled",actualGameAcceptanceClaimed:false};
        states.set(body.weaknessCode,payload);
      } else if(url.pathname.endsWith("/execution-preparation")) {
        assert.equal(posts.length,5); assert.equal(request.postDataJSON().seasonNumber,26);
        payload={statusCode:"blocked",failureCode:"synthetic_no_game"};
      } else if(request.method()==="POST") throw new Error("unexpected_mutation");
      else if(url.pathname.includes("/launch-preparation")) payload={statusCode:"blocked",failureCode:"synthetic_no_game"};
      else if(url.pathname.includes("/assets/")) return route.fulfill({status:404,body:""});
      await route.fulfill({json:payload});
    });
    await page.goto("http://127.0.0.1:18788/editor/");
    await page.evaluate(async()=>{byId("login-screen").hidden=true;byId("app-shell").hidden=false;setPage("raid");await bossSeasons.refreshCatalog();bossSeasons.selectSeason(29);});
    await page.waitForFunction(()=>!document.getElementById("user-validation-start").disabled);
    assert.equal(await page.locator("#selected-boss-card .boss-card").count(),1);
    assert.equal(await page.locator("#standard-boss-launch").isVisible(),false);
    assert.equal(posts.length,0);
    for(const weakness of ["water","fire","wind","electric","iron"]) {
      await page.locator(`.weakness-option[data-weakness-code="${weakness}"]`).click();
      await page.waitForFunction(()=>!document.getElementById("user-validation-start").disabled);
      await page.locator("#user-validation-start").click();
      await page.waitForFunction(()=>document.getElementById("user-validation-status").textContent==="관리자 권한 요청 취소");
    }
    assert.deepEqual(posts.map(p=>p.weaknessCode),["water","fire","wind","electric","iron"]);
    await page.screenshot({path:path.join(output,"validation-desktop.png"),fullPage:true});
    await page.setViewportSize({width:390,height:844});
    await page.screenshot({path:path.join(output,"validation-mobile.png"),fullPage:true});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.evaluate(()=>bossSeasons.selectSeason(26));
    assert.equal(await page.locator("#boss-user-validation").isVisible(),false);
    assert.equal(await page.locator("#standard-boss-launch").isVisible(),true);
    await page.evaluate(()=>bossSeasons.selectSeason(34));
    await page.locator("#boss-import-no").click();
    assert.equal(posts.length,5); assert.deepEqual(errors,[]);
    console.log(JSON.stringify({statusCode:"passed",fiveSyntheticUserClicks:5,realNetworkRequests:0,gameStarted:false,uacRequested:false,desktopAndMobileVerified:true}));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
