"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const union = require("../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/union-raid.js");
class Node {
  constructor() { this.listeners = {}; this.children = []; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  replaceChildren(...items) { this.children = items; }
  showModal() { this.open = true; }
  close() { this.open = false; }
}
function fixture() {
  const nodes = new Map(), requests = [];
  const byId = id => { if (!nodes.has(id)) nodes.set(id, new Node()); return nodes.get(id); };
  const catalog = { statusCode: "ready", catalogSha256: "a".repeat(64), seasons: [1, 3, 2].map(seasonNumber => ({
    seasonNumber, statusCode: seasonNumber === 1 ? "unresolved" : "available",
    bosses: [1, 2, 3, 4, 5].map(order => ({ order, displayName: `합성 ${order}` })) })) };
  let fail = false;
  const api = async (path, options) => {
    requests.push({ path, options });
    if (options?.method === "POST") {
      if (fail) throw new Error("response_lost");
      return { payload: { ...options.body, statusCode: "queued" } };
    }
    return { payload: path.endsWith("seasons") ? structuredClone(catalog) : [] };
  };
  const controller = union.create({ document: { getElementById: byId, createElement: () => new Node() }, api,
    uid: () => "same-operation", schedule: () => 1, cancel: () => {} });
  return { byId, requests, controller, fail: () => { fail = true; } };
}
const flush = () => new Promise(resolve => setImmediate(resolve));
test("latest-first scrolling selection requires confirmation; cancel never imports", async () => {
  const f = fixture(); await f.controller.refresh();
  assert.deepEqual(f.byId("union-season").children.map(n => n.value), ["3", "2", "1"]);
  f.byId("union-season").value = "3"; f.byId("union-season").listeners.change();
  assert.equal(f.byId("union-confirm-title").textContent, "시즌 3 보스를 불러오시겠습니까?");
  assert.equal(f.byId("union-bosses").children.length, 5);
  f.byId("union-no").listeners.click();
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 0);
});
test("Yes submits a pinned season once; retry after response loss keeps operation identity", async () => {
  const f = fixture(); await f.controller.refresh(); f.fail();
  f.byId("union-season").value = "2"; f.byId("union-season").listeners.change();
  f.byId("union-yes").listeners.click(); f.byId("union-yes").listeners.click(); await flush();
  assert.equal(f.requests.filter(r => r.options?.method === "POST").length, 1);
  f.byId("union-yes").listeners.click(); await flush();
  const posts = f.requests.filter(r => r.options?.method === "POST");
  assert.deepEqual(posts[0].options.body, posts[1].options.body);
  assert.equal(posts[0].options.body.seasonNumber, 2);
});
