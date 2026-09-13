using System.Text.Json;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

// Validates the controller's data binding, NOT actual OS isolation by itself.
// The bootstrap additionally requires the exact live Job and elevated token.
internal static class UserValidationLaunchEvidence
{
  internal static void ValidateParent(UserValidationBootstrapPlan plan, JsonElement root)
  {
    UserValidationBootstrapPlan.RejectDuplicates(root);
    Require(root.GetProperty("contractId").GetString() == "nll/native-fx-user-validation/v1" &&
        root.GetProperty("trialUid").GetString() == plan.TrialUid &&
        root.GetProperty("executionOwnerCode").GetString() == "user" &&
        root.GetProperty("seasonNumber").GetInt32() == plan.SeasonNumber &&
        root.GetProperty("weaknessCode").GetString() == plan.WeaknessCode &&
        root.GetProperty("profileSha256").GetString() == plan.ProfileSha256 &&
        root.GetProperty("candidateReceiptSha256").GetString() == plan.CandidateReceiptSha256);
  }

  internal static void ValidateIsolation(UserValidationBootstrapPlan plan, string bootstrapHash,
      JsonElement root, DateTimeOffset now)
  {
    UserValidationBootstrapPlan.RejectDuplicates(root);
    Require(UserValidationBootstrapPlan.IsHash(bootstrapHash));
    var appliedAt = root.GetProperty("verifiedAtUtc").GetDateTimeOffset();
    Require(root.GetProperty("contractId").GetString() == "nll/native-fx-user-validation-isolation/v1" &&
        root.GetProperty("assessmentUid").GetString() == plan.AssessmentUid &&
        root.GetProperty("trialUid").GetString() == plan.TrialUid &&
        root.GetProperty("executionOwnerCode").GetString() == "user" &&
        root.GetProperty("bootstrapPlanSha256").GetString() == bootstrapHash &&
        root.GetProperty("parentPlanSha256").GetString() == plan.ParentPlanSha256 &&
        root.GetProperty("nativeStoreSha256").GetString() == plan.NativeStore.Sha256 &&
        root.GetProperty("caseCode").GetString() == plan.CaseCode &&
        root.GetProperty("driverPolicyCode").GetString() == "nll/user-validation-ace-advt/v1" &&
        root.GetProperty("driverAuthorizationId").GetString() == "operator-2026-09-13-user-launched-ace-advt/v1" &&
        root.GetProperty("allProgramsBlocked").GetBoolean() &&
        root.GetProperty("rollbackPrepared").GetBoolean() &&
        root.GetProperty("systemChangesVerified").GetBoolean() &&
        root.GetProperty("managedServiceBaselineVerified").GetBoolean() &&
        root.GetProperty("managedDriverBaselineVerified").GetBoolean() &&
        root.GetProperty("preparedAccountVerified").GetBoolean() &&
        root.GetProperty("independentServerVerified").GetBoolean() &&
        root.GetProperty("protectedInputsUnchanged").GetBoolean() &&
        now - appliedAt >= TimeSpan.Zero && now - appliedAt < TimeSpan.FromMinutes(5));
  }
  private static void Require(bool value)
  {
    if (!value) throw new InvalidOperationException("user_validation_launch_evidence_rejected");
  }
}
