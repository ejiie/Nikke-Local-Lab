"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const union = require("../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/union-raid.js");
class Node {
  constructor(tag) {
    this.tag = tag; this.listeners = {}; this.children = []; this.dataset = {}; this.attributes = {};
    this.classList = { add: name => { this.className = `${this.className || ""} ${name}`.trim(); } };
  }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  replaceChildren(...items) { this.children = items; }
  append(...items) { this.children.push(...items); }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name]; }
  showModal() { this.open = true; }
  close() { this.open = false; }
}
const hash = "a".repeat(64);
function fixture({ jobs = [] } = {}) {
  const nodes = new Map(), requests = [], selections = [];
  const byId = id => { if (!nodes.has(id)) nodes.set(id, new Node("div")); return nodes.get(id); };
  const boss = (season, order) => ({ order, displayName: `합성 ${order} [C.${order}]`, weaknessCode: order === 2 ? "water" : null,
    imageUrl: order === 1 ? `/admin-api/v1/union-raid/seasons/${season}/bosses/1/image?catalog=${hash}` : order === 3 ? "/elsewhere.png" : null });
  const catalog = { statusCode: "ready", catalogSha256: hash, seasons: [1, 3, 2, 4].map(seasonNumber => ({
    seasonNumber, statusCode: seasonNumber === 1 ? "unresolved" : seasonNumber === 4 ? "assembled" : "available",
    bosses: [1, 2, 3, 4, 5].map(order => boss(seasonNumber, order)) })) };
  let fail = false;
  const api = async (path, options) => {
    requests.push({ path, options });
    if (options?.method === "POST") {
      if (fail) throw new Error("response_lost");
      return { payload: { ...options.body, statusCode: "queued" } };
    }
    return { payload: path.endsWith("seasons") ? structuredClone(catalog) : structuredClone(jobs) };
  };
  const controller = union.create({ document: { getElementById: byId, createElement: tag => new Node(tag) }, api,
    uid: () => "same-operation", schedule: () => 1, cancel: () => {}, onBossSelected: value => selections.push(value) });
  const choose = season => { byId("union-season").value = String(season); byId("union-season").listeners.change(); };
  return { byId, requests, selections, controller, choose, fail: () => { fail = true; } };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
const posts = f => f.requests.filter(r => r.options?.method === "POST");
test("latest-first selection asks before importing; cancel never imports", async () => {
  const f = fixture(); await f.controller.refresh();
  assert.deepEqual(f.byId("union-season").children.map(n => n.value), ["4", "3", "2", "1"]);
  assert.equal(f.byId("union-season").children[0].textContent, "시즌 4 · 불러오기 완료");
  assert.equal(f.byId("union-status").hidden, true);
  f.choose(3);
  assert.equal(f.byId("union-confirm").open, true);
  assert.equal(f.byId("union-confirm-title").textContent, "시즌 3 보스를 불러오시겠습니까?");
  f.byId("union-no").listeners.click();
  assert.equal(posts(f).length, 0);
  assert.equal(f.byId("union-season").selectedIndex, -1);
});
test("Yes submits a pinned season once; retry after response loss keeps operation identity", async () => {
  const f = fixture(); await f.controller.refresh(); f.fail();
  f.choose(2);
  f.byId("union-yes").listeners.click(); f.byId("union-yes").listeners.click(); await flush();
  assert.equal(posts(f).length, 1);
  assert.equal(f.byId("union-status").hidden, false);
  f.byId("union-yes").listeners.click(); await flush();
  assert.deepEqual(posts(f)[0].options.body, posts(f)[1].options.body);
  assert.equal(posts(f)[0].options.body.seasonNumber, 2);
});
test("an assembled season opens its five bosses without asking", async () => {
  const f = fixture(); await f.controller.refresh();
  f.choose(4);
  assert.notEqual(f.byId("union-confirm").open, true);
  assert.equal(f.byId("union-detail-empty").hidden, true);
  const cards = f.byId("union-boss-cards").children;
  assert.equal(cards.length, 5);
  assert.deepEqual(f.selections.at(-1), { seasonNumber: 4, order: 1, bossName: "합성 1 [C.1]" });
  assert.deepEqual(cards.map(card => card.getAttribute("aria-pressed")), ["true", "false", "false", "false", "false"]);
  cards[2].listeners.click();
  assert.equal(f.selections.at(-1).order, 3);
  assert.equal(cards[2].getAttribute("aria-pressed"), "true");
  // Re-selecting the season on screen keeps the chosen boss.
  const count = f.selections.length;
  f.choose(4);
  assert.equal(f.selections.length, count);
  assert.equal(f.byId("union-season").value, "4");
});
test("cards show name, code, pinned image and weakness only from valid data", async () => {
  const f = fixture(); await f.controller.refresh(); f.choose(4);
  const [first, second, third] = f.byId("union-boss-cards").children;
  const art = card => card.children[0];
  assert.equal(first.children[1].textContent, "합성 1");
  assert.equal(first.children[2].textContent, "C.1");
  assert.ok(art(first).children.some(n => n.className === "union-boss-image" && n.src.endsWith(`catalog=${hash}`)));
  assert.ok(!art(third).children.some(n => n.className === "union-boss-image"));
  assert.equal(art(third).children[0].textContent, "이미지 없음");
  const badge = art(second).children.find(n => n.className === "union-boss-weakness");
  assert.equal(badge.children[0].src, "/editor/assets/ui/code-water.png");
  assert.ok(!art(first).children.some(n => n.className === "union-boss-weakness"));
  badge.children[0].listeners.error();
  assert.deepEqual(badge.children, ["수냉"]);
});
test("running and failed imports are shown in the season list", async () => {
  const f = fixture({ jobs: [{ seasonNumber: 3, statusCode: "running" }, { seasonNumber: 2, statusCode: "failed", failureCode: "boss_union_x" },
    { seasonNumber: 3, statusCode: "failed" }] });
  await f.controller.refresh();
  const label = season => f.byId("union-season").children.find(n => n.value === String(season));
  assert.equal(label(3).textContent, "시즌 3 · 불러오는 중");
  assert.equal(label(2).textContent, "시즌 2 · 불러오기 실패");
  assert.equal(label(2).title, "boss_union_x");
  f.choose(3);
  assert.notEqual(f.byId("union-confirm").open, true);
});
test("boss labels split a bracketed code name", () => {
  assert.deepEqual(union.bossLabel({ order: 1, displayName: "크리스탈 체임버 [P.S.I.D.]" }), { name: "크리스탈 체임버", code: "P.S.I.D." });
  assert.deepEqual(union.bossLabel({ order: 2, displayName: "두리안" }), { name: "두리안", code: "" });
  assert.deepEqual(union.bossLabel({ order: 5, displayName: null }), { name: "보스 5", code: "" });
});
