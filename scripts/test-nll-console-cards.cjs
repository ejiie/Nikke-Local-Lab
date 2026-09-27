"use strict";

// Offline UI regression with synthetic UUIDs/levels. All requests are fulfilled
// in-process; this never connects to the Admin API, database or game runtime.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium } = require("playwright");

const options = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, i, args) => {
  if (i % 2 === 0) pairs.push([arg.replace(/^--/, ""), args[i + 1]]);
  return pairs;
}, []));
const root = path.resolve(options["repository-root"] || path.join(__dirname, ".."));
const editor = path.resolve(options["editor-root"] || path.join(root, "src/NikkeLocalLab.Admin.Api/wwwroot/editor"));
const assets = path.resolve(options["asset-root"] || path.join(root, "artifacts/phase-d/presentation-assets/consoles"));
const output = path.resolve(options["output-root"] || path.join(root, "artifacts/phase-d/console-card-qa"));
const definitions = [
  ["common", "공용 콘솔"], ["attacker", "화력형 콘솔"],
  ["defender", "방어형 콘솔"], ["supporter", "지원형 콘솔"],
  ["elysion", "엘리시온 콘솔"], ["missilis", "미실리스 콘솔"],
  ["tetra", "테트라 콘솔"], ["pilgrim", "필그림 콘솔"], ["abnormal", "어브노멀 콘솔"]
];
const catalog = definitions.map(([coordinateCode, displayName], index) => ({
  definitionUid: `11111111-1111-4111-8111-${String(index + 1).padStart(12, "0")}`,
  coordinateCode, displayName
}));
const values = catalog.flatMap((item, index) => [
  { fieldCode: "console_level", subjectUid: item.definitionUid, integerValue: index === 1 ? 300 : 520 },
  { fieldCode: "console_experience", subjectUid: item.definitionUid, integerValue: index * 10 }
]);
values.push({ fieldCode: "synchro_level", subjectUid: null, integerValue: 773 });
const routes = new Map([
  ["/editor/", [path.join(editor, "index.html"), "text/html; charset=utf-8"]],
  ["/editor/editor.js", [path.join(editor, "editor.js"), "text/javascript; charset=utf-8"]],
  ["/editor/editor.css", [path.join(editor, "editor.css"), "text/css; charset=utf-8"]],
  ...definitions.map(([code]) => [`/editor/assets/consoles/${code}.webp`, [path.join(assets, `${code}.webp`), "image/webp"]])
]);

async function main() {
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ headless: true });
  const errors = [], unexpectedRequests = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1478, height: 1050 }, deviceScaleFactor: 1 });
    await page.route("**/*", async route => {
      const url = new URL(route.request().url());
      if (url.host !== "127.0.0.1:18788" || url.pathname.startsWith("/admin-api/")) unexpectedRequests.push(url.pathname);
      const member = routes.get(url.pathname);
      if (member && fs.existsSync(member[0])) await route.fulfill({ path: member[0], contentType: member[1] });
      else await route.fulfill({ status: 404, body: "" });
    });
    page.on("pageerror", error => errors.push(error.message));
    await page.goto("http://127.0.0.1:18788/editor/");
    await page.evaluate(({ catalog, values }) => {
      byId("app-shell").inert = false;
      state.currentProfile = { values: [...values].reverse() };
      state.presentationByConsole = new Map([...catalog].reverse().map(item => [item.definitionUid, item]));
      renderGeneralEditor(); setPage("account");
    }, { catalog, values });
    const cards = page.locator(".console-card");
    assert.equal(await cards.count(), 9);
    assert.equal(await page.locator('[data-console-group="common-class"] .console-card').count(), 4);
    assert.equal(await page.locator('[data-console-group="manufacturer"] .console-card').count(), 5);
    assert.deepEqual(await cards.locator(".console-name").allTextContents(), definitions.map(([, name]) => name));
    assert.equal(await page.evaluate("state.editOperations.length"), 0);
    await page.locator(".console-panel").scrollIntoViewIfNeeded();
    await page.waitForFunction(() => {
      const images = [...document.querySelectorAll(".console-card img")];
      return images.length === 9 && images.every(image => image.complete && image.naturalWidth > 0);
    });
    assert.equal(await cards.nth(0).getAttribute("aria-pressed"), "true");
    await cards.nth(1).click();
    assert.equal(await page.locator("#general-console-level").inputValue(), "300");
    assert.equal(await page.locator("#general-console-experience").inputValue(), "10");
    assert.equal(await page.evaluate("state.editOperations.length"), 0);
    await page.locator("#general-console-level").fill("777");
    await page.locator("#general-console-experience").fill("123");
    await cards.nth(4).click(); // Blur queues the previous console's edit.
    assert.equal(await cards.nth(1).locator(".console-level").textContent(), "Lv. 777");
    const edits = await page.evaluate("state.editOperations");
    assert.equal(edits.length, 2);
    assert.ok(edits.every(edit => edit.subjectUid === catalog[1].definitionUid));
    assert.deepEqual(Object.fromEntries(edits.map(edit => [edit.fieldCode, edit.integerValue])), {
      console_level: 777, console_experience: 123
    });
    await page.locator("#general-console").selectOption(catalog[1].definitionUid);
    assert.equal(await cards.nth(1).getAttribute("aria-pressed"), "true");
    assert.equal(await page.locator("#general-console-level").inputValue(), "777");
    assert.equal(await page.locator("#general-console-experience").inputValue(), "123");
    await page.evaluate("renderGeneralEditor()");
    assert.equal(await page.locator("#general-console").inputValue(), catalog[1].definitionUid);
    // Native buttons retain keyboard selection, with no implicit save request.
    await cards.nth(2).focus(); await page.keyboard.press("Enter");
    assert.equal(await cards.nth(2).getAttribute("aria-pressed"), "true");
    await page.keyboard.press("Tab"); await page.keyboard.press("Space");
    assert.equal(await cards.nth(3).getAttribute("aria-pressed"), "true");
    assert.equal(await page.evaluate("state.editOperations.length"), 2);
    await cards.nth(1).click();
    // Component previews omit unrelated sticky app chrome that would otherwise
    // cover a tall element screenshot. Interaction tests above use the real UI.
    const componentStyle = ".sidebar, .account-save-bar, footer { opacity: 0 !important; pointer-events: none !important; }";
    await page.locator(".console-panel").screenshot({ path: path.join(output, "console-cards-desktop.png"), style: componentStyle });
    for (const width of [1024, 600, 390]) {
      await page.setViewportSize({ width, height: 1000 });
      await page.locator(".console-panel").scrollIntoViewIfNeeded();
      assert.ok(await page.locator(".console-panel").evaluate(element => element.scrollWidth <= element.clientWidth));
      const groups = page.locator(".console-group");
      const first = await groups.nth(0).boundingBox(), second = await groups.nth(1).boundingBox();
      assert.ok(first.y + first.height <= second.y);
      assert.ok((await cards.nth(4).boundingBox()).y > (await cards.nth(3).boundingBox()).y);
    }
    await page.locator(".console-panel").screenshot({ path: path.join(output, "console-cards-mobile.png"), style: componentStyle });
    await page.locator(".console-card img").first().dispatchEvent("error");
    assert.equal(await cards.nth(0).locator(".presentation-image-fallback").textContent(), "이미지 없음");
    await cards.nth(0).click();
    assert.equal(await page.locator("#general-console-level").inputValue(), "520");
    await page.evaluate(uid => { state.presentationByConsole.delete(uid); renderGeneralEditor(); }, catalog[8].definitionUid);
    assert.equal(await page.locator('[data-console-group="unresolved"] .console-card').count(), 1);
    assert.equal(await page.locator('[data-console-group="manufacturer"] .console-card').count(), 4);
    await page.evaluate("state.currentProfile = null; state.editOperations = []; renderGeneralEditor()");
    assert.equal(await cards.count(), 0);
    assert.equal(await page.locator(".console-panel .console-empty").textContent(), "계정을 선택하면 콘솔이 표시됩니다.");
    assert.ok(await page.locator("#general-console-level").isDisabled());
    assert.ok(await page.locator("#general-console-experience").isDisabled());
    assert.deepEqual(errors, []); assert.deepEqual(unexpectedRequests, []);
    console.log(JSON.stringify({ status: "passed", consoleCount: 9, tiers: [4, 5], viewports: [1478, 1024, 600, 390], backendRequests: 0 }));
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
