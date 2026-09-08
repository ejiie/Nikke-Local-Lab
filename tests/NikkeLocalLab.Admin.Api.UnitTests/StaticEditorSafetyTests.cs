namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class StaticEditorSafetyTests
{
  [Fact]
  public void CubeCardsEditSharedInventoryWithoutCharacterEquipWrites()
  {
    var editor = Path.Combine(FindRepositoryRoot(), "src", "NikkeLocalLab.Admin.Api", "wwwroot", "editor");
    var html = File.ReadAllText(Path.Combine(editor, "index.html"));
    var script = File.ReadAllText(Path.Combine(editor, "editor.js"));
    Assert.True(html.IndexOf("cube-panel", StringComparison.Ordinal) > html.IndexOf("console-panel", StringComparison.Ordinal));
    Assert.Contains("id=\"account-cube-level\"", html, StringComparison.Ordinal);
    Assert.Contains("queueIntegerValue(\"account_cube_level\", selectedAccountCubeUid", script, StringComparison.Ordinal);
    Assert.Contains("querySelector(\".cube-effect\").textContent", script, StringComparison.Ordinal);
    Assert.Contains("primaryEffect", script, StringComparison.Ordinal);
    Assert.Contains("queueCubeInventory();", script, StringComparison.Ordinal);
  }

  [Fact]
  public void ConsoleCardsUseLocalArtworkAndPreserveConsoleEditCoordinates()
  {
    var editor = Path.Combine(FindRepositoryRoot(), "src", "NikkeLocalLab.Admin.Api", "wwwroot", "editor");
    var html = File.ReadAllText(Path.Combine(editor, "index.html"));
    var script = File.ReadAllText(Path.Combine(editor, "editor.js"));
    Assert.Contains("id=\"console-card-groups\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("console-chip-list", html + script, StringComparison.Ordinal);
    Assert.Contains("coordinates: [\"common\", \"attacker\", \"defender\", \"supporter\"]", script, StringComparison.Ordinal);
    Assert.Contains("coordinates: [\"elysion\", \"missilis\", \"tetra\", \"pilgrim\", \"abnormal\"]", script, StringComparison.Ordinal);
    Assert.Contains("/editor/assets/consoles/${code}.webp", script, StringComparison.Ordinal);
    Assert.Contains("effectiveProfileValue(\"console_level\", card.dataset.consoleUid)", script, StringComparison.Ordinal);
    Assert.Contains("이미지 없음", script, StringComparison.Ordinal);
    Assert.Contains("종류 미확인", script, StringComparison.Ordinal);
    Assert.Contains("renderConsoleCardState();", script, StringComparison.Ordinal);
    Assert.Contains("if (subjectUid) queueIntegerValue(fieldCode, subjectUid, value(id), 0);", script, StringComparison.Ordinal);
  }

  [Fact]
  public void EditorUsesOnlyLocalExternalAssetsAndSafeDomWrites()
  {
    var root = FindRepositoryRoot();
    var editor = Path.Combine(root, "src", "NikkeLocalLab.Admin.Api", "wwwroot", "editor");
    var html = File.ReadAllText(Path.Combine(editor, "index.html"));
    var script = File.ReadAllText(Path.Combine(editor, "editor.js"));
    var style = File.ReadAllText(Path.Combine(editor, "editor.css"));

    Assert.DoesNotContain("http://", html, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("https://", html, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("<script>", html, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("<style", html, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain(" style=", html, StringComparison.OrdinalIgnoreCase);
    Assert.Contains("src=\"/editor/editor.js\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("innerHTML", script, StringComparison.Ordinal);
    Assert.DoesNotContain("insertAdjacentHTML", script, StringComparison.Ordinal);
    Assert.DoesNotContain("localStorage", script, StringComparison.Ordinal);
    Assert.DoesNotContain("sessionStorage", script, StringComparison.Ordinal);
    Assert.DoesNotContain("eval(", script, StringComparison.Ordinal);
    Assert.Contains("textContent", script, StringComparison.Ordinal);
    Assert.Contains("id=\"jewel-balance\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"credit-balance\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("local_primary", html + script, StringComparison.Ordinal);
    Assert.Contains("currencyCode: \"jewel\"", script, StringComparison.Ordinal);
    Assert.Contains("currencyCode: \"credit\"", script, StringComparison.Ordinal);
    Assert.Contains("value=\"exact_decimal\"", html, StringComparison.Ordinal);
    Assert.Contains("operation.unscaledValue", script, StringComparison.Ordinal);
    Assert.Contains("state.lobbySelections", script, StringComparison.Ordinal);
    Assert.DoesNotContain("Number.parseInt", script, StringComparison.Ordinal);
    Assert.Contains("Number.isSafeInteger", script, StringComparison.Ordinal);
    Assert.Contains("wallet_balance_not_js_safe_integer", script, StringComparison.Ordinal);
    Assert.Contains("id=\"initialize-local-state\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"account-list\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"save-as-label\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-subject\"", html, StringComparison.Ordinal);
    Assert.Contains("data-tab=\"account\"", html, StringComparison.Ordinal);
    Assert.Contains("data-tab=\"nikkes\"", html, StringComparison.Ordinal);
    Assert.Contains("data-tab=\"raid\"", html, StringComparison.Ordinal);
    Assert.Contains("data-tab=\"import\"", html, StringComparison.Ordinal);
    Assert.Contains("data-tab=\"advanced\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-filter-burst\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-filter-manufacturer\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-filter-class\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-filter-element\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("id=\"launch-practice-26\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("id=\"launch-challenge-26\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"selected-boss-launch\"", html, StringComparison.Ordinal);
    foreach (var weaknessCode in new[] { "fire", "water", "wind", "electric", "iron" })
    {
      Assert.Contains($"data-weakness-code=\"{weaknessCode}\"", html,
          StringComparison.Ordinal);
      Assert.Contains($"/editor/assets/ui/code-{weaknessCode}.png", html,
          StringComparison.Ordinal);
    }
    Assert.Contains("id=\"selected-weakness-icon\"", html, StringComparison.Ordinal);
    Assert.Equal(2, Count(html, "data-boss-weakness-summary"));
    Assert.Equal(2, Count(html, "data-boss-weakness-icon"));
    Assert.Contains("renderBossWeaknessSummary();", script, StringComparison.Ordinal);
    Assert.Contains("마더 웨일</strong>", html, StringComparison.Ordinal);
    Assert.DoesNotContain("마더 웨일 변종", html, StringComparison.Ordinal);
    Assert.Contains("id=\"save-everything\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"save-as-everything\"", html, StringComparison.Ordinal);
    Assert.Contains("/workspace${saveAs ? \"/save-as\" : \"\"}", script,
        StringComparison.Ordinal);
    Assert.Contains(
        "byId(\"save-as-profile\").addEventListener(\"click\", () => run(\"Save As\", () => saveEverything(true)))",
        script,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "byId(\"save-as-profile\").addEventListener(\"click\", () => run(\"Save As\", () => saveProfile(true)))",
        script,
        StringComparison.Ordinal);
    Assert.Contains("expectedLobbyRevisionUid: state.lobbyRevisionUid", script,
        StringComparison.Ordinal);
    Assert.Contains("expectedWalletRevisionUid: state.walletRevisionUid", script,
        StringComparison.Ordinal);
    Assert.DoesNotContain("await saveProfile(saveAs);", script, StringComparison.Ordinal);
    Assert.Contains("id=\"nikke-detail\"", html, StringComparison.Ordinal);
    Assert.Contains("data-detail-tab=\"equipment\"", html, StringComparison.Ordinal);
    Assert.Contains("data-detail-tab=\"skill\"", html, StringComparison.Ordinal);
    Assert.Contains("data-detail-tab=\"collection\"", html, StringComparison.Ordinal);
    Assert.DoesNotContain("data-detail-tab=\"cube\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"account-import-uid\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"fetch-account-by-uid\"", html, StringComparison.Ordinal);
    Assert.Contains("/admin-api/v1/account-imports", script, StringComparison.Ordinal);
    Assert.Contains("detail_combat_power_observation", script, StringComparison.Ordinal);
    Assert.Contains("state.combatPowerByCharacter.get(right)", script, StringComparison.Ordinal);
    Assert.Contains("state.combatPowerByCharacter.has(left)", script, StringComparison.Ordinal);
    Assert.Contains("observedPower == null", script, StringComparison.Ordinal);
    Assert.Contains("aspect-ratio: 10 / 18", style, StringComparison.Ordinal);
    Assert.Contains("nikke-card-identity", script + style, StringComparison.Ordinal);
    Assert.Contains("nikke-card-unowned", script + style, StringComparison.Ordinal);
    Assert.Contains("보유 ${visibleOwnedCount} / 전체 ${visible.length}", script, StringComparison.Ordinal);
    Assert.Contains("core >= 1", script, StringComparison.Ordinal);
    Assert.Contains("currentCore > 0 ? 3 + currentCore : currentLimit", script, StringComparison.Ordinal);
    Assert.Contains(".nikke-card-body .core-evolve", style, StringComparison.Ordinal);
    Assert.Contains("color: #fff !important", style, StringComparison.Ordinal);
    Assert.Contains("equipment-picker-choice", script + style, StringComparison.Ordinal);
    Assert.Contains("[9, 10].includes(item.tier)", script, StringComparison.Ordinal);
    Assert.Contains("candidate.tier === 10", script, StringComparison.Ordinal);
    Assert.Contains("controlledValue: \"not_applicable\"", script, StringComparison.Ordinal);
    Assert.Contains("booleanValue: false", script, StringComparison.Ordinal);
    Assert.Contains("const equipmentSelectionOperations = [", script, StringComparison.Ordinal);
    Assert.Contains("fieldCode: `${prefix}.state`", script, StringComparison.Ordinal);
    Assert.Contains("controlledValue: \"equipped\"", script, StringComparison.Ordinal);
    Assert.Contains("fieldCode: `${prefix}.enhancement_level`", script, StringComparison.Ordinal);
    Assert.Contains("upsertProfileOperations(equipmentSelectionOperations);", script,
        StringComparison.Ordinal);
    Assert.Contains("enhancement.querySelector(\"input\").disabled = !definition;", script,
        StringComparison.Ordinal);
    Assert.Contains("item.favoriteCharacterUid === subjectUid", script, StringComparison.Ordinal);
    Assert.Contains("item.rarityCode === \"sr\"", script, StringComparison.Ordinal);
    Assert.Contains("srCollectionLevel15Stats(presentation.weaponCode)", script,
        StringComparison.Ordinal);
    Assert.Contains("const selectedLevel = Math.min(", script, StringComparison.Ordinal);
    Assert.Contains("fieldCode: \"collection.definition\"", script, StringComparison.Ordinal);
    Assert.Contains("fieldCode: \"collection.kind\"", script, StringComparison.Ordinal);
    Assert.Contains("fieldCode: \"collection.level\"", script, StringComparison.Ordinal);
    Assert.Contains("level.querySelector(\"input\").disabled = !definition;", script,
        StringComparison.Ordinal);
    Assert.DoesNotContain("collection-notice", script + style, StringComparison.Ordinal);
    Assert.Contains("elementGlyphs", script, StringComparison.Ordinal);
    Assert.Contains("unitLabel === \"%\" ? 100 : 1", script, StringComparison.Ordinal);
    Assert.Contains(
        "queueControlledValue(`${linePrefix}.unit`, subjectUid, \"ratio\")",
        script,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "queueControlledValue(`${linePrefix}.unit`, subjectUid, \"percent\")",
        script,
        StringComparison.Ordinal);
    Assert.Contains("/editor/presentation.json", script, StringComparison.Ordinal);
    Assert.Contains("이름 미확인 니케", script, StringComparison.Ordinal);
    Assert.Contains("공용 콘솔", script, StringComparison.Ordinal);
    Assert.Contains("/runtime-projection-candidate", script, StringComparison.Ordinal);
    Assert.Contains("/revisions", script, StringComparison.Ordinal);
    Assert.Contains("accountLabel: saveAs", script, StringComparison.Ordinal);
    Assert.Contains("/local-state", script, StringComparison.Ordinal);
    Assert.Contains("id=\"add-edit\"", html, StringComparison.Ordinal);
    Assert.Contains("state.editOperations", script, StringComparison.Ordinal);
    Assert.Contains("profile_edit_coordinate_duplicate", script, StringComparison.Ordinal);
    Assert.Contains("id=\"preview-rebase\"", html, StringComparison.Ordinal);
    Assert.Contains("/rebase/preview", script, StringComparison.Ordinal);
    Assert.Contains("id=\"load-bootstrap\"", html, StringComparison.Ordinal);
    Assert.Contains("/bootstrap", script, StringComparison.Ordinal);
    Assert.Contains("id=\"preview-create-import\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"create-from-import\"", html, StringComparison.Ordinal);
    Assert.Contains("/create/preview", script, StringComparison.Ordinal);
    Assert.Contains("scopes: [\"full_profile\"]", script, StringComparison.Ordinal);
    Assert.Contains("function stableOperationUid", script, StringComparison.Ordinal);
    Assert.Contains("function operationUidForRequest", script, StringComparison.Ordinal);
    Assert.Contains("operationUidForRequest(operationKey, request)", script,
        StringComparison.Ordinal);
    Assert.Contains("state.operationRequestFingerprints[key] !== fingerprint", script,
        StringComparison.Ordinal);
    Assert.Contains("stableOperationUid(saveAs ? \"edit-save-as\" : \"edit-save\")", script, StringComparison.Ordinal);
    Assert.Contains("stableOperationUid(\"import-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("rebaseRequest(state.rebaseDiffSha256, \"rebase-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("reviewRequest(state.reviewDiffSha256, \"review-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("stableOperationUid(\"local-state-initialize\")", script, StringComparison.Ordinal);
    Assert.Contains("id=\"fetched-lobby-commander\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"preview-fetched-lobby\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"apply-fetched-lobby\"", html, StringComparison.Ordinal);
    Assert.Contains("/lobby/diff", script, StringComparison.Ordinal);
    Assert.Contains("/lobby/apply", script, StringComparison.Ordinal);
    Assert.Contains("fields: selectedFetchedLobbyFields()", script, StringComparison.Ordinal);
    Assert.Contains("expectedDiffSha256: state.fetchedLobbyDiffSha256", script, StringComparison.Ordinal);
    Assert.Equal(1, Count(script, "crypto.randomUUID()"));
    Assert.Contains("state.importDiffSha256 = null;", script, StringComparison.Ordinal);
    Assert.Contains("id=\"preview-review\"", html, StringComparison.Ordinal);
    Assert.Contains("/review/preview", script, StringComparison.Ordinal);
    Assert.Contains("review_override_coordinate_duplicate", script, StringComparison.Ordinal);
    Assert.Contains("id=\"launch-game\"", html, StringComparison.Ordinal);
    Assert.Contains("id=\"launch-season\"", html, StringComparison.Ordinal);
    Assert.Contains("value=\"26\"", html, StringComparison.Ordinal);
    Assert.Contains("/admin-api/v1/executions", script, StringComparison.Ordinal);
    Assert.Contains("/executions/${encodeURIComponent(state.launchContextUid)}", script, StringComparison.Ordinal);
    Assert.Contains("validationKind: value(\"launch-kind\")", script, StringComparison.Ordinal);
    Assert.Contains("weaknessCode: state.selectedWeaknessCode", script,
        StringComparison.Ordinal);
    Assert.Contains("selectWeaknessCode(button.dataset.weaknessCode)", script,
        StringComparison.Ordinal);
    Assert.DoesNotContain("http://", script + style, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("https://", script + style, StringComparison.OrdinalIgnoreCase);
  }

  private static int Count(string value, string needle)
  {
    var count = 0;
    var offset = 0;
    while ((offset = value.IndexOf(needle, offset, StringComparison.Ordinal)) >= 0)
    {
      count++;
      offset += needle.Length;
    }

    return count;
  }

  private static string FindRepositoryRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null && !File.Exists(Path.Combine(current.FullName, "NikkeLocalLab.sln")))
    {
      current = current.Parent;
    }

    return current?.FullName ?? throw new InvalidOperationException("repository_root_not_found");
  }
}
