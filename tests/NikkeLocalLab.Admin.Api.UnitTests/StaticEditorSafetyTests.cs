namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class StaticEditorSafetyTests
{
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
    Assert.Contains("stableOperationUid(saveAs ? \"edit-save-as\" : \"edit-save\")", script, StringComparison.Ordinal);
    Assert.Contains("stableOperationUid(\"import-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("rebaseRequest(state.rebaseDiffSha256, \"rebase-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("reviewRequest(state.reviewDiffSha256, \"review-apply\")", script, StringComparison.Ordinal);
    Assert.Contains("stableOperationUid(\"local-state-initialize\")", script, StringComparison.Ordinal);
    Assert.Equal(1, Count(script, "crypto.randomUUID()"));
    Assert.Contains("state.importDiffSha256 = null;", script, StringComparison.Ordinal);
    Assert.Contains("id=\"preview-review\"", html, StringComparison.Ordinal);
    Assert.Contains("/review/preview", script, StringComparison.Ordinal);
    Assert.Contains("review_override_coordinate_duplicate", script, StringComparison.Ordinal);
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
