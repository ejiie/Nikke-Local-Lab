"use strict";
// Actual editor and module, synthetic accounts/transport only.
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict");
const {chromium}=require("playwright");
const root=path.resolve(__dirname,"../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
(async()=>{
 const browser=await chromium.launch({channel:"msedge",headless:true});
 const output=path.resolve(process.argv[2]);fs.mkdirSync(output,{recursive:true});
 try {
  const page=await browser.newPage({viewport:{width:1280,height:900}}),errors=[];
  page.on("pageerror",e=>errors.push(e.message));
  await page.route("**/*",route=>{
   const url=new URL(route.request().url());
   if(url.pathname.startsWith("/admin-api/")) return route.fulfill({status:503,json:{code:"synthetic_unconfigured"}});
   if(url.pathname.endsWith(".png")) return route.fulfill({contentType:"image/svg+xml",body:'<svg xmlns="http://www.w3.org/2000/svg" width="60" height="60"><circle cx="30" cy="30" r="29" fill="#0af"/><text x="22" y="38" fill="white">N</text></svg>'});
   const leaf=url.pathname.endsWith("/")?"index.html":path.basename(url.pathname);
   if(!["index.html","editor.js","editor.css","account-directory.js","boss-seasons.js","union-raid.js","user-validation.js"].includes(leaf))return route.fulfill({status:404,body:""});
   return route.fulfill({body:fs.readFileSync(path.join(root,leaf)),contentType:leaf.endsWith(".js")?"text/javascript":leaf.endsWith(".css")?"text/css":"text/html"});
  });
  await page.goto("http://127.0.0.1:18795/editor/");
  await page.evaluate(()=>{
   document.getElementById("app-shell").inert=false;
   window.selected=[];window.writes=[];window.reloads=0;
   window.beginCreate=()=>NllAccountDirectory.create({api:async(url,options)=>{writes.push(options.body);return {payload:{accountUid:"new-account"}};},reload:async()=>reloads++,select:async uid=>selected.push(uid)});
  });
  assert.equal(await page.locator('.main-nav [data-tab="import"]').count(),0);
  await page.evaluate(()=>{beginCreate();});
  await page.getByRole("button",{name:"아니오",exact:true}).click();assert.equal(await page.locator("dialog:modal").count(),0);
  await page.evaluate(()=>{beginCreate();});await page.getByRole("button",{name:"예",exact:true}).click();
  await page.getByRole("button",{name:"취소",exact:true}).click();assert.equal(await page.evaluate(()=>writes.length),0);
  await page.evaluate(()=>{beginCreate();});await page.getByRole("button",{name:"예",exact:true}).click();
  await page.getByLabel("닉네임",{exact:true}).fill("새 지휘관");await page.locator("dialog:modal").getByLabel("관리용 계정 이름",{exact:true}).fill("테스트 관리 이름");
  await page.screenshot({path:path.join(output,"create-account.png")});
  await page.locator("dialog:modal").getByRole("button",{name:"확인",exact:true}).click();
  await page.getByRole("dialog",{name:"계정이 생성되었습니다."}).waitFor();
  await page.locator("dialog:modal").getByLabel("다시 보지 않기").check();await page.locator("dialog:modal").getByRole("button",{name:"확인",exact:true}).click();
  assert.equal(await page.evaluate(()=>localStorage.getItem("nll.hide-account-created")),"1");
  assert.deepEqual(await page.evaluate(()=>[writes[0].displayName,writes[0].accountLabel,selected[0],reloads]),["새 지휘관","테스트 관리 이름","new-account",1]);
  await page.evaluate(()=>{
   const accounts=[{accountUid:"first",accountLabel:"관리1"},{accountUid:"second",accountLabel:"관리2"}];
   NllAccountDirectory.render({list:document.getElementById("account-list"),
    unions:[{unionUid:"u1",displayId:1,name:"NLL",level:3,members:[{accountUid:"first"}]},{unionUid:"u2",displayId:2,name:"가져온 유니온",level:7,members:[{accountUid:"second"}]}],
    accounts,lobbies:new Map([["first",{displayName:"합성 멤버"}]]),selected:"first",select:async uid=>selected.push(uid),
    profile:async()=>({values:[{fieldCode:"synchro_level",integerValue:1200}]})});
  });
  assert.equal(await page.locator("#account-list > li").count(),2);
  await page.locator('[data-union-uid="u1"]').click();
  assert.equal(await page.locator(".union-member-row").count(),1);
  assert.equal(await page.locator(".members-instruction").innerText(),"리스트를 클릭하여 해당 멤버의 계정을 선택할 수 있습니다.");
  assert.equal(await page.locator(".member-synchro").innerText(),"싱크로 레벨: 1200");
  assert.ok(await page.locator(".union-member-row .member-portrait").evaluate(e=>e.complete&&e.naturalWidth>0));
  await page.screenshot({path:path.join(output,"union-members.png")});
  await page.locator(".union-member-row").click();assert.equal(await page.evaluate(()=>selected.at(-1)),"first");
  // The real settings handler: cancel warning must not start collection; accept sends CSRF and selected account.
  let connections=0;
  await page.route("**/admin-api/v1/accounts/00000000-0000-4000-8000-000000000002/connection",route=>{
   connections++;assert.equal(route.request().headers()["x-nll-csrf"],"synthetic-csrf");
   return route.fulfill({json:{choices:[{area:83,label:"대한민국",characterCount:2}]}});
  });
  await page.evaluate(()=>{state.accountUid="00000000-0000-4000-8000-000000000002";state.profileRevisionUid="00000000-0000-4000-8000-000000000003";state.csrf="synthetic-csrf";connectSelectedAccount();});
  await page.getByRole("button",{name:"취소",exact:true}).click();assert.equal(connections,0);
  await page.evaluate(()=>{connectSelectedAccount();});
  await page.locator("dialog:modal").getByLabel("다시 보지 않기").check();await page.locator("dialog:modal").getByRole("button",{name:"확인",exact:true}).click();
  await page.getByLabel("서버 선택").waitFor();assert.equal(connections,1);
  await page.getByRole("button",{name:"취소",exact:true}).click();
  assert.equal(await page.evaluate(()=>localStorage.getItem("nll.hide-account-import-warning")),"1");
  let imports=0;
  await page.route("**/admin-api/v1/accounts/00000000-0000-4000-8000-000000000002/synchronize",route=>{
   imports++;assert.equal(route.request().headers()["x-nll-csrf"],"synthetic-csrf");
   assert.deepEqual(route.request().postDataJSON(),{area:83,expectedProfileRevisionUid:"00000000-0000-4000-8000-000000000003"});
   return route.fulfill({json:{statusCode:"completed"}});
  });
  await page.evaluate(()=>{
   listAccounts=async()=>{state.unions=[{unionUid:"imported",displayId:2,name:"가져온 유니온",level:7,members:[{accountUid:state.accountUid,imported:true}]}];};
   loadAccount=async()=>renderAccounts();connectSelectedAccount();
  });
  await page.getByLabel("서버 선택").waitFor();
  await page.locator("dialog:modal").getByRole("button",{name:"확인",exact:true}).click();
  await page.waitForFunction(()=>document.getElementById("account-sync").textContent==="계정 동기화");
  assert.equal(imports,1);assert.ok((await page.locator("#account-list").innerText()).includes("가져온 유니온"));
  assert.deepEqual(errors,[]);console.log("Account directory: create/cancel/default preferences, registered members, portrait, selection, import warning and CSRF passed.");
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});


