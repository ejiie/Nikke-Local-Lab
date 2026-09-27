"use strict";

const NllRaidAnalysis = (() => {
  const categories = { basic: "평타", replacement: "교체 무기", automatic: "자동 무기", skill: "스킬 직접 피해", effect: "스킬 효과 피해", unknown: "미분류" };
  const origins = { basic: "기본 무기", skill1: "스킬 1", skill2: "스킬 2", burst: "버스트", unresolved: "출처 미확인" };
  const components = { collision: "부착", explosion: "폭발" };
  const effects = { InstantNumber: "대상 지정 공격", InstantAll: "전체 대상 공격", InstantSequentialAttack: "순차 공격",
    Damage: "추가 피해", DotDamage: "지속 피해", DamageByHpRate: "체력 비례 피해", AutoFireWeapon: "자동 무기",
    ChangeWeapon: "교체 무기", InstantCircle: "범위 공격", InstantSector: "부채꼴 공격" };
  const numeric = value => typeof value === "string" && /^\d{1,28}$/.test(value) ? BigInt(value) : null;
  const format = value => value == null ? "—" : value.toLocaleString("ko-KR");
  const percent = (value, total) => total > 0n ? Number(value * 10000n / total) / 100 : 0;
  function create({ document, load, portrait, characterInfo, navigate, back }) {
    const byId = id => document.getElementById(id);
    const node = (tag, cls, text) => { const e = document.createElement(tag); e.className = cls || ""; if (text != null) e.textContent = text; return e; };
    let current = null, selected = null, response = null, generation = 0;
    function setView(view) {
      for (const name of ["composition", "timeline"]) {
        byId(`raid-analysis-view-${name}`).setAttribute("aria-pressed", String(view === name));
        byId(`raid-analysis-${name}`).hidden = view !== name;
      }
      byId("raid-analysis-page-title").textContent = view === "timeline" ? "타임라인" : "피해 구성";
    }
    function render() {
      if (!current) return;
      const chars = (current.row.characters || []).slice(0, 5).map(characterInfo);
      const tabs = [[null, "전체"], ...chars.map(c => [c.ordinal, c.name, c])].map(([ordinal, label, character]) => {
        const button = node("button", "raid-analysis-member"); button.type = "button";
        button.setAttribute("aria-pressed", String(selected === ordinal));
        if (character) button.append(portrait(character)); button.append(node("span", "", label));
        button.addEventListener("click", () => { selected = ordinal; render(); }); return button;
      });
      byId("raid-analysis-members").replaceChildren(...tabs);
      const chosen = selected == null ? chars : chars.filter(c => c.ordinal === selected);
      const totals = chosen.map(c => numeric(c.projectileExcludedDamage));
      const total = totals.length > 0 && totals.every(x => x != null) ? totals.reduce((a, b) => a + b, 0n) : null;
      byId("raid-analysis-name").textContent = selected == null ? "덱 전체 피해 구성" : `${chosen[0]?.name || "캐릭터"} 피해 구성`;
      byId("raid-analysis-damage").textContent = format(total);
      const output = byId("raid-analysis-content"); output.replaceChildren();
      const summary = byId("raid-analysis-status");
      const analysis = response?.analysis;
      if (!analysis || !["ready", "partial"].includes(response.status)) {
        summary.textContent = response == null ? "피해 구성을 분석하고 있습니다…" : ({
          log_missing: "이 기록의 BattleLog 원문이 없습니다.", catalog_missing: "이 전투 버전의 분석 자료가 준비되지 않았습니다.",
          analysis_unavailable: "이 기록은 투사체 피해 제외 분석이 준비되지 않았습니다.", busy: "다른 기록을 분석 중입니다. 잠시 뒤 다시 시도해 주세요.",
          unsupported_schema: "아직 지원하지 않는 로그 형식입니다.", failed: "분석을 불러오지 못했습니다. 다시 시도해 주세요."
        }[response.status] || "이 기록의 분석 자료를 확인하지 못했습니다.");
        return;
      }
      const analyses = chosen.map(c => analysis.characters.find(a => a.ordinal === c.ordinal));
      if (analyses.some(a => !a) || total == null) { summary.textContent = "일부 캐릭터의 분석 자료가 없습니다."; return; }
      const grouped = Object.fromEntries(Object.keys(categories).map(key => [key, { total: 0n, hits: 0, rows: [] }]));
      analyses.forEach((item, i) => {
        for (const part of item.components || []) {
          const value = numeric(part.damage); if (value == null || value === 0n) continue;
          const group = grouped[part.category] || grouped.unknown;
          group.total += value; group.hits += part.hits;
          group.rows.push({ ...part, value, name: chosen[i].name, ordinal: chosen[i].ordinal });
        }
        const unresolved = numeric(item.unclassifiedDamage);
        if (unresolved != null) grouped.unknown.total += unresolved;
      });
      if (Object.values(grouped).reduce((sum, g) => sum + g.total, 0n) !== total) {
        summary.textContent = "피해 구성 합계가 딜표와 일치하지 않아 표시를 보류했습니다."; return;
      }
      summary.textContent = grouped.unknown.total > 0n ? "출처를 확정하지 못한 피해는 미분류로 표시합니다." : "";
      const split = byId("raid-analysis-split").checked;
      const stack = node("div", "raid-analysis-stack"); stack.setAttribute("aria-label", "피해 구성 비중");
      const legend = node("div", "raid-analysis-legend");
      const palette = ["#0ba9e6", "#db9250", "#7861d4", "#339e95", "#bb62bc", "#cd6677", "#7b963b", "#527aaf"];
      let chartIndex = 0;
      function addSegment(key, label, value) {
        if (value === 0n) return;
        const share = percent(value, total);
        const color = split && key !== "unknown" ? palette[chartIndex++ % palette.length] : null;
        const segment = node("span", `raid-analysis-segment composition-${key}`);
        // Layout uses greater precision than the displayed percentage, including tiny effects.
        segment.style.flexGrow = String(Number(value * 100000000n / total));
        segment.title = `${label} ${share}%`;
        segment.setAttribute("aria-label", segment.title);
        const item = node("div", `raid-analysis-legend-item composition-${key}`);
        if (color) { segment.style.setProperty("--composition", color); item.style.setProperty("--composition", color); }
        item.append(node("i", "raid-analysis-swatch"), node("span", "", label), node("strong", "", `${share}%`));
        stack.append(segment); legend.append(item);
        return color;
      }
      output.append(stack, legend);
      for (const [key, group] of Object.entries(grouped)) {
        if (group.total === 0n && !group.rows.length) continue;
        if (!split) addSegment(key, categories[key], group.total);
        else if (key === "unknown") {
          const remainder = group.total - group.rows.reduce((sum, part) => sum + part.value, 0n);
          addSegment(key, categories[key], remainder);
        }
        const details = node("details", `raid-analysis-group composition-${key}`); details.open = selected != null;
        const heading = node("summary", "");
        if (key === "basic") heading.title = "평타에 적용된 스킬 강화 효과도 이 피해에 포함됩니다.";
        heading.append(node("strong", "", categories[key]), node("span", "", format(group.total)), node("span", "", `${percent(group.total, total)}%`));
        details.append(heading);
        if (key === "unknown") details.append(node("p", "raid-analysis-muted", "다른 항목에 임의로 배분하지 않은 피해입니다."));
        const list = node("div", "raid-analysis-effects");
        let rows = group.rows;
        if (!split) {
          const summaries = new Map();
          for (const part of rows) {
            const identity = JSON.stringify([part.ordinal, part.origin, part.component]);
            const previous = summaries.get(identity);
            if (previous) { previous.value += part.value; previous.hits += part.hits; }
            else summaries.set(identity, { ...part });
          }
          rows = [...summaries.values()];
        } else {
          rows = rows.flatMap(part => {
            if (key !== "basic" || !part.breakdown?.length) return [part];
            const slices = part.breakdown.map(slice => ({ ...part, ...slice, value: numeric(slice.damage),
              sliceKind: slice.kind, penetratingValue: numeric(slice.penetratingDamage) }));
            if (slices.some(slice => slice.value == null) || slices.reduce((sum, slice) => sum + slice.value, 0n) !== part.value)
              return [{ ...part, sliceKind: "unresolved" }];
            return slices.filter(slice => slice.value > 0n);
          });
        }
        rows.forEach((part, index) => {
          const row = node("div", "raid-analysis-effect");
          let label = origins[part.origin] || origins.unresolved;
          if (split && key === "basic") {
            label = part.sliceKind === "enhanced" ? `강화 평타 · ${Math.max(...part.pelletThresholds)}펠릿 조건`
              : part.sliceKind === "normal" ? "일반 평타" : "강화 상태 미확인";
            if (part.sliceKind === "enhanced") row.title = `활성 조건: ${part.pelletThresholds.join(" · ")}펠릿`;
          } else {
            label += components[part.component] ? ` · ${components[part.component]}` : "";
            if (split && (key === "skill" || key === "effect")) {
              const kind = effects[part.effectKind] || "개별 효과";
              const same = rows.filter(p => p.ordinal === part.ordinal && p.origin === part.origin && p.effectKind === part.effectKind);
              label += ` · ${kind}${same.length > 1 ? ` ${same.indexOf(part) + 1}` : ""}`;
            }
          }
          const title = `${selected == null ? part.name + " · " : ""}${label}`;
          const color = split ? addSegment(key, title, part.value) : null;
          const info = node("div", "");
          if (!split) {
            if (selected == null) info.append(node("strong", "", part.name));
            info.append(node("span", "", label));
          }
          const metrics = node("div", "raid-analysis-effect-values");
          if (!split) metrics.append(node("strong", "", format(part.value)));
          metrics.append(node("span", "", `${split ? "" : percent(part.value, total) + "% · "}${part.hits.toLocaleString("ko-KR")}타격`));
          if (split && part.penetratingHits > 0 && part.penetratingValue != null)
            metrics.append(node("span", "", `관통 ${part.penetratingHits.toLocaleString("ko-KR")}타격 · ${format(part.penetratingValue)}`));
          row.append(info, metrics);
          if (split) {
            const effectCard = node("details", `raid-analysis-group composition-${key}`); effectCard.open = selected != null;
            if (color) effectCard.style.setProperty("--composition", color);
            const effectHeading = node("summary", "");
            effectHeading.append(node("strong", "", title), node("span", "", format(part.value)), node("span", "", `${percent(part.value, total)}%`));
            const effectBody = node("div", "raid-analysis-effects"); effectBody.append(row);
            effectCard.append(effectHeading, effectBody); output.append(effectCard);
          } else list.append(row);
        });
        if (!split) { details.append(list); output.append(details); }
        else if (key === "unknown") {
          const remainder = group.total - group.rows.reduce((sum, part) => sum + part.value, 0n);
          if (remainder > 0n) {
            heading.replaceChildren(node("strong", "", categories[key]), node("span", "", format(remainder)), node("span", "", `${percent(remainder, total)}%`));
            output.append(details);
          }
        }
      }
    }
    async function fetchAnalysis() {
      const request = ++generation; response = null; render();
      try {
        const next = await load(current.context.accountUid, current.row.battleUid);
        if (request !== generation || !current) return;
        response = next;
      } catch { if (request !== generation || !current) return; response = { status: "failed" }; }
      render();
    }
    function open(context, row, ordinal = null) {
      current = { context: { ...context }, row }; selected = ordinal; response = null;
      setView("composition");
      byId("raid-analysis-context").textContent = `${context.bossName || "보스"} · ${row.teamLabel || "덱 기록"}`;
      navigate("raid-analysis"); void fetchAnalysis();
    }
    function reset() { generation++; current = null; response = null; }
    byId("raid-analysis-back").addEventListener("click", () => { const previous = current; reset(); back(previous); });
    byId("raid-analysis-refresh").addEventListener("click", () => { if (current) void fetchAnalysis(); });
    byId("raid-analysis-split").addEventListener("change", render);
    for (const view of ["composition", "timeline"])
      byId(`raid-analysis-view-${view}`).addEventListener("click", () => setView(view));
    return { open, reset };
  }
  return { create };
})();
