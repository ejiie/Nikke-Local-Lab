"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const bosses = require("../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/boss-seasons.js");
class Node {
  constructor() { this.children = []; this.dataset = {}; this.listeners = {}; this.hidden = false; this.open = false; }
  append(...items) { this.children.push(...items); }
  replaceChildren(...items) { this.children = items; }
  setAttribute(key, value) { this[key] = value; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  showModal() { this.open = true; }
  close() { this.open = false; }
  click() { return this.listeners.click?.(); }
}
function fixture() {
  const nodes = new Map(), requests = [], selections = [], tasks = new Map();
  const byId = id => { if (!nodes.has(id)) nodes.set(id, new Node()); return nodes.get(id); };
  const catalog = { schemaVersion: 1, contractId: "nll/boss-season-catalog-view/v1", statusCode: "ready",
    catalogSha256: "a".repeat(64), maximumKnownSeason: 3, currentSeasonStatusCode: "unresolved",
    seasons: [ { seasonNumber: 1, displayName: "같은 보스", defaultWeaknessCode: "iron", processingStatusCode: "processed", imageUrl: null },
      { seasonNumber: 2, displayName: "같은 보스", defaultWeaknessCode: "fire", processingStatusCode: "unprocessed", imageUrl: null },
      { seasonNumber: 3, displayName: null, defaultWeaknessCode: null, processingStatusCode: "unresolved", imageUrl: null } ] };
  let jobs = [], post = async body => ({ ...job("queued"), ...body }), calls = 0;
  const job = status => ({ contractId: "nll/boss-onboarding-job/v1", jobUid: "synthetic-job", seasonNumber: 2,
    catalogSha256: catalog.catalogSha256, statusCode: status });
  const api = async (path, options) => {
    requests.push({ path, options });
    if (options?.method === "POST") return { payload: await post(options.body) };
    return { payload: path.endsWith("boss-seasons") ? structuredClone(catalog) : structuredClone(jobs) };
  };
  const controller = bosses.create({ document: { getElementById: byId, createElement: () => new Node() }, api,
    onSelected: row => selections.push(row), onUnavailable: () => {}, uid: () => `request-${++calls}`,
    schedule: fn => { tasks.set(calls, fn); return calls; }, cancel: id => tasks.delete(id) });
  return { byId, catalog, controller, requests, selections, job, tasks,
    setJobs: value => { jobs = value; }, setPost: fn => { post = fn; } };
}
test("default order is newest first and oldest remains selectable", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  assert.deepEqual(f.byId("boss-season-grid").children.map(row => row.dataset.season), ["3", "2", "1"]);
  f.byId("boss-season-order").value = "oldest";
  f.byId("boss-season-order").listeners.change();
  assert.deepEqual(f.byId("boss-season-grid").children.map(row => row.dataset.season), ["1", "2", "3"]);
});

test("sync adds a season while retaining filters and selected boss", async () => {
  const f = fixture(); await f.controller.refreshCatalog(); f.controller.selectSeason(1);
  f.byId("boss-season-weakness-filter").value = "fire";
  f.byId("boss-season-weakness-filter").listeners.change();
  f.setPost(async () => {
    f.catalog.maximumKnownSeason = 4;
    f.catalog.seasons.push({ seasonNumber: 4, displayName: "새 보스", defaultWeaknessCode: "water", processingStatusCode: "unprocessed", imageUrl: null });
    return { statusCode: "updated", addedSeasonCount: 1 };
  });
  await f.controller.syncCatalog();
  assert.equal(f.byId("boss-catalog-status").textContent, "시즌 1–4");
  assert.equal(f.byId("boss-season-grid").children.length, 1);
  assert.equal(f.byId("selected-boss-card").children[0].dataset.season, "1");
  assert.match(f.byId("boss-season-sync-status").textContent, /새 시즌 1개/);
  assert.equal(f.requests.filter(r => r.options?.method === "POST")[0].path, "/admin-api/v1/boss-seasons/sync");
});
test("sync coalesces clicks and preserves existing cards on failure", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  let complete; f.setPost(() => new Promise(resolve => { complete = resolve; }));
  const first = f.controller.syncCatalog();
  await f.controller.syncCatalog();
  assert.equal(f.byId("boss-season-sync").disabled, true);
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 1);
  complete({ statusCode: "failed", failureCode: "boss_catalog_sync_source_missing" }); await first;
  assert.equal(f.byId("boss-season-grid").children.length, 3);
  assert.equal(f.byId("boss-season-sync").disabled, false);
  assert.match(f.byId("boss-season-sync-status").textContent, /기존 목록은 유지/);
});
test("processed selection displays one card and retains the season's default weakness", async () => {
  const f = fixture(); await f.controller.refreshCatalog(); f.controller.selectSeason(1);
  assert.equal(f.byId("boss-season-grid").children.length, 3);
  assert.equal(f.byId("boss-season-picker").hidden, true);
  assert.equal(f.byId("boss-detail").hidden, false);
  assert.equal(f.byId("selected-boss-card").children.length, 1);
  assert.equal(f.byId("selected-boss-card").children[0].dataset.defaultWeaknessCode, "iron");
  assert.equal(f.selections[0].seasonNumber, 1);
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 0);
});
test("No and Escape close the confirmation without creating any job", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  f.controller.selectSeason(2);
  assert.match(f.byId("boss-import-question").textContent, /Season 2 보스\n같은 보스/);
  f.byId("boss-import-no").click();
  assert.equal(f.byId("boss-import-dialog").open, false);
  await f.controller.confirmImport();
  f.controller.selectSeason(2); f.byId("boss-import-dialog").listeners.cancel();
  await f.controller.confirmImport();
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 0);
});
test("verified game-validation handoff selects one card without importing or declaring acceptance", async () => {
  const f = fixture(); f.catalog.seasons[1].processingStatusCode = "awaiting_game_validation";
  await f.controller.refreshCatalog(); f.controller.selectSeason(2);
  assert.equal(f.byId("boss-import-dialog").open, false);
  assert.equal(f.byId("selected-boss-card").children.length, 1);
  assert.equal(f.selections[0].processingStatusCode, "awaiting_game_validation");
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 0);
  f.controller.selectSeason(1);
  assert.equal(f.selections[1].processingStatusCode, "processed");
});
test("Yes closes before network, duplicate clicks coalesce and unknown result reuses operation UID", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  let reject;
  f.setPost(() => new Promise((_, failure) => { reject = failure; }));
  f.controller.selectSeason(2); const pending = f.controller.confirmImport();
  assert.equal(f.byId("boss-import-dialog").open, false);
  f.controller.selectSeason(2); await f.controller.confirmImport();
  reject(new Error("uncertain response")); await pending;
  f.setPost(async body => ({ ...f.job("queued"), ...body }));
  f.controller.selectSeason(2); await f.controller.confirmImport();
  const posts = f.requests.filter(r => r.options?.method === "POST");
  assert.equal(posts.length, 2); assert.equal(posts[0].options.body.operationUid, posts[1].options.body.operationUid);
});
test("runtime-delivery wait never announces completion or changes a different selected season", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  f.setJobs([f.job("running")]); await f.controller.refreshJobs();
  f.controller.selectSeason(1);
  f.setJobs([f.job("awaiting_runtime_delivery")]); await f.controller.refreshJobs();
  assert.notEqual(f.byId("boss-message-title").textContent, "보스 불러오기 완료");
  assert.equal(f.selections.length, 1); assert.equal(f.selections[0].seasonNumber, 1);
});
test("only terminal completed announces completion, once, after progress observed", async () => {
  const f = fixture(); await f.controller.refreshCatalog();
  f.setJobs([f.job("running")]); await f.controller.refreshJobs();
  f.setJobs([f.job("completed")]); await f.controller.refreshJobs();
  assert.equal(f.byId("boss-message-title").textContent, "보스 불러오기 완료");
  f.byId("boss-message-close").click(); await f.controller.refreshJobs();
  assert.equal(f.byId("boss-message-dialog").open, false);
});
test("unresolved seasons do not create confirmations and labels are written as text", async () => {
  const f = fixture(); f.catalog.seasons[0].displayName = "<img src=x onerror=alert(1)>";
  f.catalog.seasons[0].imageUrl = "https://untrusted.invalid/image.png";
  await f.controller.refreshCatalog(); f.controller.selectSeason(3);
  assert.equal(f.byId("boss-import-dialog").open, false);
  const card = f.byId("boss-season-grid").children.find(row => row.dataset.season === "1");
  assert.equal(card.children[2].children[1].textContent, "<img src=x onerror=alert(1)>");
  assert.equal(card.children[1].children.length, 1);
});
