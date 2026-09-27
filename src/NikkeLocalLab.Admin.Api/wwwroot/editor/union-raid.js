"use strict";

const NllUnionRaid = (() => {
  function create({ document, api, uid = () => crypto.randomUUID(), schedule = setTimeout, cancel = clearTimeout }) {
    const byId = id => document.getElementById(id);
    let catalog = null, pending = null, submitting = false, timer = null, generation = 0;
    const message = text => { byId("union-status").textContent = text; };
    const statuses = { queued: "대기 중", running: "보스 5개를 불러오는 중", completed: "보스 5개 불러오기 완료", failed: "불러오기 실패" };
    function render() {
      const options = (catalog?.seasons || []).slice().sort((a, b) => b.seasonNumber - a.seasonNumber).map(row => {
        const option = document.createElement("option");
        option.value = String(row.seasonNumber);
        option.textContent = `시즌 ${row.seasonNumber}${row.statusCode === "assembled" ? " · 불러오기 완료" : row.statusCode === "unresolved" ? (row.failureCode === "boss_union_hard_not_available" ? " · 하드 자료 없음" : " · 자료 확인 필요") : ""}`;
        option.disabled = row.statusCode === "unresolved";
        return option;
      });
      byId("union-season").replaceChildren(...options);
      byId("union-season").selectedIndex = -1;
    }
    async function jobs() {
      const { payload } = await api("/admin-api/v1/union-raid/jobs");
      if (!Array.isArray(payload)) throw new Error("boss_union_jobs_invalid");
      const active = payload.find(job => ["queued", "running"].includes(job.statusCode));
      const last = active || payload[0];
      if (last) message(`시즌 ${last.seasonNumber} · ${statuses[last.statusCode] || "상태 확인 필요"}${last.failureCode ? ` (${last.failureCode})` : ""}`);
      if (active) {
        if (timer !== null) cancel(timer);
        timer = schedule(() => { timer = null; void jobs().catch(() => message("불러오기 상태를 확인하지 못했습니다. 목록을 새로고침하세요.")); }, 2000);
      } else if (last?.statusCode === "completed") {
        const { payload: latest } = await api("/admin-api/v1/union-raid/seasons");
        catalog = latest; render();
      }
    }
    async function refresh() {
      const request = ++generation;
      byId("union-refresh").disabled = true;
      try {
        const { payload } = await api("/admin-api/v1/union-raid/seasons");
        if (request !== generation) return;
        if (payload.statusCode !== "ready" || !Array.isArray(payload.seasons) || !/^[a-f0-9]{64}$/.test(payload.catalogSha256)) throw new Error("boss_union_catalog_invalid");
        catalog = payload; render();
        message("시즌을 선택하면 해당 시즌의 보스 5개를 불러옵니다.");
        await jobs();
      } catch { message("유니온 시즌 목록을 불러오지 못했습니다. 구성을 확인한 뒤 다시 시도하세요."); }
      finally { if (request === generation) byId("union-refresh").disabled = false; }
    }
    function select() {
      const row = catalog?.seasons.find(item => item.seasonNumber === Number(byId("union-season").value));
      if (!row || row.statusCode === "unresolved" || submitting) return;
      pending = { operationUid: uid(), seasonNumber: row.seasonNumber, catalogSha256: catalog.catalogSha256 };
      byId("union-bosses").replaceChildren(...row.bosses.map(boss => {
        const li = document.createElement("li"); li.textContent = boss.displayName || `보스 ${boss.order}`; return li;
      }));
      byId("union-confirm-title").textContent = `시즌 ${row.seasonNumber} 보스를 불러오시겠습니까?`;
      byId("union-confirm").showModal();
    }
    function dismiss() { pending = null; byId("union-confirm").close(); byId("union-season").selectedIndex = -1; }
    async function accept() {
      if (!pending || submitting) return;
      submitting = true; byId("union-yes").disabled = true; byId("union-season").disabled = true;
      const request = pending;
      try {
        const { payload } = await api("/admin-api/v1/union-raid/jobs", { method: "POST", body: request });
        message(`시즌 ${payload.seasonNumber} · ${statuses[payload.statusCode] || "처리 중"}`);
        dismiss(); await jobs();
      } catch { message("불러오기를 요청하지 못했습니다. 다시 예를 누르면 같은 요청으로 확인합니다."); }
      finally { submitting = false; byId("union-yes").disabled = false; byId("union-season").disabled = false; }
    }
    byId("union-season").addEventListener("change", select);
    byId("union-refresh").addEventListener("click", () => void refresh());
    byId("union-no").addEventListener("click", dismiss);
    byId("union-yes").addEventListener("click", () => void accept());
    byId("union-confirm").addEventListener("cancel", () => { pending = null; byId("union-season").selectedIndex = -1; });
    return { refresh };
  }
  return { create };
})();
if (typeof module !== "undefined") module.exports = NllUnionRaid;
