import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from playwright.sync_api import sync_playwright


class PreviewHandler(BaseHTTPRequestHandler):
    editor_root: Path
    asset_root: Path

    def do_GET(self) -> None:
        path = unquote(urlparse(self.path).path)
        routes = {
            "/editor/": (self.editor_root / "index.html", "text/html; charset=utf-8"),
            "/editor/editor.css": (self.editor_root / "editor.css", "text/css; charset=utf-8"),
            "/editor/editor.js": (self.editor_root / "editor.js", "text/javascript; charset=utf-8"),
        }
        member = routes.get(path)
        asset_types = {
            "characters": "image/png",
            "bosses": "image/png",
            "ui": "image/png",
            "equipment": "image/webp",
            "collections": "image/webp",
        }
        if member is None and path.startswith("/editor/assets/"):
            parts = Path(path).parts
            if len(parts) >= 4 and parts[-2] in asset_types:
                member = (
                    self.asset_root / parts[-2] / parts[-1],
                    asset_types[parts[-2]],
                )
        if member is None or not member[0].is_file():
            self.send_error(404)
            return
        payload = member[0].read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", member[1])
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args: object) -> None:
        return


def profile_integer(field_code: str, subject_uid: str | None, value: int) -> dict:
    return {
        "fieldCode": field_code,
        "subjectUid": subject_uid,
        "valueKind": "integer",
        "integerValue": value,
        "booleanValue": None,
        "referenceUid": None,
        "unscaledValue": None,
        "decimalScale": None,
        "controlledValue": None,
    }


def profile_reference(field_code: str, subject_uid: str, value: str) -> dict:
    result = profile_integer(field_code, subject_uid, 0)
    result.update(valueKind="reference", integerValue=None, referenceUid=value)
    return result


def profile_controlled(field_code: str, subject_uid: str, value: str) -> dict:
    result = profile_integer(field_code, subject_uid, 0)
    result.update(valueKind="controlled", integerValue=None, controlledValue=value)
    return result


def profile_exact(field_code: str, subject_uid: str, value: int, scale: int) -> dict:
    result = profile_integer(field_code, subject_uid, 0)
    result.update(
        valueKind="exact_decimal",
        integerValue=None,
        unscaledValue=value,
        decimalScale=scale,
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--install-root", type=Path, default=Path(r"C:\NLL\ControlCenter"))
    parser.add_argument("--port", type=int, default=18787)
    args = parser.parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)

    editor_root = args.install_root / "app" / "wwwroot" / "editor"
    presentation_path = editor_root / "presentation.json"
    presentation = json.loads(presentation_path.read_text(encoding="utf-8"))
    values: list[dict] = [profile_integer("synchro_level", None, 773)]
    unowned_uid = presentation["characters"][-1]["characterUid"]
    for index, character in enumerate(presentation["characters"]):
        uid = character["characterUid"]
        if uid == unowned_uid:
            continue
        values.extend(
            [
                profile_integer("character_level", uid, 773),
                profile_integer("limit_break", uid, index % 4),
                profile_integer("core_level", uid, (index % 8) if index % 4 == 3 else 0),
                profile_integer("bond_level", uid, 40),
                profile_integer("skill_1_level", uid, 10),
                profile_integer("skill_2_level", uid, 10),
                profile_integer("burst_level", uid, 10),
            ]
        )

    selected = next(
        item for item in presentation["characters"] if item["displayName"] == "레드 후드"
    )
    selected_uid = selected["characterUid"]
    equipment = [item for item in presentation["supportDefinitions"] if item["kindCode"] == "equipment"]
    selected_equipment = []
    for slot in ("head", "torso", "arms", "legs"):
        selected_equipment.append(
            next(
                item
                for item in equipment
                if item.get("slotCode") == slot
                and item.get("combatClassCode") == selected["combatClassCode"]
                and item.get("tier") == 10
            )
        )
    overload = presentation["overloadOptions"]
    fixture_levels = (9, 12, 13, 14, 15, 11, 8, 7, 6, 5, 4, 3)
    for index, slot in enumerate(("head", "torso", "arms", "legs")):
        prefix = f"equipment.{slot}"
        values.extend(
            [
                profile_reference(
                    f"{prefix}.definition",
                    selected_uid,
                    selected_equipment[index]["definitionUid"],
                ),
                profile_integer(f"{prefix}.enhancement_level", selected_uid, 5),
            ]
        )
        for line in range(1, 4):
            option = overload[(index * 3 + line - 1) % len(overload)]
            legal_values = sorted(
                option["legalValues"],
                key=lambda item: item["unscaledValue"] / (10 ** item["decimalScale"]),
            )
            legal = legal_values[fixture_levels[index * 3 + line - 1] - 1]
            line_prefix = f"{prefix}.overload.{line}"
            values.extend(
                [
                    profile_controlled(f"{line_prefix}.state", selected_uid, "present"),
                    profile_reference(f"{line_prefix}.definition", selected_uid, option["definitionUid"]),
                    profile_controlled(f"{line_prefix}.unit", selected_uid, "percent"),
                    profile_exact(
                        f"{line_prefix}.value",
                        selected_uid,
                        legal["unscaledValue"],
                        legal["decimalScale"],
                    ),
                ]
            )

    collection = next(
        item
        for item in presentation["supportDefinitions"]
        if item["kindCode"] in ("collection", "favorite")
        and (not item.get("weaponCode") or item.get("weaponCode") == selected["weaponCode"])
    )
    values.extend(
        [
            profile_controlled(
                "collection.kind",
                selected_uid,
                "favorite" if collection["kindCode"] == "favorite" else "generic_collection",
            ),
            profile_reference("collection.definition", selected_uid, collection["definitionUid"]),
            profile_integer("collection.level", selected_uid, 15),
        ]
    )

    PreviewHandler.editor_root = editor_root
    PreviewHandler.asset_root = editor_root / "assets"
    server = ThreadingHTTPServer(("127.0.0.1", args.port), PreviewHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True)
            page = browser.new_page(viewport={"width": 1478, "height": 925}, device_scale_factor=1)
            page.goto(f"http://127.0.0.1:{args.port}/editor/", wait_until="networkidle")
            page.evaluate(
                """([catalog, values]) => {
                  document.getElementById('app-shell').inert = false;
                  state.presentation = catalog;
                  state.presentationByCharacter = new Map(catalog.characters.map((item) => [item.characterUid, item]));
                  state.presentationByConsole = new Map(catalog.consoles.map((item) => [item.definitionUid, item]));
                  state.presentationBySupport = new Map(catalog.supportDefinitions.map((item) => [item.definitionUid, item]));
                  state.presentationByOverload = new Map(catalog.overloadOptions.map((item) => [item.definitionUid, item]));
                  state.currentProfile = { values };
                  state.combatPowerByCharacter = new Map(catalog.characters.map((item, index) => [item.characterUid, 900000 - index * 2117]));
                  renderNikkeEditor();
                  setPage('nikkes');
                }""",
                [presentation, values],
            )
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            page.wait_for_timeout(500)
            page.evaluate("window.scrollTo(0, 0)")
            page.wait_for_timeout(500)
            catalog_card_count = page.locator(".nikke-card").count()
            unowned_card_count = page.locator(".nikke-card-unowned").count()
            if catalog_card_count != len(presentation["characters"]):
                raise RuntimeError(
                    "phase_d_character_catalog_incomplete:"
                    f"expected={len(presentation['characters'])}:observed={catalog_card_count}"
                )
            if unowned_card_count != 1:
                raise RuntimeError(
                    f"phase_d_unowned_character_projection_invalid:{unowned_card_count}"
                )
            zero_core_uid = presentation["characters"][0]["characterUid"]
            positive_core_uid = presentation["characters"][3]["characterUid"]
            zero_core_badges = page.locator(
                f'.nikke-card[data-character-uid="{zero_core_uid}"] .core-evolve'
            ).count()
            positive_core_text = page.locator(
                f'.nikke-card[data-character-uid="{positive_core_uid}"] .core-evolve'
            ).text_content()
            if zero_core_badges != 0 or positive_core_text != "3":
                raise RuntimeError(
                    "phase_d_list_core_visibility_invalid:"
                    f"zero={zero_core_badges}:positive={positive_core_text}"
                )
            positive_core_style = page.locator(
                f'.nikke-card[data-character-uid="{positive_core_uid}"] .core-evolve'
            ).evaluate(
                """element => {
                  const style = getComputedStyle(element);
                  const badge = element.getBoundingClientRect();
                  const star = element.previousElementSibling.getBoundingClientRect();
                  return {
                    color: style.color,
                    display: style.display,
                    marginTop: style.marginTop,
                    badgeCenterY: badge.top + badge.height / 2,
                    starCenterY: star.top + star.height / 2,
                    centerDeltaY: Math.abs(
                      (badge.top + badge.height / 2) - (star.top + star.height / 2)),
                  };
                }"""
            )
            if (
                positive_core_style["color"] != "rgb(255, 255, 255)"
                or positive_core_style["display"] != "grid"
                or positive_core_style["marginTop"] != "0px"
                or positive_core_style["centerDeltaY"] > 0.75
            ):
                raise RuntimeError(
                    f"phase_d_list_core_badge_style_invalid:{positive_core_style}"
                )
            card_footer_background = page.locator(
                ".nikke-card:not(.nikke-card-unowned) .nikke-card-body"
            ).first.evaluate("element => getComputedStyle(element).backgroundImage")
            if "20, 22, 25" in card_footer_background or "23, 25, 29" in card_footer_background:
                raise RuntimeError(
                    f"phase_d_character_card_black_overlay_present:{card_footer_background}"
                )
            page.screenshot(path=args.output_root / "nikke-catalog.png", full_page=False)
            page.evaluate(
                """() => {
                  const first = '11111111-1111-4111-8111-111111111111';
                  const second = '22222222-2222-4222-8222-222222222222';
                  state.accounts = [
                    { accountUid: first, accountLabel: '메인 계정', validationStatusCode: 'ready', profileRevision: { revisionNumber: 3 } },
                    { accountUid: second, accountLabel: '실험 계정', validationStatusCode: 'ready', profileRevision: { revisionNumber: 1 } }
                  ];
                  state.accountUid = first;
                  state.accountLobbyByUid = new Map([
                    [first, { displayName: '테스트 지휘관 A', commanderLevel: 100 }],
                    [second, { displayName: '테스트 지휘관 B', commanderLevel: 200 }]
                  ]);
                  renderAccounts();
                  document.getElementById('top-account-name').textContent = '테스트 지휘관 A';
                  document.getElementById('top-account-detail').textContent = '메인 계정';
                  setPage('home');
                }"""
            )
            page.screenshot(path=args.output_root / "home.png", full_page=False)
            page.evaluate("setPage('raid')")
            page.screenshot(path=args.output_root / "solo-raid.png", full_page=False)
            page.evaluate("setPage('nikkes')")
            growth_uid = presentation["characters"][0]["characterUid"]
            page.evaluate("uid => openNikkeDetail(uid)", growth_uid)
            for _ in range(4):
                page.locator(".core-stepper button").last.click()
            growth_after_increment = page.evaluate(
                """uid => ({
                  limit: effectiveProfileValue('limit_break', uid)?.integerValue,
                  core: effectiveProfileValue('core_level', uid)?.integerValue
                })""",
                growth_uid,
            )
            if growth_after_increment != {"limit": 3, "core": 1}:
                raise RuntimeError(
                    f"phase_d_growth_increment_sequence_invalid:{growth_after_increment}"
                )
            for _ in range(4):
                page.locator(".core-stepper button").first.click()
            growth_after_decrement = page.evaluate(
                """uid => ({
                  limit: effectiveProfileValue('limit_break', uid)?.integerValue,
                  core: effectiveProfileValue('core_level', uid)?.integerValue
                })""",
                growth_uid,
            )
            if growth_after_decrement != {"limit": 0, "core": 0}:
                raise RuntimeError(
                    f"phase_d_growth_decrement_sequence_invalid:{growth_after_decrement}"
                )
            page.locator(".equipment-icon").first.click()
            picker_tiers = page.locator(
                ".equipment-card:first-of-type .equipment-picker-choice b"
            ).all_text_contents()
            if picker_tiers != ["9티어", "10티어"]:
                raise RuntimeError(
                    f"phase_d_equipment_picker_tiers_invalid:{picker_tiers}"
                )
            page.screenshot(
                path=args.output_root / "nikke-detail-equipment-picker.png",
                full_page=False,
            )
            page.locator(
                ".equipment-card:first-of-type .equipment-picker-choice"
            ).first.click()
            selected_growth_equipment = page.evaluate(
                """uid => {
                  const definition = effectiveProfileValue('equipment.head.definition', uid)?.referenceUid;
                  return state.presentationBySupport.get(definition)?.tier;
                }""",
                growth_uid,
            )
            if selected_growth_equipment != 9:
                raise RuntimeError(
                    f"phase_d_equipment_picker_selection_invalid:{selected_growth_equipment}"
                )
            (args.output_root / "growth-equipment-observation.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "catalogCharacterCount": catalog_card_count,
                        "unownedCharacterCount": unowned_card_count,
                        "zeroCoreBadgeHidden": zero_core_badges == 0,
                        "positiveCoreBadgeText": positive_core_text,
                        "positiveCoreBadgeStyle": positive_core_style,
                        "cardFooterBackground": card_footer_background,
                        "growthAfterFourIncrements": growth_after_increment,
                        "growthAfterFourDecrements": growth_after_decrement,
                        "equipmentPickerTiers": picker_tiers,
                        "selectedEquipmentTier": selected_growth_equipment,
                        "verified": True,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            page.evaluate("uid => openNikkeDetail(uid)", selected_uid)
            first_equipment_base_stats = [
                int(str(item["value"]).replace(",", ""))
                for item in selected_equipment[0]["stats"]
                if item["label"] != "능력치" or item["value"] != "0"
            ]
            expected_enhanced_stats = [
                (base_value * 15 + 5) // 10 for base_value in first_equipment_base_stats
            ]
            observed_enhanced_stats = [
                int(value.replace(",", ""))
                for value in page.locator(
                    ".equipment-card:first-of-type .equipment-stat-rows strong"
                ).all_text_contents()
            ]
            if observed_enhanced_stats != expected_enhanced_stats:
                raise RuntimeError(
                    "phase_d_equipment_enhancement_stat_projection_invalid:"
                    f"expected={expected_enhanced_stats}:observed={observed_enhanced_stats}"
                )
            first_enhancement_input = page.locator(
                ".equipment-card:first-of-type .equipment-enhancement input"
            )
            first_enhancement_input.fill("0")
            first_enhancement_input.dispatch_event("change")
            observed_base_stats = [
                int(value.replace(",", ""))
                for value in page.locator(
                    ".equipment-card:first-of-type .equipment-stat-rows strong"
                ).all_text_contents()
            ]
            if observed_base_stats != first_equipment_base_stats:
                raise RuntimeError(
                    "phase_d_equipment_base_stat_projection_invalid:"
                    f"expected={first_equipment_base_stats}:observed={observed_base_stats}"
                )
            first_enhancement_input = page.locator(
                ".equipment-card:first-of-type .equipment-enhancement input"
            )
            first_enhancement_input.fill("5")
            first_enhancement_input.dispatch_event("change")
            restored_enhanced_stats = [
                int(value.replace(",", ""))
                for value in page.locator(
                    ".equipment-card:first-of-type .equipment-stat-rows strong"
                ).all_text_contents()
            ]
            if restored_enhanced_stats != expected_enhanced_stats:
                raise RuntimeError("phase_d_equipment_enhancement_rerender_invalid")
            (args.output_root / "equipment-enhancement-observation.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "formulaCode": "round_half_up(base_stat*(1+level*0.10))",
                        "enhancementLevel": 5,
                        "baseStats": first_equipment_base_stats,
                        "observedAtLevel0": observed_base_stats,
                        "expectedStats": expected_enhanced_stats,
                        "observedStats": observed_enhanced_stats,
                        "restoredAtLevel5": restored_enhanced_stats,
                        "verified": True,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            overload_style_observation = page.locator(".overload-row").evaluate_all(
                """rows => rows.map((row) => {
                  const option = row.querySelector(':scope > select');
                  const amount = row.querySelector('label select');
                  const rowStyle = getComputedStyle(row);
                  const optionStyle = getComputedStyle(option);
                  const amountStyle = getComputedStyle(amount);
                  return {
                    className: row.className,
                    optionText: option.options[option.selectedIndex]?.textContent || '',
                    amountText: amount.options[amount.selectedIndex]?.textContent || '',
                    rowBackgroundColor: rowStyle.backgroundColor,
                    optionColor: optionStyle.color,
                    amountColor: amountStyle.color,
                  };
                })"""
            )
            (args.output_root / "overload-style-observation.json").write_text(
                json.dumps(overload_style_observation, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            page.screenshot(path=args.output_root / "nikke-detail-equipment.png", full_page=True)
            page.click('[data-detail-tab="collection"]')
            collection_stats_text = page.locator("#collection-editor .collection-stats").text_content()
            collection_notice_count = page.locator("#collection-editor .collection-notice").count()
            if "공격력" not in collection_stats_text or "방어력" not in collection_stats_text:
                raise RuntimeError(
                    f"phase_d_collection_stat_label_invalid:{collection_stats_text}"
                )
            if collection_notice_count != 0:
                raise RuntimeError(
                    f"phase_d_collection_unlock_notice_present:{collection_notice_count}"
                )
            page.screenshot(path=args.output_root / "nikke-detail-collection.png", full_page=True)
            favorite_support = next(
                item
                for item in presentation["supportDefinitions"]
                if item["kindCode"] == "favorite" and item.get("favoriteCharacterUid")
            )
            favorite_character_uid = favorite_support["favoriteCharacterUid"]
            favorite_character = next(
                item
                for item in presentation["characters"]
                if item["characterUid"] == favorite_character_uid
            )
            page.evaluate("uid => openNikkeDetail(uid)", favorite_character_uid)
            favorite_options = page.locator("#collection-editor select option").evaluate_all(
                """options => options
                  .map(option => state.presentationBySupport.get(option.value))
                  .filter(item => item?.kindCode === 'favorite')
                  .map(item => ({
                    definitionUid: item.definitionUid,
                    favoriteCharacterUid: item.favoriteCharacterUid,
                  }))"""
            )
            expected_favorite_uids = sorted(
                item["definitionUid"]
                for item in presentation["supportDefinitions"]
                if item["kindCode"] == "favorite"
                and item.get("favoriteCharacterUid") == favorite_character_uid
            )
            observed_favorite_uids = sorted(
                item["definitionUid"] for item in favorite_options
            )
            if (
                observed_favorite_uids != expected_favorite_uids
                or any(
                    item["favoriteCharacterUid"] != favorite_character_uid
                    for item in favorite_options
                )
            ):
                raise RuntimeError(
                    "phase_d_favorite_character_filter_invalid:"
                    f"expected={expected_favorite_uids}:observed={favorite_options}"
                )
            page.locator("#collection-editor select").select_option(
                favorite_support["definitionUid"]
            )
            favorite_description = page.locator(
                "#collection-editor .collection-header p"
            ).text_content()
            if favorite_description != f"{favorite_character['displayName']} 전용 애장품":
                raise RuntimeError(
                    f"phase_d_favorite_description_invalid:{favorite_description}"
                )
            favorite_stats_text = page.locator(
                "#collection-editor .collection-stats"
            ).text_content()
            sr_collections = [
                item
                for item in presentation["supportDefinitions"]
                if item["kindCode"] == "collection"
                and item.get("rarityCode") == "sr"
                and item.get("weaponCode") == favorite_character["weaponCode"]
            ]
            if len(sr_collections) != 1:
                raise RuntimeError(
                    "phase_d_sr_collection_coordinate_invalid:"
                    f"weapon={favorite_character['weaponCode']}:count={len(sr_collections)}"
                )
            sr_level_15 = next(
                (
                    item
                    for item in sr_collections[0].get("levels", [])
                    if item.get("level") == 15
                ),
                None,
            )
            if sr_level_15 is None:
                raise RuntimeError(
                    "phase_d_sr_collection_level_15_missing:"
                    f"weapon={favorite_character['weaponCode']}"
                )
            expected_favorite_stats_text = " · ".join(
                f"{item['label']} {item['value']}" for item in sr_level_15["stats"]
            )
            if favorite_stats_text != expected_favorite_stats_text:
                raise RuntimeError(
                    "phase_d_favorite_stats_not_sr_level_15:"
                    f"expected={expected_favorite_stats_text}:observed={favorite_stats_text}"
                )
            page.screenshot(
                path=args.output_root / "nikke-detail-favorite-filter.png",
                full_page=True,
            )
            nonfavorite_character = next(
                item
                for item in presentation["characters"]
                if not any(
                    support["kindCode"] == "favorite"
                    and support.get("favoriteCharacterUid") == item["characterUid"]
                    for support in presentation["supportDefinitions"]
                )
            )
            page.evaluate("uid => openNikkeDetail(uid)", nonfavorite_character["characterUid"])
            nonfavorite_option_count = page.locator(
                "#collection-editor select option"
            ).evaluate_all(
                """options => options
                  .map(option => state.presentationBySupport.get(option.value))
                  .filter(item => item?.kindCode === 'favorite').length"""
            )
            if nonfavorite_option_count != 0:
                raise RuntimeError(
                    "phase_d_nonfavorite_character_favorite_option_present:"
                    f"{nonfavorite_option_count}"
                )
            (args.output_root / "collection-filter-observation.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "collectionStatsText": collection_stats_text,
                        "unlockNoticeCount": collection_notice_count,
                        "favoriteCharacterUid": favorite_character_uid,
                        "favoriteCharacterName": favorite_character["displayName"],
                        "favoriteStatsText": favorite_stats_text,
                        "expectedSrLevel15StatsText": expected_favorite_stats_text,
                        "expectedFavoriteDefinitionUids": expected_favorite_uids,
                        "observedFavoriteOptions": favorite_options,
                        "nonfavoriteCharacterUid": nonfavorite_character["characterUid"],
                        "nonfavoriteFavoriteOptionCount": nonfavorite_option_count,
                        "verified": True,
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
