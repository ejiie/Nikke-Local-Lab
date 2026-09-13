using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;
using NikkeLocalLab.Phase3B2.UserValidation;

// Uses the production child/bootstrap plan parsers; never launches a process,
// authenticates, applies the projected store, or creates an isolation permit.
if (args.Length != 2 || !OperatingSystem.IsWindows()) return 64;
try
{
  using var entry = JsonDocument.Parse(Read(args[0], args[1], 65536));
  var e = entry.RootElement; UserValidationBootstrapPlan.RejectDuplicates(e);
  Require(e.GetProperty("contractId").GetString() == "nll/user-validation-entry/v1");
  var parentPin = Pin(e.GetProperty("parentPlan")); var bootPin = Pin(e.GetProperty("bootstrapPlan"));
  var stagePin = Pin(e.GetProperty("stagingReceipt")); var storePin = Pin(e.GetProperty("storePlan"));
  var plan = UserValidationBootstrapPlan.Parse(Read(bootPin.Path, bootPin.Sha256, 1048576));
  Require(args[0] == plan.RunRoot + @"\entry.private.json" && bootPin.Path == plan.RuntimeRoot + @"\bootstrap.private.json" &&
      parentPin.Path == plan.ParentPlanPath && parentPin.Sha256 == plan.ParentPlanSha256 &&
      stagePin.Path == plan.RunRoot + @"\runtime-staging.receipt.json" && storePin.Path == plan.RunRoot + @"\native-store.private.json");
  using var parent = JsonDocument.Parse(Read(parentPin.Path, parentPin.Sha256, 1048576));
  UserValidationLaunchEvidence.ValidateParent(plan, parent.RootElement);
  using var staging = JsonDocument.Parse(Read(stagePin.Path, stagePin.Sha256, 1048576));
  var inputs = UserValidationProcessInputs.Bind(plan, staging.RootElement);
  var store = UserValidationStorePlan.Parse(Read(storePin.Path, storePin.Sha256, 1048576));
  Require(store.TrialUid == plan.TrialUid && store.AssessmentUid == plan.AssessmentUid && store.WeaknessCode == plan.WeaknessCode &&
      store.ProfileSha256 == plan.ProfileSha256 && store.CandidateReceiptSha256 == plan.CandidateReceiptSha256 &&
      store.CaseCode == plan.CaseCode && plan.NativeStore == store.OriginalStore with { Sha256 = store.CandidateStoreSha256 } &&
      parent.RootElement.GetProperty("runtimeStagingSha256").GetString() == stagePin.Sha256 &&
      parent.RootElement.GetProperty("nativeStorePlanSha256").GetString() == storePin.Sha256);
  var before = parent.RootElement.GetProperty("clientFiles").EnumerateArray().Select(Pin).ToArray();
  Require(before.Length == plan.ClientFiles.Length && before.DistinctBy(p => p.Path, StringComparer.OrdinalIgnoreCase).Count() == before.Length);
  Require(before.Select(p => p.Path == store.OriginalStore.Path ? p with { Sha256 = store.CandidateStoreSha256 } : p).ToHashSet()
      .SetEquals(plan.ClientFiles) && before.Single(p => p.Path == store.OriginalStore.Path) == store.OriginalStore);
  var seed = inputs.ServerFiles.Single(p => p.Path == inputs.ServerRoot + @"\db.json");
  using var account = JsonDocument.Parse(Read(seed.Path, seed.Sha256, 33554432));
  var serverInfo = inputs.ServerStart(UserValidationProcessInputs.ReadLocalAccountId(account.RootElement));
  var bootstrapInfo = inputs.BootstrapStart(bootPin.Sha256);
  Require(serverInfo.ArgumentList.SequenceEqual(new[] { "--headless", "--local-only" }) &&
      bootstrapInfo.ArgumentList.SequenceEqual(new[] { "--user-start" }));
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/user-validation-compiled-plan-check/v1",
    trialUid = plan.TrialUid,
    assessmentUid = plan.AssessmentUid,
    weaknessCode = plan.WeaknessCode,
    entrySha256 = args[1],
    compiledPlanBindingPassed = true,
    gameStarted = false,
    systemChangesApplied = false,
    actualGameAcceptanceClaimed = false
  }));
  return 0;
}
catch { Console.Error.WriteLine("user_validation_compiled_plan_check_failed"); return 1; }
static UserValidationFilePin Pin(JsonElement pin) => new(pin.GetProperty("path").GetString()!, pin.GetProperty("length").GetInt64(), pin.GetProperty("sha256").GetString()!);
static byte[] Read(string path, string hash, long limit)
{
  using var file = UserValidationPinnedFiles.Open(path, new FileInfo(path).Length, hash, limit);
  var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes); return bytes;
}
static void Require(bool value) { if (!value) throw new InvalidOperationException(); }
