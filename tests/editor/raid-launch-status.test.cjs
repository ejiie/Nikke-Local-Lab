"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const source = fs.readFileSync(path.join(__dirname,
  "../../src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js"), "utf8");
const bodies = ["humanStatus", "hasReadyLaunchPreparation", "refreshLaunchPreparation",
  "updateRaidActions", "renderLaunch", "loadLaunchHistory"].map(name => {
  const match = new RegExp(`^(?:async )?function ${name}\\(`, "m").exec(source);
  assert.ok(match, name);
  const rest = source.slice(match.index);
  const next = /\n(?:async )?function /.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
});
const elements = { fire: "작열", water: "수냉", wind: "풍압", electric: "전격", iron: "철갑" };
function ready(weaknessCode = "water") {
  return { schemaVersion: 1, contractId: "nll/phase-d-preparation/v1", statusCode: "ready",
    seasonNumber: 26, weaknessCode, bindingSha256: "a".repeat(64) };
}
function setup() {
  const nodes = new Map(), timers = new Map(), output = new Map(), badge = {};
  const byId = id => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id); };
  const state = { currentWorkspace: { validationStatusCode: "ready", validationReasonCodes: [] },
    accountUid: "synthetic-account", selectedBossSeason: 26, selectedWeaknessCode: "water",
    launchProjection: null, launchRequestPending: false, launchPollTimer: null,
    launchPreparation: ready(), preparationRequestNumber: 0 };
  let timerId = 0;
  const ctx = vm.createContext({ state, byId, AbortController, elementLabels: elements,
    bossSeasonLabels: { 26: "프로비던스" },
    bossUserValidation: { refresh: async () => {} },
    document: { querySelector: () => ({ disabled: false, querySelector: () => badge }) },
    showJson: (id, value) => output.set(id, value),
    setTimeout: callback => { const id = ++timerId; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id), run: (_, fn) => fn(),
    api: async () => ({ payload: ready(state.selectedWeaknessCode) }) });
  vm.runInContext(bodies.join("\n"), ctx);
  const title = () => byId("launch-status-title").textContent;
  const description = () => byId("launch-status-description").textContent;
  const buttons = disabled => {
    assert.equal(byId("selected-boss-launch").disabled, disabled);
    assert.equal(byId("launch-game").disabled, disabled);
  };
  return { ctx, state, byId, title, description, buttons, timers, output, badge };
}

test("terminal history and all five weakness refreshes show current readiness, retaining history", async () => {
  for (const statusCode of ["completed", "rolled_back", "failed"]) {
    const h = setup();
    const projection = { statusCode, launchContextUid: "synthetic-history",
      ...(statusCode === "failed" ? { failureCode: "synthetic_failure" } : {}) };
    h.ctx.api = async () => ({ payload: [projection] });
    await h.ctx.loadLaunchHistory();
    assert.equal(h.state.launchProjection, projection);
    for (const [code, label] of Object.entries(elements)) {
      h.state.selectedWeaknessCode = code;
      let finish;
      h.ctx.api = () => new Promise(resolve => { finish = resolve; });
      const pending = h.ctx.refreshLaunchPreparation();
      assert.match(h.title(), /구성 확인 중/);
      h.buttons(true);
      finish({ payload: ready(code) });
      await pending;
      assert.equal(h.title(), `시즌 26 · 프로비던스 · 약점 ${label} 실행 준비 완료`);
      assert.match(h.description(), /최근 실행:/);
      if (statusCode === "failed") assert.match(h.description(), /synthetic_failure/);
      assert.equal(h.badge.textContent, "구성 확인 완료");
      assert.equal(h.state.launchContextUid, "synthetic-history");
      assert.equal(h.output.get("launch-output"), projection);
      assert.equal(h.timers.size, 0);
      h.buttons(false);
    }
  }
});

test("history arriving during preparation cannot leave its transient label after readiness", async () => {
  const h = setup();
  let finish;
  h.ctx.api = () => new Promise(resolve => { finish = resolve; });
  const pending = h.ctx.refreshLaunchPreparation();
  h.ctx.renderLaunch({ statusCode: "rolled_back", launchContextUid: "synthetic-history" });
  assert.match(h.title(), /구성 확인 중/);
  finish({ payload: ready() });
  await pending;
  assert.match(h.title(), /약점 수냉 실행 준비 완료/);
  h.buttons(false);
});

test("old terminal history does not suppress no-account or invalid-workspace guidance", () => {
  const h = setup();
  h.ctx.renderLaunch({ statusCode: "completed", launchContextUid: "synthetic-history" });
  h.state.currentWorkspace = null;
  h.ctx.updateRaidActions();
  assert.equal(h.title(), "계정을 선택하세요");
  h.buttons(true);
  h.state.currentWorkspace = { validationStatusCode: "blocked", validationReasonCodes: ["synthetic_reason"] };
  h.ctx.updateRaidActions();
  assert.equal(h.title(), "계정 확인 필요");
  h.buttons(true);
});

test("active and recovery states override preparation without enabling start or losing polling", async () => {
  for (const statusCode of ["draft", "validated", "started"]) {
    const h = setup();
    h.ctx.renderLaunch({ statusCode, launchContextUid: "synthetic-active" });
    const label = h.title();
    h.state.launchPreparation = null;
    h.ctx.updateRaidActions();
    assert.equal(h.title(), label);
    await h.ctx.refreshLaunchPreparation();
    assert.equal(h.title(), label);
    assert.equal(h.timers.size, 1);
    h.buttons(true);
  }
  const h = setup();
  h.ctx.renderLaunch({ statusCode: "started", launchContextUid: "synthetic-active",
    failureCode: "phase_d_process_identity_unresolved" });
  await h.ctx.refreshLaunchPreparation();
  assert.equal(h.title(), "실행 상태 확인 필요");
  assert.match(h.description(), /phase_d_process_identity_unresolved/);
  assert.equal(h.timers.size, 1);
  h.buttons(true);
});

test("pending launch is explicitly displayed before any execution projection exists", () => {
  const h = setup();
  h.state.launchPreparation = null;
  h.ctx.updateRaidActions();
  h.state.launchPreparation = ready();
  h.state.launchRequestPending = true;
  h.ctx.updateRaidActions();
  assert.equal(h.title(), "게임 실행 요청 중…");
  h.buttons(true);
});

test("blocked, failed, and stale preparations cannot inherit a ready message from history", async () => {
  const h = setup();
  h.ctx.renderLaunch({ statusCode: "completed", launchContextUid: "synthetic-history" });
  h.state.selectedBossSeason = 29;
  h.ctx.api = async () => ({ payload: { statusCode: "blocked", failureCode: "phase_d_boss_variant_profile_drifted" } });
  await h.ctx.refreshLaunchPreparation();
  assert.equal(h.title(), "보스·리소스 구성 확인 필요");
  assert.match(h.description(), /phase_d_boss_variant_profile_drifted/);
  h.buttons(true);
  h.state.selectedBossSeason = 26;
  h.ctx.api = async () => { throw Error("offline"); };
  await h.ctx.refreshLaunchPreparation();
  assert.match(h.description(), /phase_d_preparation_unavailable/);
  h.buttons(true);
  h.state.selectedWeaknessCode = "electric";
  const answers = [];
  h.ctx.api = () => new Promise(resolve => answers.push(resolve));
  const obsolete = h.ctx.refreshLaunchPreparation();
  h.state.selectedWeaknessCode = "water";
  const current = h.ctx.refreshLaunchPreparation();
  answers[1]({ payload: ready("water") });
  await current;
  answers[0]({ payload: ready("electric") });
  await obsolete;
  assert.match(h.title(), /약점 수냉 실행 준비 완료/);
  h.buttons(false);
});
