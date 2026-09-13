// Optional local browser gate: real checked-in UI + synthetic HTTP only.
// Usage: NODE_PATH=<bundled packages> node tests/editor/boss-seasons.browser.cjs <new-output-dir>
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const { chromium } = require("playwright");
const editorRoot = path.resolve(__dirname, "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor");
async function main() {
  const output = path.resolve(process.argv[2] || "");
  assert.ok(process.argv[2] && !fs.existsSync(output), "new browser output required");
  fs.mkdirSync(output, { recursive: true });
  const catalog = { schemaVersion: 1, contractId: "nll/boss-season-catalog-view/v1", statusCode: "ready",
    catalogSha256: "a".repeat(64), maximumKnownSeason: 40, currentSeasonStatusCode: "unresolved",
    seasons: Array.from({ length: 40 }, (_, index) => ({ seasonNumber: index + 1, displayName: `합성 보스 ${index + 1}`,
      defaultWeaknessCode: ["fire", "water", "wind", "electric", "iron"][index % 5], imageUrl: null,
      processingStatusCode: index === 25 ? "processed" : "unprocessed", failureCode: null })) };
  const imagePayloads = new Map();
  if (process.argv[3]) {
    const local = path.resolve(process.argv[3]), bytes = fs.readFileSync(local);
    const pin = crypto.createHash("sha256").update(bytes).digest("hex");
    assert.equal(pin, process.argv[4], "explicit local catalog pin required");
    const snapshot = JSON.parse(bytes);
    assert.equal(snapshot.contractId, "nll/boss-season-catalog/v1");
    assert.equal(snapshot.maximumKnownSeason, 40);
    catalog.catalogSha256 = pin;
    catalog.seasons = snapshot.seasons.map(row => {
      const imageUrl = row.imageStatusCode === "resolved" ? `/admin-api/v1/boss-seasons/${row.seasonNumber}/image?catalog=${pin}` : null;
      if (imageUrl) {
        assert.match(row.imageSha256, /^[a-f0-9]{64}$/);
        const payload = fs.readFileSync(path.join(path.dirname(local), "images", row.imageSha256 + ".png"));
        assert.equal(crypto.createHash("sha256").update(payload).digest("hex"), row.imageSha256);
        imagePayloads.set(imageUrl, payload);
      }
      // Job and preparation HTTP remain synthetic: this only inspects the local
      // presentation snapshot and never asserts that another boss is admitted.
      return { ...row, imageUrl, processingStatusCode: row.discoveryStatusCode !== "resolved" ? "unresolved" :
        row.seasonNumber === 26 ? "processed" : "unprocessed" };
    });
  }
  let jobs = [], posts = 0;
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (!url.pathname.startsWith("/editor/")) { response.writeHead(404); response.end(); return; }
    const name = decodeURIComponent(url.pathname.slice("/editor/".length)) || "index.html";
    const file = path.resolve(editorRoot, name);
    if (!file.startsWith(editorRoot + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      response.writeHead(404); response.end(); return;
    }
    response.writeHead(200, { "Content-Type": file.endsWith(".js") ? "text/javascript" : file.endsWith(".css") ? "text/css" :
      file.endsWith(".png") ? "image/png" : "text/html", "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'" });
    fs.createReadStream(file).pipe(response);
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let browser;
  try {
    browser = await chromium.launch({ channel: "msedge", headless: true });
    const page = await browser.newPage({ viewport: { width: 1385, height: 900 } });
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    await page.route("**/admin-api/**", async route => {
      const request = route.request(), url = new URL(request.url());
      const payload = imagePayloads.get(url.pathname + url.search);
      if (payload) { await route.fulfill({ status: 200, body: payload, contentType: "image/png" }); return; }
      let body;
      if (url.pathname.endsWith("boss-seasons")) body = catalog;
      else if (url.pathname.endsWith("boss-onboarding-jobs")) {
        if (request.method() === "POST") {
          posts++;
          jobs = [{ schemaVersion: 1, contractId: "nll/boss-onboarding-job/v1", jobUid: "synthetic-job", ...request.postDataJSON(), statusCode: "running" }];
          body = jobs[0];
        } else body = jobs;
      } else if (url.pathname.endsWith("execution-preparation")) body = { schemaVersion: 1, contractId: "nll/phase-d-preparation/v1",
        ...request.postDataJSON(), statusCode: "ready", bindingSha256: "b".repeat(64), failureCode: null, clientBuildCode: "build_151.8.5" };
      else { await route.fulfill({ status: 404, json: { code: "synthetic_not_found" } }); return; }
      await route.fulfill({ status: 200, json: body });
    });
    await page.goto(`http://127.0.0.1:${server.address().port}/editor/index.html`);
    await page.evaluate(() => { document.getElementById("login-screen").hidden = true; document.getElementById("app-shell").hidden = false; setPage("raid"); });
    await page.locator("#select-boss-season").click();
    await page.waitForFunction(() => document.querySelectorAll(".boss-season-option").length === 40);
    if (imagePayloads.size) {
      await page.locator(".boss-season-option .boss-catalog-image").evaluateAll(images => images.forEach(image => { image.loading = "eager"; }));
      await page.waitForFunction(count => [...document.querySelectorAll(".boss-season-option .boss-catalog-image")].filter(image => image.complete && image.naturalWidth > 0).length === count, imagePayloads.size);
    }
    await page.screenshot({ path: path.join(output, "season-picker.png"), fullPage: false });
    await page.locator('.boss-season-option[data-season="26"]').click();
    assert.equal(await page.locator(".raid-boss-option:visible").count(), 1);
    assert.equal(await page.locator(".boss-season-option:visible").count(), 0);
    const before = await page.locator("#selected-boss-card [data-boss-weakness-label]").textContent();
    assert.equal(await page.locator('.weakness-option[aria-checked="true"]').count(), 1);
    await page.locator('[data-weakness-code="iron"]').click();
    assert.equal(await page.locator('.weakness-option[aria-checked="true"]').count(), 1);
    assert.equal(await page.locator('.weakness-option[aria-checked="true"]').getAttribute("data-weakness-code"), "iron");
    assert.equal(await page.locator('.weakness-option img:visible').count(), 0, "missing synthetic icons must not render broken images");
    assert.equal(await page.locator('#selected-weakness-icon:visible').count(), 0);
    assert.equal(await page.locator("#selected-boss-card [data-boss-weakness-label]").textContent(), before);
    await page.screenshot({ path: path.join(output, "selected-boss.png"), fullPage: false });
    await page.locator("#select-boss-season").click();
    await page.locator('.boss-season-option[data-season="29"]').click();
    await page.screenshot({ path: path.join(output, "import-confirmation.png"), fullPage: false });
    await page.locator("#boss-import-no").click(); assert.equal(posts, 0);
    await page.locator('.boss-season-option[data-season="29"]').click();
    await page.locator("#boss-import-yes").click();
    await page.waitForFunction(() => document.getElementById("boss-job-status").textContent.includes("처리 중"));
    assert.equal(await page.locator("#boss-import-dialog").isVisible(), false); assert.equal(posts, 1);
    jobs[0].statusCode = "awaiting_runtime_delivery";
    await page.locator("#boss-jobs-refresh").click();
    await page.locator("#boss-message-dialog").waitFor({ state: "visible" });
    assert.notEqual(await page.locator("#boss-message-title").textContent(), "보스 불러오기 완료");
    assert.deepEqual(errors, []);
    await page.setViewportSize({ width: 430, height: 880 });
    await page.screenshot({ path: path.join(output, "mobile-dialog.png"), fullPage: false });
    console.log(JSON.stringify({ status: "passed", syntheticHttpOnly: true, nativeClientExecuted: false,
      seasonCards: 40, selectedVisibleCards: 1, noButtonJobs: 0, yesButtonJobs: posts, pageErrors: errors.length,
      presentationSource: process.argv[3] ? "pinned_local_snapshot" : "synthetic", decodedSeasonImages: imagePayloads.size }));
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
