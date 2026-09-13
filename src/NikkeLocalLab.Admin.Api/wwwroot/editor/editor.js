"use strict";

const byId = (id) => document.getElementById(id);
const state = {
  csrf: null,
  accounts: [],
  currentAccountSummary: null,
  currentWorkspace: null,
  accountUid: null,
  profileRevisionUid: null,
  candidateDraftUid: null,
  candidateSha256: null,
  editDiffSha256: null,
  editOperations: [],
  currentProfile: null,
  importDraftUid: null,
  importDraftSha256: null,
  importDiffSha256: null,
  createImportDiffSha256: null,
  rebaseDiffSha256: null,
  reviewDiffSha256: null,
  fetchedSnapshotUid: null,
  fetchedLobbyDiffSha256: null,
  lobbyRevisionUid: null,
  walletRevisionUid: null,
  lobbySelections: null,
  featureManifest: null,
  operationUids: Object.create(null),
  operationRequestFingerprints: Object.create(null),
  workspaceSaveAttempts: new Map(),
  workspaceSaveRecovery: new Map(),
  workspaceSaveBusy: false,
  launchContextUid: null,
  launchPollTimer: null,
  launchProjection: null,
  launchRequestPending: false,
  launchPreparation: null,
  preparationRequestNumber: 0,
  preparationController: null,
  presentation: { characters: [], consoles: [], supportDefinitions: [], overloadOptions: [] },
  presentationByCharacter: new Map(),
  presentationByConsole: new Map(),
  presentationBySupport: new Map(),
  presentationByOverload: new Map(),
  accountLobbyByUid: new Map(),
  currentFetchedSnapshot: null,
  currentImportDraft: null,
  combatPowerByCharacter: new Map(),
  selectedNikkeUid: null,
  selectedBossSeason: 26,
  selectedWeaknessCode: "iron"
};

const consoleLabels = Object.freeze({
  common: "공용 콘솔", attacker: "화력형 콘솔", defender: "방어형 콘솔",
  supporter: "지원형 콘솔", elysion: "엘리시온 콘솔", missilis: "미실리스 콘솔",
  tetra: "테트라 콘솔", pilgrim: "필그림 콘솔", abnormal: "어브노멀 콘솔"
});
const consoleGroups = Object.freeze([
  { code: "common-class", label: "공용 · 클래스", coordinates: ["common", "attacker", "defender", "supporter"] },
  { code: "manufacturer", label: "기업", coordinates: ["elysion", "missilis", "tetra", "pilgrim", "abnormal"] }
]);
const bossSeasonLabels = Object.create(null);
const manufacturerLabels = Object.freeze({
  elysion: "엘리시온", missilis: "미실리스", tetra: "테트라",
  pilgrim: "필그림", abnormal: "어브노멀"
});
const classLabels = Object.freeze({ attacker: "화력형", defender: "방어형", supporter: "지원형" });
const weaponLabels = Object.freeze({
  assault_rifle: "소총", machine_gun: "머신건", rocket_launcher: "런처",
  shotgun: "샷건", sniper_rifle: "저격소총", submachine_gun: "기관단총"
});
const weaponShortLabels = Object.freeze({
  assault_rifle: "AR", machine_gun: "MG", rocket_launcher: "RL",
  shotgun: "SG", sniper_rifle: "SR", submachine_gun: "SMG"
});
const elementLabels = Object.freeze({
  fire: "작열", water: "수냉", wind: "풍압", electric: "전격", iron: "철갑"
});
const elementGlyphs = Object.freeze({
  fire: "◆", water: "⬟", wind: "⬢", electric: "✦", iron: "◇"
});
const uiAssetRoot = "/editor/assets/ui";
const elementAssetNames = Object.freeze({
  fire: "fire", water: "water", wind: "wind", electric: "electric", iron: "iron"
});
const weaponAssetNames = Object.freeze({
  assault_rifle: "assault_rifle", machine_gun: "machine_gun",
  rocket_launcher: "rocket_launcher", shotgun: "shotgun",
  sniper_rifle: "sniper_rifle", submachine_gun: "submachine_gun"
});
const burstAssetCodes = Object.freeze({ 1: "1", 2: "2", 3: "3", 5: "p" });
const burstDisplayLabels = Object.freeze({ 1: "Ⅰ", 2: "Ⅱ", 3: "Ⅲ", 5: "P" });
const equipmentSlotLabels = Object.freeze({
  head: "머리", torso: "몸통", arms: "팔", legs: "다리"
});
const fieldLabels = Object.freeze({
  character_level: "레벨", limit_break: "한계돌파", core_level: "코어 강화",
  bond_level: "호감도", skill_1_level: "스킬 1", skill_2_level: "스킬 2",
  burst_level: "버스트 스킬", "cube.level": "하모니 큐브 레벨", account_cube_level: "계정 큐브 레벨",
  "collection.level": "소장품 레벨", "collection.definition": "소장품 종류",
  synchro_level: "싱크로 레벨"
});
const pageTitles = Object.freeze({
  home: ["지휘관 관리", "홈"], account: ["계정 정보", "계정 설정"],
  nikkes: ["보유 니케", "니케 관리"], raid: ["보스 선택", "솔로 레이드"],
  import: ["새 계정 등록", "계정 가져오기"], advanced: ["문제 해결", "고급 진단"]
});

function showStatus(message) { byId("status").textContent = message; }
function showJson(target, value) { byId(target).textContent = JSON.stringify(value, null, 2); }
function value(id) { return byId(id).value.trim(); }
function appendPortrait(container, portraitPath, displayName, lazy = false) {
  let image = null;
  const fallback = () => {
    image?.remove();
    if (container.querySelector(":scope > .portrait-fallback")) return;
    const initial = document.createElement("span");
    initial.className = "portrait-fallback";
    initial.textContent = (displayName || "N").slice(0, 1);
    container.prepend(initial);
  };
  if (!portraitPath) {
    fallback();
    return;
  }
  image = document.createElement("img");
  image.src = portraitPath;
  image.alt = "";
  if (lazy) image.loading = "lazy";
  image.addEventListener("error", fallback, { once: true });
  container.appendChild(image);
}
function appendPresentationImage(container, path, className, alt, fallbackText = "?") {
  const image = document.createElement("img");
  image.className = className;
  image.src = path;
  image.alt = alt || "";
  image.loading = "lazy";
  image.addEventListener("error", () => {
    image.remove();
    if (!fallbackText) return;
    const fallback = document.createElement("span");
    fallback.className = `${className} presentation-image-fallback`;
    fallback.textContent = fallbackText;
    container.appendChild(fallback);
  }, { once: true });
  container.appendChild(image);
  return image;
}
function configuredSynchroLevel() {
  const projected = effectiveProfileValue("synchro_level", null)?.integerValue;
  if (Number.isSafeInteger(projected) && projected > 0) return projected;
  const raw = byId("general-synchro")?.value?.trim() || "";
  return /^(0|[1-9][0-9]*)$/.test(raw)
    ? parseCanonicalInteger(raw, "synchro_level_invalid", 1)
    : 1;
}
function burstLabel(step) { return burstDisplayLabels[step] || "-"; }
function burstAssetPath(step) {
  const code = burstAssetCodes[step];
  return code ? `${uiAssetRoot}/burst-${code}.png` : null;
}
function displayField(fieldCode) {
  if (fieldLabels[fieldCode]) return fieldLabels[fieldCode];
  const equipment = /^equipment\.([a-z_]+)\.(.+)$/.exec(fieldCode);
  if (equipment) {
    const slots = { head: "머리 장비", torso: "몸통 장비", arms: "팔 장비", legs: "다리 장비" };
    const facts = {
      state: "착용 상태", enhancement_level: "강화 단계", definition: "장비 종류",
      manufacturer_matched: "기업 일치", kind: "종류", value: "수치"
    };
    return `${slots[equipment[1]] || "장비"} · ${facts[equipment[2]] || equipment[2]}`;
  }
  return fieldCode.replaceAll("_", " ");
}
function humanStatus(code) {
  return ({ ready: "실행 준비 완료", blocked: "확인 필요", incomplete: "정보 미완성",
    draft: "검증 준비", validated: "실행 준비", started: "게임 실행 중", completed: "실행 완료",
    failed: "실행 실패", rolled_back: "복구 완료" })[code] || "상태 확인 필요";
}
function setPage(selected) {
  for (const candidate of document.querySelectorAll(".tab-button")) {
    candidate.setAttribute("aria-selected", String(candidate.dataset.tab === selected));
  }
  for (const panel of document.querySelectorAll(".tab-panel")) {
    panel.hidden = panel.dataset.tabPanel !== selected;
  }
  const title = pageTitles[selected] || pageTitles.home;
  byId("page-eyebrow").textContent = title[0];
  byId("page-title").textContent = title[1];
  window.scrollTo({ top: 0, behavior: "smooth" });
}
async function loadPresentationCatalog() {
  try {
    const response = await fetch("/editor/presentation.json", {
      credentials: "same-origin", cache: "no-store"
    });
    if (!response.ok) return;
    const catalog = await response.json();
    if (catalog?.contractId !== "nll/control-center-presentation/v1") return;
    state.presentation = catalog;
    state.presentationByCharacter = new Map(
      (catalog.characters || []).map((item) => [item.characterUid, item]));
    state.presentationByConsole = new Map(
      (catalog.consoles || []).map((item) => [item.definitionUid, item]));
    state.presentationBySupport = new Map(
      (catalog.supportDefinitions || []).map((item) => [item.definitionUid, item]));
    state.presentationByOverload = new Map(
      (catalog.overloadOptions || []).map((item) => [item.definitionUid, item]));
  } catch { /* Presentation data is optional; the editor remains fail-safe. */ }
}
function newOperationUid() {
  return crypto.randomUUID();
}
function stableOperationUid(key) {
  state.operationUids[key] ||= newOperationUid();
  return state.operationUids[key];
}
function operationUidForRequest(key, request) {
  const fingerprint = JSON.stringify(request);
  if (state.operationRequestFingerprints[key] !== fingerprint) {
    state.operationUids[key] = newOperationUid();
    state.operationRequestFingerprints[key] = fingerprint;
  }
  return state.operationUids[key];
}
function clearOperationUids(...keys) {
  for (const key of keys) {
    delete state.operationUids[key];
    delete state.operationRequestFingerprints[key];
  }
}

function parseCanonicalInteger(raw, code, minimum = Number.MIN_SAFE_INTEGER) {
  if (!/^-?(0|[1-9][0-9]*)$/.test(raw)) { throw new Error(code); }
  const parsed = Number(raw);
  if (!Number.isSafeInteger(parsed) || parsed < minimum) { throw new Error(code); }
  return parsed;
}

function requireSafeWireBalance(balance) {
  if (typeof balance !== "number" || !Number.isSafeInteger(balance) || balance < 0) {
    throw new Error("wallet_balance_not_js_safe_integer");
  }
  return balance;
}

async function readResponse(response) {
  const payload = await response.json().catch(() => ({ code: "response_json_invalid" }));
  if (!response.ok) {
    const error = new Error(payload.code || "request_failed");
    error.status = response.status;
    throw error;
  }
  return { payload, etag: response.headers.get("ETag")?.replaceAll("\"", "") || null };
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (options.body !== undefined) {
    headers.set("Content-Type", "application/json");
    if (state.csrf) { headers.set("X-NLL-CSRF", state.csrf); }
  }
  const response = await fetch(path, {
    method: options.method || "GET",
    headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    credentials: "same-origin",
    cache: "no-store",
    signal: options.signal
  });
  return readResponse(response);
}

function withIfMatch(revisionUid) {
  if (!revisionUid) { throw new Error("revision_not_loaded"); }
  return { "If-Match": `"${revisionUid}"` };
}

async function run(label, action) {
  try {
    showStatus(`${label} 진행 중…`);
    await action();
    showStatus(`${label} 완료`);
  } catch (error) {
    showStatus(`${label} 실패: ${error instanceof Error ? error.message : "unknown_error"}`);
  }
}

async function readCombatPowerProjection(snapshotUid) {
  if (!snapshotUid) return null;
  const fetched = await api(
    `/admin-api/v1/fetched-snapshots/${encodeURIComponent(snapshotUid)}`);
  if (!fetched.payload.sanitizedDraftUid) return { fetched: fetched.payload, draft: null };
  const draft = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(fetched.payload.sanitizedDraftUid)}`);
  const detail = new Map();
  const roster = new Map();
  for (const item of draft.payload.values || []) {
    if (!item.subjectUid || !Number.isSafeInteger(item.integerValue)) continue;
    if (item.fieldCode === "detail_combat_power_observation") {
      detail.set(item.subjectUid, item.integerValue);
    }
    if (item.fieldCode === "roster_combat_power_observation") {
      roster.set(item.subjectUid, item.integerValue);
    }
  }
  state.combatPowerByCharacter = new Map(
    [...new Set([...detail.keys(), ...roster.keys()])]
      .map((uid) => [uid, detail.get(uid) ?? roster.get(uid)]));
  return { fetched: fetched.payload, draft: draft.payload };
}

async function loadAccount() {
  state.accountUid = value("account-uid");
  await refreshWorkspaceSaveRecovery();
  state.fetchedSnapshotUid = null;
  state.fetchedLobbyDiffSha256 = null;
  byId("preview-fetched-lobby").disabled = true;
  byId("apply-fetched-lobby").disabled = true;
  state.editOperations = [];
  invalidateEditPreview();
  invalidateImportPreview();
  invalidateRebasePreview();
  renderEditOperations();
  clearOperationUids("local-state-initialize", "lobby-save", "wallet-save");
  const profile = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/profile`);
  const workspace = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/workspace`);
  state.currentProfile = profile.payload;
  state.currentWorkspace = workspace.payload;
  state.profileRevisionUid = profile.etag;
  state.fetchedSnapshotUid = workspace.payload.fetchedSnapshotUid || null;
  state.currentFetchedSnapshot = null;
  state.currentImportDraft = null;
  state.combatPowerByCharacter = new Map();
  let combatPowerSnapshotUid = state.fetchedSnapshotUid;
  if (!combatPowerSnapshotUid) {
    try {
      const latestObserved = await api(
        `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/fetched-snapshots/latest`);
      combatPowerSnapshotUid = latestObserved.payload.snapshotUid || null;
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "fetched_snapshot_observation_not_found") {
        throw error;
      }
    }
  }
  if (combatPowerSnapshotUid) {
    const projection = await readCombatPowerProjection(combatPowerSnapshotUid);
    if (state.fetchedSnapshotUid) state.currentFetchedSnapshot = projection?.fetched || null;
    state.currentImportDraft = projection?.draft || null;
  }
  state.currentAccountSummary = state.accounts.find((item) => item.accountUid === state.accountUid) || null;
  byId("account-label").value = workspace.payload.accountLabel;
  const character = profile.payload.characterCatalog;
  const support = profile.payload.combatSupportCatalog;
  byId("rebase-character-catalog").value = character.catalogSnapshotUid;
  byId("rebase-character-dataset").value = character.datasetSnapshotUid;
  byId("rebase-character-manifest").value = character.manifestSha256;
  byId("rebase-support-catalog").value = support.catalogSnapshotUid;
  byId("rebase-support-dataset").value = support.datasetSnapshotUid;
  byId("rebase-support-manifest").value = support.manifestSha256;
  showJson("account-output", profile.payload);
  renderProgression();
  renderAccounts();
  renderGeneralEditor();
  synchronizeCharacterLevelsToSynchro();
  renderNikkeEditor();
  byId("add-edit").disabled = false;
  byId("clear-edits").disabled = false;
  byId("preview-edit").disabled = false;
  byId("load-bootstrap").disabled = false;
  byId("load-local-state").disabled = false;
  byId("initialize-local-state").disabled = !state.featureManifest;
  byId("rename-account").disabled = false;
  byId("load-revisions").disabled = false;
  byId("export-runtime").disabled = false;
  byId("register-fetched-snapshot").disabled = false;
  byId("save-everything").disabled = false;
  byId("save-as-everything").disabled = false;
  byId("nikke-save-everything").disabled = false;
  byId("nikke-save-as").disabled = false;
  byId("launch-account").value = `${workspace.payload.accountLabel} (${workspace.payload.accountUid})`;
  byId("launch-game").disabled = workspace.payload.validationStatusCode !== "ready" ||
    (workspace.payload.validationReasonCodes || []).length !== 0;
  byId("load-launch-history").disabled = false;
  updateRaidActions();
  renderAccountSummary();
  try { await loadLocalState(); } catch { renderAccountSummary(); }
  renderWorkspaceSaveRecovery();
}

function renderAccountSummary() {
  const workspace = state.currentWorkspace;
  const fetched = state.currentFetchedSnapshot?.account || state.currentFetchedSnapshot;
  const lobby = state.accountLobbyByUid.get(state.accountUid);
  const name = value("display-name") || lobby?.displayName || fetched?.displayName || workspace?.accountLabel || "계정을 선택하세요";
  const commander = value("commander-level") || lobby?.commanderLevel || fetched?.commanderLevel || "-";
  const synchro = value("general-synchro") || fetched?.synchroLevel || "-";
  byId("top-account-name").textContent = name;
  byId("top-account-detail").textContent = workspace ? workspace.accountLabel : "로컬 전용";
  byId("profile-display-title").textContent = name;
  byId("profile-account-label").textContent = workspace ? workspace.accountLabel : "저장 슬롯 없음";
  byId("profile-commander-summary").textContent = String(commander);
  byId("profile-synchro-summary").textContent = String(synchro);
  const readiness = byId("account-readiness");
  const ready = workspace?.validationStatusCode === "ready" &&
    (workspace.validationReasonCodes || []).length === 0;
  readiness.className = `status-pill ${workspace ? (ready ? "ready" : "blocked") : "neutral"}`;
  readiness.textContent = workspace ? humanStatus(workspace.validationStatusCode) : "계정 미선택";
}

function renderProgression() {
  const target = byId("progression-output");
  const progression = state.currentFetchedSnapshot?.progression;
  if (!progression) {
    target.textContent = "등록된 스토리 진행 정보가 없습니다.";
    return;
  }
  const rows = [
    ["일반 캠페인", progression.normalStageLabel || "정보 없음"],
    ["하드 캠페인", progression.hardStageLabel || "정보 없음"],
    ["스토리", progression.storyStageLabel || "정보 없음"],
    ["완료 메인 퀘스트", progression.mainQuestCompletedCount ?? "정보 없음"],
    ["완료 시나리오", progression.completedScenarioCount ?? "정보 없음"],
    ["확인한 콘텐츠 해금", progression.contentsOpenUnlockedCount ?? "정보 없음"]
  ];
  target.replaceChildren();
  for (const [label, data] of rows) {
    const row = document.createElement("div");
    const strong = document.createElement("strong");
    const span = document.createElement("span");
    strong.textContent = label;
    span.textContent = String(data);
    row.append(strong, span);
    target.appendChild(row);
  }
}

function hasReadyLaunchPreparation() {
  const preparation = state.launchPreparation;
  return preparation?.contractId === "nll/phase-d-preparation/v1" &&
    preparation.schemaVersion === 1 && preparation.statusCode === "ready" &&
    preparation.seasonNumber === state.selectedBossSeason &&
    preparation.weaknessCode === state.selectedWeaknessCode &&
    /^[0-9a-f]{64}$/.test(preparation.bindingSha256 || "");
}

async function refreshLaunchPreparation() {
  const requestNumber = ++state.preparationRequestNumber;
  state.preparationController?.abort();
  const controller = new AbortController();
  state.preparationController = controller;
  const season = state.selectedBossSeason;
  const weakness = state.selectedWeaknessCode;
  state.launchPreparation = null;
  updateRaidActions();
  try {
    const result = await api("/admin-api/v1/execution-preparation", {
      method: "POST", body: { seasonNumber: season, weaknessCode: weakness }, signal: controller.signal
    });
    if (requestNumber !== state.preparationRequestNumber) return;
    state.launchPreparation = result.payload;
  } catch (error) {
    if (requestNumber !== state.preparationRequestNumber) return;
    state.launchPreparation = { statusCode: "blocked", failureCode: "phase_d_preparation_unavailable" };
  } finally {
    if (requestNumber === state.preparationRequestNumber) {
      state.preparationController = null;
      updateRaidActions();
    }
  }
}

function updateRaidActions() {
  const ready = Boolean(state.currentWorkspace) &&
    state.currentWorkspace.validationStatusCode === "ready" &&
    (state.currentWorkspace.validationReasonCodes || []).length === 0;
  const selectedBoss = document.querySelector(
    `.raid-boss-option[data-season="${state.selectedBossSeason}"]`);
  const bossEnabled = Boolean(selectedBoss) && !selectedBoss.disabled;
  const configured = hasReadyLaunchPreparation();
  const badge = selectedBoss?.querySelector(".available-badge");
  if (badge) badge.textContent = configured ? "구성 확인 완료"
    : state.launchPreparation ? "실행 준비 필요" : "구성 확인 중";
  const projection = state.launchProjection;
  const executionActive = ["draft", "validated", "started"].includes(projection?.statusCode);
  const active = state.launchRequestPending || executionActive;
  byId("selected-boss-launch").disabled = active || !ready || !bossEnabled || !configured;
  byId("launch-game").disabled = active || !ready || !bossEnabled || !configured;
  // One renderer owns the status text and buttons. Terminal history must not
  // freeze a transient preparation label, while live recovery keeps priority.
  if (active) {
    const failureCode = executionActive ? projection.failureCode : null;
    byId("launch-status-title").textContent = failureCode ? "실행 상태 확인 필요"
      : state.launchRequestPending ? "게임 실행 요청 중…" : humanStatus(projection.statusCode);
    byId("launch-status-description").textContent = failureCode ? `확인 필요: ${failureCode}`
      : state.launchRequestPending ? "선택한 계정과 보스의 실행을 준비하고 있습니다."
        : "게임이 종료될 때까지 관리 도구를 닫지 마세요.";
    return;
  }
  if (!configured) {
    byId("launch-status-title").textContent = state.launchPreparation ? "보스·리소스 구성 확인 필요" : "보스·리소스 구성 확인 중…";
    byId("launch-status-description").textContent = state.launchPreparation
      ? `확인 필요: ${state.launchPreparation.failureCode || "phase_d_preparation_invalid"}`
      : "선택한 보스·속성과 실행 리소스의 등록 정보를 대조하고 있습니다.";
    return;
  }
  if (!state.currentWorkspace) {
    byId("launch-status-title").textContent = "계정을 선택하세요";
    byId("launch-status-description").textContent =
      "보스·리소스 구성 확인이 완료되었습니다. 홈에서 실행할 계정을 선택하세요.";
    return;
  }
  const weaknessLabel = elementLabels[state.selectedWeaknessCode] || "미확인";
  const bossLabel = bossSeasonLabels[state.selectedBossSeason] || "선택 보스";
  byId("launch-status-title").textContent = ready
    ? `시즌 ${state.selectedBossSeason} · ${bossLabel} · 약점 ${weaknessLabel} 실행 준비 완료`
    : "계정 확인 필요";
  byId("launch-status-description").textContent = ready
    ? "게임에 진입한 뒤 Challenge 화면에서 실전 또는 모의전을 선택하세요."
    : "계정의 미해결 항목을 먼저 확인하세요.";
  if (["completed", "rolled_back", "failed"].includes(projection?.statusCode)) {
    const failure = projection.failureCode ? ` (${projection.failureCode})` : "";
    byId("launch-status-description").textContent +=
      ` 최근 실행: ${humanStatus(projection.statusCode)}${failure}.`;
  }
}

function renderLaunch(projection) {
  state.launchProjection = projection || null;
  showJson("launch-output", projection);
  state.launchContextUid = projection?.launchContextUid || null;
  byId("refresh-launch").disabled = !state.launchContextUid;
  const active = ["draft", "validated", "started"].includes(projection?.statusCode);
  if (state.launchPollTimer) {
    clearTimeout(state.launchPollTimer);
    state.launchPollTimer = null;
  }
  if (active) {
    state.launchPollTimer = setTimeout(() => {
      run("Launch status", refreshLaunch);
    }, 3000);
  }
  updateRaidActions();
}

async function startLaunch() {
  if (!state.accountUid || !state.currentWorkspace) { throw new Error("account_not_loaded"); }
  if (state.launchRequestPending) return;
  if (!hasReadyLaunchPreparation()) throw new Error("phase_d_preparation_not_ready");
  state.launchRequestPending = true;
  updateRaidActions();
  try {
    const result = await api("/admin-api/v1/executions", {
      method: "POST",
      body: {
        accountUid: state.accountUid,
        seasonNumber: state.selectedBossSeason,
        validationKind: value("launch-kind"),
        weaknessCode: state.selectedWeaknessCode,
        preparationBindingSha256: state.launchPreparation.bindingSha256
      }
    });
    renderLaunch(result.payload);
  } finally {
    state.launchRequestPending = false;
    updateRaidActions();
  }
}

function selectRaidBoss(seasonNumber) {
  bossSeasons.selectSeason(seasonNumber);
}

function renderBossWeaknessSummary() {
  for (const button of document.querySelectorAll(".raid-boss-option")) {
    const code = button.dataset.defaultWeaknessCode;
    const label = elementLabels[code] || "미확인";
    const summary = button.querySelector("[data-boss-weakness-summary]");
    if (!summary) { continue; }
    summary.hidden = false;
    const icon = summary.querySelector("[data-boss-weakness-icon]");
    const text = summary.querySelector("[data-boss-weakness-label]");
    if (icon && elementAssetNames[code]) { icon.src = `${uiAssetRoot}/code-${elementAssetNames[code]}.png`; }
    if (text) { text.textContent = label; }
  }
}

function selectWeaknessCode(weaknessCode) {
  if (!Object.hasOwn(elementAssetNames, weaknessCode)) {
    throw new Error("launch_weakness_code_invalid");
  }
  state.selectedWeaknessCode = weaknessCode;
  const label = elementLabels[weaknessCode];
  const iconPath = `${uiAssetRoot}/code-${elementAssetNames[weaknessCode]}.png`;
  byId("selected-weakness-label").textContent = label;
  byId("selected-weakness-icon").src = iconPath;
  renderBossWeaknessSummary();
  for (const button of document.querySelectorAll(".weakness-option")) {
    button.setAttribute("aria-checked", String(button.dataset.weaknessCode === weaknessCode));
  }
  void refreshLaunchPreparation();
}

async function refreshLaunch() {
  if (!state.launchContextUid) { throw new Error("launch_not_selected"); }
  try {
    const result = await api(
      `/admin-api/v1/executions/${encodeURIComponent(state.launchContextUid)}`);
    renderLaunch(result.payload);
  } catch (error) {
    // A transient read failure cannot declare an active run cold or silently
    // stop all subsequent polling.
    if (["draft", "validated", "started"].includes(state.launchProjection?.statusCode)) {
      if (state.launchPollTimer) clearTimeout(state.launchPollTimer);
      state.launchPollTimer = setTimeout(() => run("Launch status", refreshLaunch), 5000);
    }
    throw error;
  }
}

async function loadLaunchHistory() {
  if (!state.accountUid) { throw new Error("account_not_loaded"); }
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/executions`);
  showJson("launch-output", result.payload);
  if (Array.isArray(result.payload) && result.payload.length > 0) {
    renderLaunch(result.payload[0]);
  }
}

function renderAccounts() {
  const list = byId("account-list");
  list.replaceChildren();
  for (const account of state.accounts) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.accountUid = account.accountUid;
    button.setAttribute("aria-current", String(account.accountUid === state.accountUid));
    const lobby = state.accountLobbyByUid.get(account.accountUid);
    const avatar = document.createElement("span");
    avatar.className = "account-avatar";
    avatar.textContent = (lobby?.displayName || account.accountLabel || "C").slice(0, 1).toUpperCase();
    const names = document.createElement("span");
    names.className = "account-name-group";
    const displayName = document.createElement("strong");
    displayName.textContent = lobby?.displayName || account.accountLabel;
    const label = document.createElement("span");
    label.textContent = lobby?.displayName ? account.accountLabel : "로컬 계정";
    const meta = document.createElement("small");
    meta.textContent = `${humanStatus(account.validationStatusCode)} · 저장본 ${account.profileRevision.revisionNumber}`;
    names.append(displayName, label, meta);
    const level = document.createElement("span");
    level.className = "account-level";
    const levelLabel = document.createElement("span");
    levelLabel.textContent = "지휘관 Lv.";
    const levelValue = document.createElement("strong");
    levelValue.textContent = lobby?.commanderLevel == null ? "-" : String(lobby.commanderLevel);
    level.append(levelLabel, levelValue);
    button.append(avatar, names, level);
    button.addEventListener("click", () => run("Account load", async () => {
      byId("account-uid").value = account.accountUid;
      await loadAccount();
    }));
    item.appendChild(button);
    list.appendChild(item);
  }
}

async function listAccounts() {
  const result = await api("/admin-api/v1/accounts");
  state.accounts = Array.isArray(result.payload) ? result.payload : [];
  const lobbyPairs = await Promise.all(state.accounts.map(async (account) => {
    try {
      const lobby = await api(`/admin-api/v1/accounts/${encodeURIComponent(account.accountUid)}/lobby`);
      return [account.accountUid, lobby.payload];
    } catch { return [account.accountUid, null]; }
  }));
  state.accountLobbyByUid = new Map(lobbyPairs);
  renderAccounts();
}

async function renameAccount() {
  if (!state.currentWorkspace) { throw new Error("account_not_loaded"); }
  const replacement = value("account-label");
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/label`,
    {
      method: "PUT",
      body: {
        expectedAccountLabel: state.currentWorkspace.accountLabel,
        accountLabel: replacement
      }
    });
  state.currentWorkspace.accountLabel = result.payload.accountLabel;
  await listAccounts();
  showJson("account-output", result.payload);
}

async function loadRevisionHistory() {
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/revisions`);
  showJson("account-output", result.payload);
}

async function exportRuntimeCandidate() {
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/runtime-projection-candidate`);
  showJson("account-output", result.payload);
}

async function registerFetchedSnapshot() {
  if (!state.accountUid || !state.profileRevisionUid) { throw new Error("account_not_loaded"); }
  const snapshotFile = byId("fetched-snapshot-file").files?.[0];
  const draftFile = byId("fetched-draft-file").files?.[0];
  const progressionFile = byId("fetched-progression-file").files?.[0];
  if (!snapshotFile || !draftFile) { throw new Error("fetched_snapshot_files_required"); }
  const [canonicalSnapshotJson, canonicalSanitizedDraftJson, canonicalProgressionObservationJson] = await Promise.all([
    snapshotFile.text(), draftFile.text(), progressionFile ? progressionFile.text() : Promise.resolve(null)
  ]);
  let snapshot;
  let draft;
  let progression = null;
  try {
    snapshot = JSON.parse(canonicalSnapshotJson);
    draft = JSON.parse(canonicalSanitizedDraftJson);
    progression = canonicalProgressionObservationJson
      ? JSON.parse(canonicalProgressionObservationJson)
      : null;
  } catch {
    throw new Error("fetched_snapshot_json_invalid");
  }
  if (snapshot?.contractId !== "nll/fetched-account-snapshot/v1" ||
      snapshot?.source?.credentialOrSessionPersisted !== false ||
      snapshot?.source?.rawSourcePersisted !== false ||
      draft?.schema_code !== "nll/sanitized-profile-draft/v1") {
    throw new Error("fetched_snapshot_source_free_contract_invalid");
  }
  if (progression &&
      (progression.contractId !== "nll/fetched-progression-observation/v2" ||
       progression.snapshotUid !== snapshot.snapshotUid ||
       progression.capturedAtUtc !== snapshot.capturedAtUtc ||
       progression?.source?.credentialOrSessionPersisted !== false ||
       progression?.source?.officialUserIdentifierPersisted !== false ||
       progression?.source?.rawSourcePersisted !== false ||
       progression?.source?.rawSourcePathPersisted !== false ||
       progression?.source?.rawSourceHashPersisted !== false)) {
    throw new Error("fetched_progression_observation_binding_invalid");
  }
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/fetched-snapshots`,
    {
      method: "POST",
      headers: withIfMatch(state.profileRevisionUid),
      body: {
        canonicalSnapshotJson,
        canonicalSanitizedDraftJson,
        canonicalProgressionObservationJson
      }
    });
  state.fetchedSnapshotUid = result.payload.snapshotUid;
  state.fetchedLobbyDiffSha256 = null;
  state.importDraftUid = result.payload.sanitizedDraftUid;
  byId("draft-uid").value = state.importDraftUid;
  showJson("progression-output", {
    registration: result.payload,
    lobbySource: {
      displayName: result.payload.displayName,
      commanderLevel: result.payload.commanderLevel
    },
    progression: progression ?? snapshot.progression,
    completeness: snapshot.completeness
  });
  await listAccounts();
  await loadDraft();
  byId("preview-fetched-lobby").disabled = !state.lobbyRevisionUid;
}

async function startAdminSession() {
  await api("/admin-auth/v1/bootstrap", {
    method: "POST",
    body: { code: value("bootstrap-code") }
  });
  byId("bootstrap-code").value = "";
  const csrf = await api("/admin-api/v1/security/csrf");
  state.csrf = csrf.payload.requestToken;
  byId("load-account").disabled = false;
  byId("load-features").disabled = false;
  byId("load-draft").disabled = false;
  byId("refresh-accounts").disabled = false;
  byId("fetch-account-by-uid").disabled = false;
  await loadPresentationCatalog();
  await listAccounts();
  byId("login-screen").hidden = true;
  byId("app-shell").hidden = false;
  showStatus("관리 도구가 준비되었습니다. 계정을 선택하세요.");
  void refreshLaunchPreparation();
  void bossSeasons.refreshJobs();
}

async function loadBootstrap() {
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/bootstrap`);
  showJson("account-output", result.payload);
}

function editOperation() {
  const kind = value("edit-kind");
  const raw = value("edit-value");
  const operation = {
    fieldCode: value("edit-field"),
    subjectUid: value("edit-subject") || null,
    valueKind: kind,
    integerValue: null,
    booleanValue: null,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  };
  if (kind === "integer") {
    operation.integerValue = parseCanonicalInteger(raw, "integer_value_invalid");
  }
  if (kind === "boolean") {
    if (raw !== "true" && raw !== "false") { throw new Error("boolean_value_invalid"); }
    operation.booleanValue = raw === "true";
  }
  if (kind === "reference") { operation.referenceUid = raw; }
  if (kind === "exact_decimal") {
    operation.unscaledValue = parseCanonicalInteger(raw, "exact_decimal_value_invalid");
    operation.decimalScale = parseCanonicalInteger(value("edit-scale"), "decimal_scale_invalid", 0);
    if (operation.decimalScale > 12) { throw new Error("decimal_scale_invalid"); }
  }
  if (kind === "controlled") { operation.controlledValue = raw; }
  return operation;
}

function invalidateEditPreview() {
  state.candidateDraftUid = null;
  state.candidateSha256 = null;
  state.editDiffSha256 = null;
  byId("save-profile").disabled = true;
  byId("save-as-profile").disabled = true;
  clearOperationUids("edit-preview", "edit-save", "edit-save-as");
}

function renderEditOperations() {
  showJson("operation-output", state.editOperations);
  byId("pending-edit-count").textContent = `변경 ${state.editOperations.length}건`;
  renderConsoleCardState();
  renderCubeCardState();
}

function addProfileOperation(operation) {
  addProfileOperations([operation]);
}

function upsertProfileOperation(operation) {
  upsertProfileOperations([operation]);
}

function upsertProfileOperations(operations) {
  const replacements = new Map(operations.map((operation) => [
    `${operation.fieldCode}\u0000${operation.subjectUid || ""}`,
    operation
  ]));
  state.editOperations = state.editOperations.filter((item) =>
    !replacements.has(`${item.fieldCode}\u0000${item.subjectUid || ""}`));
  state.editOperations.push(...replacements.values());
  state.editOperations.sort((left, right) => {
    const fieldOrder = left.fieldCode.localeCompare(right.fieldCode, "en");
    return fieldOrder !== 0
      ? fieldOrder
      : String(left.subjectUid || "").localeCompare(String(right.subjectUid || ""), "en");
  });
  invalidateEditPreview();
  renderEditOperations();
}

function addProfileOperations(operations) {
  const coordinates = new Set(state.editOperations.map((item) =>
    `${item.fieldCode}\u0000${item.subjectUid || ""}`));
  for (const operation of operations) {
    const coordinate = `${operation.fieldCode}\u0000${operation.subjectUid || ""}`;
    if (coordinates.has(coordinate)) { throw new Error("profile_edit_coordinate_duplicate"); }
    coordinates.add(coordinate);
  }
  state.editOperations.push(...operations);
  state.editOperations.sort((left, right) => {
    const fieldOrder = left.fieldCode.localeCompare(right.fieldCode, "en");
    return fieldOrder !== 0
      ? fieldOrder
      : String(left.subjectUid || "").localeCompare(String(right.subjectUid || ""), "en");
  });
  invalidateEditPreview();
  renderEditOperations();
}

function addEditOperation() {
  addProfileOperation(editOperation());
}

function profileValues(fieldCode, subjectUid) {
  return (state.currentProfile?.values || []).filter((item) =>
    item.fieldCode === fieldCode && item.subjectUid === subjectUid);
}

function effectiveProfileValue(fieldCode, subjectUid) {
  const operation = state.editOperations.find((item) =>
    item.fieldCode === fieldCode && (item.subjectUid || null) === (subjectUid || null));
  return operation || profileValues(fieldCode, subjectUid)[0] || null;
}

function queueIntegerValue(fieldCode, subjectUid, raw, minimum = 0) {
  upsertProfileOperation({
    fieldCode,
    subjectUid,
    valueKind: "integer",
    integerValue: parseCanonicalInteger(raw, "integer_value_invalid", minimum),
    booleanValue: null,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  });
}

function synchronizeCharacterLevelsToSynchro() {
  if (!state.currentProfile) return;
  const synchroLevel = parseCanonicalInteger(
    value("general-synchro"), "synchro_level_invalid", 1);
  const operations = [...new Set((state.currentProfile.values || [])
    .filter((item) => item.fieldCode === "character_level" && item.subjectUid)
    .map((item) => item.subjectUid))]
    .filter((subjectUid) =>
      effectiveProfileValue("character_level", subjectUid)?.integerValue !== synchroLevel)
    .map((subjectUid) => ({
      fieldCode: "character_level",
      subjectUid,
      valueKind: "integer",
      integerValue: synchroLevel,
      booleanValue: null,
      referenceUid: null,
      unscaledValue: null,
      decimalScale: null,
      controlledValue: null
    }));
  if (operations.length > 0) upsertProfileOperations(operations);
}

function queueReferenceValue(fieldCode, subjectUid, referenceUid) {
  upsertProfileOperation({
    fieldCode,
    subjectUid,
    valueKind: "reference",
    integerValue: null,
    booleanValue: null,
    referenceUid,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  });
}

function queueBooleanValue(fieldCode, subjectUid, booleanValue) {
  upsertProfileOperation({
    fieldCode,
    subjectUid,
    valueKind: "boolean",
    integerValue: null,
    booleanValue,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  });
}

function queueControlledValue(fieldCode, subjectUid, controlledValue) {
  upsertProfileOperation({
    fieldCode,
    subjectUid,
    valueKind: "controlled",
    integerValue: null,
    booleanValue: null,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue
  });
}

function queueExactValue(fieldCode, subjectUid, raw, scale) {
  upsertProfileOperation({
    fieldCode,
    subjectUid,
    valueKind: "exact_decimal",
    integerValue: null,
    booleanValue: null,
    referenceUid: null,
    unscaledValue: parseCanonicalInteger(raw, "exact_decimal_value_invalid", 0),
    decimalScale: scale,
    controlledValue: null
  });
}

function queueExactDecimalText(fieldCode, subjectUid, raw) {
  if (!/^\d+(?:\.\d{1,12})?$/.test(raw)) throw new Error("exact_decimal_value_invalid");
  const [whole, fraction = ""] = raw.split(".");
  queueExactValue(fieldCode, subjectUid, whole + fraction, fraction.length);
}

function renderGeneralEditor() {
  const values = state.currentProfile?.values || [];
  const synchro = values.find((item) => item.fieldCode === "synchro_level" && !item.subjectUid);
  byId("general-synchro").value = synchro?.integerValue ?? "";
  const consoles = values.filter((item) => item.fieldCode === "console_level" && item.subjectUid);
  const select = byId("general-console");
  const previousSelection = select.value;
  const groups = byId("console-card-groups");
  select.replaceChildren();
  groups.replaceChildren();
  const knownCoordinates = consoleGroups.flatMap((group) => group.coordinates);
  for (const group of [...consoleGroups, { code: "unresolved", label: "종류 미확인", coordinates: [] }]) {
    const members = consoles.filter((item) => {
      const code = state.presentationByConsole.get(item.subjectUid)?.coordinateCode;
      return group.code === "unresolved" ? !knownCoordinates.includes(code) : group.coordinates.includes(code);
    }).sort((left, right) => group.coordinates.indexOf(state.presentationByConsole.get(left.subjectUid)?.coordinateCode) -
      group.coordinates.indexOf(state.presentationByConsole.get(right.subjectUid)?.coordinateCode));
    if (!members.length) continue;
    const section = document.createElement("section");
    section.className = "console-group";
    section.dataset.consoleGroup = group.code;
    const heading = document.createElement("h4");
    heading.id = `console-group-${group.code}`;
    heading.textContent = group.label;
    section.setAttribute("aria-labelledby", heading.id);
    const grid = document.createElement("div");
    grid.className = "console-grid";
    const options = document.createElement("optgroup");
    options.label = group.label;
    for (const item of members) {
      const presentation = state.presentationByConsole.get(item.subjectUid);
      const code = presentation?.coordinateCode;
      const displayName = presentation?.displayName || (knownCoordinates.includes(code) ? consoleLabels[code] : "이름을 확인할 수 없는 콘솔");
      const option = document.createElement("option");
      option.value = item.subjectUid;
      option.textContent = displayName;
      options.appendChild(option);
      const card = document.createElement("button");
      card.type = "button";
      card.className = "console-card";
      card.dataset.consoleUid = item.subjectUid;
      card.setAttribute("aria-controls", "general-console-level general-console-experience");
      const artwork = document.createElement("span");
      artwork.className = "console-artwork";
      if (knownCoordinates.includes(code)) {
        appendPresentationImage(artwork, `/editor/assets/consoles/${code}.webp`, "console-image", "", "이미지 없음");
      } else {
        artwork.textContent = "이미지 없음";
      }
      const name = document.createElement("strong");
      name.className = "console-name";
      name.textContent = displayName;
      const level = document.createElement("span");
      level.className = "console-level";
      const selected = document.createElement("span");
      selected.className = "console-selected-mark";
      selected.textContent = "✓";
      selected.setAttribute("aria-hidden", "true");
      card.append(artwork, name, level, selected);
      card.addEventListener("click", () => {
        select.value = item.subjectUid;
        renderSelectedConsole();
      });
      grid.appendChild(card);
    }
    section.append(heading, grid);
    groups.appendChild(section);
    select.appendChild(options);
  }
  if (consoles.some((item) => item.subjectUid === previousSelection)) select.value = previousSelection;
  if (!consoles.length) {
    const empty = document.createElement("p");
    empty.className = "console-empty";
    empty.textContent = state.currentProfile ? "이 계정의 콘솔 정보가 없습니다." : "계정을 선택하면 콘솔이 표시됩니다.";
    groups.appendChild(empty);
  }
  renderSelectedConsole();
  renderCubeCards();
  byId("add-general-edits").disabled = !state.currentProfile;
}

let selectedAccountCubeUid = null;

function cubeDefinitions() {
  return (state.presentation.supportDefinitions || []).filter((item) => item.kindCode === "cube")
    .sort((left, right) => (left.displayOrder ?? 0) - (right.displayOrder ?? 0) || left.displayName.localeCompare(right.displayName, "ko"));
}

function cubeLevels(cube) {
  return (cube.levels || []).filter((entry) => Number.isInteger(entry.level) && entry.level >= 1 && entry.level <= 15)
    .sort((left, right) => left.level - right.level);
}

function accountCubeLevel(cube) {
  const stored = effectiveProfileValue("account_cube_level", cube.definitionUid)?.integerValue;
  if (Number.isInteger(stored)) return stored;
  const observed = (state.currentProfile?.values || [])
    .filter((entry) => entry.fieldCode === "cube.definition" && entry.referenceUid === cube.definitionUid)
    .map((entry) => effectiveProfileValue("cube.level", entry.subjectUid)?.integerValue)
    .filter(Number.isInteger);
  return observed.length ? Math.max(...observed) : cubeLevels(cube).at(-1)?.level;
}

function cubeEffect(cube) {
  return cubeLevels(cube).find((entry) => entry.level === accountCubeLevel(cube))?.primaryEffect || "효과 정보를 확인할 수 없습니다.";
}

function renderCubeCards() {
  const grid = byId("cube-cards");
  grid.replaceChildren();
  const cubes = state.currentProfile ? cubeDefinitions() : [];
  byId("cube-owned-count").textContent = cubes.length ? `${cubes.length}종 보유` : "";
  if (!cubes.some((cube) => cube.definitionUid === selectedAccountCubeUid)) selectedAccountCubeUid = null;
  if (!cubes.length) {
    const empty = document.createElement("p");
    empty.className = "console-empty";
    empty.textContent = state.currentProfile ? "큐브 카탈로그가 없습니다." : "계정을 선택하면 큐브가 표시됩니다.";
    grid.appendChild(empty);
  }
  for (const cube of cubes) {
    const card = document.createElement("button");
    card.type = "button";
    card.className = "cube-card";
    card.dataset.cubeUid = cube.definitionUid;
    card.setAttribute("aria-controls", "account-cube-editor");
    card.disabled = !cubeLevels(cube).length;
    const artwork = document.createElement("span");
    artwork.className = "cube-artwork";
    appendPresentationImage(artwork, cube.imagePath, "cube-image", "", "이미지 없음");
    const name = document.createElement("strong");
    name.className = "cube-name";
    name.textContent = cube.displayName;
    const level = document.createElement("span");
    level.className = "cube-level";
    const effect = document.createElement("span");
    effect.className = "cube-effect";
    card.append(artwork, name, level, effect);
    card.addEventListener("click", () => {
      selectedAccountCubeUid = cube.definitionUid;
      renderCubeCardState();
      byId("account-cube-level").focus();
    });
    grid.appendChild(card);
  }
  renderCubeCardState();
}

function renderCubeCardState() {
  const cubes = cubeDefinitions();
  for (const card of document.querySelectorAll(".cube-card")) {
    const cube = cubes.find((item) => item.definitionUid === card.dataset.cubeUid);
    if (!cube) continue;
    card.setAttribute("aria-pressed", String(cube.definitionUid === selectedAccountCubeUid));
    card.querySelector(".cube-level").textContent = `Lv. ${accountCubeLevel(cube) ?? "—"}`;
    card.querySelector(".cube-effect").textContent = cubeEffect(cube);
  }
  const cube = state.currentProfile && cubes.find((item) => item.definitionUid === selectedAccountCubeUid);
  byId("account-cube-editor").hidden = !cube;
  if (!cube) return;
  byId("account-cube-name").textContent = cube.displayName;
  byId("account-cube-effect").textContent = cubeEffect(cube);
  const select = byId("account-cube-level");
  select.replaceChildren();
  for (const entry of cubeLevels(cube)) {
    const option = document.createElement("option");
    option.value = String(entry.level);
    option.textContent = `Lv. ${entry.level}`;
    select.appendChild(option);
  }
  select.value = String(accountCubeLevel(cube));
}

function queueCubeInventory() {
  for (const cube of cubeDefinitions()) {
    const level = accountCubeLevel(cube);
    if (Number.isInteger(level) && !effectiveProfileValue("account_cube_level", cube.definitionUid)) {
      queueIntegerValue("account_cube_level", cube.definitionUid, String(level), 1);
    }
  }
}

function renderConsoleCardState() {
  const selectedUid = value("general-console");
  for (const card of document.querySelectorAll(".console-card")) {
    card.setAttribute("aria-pressed", String(card.dataset.consoleUid === selectedUid));
    const level = effectiveProfileValue("console_level", card.dataset.consoleUid)?.integerValue;
    card.querySelector(".console-level").textContent = `Lv. ${level ?? "—"}`;
  }
}

function renderSelectedConsole() {
  const subjectUid = value("general-console") || null;
  const level = effectiveProfileValue("console_level", subjectUid);
  const experience = effectiveProfileValue("console_experience", subjectUid);
  byId("general-console-level").value = level?.integerValue ?? "";
  byId("general-console-experience").value = experience?.integerValue ?? "";
  for (const id of ["general-console", "general-console-level", "general-console-experience"]) {
    byId(id).disabled = !subjectUid;
  }
  renderConsoleCardState();
}

function addGeneralEdits() {
  const subjectUid = value("general-console") || null;
  const operations = [{
    fieldCode: "synchro_level",
    subjectUid: null,
    valueKind: "integer",
    integerValue: parseCanonicalInteger(value("general-synchro"), "integer_value_invalid"),
    booleanValue: null,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  }];
  if (subjectUid) {
    for (const [fieldCode, inputId] of [
      ["console_level", "general-console-level"],
      ["console_experience", "general-console-experience"]
    ]) {
      operations.push({
        fieldCode,
        subjectUid,
        valueKind: "integer",
        integerValue: parseCanonicalInteger(value(inputId), "integer_value_invalid", 0),
        booleanValue: null,
        referenceUid: null,
        unscaledValue: null,
        decimalScale: null,
        controlledValue: null
      });
    }
  }
  addProfileOperations(operations);
}

function inferValueKind(projection) {
  if (projection.integerValue != null) return "integer";
  if (projection.booleanValue != null) return "boolean";
  if (projection.referenceUid != null) return "reference";
  if (projection.unscaledValue != null) return "exact_decimal";
  if (projection.controlledValue != null) return "controlled";
  if (projection.fieldCode.endsWith(".definition")) return "reference";
  if (projection.fieldCode.endsWith(".value")) return "exact_decimal";
  if (projection.fieldCode.endsWith(".manufacturer_matched")) return "boolean";
  return "controlled";
}

function projectionWireValue(projection) {
  const kind = inferValueKind(projection);
  if (kind === "integer") return projection.integerValue ?? "";
  if (kind === "boolean") return projection.booleanValue === null ? "" : String(projection.booleanValue);
  if (kind === "reference") return projection.referenceUid ?? "";
  if (kind === "exact_decimal") return projection.unscaledValue ?? "";
  return projection.controlledValue ?? "";
}

function renderNikkeEditor() {
  const values = state.currentProfile?.values || [];
  const ownedSubjects = new Set(values
    .filter((item) => item.fieldCode === "character_level" && item.subjectUid)
    .map((item) => item.subjectUid));
  const subjects = (state.presentation.characters || [])
    .map((item) => item.characterUid);
  const select = byId("nikke-subject");
  const prior = select.value;
  select.replaceChildren();
  for (const subjectUid of subjects) {
    const option = document.createElement("option");
    option.value = subjectUid;
    option.textContent = state.presentationByCharacter.get(subjectUid)?.displayName || "이름 미확인 니케";
    select.appendChild(option);
  }
  if (subjects.includes(prior)) select.value = prior;
  renderNikkeCards(subjects, ownedSubjects);
  renderNikkeFields();
  byId("add-nikke-edit").disabled = subjects.length === 0;
}

function renderNikkeCards(subjects = null, ownedSubjects = null) {
  const target = byId("nikke-card-list");
  const profileOwnedSubjects = ownedSubjects || new Set((state.currentProfile?.values || [])
    .filter((item) => item.fieldCode === "character_level" && item.subjectUid)
    .map((item) => item.subjectUid));
  const allSubjects = subjects || (state.presentation.characters || [])
    .map((item) => item.characterUid);
  const query = value("nikke-search").toLocaleLowerCase("ko-KR");
  const burst = value("nikke-filter-burst");
  const manufacturer = value("nikke-filter-manufacturer");
  const combatClass = value("nikke-filter-class");
  const element = value("nikke-filter-element");
  const visible = allSubjects.filter((subjectUid) => {
    const item = state.presentationByCharacter.get(subjectUid);
    const name = item?.displayName || "이름 미확인 니케";
    return (!query || name.toLocaleLowerCase("ko-KR").includes(query)) &&
      (burst === "all" || String(item?.burstStep) === burst || item?.burstStep === 5) &&
      (manufacturer === "all" || item?.manufacturerCode === manufacturer) &&
      (combatClass === "all" || item?.combatClassCode === combatClass) &&
      (element === "all" || item?.elementCode === element);
  }).sort((left, right) => {
    const leftOwned = profileOwnedSubjects.has(left);
    const rightOwned = profileOwnedSubjects.has(right);
    if (leftOwned !== rightOwned) return rightOwned ? 1 : -1;
    const leftPowerKnown = state.combatPowerByCharacter.has(left);
    const rightPowerKnown = state.combatPowerByCharacter.has(right);
    if (leftPowerKnown !== rightPowerKnown) return rightPowerKnown ? 1 : -1;
    const powerOrder = (state.combatPowerByCharacter.get(right) ?? 0) -
      (state.combatPowerByCharacter.get(left) ?? 0);
    if (powerOrder !== 0) return powerOrder;
    const leftName = state.presentationByCharacter.get(left)?.displayName || "";
    const rightName = state.presentationByCharacter.get(right)?.displayName || "";
    return leftName.localeCompare(rightName, "ko");
  });
  target.replaceChildren();
  const visibleOwnedCount = visible.filter((subjectUid) =>
    profileOwnedSubjects.has(subjectUid)).length;
  byId("nikke-count").textContent =
    `보유 ${visibleOwnedCount} / 전체 ${visible.length}`;
  for (const subjectUid of visible) {
    const item = state.presentationByCharacter.get(subjectUid) || {};
    const isOwned = profileOwnedSubjects.has(subjectUid);
    const card = document.createElement("button");
    card.type = "button";
    card.className = "nikke-card";
    card.classList.toggle("nikke-card-unowned", !isOwned);
    card.dataset.characterUid = subjectUid;
    card.dataset.owned = String(isOwned);
    card.dataset.rarity = item.rarityCode || "unknown";
    card.setAttribute("aria-current", String(state.selectedNikkeUid === subjectUid));
    const portrait = document.createElement("span");
    portrait.className = "nikke-portrait";
    appendPortrait(portrait, item.portraitPath, item.displayName, true);
    const iconRail = document.createElement("span");
    iconRail.className = "nikke-icon-rail";
    const iconDefinitions = [
      {
        kind: "element",
        label: elementLabels[item.elementCode] || "속성 미확인",
        path: elementAssetNames[item.elementCode]
          ? `${uiAssetRoot}/code-${elementAssetNames[item.elementCode]}.png`
          : null,
        fallback: elementGlyphs[item.elementCode] || "?"
      },
      {
        kind: "weapon",
        label: weaponLabels[item.weaponCode] || "무기군 미확인",
        path: weaponAssetNames[item.weaponCode]
          ? `${uiAssetRoot}/weapon-${weaponAssetNames[item.weaponCode]}.png`
          : null,
        fallback: weaponShortLabels[item.weaponCode] || "?"
      },
      {
        kind: "burst",
        label: item.burstStep ? `버스트 ${burstLabel(item.burstStep)}` : "버스트 미확인",
        path: burstAssetPath(item.burstStep),
        fallback: burstLabel(item.burstStep)
      }
    ];
    for (const icon of iconDefinitions) {
      const badge = document.createElement("span");
      badge.className = icon.kind;
      badge.title = icon.label;
      badge.setAttribute("aria-label", icon.label);
      if (icon.path) appendPresentationImage(badge, icon.path, "card-system-icon", "", icon.fallback);
      else badge.textContent = icon.fallback;
      iconRail.appendChild(badge);
    }
    portrait.appendChild(iconRail);
    if (!isOwned) {
      const unowned = document.createElement("span");
      unowned.className = "nikke-unowned-badge";
      unowned.textContent = "미보유";
      portrait.appendChild(unowned);
    }
    const body = document.createElement("span");
    body.className = "nikke-card-body";
    const identity = document.createElement("span");
    identity.className = "nikke-card-identity";
    const name = document.createElement("strong");
    name.textContent = item.displayName || "이름 미확인 니케";
    const level = isOwned ? configuredSynchroLevel() : null;
    const levelBadge = document.createElement("span");
    levelBadge.className = "nikke-level";
    const levelCaption = document.createElement("small");
    levelCaption.textContent = "LV.";
    const levelValue = document.createElement("b");
    levelValue.textContent = level == null ? "미보유" : String(level);
    levelBadge.append(levelCaption, levelValue);
    const storedLimit = effectiveProfileValue("limit_break", subjectUid)?.integerValue ?? 0;
    const core = effectiveProfileValue("core_level", subjectUid)?.integerValue ?? 0;
    const limit = core > 0 ? 3 : Math.max(0, Math.min(3, storedLimit));
    const limitStrip = document.createElement("span");
    limitStrip.className = "limit-strip";
    for (let index = 0; index < 3; index++) {
      appendPresentationImage(
        limitStrip,
        `${uiAssetRoot}/star-${index < limit ? "filled" : "empty"}.png`,
        "limit-star",
        "",
        index < limit ? "★" : "☆");
    }
    if (core >= 1) {
      const evolve = document.createElement("span");
      evolve.className = "core-evolve";
      evolve.style.backgroundImage = `url('${uiAssetRoot}/evolve.png')`;
      evolve.textContent = core >= 7 ? "MAX" : String(core);
      limitStrip.appendChild(evolve);
    }
    const job = document.createElement("img");
    job.className = "nikke-job-mark";
    job.src = `${uiAssetRoot}/job-${item.combatClassCode || "attacker"}.png`;
    job.alt = "";
    job.addEventListener("error", () => job.remove(), { once: true });
    body.appendChild(job);
    identity.append(limitStrip, name);
    body.append(levelBadge, identity);
    card.append(portrait, body);
    card.addEventListener("click", () => {
      state.selectedNikkeUid = subjectUid;
      byId("nikke-subject").value = subjectUid;
      openNikkeDetail(subjectUid);
    });
    target.appendChild(card);
  }
  if (visible.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "조건에 맞는 니케가 없습니다.";
    target.appendChild(empty);
  }
}

function openNikkeDetail(subjectUid) {
  state.selectedNikkeUid = subjectUid;
  byId("nikke-subject").value = subjectUid;
  byId("nikke-browser").hidden = true;
  byId("nikke-detail").hidden = false;
  renderNikkeDetail(subjectUid);
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function closeNikkeDetail() {
  byId("nikke-detail").hidden = true;
  byId("nikke-browser").hidden = false;
  renderNikkeCards();
}

function exactValueText(projection, unitLabel = null) {
  if (!projection || projection.unscaledValue == null) return "-";
  const scale = projection.decimalScale || 0;
  const ratioMultiplier = unitLabel === "%" ? 100 : 1;
  const fractionDigits = unitLabel === "%" ? Math.max(0, scale - 2) : scale;
  return (projection.unscaledValue / (10 ** scale) * ratioMultiplier).toLocaleString("ko-KR", {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits
  });
}

function enhancedEquipmentStatText(stat, enhancementLevel, basisPointsPerLevel) {
  const fallback = String(stat?.value ?? "미확인");
  const parsedFallback = Number(fallback.replaceAll(",", ""));
  const baseValue = Number(stat?.baseValue ?? parsedFallback);
  const level = Number(enhancementLevel);
  const rate = Number(basisPointsPerLevel);
  if (!Number.isSafeInteger(baseValue) || baseValue < 0 ||
      !Number.isSafeInteger(level) || level < 0 ||
      !Number.isSafeInteger(rate) || rate < 0) {
    return fallback;
  }
  const numerator = baseValue * (10_000 + level * rate);
  if (!Number.isSafeInteger(numerator)) return fallback;
  // All equipment stats are non-negative. Adding half the denominator before
  // integer division reproduces the client's nearest-integer rounding.
  return Math.floor((numerator + 5_000) / 10_000).toLocaleString("ko-KR");
}

function numericEditor(labelText, fieldCode, subjectUid, minimum = 0, maximum = null) {
  const label = document.createElement("label");
  label.textContent = labelText;
  const input = document.createElement("input");
  input.type = "number";
  input.min = String(minimum);
  if (maximum != null) input.max = String(maximum);
  input.value = String(effectiveProfileValue(fieldCode, subjectUid)?.integerValue ?? minimum);
  input.addEventListener("change", () => {
    queueIntegerValue(fieldCode, subjectUid, input.value, minimum);
    renderNikkeDetail(subjectUid);
  });
  label.appendChild(input);
  return label;
}

function synchronizedLevelEditor(subjectUid) {
  const label = document.createElement("label");
  label.textContent = "레벨 (싱크로 적용)";
  const input = document.createElement("input");
  input.type = "number";
  input.value = String(configuredSynchroLevel());
  input.disabled = true;
  label.appendChild(input);
  return label;
}

function limitBreakEditor(subjectUid) {
  const group = document.createElement("div");
  group.className = "growth-visual-field limit-break-editor";
  const label = document.createElement("span");
  label.textContent = "돌파";
  const stars = document.createElement("div");
  stars.className = "growth-stars";
  const current = effectiveProfileValue("limit_break", subjectUid)?.integerValue ?? 0;
  const currentCore = effectiveProfileValue("core_level", subjectUid)?.integerValue ?? 0;
  for (let index = 1; index <= 3; index++) {
    const button = document.createElement("button");
    button.type = "button";
    button.title = `${index}돌파`;
    button.setAttribute("aria-pressed", String(index <= current));
    appendPresentationImage(
      button,
      `${uiAssetRoot}/star-${index <= current ? "filled" : "empty"}.png`,
      "growth-star-image",
      `${index}번째 돌파`,
      index <= current ? "★" : "☆");
    button.addEventListener("click", () => {
      const nextLimit = index === current && currentCore === 0 ? 0 : index;
      upsertProfileOperations([
        {
          fieldCode: "limit_break", subjectUid, valueKind: "integer",
          integerValue: nextLimit, booleanValue: null, referenceUid: null,
          unscaledValue: null, decimalScale: null, controlledValue: null
        },
        {
          fieldCode: "core_level", subjectUid, valueKind: "integer",
          integerValue: 0, booleanValue: null, referenceUid: null,
          unscaledValue: null, decimalScale: null, controlledValue: null
        }
      ]);
      renderNikkeDetail(subjectUid);
    });
    stars.appendChild(button);
  }
  group.append(label, stars);
  return group;
}

function coreBreakEditor(subjectUid) {
  const group = document.createElement("div");
  group.className = "growth-visual-field core-break-editor";
  const label = document.createElement("span");
  label.textContent = "코어 강화";
  const control = document.createElement("div");
  control.className = "core-stepper";
  const currentLimit = Math.max(0, Math.min(3,
    effectiveProfileValue("limit_break", subjectUid)?.integerValue ?? 0));
  const currentCore = Math.max(0, Math.min(7,
    effectiveProfileValue("core_level", subjectUid)?.integerValue ?? 0));
  const currentProgress = Math.min(10,
    currentCore > 0 ? 3 + currentCore : currentLimit);
  const badge = document.createElement("span");
  badge.className = "core-evolve detail-core-evolve";
  badge.style.backgroundImage = `url('${uiAssetRoot}/evolve.png')`;
  badge.textContent = currentCore >= 7 ? "MAX" : String(currentCore);
  for (const [caption, delta] of [["−", -1], ["+", 1]]) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = caption;
    button.disabled = delta < 0 ? currentProgress <= 0 : currentProgress >= 10;
    button.addEventListener("click", () => {
      const nextProgress = Math.max(0, Math.min(10, currentProgress + delta));
      const nextLimit = Math.min(3, nextProgress);
      const nextCore = Math.max(0, nextProgress - 3);
      upsertProfileOperations([
        {
          fieldCode: "limit_break", subjectUid, valueKind: "integer",
          integerValue: nextLimit, booleanValue: null, referenceUid: null,
          unscaledValue: null, decimalScale: null, controlledValue: null
        },
        {
          fieldCode: "core_level", subjectUid, valueKind: "integer",
          integerValue: nextCore, booleanValue: null, referenceUid: null,
          unscaledValue: null, decimalScale: null, controlledValue: null
        }
      ]);
      renderNikkeDetail(subjectUid);
    });
    control.appendChild(button);
    if (delta < 0) control.appendChild(badge);
  }
  group.append(label, control);
  return group;
}

function renderNikkeDetail(subjectUid) {
  const presentation = state.presentationByCharacter.get(subjectUid) || {};
  byId("nikke-selected-name").textContent = presentation.displayName || "이름 미확인 니케";
  byId("nikke-selected-tags").textContent = [
    presentation.rarityCode?.toUpperCase(),
    presentation.burstStep ? `버스트 ${burstLabel(presentation.burstStep)}` : null,
    manufacturerLabels[presentation.manufacturerCode],
    classLabels[presentation.combatClassCode],
    elementLabels[presentation.elementCode],
    weaponLabels[presentation.weaponCode]
  ].filter(Boolean).join(" · ");
  const observedPower = state.combatPowerByCharacter.get(subjectUid);
  byId("nikke-detail-power").textContent = observedPower == null
    ? "미확인"
    : observedPower.toLocaleString("ko-KR");
  const portrait = byId("selected-nikke-portrait");
  portrait.replaceChildren();
  appendPortrait(portrait, presentation.portraitPath, presentation.displayName);

  const growth = byId("nikke-core-panel");
  growth.replaceChildren();
  growth.append(
    synchronizedLevelEditor(subjectUid),
    numericEditor("호감도", "bond_level", subjectUid, 0),
    limitBreakEditor(subjectUid),
    coreBreakEditor(subjectUid));
  renderEquipmentDetail(subjectUid);
  renderSkillDetail(subjectUid);
  renderCollectionDetail(subjectUid, presentation);
  renderNikkeFields();
}

function renderEquipmentDetail(subjectUid) {
  const summary = byId("equipment-summary");
  summary.replaceChildren();
  const title = document.createElement("strong");
  title.className = "equipment-summary-title";
  title.textContent = "장비 효과 보기";
  const totalGrid = document.createElement("div");
  totalGrid.className = "equipment-total-grid";
  const totals = collectEquipmentOverloadTotals(subjectUid);
  for (const total of totals) {
    const row = document.createElement("div");
    row.className = "equipment-total-row";
    const label = document.createElement("span");
    label.textContent = `[${total.displayName}]`;
    const amount = document.createElement("strong");
    amount.textContent = total.value.toLocaleString("ko-KR", {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    }) + total.unitLabel;
    row.append(label, amount);
    totalGrid.appendChild(row);
  }
  if (totals.length === 0) {
    const empty = document.createElement("p");
    empty.className = "equipment-total-empty";
    empty.textContent = "설정된 오버로드 옵션이 없습니다.";
    totalGrid.appendChild(empty);
  }
  summary.append(title, totalGrid);
  const list = byId("equipment-list");
  list.replaceChildren();
  for (const slot of ["head", "torso", "arms", "legs"]) {
    const prefix = `equipment.${slot}`;
    const definition = effectiveProfileValue(`${prefix}.definition`, subjectUid);
    const support = state.presentationBySupport.get(definition?.referenceUid) || {};
    const enhancementLevel = Number(
      effectiveProfileValue(`${prefix}.enhancement_level`, subjectUid)?.integerValue ?? 0);
    const card = document.createElement("article");
    card.className = "equipment-card surface";
    const header = document.createElement("div");
    header.className = "equipment-card-header";
    const icon = document.createElement("button");
    icon.type = "button";
    icon.className = "equipment-icon";
    icon.title = `${equipmentSlotLabels[slot]} 장비 변경`;
    icon.setAttribute("aria-label", `${equipmentSlotLabels[slot]} 장비 변경`);
    if (support.imagePath) {
      appendPresentationImage(
        icon, support.imagePath, "equipment-image", support.displayName || "",
        equipmentSlotLabels[slot].slice(0, 1));
    } else {
      icon.textContent = equipmentSlotLabels[slot].slice(0, 1);
    }
    if (support.tier) {
      const tierBadge = document.createElement("span");
      tierBadge.className = "equipment-tier-badge";
      tierBadge.textContent = `T${support.tier}`;
      icon.appendChild(tierBadge);
    }
    const heading = document.createElement("div");
    heading.className = "equipment-stat-panel";
    const name = document.createElement("strong");
    name.textContent = support.displayName || `${equipmentSlotLabels[slot]} 장비`;
    const statTitle = document.createElement("span");
    statTitle.className = "equipment-column-title";
    statTitle.textContent = "장비 능력치";
    const statRows = document.createElement("div");
    statRows.className = "equipment-stat-rows";
    const supportStats = (support.stats || [])
      .filter((item) => item.label !== "능력치" || item.value !== "0");
    for (const item of supportStats) {
      const statRow = document.createElement("div");
      const statLabel = document.createElement("span");
      statLabel.textContent = item.label;
      const statValue = document.createElement("strong");
      statValue.textContent = enhancedEquipmentStatText(
        item,
        enhancementLevel,
        support.enhancementStatIncreaseBasisPointsPerLevel ?? 1_000);
      statRow.append(statLabel, statValue);
      statRows.appendChild(statRow);
    }
    if (supportStats.length === 0) {
      const missing = document.createElement("span");
      missing.textContent = "능력치 미확인";
      statRows.appendChild(missing);
    }
    heading.append(name, statTitle, statRows);
    const enhancement = numericEditor(
      "강화",
      `${prefix}.enhancement_level`,
      subjectUid,
      0,
      support.maximumEnhancementLevel ?? 5);
    enhancement.className = "equipment-enhancement";
    enhancement.querySelector("input").disabled = !definition;
    header.append(icon, heading, enhancement);
    const optionList = document.createElement("div");
    optionList.className = "overload-list";
    const effectTitle = document.createElement("strong");
    effectTitle.className = "equipment-column-title overload-column-title";
    effectTitle.textContent = "장비 효과";
    const effectNotice = document.createElement("small");
    effectNotice.className = "equipment-effect-notice";
    effectNotice.textContent = "효과의 수치는 전투 진입 시 적용됩니다.";
    optionList.append(effectTitle, effectNotice);
    for (let line = 1; line <= 3; line++) {
      const linePrefix = `${prefix}.overload.${line}`;
      const optionState = effectiveProfileValue(`${linePrefix}.state`, subjectUid)?.controlledValue;
      const optionDefinition = optionState === "absent"
        ? null
        : effectiveProfileValue(`${linePrefix}.definition`, subjectUid);
      const optionValue = optionState === "absent"
        ? null
        : effectiveProfileValue(`${linePrefix}.value`, subjectUid);
      const option = state.presentationByOverload.get(optionDefinition?.referenceUid) || {};
      const row = document.createElement("div");
      row.className = `overload-row ${overloadTierClass(optionValue, option)}`;
      const optionName = document.createElement("select");
      optionName.setAttribute("aria-label", `오버로드 옵션 ${line}`);
      const empty = document.createElement("option");
      empty.value = "";
      empty.textContent = "옵션 없음";
      optionName.appendChild(empty);
      for (const candidate of state.presentation.overloadOptions || []) {
        const choice = document.createElement("option");
        choice.value = candidate.definitionUid;
        choice.textContent = candidate.displayName;
        optionName.appendChild(choice);
      }
      optionName.value = optionDefinition?.referenceUid || "";
      optionName.addEventListener("change", () => {
        if (!optionName.value) {
          for (const suffix of ["definition", "unit", "value"]) {
            const index = state.editOperations.findIndex((item) =>
              item.fieldCode === `${linePrefix}.${suffix}` && item.subjectUid === subjectUid);
            if (index >= 0) state.editOperations.splice(index, 1);
          }
          queueControlledValue(`${linePrefix}.state`, subjectUid, "absent");
          renderEditOperations();
          renderNikkeDetail(subjectUid);
          return;
        }
        const selected = state.presentationByOverload.get(optionName.value);
        const initialValue = selected?.legalValues?.[0];
        if (!initialValue) throw new Error("overload_legal_value_missing");
        queueControlledValue(`${linePrefix}.state`, subjectUid, "present");
        queueReferenceValue(`${linePrefix}.definition`, subjectUid, optionName.value);
        // Overload values are stored as normalized ratios. The percent sign is
        // presentation-only and exactValueText applies the display conversion.
        queueControlledValue(`${linePrefix}.unit`, subjectUid, "ratio");
        queueExactValue(`${linePrefix}.value`, subjectUid,
          String(initialValue.unscaledValue), initialValue.decimalScale);
        renderNikkeDetail(subjectUid);
      });
      const shown = document.createElement("label");
      shown.textContent = option.unitLabel || "%";
      const input = document.createElement("select");
      input.setAttribute("aria-label", `오버로드 옵션 ${line} 수치`);
      for (const legalValue of option.legalValues || []) {
        const choice = document.createElement("option");
        choice.value = `${legalValue.unscaledValue}:${legalValue.decimalScale}`;
        choice.textContent = exactValueText(legalValue, option.unitLabel || "%");
        input.appendChild(choice);
      }
      input.value = optionValue
        ? `${optionValue.unscaledValue}:${optionValue.decimalScale || 0}`
        : "";
      input.disabled = !optionDefinition;
      input.addEventListener("change", () => {
        const [unscaledValue, decimalScale] = input.value.split(":");
        queueExactValue(`${linePrefix}.value`, subjectUid, unscaledValue, Number(decimalScale));
        renderNikkeDetail(subjectUid);
      });
      shown.prepend(input);
      row.append(optionName, shown);
      optionList.appendChild(row);
    }
    const picker = document.createElement("div");
    picker.className = "equipment-picker";
    picker.hidden = true;
    const pickerTitle = document.createElement("strong");
    pickerTitle.textContent = `${equipmentSlotLabels[slot]} 장비 선택`;
    const pickerChoices = document.createElement("div");
    pickerChoices.className = "equipment-picker-choices";
    const character = state.presentationByCharacter.get(subjectUid) || {};
    const candidates = (state.presentation.supportDefinitions || [])
      .filter((item) => item.kindCode === "equipment" &&
        item.slotCode === slot &&
        item.combatClassCode === character.combatClassCode &&
        [9, 10].includes(item.tier))
      .sort((left, right) => left.tier - right.tier);
    for (const candidate of candidates) {
      const choice = document.createElement("button");
      choice.type = "button";
      choice.className = "equipment-picker-choice";
      choice.classList.toggle("selected", candidate.definitionUid === definition?.referenceUid);
      choice.setAttribute("aria-pressed",
        String(candidate.definitionUid === definition?.referenceUid));
      const choiceIcon = document.createElement("span");
      choiceIcon.className = "equipment-picker-icon";
      appendPresentationImage(
        choiceIcon, candidate.imagePath, "equipment-picker-image",
        candidate.displayName || "", `T${candidate.tier}`);
      const choiceCopy = document.createElement("span");
      const choiceTier = document.createElement("b");
      choiceTier.textContent = `${candidate.tier}티어`;
      const choiceName = document.createElement("small");
      choiceName.textContent = candidate.displayName;
      choiceCopy.append(choiceTier, choiceName);
      choice.append(choiceIcon, choiceCopy);
      choice.addEventListener("click", () => {
        const currentEnhancement = Number(
          effectiveProfileValue(`${prefix}.enhancement_level`, subjectUid)?.integerValue ?? 0);
        const equipmentSelectionOperations = [
          {
            fieldCode: `${prefix}.state`, subjectUid, valueKind: "controlled",
            integerValue: null, booleanValue: null, referenceUid: null,
            unscaledValue: null, decimalScale: null, controlledValue: "equipped"
          },
          {
            fieldCode: `${prefix}.definition`, subjectUid, valueKind: "reference",
            integerValue: null, booleanValue: null, referenceUid: candidate.definitionUid,
            unscaledValue: null, decimalScale: null, controlledValue: null
          },
          {
            fieldCode: `${prefix}.enhancement_level`, subjectUid, valueKind: "integer",
            integerValue: currentEnhancement, booleanValue: null, referenceUid: null,
            unscaledValue: null, decimalScale: null, controlledValue: null
          },
          candidate.tier === 10
            ? {
              fieldCode: `${prefix}.manufacturer_matched`, subjectUid,
              valueKind: "controlled", integerValue: null, booleanValue: null,
              referenceUid: null, unscaledValue: null, decimalScale: null,
              controlledValue: "not_applicable"
            }
            : {
              fieldCode: `${prefix}.manufacturer_matched`, subjectUid,
              valueKind: "boolean", integerValue: null, booleanValue: false,
              referenceUid: null, unscaledValue: null, decimalScale: null,
              controlledValue: null
            }
        ];
        if (candidate.tier === 9) {
          for (let line = 1; line <= 3; line++) {
            equipmentSelectionOperations.push({
              fieldCode: `${prefix}.overload.${line}.state`, subjectUid,
              valueKind: "controlled", integerValue: null, booleanValue: null,
              referenceUid: null, unscaledValue: null, decimalScale: null,
              controlledValue: "absent"
            });
          }
        }
        // A definition without state/enhancement is not a legal equipment shape
        // when the source slot was empty. Queue the complete selection atomically.
        upsertProfileOperations(equipmentSelectionOperations);
        renderNikkeDetail(subjectUid);
      });
      pickerChoices.appendChild(choice);
    }
    if (candidates.length === 0) {
      const missing = document.createElement("span");
      missing.className = "equipment-picker-missing";
      missing.textContent = "선택 가능한 9·10티어 장비 정보가 없습니다.";
      pickerChoices.appendChild(missing);
    }
    picker.append(pickerTitle, pickerChoices);
    icon.addEventListener("click", () => {
      picker.hidden = !picker.hidden;
      icon.setAttribute("aria-expanded", String(!picker.hidden));
    });
    icon.setAttribute("aria-expanded", "false");
    card.append(header, optionList, picker);
    list.appendChild(card);
  }
}

function overloadTierClass(valueProjection, option) {
  const level = overloadLevel(valueProjection, option);
  return level === 0 ? "overload-tier-normal" : `overload-level-${level}`;
}

function overloadLevel(valueProjection, option) {
  if (!valueProjection || !Array.isArray(option.legalValues) || option.legalValues.length === 0) {
    return 0;
  }
  const legal = [...option.legalValues].sort((left, right) =>
    (left.unscaledValue / (10 ** (left.decimalScale || 0))) -
    (right.unscaledValue / (10 ** (right.decimalScale || 0))));
  const ordinal = legal.findIndex((item) =>
    item.unscaledValue === valueProjection.unscaledValue &&
    (item.decimalScale || 0) === (valueProjection.decimalScale || 0));
  return ordinal < 0 ? 0 : ordinal + 1;
}

function collectEquipmentOverloadTotals(subjectUid) {
  const totals = new Map();
  for (const slot of ["head", "torso", "arms", "legs"]) {
    for (let line = 1; line <= 3; line++) {
      const prefix = `equipment.${slot}.overload.${line}`;
      if (effectiveProfileValue(`${prefix}.state`, subjectUid)?.controlledValue === "absent") continue;
      const definition = effectiveProfileValue(`${prefix}.definition`, subjectUid);
      const projection = effectiveProfileValue(`${prefix}.value`, subjectUid);
      const option = state.presentationByOverload.get(definition?.referenceUid);
      if (!option || projection?.unscaledValue == null) continue;
      const scale = projection.decimalScale || 0;
      const multiplier = option.unitLabel === "%" ? 100 : 1;
      const value = projection.unscaledValue / (10 ** scale) * multiplier;
      const key = option.definitionUid || option.displayName;
      const current = totals.get(key) || {
        displayName: option.displayName || "오버로드 옵션",
        unitLabel: option.unitLabel || "%",
        value: 0
      };
      current.value += value;
      totals.set(key, current);
    }
  }
  return [...totals.values()];
}

function renderSkillDetail(subjectUid) {
  const target = byId("skill-editor");
  target.replaceChildren();
  for (const [fieldCode, label] of [
    ["skill_1_level", "스킬 1"], ["skill_2_level", "스킬 2"], ["burst_level", "버스트 스킬"]
  ]) {
    const card = numericEditor(label, fieldCode, subjectUid, 1);
    card.className = "skill-card surface";
    target.appendChild(card);
  }
}

function srCollectionLevel15Stats(weaponCode) {
  const srCollections = (state.presentation.supportDefinitions || []).filter((item) =>
    item.kindCode === "collection" && item.rarityCode === "sr" &&
    item.weaponCode === weaponCode);
  if (srCollections.length !== 1) return [];
  return (srCollections[0].levels || [])
    .find((item) => item.level === 15)?.stats || [];
}

function renderCollectionDetail(subjectUid, presentation) {
  const target = byId("collection-editor");
  target.replaceChildren();
  const kind = effectiveProfileValue("collection.kind", subjectUid)?.controlledValue || "none";
  const definition = effectiveProfileValue("collection.definition", subjectUid);
  const support = state.presentationBySupport.get(definition?.referenceUid) || {};
  const header = document.createElement("div");
  header.className = "collection-header";
  const icon = document.createElement("span");
  icon.className = "collection-icon";
  if (support.imagePath) {
    appendPresentationImage(
      icon, support.imagePath, "collection-image", support.displayName || "",
      weaponLabels[presentation.weaponCode]?.slice(0, 1) || "소");
  } else {
    icon.textContent = weaponLabels[presentation.weaponCode]?.slice(0, 1) || "소";
  }
  const copy = document.createElement("div");
  const title = document.createElement("h3");
  title.textContent = support.displayName || (kind === "favorite" ? "애장품" : "SR 소장품");
  const description = document.createElement("p");
  description.textContent = kind === "favorite"
    ? `${presentation.displayName || "선택 니케"} 전용 애장품`
    : `${weaponLabels[presentation.weaponCode] || "무기군"} 전용 소장품`;
  copy.append(title, description);
  const phase = document.createElement("div");
  phase.className = "collection-phase";
  const currentCollectionLevel = effectiveProfileValue("collection.level", subjectUid)?.integerValue ?? 0;
  const phaseGrade = document.createElement("strong");
  phaseGrade.textContent = kind === "favorite" ? "애장품" : "SR";
  const phaseLevel = document.createElement("span");
  phaseLevel.textContent = `Phase ${currentCollectionLevel}`;
  phase.append(phaseGrade, phaseLevel);
  const phaseStars = document.createElement("span");
  phaseStars.className = "collection-phase-stars";
  for (let index = 0; index < 3; index++) {
    appendPresentationImage(
      phaseStars, `${uiAssetRoot}/star-filled.png`, "collection-star", "", "★");
  }
  phase.appendChild(phaseStars);
  copy.appendChild(phase);
  header.append(icon, copy);
  const selector = document.createElement("label");
  selector.textContent = "소장품 종류";
  const collectionSelect = document.createElement("select");
  for (const candidate of (state.presentation.supportDefinitions || []).filter((item) =>
    (item.kindCode === "collection" &&
      (!item.weaponCode || item.weaponCode === presentation.weaponCode)) ||
    (item.kindCode === "favorite" && item.favoriteCharacterUid === subjectUid))) {
    const option = document.createElement("option");
    option.value = candidate.definitionUid;
    option.textContent = candidate.displayName;
    collectionSelect.appendChild(option);
  }
  collectionSelect.value = definition?.referenceUid || "";
  collectionSelect.addEventListener("change", () => {
    const selected = state.presentationBySupport.get(collectionSelect.value);
    const selectedKind = selected?.kindCode === "favorite"
      ? "favorite"
      : "generic_collection";
    const selectedMaximumLevel = selectedKind === "favorite"
      ? Math.max(0, ...(selected?.levels || []).map((item) => item.level))
      : 15;
    const selectedLevel = Math.min(
      effectiveProfileValue("collection.level", subjectUid)?.integerValue ?? 0,
      selectedMaximumLevel || 0);
    // Detached collections have no stored level. Definition, kind and level must
    // therefore be submitted together to form one legal selected collection.
    upsertProfileOperations([
      {
        fieldCode: "collection.definition", subjectUid, valueKind: "reference",
        integerValue: null, booleanValue: null, referenceUid: collectionSelect.value,
        unscaledValue: null, decimalScale: null, controlledValue: null
      },
      {
        fieldCode: "collection.kind", subjectUid, valueKind: "controlled",
        integerValue: null, booleanValue: null, referenceUid: null,
        unscaledValue: null, decimalScale: null, controlledValue: selectedKind
      },
      {
        fieldCode: "collection.level", subjectUid, valueKind: "integer",
        integerValue: selectedLevel, booleanValue: null, referenceUid: null,
        unscaledValue: null, decimalScale: null, controlledValue: null
      }
    ]);
    renderNikkeDetail(subjectUid);
  });
  selector.appendChild(collectionSelect);
  const maximumLevel = kind === "favorite"
    ? Math.max(0, ...(support.levels || []).map((item) => item.level))
    : 15;
  const level = numericEditor("소장품 레벨", "collection.level", subjectUid, 0,
    maximumLevel || null);
  level.className = "collection-level";
  level.querySelector("input").disabled = !definition;
  const currentLevel = currentCollectionLevel;
  const favoriteBaseStats = kind === "favorite"
    ? srCollectionLevel15Stats(presentation.weaponCode)
    : [];
  const currentStats = favoriteBaseStats.length ? favoriteBaseStats : (support.levels || [])
    .filter((item) => item.level <= currentLevel)
    .sort((left, right) => right.level - left.level)[0]?.stats || [];
  const stats = document.createElement("div");
  stats.className = "collection-stats";
  stats.textContent = currentStats.length
    ? currentStats.map((item) => `${item.label} ${item.value}`).join(" · ")
    : "능력치 정보 없음";
  target.append(header, selector, level, stats);
}

function renderNikkeFields() {
  const subjectUid = value("nikke-subject") || null;
  const fields = (state.currentProfile?.values || [])
    .filter((item) => item.subjectUid === subjectUid)
    .sort((left, right) => left.fieldCode.localeCompare(right.fieldCode, "en"));
  const select = byId("nikke-field");
  const prior = select.value;
  select.replaceChildren();
  for (const field of fields) {
    const option = document.createElement("option");
    option.value = field.fieldCode;
    option.textContent = displayField(field.fieldCode);
    select.appendChild(option);
  }
  if (fields.some((item) => item.fieldCode === prior)) select.value = prior;
  renderNikkeValue();
  const presentation = state.presentationByCharacter.get(subjectUid);
  byId("nikke-selected-name").textContent = presentation?.displayName || "이름 미확인 니케";
  byId("nikke-selected-tags").textContent = [
    presentation?.rarityCode?.toUpperCase(),
    presentation?.burstStep ? `버스트 ${burstLabel(presentation.burstStep)}` : null,
    manufacturerLabels[presentation?.manufacturerCode], classLabels[presentation?.combatClassCode],
    weaponLabels[presentation?.weaponCode]
  ].filter(Boolean).join(" · ") || "세부 정보 확인 중";
  const portrait = byId("selected-nikke-portrait");
  portrait.replaceChildren();
  appendPortrait(portrait, presentation?.portraitPath, presentation?.displayName);
  const summary = byId("nikke-output");
  summary.replaceChildren();
  for (const field of fields.filter((item) => [
    "character_level", "limit_break", "core_level", "bond_level",
    "skill_1_level", "skill_2_level", "burst_level"
  ].includes(item.fieldCode))) {
    const row = document.createElement("div");
    const label = document.createElement("span");
    const shown = document.createElement("strong");
    label.textContent = displayField(field.fieldCode);
    shown.textContent = String(projectionWireValue(
      effectiveProfileValue(field.fieldCode, subjectUid) || field));
    row.append(label, shown);
    summary.appendChild(row);
  }
}

function selectedNikkeProjection() {
  const subjectUid = value("nikke-subject") || null;
  const fieldCode = value("nikke-field");
  return (state.currentProfile?.values || []).find((item) =>
    item.subjectUid === subjectUid && item.fieldCode === fieldCode) || null;
}

function renderNikkeValue() {
  const projection = selectedNikkeProjection();
  byId("nikke-value").value = projection ? projectionWireValue(projection) : "";
  byId("nikke-scale").value = projection?.decimalScale ?? 0;
}

function addNikkeEdit() {
  const projection = selectedNikkeProjection();
  if (!projection) throw new Error("profile_edit_subject_not_found");
  const kind = inferValueKind(projection);
  const raw = value("nikke-value");
  const operation = {
    fieldCode: projection.fieldCode,
    subjectUid: projection.subjectUid,
    valueKind: kind,
    integerValue: null,
    booleanValue: null,
    referenceUid: null,
    unscaledValue: null,
    decimalScale: null,
    controlledValue: null
  };
  if (kind === "integer") operation.integerValue = parseCanonicalInteger(raw, "integer_value_invalid");
  if (kind === "boolean") {
    if (raw !== "true" && raw !== "false") throw new Error("boolean_value_invalid");
    operation.booleanValue = raw === "true";
  }
  if (kind === "reference") operation.referenceUid = raw;
  if (kind === "exact_decimal") {
    operation.unscaledValue = parseCanonicalInteger(raw, "exact_decimal_value_invalid");
    operation.decimalScale = parseCanonicalInteger(value("nikke-scale"), "decimal_scale_invalid", 0);
  }
  if (kind === "controlled") operation.controlledValue = raw;
  addProfileOperation(operation);
}

function clearEditOperations() {
  state.editOperations = [];
  invalidateEditPreview();
  renderEditOperations();
  synchronizeCharacterLevelsToSynchro();
  renderNikkeCards();
}

async function previewEdit() {
  const result = await api(
    `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/profile/preview`,
    {
      method: "POST",
      headers: withIfMatch(state.profileRevisionUid),
      body: { operationUid: stableOperationUid("edit-preview"), operations: state.editOperations }
    });
  state.candidateDraftUid = result.payload.candidateDraftUid;
  state.candidateSha256 = result.payload.candidateSha256;
  state.editDiffSha256 = result.payload.diffSha256;
  byId("save-profile").disabled = false;
  byId("save-as-profile").disabled = false;
  showJson("profile-output", result.payload);
}

async function saveProfile(saveAs) {
  const suffix = saveAs ? "save-as" : "profile";
  const method = saveAs ? "POST" : "PUT";
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/${suffix}`, {
    method,
    headers: withIfMatch(state.profileRevisionUid),
    body: {
      operationUid: stableOperationUid(saveAs ? "edit-save-as" : "edit-save"),
      candidateDraftUid: state.candidateDraftUid,
      candidateSha256: state.candidateSha256,
      expectedDiffSha256: state.editDiffSha256,
      accountLabel: saveAs ? value("save-as-label") : undefined
    }
  });
  clearOperationUids(saveAs ? "edit-save-as" : "edit-save");
  if (!saveAs) {
    state.profileRevisionUid = result.etag;
    invalidateImportPreview();
  } else {
    byId("account-uid").value = result.payload.accountUid;
    byId("save-as-label").value = "";
    await listAccounts();
    await loadAccount();
  }
  showJson("profile-output", result.payload);
  clearEditOperations();
}

function renderObservations(observations) {
  const body = byId("observation-body");
  body.replaceChildren();
  const rows = new Map();
  for (const observation of observations || []) {
    if (!rows.has(observation.characterUid)) { rows.set(observation.characterUid, {}); }
    rows.get(observation.characterUid)[observation.observationKind] = observation;
  }
  for (const [characterUid, pair] of rows) {
    const row = document.createElement("tr");
    for (const text of [
      characterUid,
      pair["roster_observation/v1"]?.observedValue ?? pair["roster_observation/v1"]?.status ?? "—",
      pair["detail_observation/v1"]?.observedValue ?? pair["detail_observation/v1"]?.status ?? "—"
    ]) {
      const cell = document.createElement("td");
      cell.textContent = String(text);
      row.appendChild(cell);
    }
    body.appendChild(row);
  }
}

async function loadDraft() {
  state.importDraftUid = value("draft-uid");
  const result = await api(`/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}`);
  if (result.payload.contractId !== "nll/sanitized-profile-draft/v1") {
    throw new Error("draft_contract_invalid");
  }
  state.importDraftSha256 = result.payload.draftSha256;
  state.importDiffSha256 = null;
  state.createImportDiffSha256 = null;
  state.rebaseDiffSha256 = null;
  state.reviewDiffSha256 = null;
  clearOperationUids(
    "import-preview", "import-apply", "import-create-preview", "import-create",
    "rebase-preview", "rebase-apply", "review-preview", "review-apply");
  renderObservations(result.payload.observations);
  showJson("import-output", result.payload);
  byId("preview-import").disabled = !state.accountUid || !state.profileRevisionUid;
  byId("preview-create-import").disabled = false;
  byId("preview-rebase").disabled = false;
  byId("preview-review").disabled = false;
  byId("apply-import").disabled = true;
  byId("create-from-import").disabled = true;
  byId("apply-rebase").disabled = true;
  byId("apply-review").disabled = true;
}

function reviewedOverrides() {
  let parsed;
  try { parsed = JSON.parse(value("review-overrides")); }
  catch { throw new Error("review_override_json_invalid"); }
  if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > 512) {
    throw new Error("review_override_set_invalid");
  }
  const seen = new Set();
  return parsed.map((item) => {
    const keys = item && typeof item === "object" && !Array.isArray(item)
      ? Object.keys(item).sort().join(",")
      : "";
    if (keys !== "booleanValue,characterUid,equipmentSlot,integerValue,kind,reasonCode" ||
        typeof item.characterUid !== "string" ||
        !["user_reviewed_override", "original_client_verified_override"].includes(item.reasonCode)) {
      throw new Error("review_override_set_invalid");
    }
    if (item.kind === "bond_level") {
      if (item.equipmentSlot !== null || item.booleanValue !== null ||
          !Number.isSafeInteger(item.integerValue)) {
        throw new Error("review_override_value_invalid");
      }
    } else if (item.kind === "equipment_manufacturer_matched") {
      if (!["head", "torso", "arms", "legs"].includes(item.equipmentSlot) ||
          item.integerValue !== null || typeof item.booleanValue !== "boolean") {
        throw new Error("review_override_value_invalid");
      }
    } else {
      throw new Error("review_override_kind_invalid");
    }
    const coordinate = `${item.kind}:${item.characterUid}:${item.equipmentSlot || ""}`;
    if (seen.has(coordinate)) { throw new Error("review_override_coordinate_duplicate"); }
    seen.add(coordinate);
    return item;
  });
}

function reviewRequest(expectedDiffSha256, operationKey) {
  return {
    operationUid: stableOperationUid(operationKey),
    expectedDraftSha256: state.importDraftSha256,
    overrides: reviewedOverrides(),
    expectedDiffSha256
  };
}

async function previewReview() {
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/review/preview`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: reviewRequest(null, "review-preview")
    });
  state.reviewDiffSha256 = result.payload.diffSha256;
  byId("apply-review").disabled = false;
  showJson("import-output", result.payload);
}

async function applyReview() {
  if (!state.reviewDiffSha256) { throw new Error("review_preview_required"); }
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/review`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: reviewRequest(state.reviewDiffSha256, "review-apply")
    });
  clearOperationUids("review-apply");
  state.importDraftUid = result.payload.draftUid;
  state.importDraftSha256 = result.payload.draftSha256;
  state.reviewDiffSha256 = null;
  state.rebaseDiffSha256 = null;
  state.importDiffSha256 = null;
  state.createImportDiffSha256 = null;
  byId("draft-uid").value = state.importDraftUid;
  byId("apply-review").disabled = true;
  byId("apply-rebase").disabled = true;
  byId("apply-import").disabled = true;
  byId("create-from-import").disabled = true;
  clearOperationUids(
    "review-preview", "rebase-preview", "rebase-apply", "import-preview", "import-apply",
    "import-create-preview", "import-create");
  renderObservations(result.payload.observations);
  showJson("import-output", result.payload);
}

function rebaseMappings() {
  let parsed;
  try { parsed = JSON.parse(value("rebase-mappings")); }
  catch { throw new Error("rebase_mapping_json_invalid"); }
  if (!Array.isArray(parsed) || parsed.length > 4096) {
    throw new Error("rebase_mapping_set_invalid");
  }
  const seen = new Set();
  return parsed.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item) ||
        Object.keys(item).sort().join(",") !== "fromUid,toUid" ||
        typeof item.fromUid !== "string" || typeof item.toUid !== "string" ||
        seen.has(item.fromUid)) {
      throw new Error("rebase_mapping_set_invalid");
    }
    seen.add(item.fromUid);
    return { fromUid: item.fromUid, toUid: item.toUid };
  });
}

function rebaseRequest(expectedDiffSha256, operationKey) {
  return {
    operationUid: stableOperationUid(operationKey),
    expectedDraftSha256: state.importDraftSha256,
    targetCharacterCatalog: {
      catalogSnapshotUid: value("rebase-character-catalog"),
      datasetSnapshotUid: value("rebase-character-dataset"),
      manifestSha256: value("rebase-character-manifest")
    },
    targetCombatSupportCatalog: {
      catalogSnapshotUid: value("rebase-support-catalog"),
      datasetSnapshotUid: value("rebase-support-dataset"),
      manifestSha256: value("rebase-support-manifest")
    },
    explicitMappings: rebaseMappings(),
    expectedDiffSha256
  };
}

async function previewRebase() {
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/rebase/preview`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: rebaseRequest(null, "rebase-preview")
    });
  state.rebaseDiffSha256 = result.payload.diffSha256;
  byId("apply-rebase").disabled = false;
  showJson("import-output", result.payload);
}

async function applyRebase() {
  if (!state.rebaseDiffSha256) { throw new Error("rebase_preview_required"); }
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/rebase`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: rebaseRequest(state.rebaseDiffSha256, "rebase-apply")
    });
  clearOperationUids("rebase-apply");
  state.importDraftUid = result.payload.draftUid;
  state.importDraftSha256 = result.payload.draftSha256;
  invalidateRebasePreview();
  invalidateImportPreview();
  invalidateReviewPreview();
  byId("draft-uid").value = state.importDraftUid;
  clearOperationUids(
    "rebase-preview", "import-preview", "import-apply",
    "import-create-preview", "import-create");
  renderObservations(result.payload.observations);
  showJson("import-output", result.payload);
}

async function previewImport() {
  const result = await api(`/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/diff`, {
    method: "POST",
    headers: withIfMatch(state.profileRevisionUid),
    body: {
      operationUid: stableOperationUid("import-preview"),
      expectedDraftSha256: state.importDraftSha256,
      targetAccountUid: state.accountUid,
      levelAuthorityPolicy: value("level-authority"),
      scopes: [value("import-scope")]
    }
  });
  state.importDiffSha256 = result.payload.diffSha256;
  byId("apply-import").disabled = importLevelAuthorityRequired() &&
    value("level-authority") === "unresolved/no_apply";
  showJson("import-output", result.payload);
}

function importLevelAuthorityRequired() {
  return value("import-scope") !== "account_state_only";
}

async function applyImport() {
  if (importLevelAuthorityRequired() && value("level-authority") === "unresolved/no_apply") {
    throw new Error("level_authority_required");
  }
  const result = await api(`/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/apply`, {
    method: "POST",
    headers: withIfMatch(state.profileRevisionUid),
    body: {
      operationUid: stableOperationUid("import-apply"),
      expectedDraftSha256: state.importDraftSha256,
      targetAccountUid: state.accountUid,
      expectedDiffSha256: state.importDiffSha256,
      levelAuthorityPolicy: value("level-authority"),
      scopes: [value("import-scope")]
    }
  });
  clearOperationUids("import-apply");
  state.profileRevisionUid = result.etag;
  invalidateImportPreview();
  clearEditOperations();
  showJson("import-output", result.payload);
}

async function previewCreateFromImport() {
  if (value("level-authority") === "unresolved/no_apply") {
    throw new Error("level_authority_required");
  }
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/create/preview`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: {
        operationUid: stableOperationUid("import-create-preview"),
        expectedDraftSha256: state.importDraftSha256,
        levelAuthorityPolicy: value("level-authority"),
        scopes: ["full_profile"]
      }
    });
  state.createImportDiffSha256 = result.payload.diffSha256;
  byId("create-from-import").disabled = false;
  showJson("import-output", result.payload);
}

async function createFromImport() {
  if (!state.createImportDiffSha256) { throw new Error("create_import_preview_required"); }
  if (value("level-authority") === "unresolved/no_apply") {
    throw new Error("level_authority_required");
  }
  const result = await api(
    `/admin-api/v1/import-drafts/${encodeURIComponent(state.importDraftUid)}/create`,
    {
      method: "POST",
      headers: withIfMatch(state.importDraftUid),
      body: {
        operationUid: stableOperationUid("import-create"),
        expectedDraftSha256: state.importDraftSha256,
        expectedDiffSha256: state.createImportDiffSha256,
        levelAuthorityPolicy: value("level-authority"),
        scopes: ["full_profile"]
      }
    });
  clearOperationUids("import-create");
  state.accountUid = result.payload.accountUid;
  state.profileRevisionUid = result.etag;
  byId("account-uid").value = state.accountUid;
  state.createImportDiffSha256 = null;
  byId("create-from-import").disabled = true;
  await loadAccount();
  showJson("import-output", result.payload);
}

async function loadLocalState() {
  state.lobbyRevisionUid = null;
  state.walletRevisionUid = null;
  byId("save-lobby").disabled = true;
  byId("save-wallet").disabled = true;
  const lobby = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/lobby`);
  const wallet = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/wallet`);
  state.lobbyRevisionUid = lobby.etag;
  state.walletRevisionUid = wallet.etag;
  state.accountLobbyByUid.set(state.accountUid, lobby.payload);
  clearOperationUids("local-state-initialize", "lobby-save", "wallet-save");
  state.lobbySelections = {
    profileIconSelectionUid: lobby.payload.profileIconSelectionUid ?? null,
    profileFrameSelectionUid: lobby.payload.profileFrameSelectionUid ?? null,
    lobbyCharacterSelectionUid: lobby.payload.lobbyCharacterSelectionUid ?? null,
    lobbyBackgroundSelectionUid: lobby.payload.lobbyBackgroundSelectionUid ?? null
  };
  byId("display-name").value = lobby.payload.displayName;
  byId("commander-level").value = String(lobby.payload.commanderLevel);
  const balances = new Map(
    (wallet.payload.balances || []).map((balance) => [
      balance.currencyCode,
      requireSafeWireBalance(balance.balance)
    ]));
  if (!balances.has("jewel") || !balances.has("credit") || balances.size !== 2) {
    throw new Error("wallet_balance_set_invalid");
  }
  byId("jewel-balance").value = String(balances.get("jewel"));
  byId("credit-balance").value = String(balances.get("credit"));
  showJson("local-state-output", { lobby: lobby.payload, wallet: wallet.payload });
  byId("save-lobby").disabled = false;
  byId("save-wallet").disabled = false;
  byId("preview-fetched-lobby").disabled = !state.fetchedSnapshotUid;
  renderAccountSummary();
  renderAccounts();
}

function selectedFetchedLobbyFields() {
  const fields = [];
  if (byId("fetched-lobby-commander").checked) { fields.push("commander_level"); }
  if (byId("fetched-lobby-display-name").checked) { fields.push("display_name"); }
  if (fields.length === 0) { throw new Error("fetched_lobby_field_set_invalid"); }
  return fields;
}

function invalidateFetchedLobbyPreview() {
  state.fetchedLobbyDiffSha256 = null;
  byId("apply-fetched-lobby").disabled = true;
  clearOperationUids("fetched-lobby-preview", "fetched-lobby-apply");
}

async function previewFetchedLobby() {
  if (!state.fetchedSnapshotUid) { throw new Error("fetched_snapshot_not_registered"); }
  const result = await api(
    `/admin-api/v1/fetched-snapshots/${encodeURIComponent(state.fetchedSnapshotUid)}/lobby/diff`,
    {
      method: "POST",
      headers: withIfMatch(state.lobbyRevisionUid),
      body: {
        operationUid: stableOperationUid("fetched-lobby-preview"),
        targetAccountUid: state.accountUid,
        fields: selectedFetchedLobbyFields()
      }
    });
  state.fetchedLobbyDiffSha256 = result.payload.diffSha256;
  byId("apply-fetched-lobby").disabled = result.payload.changes.length === 0;
  showJson("local-state-output", { fetchedLobbyDiff: result.payload });
}

async function applyFetchedLobby() {
  if (!state.fetchedLobbyDiffSha256) { throw new Error("fetched_lobby_preview_required"); }
  const result = await api(
    `/admin-api/v1/fetched-snapshots/${encodeURIComponent(state.fetchedSnapshotUid)}/lobby/apply`,
    {
      method: "POST",
      headers: withIfMatch(state.lobbyRevisionUid),
      body: {
        operationUid: stableOperationUid("fetched-lobby-apply"),
        targetAccountUid: state.accountUid,
        expectedDiffSha256: state.fetchedLobbyDiffSha256,
        fields: selectedFetchedLobbyFields()
      }
    });
  state.lobbyRevisionUid = result.etag;
  state.fetchedLobbyDiffSha256 = null;
  clearOperationUids("fetched-lobby-preview", "fetched-lobby-apply", "lobby-save");
  byId("display-name").value = result.payload.lobby.displayName;
  byId("commander-level").value = String(result.payload.lobby.commanderLevel);
  state.accountLobbyByUid.set(state.accountUid, result.payload.lobby);
  byId("apply-fetched-lobby").disabled = true;
  renderAccountSummary();
  renderAccounts();
  showJson("local-state-output", result.payload);
}

async function saveLobby() {
  if (!state.lobbySelections) { throw new Error("lobby_presentation_not_loaded"); }
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/lobby`, {
    method: "PUT",
    headers: withIfMatch(state.lobbyRevisionUid),
    body: {
      operationUid: stableOperationUid("lobby-save"),
      displayName: value("display-name"),
      commanderLevel: parseCanonicalInteger(value("commander-level"), "commander_level_invalid", 1),
      ...state.lobbySelections
    }
  });
  clearOperationUids("lobby-save");
  state.lobbyRevisionUid = result.etag;
  state.accountLobbyByUid.set(state.accountUid, result.payload);
  renderAccountSummary();
  renderAccounts();
  showJson("local-state-output", result.payload);
}

async function saveWallet() {
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/wallet`, {
    method: "PUT",
    headers: withIfMatch(state.walletRevisionUid),
    body: {
      operationUid: stableOperationUid("wallet-save"),
      balances: [
        {
          currencyCode: "jewel",
          balance: parseCanonicalInteger(value("jewel-balance"), "wallet_balance_invalid", 0)
        },
        {
          currencyCode: "credit",
          balance: parseCanonicalInteger(value("credit-balance"), "wallet_balance_invalid", 0)
        }
      ]
    }
  });
  clearOperationUids("wallet-save");
  state.walletRevisionUid = result.etag;
  showJson("local-state-output", result.payload);
}

function queueAccountProfileEdits() {
  queueCubeInventory();
  const synchro = effectiveProfileValue("synchro_level", null)?.integerValue;
  const synchroInput = parseCanonicalInteger(value("general-synchro"), "integer_value_invalid", 1);
  if (synchro !== synchroInput) queueIntegerValue("synchro_level", null, String(synchroInput), 1);
  synchronizeCharacterLevelsToSynchro();
  const consoleUid = value("general-console") || null;
  if (!consoleUid) return;
  for (const [fieldCode, inputId] of [
    ["console_level", "general-console-level"],
    ["console_experience", "general-console-experience"]
  ]) {
    const next = parseCanonicalInteger(value(inputId), "integer_value_invalid", 0);
    const current = effectiveProfileValue(fieldCode, consoleUid)?.integerValue;
    if (current !== next) queueIntegerValue(fieldCode, consoleUid, String(next), 0);
  }
}

async function refreshWorkspaceSaveRecovery() {
  const accountUid = state.accountUid;
  if (!accountUid) return;
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(accountUid)}/workspace/saves`);
  state.workspaceSaveRecovery.set(accountUid, result.payload);
  renderWorkspaceSaveRecovery();
}

function renderWorkspaceSaveRecovery() {
  const panel = byId("workspace-save-recovery");
  const list = byId("workspace-save-recovery-list");
  list.replaceChildren();
  const attempt = state.workspaceSaveAttempts.get(state.accountUid);
  const rows = state.workspaceSaveRecovery.get(state.accountUid) || [];
  const pending = rows.filter(item => item.statusCode === "pending");
  panel.hidden = !state.workspaceSaveBusy && !attempt && pending.length === 0;
  byId("workspace-save-recovery-message").textContent = state.workspaceSaveBusy
    ? "저장 처리 중입니다. 응답이 끊겨도 원래 요청으로 복구할 수 있습니다."
    : attempt || pending.length
      ? "미완료 저장이 있습니다. 새 편집 전에 원래 요청을 이어서 저장하세요. 새 preview나 최신값 덮어쓰기는 하지 않습니다."
      : "최근 저장은 완료됐습니다. 응답을 받지 못했더라도 중복 저장할 필요가 없습니다.";
  for (const tab of document.querySelectorAll(".tab-panel")) {
    tab.inert = state.workspaceSaveBusy || (Boolean(attempt || pending.length) && tab.dataset.tabPanel !== "home");
  }
  if (attempt) {
    const button = document.createElement("button");
    button.type = "button"; button.textContent = "원래 요청 다시 전송";
    button.disabled = state.workspaceSaveBusy;
    button.addEventListener("click", () => run("저장 복구", () => saveEverything(attempt.saveAs)));
    list.appendChild(button);
  }
  for (const item of rows) {
    if (attempt?.options.body.operationUid === item.operationUid) continue;
    const row = document.createElement("div");
    const text = document.createElement("p");
    text.textContent = `${item.saveAs ? "Save As" : "Save"} · ${item.createdAtUtc} · ${item.statusCode === "completed" ? "완료" : "미완료"}`;
    row.appendChild(text);
    if (item.recoveryCode === "exact_request_available") {
      const button = document.createElement("button");
      button.type = "button"; button.textContent = "원래 요청 이어서 저장";
      button.disabled = state.workspaceSaveBusy;
      button.addEventListener("click", () => run("저장 복구", () => resumeWorkspaceSave(item)));
      row.appendChild(button);
    } else if (item.statusCode === "pending") {
      const note = document.createElement("p");
      note.textContent = item.recoveryCode === "original_request_required"
        ? "이전 버전 저장: 원래 요청이 없어 자동 복구할 수 없습니다. 기록을 보존한 채 별도 점검이 필요합니다."
        : "저장 요청의 무결성을 확인할 수 없습니다. 자동 복구하지 않습니다.";
      row.appendChild(note);
    } else if (item.completedReceipt) {
      const button = document.createElement("button");
      button.type = "button"; button.textContent = "완료 기록 확인";
      button.addEventListener("click", () => { showJson("account-output", item.completedReceipt); setPage("advanced"); });
      row.appendChild(button);
    }
    list.appendChild(row);
  }
}

async function finishWorkspaceSave(receipt) {
  state.workspaceSaveAttempts.delete(receipt.sourceAccountUid || state.accountUid);
  clearOperationUids("workspace-save", "workspace-save-as", "edit-preview");
  byId("account-uid").value = receipt.accountUid;
  byId("save-as-label").value = "";
  state.editOperations = [];
  invalidateEditPreview();
  await listAccounts();
  await loadAccount();
  showJson("account-output", receipt);
}

async function resumeWorkspaceSave(item) {
  if (state.workspaceSaveBusy) throw new Error("account_workspace_save_in_progress");
  if (item.recoveryCode !== "exact_request_available") throw new Error("account_workspace_save_original_request_required");
  state.workspaceSaveBusy = true;
  renderWorkspaceSaveRecovery();
  try {
    const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(item.sourceAccountUid)}/workspace/saves/resume`, {
      method: "POST", headers: withIfMatch(item.requestSha256), body: { operationUid: item.operationUid }
    });
    await finishWorkspaceSave(result.payload);
  } finally {
    state.workspaceSaveBusy = false;
    await refreshWorkspaceSaveRecovery().catch(() => {});
    renderWorkspaceSaveRecovery();
  }
}

async function saveEverything(saveAs) {
  if (!state.currentWorkspace) throw new Error("account_not_loaded");
  if (state.workspaceSaveBusy) throw new Error("account_workspace_save_in_progress");
  let attempt = state.workspaceSaveAttempts.get(state.accountUid);
  if (attempt && attempt.saveAs !== saveAs) throw new Error("account_workspace_save_pending");
  // Disable editing before the first await, including during preview.
  state.workspaceSaveBusy = true;
  renderWorkspaceSaveRecovery();
  try {
    if (!attempt) {
      await refreshWorkspaceSaveRecovery();
      if ((state.workspaceSaveRecovery.get(state.accountUid) || []).some(item => item.statusCode === "pending"))
        throw new Error("account_workspace_save_pending");
      queueAccountProfileEdits();
      if (saveAs) {
        const requested = window.prompt("새 저장본 이름을 입력하세요.", `${value("account-label")} 복사본`);
        if (requested === null) return;
        byId("save-as-label").value = requested.trim();
        if (!value("save-as-label")) throw new Error("account_label_invalid");
      }
      await previewEdit();
      const operationKey = saveAs ? "workspace-save-as" : "workspace-save";
      const request = {
        expectedProfileRevisionUid: state.profileRevisionUid,
        expectedLobbyRevisionUid: state.lobbyRevisionUid,
        expectedWalletRevisionUid: state.walletRevisionUid,
        candidateDraftUid: state.candidateDraftUid,
        candidateSha256: state.candidateSha256,
        expectedDiffSha256: state.editDiffSha256,
        expectedAccountLabel: state.currentWorkspace.accountLabel,
        accountLabel: saveAs ? value("save-as-label") : value("account-label"),
        displayName: value("display-name"),
        commanderLevel: parseCanonicalInteger(
          value("commander-level"), "commander_level_invalid", 1),
        ...state.lobbySelections,
        balances: [
          {
            currencyCode: "jewel",
            balance: parseCanonicalInteger(value("jewel-balance"), "wallet_balance_invalid", 0)
          },
          {
            currencyCode: "credit",
            balance: parseCanonicalInteger(value("credit-balance"), "wallet_balance_invalid", 0)
          }
        ]
      };
      attempt = {
        saveAs, accountUid: state.accountUid,
        path: `/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/workspace${saveAs ? "/save-as" : ""}`,
        options: {
          method: saveAs ? "POST" : "PUT",
          headers: withIfMatch(state.currentWorkspace.baseRevisions.revisionSetSha256),
          body: {
            operationUid: operationUidForRequest(operationKey, request),
            ...request
          }
        }
      };
      state.workspaceSaveAttempts.set(attempt.accountUid, attempt);
    }
    const result = await api(attempt.path, attempt.options);
    await finishWorkspaceSave(result.payload);
  } catch (error) {
    // A definite 4xx before claim must not strand an editable account. An unknown
    // outcome retains the exact in-memory request; accepted writes also live in DB.
    if (attempt && error.status >= 400 && error.status < 500) {
      const refreshed = await refreshWorkspaceSaveRecovery().then(() => true, () => false);
      const rows = state.workspaceSaveRecovery.get(attempt.accountUid);
      if (refreshed && rows && !rows.some(item => item.operationUid === attempt.options.body.operationUid) &&
          !["account_workspace_save_in_progress", "account_workspace_save_pending"].includes(error.message)) {
        state.workspaceSaveAttempts.delete(attempt.accountUid);
      }
    }
    throw error;
  } finally {
    state.workspaceSaveBusy = false;
    renderWorkspaceSaveRecovery();
  }
}

async function importAccountByUid() {
  const uid = value("account-import-uid");
  if (!/^\d{4,32}$/.test(uid)) throw new Error("account_import_uid_invalid");
  const button = byId("fetch-account-by-uid");
  const status = byId("account-import-status");
  button.disabled = true;
  status.className = "import-status running";
  status.textContent = "브라우저 수집과 계정 가공을 진행 중입니다. 로그인 창이 뜨면 완료해 주세요.";
  try {
    const result = await api("/admin-api/v1/account-imports", {
      method: "POST",
      body: { uid }
    });
    status.className = "import-status complete";
    status.textContent = `${result.payload.displayName} · 니케 ${result.payload.characterCount}명 가져오기 완료`;
    byId("account-import-uid").value = "";
    await listAccounts();
    byId("account-uid").value = result.payload.accountUid;
    await loadAccount();
    setPage("home");
  } finally {
    button.disabled = false;
  }
}

async function initializeLocalState() {
  if (!state.featureManifest) { throw new Error("feature_manifest_not_loaded"); }
  const result = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/local-state`, {
    method: "POST",
    headers: withIfMatch(state.profileRevisionUid),
    body: {
      operationUid: stableOperationUid("local-state-initialize"),
      featureManifestUid: state.featureManifest.manifestUid,
      expectedFeatureManifestSha256: state.featureManifest.contentSha256,
      displayName: value("display-name"),
      commanderLevel: parseCanonicalInteger(value("commander-level"), "commander_level_invalid", 1),
      profileIconSelectionUid: null,
      profileFrameSelectionUid: null,
      lobbyCharacterSelectionUid: null,
      lobbyBackgroundSelectionUid: null,
      balances: [
        {
          currencyCode: "jewel",
          balance: parseCanonicalInteger(value("jewel-balance"), "wallet_balance_invalid", 0)
        },
        {
          currencyCode: "credit",
          balance: parseCanonicalInteger(value("credit-balance"), "wallet_balance_invalid", 0)
        }
      ]
    }
  });
  clearOperationUids("local-state-initialize");
  state.lobbyRevisionUid = result.payload.lobby.revision.revisionUid;
  state.walletRevisionUid = result.payload.wallet.revision.revisionUid;
  state.lobbySelections = {
    profileIconSelectionUid: result.payload.lobby.profileIconSelectionUid ?? null,
    profileFrameSelectionUid: result.payload.lobby.profileFrameSelectionUid ?? null,
    lobbyCharacterSelectionUid: result.payload.lobby.lobbyCharacterSelectionUid ?? null,
    lobbyBackgroundSelectionUid: result.payload.lobby.lobbyBackgroundSelectionUid ?? null
  };
  byId("save-lobby").disabled = false;
  byId("save-wallet").disabled = false;
  byId("initialize-local-state").disabled = true;
  state.accountLobbyByUid.set(state.accountUid, result.payload.lobby);
  renderAccountSummary();
  renderAccounts();
  showJson("local-state-output", result.payload);
}

byId("load-account").addEventListener("click", () => run("Account load", loadAccount));
byId("refresh-accounts").addEventListener("click", () => run("Account list", listAccounts));
byId("rename-account").addEventListener("click", () => run("Account rename", renameAccount));
byId("load-revisions").addEventListener(
  "click", () => run("Revision history", loadRevisionHistory));
byId("export-runtime").addEventListener(
  "click", () => run("Runtime candidate", exportRuntimeCandidate));
byId("register-fetched-snapshot").addEventListener(
  "click", () => run("Fetched snapshot register", registerFetchedSnapshot));
byId("load-bootstrap").addEventListener("click", () => run("Bootstrap load", loadBootstrap));
byId("launch-game").addEventListener("click", () => run("Solo Raid launch", startLaunch));
byId("refresh-launch").addEventListener("click", () => run("Launch status", refreshLaunch));
byId("load-launch-history").addEventListener(
  "click", () => run("Launch history", loadLaunchHistory));
byId("admin-login").addEventListener("click", () => run("Admin session", startAdminSession));
byId("load-features").addEventListener("click", () => run("Feature load", async () => {
  const result = await api("/admin-api/v1/client-feature-manifest");
  state.featureManifest = result.payload;
  byId("initialize-local-state").disabled = !state.accountUid || !state.profileRevisionUid;
  showJson("account-output", result.payload);
}));
byId("add-edit").addEventListener("click", () => run("Edit add", async () => addEditOperation()));
byId("clear-edits").addEventListener("click", () => run("Edit clear", async () => clearEditOperations()));
byId("preview-edit").addEventListener("click", () => run("Edit preview", previewEdit));
byId("save-profile").addEventListener("click", () => run("Save", () => saveProfile(false)));
byId("save-as-profile").addEventListener("click", () => run("Save As", () => saveEverything(true)));
byId("save-everything").addEventListener(
  "click", () => run("계정 저장", () => saveEverything(false)));
byId("save-as-everything").addEventListener(
  "click", () => run("다른 이름으로 저장", () => saveEverything(true)));
byId("nikke-save-as").addEventListener(
  "click", () => run("다른 이름으로 저장", () => saveEverything(true)));
byId("nikke-save-everything").addEventListener(
  "click", () => run("니케 저장", () => saveEverything(false)));
byId("fetch-account-by-uid").addEventListener(
  "click", () => run("계정 정보 가져오기", importAccountByUid));
byId("general-console").addEventListener("change", renderSelectedConsole);
byId("account-cube-level").addEventListener("change", () => {
  if (!state.currentProfile || !selectedAccountCubeUid) return;
  queueIntegerValue("account_cube_level", selectedAccountCubeUid, value("account-cube-level"), 1);
});
byId("general-synchro").addEventListener("change", () => {
  if (!state.currentProfile) return;
  queueIntegerValue("synchro_level", null, value("general-synchro"), 1);
  synchronizeCharacterLevelsToSynchro();
  renderNikkeCards();
  if (state.selectedNikkeUid && !byId("nikke-detail").hidden) {
    renderNikkeDetail(state.selectedNikkeUid);
  }
});
for (const [id, fieldCode] of [
  ["general-console-level", "console_level"],
  ["general-console-experience", "console_experience"]
]) {
  byId(id).addEventListener("change", () => {
    const subjectUid = value("general-console") || null;
    if (subjectUid) queueIntegerValue(fieldCode, subjectUid, value(id), 0);
  });
}
byId("add-general-edits").addEventListener(
  "click", () => run("General edit add", async () => addGeneralEdits()));
byId("nikke-subject").addEventListener("change", renderNikkeFields);
byId("nikke-field").addEventListener("change", renderNikkeValue);
for (const id of [
  "nikke-search", "nikke-filter-burst", "nikke-filter-manufacturer",
  "nikke-filter-class", "nikke-filter-element"
]) {
  byId(id).addEventListener(id === "nikke-search" ? "input" : "change", () => renderNikkeCards());
}
for (const button of document.querySelectorAll("[data-filter-select]")) {
  button.addEventListener("click", () => {
    const selectId = button.dataset.filterSelect;
    const select = byId(selectId);
    select.value = button.dataset.filterValue;
    for (const candidate of document.querySelectorAll("[data-filter-select]")) {
      if (candidate.dataset.filterSelect === selectId) {
        candidate.setAttribute("aria-pressed", String(candidate === button));
      }
    }
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
}
byId("nikke-detail-back").addEventListener("click", closeNikkeDetail);
for (const button of document.querySelectorAll("[data-detail-tab]")) {
  button.addEventListener("click", () => {
    for (const candidate of document.querySelectorAll("[data-detail-tab]")) {
      candidate.setAttribute("aria-selected", String(candidate === button));
    }
    for (const pane of document.querySelectorAll("[data-detail-pane]")) {
      pane.hidden = pane.dataset.detailPane !== button.dataset.detailTab;
    }
  });
}
byId("add-nikke-edit").addEventListener(
  "click", () => run("Nikke edit add", async () => addNikkeEdit()));
byId("load-draft").addEventListener("click", () => run("Draft load", loadDraft));
byId("preview-import").addEventListener("click", () => run("Import diff", previewImport));
byId("apply-import").addEventListener("click", () => run("Import apply", applyImport));
byId("preview-create-import").addEventListener(
  "click", () => run("Import create preview", previewCreateFromImport));
byId("create-from-import").addEventListener(
  "click", () => run("Local profile create", createFromImport));
byId("preview-rebase").addEventListener("click", () => run("Rebase preview", previewRebase));
byId("apply-rebase").addEventListener("click", () => run("Rebase", applyRebase));
byId("preview-review").addEventListener("click", () => run("Override preview", previewReview));
byId("apply-review").addEventListener("click", () => run("Override apply", applyReview));
function invalidateImportPreview() {
  state.importDiffSha256 = null;
  state.createImportDiffSha256 = null;
  byId("apply-import").disabled = true;
  byId("create-from-import").disabled = true;
  clearOperationUids(
    "import-preview", "import-apply", "import-create-preview", "import-create");
}
function invalidateRebasePreview() {
  state.rebaseDiffSha256 = null;
  byId("apply-rebase").disabled = true;
  clearOperationUids("rebase-preview", "rebase-apply");
}
function invalidateReviewPreview() {
  state.reviewDiffSha256 = null;
  byId("apply-review").disabled = true;
  clearOperationUids("review-preview", "review-apply");
}
byId("level-authority").addEventListener("change", invalidateImportPreview);
byId("import-scope").addEventListener("change", invalidateImportPreview);
for (const id of [
  "rebase-character-catalog", "rebase-character-dataset", "rebase-character-manifest",
  "rebase-support-catalog", "rebase-support-dataset", "rebase-support-manifest", "rebase-mappings"
]) {
  byId(id).addEventListener("input", invalidateRebasePreview);
}
byId("review-overrides").addEventListener("input", invalidateReviewPreview);
byId("save-as-label").addEventListener("input", () => clearOperationUids("edit-save-as"));
for (const button of document.querySelectorAll(".tab-button")) {
  button.addEventListener("click", () => setPage(button.dataset.tab));
}
for (const button of document.querySelectorAll(".jump-button")) {
  button.addEventListener("click", () => setPage(button.dataset.jump));
}
for (const button of document.querySelectorAll(".raid-action")) {
  button.addEventListener("click", () => {
    byId("launch-season").value = button.dataset.season;
    byId("launch-kind").value = button.dataset.kind;
    run(button.dataset.kind === "practice" ? "모의전 실행" : "실전 실행", startLaunch);
  });
}
const bossSeasons = NllBossSeasons.create({ document, api,
  onSelected: row => {
    state.selectedBossSeason = row.seasonNumber;
    bossSeasonLabels[row.seasonNumber] = row.displayName || "선택 보스";
    const option = document.createElement("option");
    option.value = String(row.seasonNumber);
    option.textContent = `시즌 ${row.seasonNumber} · ${bossSeasonLabels[row.seasonNumber]}`;
    byId("launch-season").replaceChildren(option);
    selectWeaknessCode(row.defaultWeaknessCode);
  },
  onUnavailable: () => {
    ++state.preparationRequestNumber;
    state.preparationController?.abort();
    state.launchPreparation = { statusCode: "blocked", failureCode: "phase_d_boss_catalog_unavailable" };
    updateRaidActions();
  }
});
for (const button of document.querySelectorAll(".weakness-option")) {
  const icon = button.querySelector("img");
  icon?.addEventListener("error", () => { icon.hidden = true; });
  button.addEventListener("click", () => selectWeaknessCode(button.dataset.weaknessCode));
}
byId("selected-boss-launch").addEventListener(
  "click", () => run("솔로 레이드 실행", startLaunch));
byId("launch-season").addEventListener("change", () => selectRaidBoss(Number(value("launch-season"))));
for (const id of ["display-name", "commander-level"])
{
  byId(id).addEventListener("input", () =>
    clearOperationUids("local-state-initialize", "lobby-save"));
}
for (const id of ["jewel-balance", "credit-balance"])
{
  byId(id).addEventListener("input", () =>
    clearOperationUids("local-state-initialize", "wallet-save"));
}
byId("load-local-state").addEventListener("click", () => run("Local state load", loadLocalState));
byId("initialize-local-state").addEventListener("click", () => run("Local state initialize", initializeLocalState));
byId("save-lobby").addEventListener("click", () => run("Lobby save", saveLobby));
byId("save-wallet").addEventListener("click", () => run("Wallet save", saveWallet));
byId("preview-fetched-lobby").addEventListener(
  "click", () => run("Fetched lobby diff", previewFetchedLobby));
byId("apply-fetched-lobby").addEventListener(
  "click", () => run("Fetched lobby apply", applyFetchedLobby));
for (const id of ["fetched-lobby-commander", "fetched-lobby-display-name"])
{
  byId(id).addEventListener("change", invalidateFetchedLobbyPreview);
}

showStatus("독립 실행 프로그램을 준비하는 중입니다.");
