using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Phase3B2.UserValidation;

internal sealed record UserValidationStorePatch(string RoleCode, long Offset,
    UserValidationFilePin Before, UserValidationFilePin After);
internal sealed record UserValidationStorePlan(string ContractId, string TrialUid, string AssessmentUid,
    string ExecutionOwnerCode, string WeaknessCode, string CaseCode, string ProfileSha256,
    string CandidateReceiptSha256, UserValidationFilePin OriginalStore, string CandidateStoreSha256,
    UserValidationStorePatch[] Patches)
{
  [JsonIgnore] internal string RunRoot => @"C:\NLL\Staging\NativeFxUserValidation\" + TrialUid + @"\runs\" + AssessmentUid;
  [JsonIgnore] internal string PlanPath => RunRoot + @"\native-store.private.json";
  internal static UserValidationStorePlan Parse(byte[] bytes)
  {
    Require(bytes.Length is > 0 and <= 1048576);
    using var doc = JsonDocument.Parse(bytes);
    UserValidationBootstrapPlan.RejectDuplicates(doc.RootElement);
    var plan = JsonSerializer.Deserialize<UserValidationStorePlan>(bytes, new JsonSerializerOptions
    {
      PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
      UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    });
    Require(plan is not null); plan!.Validate(); return plan;
  }
  internal void Validate()
  {
    Require(ContractId == "nll/native-fx-user-validation-store/v1" && ExecutionOwnerCode == "user" &&
        Uid(TrialUid) && Uid(AssessmentUid) && TrialUid != AssessmentUid &&
        WeaknessCode is "fire" or "water" or "wind" or "electric" or "iron" &&
        CaseCode is "baseline" or "candidate" or "restored" &&
        UserValidationBootstrapPlan.IsHash(ProfileSha256) && UserValidationBootstrapPlan.IsHash(CandidateReceiptSha256));
    var client = @"C:\NLL\Clients\NIKKE-151.8.5-UserValidation-" + TrialUid;
    Require(OriginalStore is not null && OriginalStore.Length == 6574364321 &&
        OriginalStore.Sha256 == "0745db76654f7d7059ae6777d0572520e23e825590c8a4fb3207f81bf58bf792" &&
        UserValidationBootstrapPlan.IsMember(OriginalStore.Path, client) &&
        OriginalStore.Path.StartsWith(client + @"\Unity\com_proximabeta_NIKKE\com.shiftup.patch\", StringComparison.Ordinal) &&
        OriginalStore.Path.EndsWith(".cdb", StringComparison.Ordinal));
    var role = CaseCode == "candidate" ? WeaknessCode switch { "fire" => "wind", "water" => "fire", "wind" => "iron", _ => null } : null;
    Require(Patches is not null && (role is null ? Patches.Length == 0 && CandidateStoreSha256 == OriginalStore!.Sha256 :
        Patches.Length is > 0 and <= 32 && UserValidationBootstrapPlan.IsHash(CandidateStoreSha256) && CandidateStoreSha256 != OriginalStore!.Sha256));
    long end = 256, total = 0;
    for (var i = 0; i < Patches!.Length; i++)
    {
      var patch = Patches[i];
      Require(patch is not null && patch.RoleCode == role && patch.Before is not null && patch.After is not null &&
          patch.Before.Length is > 0 and <= 16777216 && patch.Before.Length == patch.After.Length &&
          UserValidationBootstrapPlan.IsHash(patch.Before.Sha256) && UserValidationBootstrapPlan.IsHash(patch.After.Sha256) &&
          patch.Before.Sha256 != patch.After.Sha256 && patch.Offset >= end && patch.Offset <= OriginalStore!.Length - patch.Before.Length &&
          patch.Before.Path == RunRoot + @"\store-rollback\" + i + ".before.chunk" &&
          patch.After.Path == RunRoot + @"\store-rollback\" + i + ".after.chunk");
      end = patch!.Offset + patch.Before!.Length; total += patch.Before.Length;
    }
    Require(total <= 67108864);
  }
  private static bool Uid(string value) => Guid.TryParseExact(value, "D", out var uid) && uid != Guid.Empty && uid.ToString("D") == value;
  private static void Require(bool value) { if (!value) throw new InvalidOperationException("user_validation_store_plan_rejected"); }
}
