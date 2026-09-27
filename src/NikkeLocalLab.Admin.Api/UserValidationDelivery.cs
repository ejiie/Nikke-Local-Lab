using System.Text.Json;
using static NikkeLocalLab.Admin.Api.FilesystemBossSeasonCatalogService;

namespace NikkeLocalLab.Admin.Api;

public sealed record UserValidationSelection(string WeaknessCode, Guid AssessmentUid, string EntrySha256);
public sealed record UserValidationDeliveryView(int SchemaVersion, string ContractId, int SeasonNumber,
    string StatusCode, string? FailureCode, string? BindingSha256, UserValidationSelection[] Selections,
    bool ActualGameAcceptanceClaimed = false);

// This is a handoff for USER testing, not operational registry admission. Read
// only small sealed plans/tools here; the elevated controller rechecks the whole
// current client and OS immediately before making any changes or starting it.
public sealed class UserValidationDelivery(string manifestPath, string manifestSha256,
    Func<string, int, byte[]>? reader = null)
{
  private readonly Func<string, int, byte[]> read = reader ?? ReadFile;
  internal sealed record Bound(UserValidationDeliveryView View, string TrialUid, string DefaultWeaknessCode, string ProfileSha256,
      string CandidateReceiptSha256, string PowerShellPath, string PowerShellSha256,
      IReadOnlyDictionary<string, (string RunRoot, string ControllerPath)> Entries);
  public UserValidationDeliveryView Get(int season)
  {
    try
    {
      var bound = ReadBound(); Require(bound.View.SeasonNumber == season); return bound.View;
    }
    catch (Exception error) when (IsReadFailure(error))
    {
      return new(1, "nll/user-validation-delivery-view/v1", season, "blocked", "boss_validation_delivery_unavailable", null, []);
    }
  }
  internal Bound ReadBound()
  {
    using var document = Pinned(manifestPath, manifestSha256, 65536);
    var root = document.RootElement;
    Require(root.GetProperty("schemaVersion").GetInt32() == 1 && root.GetProperty("contractId").GetString() == "nll/user-validation-delivery/v1" &&
        root.GetProperty("statusCode").GetString() == "awaiting_game_validation" &&
        !root.GetProperty("nativeClientExecuted").GetBoolean() && !root.GetProperty("actualGameAcceptanceClaimed").GetBoolean());
    var season = root.GetProperty("seasonNumber").GetInt32(); Require(season is >= 1 and <= 1000);
    var trial = Uid(root.GetProperty("trialUid").GetString());
    var trialRoot = @"C:\NLL\Staging\NativeFxUserValidation\" + trial;
    var profileHash = root.GetProperty("profileSha256").GetString()!;
    var candidateHash = root.GetProperty("candidateReceiptSha256").GetString()!;
    Require(IsHash(profileHash) && IsHash(candidateHash));
    using var profile = PinObject(root.GetProperty("profile"), 1048576);
    var p = profile.RootElement;
    var defaultWeakness = p.GetProperty("sourceAffinity").GetProperty("weaknessCode").GetString()!;
    Require(root.GetProperty("profile").GetProperty("sha256").GetString() == profileHash &&
        p.GetProperty("schemaVersion").GetInt32() == 3 && p.GetProperty("contractId").GetString() == "nll/boss-runtime-variant-profile/v3" &&
        p.GetProperty("seasonNumber").GetInt32() == season && IsWeakness(defaultWeakness));
    using var candidate = PinObject(root.GetProperty("candidateReceipt"), 1048576);
    var c = candidate.RootElement;
    Require(root.GetProperty("candidateReceipt").GetProperty("sha256").GetString() == candidateHash &&
        c.GetProperty("contractId").GetString() == "nll/boss-onboarding-verified-candidate/v1" &&
        c.GetProperty("seasonNumber").GetInt32() == season && c.GetProperty("profileSha256").GetString() == profileHash &&
        c.GetProperty("fiveAffinityVariantStatusCode").GetString() == "passed" && c.GetProperty("affinityVariantCount").GetInt32() == 5 &&
        c.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed" && !c.GetProperty("clientStarted").GetBoolean());
    using var proof = PinObject(root.GetProperty("offlineCheckReceipt"), 65536);
    var proofRoot = proof.RootElement;
    Require(proofRoot.GetProperty("contractId").GetString() == "nll/user-validation-offline-matrix/v1" &&
        proofRoot.GetProperty("trialUid").GetString() == trial && proofRoot.GetProperty("profileSha256").GetString() == profileHash &&
        proofRoot.GetProperty("candidateReceiptSha256").GetString() == candidateHash &&
        !proofRoot.GetProperty("gameStarted").GetBoolean() && !proofRoot.GetProperty("systemChangesApplied").GetBoolean() &&
        !proofRoot.GetProperty("actualGameAcceptanceClaimed").GetBoolean());
    var proofRows = proofRoot.GetProperty("entries").EnumerateArray().ToArray();
    var rows = root.GetProperty("entries").EnumerateArray().ToArray();
    Require(rows.Length == 5 && proofRows.Length == 5);
    var entries = new Dictionary<string, (string RunRoot, string ControllerPath)>(StringComparer.Ordinal);
    var selections = new List<UserValidationSelection>();
    var assessments = new HashSet<string>(StringComparer.Ordinal);
    foreach (var row in rows)
    {
      var weakness = row.GetProperty("weaknessCode").GetString()!;
      var uid = Uid(row.GetProperty("assessmentUid").GetString());
      var entryHash = row.GetProperty("entrySha256").GetString()!;
      Require(IsWeakness(weakness) && assessments.Add(uid) && uid != trial && IsHash(entryHash));
      var evidence = proofRows.Single(e => e.GetProperty("weaknessCode").GetString() == weakness);
      Require(evidence.GetProperty("assessmentUid").GetString() == uid && evidence.GetProperty("entrySha256").GetString() == entryHash &&
          evidence.GetProperty("controllerInspectionPassed").GetBoolean() && evidence.GetProperty("compiledPlanBindingPassed").GetBoolean());
      var run = trialRoot + @"\runs\" + uid;
      using var entry = Pinned(run + @"\entry.private.json", entryHash, 65536);
      var e = entry.RootElement; Require(e.GetProperty("contractId").GetString() == "nll/user-validation-entry/v1");
      Require(e.GetProperty("parentPlan").GetProperty("path").GetString() == run + @"\validation.private.json" &&
          e.GetProperty("stagingReceipt").GetProperty("path").GetString() == run + @"\runtime-staging.receipt.json" &&
          e.GetProperty("storePlan").GetProperty("path").GetString() == run + @"\native-store.private.json" &&
          e.GetProperty("bootstrapPlan").GetProperty("path").GetString() == @"C:\NLL\Runtime\NativeFxUserValidationBootstrap\" + uid + @"\bootstrap.private.json");
      using var parent = PinObject(e.GetProperty("parentPlan"), 1048576);
      var parentRoot = parent.RootElement;
      Require(parentRoot.GetProperty("contractId").GetString() == "nll/native-fx-user-validation/v1");
      using var bootstrap = PinObject(e.GetProperty("bootstrapPlan"), 1048576);
      using var staging = PinObject(e.GetProperty("stagingReceipt"), 1048576);
      using var store = PinObject(e.GetProperty("storePlan"), 1048576);
      Require(bootstrap.RootElement.GetProperty("contractId").GetString() == "nll/native-fx-user-validation-bootstrap/v1" &&
          staging.RootElement.GetProperty("contractId").GetString() == "nll/user-validation-runtime-staging/v1" &&
          store.RootElement.GetProperty("contractId").GetString() == "nll/native-fx-user-validation-store/v1");
      foreach (var boundRoot in new[] { parentRoot, bootstrap.RootElement, staging.RootElement, store.RootElement })
        Require(boundRoot.GetProperty("trialUid").GetString() == trial && boundRoot.GetProperty("assessmentUid").GetString() == uid &&
            boundRoot.GetProperty("executionOwnerCode").GetString() == "user" && boundRoot.GetProperty("weaknessCode").GetString() == weakness &&
            boundRoot.GetProperty("profileSha256").GetString() == profileHash && boundRoot.GetProperty("candidateReceiptSha256").GetString() == candidateHash);
      Require(parentRoot.GetProperty("seasonNumber").GetInt32() == season &&
          parentRoot.GetProperty("runtimeStagingSha256").GetString() == e.GetProperty("stagingReceipt").GetProperty("sha256").GetString() &&
          parentRoot.GetProperty("nativeStorePlanSha256").GetString() == e.GetProperty("storePlan").GetProperty("sha256").GetString() &&
          bootstrap.RootElement.GetProperty("parentPlanSha256").GetString() == e.GetProperty("parentPlan").GetProperty("sha256").GetString());
      var controller = run + @"\controller\invoke-nll-user-validation.ps1";
      Require(e.GetProperty("controller").GetProperty("path").GetString() == controller);
      PinBytes(e.GetProperty("controller"), 1048576);
      var toolNames = new HashSet<string>(StringComparer.Ordinal);
      foreach (var tool in e.GetProperty("tools").EnumerateArray())
      {
        var name = tool.GetProperty("path").GetString()!;
        Require(name.StartsWith(run + @"\controller\", StringComparison.Ordinal) && toolNames.Add(name)); PinBytes(tool, 16777216);
      }
      var preflight = e.TryGetProperty("preflightContractId", out var preflightContract);
      if (preflight)
        Require(preflightContract.GetString() == "nll/user-validation-preflight/v1" &&
            e.GetProperty("preflightMode").GetString() == "deep" && toolNames.Contains(run + @"\controller\Nll.UserValidationPreflight.ps1"));
      Require(toolNames.Count == (preflight ? 8 : 7));
      foreach (var name in new[] { "Nll.ResourceNative.ps1", "Nll.NativeFxManagedService.ps1", "Nll.NativeFxManagedDriver.ps1",
          "Nll.UserValidationController.ps1", "Nll.PhaseDJob.cs", "Nll.FxProcessIdentity.cs", "NikkeLocalLab.NativeFxUserValidationStore.dll" })
        Require(toolNames.Contains(run + @"\controller\" + name));
      Require(entries.TryAdd(weakness, (run, controller)));
      selections.Add(new(weakness, Guid.Parse(uid), entryHash));
    }
    var shell = root.GetProperty("powerShell"); PinBytes(shell, 10485760);
    var shellPath = shell.GetProperty("path").GetString()!;
    Require(shellPath.EndsWith(@"\pwsh.exe", StringComparison.OrdinalIgnoreCase));
    return new(new(1, "nll/user-validation-delivery-view/v1", season, "awaiting_game_validation", null, manifestSha256,
        selections.ToArray()), trial, defaultWeakness, profileHash, candidateHash, shellPath, shell.GetProperty("sha256").GetString()!, entries);
  }
  private byte[] PinBytes(JsonElement pin, int maximum)
  {
    var bytes = read(pin.GetProperty("path").GetString()!, maximum);
    Require(bytes.LongLength == pin.GetProperty("length").GetInt64() && IsHash(pin.GetProperty("sha256").GetString()) &&
        Hash(bytes) == pin.GetProperty("sha256").GetString());
    return bytes;
  }
  private JsonDocument PinObject(JsonElement pin, int maximum) => Parse(PinBytes(pin, maximum));
  private JsonDocument Pinned(string path, string? hash, int maximum)
  {
    var bytes = read(path, maximum); Require(IsHash(hash) && Hash(bytes) == hash); return Parse(bytes);
  }
  private static JsonDocument Parse(byte[] bytes)
  {
    var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 24 });
    try { Unique(doc.RootElement); return doc; } catch { doc.Dispose(); throw; }
  }
  private static void Unique(JsonElement value)
  {
    if (value.ValueKind == JsonValueKind.Object)
    {
      var names = new HashSet<string>(StringComparer.Ordinal);
      foreach (var property in value.EnumerateObject()) { Require(names.Add(property.Name)); Unique(property.Value); }
    }
    else if (value.ValueKind == JsonValueKind.Array) foreach (var element in value.EnumerateArray()) Unique(element);
  }
  private static string Uid(string? value)
  {
    Require(Guid.TryParseExact(value, "D", out var uid) && uid != Guid.Empty && uid.ToString("D") == value); return value!;
  }
}
