"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { create } = require("../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/user-validation.js");
function fixture() {
  const nodes = new Map(), calls = [], tasks = new Map(); let next = 0, failPost = false;
  const selection = { seasonNumber: 29, weaknessCode: "water", validationOnly: true };
  const delivery = { schemaVersion: 1, contractId: "nll/user-validation-delivery-view/v1", seasonNumber: 29,
    statusCode: "awaiting_game_validation", bindingSha256: "a".repeat(64), actualGameAcceptanceClaimed: false,
    selections: ["fire", "water", "wind", "electric", "iron"].map((weaknessCode, i) => ({ weaknessCode, entrySha256: String(i).repeat(64) })) };
  const action = { schemaVersion: 1, contractId: "nll/user-validation-action/v1", seasonNumber: 29, weaknessCode: "water",
    statusCode: "prepared", operationUid: null, failureCode: null, actualGameAcceptanceClaimed: false };
  const byId = id => { if (!nodes.has(id)) nodes.set(id, { addEventListener() {} }); return nodes.get(id); };
  const api = async (path, options) => {
    calls.push({ path, options });
    if (options?.method === "POST") {
      if (failPost) throw Error("uncertain_response");
      Object.assign(action, { operationUid: options.body.operationUid, statusCode: "awaiting_user_approval" });
      return { payload: structuredClone(action) };
    }
    return { payload: structuredClone(path.endsWith("/29") ? delivery : action) };
  };
  const controller = create({ document: { getElementById: byId }, api, getSelection: () => selection,
    uid: () => `synthetic-${++next}`, schedule: fn => { tasks.set(++next, fn); return next; }, cancel: id => tasks.delete(id) });
  return { controller, selection, delivery, action, byId, calls, tasks, failPost: value => { failPost = value; } };
}
test("selection and refresh perform reads only; an explicit click binds exact weakness and hashes", async () => {
  const f = fixture(); await f.controller.refresh();
  assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 0);
  assert.equal(f.byId("user-validation-start").disabled, false);
  await f.controller.begin("Start");
  const post = f.calls.find(c => c.options?.method === "POST").options.body;
  assert.equal(post.weaknessCode, "water"); assert.equal(post.entrySha256, "1".repeat(64));
  assert.equal(post.bindingSha256, "a".repeat(64)); assert.equal(post.mode, "Start");
  assert.equal(f.byId("user-validation-start").disabled, true);
});
test("all five weaknesses select their own entry; selecting another season hides the validation lane", async () => {
  for (const weakness of ["fire", "water", "wind", "electric", "iron"]) {
    const f = fixture(); f.selection.weaknessCode = weakness; f.action.weaknessCode = weakness;
    await f.controller.refresh(); await f.controller.begin("Start");
    assert.equal(f.calls.find(c => c.options?.method === "POST").options.body.entrySha256,
      f.delivery.selections.find(s => s.weaknessCode === weakness).entrySha256);
    f.selection.validationOnly = false; await f.controller.refresh();
    assert.equal(f.byId("boss-user-validation").hidden, true);
  }
});
test("failed cleanup enables only explicit recovery; polling never recovers automatically", async () => {
  const f = fixture(); f.action.statusCode = "cleanup_required"; await f.controller.refresh();
  assert.equal(f.byId("user-validation-start").disabled, true); assert.equal(f.byId("user-validation-recover").disabled, false);
  await f.controller.begin("Start"); assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 0);
  await f.controller.begin("Recover"); assert.equal(f.calls.find(c => c.options?.method === "POST").options.body.mode, "Recover");
});
test("uncertain POST retry reuses operation identity and never creates an automatic retry", async () => {
  const f = fixture(); f.failPost(true); await f.controller.refresh(); await f.controller.begin("Start");
  assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 1);
  await f.controller.begin("Start");
  const posts = f.calls.filter(c => c.options?.method === "POST"); assert.equal(posts[0].options.body.operationUid, posts[1].options.body.operationUid);
});
test("finished execution is not game acceptance, and malformed/duplicate delivery is blocked", async () => {
  const f = fixture(); f.action.statusCode = "finished"; await f.controller.refresh();
  assert.equal(f.byId("user-validation-start").disabled, true); assert.match(f.byId("user-validation-status").textContent, /원복 완료/);
  f.delivery.selections[0].weaknessCode = "water"; await f.controller.refresh();
  assert.equal(f.byId("user-validation-start").disabled, true);
  assert.equal(f.byId("user-validation-recover").disabled, true);
});
test("unknown state never enables start and an invalid action mode never posts", async () => {
  const f = fixture(); f.action.statusCode = "status_unknown"; await f.controller.refresh(); await f.controller.begin("Start");
  assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 0);
  f.action.statusCode = "prepared"; await f.controller.refresh(); await f.controller.begin("invalid");
  assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 0);
});
test("each preflight and recovery stage remains read-only and never offers a second start", async () => {
  for (const status of ["quick_check", "deep_check", "bootstrap_check", "preparing", "game_start", "running", "cleanup", "status_unknown"]) {
    const f = fixture(); f.action.statusCode = status;
    f.action.progress = { elapsedMilliseconds: 1234, completedReadBytes: 1024, plannedReadBytes: 2048 };
    await f.controller.refresh(); await f.controller.begin("Start"); await f.controller.begin("Recover");
    assert.equal(f.byId("user-validation-start").disabled, true);
    assert.equal(f.byId("user-validation-recover").disabled, true);
    assert.equal(f.tasks.size, 1); assert.equal(f.calls.filter(c => c.options?.method === "POST").length, 0);
    assert.match(f.byId("user-validation-status").textContent, /1.2초/);
    if (status !== "running") assert.doesNotMatch(f.byId("user-validation-status").textContent, /게임 프로세스 실행 중/);
  }
});
