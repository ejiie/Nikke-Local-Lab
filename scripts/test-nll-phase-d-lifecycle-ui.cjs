"use strict";
// Offline behavior tests: real editor functions, fake DOM/API/timers. No network.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js"), "utf8");
const names = ["humanStatus", "hasReadyLaunchPreparation", "refreshLaunchPreparation", "updateRaidActions", "renderLaunch", "startLaunch", "refreshLaunch", "loadLaunchHistory"];
const bodies = names.map(name => {
  const match = new RegExp(`^(?:async )?function ${name}\\(`, "m").exec(source);
  assert.ok(match, name);
  const rest = source.slice(match.index);
  const next = /\n(?:async )?function /.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
});
const nodes = new Map();
const byId = id => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id); };
const state = {
  accountUid: "synthetic-account", currentWorkspace: { validationStatusCode: "ready", validationReasonCodes: [] },
  launchProjection: null, launchPollTimer: null, launchContextUid: null,
  launchRequestPending: false, selectedBossSeason: 26, selectedWeaknessCode: "water",
  preparationRequestNumber: 0,
  launchPreparation: { schemaVersion: 1, contractId: "nll/phase-d-preparation/v1", seasonNumber: 26,
    weaknessCode: "water", statusCode: "ready", bindingSha256: "a".repeat(64) }
};
let nextTimer = 0;
const timers = new Map();
const context = vm.createContext({
  bossUserValidation: { refresh: async () => {} },
  state, byId, AbortController, document: { querySelector: () => ({ disabled: false, querySelector: () => null }) },
  elementLabels: { water: "수냉" }, bossSeasonLabels: { 26: "프로비던스" },
  showJson() {}, setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
  clearTimeout: id => timers.delete(id), run: (_, action) => action(),
  value: id => id === "launch-season" ? "26" : "challenge", parseCanonicalInteger: Number,
  api: async () => ({ payload: { launchContextUid: "synthetic-launch", statusCode: "draft" } })
});
vm.runInContext(bodies.join("\n"), context);
async function main() {
  context.renderLaunch({ launchContextUid: "synthetic-launch", statusCode: "started" });
  assert.equal(byId("selected-boss-launch").disabled, true);
  assert.equal(byId("launch-game").disabled, true);
  assert.equal(byId("launch-status-title").textContent, "게임 실행 중");
  context.updateRaidActions();
  assert.equal(byId("launch-status-title").textContent, "게임 실행 중");
  context.renderLaunch({ launchContextUid: "synthetic-launch", statusCode: "started", failureCode: "phase_d_process_identity_unresolved" });
  assert.equal(byId("launch-status-title").textContent, "실행 상태 확인 필요");
  assert.match(byId("launch-status-description").textContent, /phase_d_process_identity_unresolved/);
  assert.equal(byId("selected-boss-launch").disabled, true); // not proof of cold runtime
  assert.equal(timers.size, 1); // keep polling for genuine recovery
  context.renderLaunch({ launchContextUid: "synthetic-launch", statusCode: "rolled_back" });
  assert.equal(byId("selected-boss-launch").disabled, false);
  assert.equal(byId("launch-status-title").textContent, "시즌 26 · 프로비던스 · 약점 수냉 실행 준비 완료");
  assert.match(byId("launch-status-description").textContent, /최근 실행: 복구 완료/);
  assert.equal(timers.size, 0);
  let finish;
  context.api = () => new Promise(resolve => { finish = resolve; });
  const start = context.startLaunch();
  assert.equal(state.launchRequestPending, true);
  assert.equal(byId("selected-boss-launch").disabled, true);
  await context.startLaunch(); // duplicate click must not replace the pending request
  finish({ payload: { launchContextUid: "synthetic-launch", statusCode: "draft" } });
  await start;
  assert.equal(state.launchRequestPending, false);
  assert.equal(byId("selected-boss-launch").disabled, true);
  context.api = async () => { throw new Error("temporary_status_failure"); };
  await assert.rejects(context.refreshLaunch(), /temporary_status_failure/);
  assert.equal(timers.size, 1);
  assert.equal(byId("selected-boss-launch").disabled, true);
  context.renderLaunch({ launchContextUid: "synthetic-launch", statusCode: "failed", failureCode: "synthetic_failure" });
  assert.match(byId("launch-status-description").textContent, /synthetic_failure/);
  assert.equal(timers.size, 0);
  const readyPreparation = state.launchPreparation;
  const answers = [];
  context.api = () => new Promise(resolve => answers.push(resolve));
  const obsolete = context.refreshLaunchPreparation();
  assert.equal(byId("selected-boss-launch").disabled, true);
  state.selectedBossSeason = 29;
  const current = context.refreshLaunchPreparation();
  answers[1]({ payload: { statusCode: "blocked", failureCode: "phase_d_boss_variant_profile_drifted" } });
  await current;
  answers[0]({ payload: readyPreparation });
  await obsolete;
  assert.equal(byId("selected-boss-launch").disabled, true);
  assert.match(byId("launch-status-description").textContent, /phase_d_boss_variant_profile_drifted/);
  await assert.rejects(context.startLaunch(), /phase_d_preparation_not_ready/);
  state.selectedBossSeason = 26;
  context.api = async () => { throw new Error("offline"); };
  await context.refreshLaunchPreparation();
  assert.equal(byId("launch-game").disabled, true);
  context.api = async () => ({ payload: readyPreparation });
  await context.refreshLaunchPreparation();
  assert.equal(byId("launch-game").disabled, false);
  state.currentWorkspace = null;
  state.accountUid = null;
  state.launchProjection = null;
  state.launchPreparation = null;
  context.updateRaidActions();
  assert.match(byId("launch-status-title").textContent, /구성 확인 중/);
  state.launchPreparation = readyPreparation;
  context.updateRaidActions();
  assert.equal(byId("launch-status-title").textContent, "계정을 선택하세요");
  assert.equal(byId("launch-status-description").textContent,
    "보스·리소스 구성 확인이 완료되었습니다. 홈에서 실행할 계정을 선택하세요.");
  assert.equal(byId("selected-boss-launch").disabled, true);
  assert.equal(byId("launch-game").disabled, true);
  console.log("Phase D lifecycle UI: pending/active/terminal/duplicate/read-error behavior passed offline.");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
