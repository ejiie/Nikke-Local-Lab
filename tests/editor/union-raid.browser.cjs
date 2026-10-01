"use strict";
// Real editor + synthetic local HTTP. No account writes or game launch.
const fs = require("node:fs"), path = require("node:path"), assert = require("node:assert/strict");
const { chromium } = require("playwright");
const editor = path.resolve(__dirname, "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
const hash = "a".repeat(64);
const weaknesses = ["wind", "electric", "fire", "iron", "water"];
const art = hue => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 120"><rect width="160" height="120" fill="hsl(${hue} 30% 82%)"/>` +
  `<ellipse cx="80" cy="70" rx="38" ry="34" fill="hsl(${hue} 35% 45%)"/></svg>`;
(async () => {
  const output = path.resolve(process.argv[2]); fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ channel: "msedge", headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    let posts = 0; const recordQueries = [];
    const catalog = { statusCode: "ready", catalogSha256: hash, seasons: Array.from({ length: 45 }, (_, n) => ({
      seasonNumber: n + 1, statusCode: n < 23 ? "unresolved" : n === 44 ? "assembled" : "available",
      failureCode: n < 23 ? "boss_union_hard_not_available" : null,
      bosses: n < 23 ? [] : Array.from({ length: 5 }, (_, order) => ({ order: order + 1,
        displayName: `합성 보스 ${order + 1} [S.Y.N.${order + 1}]`, weaknessCode: weaknesses[order],
        imageUrl: order === 4 ? null : `/admin-api/v1/union-raid/seasons/${n + 1}/bosses/${order + 1}/image?catalog=${hash}` })) })) };
    const characters = ["캐릭터 A", "캐릭터 B", "캐릭터 C", "캐릭터 D", "캐릭터 E"].map((name, i) => ({ name, ordinal: i + 1,
      projectileExcludedDamage: null, portraitPath: "/editor/test-portrait.svg" }));
    await page.route("**/*", async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.pathname === "/admin-api/v1/union-raid/seasons") return route.fulfill({ json: catalog });
      if (url.pathname === "/admin-api/v1/union-raid/jobs") {
        if (request.method() === "POST") { posts++; return route.fulfill({ status: 202, json: { ...request.postDataJSON(), statusCode: "queued" } }); }
        return route.fulfill({ json: [] });
      }
      const image = /^\/admin-api\/v1\/union-raid\/seasons\/45\/bosses\/(\d)\/image$/.exec(url.pathname);
      if (image) return route.fulfill({ body: art(Number(image[1]) * 60), contentType: "image/svg+xml" });
      if (/^\/admin-api\/v1\/accounts\/example-account\/raid-records$/.test(url.pathname)) {
        const query = Object.fromEntries(url.searchParams); recordQueries.push(query);
        const step = Number(query.step);
        return route.fulfill({ json: { nextCursor: null, records: Array.from({ length: step === 2 ? 0 : 3 }, (_, i) => ({
          battleUid: `example-${step}-${i}`, accountUid: "example-account", seasonNumber: 45, mode: i === 2 ? "live" : "practice",
          weaknessCode: weaknesses[step - 1], playedAt: `2026-10-01T${String(21 - i).padStart(2, "0")}:10:00+09:00`,
          teamLabel: `덱 ${i + 1}`, resultDamage: String(8000000000 - i * 700000000), characters })) } });
      }
      if (url.pathname.startsWith("/admin-api/")) return route.fulfill({ status: 503, json: { code: "synthetic_not_configured" } });
      const leaf = url.pathname.endsWith("/") ? "index.html" : path.basename(url.pathname);
      if (!["index.html", "editor.js", "account-directory.js", "editor.css", "boss-seasons.js", "union-raid.js", "user-validation.js",
        "raid-records.js", "raid-analysis.js"].includes(leaf)) return route.fulfill({ status: 404, body: "" });
      return route.fulfill({ body: fs.readFileSync(path.join(editor, leaf)), contentType: leaf.endsWith(".js") ? "text/javascript" : leaf.endsWith(".css") ? "text/css" : "text/html" });
    });
    await page.goto("http://127.0.0.1:18792/editor/");
    await page.evaluate(() => {
      document.getElementById("app-shell").inert = false;
      state.accountUid = "example-account";
      document.getElementById("top-account-name").textContent = "예시 계정";
    });
    await page.locator('[data-tab="union-raid"]').click();
    await page.waitForFunction(() => document.querySelectorAll("#union-season option").length === 45);
    assert.equal(await page.locator("#union-season option").first().getAttribute("value"), "45");
    assert.equal(await page.locator("#union-season").getAttribute("size"), "14");
    assert.equal(await page.locator("#union-status").isHidden(), true);
    await page.screenshot({ path: path.join(output, "union-seasons.png") });

    await page.locator("#union-season").selectOption("44");
    assert.equal(await page.locator("#union-confirm-title").innerText(), "시즌 44 보스를 불러오시겠습니까?");
    await page.screenshot({ path: path.join(output, "union-confirm.png") });
    await page.locator("#union-no").click(); assert.equal(posts, 0);

    // An assembled season opens its bosses and the shared record panel without asking.
    await page.locator("#union-season").selectOption("45");
    assert.equal(await page.locator("#union-confirm").evaluate(el => el.open), false);
    await page.waitForFunction(() => document.querySelectorAll("#raid-records-list li").length === 3);
    assert.equal(await page.locator("#union-boss-cards .union-boss-card").count(), 5);
    assert.equal(await page.locator("#union-records-host #raid-records").count(), 1);
    assert.equal(await page.locator(".raid-record-modes").isHidden(), true);
    assert.equal(await page.locator("#raid-records-elements").isHidden(), true);
    assert.equal(await page.locator("#raid-records-list-title").innerText(), "기록");
    assert.deepEqual(recordQueries.at(-1), { season: "45", kind: "union", step: "1", mode: "all", weakness: "all" });
    await page.waitForFunction(() => [...document.querySelectorAll(".union-boss-image")].every(img => img.complete));
    await page.screenshot({ path: path.join(output, "union-records.png"), fullPage: true });

    await page.locator('#union-boss-cards [data-order="2"]').click();
    await page.waitForFunction(() => document.getElementById("raid-records-empty-title").textContent === "아직 기록이 없습니다");
    assert.equal(recordQueries.at(-1).step, "2");
    assert.equal(await page.locator("#raid-records-empty-title").innerText(), "아직 기록이 없습니다");
    await page.locator('#union-boss-cards [data-order="3"]').click();
    await page.waitForFunction(() => document.querySelectorAll("#raid-records-list li").length === 3);
    await page.locator("#raid-records-list .raid-record-row").first().click();
    assert.equal(await page.locator("#raid-record-dialog").evaluate(el => el.open), true);
    await page.screenshot({ path: path.join(output, "union-record-detail.png") });
    await page.locator("#raid-record-dialog-close").click();

    // The solo tab takes the panel back with its own controls; returning restores the union scope.
    await page.locator('[data-tab="raid"]').click();
    assert.equal(await page.locator(".raid-boss-overview #raid-records").count(), 1);
    assert.equal(await page.locator(".raid-record-modes").evaluate(el => el.hidden), false);
    await page.locator('[data-tab="union-raid"]').click();
    assert.equal(await page.locator("#union-records-host #raid-records").count(), 1);
    await page.waitForFunction(() => document.querySelectorAll("#raid-records-list li").length === 3);
    assert.equal(recordQueries.at(-1).step, "3");

    await page.setViewportSize({ width: 700, height: 900 });
    await page.screenshot({ path: path.join(output, "union-narrow.png"), fullPage: true });
    await page.setViewportSize({ width: 1280, height: 900 });

    await page.locator("#union-season").selectOption("44"); await page.locator("#union-yes").click();
    await page.waitForFunction(() => !document.getElementById("union-confirm").open);
    assert.equal(posts, 1); assert.deepEqual(errors, []);
    console.log("Union UI: latest-first seasons, confirm only for new seasons, five boss cards, union-scoped shared records; no page errors.");
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
