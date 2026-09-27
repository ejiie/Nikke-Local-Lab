"use strict";
// Real editor scripts with synthetic local transport; no installed account writes.
const fs = require("node:fs"), path = require("node:path"), assert = require("node:assert/strict");
const { chromium } = require("playwright");
const editor = path.resolve(__dirname, "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
(async () => {
  const browser = await chromium.launch({channel:"msedge",headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1280,height:900}});
    let authorized=false, bootstrapCount=0, failAccounts=false;
    const errors=[]; page.on("pageerror",error=>errors.push(error.message));
    await page.route("**/*",async route=>{
      const request=route.request(), url=new URL(request.url());
      if(url.pathname==="/admin-auth/v1/bootstrap") {
        assert.equal(request.postDataJSON().code,"synthetic-start-code");
        authorized=true;bootstrapCount++;return route.fulfill({json:{statusCode:"ready"}});
      }
      if(url.pathname.startsWith("/admin-api/")) {
        if(!authorized) return route.fulfill({status:401,json:{code:"unauthorized"}});
        if(url.pathname.endsWith("/security/csrf")) return route.fulfill({json:{requestToken:"synthetic-csrf"}});
        if(url.pathname==="/admin-api/v1/accounts") return route.fulfill(failAccounts
          ? {status:503,json:{code:"synthetic_accounts_unavailable"}} : {json:[]});
        if(url.pathname==="/admin-api/v1/unions") return route.fulfill({json:[]});
        if(url.pathname.endsWith("/boss-onboarding-jobs")) return route.fulfill({json:[]});
        return route.fulfill({status:503,json:{code:"synthetic_not_configured"}});
      }
      if(url.pathname==="/editor/presentation.json") return route.fulfill({json:{contractId:"nll/control-center-presentation/v1",characters:[]}});
      const leaf=url.pathname==="/editor/"?"index.html":path.basename(url.pathname);
      if(!["index.html","editor.js","account-directory.js","editor.css","boss-seasons.js","user-validation.js"].includes(leaf)) return route.fulfill({status:404,body:""});
      return route.fulfill({body:fs.readFileSync(path.join(editor,leaf)),contentType:leaf.endsWith(".js")?"text/javascript":leaf.endsWith(".css")?"text/css":"text/html"});
    });
    await page.goto("http://127.0.0.1:18791/editor/");
    assert.equal(await page.locator("#login-screen,#bootstrap-code,#admin-login").count(),0);
    assert.equal(await page.locator("#app-shell").isVisible(),true);
    assert.equal(await page.locator("#app-shell").evaluate(e=>e.inert),true);
    await page.evaluate(()=>startAdminSession("synthetic-start-code"));
    assert.equal(await page.locator("#app-shell").evaluate(e=>e.inert),false);
    await page.locator('.main-nav [data-tab="nikkes"]').click();
    assert.equal(await page.locator("#page-title").innerText(),"니케 관리");
    assert.equal(await page.locator("body").innerText().then(s=>s.includes("synthetic-start-code")),false);
    await page.reload();await page.evaluate(()=>startAdminSession());
    assert.equal(bootstrapCount,1);
    assert.equal(await page.locator("#app-shell").getAttribute("aria-busy"),"false");
    failAccounts=true;await page.reload();
    const failure=await page.evaluate(()=>startAdminSession().then(()=>null,error=>error.message));
    assert.equal(failure,"synthetic_accounts_unavailable");
    assert.equal(await page.locator("#app-shell").evaluate(e=>e.inert),true);
    assert.deepEqual(errors,[]);
    console.log("Direct startup: visible main shell, no login form/click, session resume, initialization failure checks passed.");
  } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
