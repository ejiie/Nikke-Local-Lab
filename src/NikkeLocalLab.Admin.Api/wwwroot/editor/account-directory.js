"use strict";

// The member layout follows the operator-supplied Blablalink reference.
window.NllAccountDirectory = (() => {
  const pref = (name) => { try { return localStorage.getItem(`nll.${name}`) === "1"; } catch { return false; } };
  const remember = (name, checked) => { try { if (checked) localStorage.setItem(`nll.${name}`, "1"); } catch { /* Optional preference. */ } };
  function node(tag, text, className) {
    const item = document.createElement(tag);
    if (text != null) item.textContent = text;
    if (className) item.className = className;
    return item;
  }
  function image(path, alt, className) {
    const img = node("img", null, className); img.alt = alt;
    img.src = typeof path === "string" && /^\/(editor\/assets|admin-api\/v1\/account-art)\//.test(path)
      ? path : "/editor/assets/ui/default-account.png";
    return img;
  }
  function dialog(title, wide = false) {
    const box = node("dialog", null, `account-dialog${wide ? " union-members-dialog" : ""}`);
    const heading = node("h2", title);
    box.setAttribute("aria-label", title);
    box.append(heading); document.body.append(box);
    box.addEventListener("close", () => box.remove(), { once: true });
    return box;
  }
  function renderAvatar(container, member) {
    const portrait = image(member?.portraitPath, "대표 사진", "member-portrait");
    portrait.addEventListener("error", () => { portrait.src = "/editor/assets/ui/default-account.png"; }, { once: true });
    container.replaceChildren(portrait);
    container.classList.remove("has-profile-frame");
    if (member?.framePath && /^\/(editor\/assets|admin-api\/v1\/account-art)\//.test(member.framePath)) {
      const frame = image(member.framePath, "착용 테두리", "member-frame");
      container.classList.add("has-profile-frame");
      frame.addEventListener("error", () => { frame.remove(); container.classList.remove("has-profile-frame"); }, { once: true });
      container.append(frame);
    }
  }
  function button(text, action, primary = false) {
    const value = node("button", text, primary ? "primary" : "ghost");
    value.type = "button"; value.addEventListener("click", action); return value;
  }
  async function confirm(text, { yes = "확인", no = "취소", preference } = {}) {
    if (preference && pref(preference)) return true;
    return new Promise(resolve => {
      const box = dialog(text), actions = node("div", null, "action-row");
      const check = node("input"); check.type = "checkbox";
      actions.append(button(yes, () => { if (preference) remember(preference, check.checked); resolve(true); box.close(); }, true));
      if (no) actions.append(button(no, () => { resolve(false); box.close(); }));
      box.append(actions);
      if (preference) { const label = node("label", null, "dialog-remember"); label.append(check, document.createTextNode("다시 보지 않기")); box.append(label); }
      box.addEventListener("cancel", () => resolve(false), { once: true });
      box.showModal();
    });
  }
  async function create({ api, reload, select }) {
    if (!await confirm("계정을 생성하시겠습니까?", { yes: "예", no: "아니오" })) return;
    const box = dialog("계정 만들기"), form = node("form"), error = node("p", null, "dialog-error");
    const name = node("input"), label = node("input");
    name.required = label.required = true; name.maxLength = 32; label.maxLength = 64;
    name.autocomplete = label.autocomplete = "off";
    for (const [text, input] of [["닉네임", name], ["관리용 계정 이름", label]]) {
      const field = node("label", text); field.append(input); form.append(field);
    }
    const actions = node("div", null, "action-row"), submit = node("button", "확인", "primary");
    submit.type = "submit"; actions.append(submit, button("취소", () => box.close()));
    error.setAttribute("role", "alert"); form.append(error, actions); box.append(form);
    let request = null;
    form.addEventListener("submit", async event => {
      event.preventDefault(); if (submit.disabled) return;
      submit.disabled = true; error.textContent = "";
      request ??= { operationUid: crypto.randomUUID(), createdAtUtc: new Date().toISOString(), displayName: name.value.trim(), accountLabel: label.value.trim() };
      name.disabled = label.disabled = true;
      try {
        const result = await api("/admin-api/v1/accounts/create", { method: "POST", body: request });
        await reload(); await select(result.payload.accountUid); box.close();
        await confirm("계정이 생성되었습니다.", { no: null, preference: "hide-account-created" });
      } catch (failure) { error.textContent = `계정을 생성하지 못했습니다. ${failure.message} 같은 요청으로 다시 시도하거나 취소할 수 있습니다.`; }
      finally { submit.disabled = false; }
    });
    box.showModal(); name.focus();
  }
  function render({ list, unions, accounts, lobbies, selected, select, profile }) {
    list.replaceChildren();
    for (const union of unions) {
      const li = node("li"), card = button("", () => members(union));
      card.dataset.unionUid = union.unionUid;
      card.setAttribute("aria-current", String(union.members.some(m => m.accountUid === selected)));
      const names = node("span", null, "account-name-group"), level = node("span", null, "account-level");
      names.append(node("strong", union.name), node("span", `ID: ${union.displayId}`));
      level.append(node("span", "유니온 Lv."), node("strong", String(union.level)));
      card.append(image(union.emblemPath || "/editor/assets/ui/default-union.png", "유니온 엠블럼", "union-emblem"), names, level);
      li.append(card); list.append(li);
    }
    if (!unions.length) list.append(node("li", "계정을 만들면 소속 유니온이 표시됩니다.", "directory-empty"));
    function members(union) {
      const box = dialog("유니온 멤버", true), heading = box.querySelector("h2");
      heading.prepend(button("‹", () => box.close()));
      const icon = node("span", "👥", "members-heading-icon"); heading.insertBefore(icon, heading.lastChild);
      box.append(node("p", "리스트를 클릭하여 해당 멤버의 계정을 선택할 수 있습니다.", "members-instruction"));
      const rows = node("div", null, "union-member-list"); box.append(rows);
      for (const member of union.members) {
        const account = accounts.find(a => a.accountUid === member.accountUid); if (!account) continue;
        const lobby = lobbies.get(member.accountUid), row = button("", async () => {
          row.disabled = true;
          try { await select(member.accountUid); box.close(); }
          catch (error) { status.textContent = `계정 선택 실패: ${error.message}`; row.disabled = false; }
        });
        row.className = "union-member-row"; row.dataset.accountUid = member.accountUid;
        const avatar = node("span", null, "member-avatar");
        renderAvatar(avatar, member);
        const badge = node("span", "싱크로 레벨: …", "member-synchro"), arrow = node("span", "›", "member-chevron");
        row.append(avatar, node("strong", lobby?.displayName || account.accountLabel, "member-name"), badge, arrow); rows.append(row);
        profile(member.accountUid).then(value => {
          const synchro = value.values?.find(v => v.fieldCode === "synchro_level")?.integerValue;
          badge.textContent = `싱크로 레벨: ${synchro ?? "미확인"}`;
        }).catch(() => { badge.textContent = "싱크로 레벨: 미확인"; });
      }
      const status = node("p", null, "dialog-error"); status.setAttribute("role", "status"); box.append(status);
      box.showModal();
    }
  }
  return { create, render, confirm, renderAvatar };
})();
