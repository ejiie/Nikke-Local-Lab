using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationDeliveryTests
{
  [Fact]
  public void NewPreflightRequiresCompleteHelperClosureAndExplicitDeepMode()
  {
    var fixture = new DeliveryFixture(preflight: true);
    Assert.Equal("awaiting_game_validation", fixture.Service.Get(29).StatusCode);
    var helper = fixture.Files.Keys.First(p => p.EndsWith(@"\Nll.UserValidationPreflight.ps1", StringComparison.Ordinal));
    fixture.Files[helper] = "changed"u8.ToArray();
    Assert.Equal("blocked", fixture.Service.Get(29).StatusCode);
    Assert.Equal("blocked", new DeliveryFixture(preflight: true, preflightMode: "fast").Service.Get(29).StatusCode);
  }
  [Fact]
  public void VerifiedFiveEntryHandoffIsOnlyGameValidationPending()
  {
    var fixture = new DeliveryFixture(); var view = fixture.Service.Get(29);
    Assert.Equal("awaiting_game_validation", view.StatusCode); Assert.Equal(5, view.Selections.Length);
    Assert.False(view.ActualGameAcceptanceClaimed); Assert.Equal("blocked", fixture.Service.Get(26).StatusCode);
    Assert.DoesNotContain("C:\\", JsonSerializer.Serialize(view), StringComparison.Ordinal);
  }
  [Theory]
  [InlineData("statusCode", "completed")]
  [InlineData("contractId", "nll/boss-onboarding-admission/v1")]
  [InlineData("profileSha256", "invalid")]
  [InlineData("trialUid", "00000000-0000-0000-0000-000000000000")]
  public void WrongAuthorityOrIdentityCannotPromoteASeason(string field, string value)
  {
    var fixture = new DeliveryFixture(); fixture.Manifest[field] = value;
    Assert.Equal("blocked", fixture.Service.Get(29).StatusCode);
  }
  [Fact]
  public void IncompleteDuplicateOrCrossCaseMatrixIsRejected()
  {
    foreach (var change in new Action<JsonArray>[] { rows => rows.RemoveAt(0), rows => rows[1] = rows[0]!.DeepClone(),
        rows => rows[0]!["assessmentUid"] = Guid.NewGuid().ToString("D"), rows => rows[0]!["weaknessCode"] = "unsupported" })
    {
      var fixture = new DeliveryFixture(); change((JsonArray)fixture.Manifest["entries"]!);
      Assert.Equal("blocked", fixture.Service.Get(29).StatusCode);
    }
  }
  [Fact]
  public void EveryPinnedPlanToolOrReceiptDriftRetractsPreparation()
  {
    var inventory = new DeliveryFixture().Files.Keys.ToArray();
    foreach (var path in inventory)
    {
      var fixture = new DeliveryFixture(); fixture.Files[path] = "changed"u8.ToArray();
      Assert.Equal("blocked", fixture.Service.Get(29).StatusCode);
    }
  }
  [Fact]
  public void GameExecutedAndFabricatedAcceptanceFlagsAreRejected()
  {
    foreach (var field in new[] { "nativeClientExecuted", "actualGameAcceptanceClaimed" })
    {
      var fixture = new DeliveryFixture(); fixture.Manifest[field] = true;
      Assert.Equal("blocked", fixture.Service.Get(29).StatusCode);
    }
  }
  [Fact]
  public void DuplicateJsonKeysAreRejectedEvenWithMatchingDigest()
  {
    var fixture = new DeliveryFixture();
    var bytes = System.Text.Encoding.UTF8.GetBytes(fixture.Manifest.ToJsonString().Replace("{", "{\"schemaVersion\":1,", StringComparison.Ordinal));
    var service = new UserValidationDelivery("manifest", DeliveryFixture.Hash(bytes), (path, limit) => path == "manifest" ? bytes : fixture.Read(path, limit));
    Assert.Equal("blocked", service.Get(29).StatusCode);
  }
}

internal sealed class DeliveryFixture
{
  internal const string Trial = "10000000-0000-0000-0000-000000000001";
  internal string TrialRoot => @"C:\NLL\Staging\NativeFxUserValidation\" + Trial;
  internal Dictionary<string, byte[]> Files { get; } = new(StringComparer.Ordinal);
  internal JsonObject Manifest { get; }
  internal UserValidationDelivery Service
  {
    get
    {
      var bytes = JsonSerializer.SerializeToUtf8Bytes(Manifest);
      return new("manifest", Hash(bytes), (path, limit) => path == "manifest" ? bytes : Read(path, limit));
    }
  }
  internal byte[] Read(string path, int maximum)
  {
    var bytes = Files[path]; Assert.InRange(bytes.Length, 1, maximum); return bytes;
  }
  internal static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  private JsonObject Pin(string path, object value)
  {
    var bytes = JsonSerializer.SerializeToUtf8Bytes(value); Files.Add(path, bytes);
    return new() { ["path"] = path, ["length"] = bytes.Length, ["sha256"] = Hash(bytes) };
  }
  internal DeliveryFixture(bool preflight = false, string preflightMode = "deep")
  {
    var profile = Pin("profile", new { schemaVersion = 3, contractId = "nll/boss-runtime-variant-profile/v3", seasonNumber = 29, sourceAffinity = new { weaknessCode = "iron" } });
    var ph = profile["sha256"]!.GetValue<string>();
    var candidate = Pin("candidate", new
    {
      contractId = "nll/boss-onboarding-verified-candidate/v1",
      seasonNumber = 29,
      profileSha256 = ph,
      fiveAffinityVariantStatusCode = "passed",
      affinityVariantCount = 5,
      runtimeAdmissionStatusCode = "not_assessed",
      clientStarted = false
    });
    var ch = candidate["sha256"]!.GetValue<string>();
    var entries = new JsonArray(); var proofRows = new JsonArray();
    var index = 0;
    foreach (var weakness in new[] { "fire", "water", "wind", "electric", "iron" })
    {
      var uid = "20000000-0000-0000-0000-" + (++index).ToString("D12");
      var run = TrialRoot + @"\runs\" + uid;
      JsonObject Common(string contract) => new()
      {
        ["contractId"] = contract,
        ["trialUid"] = Trial,
        ["assessmentUid"] = uid,
        ["executionOwnerCode"] = "user",
        ["weaknessCode"] = weakness,
        ["profileSha256"] = ph,
        ["candidateReceiptSha256"] = ch
      };
      var staging = Pin(run + @"\runtime-staging.receipt.json", Common("nll/user-validation-runtime-staging/v1"));
      var store = Pin(run + @"\native-store.private.json", Common("nll/native-fx-user-validation-store/v1"));
      var parentValue = Common("nll/native-fx-user-validation/v1"); parentValue["seasonNumber"] = 29;
      parentValue["runtimeStagingSha256"] = staging["sha256"]!.DeepClone(); parentValue["nativeStorePlanSha256"] = store["sha256"]!.DeepClone();
      var parent = Pin(run + @"\validation.private.json", parentValue);
      var bootstrapValue = Common("nll/native-fx-user-validation-bootstrap/v1"); bootstrapValue["parentPlanSha256"] = parent["sha256"]!.DeepClone();
      var bootstrap = Pin(@"C:\NLL\Runtime\NativeFxUserValidationBootstrap\" + uid + @"\bootstrap.private.json", bootstrapValue);
      var controller = Pin(run + @"\controller\invoke-nll-user-validation.ps1", "synthetic controller: never execute");
      var tools = new JsonArray();
      foreach (var name in new[] { "Nll.ResourceNative.ps1", "Nll.NativeFxManagedService.ps1", "Nll.NativeFxManagedDriver.ps1", "Nll.UserValidationController.ps1",
          "Nll.PhaseDJob.cs", "Nll.FxProcessIdentity.cs", "NikkeLocalLab.NativeFxUserValidationStore.dll" })
        tools.Add(Pin(run + @"\controller\" + name, "synthetic inert data"));
      if (preflight) tools.Add(Pin(run + @"\controller\Nll.UserValidationPreflight.ps1", "synthetic inert preflight"));
      var entryValue = new JsonObject
      {
        ["contractId"] = "nll/user-validation-entry/v1",
        ["parentPlan"] = parent,
        ["bootstrapPlan"] = bootstrap,
        ["stagingReceipt"] = staging,
        ["storePlan"] = store,
        ["controller"] = controller,
        ["tools"] = tools
      };
      if (preflight) { entryValue["preflightContractId"] = "nll/user-validation-preflight/v1"; entryValue["preflightMode"] = preflightMode; }
      var entry = Pin(run + @"\entry.private.json", entryValue);
      var row = new JsonObject { ["weaknessCode"] = weakness, ["assessmentUid"] = uid, ["entrySha256"] = entry["sha256"]!.DeepClone() };
      entries.Add(row);
      var proof = (JsonObject)row.DeepClone(); proof["controllerInspectionPassed"] = true; proof["compiledPlanBindingPassed"] = true; proofRows.Add(proof);
    }
    var proofPin = Pin("matrix", new JsonObject
    {
      ["contractId"] = "nll/user-validation-offline-matrix/v1",
      ["trialUid"] = Trial,
      ["profileSha256"] = ph,
      ["candidateReceiptSha256"] = ch,
      ["entries"] = proofRows,
      ["gameStarted"] = false,
      ["systemChangesApplied"] = false,
      ["actualGameAcceptanceClaimed"] = false
    });
    Manifest = new JsonObject
    {
      ["schemaVersion"] = 1,
      ["contractId"] = "nll/user-validation-delivery/v1",
      ["statusCode"] = "awaiting_game_validation",
      ["seasonNumber"] = 29,
      ["trialUid"] = Trial,
      ["profileSha256"] = ph,
      ["candidateReceiptSha256"] = ch,
      ["profile"] = profile,
      ["candidateReceipt"] = candidate,
      ["offlineCheckReceipt"] = proofPin,
      ["entries"] = entries,
      ["powerShell"] = Pin(@"C:\synthetic\pwsh.exe", "inert synthetic interpreter"),
      ["nativeClientExecuted"] = false,
      ["actualGameAcceptanceClaimed"] = false
    };
  }
}
