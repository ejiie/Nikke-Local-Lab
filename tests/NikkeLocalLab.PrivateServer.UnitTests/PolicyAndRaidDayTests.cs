using System.Globalization;

namespace NikkeLocalLab.PrivateServer.UnitTests;

public sealed class PolicyAndRaidDayTests
{
  [Fact]
  public void AsiaSeoulRaidDayChangesAtExactlyFiveAndNormalizesOffsets()
  {
    var before = new DateTimeOffset(2026, 8, 20, 4, 59, 59, TimeSpan.FromHours(9));
    var boundary = before.AddSeconds(1);

    Assert.Equal("2026-08-19", AsiaSeoulRaidDay.GetKey(before).Value);
    Assert.Equal("2026-08-20", AsiaSeoulRaidDay.GetKey(boundary).Value);
    Assert.Equal(
        AsiaSeoulRaidDay.GetKey(boundary),
        AsiaSeoulRaidDay.GetKey(boundary.ToOffset(TimeSpan.FromHours(-4))));
    Assert.Equal(
        new DateTimeOffset(2026, 8, 19, 20, 0, 0, TimeSpan.Zero),
        AsiaSeoulRaidDay.GetBoundaryUtc(RaidDayKey.Parse("2026-08-20")));
  }

  [Fact]
  public void OperationalPolicyIsAllOrNothingAndUnresolvedFailsAdmission()
  {
    var unresolved = ChallengeOperationalPolicy.CreateUnresolvedV1(
        PrivateServerTestData.Uid(1));

    Assert.False(unresolved.IsAdmissionReady);
    Assert.Equal(
        "challenge_operational_policy_unresolved",
        Assert.Throws<PrivateServerIntegrityException>(unresolved.RequireAdmissionReady).Code);
    Assert.Equal(
        "challenge_operational_policy_partially_configured",
        Assert.Throws<PrivateServerIntegrityException>(() => new ChallengeOperationalPolicy(
            PrivateServerTestData.Uid(2),
            "challenge-operational-policy/test/v1",
            PolicyFact<int>.Configured(1),
            PolicyFact<ChallengeEntryConsumptionPoint>.Unresolved("unknown"),
            PolicyFact<ActiveRunAtResetPolicy>.Unresolved("unknown"),
            PolicyFact<DailyCounterScope>.Unresolved("unknown"),
            PolicyFact<MockBattleCapability>.Unresolved("unknown"),
            PolicyFact<LocalRankingCapability>.Unresolved("unknown"))).Code);
  }

  [Fact]
  public void ControlledConfigurationCodesMaterializeExactInitialPolicy()
  {
    var unresolved = ChallengeOperationalPolicy.CreateFromControlledCodes(
        PrivateServerTestData.Uid(3),
        "challenge-operational-policy/unresolved/v1",
        "unresolved",
        null,
        "unresolved",
        "unresolved",
        "unresolved",
        "unresolved",
        "unresolved");
    Assert.False(unresolved.IsAdmissionReady);

    var configured = ChallengeOperationalPolicy.CreateFromControlledCodes(
        PrivateServerTestData.Uid(4),
        "challenge-operational-policy/config-composition/v1",
        "configured",
        3,
        "first_team_entered",
        "reject_post_boundary_progress",
        "shared_across_directory",
        "lab_owned_only",
        "local_records_only");
    Assert.True(configured.IsAdmissionReady);
    Assert.Equal(3, configured.DailyEntryLimit.RequireConfigured());
    Assert.Equal(
        ChallengeEntryConsumptionPoint.FirstTeamEntered,
        configured.EntryConsumptionPoint.RequireConfigured());
    Assert.Equal(
        ActiveRunAtResetPolicy.RejectPostBoundaryProgress,
        configured.ActiveRunAtReset.RequireConfigured());
    Assert.Equal(
        DailyCounterScope.SharedAcrossDirectory,
        configured.DailyCounterScope.RequireConfigured());
    Assert.Equal(
        MockBattleCapability.LabOwnedOnly,
        configured.MockBattleCapability.RequireConfigured());
    Assert.Equal(
        LocalRankingCapability.LocalRecordsOnly,
        configured.LocalRankingCapability.RequireConfigured());

    Assert.Equal(
        "challenge_entry_consumption_point_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            ChallengeOperationalPolicy.CreateFromControlledCodes(
                PrivateServerTestData.Uid(5),
                "challenge-operational-policy/config-composition/v1",
                "configured",
                3,
                "invalid",
                "pin_opening_raid_day",
                "per_season",
                "unsupported",
                "unsupported")).Code);
  }

  [Theory]
  [InlineData(0)]
  [InlineData(1_000_001)]
  public void OperationalPolicyRejectsEntryLimitsOutsidePersistenceRange(int limit)
  {
    Assert.Equal(
        "challenge_daily_entry_limit_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            PrivateServerTestData.ConfiguredPolicy(limit: limit)).Code);
  }

  [Fact]
  public void PolicyHashIsCultureInvariant()
  {
    var originalCulture = CultureInfo.CurrentCulture;
    var originalUiCulture = CultureInfo.CurrentUICulture;
    try
    {
      CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("ar-SA");
      CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("ar-SA");
      var first = PrivateServerTestData.ConfiguredPolicy(uid: 20, limit: 123456);
      CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("tr-TR");
      CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("tr-TR");
      var second = PrivateServerTestData.ConfiguredPolicy(uid: 21, limit: 123456);

      Assert.Equal(first.ContentSha256, second.ContentSha256);
    }
    finally
    {
      CultureInfo.CurrentCulture = originalCulture;
      CultureInfo.CurrentUICulture = originalUiCulture;
    }
  }

  [Fact]
  public void InitialActivationAcceptsUnresolvedOnlyForObservedDayAndRequiresCleanState()
  {
    var policy = ChallengeOperationalPolicy.CreateUnresolvedV1(
        PrivateServerTestData.Uid(30));
    var today = RaidDayKey.Parse("2026-08-20");
    var initial = ChallengeOperationalPolicyActivationRevision.CreateInitial(
        PrivateServerTestData.Uid(31),
        PrivateServerTestData.Uid(32),
        policy,
        today,
        PrivateServerTestData.Instant,
        today,
        0,
        0);

    Assert.Equal(policy.PolicyUid, initial.PolicyUid);
    Assert.Equal(
        "challenge_policy_activation_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            ChallengeOperationalPolicyActivationRevision.CreateInitial(
                PrivateServerTestData.Uid(33),
                PrivateServerTestData.Uid(34),
                policy,
                RaidDayKey.Parse("2026-08-21"),
                PrivateServerTestData.Instant,
                today,
                0,
                0)).Code);
    Assert.Equal(
        "challenge_policy_activation_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            ChallengeOperationalPolicyActivationRevision.CreateInitial(
                PrivateServerTestData.Uid(35),
                PrivateServerTestData.Uid(36),
                policy,
                today,
                PrivateServerTestData.Instant,
                today,
                1,
                0)).Code);
  }

  [Fact]
  public void SubsequentPolicyActivationIsFutureOnly()
  {
    var today = RaidDayKey.Parse("2026-08-20");
    var initialPolicy = ChallengeOperationalPolicy.CreateUnresolvedV1(
        PrivateServerTestData.Uid(40));
    var initial = ChallengeOperationalPolicyActivationRevision.CreateInitial(
        PrivateServerTestData.Uid(41),
        PrivateServerTestData.Uid(42),
        initialPolicy,
        today,
        PrivateServerTestData.Instant,
        today,
        0,
        0);
    var configured = PrivateServerTestData.ConfiguredPolicy(uid: 43);

    Assert.Equal(
        "challenge_policy_activation_requires_future_day",
        Assert.Throws<PrivateServerIntegrityException>(() => initial.Activate(
            PrivateServerTestData.Uid(44),
            configured,
            today,
            PrivateServerTestData.Instant.AddMinutes(1),
            today)).Code);
    var scheduled = initial.Activate(
        PrivateServerTestData.Uid(45),
        configured,
        RaidDayKey.Parse("2026-08-21"),
        PrivateServerTestData.Instant.AddMinutes(1),
        today);
    Assert.Equal(2, scheduled.RevisionNumber);
  }

  [Fact]
  public void DailyCountersAreIndependentPerDayAndPinDirectoryTopology()
  {
    var directory = PrivateServerTestData.Directory();
    var policy = PrivateServerTestData.ConfiguredPolicy(limit: 1);
    var account = PrivateServerTestData.Uid(50);
    var season = directory.RequireMember(7).RaidSnapshotUid;
    var firstDay = ChallengeDailyStateRevision.Open(
        PrivateServerTestData.Uid(51),
        PrivateServerTestData.Uid(52),
        account,
        RaidDayKey.Parse("2026-08-20"),
        season,
        directory,
        policy).ConsumeEntry(PrivateServerTestData.Uid(53), policy);
    var nextDay = ChallengeDailyStateRevision.Open(
        PrivateServerTestData.Uid(54),
        PrivateServerTestData.Uid(55),
        account,
        RaidDayKey.Parse("2026-08-21"),
        season,
        directory,
        policy);

    Assert.NotEqual(firstDay.DailyStateUid, nextDay.DailyStateUid);
    Assert.Null(typeof(ChallengeDailyStateRevision).GetMethod("Rollover"));
    Assert.Equal(1, firstDay.ConsumedEntries);
    Assert.Equal(0, nextDay.ConsumedEntries);
    Assert.Equal(directory.DirectoryUid, nextDay.DirectoryUid);
    Assert.Equal(
        "challenge_daily_entry_limit_reached",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            firstDay.ConsumeEntry(PrivateServerTestData.Uid(56), policy)).Code);
  }
}
