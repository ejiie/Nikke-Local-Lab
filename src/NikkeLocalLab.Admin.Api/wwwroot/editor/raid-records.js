"use strict";

// Account-scoped persisted records. Missing analysis is never replaced with TAB damage.
const NllRaidRecords = (() => {
  const elements = { all: "전체", fire: "작열", water: "수냉", wind: "풍압", electric: "전격", iron: "철갑", unknown: "미확인" };
  const money = value => typeof value === "string" && /^\d{1,28}$/.test(value)
    ? BigInt(value).toLocaleString("ko-KR") : "미확인";
  function date(value) {
    const parsed = new Date(value);
    return Number.isFinite(parsed.getTime()) ? new Intl.DateTimeFormat("ko-KR", {
      timeZone: "Asia/Seoul", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23"
    }).format(parsed) : "일시 미확인";
  }
  function filter(rows, context, mode, weakness) {
    return rows.filter(row => row.accountUid === context.accountUid && row.seasonNumber === context.seasonNumber &&
      (mode === "all" || row.mode === mode) && (weakness === "all" || (Object.hasOwn(elements, row.weaknessCode) ? row.weaknessCode : "unknown") === weakness))
      .sort((a, b) => (Date.parse(b.playedAt) || 0) - (Date.parse(a.playedAt) || 0));
  }
  function create({ document, loadRecords = null, presentation = () => null, loadAnalysis = async () => ({ status: "analysis_unavailable" }),
    navigate = selected => { for (const panel of document.querySelectorAll(".tab-panel")) panel.hidden = panel.dataset.tabPanel !== selected; } }) {
    const byId = id => document.getElementById(id);
    const node = (tag, cls, text) => {
      const el = document.createElement(tag); el.className = cls || "";
      if (text !== undefined) el.textContent = text;
      return el;
    };
    let context = {}, mode = "practice", weakness = "all", records = [], status = "unselected", generation = 0, nextCursor = null;
    // Union bosses keep their original weakness and the operator reads one list
    // per boss, so union scope asks for every mode and weakness.
    const union = () => context.raidKind === "union";
    const scope = () => union() ? { mode: "all", weakness: "all" } : { mode, weakness };
    const more = node("button", "ghost", "더 보기"); more.type = "button"; more.hidden = true;
    byId("raid-records-list").after(more);
    const refresh = node("button", "ghost", "새로고침"); refresh.type = "button";
    const order = byId("raid-records-order");
    order.parentElement.prepend(refresh);
    let returnScroll = 0, returnListScroll = 0, returnPanel = "raid";
    const analysis = NllRaidAnalysis.create({ document, load: loadAnalysis, portrait, characterInfo, navigate,
      back: previous => {
        if (!previous || previous.context.accountUid !== context.accountUid || previous.context.seasonNumber !== context.seasonNumber) return;
        navigate(returnPanel);
        byId("raid-records-list").scrollTop = returnListScroll;
        document.defaultView?.scrollTo({ top: returnScroll, behavior: "instant" });
        showDetail(previous.row);
      }
    });
    function openAnalysis(row, ordinal = null) {
      returnScroll = document.defaultView?.scrollY || 0;
      returnListScroll = byId("raid-records-list").scrollTop;
      returnPanel = [...document.querySelectorAll(".tab-panel")].find(panel => !panel.hidden)?.dataset.tabPanel || "raid";
      byId("raid-record-dialog").close();
      analysis.open(context, row, ordinal);
    }
    function characterInfo(character) {
      const art = presentation(character.characterUid) || {};
      return { ...character, name: character.name || art.displayName || "이름 미확인", portraitPath: character.portraitPath || art.portraitPath };
    }
    function portrait(character) {
      const holder = node("span", "raid-record-portrait"); holder.title = character.name;
      if (typeof character.portraitPath === "string" && /^\/editor\/[a-zA-Z0-9_./-]+$/.test(character.portraitPath) && !character.portraitPath.includes("..")) {
        const img = node("img", ""); img.alt = character.name; img.loading = "lazy";
        // MI artwork is a tall body portrait. SI is the site's square face artwork.
        const square = character.portraitPath.replace(/^\/editor\/assets\/characters\/([0-9a-f-]+)\.png$/i,
          "/editor/assets/character-faces/$1.png");
        img.src = square;
        let fallback = false;
        img.addEventListener("error", () => {
          if (!fallback && square !== character.portraitPath) {
            fallback = true; img.src = character.portraitPath;
          } else holder.replaceChildren(node("span", "", "?"));
        }); holder.append(img);
      } else holder.append(node("span", "", "?"));
      return holder;
    }
    function showDetail(row) {
      byId("raid-record-dialog-title").textContent = row.teamLabel || "덱 기록";
      byId("raid-record-dialog-context").textContent = `${context.bossName} · ${elements[row.weaknessCode] || elements.unknown} · ${date(row.playedAt)}`;
      byId("raid-record-total").textContent = money(row.resultDamage);
      const sources = (row.characters || []).slice(0, 5);
      const values = sources.map(c => typeof c.projectileExcludedDamage === "string" && /^\d{1,28}$/.test(c.projectileExcludedDamage)
        ? BigInt(c.projectileExcludedDamage) : null);
      const maximum = values.reduce((max, value) => value != null && value > max ? value : max, 0n);
      const complete = values.every(value => value != null);
      const characters = sources.map((source, i) => {
        const character = characterInfo(source);
        const li = node("li", "");
        const value = values[i];
        const rank = complete && value > 0n ? 1 + values.filter(other => other > value).length : 0;
        if (rank === 1 || rank === 2) li.dataset.damageRank = String(rank);
        const meter = node("span", "raid-record-damage-meter");
        meter.append(node("span", "raid-record-character-damage", value == null ? "분석값 없음" : money(character.projectileExcludedDamage)));
        if (value != null) {
          const track = node("span", "raid-record-damage-track");
          const fill = node("span", "raid-record-damage-fill");
          // Keep 64-bit damage exact; convert only the bounded percentage for CSS.
          fill.style.width = `${maximum > 0n ? Number(value * 10000n / maximum) / 100 : 0}%`;
          track.setAttribute("aria-hidden", "true"); track.append(fill); meter.append(track);
        }
        li.append(portrait(character), node("strong", "raid-record-character-name", character.name), meter);
        li.classList.add("raid-record-character-link"); li.tabIndex = 0; li.setAttribute("role", "button");
        li.setAttribute("aria-label", `${character.name} 상세 분석 보기`);
        li.addEventListener("click", () => openAnalysis(row, character.ordinal));
        li.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); openAnalysis(row, character.ordinal); } });
        return li;
      });
      byId("raid-record-characters").replaceChildren(...characters);
      if (!characters.length) byId("raid-record-characters").append(node("li", "", "편성 정보가 없습니다."));
      byId("raid-record-analysis-open").onclick = () => openAnalysis(row);
      byId("raid-record-dialog").showModal();
    }
    function rowNode(row) {
      const li = node("li", ""), button = node("button", "raid-record-row"); button.type = "button";
      const when = node("span", "raid-record-when");
      when.append(node("strong", "", date(row.playedAt)), node("span", "raid-record-element-label", elements[row.weaknessCode] || elements.unknown));
      const team = node("span", "raid-record-team");
      team.append(node("strong", "", row.teamLabel || "덱 기록"));
      const members = node("span", "raid-record-member-portraits");
      members.append(...(row.characters || []).slice(0, 5).map(c => portrait(characterInfo(c))));
      if (!members.childElementCount) members.textContent = "편성 정보 없음";
      team.append(members);
      const damage = node("span", "raid-record-damage");
      damage.append(node("small", "", "Damage"), node("strong", "", money(row.resultDamage)));
      button.append(when, team, damage, node("span", "raid-record-chevron", "›"));
      button.addEventListener("click", () => showDetail(row)); li.append(button); return li;
    }
    function render() {
      byId("raid-records-title").textContent = context.bossName ? `${context.bossName} 기록` : "보스별 기록";
      byId("raid-records-context").textContent = context.accountUid
        ? `${context.accountName || "선택 계정"} · 시즌 ${context.seasonNumber || "—"}` : "계정을 선택해 주세요.";
      for (const key of ["practice", "live"]) byId(`raid-records-${key}`).setAttribute("aria-pressed", String(key === mode));
      byId("raid-records-practice").parentElement.hidden = union();
      byId("raid-records-elements").hidden = union();
      byId("raid-records").querySelector(".raid-records-footnote").hidden = union();
      const controls = Object.entries(elements).map(([code, label]) => {
        const button = node("button", "raid-record-element"); button.type = "button"; button.dataset.recordWeakness = code;
        button.setAttribute("aria-pressed", String(code === weakness));
        if (!["all", "unknown"].includes(code)) {
          const img = node("img", ""); img.alt = ""; img.src = `/editor/assets/ui/code-${code}.png`;
          img.addEventListener("error", () => { img.hidden = true; }); button.append(img);
        }
        button.append(node("span", "", label));
        button.addEventListener("click", () => {
          weakness = code; void reload();
          byId("raid-records-elements").querySelector(`[data-record-weakness="${code}"]`).focus();
        }); return button;
      });
      byId("raid-records-elements").replaceChildren(...controls);
      byId("raid-records-list-title").textContent = union() ? "기록" : `${mode === "practice" ? "모의전" : "실전"} 기록 · ${elements[weakness]}`;
      const visible = status === "ready" ? filter(records, context, scope().mode, scope().weakness) : [];
      byId("raid-records-count").textContent = status === "ready" ? `${visible.length}건` : "—";
      byId("raid-records-list").replaceChildren(...visible.map(rowNode));
      more.hidden = !nextCursor || status !== "ready";
      refresh.disabled = status === "loading" || !context.accountUid;
      byId("raid-records-list").hidden = visible.length === 0;
      byId("raid-records-empty").hidden = visible.length !== 0;
      const messages = {
        unselected: ["계정을 선택해 주세요", "선택한 계정의 보스별 전투 기록을 확인할 수 있습니다."],
        unconnected: ["기록 조회를 준비하고 있습니다", "모의전·실전과 속성별로 기록을 확인할 수 있도록 준비 중입니다."],
        loading: ["기록을 불러오는 중입니다", "잠시만 기다려 주세요."],
        failed: ["기록을 불러오지 못했습니다", "보스를 다시 선택해 주세요."],
        ready: union() ? ["아직 기록이 없습니다", "이 보스와 전투하면 기록이 표시됩니다."]
          : ["조건에 맞는 기록이 없습니다", "다른 속성이나 기록 종류를 선택해 보세요."]
      };
      const message = messages[status];
      byId("raid-records-empty-title").textContent = message[0]; byId("raid-records-empty-text").textContent = message[1];
    }
    async function setContext(next) {
      const unchanged = context.accountUid === next.accountUid && context.seasonNumber === next.seasonNumber && context.raidKind === next.raidKind && context.bossStep === next.bossStep;
      context = { ...next };
      if (unchanged) { render(); return; }
      analysis.reset();
      if (!document.querySelector('[data-tab-panel="raid-analysis"]').hidden) navigate(union() ? "union-raid" : "raid");
      weakness = "all";
      await reload();
    }
    async function reload(append = false) {
      const request = ++generation;
      const cursor = append ? nextCursor : null;
      if (!append) { records = []; nextCursor = null; }
      if (byId("raid-record-dialog").open) byId("raid-record-dialog").close();
      status = !context.accountUid || !context.seasonNumber ? "unselected" : loadRecords ? "loading" : "unconnected";
      render();
      if (status !== "loading") return;
      try {
        const loaded = await loadRecords({ ...context, ...scope(), cursor });
        if (request !== generation) return;
        const rows = Array.isArray(loaded) ? loaded : loaded.records;
        if (!Array.isArray(rows)) throw new Error("records_invalid");
        const combined = append ? records.concat(rows) : rows;
        records = [...new Map(combined.map(row => [row.battleUid, row])).values()];
        nextCursor = Array.isArray(loaded) ? null : loaded.nextCursor;
        status = "ready";
      } catch { if (request !== generation) return; status = "failed"; }
      render();
    }
    for (const key of ["practice", "live"]) byId(`raid-records-${key}`).addEventListener("click", () => { mode = key; void reload(); });
    more.addEventListener("click", () => void reload(true));
    refresh.addEventListener("click", () => void reload());
    order.addEventListener("change", () => {
      // Newest is the only supported order, matching the API's cursor order.
      order.value = "newest";
      render();
      byId("raid-records-list").scrollTop = 0;
    });
    byId("raid-record-dialog-close").addEventListener("click", () => byId("raid-record-dialog").close());
    render();
    return { setContext };
  }
  return { create, filter, money };
})();
if (typeof module !== "undefined") module.exports = NllRaidRecords;
