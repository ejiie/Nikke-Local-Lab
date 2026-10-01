"use strict";

const NllUnionRaid = (() => {
  const weaknesses = { fire: "작열", water: "수냉", wind: "풍압", electric: "전격", iron: "철갑" };
  // "이름 [코드]" splits into a name line and a smaller code line on the card.
  function bossLabel(boss) {
    const name = boss.displayName || `보스 ${boss.order}`;
    const match = /^(.*\S)\s*\[([^\]]+)\]$/.exec(name);
    return match ? { name: match[1], code: match[2] } : { name, code: "" };
  }
  function create({ document, api, uid = () => crypto.randomUUID(), schedule = setTimeout, cancel = clearTimeout, onBossSelected = () => {} }) {
    const byId = id => document.getElementById(id);
    const node = (tag, cls, text) => {
      const el = document.createElement(tag); el.className = cls || "";
      if (text !== undefined) el.textContent = text;
      return el;
    };
    let catalog = null, pending = null, submitting = false, timer = null, generation = 0;
    let shown = null, order = 1, jobsBySeason = new Map();
    // Only failures are shown under the list; progress lives in the season labels.
    const message = text => { byId("union-status").textContent = text; byId("union-status").hidden = !text; };
    const active = job => ["queued", "running"].includes(job?.statusCode);
    const shownRow = () => catalog?.seasons.find(row => row.seasonNumber === shown);
    function suffix(row) {
      const job = jobsBySeason.get(row.seasonNumber);
      if (active(job)) return " · 불러오는 중";
      if (row.statusCode === "assembled") return " · 불러오기 완료";
      if (job?.statusCode === "failed") return " · 불러오기 실패";
      if (row.statusCode === "unresolved") return row.failureCode === "boss_union_hard_not_available" ? " · 하드 자료 없음" : " · 자료 확인 필요";
      return "";
    }
    function restoreSelection() {
      if (shown === null) byId("union-season").selectedIndex = -1;
      else byId("union-season").value = String(shown);
    }
    function render() {
      const options = (catalog?.seasons || []).slice().sort((a, b) => b.seasonNumber - a.seasonNumber).map(row => {
        const option = document.createElement("option");
        option.value = String(row.seasonNumber);
        option.textContent = `시즌 ${row.seasonNumber}${suffix(row)}`;
        option.title = jobsBySeason.get(row.seasonNumber)?.failureCode || "";
        option.disabled = row.statusCode === "unresolved";
        return option;
      });
      byId("union-season").replaceChildren(...options);
      if (shown !== null && shownRow()?.statusCode !== "assembled") hide();
      restoreSelection();
    }
    function hide() {
      shown = null;
      byId("union-boss-cards").replaceChildren(); byId("union-boss-cards").hidden = true;
      byId("union-detail-empty").hidden = false;
      onBossSelected(null);
    }
    function card(row, boss) {
      const label = bossLabel(boss);
      const button = node("button", "union-boss-card"); button.type = "button";
      button.dataset.order = String(boss.order);
      button.setAttribute("aria-pressed", String(boss.order === order));
      const art = node("span", "union-boss-art");
      const expected = `/admin-api/v1/union-raid/seasons/${row.seasonNumber}/bosses/${boss.order}/image?catalog=${catalog.catalogSha256}`;
      const placeholder = node("span", "union-boss-placeholder", boss.imageUrl === expected ? "이미지 확인 중" : "이미지 없음");
      art.append(placeholder);
      if (boss.imageUrl === expected) {
        const image = node("img", "union-boss-image"); image.alt = ""; image.loading = "lazy";
        image.addEventListener("load", () => { placeholder.hidden = true; });
        image.addEventListener("error", () => { image.hidden = true; placeholder.textContent = "이미지 없음"; });
        image.src = expected; art.append(image);
      }
      if (Object.hasOwn(weaknesses, boss.weaknessCode)) {
        const text = weaknesses[boss.weaknessCode];
        const badge = node("span", "union-boss-weakness"); badge.title = `약점 ${text}`;
        const icon = node("img", ""); icon.alt = `약점 ${text}`;
        icon.addEventListener("error", () => { badge.classList.add("text"); badge.replaceChildren(text); });
        icon.src = `/editor/assets/ui/code-${boss.weaknessCode}.png`;
        badge.append(icon); art.append(badge);
      }
      button.append(art, node("strong", "union-boss-name", label.name));
      if (label.code) button.append(node("span", "union-boss-code", label.code));
      button.addEventListener("click", () => choose(row, boss.order));
      return button;
    }
    function renderBosses(row) {
      byId("union-boss-cards").replaceChildren(...row.bosses.map(boss => card(row, boss)));
      byId("union-boss-cards").hidden = false;
      byId("union-detail-empty").hidden = true;
    }
    function choose(row, next) {
      order = next;
      for (const button of byId("union-boss-cards").children)
        button.setAttribute("aria-pressed", String(Number(button.dataset.order) === order));
      const boss = row.bosses.find(item => item.order === order);
      onBossSelected({ seasonNumber: row.seasonNumber, order, bossName: boss?.displayName || `보스 ${order}` });
    }
    function show(row) {
      shown = row.seasonNumber; order = 1;
      renderBosses(row); choose(row, 1);
    }
    async function loadCatalog() {
      const { payload } = await api("/admin-api/v1/union-raid/seasons");
      if (payload.statusCode !== "ready" || !Array.isArray(payload.seasons) || !/^[a-f0-9]{64}$/.test(payload.catalogSha256)) throw new Error("boss_union_catalog_invalid");
      return payload;
    }
    async function jobs() {
      const { payload } = await api("/admin-api/v1/union-raid/jobs");
      if (!Array.isArray(payload)) throw new Error("boss_union_jobs_invalid");
      // The list is newest first; the first job per season is its current state.
      jobsBySeason = new Map();
      for (const job of payload) if (!jobsBySeason.has(job.seasonNumber)) jobsBySeason.set(job.seasonNumber, job);
      if (payload.some(active)) {
        if (timer !== null) cancel(timer);
        timer = schedule(() => { timer = null; void jobs().catch(() => message("불러오기 상태를 확인하지 못했습니다. 목록을 새로고침하세요.")); }, 2000);
      }
      const stale = [...jobsBySeason.values()].some(job => job.statusCode === "completed" &&
        catalog?.seasons.find(row => row.seasonNumber === job.seasonNumber)?.statusCode === "available");
      if (stale) catalog = await loadCatalog();
      render();
    }
    async function refresh() {
      const request = ++generation;
      byId("union-refresh").disabled = true;
      try {
        const payload = await loadCatalog();
        if (request !== generation) return;
        catalog = payload; message(""); render();
        // A new catalog pin changes the image addresses of the cards on screen.
        if (shown !== null) renderBosses(shownRow());
        await jobs();
      } catch { message("유니온 시즌 목록을 불러오지 못했습니다. 구성을 확인한 뒤 다시 시도하세요."); }
      finally { if (request === generation) byId("union-refresh").disabled = false; }
    }
    function select() {
      const row = catalog?.seasons.find(item => item.seasonNumber === Number(byId("union-season").value));
      if (!row || row.statusCode === "unresolved" || submitting) return;
      if (row.statusCode === "assembled") { if (row.seasonNumber !== shown) show(row); return; }
      if (active(jobsBySeason.get(row.seasonNumber))) { restoreSelection(); return; }
      pending = { operationUid: uid(), seasonNumber: row.seasonNumber, catalogSha256: catalog.catalogSha256 };
      byId("union-confirm-title").textContent = `시즌 ${row.seasonNumber} 보스를 불러오시겠습니까?`;
      byId("union-confirm").showModal();
    }
    function dismiss() { pending = null; byId("union-confirm").close(); restoreSelection(); }
    async function accept() {
      if (!pending || submitting) return;
      submitting = true; byId("union-yes").disabled = true; byId("union-season").disabled = true;
      const request = pending;
      try {
        const { payload } = await api("/admin-api/v1/union-raid/jobs", { method: "POST", body: request });
        jobsBySeason.set(payload.seasonNumber, payload); message("");
        dismiss(); await jobs();
      } catch { message("불러오기를 요청하지 못했습니다. 다시 예를 누르면 같은 요청으로 확인합니다."); }
      finally { submitting = false; byId("union-yes").disabled = false; byId("union-season").disabled = false; }
    }
    byId("union-season").addEventListener("change", select);
    byId("union-refresh").addEventListener("click", () => void refresh());
    byId("union-no").addEventListener("click", dismiss);
    byId("union-yes").addEventListener("click", () => void accept());
    byId("union-confirm").addEventListener("cancel", () => { pending = null; restoreSelection(); });
    return { refresh };
  }
  return { create, bossLabel };
})();
if (typeof module !== "undefined") module.exports = NllUnionRaid;
