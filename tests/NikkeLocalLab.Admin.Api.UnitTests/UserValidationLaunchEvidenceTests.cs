using System.Text.Json;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationLaunchEvidenceTests
{
  private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-09-13T12:00:00Z");
  private static readonly string Hash = new('e', 64);
  private static Dictionary<string, object> Evidence()
  {
    var p = UserValidationBootstrapPlanTests.Example();
    return new()
    {
      ["contractId"] = "nll/native-fx-user-validation-isolation/v1",
      ["assessmentUid"] = p.AssessmentUid,
      ["trialUid"] = p.TrialUid,
      ["executionOwnerCode"] = "user",
      ["bootstrapPlanSha256"] = Hash,
      ["parentPlanSha256"] = p.ParentPlanSha256,
      ["nativeStoreSha256"] = p.NativeStore.Sha256,
      ["caseCode"] = p.CaseCode,
      ["driverPolicyCode"] = "nll/user-validation-ace-advt/v1",
      ["driverAuthorizationId"] = "operator-2026-09-13-user-launched-ace-advt/v1",
      ["allProgramsBlocked"] = true,
      ["rollbackPrepared"] = true,
      ["systemChangesVerified"] = true,
      ["managedServiceBaselineVerified"] = true,
      ["managedDriverBaselineVerified"] = true,
      ["preparedAccountVerified"] = true,
      ["independentServerVerified"] = true,
      ["protectedInputsUnchanged"] = true,
      ["verifiedAtUtc"] = Now
    };
  }
  private static void Validate(Dictionary<string, object> evidence) => UserValidationLaunchEvidence.ValidateIsolation(
      UserValidationBootstrapPlanTests.Example(), Hash, JsonSerializer.SerializeToElement(evidence), Now);
  public static IEnumerable<object[]> Fields() => Evidence().Keys.Where(name => name != "verifiedAtUtc").Select(name => new object[] { name });
  [Theory]
  [MemberData(nameof(Fields))]
  public void EveryBindingAndRequiredProofMustBePresentAndMatch(string field)
  {
    var e = Evidence();
    Validate(e);
    e.Remove(field);
    Assert.ThrowsAny<Exception>(() => Validate(e));
    e = Evidence();
    e[field] = e[field] is bool ? false : "not-the-pinned-value";
    Assert.ThrowsAny<Exception>(() => Validate(e));
  }
  [Theory]
  [InlineData(-300, false)]
  [InlineData(-299, true)]
  [InlineData(0, true)]
  [InlineData(1, false)]
  public void ReadyEvidenceMustBeRecentAndNeverFromTheFuture(int seconds, bool accepted)
  {
    var e = Evidence();
    e["verifiedAtUtc"] = Now.AddSeconds(seconds);
    if (accepted) Validate(e);
    else Assert.Throws<InvalidOperationException>(() => Validate(e));
  }
  [Fact]
  public void DuplicateFieldsAndInvalidPlanHashCannotCreateAnAlternativePermit()
  {
    var json = JsonSerializer.Serialize(Evidence());
    using var doc = JsonDocument.Parse("{\"allProgramsBlocked\":false," + json[1..]);
    Assert.Throws<InvalidOperationException>(() => UserValidationLaunchEvidence.ValidateIsolation(
        UserValidationBootstrapPlanTests.Example(), Hash, doc.RootElement, Now));
    Assert.Throws<InvalidOperationException>(() => UserValidationLaunchEvidence.ValidateIsolation(
        UserValidationBootstrapPlanTests.Example(), "", JsonSerializer.SerializeToElement(Evidence()), Now));
  }
  [Fact]
  public void ParentMustBindThePreparedUserTrialAndExactBossCandidate()
  {
    var p = UserValidationBootstrapPlanTests.Example();
    var parent = new Dictionary<string, object>
    {
      ["contractId"] = "nll/native-fx-user-validation/v1",
      ["trialUid"] = p.TrialUid,
      ["assessmentUid"] = p.AssessmentUid,
      ["caseCode"] = p.CaseCode,
      ["executionOwnerCode"] = "user",
      ["seasonNumber"] = p.SeasonNumber,
      ["weaknessCode"] = p.WeaknessCode,
      ["profileSha256"] = p.ProfileSha256,
      ["candidateReceiptSha256"] = p.CandidateReceiptSha256
    };
    void Check(Dictionary<string, object> value) => UserValidationLaunchEvidence.ValidateParent(p, JsonSerializer.SerializeToElement(value));
    Check(parent);
    foreach (var field in parent.Keys)
    {
      var copy = new Dictionary<string, object>(parent);
      copy.Remove(field);
      Assert.ThrowsAny<Exception>(() => Check(copy));
      copy[field] = parent[field] is int ? 26 : "wrong";
      Assert.ThrowsAny<Exception>(() => Check(copy));
    }
  }
}
