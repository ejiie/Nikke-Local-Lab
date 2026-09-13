using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

// Data-only contract. Shape validation is NOT a file pin, isolation or launch proof.
internal sealed record UserValidationFilePin(string Path, long Length, string Sha256);
internal sealed record UserValidationBootstrapPlan(
    string ContractId, string AssessmentUid, string TrialUid, string ExecutionOwnerCode,
    int DurationSeconds, int SeasonNumber, string WeaknessCode, string CaseCode,
    string ProfileSha256, string CandidateReceiptSha256, string ParentPlanSha256,
    string JobName, UserValidationFilePin NativeStore,
    UserValidationFilePin[] RuntimeFiles, UserValidationFilePin[] ClientFiles)
{
  internal const string RuntimeParent = @"C:\NLL\Runtime\NativeFxUserValidationBootstrap";
  [JsonIgnore] internal string RuntimeRoot => RuntimeParent + @"\" + AssessmentUid;
  [JsonIgnore] internal string ClientRoot => @"C:\NLL\Clients\NIKKE-151.8.5-UserValidation-" + TrialUid;
  [JsonIgnore] internal string RunRoot => @"C:\NLL\Staging\NativeFxUserValidation\" + TrialUid + @"\runs\" + AssessmentUid;
  [JsonIgnore] internal string ParentPlanPath => RunRoot + @"\validation.private.json";

  internal static UserValidationBootstrapPlan Parse(byte[] bytes)
  {
    Require(bytes.Length is > 0 and <= 1048576);
    using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
    RejectDuplicates(document.RootElement);
    var plan = JsonSerializer.Deserialize<UserValidationBootstrapPlan>(bytes, new JsonSerializerOptions
    {
      PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
      UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
      MaxDepth = 16
    });
    Require(plan is not null);
    plan!.ValidateShape();
    return plan;
  }

  internal static void RejectDuplicates(JsonElement value)
  {
    if (value.ValueKind == JsonValueKind.Object)
    {
      var names = new HashSet<string>(StringComparer.Ordinal);
      foreach (var property in value.EnumerateObject()) { Require(names.Add(property.Name)); RejectDuplicates(property.Value); }
    }
    else if (value.ValueKind == JsonValueKind.Array)
      foreach (var item in value.EnumerateArray()) RejectDuplicates(item);
  }

  internal void ValidateShape()
  {
    Require(ContractId == "nll/native-fx-user-validation-bootstrap/v1" && ExecutionOwnerCode == "user");
    Require(IsUid(AssessmentUid) && IsUid(TrialUid) && AssessmentUid != TrialUid);
    Require(DurationSeconds is >= 60 and <= 1800 && SeasonNumber is >= 1 and <= 1000);
    Require(WeaknessCode is "fire" or "water" or "wind" or "electric" or "iron");
    Require(CaseCode is "baseline" or "candidate" or "restored");
    Require(IsHash(ProfileSha256) && IsHash(CandidateReceiptSha256) && IsHash(ParentPlanSha256));
    Require(JobName == "Local\\NLL.FxValidation." + Guid.ParseExact(AssessmentUid, "D").ToString("N"));
    Require(RuntimeFiles is { Length: > 0 and <= 64 } && ClientFiles is { Length: > 0 and <= 10000 });
    ValidatePins(RuntimeFiles!, RuntimeRoot, 512L * 1024 * 1024, allowEmpty: false);
    ValidatePins(ClientFiles!, ClientRoot, 16L * 1024 * 1024 * 1024, allowEmpty: true);
    Require(RuntimeFiles!.Sum(pin => pin.Length) <= 1024L * 1024 * 1024 &&
        ClientFiles!.Sum(pin => pin.Length) <= 64L * 1024 * 1024 * 1024);
    foreach (var name in new[] { "synthetic-context.json", "server.cer", "trust-root.cer", "sail_api_impl64.dll",
            "NikkeLocalLab.NativeFxUserValidationBootstrap.exe", "NikkeLocalLab.NativeFxUserValidationBootstrap.dll" })
      Require(RuntimeFiles.Any(pin => pin.Path == RuntimeRoot + @"\" + name));
    Require(RuntimeFiles.Any(pin => pin.Path == RuntimeRoot + @"\sail_api_impl64.dll" &&
        pin.Sha256 == "8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d"));
    Require(RuntimeFiles.Any(pin => pin.Path == RuntimeRoot + @"\trust-root.cer" &&
        pin.Sha256 == "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda"));
    RequireClientPin(@"NIKKE\game\nikke.exe", "36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732");
    RequireClientPin(@"NIKKE\game\GameAssembly.dll", "23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed");
    RequireClientPin(@"NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll", "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662");
    Require(NativeStore is not null && NativeStore.Length > 0 && ClientFiles!.Contains(NativeStore) &&
        NativeStore.Path.StartsWith(ClientRoot + @"\Unity\com_proximabeta_NIKKE\com.shiftup.patch\", StringComparison.Ordinal) &&
        NativeStore.Path.EndsWith(".cdb", StringComparison.Ordinal));
  }

  private void RequireClientPin(string relative, string hash) =>
      Require(ClientFiles.Any(pin => pin.Path == ClientRoot + @"\" + relative && pin.Length > 0 && pin.Sha256 == hash));

  private static void ValidatePins(UserValidationFilePin[] pins, string root, long limit, bool allowEmpty)
  {
    Require(pins.All(pin => pin is not null && IsMember(pin.Path, root) &&
        pin.Length >= (allowEmpty ? 0 : 1) && pin.Length <= limit && IsHash(pin.Sha256) &&
        (pin.Length != 0 || pin.Sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")));
    Require(pins.Select(pin => pin.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() == pins.Length);
  }

  internal static bool IsMember(string? path, string root)
  {
    if (path is null || !path.StartsWith(root + @"\", StringComparison.Ordinal)) return false;
    var relative = path[(root.Length + 1)..];
    // Windows paths are validated identically in source-only Linux CI. No IO
    // or Path.GetFullPath based on the CI host's filesystem semantics.
    return relative.Length is > 0 and <= 400 && relative.Split('\\').All(part =>
        Regex.IsMatch(part, @"\A[A-Za-z0-9][A-Za-z0-9 ._()\-]{0,159}\z") && !part.EndsWith('.') && !part.EndsWith(' ') &&
        !Regex.IsMatch(part, @"\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)", RegexOptions.IgnoreCase));
  }
  internal static bool IsHash(string? value) => value is not null && Regex.IsMatch(value, @"\A[a-f0-9]{64}\z");
  private static bool IsUid(string? value) => Guid.TryParseExact(value, "D", out var uid) && uid != Guid.Empty && uid.ToString("D") == value;
  private static void Require(bool value) { if (!value) throw new InvalidOperationException("user_validation_bootstrap_plan_invalid"); }
}
