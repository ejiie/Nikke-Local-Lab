"use strict";
// This panel launches only on an explicit user click. Reads/selection/polling
// never trigger UAC, imports, recovery or an original-client process.
const NllUserValidation = (() => {
  const labels = { prepared: "정밀 검사 경로 준비 완료", awaiting_user_approval: "관리자 권한 승인 대기",
    quick_check: "빠른 실행 조건 확인 중", deep_check: "파일·저장소 정밀 검사 중", preparing: "격리·실행 환경 준비 중",
    bootstrap_check: "서버·부트스트랩 정밀 검사 중",
    game_start: "게임 시작 준비 중", running: "게임 프로세스 실행 중", cleanup: "실행 종료·원복 중",
    finished: "검증 실행 종료 · 원복 완료", cleanup_required: "원복 필요 · 다음 실행 차단",
    failed: "검증 실행 실패", uac_cancelled: "관리자 권한 요청 취소", status_unknown: "실행 상태 확인 필요", blocked: "검증 준비 확인 필요" };
  const active = status => ["awaiting_user_approval", "quick_check", "deep_check", "bootstrap_check", "preparing", "game_start", "running", "cleanup", "status_unknown"].includes(status);
  function create({ document, api, getSelection, uid = () => crypto.randomUUID(),
    schedule = (fn, ms) => setTimeout(fn, ms), cancel = id => clearTimeout(id) }) {
    const byId = id => document.getElementById(id);
    let revision = 0, delivery = null, action = null, timer = null, pending = false;
    const operations = new Map();
    const key = selection => `${selection.seasonNumber}:${selection.weaknessCode}`;
    function render() {
      const selection = getSelection();
      byId("boss-user-validation").hidden = !selection.validationOnly;
      if (!selection.validationOnly) return;
      const valid = delivery?.statusCode === "awaiting_game_validation" && delivery.seasonNumber === selection.seasonNumber &&
        action?.seasonNumber === selection.seasonNumber && action.weaknessCode === selection.weaknessCode;
      const status = valid ? action.statusCode : "blocked";
      byId("user-validation-status").textContent = pending ? "사용자 실행 요청 중…" : labels[status] || labels.blocked;
      if (!pending && valid && action.progress) {
        const p = action.progress;
        if (Number.isFinite(p.elapsedMilliseconds) && p.elapsedMilliseconds >= 0 &&
            Number.isSafeInteger(p.completedReadBytes) && p.completedReadBytes >= 0 && Number.isSafeInteger(p.plannedReadBytes) && p.plannedReadBytes >= 0) {
          const start = Date.parse(p.startedAtUtc), elapsed = p.state !== "ended" && Number.isFinite(start)
            ? Math.max(p.elapsedMilliseconds, Date.now() - start) : p.elapsedMilliseconds;
          byId("user-validation-status").textContent += ` · 이 단계 ${(elapsed / 1000).toFixed(1)}초`;
          if (p.plannedReadBytes > 0) byId("user-validation-status").textContent +=
            ` · 확인된 읽기 ${(p.completedReadBytes / 1073741824).toFixed(2)} / 계획 ${(p.plannedReadBytes / 1073741824).toFixed(2)} GiB`;
        }
      }
      byId("user-validation-failure").textContent = action?.failureCode || "";
      byId("user-validation-start").disabled = pending || !valid || !["prepared", "uac_cancelled", "failed"].includes(status);
      byId("user-validation-recover").disabled = pending || !valid || status !== "cleanup_required";
    }
    async function refresh() {
      const version = ++revision, selection = { ...getSelection() };
      if (timer !== null) { cancel(timer); timer = null; }
      delivery = null; action = null; render();
      if (!selection.validationOnly) return;
      try {
        const [d, a] = await Promise.all([api(`/admin-api/v1/boss-user-validation/${selection.seasonNumber}`),
          api(`/admin-api/v1/boss-user-validation/${selection.seasonNumber}/${selection.weaknessCode}`)]);
        if (version !== revision || key(selection) !== key(getSelection()) || !getSelection().validationOnly) return;
        if (d.payload?.contractId !== "nll/user-validation-delivery-view/v1" || d.payload.schemaVersion !== 1 ||
            d.payload.seasonNumber !== selection.seasonNumber || d.payload.actualGameAcceptanceClaimed !== false ||
            !/^[0-9a-f]{64}$/.test(d.payload.bindingSha256 || "") || !Array.isArray(d.payload.selections) || d.payload.selections.length !== 5 ||
            new Set(d.payload.selections.map(s => s.weaknessCode)).size !== 5 ||
            d.payload.selections.some(s => !["fire", "water", "wind", "electric", "iron"].includes(s.weaknessCode) || !/^[0-9a-f]{64}$/.test(s.entrySha256 || "")) ||
            a.payload?.contractId !== "nll/user-validation-action/v1" || a.payload.seasonNumber !== selection.seasonNumber ||
            a.payload.weaknessCode !== selection.weaknessCode || a.payload.actualGameAcceptanceClaimed !== false || !Object.hasOwn(labels, a.payload.statusCode))
          throw new Error("boss_validation_view_invalid");
        delivery = d.payload; action = a.payload;
        if (!active(action.statusCode) && action.operationUid) for (const mode of ["Start", "Recover"]) {
          const operationKey = `${key(selection)}:${mode}`;
          if (operations.get(operationKey) === action.operationUid) operations.delete(operationKey);
        }
        if (active(action.statusCode)) timer = schedule(() => { void refresh(); }, 3000);
      } catch {
        if (version !== revision) return;
        action = { ...selection, statusCode: "blocked", failureCode: "boss_validation_status_unavailable" };
        // An uncertain read is not a stopped game. Keep retrying only reads.
        timer = schedule(() => { void refresh(); }, 5000);
      } finally { if (version === revision) render(); }
    }
    async function begin(mode) {
      if (pending || !["Start", "Recover"].includes(mode)) return;
      const selection = { ...getSelection() }, d = delivery, a = action;
      const selected = d?.selections.find(s => s.weaknessCode === selection.weaknessCode);
      if (!selection.validationOnly || d?.seasonNumber !== selection.seasonNumber || a?.weaknessCode !== selection.weaknessCode ||
          !selected || d.statusCode !== "awaiting_game_validation" ||
          (mode === "Start" ? !["prepared", "uac_cancelled", "failed"].includes(a.statusCode) : a.statusCode !== "cleanup_required")) return;
      const operationKey = `${key(selection)}:${mode}`;
      if (!operations.has(operationKey)) operations.set(operationKey, uid());
      pending = true; render();
      try {
        const { payload } = await api("/admin-api/v1/boss-user-validation-actions", { method: "POST", body: {
          operationUid: operations.get(operationKey), seasonNumber: selection.seasonNumber, weaknessCode: selection.weaknessCode,
          bindingSha256: d.bindingSha256, entrySha256: selected.entrySha256, mode } });
        if (payload?.contractId !== "nll/user-validation-action/v1" || payload.operationUid !== operations.get(operationKey) ||
            payload.seasonNumber !== selection.seasonNumber || payload.weaknessCode !== selection.weaknessCode || payload.actualGameAcceptanceClaimed !== false)
          throw new Error("boss_validation_action_invalid");
      } catch {
        // Preserve the operation UID until a read proves a terminal result.
        byId("user-validation-failure").textContent = "요청 결과가 불확실합니다. 상태를 확인한 뒤 같은 요청으로 재시도합니다.";
      } finally { pending = false; await refresh(); }
    }
    byId("user-validation-start").addEventListener("click", () => { void begin("Start"); });
    byId("user-validation-recover").addEventListener("click", () => { void begin("Recover"); });
    byId("user-validation-refresh").addEventListener("click", () => { void refresh(); });
    render();
    return { refresh, begin };
  }
  return { create };
})();
if (typeof module !== "undefined") module.exports = NllUserValidation;
