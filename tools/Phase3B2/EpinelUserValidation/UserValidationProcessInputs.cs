using System.Diagnostics;
using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Phase3B2.UserValidation;

// Shared by the user-owned child and server-only checks. No process is started
// here; the caller must verify file pins and its live isolation before Start.
internal sealed record UserValidationProcessInputs(UserValidationBootstrapPlan Bootstrap,
    UserValidationFilePin[] ServerFiles, string? VariantSha256)
{
  internal string ServerRoot => @"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + Bootstrap.AssessmentUid;

  internal static UserValidationProcessInputs Bind(UserValidationBootstrapPlan bootstrap, JsonElement staging)
  {
    bootstrap.ValidateShape();
    UserValidationBootstrapPlan.RejectDuplicates(staging);
    Require(staging.GetProperty("contractId").GetString() == "nll/user-validation-runtime-staging/v1" &&
        staging.GetProperty("executionOwnerCode").GetString() == "user" &&
        staging.GetProperty("assessmentUid").GetString() == bootstrap.AssessmentUid &&
        staging.GetProperty("trialUid").GetString() == bootstrap.TrialUid &&
        staging.GetProperty("seasonNumber").GetInt32() == bootstrap.SeasonNumber &&
        staging.GetProperty("weaknessCode").GetString() == bootstrap.WeaknessCode &&
        staging.GetProperty("profileSha256").GetString() == bootstrap.ProfileSha256 &&
        staging.GetProperty("candidateReceiptSha256").GetString() == bootstrap.CandidateReceiptSha256 &&
        staging.GetProperty("installedBundlePreserved").GetBoolean() &&
        staging.GetProperty("preparedAccountPreserved").GetBoolean() &&
        !staging.GetProperty("serverStarted").GetBoolean() && !staging.GetProperty("gameStarted").GetBoolean() &&
        !staging.GetProperty("clientModified").GetBoolean() && !staging.GetProperty("systemChangesApplied").GetBoolean() &&
        !staging.GetProperty("readyForGameLaunch").GetBoolean() &&
        staging.GetProperty("runtimeAdmissionStatusCode").GetString() == "not_assessed");
    var root = @"C:\NLL\Runtime\EpinelPS-151-UserValidation\" + bootstrap.AssessmentUid;
    Require(staging.GetProperty("serverRoot").GetString() == root &&
        staging.GetProperty("bootstrapRoot").GetString() == bootstrap.RuntimeRoot &&
        staging.GetProperty("runRoot").GetString() == bootstrap.RunRoot);
    var files = Pins(staging.GetProperty("serverFiles"));
    Require(files.Length is > 0 and <= 128 && files.All(p =>
        UserValidationBootstrapPlan.IsMember(p.Path, root) && p.Length is > 0 and <= 536870912 &&
        UserValidationBootstrapPlan.IsHash(p.Sha256)) && files.Sum(p => p.Length) <= 2147483648L &&
        files.Select(p => p.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() == files.Length);
    foreach (var name in new[] { "EpinelPS.exe", "EpinelPS.dll", "EpinelPS.deps.json", "EpinelPS.runtimeconfig.json",
        "db.json", "site.pfx", "gameconfig.json", "boss-runtime-variant.profile.json" })
      Require(files.Count(p => p.Path == root + "\\" + name) == 1);
    Require(files.Single(p => p.Path == root + @"\boss-runtime-variant.profile.json").Sha256 == bootstrap.ProfileSha256 &&
        !files.Any(p => p.Path == root + @"\epinelps.db"));
    var runtime = Pins(staging.GetProperty("bootstrapFiles"));
    Require(runtime.Length == bootstrap.RuntimeFiles.Length && runtime.Distinct().Count() == runtime.Length &&
        runtime.ToHashSet().SetEquals(bootstrap.RuntimeFiles));
    var variantRequired = staging.GetProperty("staticDataVariantRequired").GetBoolean();
    var variant = staging.GetProperty("variantStaticDataSha256").GetString();
    Require(variantRequired == (bootstrap.WeaknessCode != "iron") &&
        (variantRequired ? UserValidationBootstrapPlan.IsHash(variant) : variant is null));
    var variants = files.Where(p => p.Path == root + @"\client-static-data-variant.pack").ToArray();
    Require(variantRequired ? variants.Length == 1 && variants[0].Sha256 == variant : variants.Length == 0);
    return new(bootstrap, files, variantRequired ? variant : null);
  }

  internal ProcessStartInfo ServerStart(ulong accountId)
  {
    var info = Info(ServerRoot + @"\EpinelPS.exe", ServerRoot);
    SetEnvironment(info, UserValidationServerEnvironment.Create(Guid.Parse(Bootstrap.AssessmentUid), accountId, VariantSha256));
    info.ArgumentList.Add("--headless");
    info.ArgumentList.Add("--local-only");
    return info;
  }

  internal ProcessStartInfo BootstrapStart(string planHash)
  {
    Require(UserValidationBootstrapPlan.IsHash(planHash));
    var info = Info(Bootstrap.RuntimeRoot + @"\NikkeLocalLab.NativeFxUserValidationBootstrap.exe", Bootstrap.RuntimeRoot);
    SetEnvironment(info, new Dictionary<string, string>
    {
      ["SystemRoot"] = @"C:\Windows",
      ["WINDIR"] = @"C:\Windows",
      ["PATH"] = @"C:\Windows\System32;C:\Windows;C:\Program Files\dotnet",
      ["DOTNET_ROOT"] = @"C:\Program Files\dotnet",
      ["DOTNET_EnableDiagnostics"] = "0",
      ["TEMP"] = Bootstrap.RunRoot + @"\scratch",
      ["TMP"] = Bootstrap.RunRoot + @"\scratch",
      ["NLL_USER_VALIDATION_BOOTSTRAP_SHA256"] = planHash
    });
    info.ArgumentList.Add("--user-start");
    return info;
  }

  internal static ulong ReadLocalAccountId(JsonElement database)
  {
    UserValidationBootstrapPlan.RejectDuplicates(database);
    var users = database.GetProperty("Users");
    Require(users.ValueKind == JsonValueKind.Array && users.GetArrayLength() == 1);
    var user = users[0];
    var id = user.GetProperty("ID").GetUInt64();
    Require(id != 0 && user.GetProperty("Username").GetString()?.StartsWith("synthetic-validation-", StringComparison.Ordinal) == true &&
        user.GetProperty("LocalPersistenceBinding").ValueKind == JsonValueKind.Null &&
        user.GetProperty("SelectedClassicSoloRaidManagerId").GetInt32() > 0);
    return id; // Private process environment only; never a receipt/API/log value.
  }

  private static UserValidationFilePin[] Pins(JsonElement array) => array.EnumerateArray().Select(p =>
      new UserValidationFilePin(p.GetProperty("path").GetString()!, p.GetProperty("length").GetInt64(),
          p.GetProperty("sha256").GetString()!)).ToArray();
  private static ProcessStartInfo Info(string path, string directory) => new(path)
  {
    WorkingDirectory = directory,
    UseShellExecute = false,
    CreateNoWindow = true,
    RedirectStandardOutput = true,
    RedirectStandardError = true
  };
  private static void SetEnvironment(ProcessStartInfo info, IReadOnlyDictionary<string, string> environment)
  {
    info.Environment.Clear();
    foreach (var pair in environment) info.Environment.Add(pair.Key, pair.Value);
  }
  private static void Require(bool value)
  {
    if (!value) throw new InvalidOperationException("user_validation_process_inputs_rejected");
  }
}
