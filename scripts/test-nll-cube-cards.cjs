"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");
const root = path.resolve(__dirname, "..");
const editor = path.join(root, "src/NikkeLocalLab.Admin.Api/wwwroot/editor");
const prepared = path.join(root, "artifacts/phase-d/cube-presentation");
const output = path.join(root, "artifacts/phase-d/cube-card-qa");
const source = JSON.parse(fs.readFileSync(path.join(prepared, "presentation.json"), "utf8"));
const sourceCubes = source.supportDefinitions.filter(item => item.kindCode === "cube");
const cubeImages = new Map();
const cubes = sourceCubes.map((cube, index) => {
  const uid = `22222222-2222-4222-8222-${String(index + 1).padStart(12, "0")}`;
  const imagePath = `/editor/assets/cubes/${uid}.webp`;
  cubeImages.set(imagePath, path.join(prepared, "assets/cubes", `${cube.definitionUid}.webp`));
  return { ...cube, definitionUid: uid, imagePath };
});
async function main() {
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const errors = [], unexpectedRequests = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1478, height: 1050 } });
    page.on("pageerror", error => errors.push(error.message));
    await page.route("**/*", async route => {
      const url = new URL(route.request().url());
      if (url.host !== "127.0.0.1:18788" || url.pathname.startsWith("/admin-api")) unexpectedRequests.push(url.pathname);
      const file = cubeImages.get(url.pathname) || ({
        "/editor/": path.join(editor, "index.html"),
        "/editor/editor.js": path.join(editor, "editor.js"),
        "/editor/editor.css": path.join(editor, "editor.css")
      })[url.pathname];
      if (file && fs.existsSync(file)) await route.fulfill({ path: file });
      else await route.fulfill({ status: 404, body: "" });
    });
    await page.goto("http://127.0.0.1:18788/editor/");
    await page.evaluate(cubes => {
      byId("app-shell").inert = false;
      state.currentProfile = { values: [
        { fieldCode: "synchro_level", integerValue: 773 },
        { fieldCode: "account_cube_level", subjectUid: cubes[0].definitionUid, integerValue: 3 }
      ] };
      state.presentation.supportDefinitions = cubes;
      renderGeneralEditor(); setPage("account");
    }, cubes);
    const cards = page.locator(".cube-card");
    assert.equal(await cards.count(), 17);
    assert.equal(await page.evaluate("state.editOperations.length"), 0);
    assert.ok(await page.locator("#account-cube-editor").isHidden());
    await page.waitForFunction(() => [...document.querySelectorAll(".cube-image")].every(image => image.complete && image.naturalWidth > 0));
    const uid = cubes[0].definitionUid;
    const first = page.locator(`[data-cube-uid="${uid}"]`);
    await first.click();
    assert.equal(await page.locator("#account-cube-level").inputValue(), "3");
    assert.equal(await page.locator("#account-cube-level option").count(), 15);
    await page.locator("#account-cube-level").selectOption("1");
    assert.equal(await first.locator(".cube-level").textContent(), "Lv. 1");
    assert.equal(await first.locator(".cube-effect").textContent(), cubes[0].levels[0].primaryEffect);
    const edits = await page.evaluate("state.editOperations");
    assert.equal(edits.length, 1);
    assert.equal(edits[0].fieldCode, "account_cube_level");
    assert.equal(edits[0].subjectUid, uid);
    await cards.nth(2).focus(); await page.keyboard.press("Enter");
    assert.equal(await cards.nth(2).getAttribute("aria-pressed"), "true");
    await page.locator("#account-cube-level").selectOption("15");
    await page.evaluate("queueCubeInventory()");
    assert.equal(await page.evaluate("state.editOperations.length"), 17);
    await page.evaluate("renderGeneralEditor()");
    assert.equal(await first.locator(".cube-level").textContent(), "Lv. 1");
    const style = ".sidebar,.account-save-bar,footer { opacity:0!important;pointer-events:none!important; }";
    await page.locator(".cube-panel").screenshot({ path: path.join(output, "cube-cards-desktop.png"), style });
    for (const width of [1024, 600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.waitForTimeout(60);
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
      for (const card of await cards.all()) {
        const box = await card.boundingBox();
        assert.ok(box.width > 100 && box.x >= 0 && box.x + box.width <= width + 1);
      }
    }
    await page.locator(".cube-panel").screenshot({ path: path.join(output, "cube-cards-mobile.png"), style });
    await first.locator("img").dispatchEvent("error");
    assert.equal(await first.locator(".presentation-image-fallback").textContent(), "이미지 없음");
    await page.evaluate(() => { state.currentProfile = null; state.editOperations = []; renderGeneralEditor(); });
    assert.equal(await cards.count(), 0);
    assert.ok(await page.locator("#account-cube-editor").isHidden());
    assert.deepEqual(errors, []); assert.deepEqual(unexpectedRequests, []);
    console.log(JSON.stringify({ status: "passed", cubes: 17, levels: 15, viewports: [1478,1024,600,390], backendRequests: 0 }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
