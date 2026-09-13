using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;
using NikkeLocalLab.Phase3B2.UserValidation;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationStorePlanTests
{
  private static UserValidationStorePlan Example(string weakness, string caseCode)
  {
    var bootstrap = UserValidationBootstrapPlanTests.Example();
    var original = bootstrap.NativeStore with { Length = 6574364321, Sha256 = "0745db76654f7d7059ae6777d0572520e23e825590c8a4fb3207f81bf58bf792" };
    var role = caseCode == "candidate" ? weakness switch { "fire" => "wind", "water" => "fire", "wind" => "iron", _ => null } : null;
    UserValidationStorePatch[] patches = role is null ? [] : [new(role, 1024,
        new(bootstrap.RunRoot + @"\store-rollback\0.before.chunk", 100, new string('a', 64)),
        new(bootstrap.RunRoot + @"\store-rollback\0.after.chunk", 100, new string('b', 64)))];
    return new("nll/native-fx-user-validation-store/v1", bootstrap.TrialUid, bootstrap.AssessmentUid, "user", weakness,
        caseCode, bootstrap.ProfileSha256, bootstrap.CandidateReceiptSha256, original,
        role is null ? original.Sha256 : new string('c', 64), patches);
  }
  public static IEnumerable<object[]> Matrix() => UserValidationBootstrapPlanTests.Cases();
  [Theory]
  [MemberData(nameof(Matrix))]
  public void AllCasesMapWeaknessToOnlyItsBossElementOrExplicitNoChange(string weakness, string caseCode)
  {
    var plan = Example(weakness, caseCode);
    var copy = UserValidationStorePlan.Parse(JsonSerializer.SerializeToUtf8Bytes(plan,
        new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    Assert.Equal(plan.CandidateStoreSha256, copy.CandidateStoreSha256);
    Assert.Equal(plan.Patches.Length, copy.Patches.Length);
    if (plan.Patches.Length == 0) Assert.Equal(plan.OriginalStore.Sha256, copy.CandidateStoreSha256);
    else Assert.Equal(weakness switch { "fire" => "wind", "water" => "fire", "wind" => "iron", _ => throw new InvalidOperationException() }, copy.Patches[0].RoleCode);
  }
  [Fact]
  public void NoChangeCasesNeverAdmitTransformedChunksOrFictitiousCandidateHash()
  {
    var candidate = Example("water", "candidate");
    foreach (var (weakness, code) in new[] { ("iron", "candidate"), ("electric", "candidate"), ("water", "baseline"), ("water", "restored") })
    {
      var plan = Example(weakness, code);
      Assert.Throws<InvalidOperationException>(() => (plan with { Patches = candidate.Patches }).Validate());
      Assert.Throws<InvalidOperationException>(() => (plan with { CandidateStoreSha256 = candidate.CandidateStoreSha256 }).Validate());
    }
  }
  [Fact]
  public void CrossTrialNativeFilesUnboundedRangesAndMixedRolesAreRejected()
  {
    var plan = Example("water", "candidate"); var patch = plan.Patches[0];
    foreach (var invalid in new[] { plan with { ExecutionOwnerCode = "agent" }, plan with { AssessmentUid = plan.TrialUid },
        plan with { TrialUid = Guid.Empty.ToString("D") }, plan with { OriginalStore = plan.OriginalStore with { Path = @"C:\NIKKE\store.cdb" } },
        plan with { OriginalStore = plan.OriginalStore with { Sha256 = new string('0', 64) } },
        plan with { OriginalStore = plan.OriginalStore with { Length = 6574364320 } }, plan with { Patches = [] },
        plan with { Patches = [patch, patch] }, plan with { Patches = [patch with { RoleCode = "wind" }] },
        plan with { Patches = [patch with { Offset = 0 }] }, plan with { Patches = [patch with { Offset = long.MaxValue }] },
        plan with { Patches = [patch with { Before = patch.Before with { Length = 0 } }] },
        plan with { Patches = [patch with { Before = patch.Before with { Path = patch.After.Path } }] },
        plan with { Patches = [patch with { After = patch.After with { Sha256 = patch.Before.Sha256 } }] } })
      Assert.Throws<InvalidOperationException>(invalid.Validate);
  }

  [Theory]
  [InlineData("apply", false)]
  [InlineData("restore", false)]
  [InlineData("unknown", true)]
  public void FileOperationsRejectMissingColdScopeOrUnknownModeBeforeOpeningAnyPath(string operation, bool cold)
  {
    var exception = Assert.Throws<InvalidOperationException>(() => NativeStoreOperations.Execute("not-a-path", "not-a-hash", operation, cold));
    Assert.Equal("user_validation_store_operation_rejected", exception.Message);
  }
}
