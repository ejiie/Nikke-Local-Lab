"use strict";
// Checked-in UI, synthetic records only. Optional local artwork stays private.
const fs = require("node:fs"), path = require("node:path"), http = require("node:http");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const model = require("../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/raid-records.js");
const root = path.resolve(__dirname, "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
const output = path.resolve(process.argv[2]); fs.mkdirSync(output, { recursive: true });
const art = process.argv[3] && process.argv[3] !== "--serve" ? fs.readFileSync(process.argv[3]) : null;
const uiAssets = process.env.NLL_PREVIEW_UI_ASSETS;
const characters = ["캐릭터 A", "캐릭터 B", "캐릭터 C", "캐릭터 D", "캐릭터 E"].map((name, i) => ({ name, ordinal: i + 1,
  damage: String(1000000000 + i * 200000000), projectileExcludedDamage: String(1000000000 + i * 200000000 - 100),
  portraitPath: "/editor/test-portrait.svg" }));
const records = Array.from({ length: 8 }, (_, i) => ({ battleUid: "example-" + i, accountUid: "example-account", seasonNumber: 7,
  mode: i < 5 ? "practice" : "live", weaknessCode: ["iron", "fire", "iron", "water", "unknown"][i % 5],
  playedAt: "2026-09-19T" + String(20 - i).padStart(2, "0") + ":15:00+09:00", teamLabel: "덱 " + (i % 3 + 1) + " · 예시 편성",
  resultDamage: String(9000000000 - i * 100000000), projectileExcludedDamage: i === 0 ? "6999999500" : null,
  characters: characters.map(c => ({ ...c, projectileExcludedDamage: i === 0 ? c.projectileExcludedDamage : null })) }));
records.push({ ...records[0], accountUid: "another-account", battleUid: "cross-account" }, { ...records[0], seasonNumber: 8, battleUid: "cross-season" });
assert.equal(model.filter(records, { accountUid: "example-account", seasonNumber: 7 }, "practice", "iron").length, 2);
assert.equal(model.money("9007199254740993"), "9,007,199,254,740,993");
assert.equal(model.money(null), "미확인");
function fixtureSetup(records, hasArt) {
  document.getElementById("app-shell").inert = false;
  document.getElementById("app-shell").setAttribute("aria-busy", "false");
  for (const panel of document.querySelectorAll("[data-tab-panel]")) panel.hidden = panel.dataset.tabPanel !== "raid";
  for (const tab of document.querySelectorAll(".tab-button")) tab.setAttribute("aria-selected", String(tab.dataset.tab === "raid"));
  document.getElementById("top-account-name").textContent = "디자인 미리보기";
  document.getElementById("top-account-detail").textContent = "예시 데이터 · 실제 전투 기록 아님";
  document.querySelector('[data-tab-panel="raid"] .section-heading p:not(.eyebrow)').textContent = "예시 데이터로 구성한 화면입니다. 실제 전투 기록이 아닙니다.";
  window.recordsPreview = NllRaidRecords.create({ document, loadRecords: async () => records,
    loadAnalysis: async (account, battle) => {
      const row = records.find(r => r.accountUid === account && r.battleUid === battle);
      if (row.characters.some(c => c.projectileExcludedDamage == null)) return { status: "analysis_unavailable" };
      return { status: "ready", analysis: { characters: row.characters.map(c => ({ ordinal: c.ordinal, damage: c.projectileExcludedDamage,
        unclassifiedDamage: "0", components: [
          { category: "basic", origin: "basic", component: "unspecified", damage: "500000000", hits: 100,
            breakdown: [
              { kind: "normal", pelletThresholds: [], damage: "200000000", hits: 40, penetratingHits: 0, penetratingDamage: "0" },
              { kind: "enhanced", pelletThresholds: [80], damage: "150000000", hits: 30, penetratingHits: 30, penetratingDamage: "150000000" },
              { kind: "enhanced", pelletThresholds: [80,160], damage: "150000000", hits: 30, penetratingHits: 30, penetratingDamage: "150000000" }
            ] },
          ...(c.ordinal === 3 ? [
            { category: "skill", origin: "burst", component: "unspecified", effectKind: "InstantAll", damage: "100000000", hits: 1 },
            { category: "skill", origin: "burst", component: "unspecified", effectKind: "InstantSequentialAttack", damage: String(BigInt(c.projectileExcludedDamage) - 600000000n), hits: 6 }
          ] : [{ category: c.ordinal === 5 ? "automatic" : "replacement", origin: "burst", component: "collision", damage: String(BigInt(c.projectileExcludedDamage) - 500000000n), hits: 7 }])
        ] })) } };
    }
  });
  const catalog = { schemaVersion: 1, contractId: "nll/boss-season-catalog-view/v1", statusCode: "ready", catalogSha256: "a".repeat(64), maximumKnownSeason: 7,
    seasons: Array.from({ length: 7 }, (_, i) => ({ seasonNumber: i + 1, displayName: "울트라 [Z.E.U.S.]", defaultWeaknessCode: "iron", processingStatusCode: "processed",
      imageUrl: hasArt ? "/admin-api/v1/boss-seasons/" + (i + 1) + "/image?catalog=" + "a".repeat(64) : null })) };
  window.bossPreview = NllBossSeasons.create({ document, api: async p => ({ payload: p.endsWith("boss-seasons") ? catalog : [] }), onSelected: row => {
    void recordsPreview.setContext({ accountUid: "example-account", accountName: "예시 계정", seasonNumber: row.seasonNumber, bossName: row.displayName });
  } });
  void bossPreview.refreshCatalog().then(() => bossPreview.selectSeason(7));
}
const fixture = "(" + fixtureSetup.toString() + ")(" + JSON.stringify(records) + "," + Boolean(art) + ");";
let html = fs.readFileSync(path.join(root, "index.html"), "utf8");
html = html.replace(/<script src="\/editor\/(?:editor|account-directory|union-raid|user-validation)\.js" defer><\/script>/g, "");
html = html.replace("</head>", '<script src="/fixture.js" defer></script></head>');
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1");
  res.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'");
  if (url.pathname === "/" || url.pathname === "/editor/index.html") { res.setHeader("Content-Type", "text/html; charset=utf-8"); res.end(html); return; }
  if (url.pathname === "/fixture.js") { res.setHeader("Content-Type", "text/javascript; charset=utf-8"); res.end(fixture); return; }
  if (url.pathname === "/editor/test-portrait.svg") { res.setHeader("Content-Type", "image/svg+xml"); res.end('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#18adeb"/></svg>'); return; }
  if (url.pathname === "/production") { res.setHeader("Content-Type", "text/html; charset=utf-8"); res.end(fs.readFileSync(path.join(root, "index.html"))); return; }
  if (uiAssets && /^\/editor\/assets\/ui\/(app-icon\.ico|code-(fire|water|wind|electric|iron)\.png)$/.test(url.pathname)) {
    const file = path.join(uiAssets, path.basename(url.pathname));
    if (fs.existsSync(file)) { res.setHeader("Content-Type", file.endsWith(".ico") ? "image/x-icon" : "image/png"); fs.createReadStream(file).pipe(res); return; }
  }
  if (art && /^\/admin-api\/v1\/boss-seasons\/\d+\/image$/.test(url.pathname)) { res.setHeader("Content-Type", "image/png"); res.end(art); return; }
  const file = path.resolve(root, decodeURIComponent(url.pathname.replace(/^\/editor\//, "")));
  if (!url.pathname.startsWith("/editor/") || !file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  res.setHeader("Content-Type", file.endsWith(".css") ? "text/css" : file.endsWith(".js") ? "text/javascript" : "application/octet-stream");
  fs.createReadStream(file).pipe(res);
});
(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const url = "http://127.0.0.1:" + server.address().port;
  const browser = await chromium.launch({ channel: "msedge", headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1460, height: 1000 } });
    const errors = []; page.on("pageerror", e => errors.push(e.message));
    await page.goto(url); await page.waitForFunction(() => document.querySelectorAll(".raid-record-row").length === 5);
    assert.equal(await page.locator("#raid-records-count").textContent(), "5건");
    const card = await page.locator("#selected-boss-card").boundingBox(), panel = await page.locator("#raid-records").boundingBox();
    assert.ok(panel.x > card.x + card.width, "records must sit right of boss");
    await page.locator('#raid-records-elements [data-record-weakness="iron"]').click();
    assert.equal(await page.locator(".raid-record-row").count(), 2);
    await page.locator("#raid-records-live").click(); assert.equal(await page.locator(".raid-record-row").count(), 2);
    await page.locator('#raid-records-elements [data-record-weakness="wind"]').click();
    assert.equal(await page.locator(".raid-record-row").count(), 0);
    assert.equal(await page.locator("#raid-records-count").textContent(), "0건");
    await page.locator("#raid-records-practice").click();
    await page.locator('#raid-records-elements [data-record-weakness="all"]').click();
    await page.waitForTimeout(250);
    await page.screenshot({ path: path.join(output, "records-desktop.png") });
    await page.locator(".raid-record-row").first().click();
    assert.equal(await page.locator("#raid-record-characters li").count(), 5);
    assert.equal(await page.locator(".raid-record-metrics dt").textContent(), "Damage");
    assert.equal(await page.locator("#raid-record-characters .raid-record-character-damage").first().textContent(), "999,999,900");
    assert.equal(await page.locator("#raid-record-characters .raid-record-portrait img").count(), 5);
    const portraitBox = await page.locator("#raid-record-characters .raid-record-portrait").first().boundingBox();
    assert.equal(portraitBox.width, portraitBox.height);
    assert.equal(await page.locator("#raid-record-original").count(), 0);
    assert.equal(await page.locator('#raid-record-characters li[data-damage-rank="1"] .raid-record-character-damage').textContent(), "1,799,999,900");
    assert.equal(await page.locator('#raid-record-characters li[data-damage-rank="2"] .raid-record-character-damage').textContent(), "1,599,999,900");
    assert.equal(await page.locator('#raid-record-characters li[data-damage-rank="1"] .raid-record-damage-fill').evaluate(el => el.style.width), "100%");
    assert.equal(await page.locator('#raid-record-characters li[data-damage-rank="1"] .raid-record-character-damage').evaluate(el => getComputedStyle(el).color), "rgb(166, 48, 48)");
    await page.screenshot({ path: path.join(output, "record-detail.png") });
    await page.locator('#raid-record-characters li').nth(1).focus();
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelectorAll('.raid-analysis-group').length === 2);
    assert.equal(await page.locator('#raid-analysis-name').textContent(), '캐릭터 B 피해 구성');
    assert.equal(await page.locator('#raid-analysis-damage').textContent(), '1,199,999,900');
    assert.equal(await page.locator('#raid-record-dialog').evaluate(el => el.open), false);
    await page.locator('#raid-analysis-view-timeline').click();
    assert.equal(await page.locator('#raid-analysis-timeline').isVisible(), true);
    assert.equal(await page.locator('#raid-analysis-composition').isVisible(), false);
    assert.equal(await page.locator('#raid-analysis-page-title').textContent(), '타임라인');
    await page.locator('#raid-analysis-view-composition').click();
    assert.equal(await page.locator('#raid-analysis-composition').isVisible(), true);
    assert.equal(await page.locator('#raid-analysis-name').textContent(), '캐릭터 B 피해 구성');
    await page.screenshot({ path: path.join(output, 'character-composition.png') });
    assert.equal(await page.locator('.composition-basic .raid-analysis-effect').count(),1);
    assert.equal(await page.locator('.raid-analysis-segment').count(),2);
    await page.locator('#raid-analysis-split').check();
    assert.equal(await page.locator('.composition-basic .raid-analysis-effect').count(),3);
    assert.equal(await page.locator('.raid-analysis-segment').count(),4);
    assert.ok((await page.locator('#raid-analysis-content').textContent()).includes('160펠릿 조건'));
    assert.equal(await page.locator('#raid-analysis-damage').textContent(),'1,199,999,900');
    await page.locator('.raid-analysis-member').filter({hasText:'캐릭터 C'}).click();
    assert.equal(await page.locator('.composition-skill .raid-analysis-effect').count(),2);
    assert.ok((await page.locator('.raid-analysis-group.composition-skill').allTextContents()).join(' ').includes('순차 공격'));
    assert.equal(await page.locator('.raid-analysis-group.composition-skill').count(),2);
    assert.ok((await page.locator('.raid-analysis-group.composition-skill summary').allTextContents()).join(' ').includes('7.14%'));
    assert.equal(await page.locator('.raid-analysis-segment').count(),5);
    assert.ok((await page.locator('.raid-analysis-legend').textContent()).includes('버스트 · 전체 대상 공격7.14%'));
    assert.ok((await page.locator('.raid-analysis-legend').textContent()).includes('버스트 · 순차 공격57.14%'));
    const skillColors = await page.locator('.raid-analysis-segment.composition-skill').evaluateAll(nodes => nodes.map(n => getComputedStyle(n).backgroundColor));
    assert.notEqual(skillColors[0],skillColors[1]);
    await page.locator('#raid-analysis-split').uncheck();
    assert.equal(await page.locator('.composition-skill .raid-analysis-effect').count(),1);
    assert.equal(await page.locator('.raid-analysis-segment').count(),2);
    assert.ok((await page.locator('.raid-analysis-legend').textContent()).includes('스킬 직접 피해64.28%'));
    await page.locator('.raid-analysis-member').filter({hasText:'캐릭터 B'}).click();
    await page.locator('#raid-analysis-back').click();
    assert.equal(await page.locator('#raid-record-dialog').evaluate(el => el.open), true);
    await page.locator('#raid-record-analysis-open').click();
    await page.waitForFunction(() => document.querySelectorAll('.raid-analysis-group').length === 4);
    assert.equal(await page.locator('.raid-analysis-group.composition-automatic summary strong').textContent(), '자동 무기');
    assert.equal(await page.locator('#raid-analysis-damage').textContent(), '6,999,999,500');
    assert.equal(await page.locator('#raid-analysis-members button').count(), 6);
    await page.setViewportSize({ width: 390, height: 950 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.screenshot({ path: path.join(output, 'composition-narrow.png'), fullPage: true });
    await page.setViewportSize({ width: 1460, height: 1000 });
    await page.locator('#raid-analysis-back').click();
    await page.keyboard.press("Escape");
    await page.locator(".raid-record-row").nth(1).click();
    assert.equal(await page.locator("#raid-record-characters .raid-record-character-damage").first().textContent(), "분석값 없음");
    assert.equal(await page.locator("#raid-record-characters .raid-record-damage-track").count(), 0);
    await page.locator("#raid-record-dialog-close").click();
    await page.setViewportSize({ width: 720, height: 1150 });
    await page.screenshot({ path: path.join(output, "records-narrow.png"), fullPage: true });
    const nc = await page.locator("#selected-boss-card").boundingBox(), np = await page.locator("#raid-records").boundingBox();
    assert.ok(np.y > nc.y + nc.height, "narrow layout stacks");
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "no horizontal overflow");
    await page.evaluate(() => recordsPreview.setContext({ accountUid: "absent", seasonNumber: 7, bossName: "다른 계정" }));
    assert.equal(await page.locator(".raid-record-row").count(), 0);
    await page.evaluate(async records => {
      let release;
      const slow = NllRaidRecords.create({ document, loadRecords: () => new Promise(resolve => { release = resolve; }) });
      const old = slow.setContext({ accountUid: "example-account", seasonNumber: 7 });
      await slow.setContext({});
      release(records); await old;
    }, records);
    assert.equal(await page.locator(".raid-record-row").count(), 0, "late response cannot restore deselected account");
    await page.route("**/admin-api/**", route => route.fulfill({ status: 404, json: { code: "preview_unavailable" } }));
    await page.goto(url + "/production");
    await page.evaluate(() => {
      document.getElementById("app-shell").inert = false;
      document.querySelector('[data-tab-panel="raid"]').hidden = false;
      document.getElementById("boss-detail").hidden = false;
      state.accountUid = "example-account";
      state.selectedBossSeason = 7;
      updateRaidRecordContext("예시 계정");
    });
    await page.waitForFunction(() => document.getElementById("raid-records-empty-title").textContent === "기록을 불러오지 못했습니다");
    await page.locator("#raid-records-live").click();
    await page.locator('#raid-records-elements [data-record-weakness="water"]').click();
    assert.equal(await page.evaluate(() => state.selectedWeaknessCode), "iron", "record filter cannot change launch weakness");
    assert.equal(await page.locator("#raid-records-count").textContent(), "—", "unconnected is not zero records");
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(output, "result.json"), JSON.stringify({ status: "passed", scope: "synthetic UI only", url }, null, 2));
    console.log("PASS: filters, exact damage, detail, empty states, responsive layout. Preview: " + url);
  } finally { await browser.close(); if (!process.argv.includes("--serve")) server.close(); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
