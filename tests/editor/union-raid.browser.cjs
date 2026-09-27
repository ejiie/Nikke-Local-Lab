"use strict";
// Real editor + synthetic local HTTP. No account writes or game launch.
const fs = require("node:fs"), path = require("node:path"), assert = require("node:assert/strict");
const { chromium } = require("playwright");
const editor = path.resolve(__dirname, "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
(async () => {
  const output = path.resolve(process.argv[2]); fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ channel: "msedge", headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    let posts = 0;
    const catalog = { statusCode: "ready", catalogSha256: "a".repeat(64), seasons: Array.from({ length: 45 }, (_, n) => ({
      seasonNumber: n + 1, statusCode: n < 23 ? "unresolved" : "available", failureCode: n < 23 ? "boss_union_hard_not_available" : null,
      bosses: n < 23 ? [] : Array.from({ length: 5 }, (_, order) => ({ order: order + 1, displayName: `합성 보스 ${order + 1}` })) })) };
    await page.route("**/*", async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.pathname === "/admin-api/v1/union-raid/seasons") return route.fulfill({ json: catalog });
      if (url.pathname === "/admin-api/v1/union-raid/jobs") {
        if (request.method() === "POST") { posts++; return route.fulfill({ status: 202, json: { ...request.postDataJSON(), statusCode: "queued" } }); }
        return route.fulfill({ json: [] });
      }
      if (url.pathname.startsWith("/admin-api/")) return route.fulfill({ status: 503, json: { code: "synthetic_not_configured" } });
      const leaf = url.pathname.endsWith("/") ? "index.html" : path.basename(url.pathname);
      if (!["index.html", "editor.js","account-directory.js", "editor.css", "boss-seasons.js", "union-raid.js", "user-validation.js"].includes(leaf)) return route.fulfill({ status: 404, body: "" });
      return route.fulfill({ body: fs.readFileSync(path.join(editor, leaf)), contentType: leaf.endsWith(".js") ? "text/javascript" : leaf.endsWith(".css") ? "text/css" : "text/html" });
    });
    await page.goto("http://127.0.0.1:18792/editor/");
    await page.evaluate(() => { document.getElementById("app-shell").inert = false; });
    await page.locator('[data-tab="union-raid"]').click();
    await page.waitForFunction(() => document.querySelectorAll("#union-season option").length === 45);
    assert.equal(await page.locator("#union-season option").first().getAttribute("value"), "45");
    assert.equal(await page.locator("#union-season").getAttribute("size"), "8");
    await page.screenshot({ path: path.join(output, "union-seasons.png") });
    await page.locator("#union-season").selectOption("45");
    assert.equal(await page.locator("#union-confirm-title").innerText(), "시즌 45 보스를 불러오시겠습니까?");
    await page.screenshot({ path: path.join(output, "union-confirm.png") });
    await page.locator("#union-no").click(); assert.equal(posts, 0);
    await page.locator("#union-season").selectOption("45"); await page.locator("#union-yes").click();
    await page.waitForFunction(() => !document.getElementById("union-confirm").open);
    assert.equal(posts, 1); assert.deepEqual(errors, []);
    console.log("Union UI: 45 latest-first seasons, scroll selector, cancel, confirmed import; no page errors.");
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
