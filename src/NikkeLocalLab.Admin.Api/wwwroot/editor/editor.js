"use strict";

const byId = (id) => document.getElementById(id);
const state = {
  csrf: null,
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
  lobbyRevisionUid: null,
  walletRevisionUid: null,
  lobbySelections: null,
  featureManifest: null,
  operationUids: Object.create(null)
};

function showStatus(message) { byId("status").textContent = message; }
function showJson(target, value) { byId(target).textContent = JSON.stringify(value, null, 2); }
function value(id) { return byId(id).value.trim(); }
function stableOperationUid(key) {
  state.operationUids[key] ||= crypto.randomUUID();
  return state.operationUids[key];
}
function clearOperationUids(...keys) {
  for (const key of keys) { delete state.operationUids[key]; }
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
    throw new Error(payload.code || "request_failed");
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
    cache: "no-store"
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

async function loadAccount() {
  state.accountUid = value("account-uid");
  state.editOperations = [];
  invalidateEditPreview();
  invalidateImportPreview();
  invalidateRebasePreview();
  renderEditOperations();
  clearOperationUids("local-state-initialize", "lobby-save", "wallet-save");
  const profile = await api(`/admin-api/v1/accounts/${encodeURIComponent(state.accountUid)}/profile`);
  state.currentProfile = profile.payload;
  state.profileRevisionUid = profile.etag;
  const character = profile.payload.characterCatalog;
  const support = profile.payload.combatSupportCatalog;
  byId("rebase-character-catalog").value = character.catalogSnapshotUid;
  byId("rebase-character-dataset").value = character.datasetSnapshotUid;
  byId("rebase-character-manifest").value = character.manifestSha256;
  byId("rebase-support-catalog").value = support.catalogSnapshotUid;
  byId("rebase-support-dataset").value = support.datasetSnapshotUid;
  byId("rebase-support-manifest").value = support.manifestSha256;
  showJson("account-output", profile.payload);
  byId("add-edit").disabled = false;
  byId("clear-edits").disabled = false;
  byId("preview-edit").disabled = false;
  byId("load-bootstrap").disabled = false;
  byId("load-local-state").disabled = false;
  byId("initialize-local-state").disabled = !state.featureManifest;
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
}

function addEditOperation() {
  const operation = editOperation();
  const duplicate = state.editOperations.some((item) =>
    item.fieldCode === operation.fieldCode && item.subjectUid === operation.subjectUid);
  if (duplicate) { throw new Error("profile_edit_coordinate_duplicate"); }
  state.editOperations.push(operation);
  state.editOperations.sort((left, right) => {
    const fieldOrder = left.fieldCode.localeCompare(right.fieldCode, "en");
    return fieldOrder !== 0
      ? fieldOrder
      : String(left.subjectUid || "").localeCompare(String(right.subjectUid || ""), "en");
  });
  invalidateEditPreview();
  renderEditOperations();
}

function clearEditOperations() {
  state.editOperations = [];
  invalidateEditPreview();
  renderEditOperations();
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
      expectedDiffSha256: state.editDiffSha256
    }
  });
  clearOperationUids(saveAs ? "edit-save-as" : "edit-save");
  if (!saveAs) {
    state.profileRevisionUid = result.etag;
    invalidateImportPreview();
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
  showJson("local-state-output", result.payload);
}

byId("load-account").addEventListener("click", () => run("Account load", loadAccount));
byId("load-bootstrap").addEventListener("click", () => run("Bootstrap load", loadBootstrap));
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
byId("save-as-profile").addEventListener("click", () => run("Save As", () => saveProfile(true)));
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

showStatus("One-time bootstrap code를 입력하세요.");
