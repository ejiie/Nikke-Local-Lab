"use strict";

// Presentation/controller only. An HTTP success is not a completed import, and
// a completed candidate is not native-game acceptance.
const NllBossSeasons = (() => {
  const elements = { fire: "작열", water: "수냉", wind: "풍압", electric: "전격", iron: "철갑" };
  const statuses = { processed: "정보 처리 완료", unprocessed: "불러오기 필요", unresolved: "자료 확인 필요",
    awaiting_runtime_delivery: "FX 전달 준비 필요", queued: "처리 대기", running: "보스 정보 처리 중",
    completed: "정보 처리 완료", failed: "처리 실패", blocked: "처리 보류", awaiting_game_validation: "실게임 검증 대기" };
  function create({ document, api, onSelected, onUnavailable = () => {}, uid = () => crypto.randomUUID(),
    schedule = (fn, ms) => setTimeout(fn, ms), cancel = timer => clearTimeout(timer) }) {
    const byId = id => document.getElementById(id);
    let catalog = null, loadNumber = 0, selected = null, pending = null, timer = null, polling = false;
    const operations = new Map(), inflight = new Set(), observed = new Set(), notified = new Set();
    function node(tag, className, text) {
      const value = document.createElement(tag);
      if (className) value.className = className;
      if (text !== undefined) value.textContent = text;
      return value;
    }
    function card(row, detail = false) {
      const button = node("button", `boss-card ${detail ? "raid-boss-option" : "boss-season-option"}`);
      button.type = "button";
      button.dataset.season = String(row.seasonNumber);
      button.dataset.defaultWeaknessCode = row.defaultWeaknessCode || "";
      button.disabled = row.processingStatusCode === "unresolved" || inflight.has(row.seasonNumber);
      button.setAttribute("aria-pressed", String(detail));
      button.append(node("span", "boss-season", `SEASON ${row.seasonNumber}`));
      const art = node("span", "boss-art boss-catalog-art");
      const placeholder = node("span", "boss-image-placeholder", "보스 이미지 확인 중");
      art.append(placeholder);
      const expectedImage = `/admin-api/v1/boss-seasons/${row.seasonNumber}/image?catalog=${catalog.catalogSha256}`;
      if (row.imageUrl === expectedImage) {
        const image = node("img", "boss-catalog-image");
        image.alt = "";
        image.loading = "lazy";
        image.addEventListener("load", () => { placeholder.hidden = true; });
        image.addEventListener("error", () => { image.hidden = true; placeholder.hidden = false; });
        image.src = expectedImage;
        art.append(image);
      }
      const content = node("span", "boss-content");
      content.append(node("span", "available-badge", statuses[row.processingStatusCode] || "확인 필요"));
      content.append(node("strong", "", row.displayName || "보스 이름 미확인"));
      content.append(node("small", "", "Classic Solo Raid · Challenge"));
      const summary = node("span", "boss-weakness-summary");
      summary.dataset.bossWeaknessSummary = "";
      summary.append(node("span", "", "기본 약점"));
      const value = node("span", "");
      if (Object.hasOwn(elements, row.defaultWeaknessCode || "")) {
        const icon = node("img", "");
        icon.alt = "";
        icon.addEventListener("error", () => { icon.hidden = true; });
        icon.dataset.bossWeaknessIcon = "";
        icon.src = `/editor/assets/ui/code-${row.defaultWeaknessCode}.png`;
        value.append(icon);
      }
      const label = node("b", "", elements[row.defaultWeaknessCode] || "미확인");
      label.dataset.bossWeaknessLabel = "";
      value.append(label); summary.append(value); content.append(summary);
      button.append(art, content);
      if (!detail) button.addEventListener("click", () => selectSeason(row.seasonNumber));
      return button;
    }
    function render() {
      byId("boss-season-grid").replaceChildren(...(catalog?.seasons || []).map(row => card(row)));
      if (!selected) byId("selected-boss-card").replaceChildren();
      if (selected) {
        const row = catalog?.seasons.find(item => item.seasonNumber === selected);
        if (["processed", "awaiting_game_validation"].includes(row?.processingStatusCode)) byId("selected-boss-card").replaceChildren(card(row, true));
        else { selected = null; byId("selected-boss-card").replaceChildren(); byId("boss-detail").hidden = true; onUnavailable(); }
      }
    }
    function showMessage(title, message) {
      byId("boss-message-title").textContent = title;
      byId("boss-message-text").textContent = message;
      if (!byId("boss-message-dialog").open) byId("boss-message-dialog").showModal();
    }
    async function refreshCatalog() {
      const number = ++loadNumber;
      try {
        const { payload } = await api("/admin-api/v1/boss-seasons");
        if (number !== loadNumber) return;
        if (payload?.schemaVersion !== 1 || payload.contractId !== "nll/boss-season-catalog-view/v1" || payload.statusCode !== "ready" ||
            !/^[0-9a-f]{64}$/.test(payload.catalogSha256 || "") || !Number.isInteger(payload.maximumKnownSeason) ||
            payload.maximumKnownSeason < 1 || payload.maximumKnownSeason > 1000 || !Array.isArray(payload.seasons) ||
            payload.seasons.length !== payload.maximumKnownSeason || payload.seasons.some((row, index) =>
              row.seasonNumber !== index + 1 || !["processed", "unprocessed", "unresolved", "awaiting_runtime_delivery", "awaiting_game_validation"].includes(row.processingStatusCode) ||
              (row.processingStatusCode !== "unresolved" && !Object.hasOwn(elements, row.defaultWeaknessCode || "")) ||
              (row.defaultWeaknessCode !== null && !Object.hasOwn(elements, row.defaultWeaknessCode)))) throw new Error("boss_catalog_invalid");
        catalog = payload;
        byId("boss-catalog-status").textContent = `시즌 1–${payload.maximumKnownSeason} · 로컬 자료 기준 (현재 시즌 여부 미확인)`;
        render();
      } catch {
        if (number !== loadNumber) return;
        catalog = null; selected = null;
        byId("boss-catalog-status").textContent = "시즌 목록을 확인할 수 없습니다. 로컬 자료 구성을 확인한 뒤 다시 시도하세요.";
        byId("boss-detail").hidden = true;
        render(); onUnavailable();
      }
    }
    function selectSeason(season) {
      const row = catalog?.seasons.find(item => item.seasonNumber === season);
      if (!row || row.processingStatusCode === "unresolved" || inflight.has(season)) return;
      if (["processed", "awaiting_game_validation"].includes(row.processingStatusCode)) {
        selected = season;
        byId("boss-season-picker").hidden = true;
        byId("boss-detail").hidden = false;
        render(); onSelected(row);
        return;
      }
      pending = { seasonNumber: season, displayName: row.displayName, catalogSha256: catalog.catalogSha256 };
      byId("boss-import-question").textContent = `Season ${season} 보스\n${row.displayName || "이름 미확인 보스"}을 불러오시겠습니까?`;
      byId("boss-import-dialog").showModal();
    }
    async function confirmImport() {
      const request = pending;
      pending = null;
      byId("boss-import-dialog").close(); // Close before the first network operation.
      if (!request || inflight.has(request.seasonNumber)) return;
      inflight.add(request.seasonNumber); render();
      const key = `${request.catalogSha256}:${request.seasonNumber}`;
      if (!operations.has(key)) operations.set(key, uid());
      byId("boss-job-status").textContent = `Season ${request.seasonNumber} 불러오기 요청 중…`;
      try {
        const { payload } = await api("/admin-api/v1/boss-onboarding-jobs", { method: "POST", body: {
          seasonNumber: request.seasonNumber, catalogSha256: request.catalogSha256, operationUid: operations.get(key) } });
        if (payload?.contractId !== "nll/boss-onboarding-job/v1" || payload.seasonNumber !== request.seasonNumber ||
            payload.catalogSha256 !== request.catalogSha256 || !payload.jobUid) throw new Error("boss_job_invalid");
        observed.add(payload.jobUid);
        await refreshJobs();
      } catch {
        // Retain operation UID: an uncertain HTTP result must not duplicate work.
        showMessage("불러오기 상태 확인 필요", "요청 결과를 확인하지 못했습니다. 다시 시도하면 같은 요청의 상태를 확인합니다.");
      } finally { inflight.delete(request.seasonNumber); render(); }
    }
    async function refreshJobs() {
      if (polling) return;
      polling = true;
      if (timer !== null) { cancel(timer); timer = null; }
      try {
        const { payload } = await api("/admin-api/v1/boss-onboarding-jobs");
        if (!Array.isArray(payload) || payload.length > 1000 || payload.some(job => job.contractId !== "nll/boss-onboarding-job/v1" ||
            !["queued", "running", "completed", "failed", "blocked", "awaiting_runtime_delivery", "awaiting_game_validation"].includes(job.statusCode)))
          throw new Error("boss_jobs_invalid");
        const active = payload.filter(job => ["queued", "running"].includes(job.statusCode));
        for (const job of active) observed.add(job.jobUid);
        byId("boss-job-status").textContent = active.length ? `보스 정보 처리 중 · ${active.length}건` : "진행 중인 불러오기 작업이 없습니다.";
        byId("boss-jobs").replaceChildren(...payload.slice(0, 12).map(job => node("li", "",
          `Season ${job.seasonNumber} · ${statuses[job.statusCode] || "상태 확인 필요"}`)));
        for (const job of payload) {
          if (!observed.has(job.jobUid) || notified.has(job.jobUid) || ["queued", "running"].includes(job.statusCode)) continue;
          notified.add(job.jobUid);
          operations.delete(`${job.catalogSha256}:${job.seasonNumber}`);
          showMessage(job.statusCode === "completed" ? "보스 불러오기 완료" : "보스 불러오기 상태",
            `Season ${job.seasonNumber} · ${statuses[job.statusCode]}${job.failureCode ? `\n${job.failureCode}` : ""}`);
          await refreshCatalog(); // Never switch the user's selected season on a late completion.
        }
        if (active.length) timer = schedule(() => { void refreshJobs(); }, 2500);
      } catch {
        byId("boss-job-status").textContent = "불러오기 상태를 확인할 수 없습니다. 상태 새로고침을 눌러주세요.";
        // Polling failures do not mean the durable worker stopped.
        if (observed.size) timer = schedule(() => { void refreshJobs(); }, 5000);
      } finally { polling = false; }
    }
    byId("select-boss-season").addEventListener("click", () => {
      byId("boss-season-picker").hidden = false; byId("boss-detail").hidden = true;
      void refreshCatalog(); void refreshJobs();
    });
    byId("boss-season-back").addEventListener("click", () => {
      byId("boss-season-picker").hidden = true; byId("boss-detail").hidden = selected === null;
    });
    byId("boss-import-no").addEventListener("click", () => { pending = null; byId("boss-import-dialog").close(); });
    byId("boss-import-dialog").addEventListener("cancel", () => { pending = null; });
    byId("boss-import-yes").addEventListener("click", () => { void confirmImport(); });
    byId("boss-message-close").addEventListener("click", () => byId("boss-message-dialog").close());
    byId("boss-jobs-refresh").addEventListener("click", () => { void refreshJobs(); void refreshCatalog(); });
    return { refreshCatalog, refreshJobs, selectSeason, confirmImport };
  }
  return { create };
})();
if (typeof module !== "undefined") module.exports = NllBossSeasons;
