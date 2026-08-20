namespace NikkeLocalLab.PrivateServer.UnitTests;

public sealed class ChallengeRunTests
{
  [Fact]
  public void RunPinsDailyStateAndCompletesOrderedTeamsWithExactDamageSum()
  {
    var fixture = Fixture(teamCount: 2);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_000),
        PrivateServerTestData.Uid(10_001),
        fixture.Binding,
        fixture.OpenedAtUtc);

    run = run.EnterTeam(
        PrivateServerTestData.Uid(10_002),
        1,
        fixture.OpenedAtUtc.AddSeconds(1));
    run = run.AcceptTeamResult(
        PrivateServerTestData.Uid(10_003),
        Receipt(run, fixture, 1, "999999999999999999", fixture.OpenedAtUtc.AddSeconds(2)));
    run = run.PrepareRegroup(
        PrivateServerTestData.Uid(10_004),
        fixture.OpenedAtUtc.AddSeconds(3));
    run = run.EnterTeam(
        PrivateServerTestData.Uid(10_005),
        2,
        fixture.OpenedAtUtc.AddSeconds(4));
    run = run.AcceptTeamResult(
        PrivateServerTestData.Uid(10_006),
        Receipt(run, fixture, 2, "1", fixture.OpenedAtUtc.AddSeconds(5)));
    run = run.Close(
        PrivateServerTestData.Uid(10_007),
        PrivateServerTestData.Uid(10_008),
        fixture.OpenedAtUtc.AddSeconds(6));

    Assert.Equal(ChallengeRunState.Completed, run.State);
    Assert.Equal("1000000000000000000", run.CumulativeDamage.CanonicalDigits);
    Assert.Equal(fixture.Daily.DailyStateUid, run.Binding.DailyStateUid);
    Assert.Equal(fixture.Daily.DailyStateRevisionUid, run.Binding.DailyStateRevisionUid);
    Assert.Equal(fixture.Daily.ContentSha256, run.Binding.DailyStateContentSha256);
    Assert.True(run.TransitionConsumesAttempt(ChallengeEntryConsumptionPoint.RunClosed));
  }

  [Fact]
  public void ResultSegmentsMustUseTheProfilesPinnedAtRunOpen()
  {
    var fixture = Fixture(teamCount: 1);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_100),
        PrivateServerTestData.Uid(10_101),
        fixture.Binding,
        fixture.OpenedAtUtc).EnterTeam(
            PrivateServerTestData.Uid(10_102),
            1,
            fixture.OpenedAtUtc.AddSeconds(1));
    var receipt = Receipt(
        run,
        fixture,
        1,
        "10",
        fixture.OpenedAtUtc.AddSeconds(2),
        runtimeRevisionUid: PrivateServerTestData.Uid(99_999));

    Assert.Equal(
        "challenge_team_result_transition_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => run.AcceptTeamResult(
            PrivateServerTestData.Uid(10_103),
            receipt)).Code);
  }

  [Fact]
  public void RestoreRejectsAcceptedReceiptWhoseExecutionProfilesDoNotMatchRunPins()
  {
    var fixture = Fixture(teamCount: 1);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_110),
        PrivateServerTestData.Uid(10_111),
        fixture.Binding,
        fixture.OpenedAtUtc).EnterTeam(
            PrivateServerTestData.Uid(10_112),
            1,
            fixture.OpenedAtUtc.AddSeconds(1));
    var receipt = Receipt(
        run,
        fixture,
        1,
        "10",
        fixture.OpenedAtUtc.AddSeconds(2),
        runtimeRevisionUid: PrivateServerTestData.Uid(99_998));
    var attempt = run.Attempts[0] with { ResultReceipt = receipt };

    Assert.Equal(
        "challenge_run_attempt_binding_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => ChallengeRun.Restore(
            run.RunUid,
            PrivateServerTestData.Uid(10_113),
            run.RevisionNumber + 1,
            run.RunRevisionUid,
            run.Binding,
            ChallengeRunState.TeamResultAccepted,
            run.OpenedAtUtc,
            receipt.ObservedAtUtc,
            [attempt],
            receipt.ObservedDamage,
            null,
            null,
            null)).Code);
  }

  [Fact]
  public void RunBindingRejectsPolicyThatDoesNotMatchContextCapabilityManifest()
  {
    var profileData = PrivateServerTestData.ProfileWithSquads(1);
    var manifestPolicy = PrivateServerTestData.ConfiguredPolicy(uid: 10_200);
    var passedPolicy = PrivateServerTestData.ConfiguredPolicy(uid: 10_201, limit: 4);
    var lobby = PrivateServerTestData.LobbyReadyContext(
        profileData.Account.LocalAccountUid,
        manifestPolicy);
    var openedAt = PrivateServerTestData.Instant.AddMinutes(5);
    var daily = ChallengeDailyStateRevision.Open(
        PrivateServerTestData.Uid(10_202),
        PrivateServerTestData.Uid(10_203),
        profileData.Account.LocalAccountUid,
        AsiaSeoulRaidDay.GetKey(openedAt),
        lobby.Selection.Member.RaidSnapshotUid,
        lobby.Directory,
        passedPolicy);

    Assert.Equal(
        "challenge_run_admission_binding_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            ChallengeRunBinding.CreateForLabHarness(
                lobby.Context,
                lobby.Selection,
                lobby.Directory,
                daily,
                passedPolicy,
                lobby.Manifest,
                PrivateServerTestData.RuntimeProfile(profileData.Account.LocalAccountUid),
                PrivateServerTestData.ControlProfile(profileData.Account.LocalAccountUid),
                profileData.Profile,
                profileData.Squads,
                false,
                openedAt)).Code);
  }

  [Fact]
  public void RejectBoundaryPolicyBlocksCloseButAbandonStillReleasesActiveSlot()
  {
    var openedAt = new DateTimeOffset(2026, 8, 20, 19, 59, 0, TimeSpan.Zero);
    var fixture = Fixture(
        teamCount: 1,
        openedAtUtc: openedAt,
        reset: ActiveRunAtResetPolicy.RejectPostBoundaryProgress);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_300),
        PrivateServerTestData.Uid(10_301),
        fixture.Binding,
        openedAt).EnterTeam(
            PrivateServerTestData.Uid(10_302),
            1,
            openedAt.AddSeconds(10));
    run = run.AcceptTeamResult(
        PrivateServerTestData.Uid(10_303),
        Receipt(run, fixture, 1, "10", openedAt.AddSeconds(20)));
    var afterBoundary = new DateTimeOffset(2026, 8, 20, 20, 0, 0, TimeSpan.Zero);

    Assert.Equal(
        "challenge_run_crossed_raid_day_boundary",
        Assert.Throws<PrivateServerIntegrityException>(() => run.Close(
            PrivateServerTestData.Uid(10_304),
            PrivateServerTestData.Uid(10_305),
            afterBoundary)).Code);
    var abandoned = run.Abandon(
        PrivateServerTestData.Uid(10_306),
        PrivateServerTestData.Uid(10_307),
        "client_exit",
        afterBoundary);
    Assert.Equal(ChallengeRunState.Abandoned, abandoned.State);
    Assert.True(abandoned.AbandonmentConsumesAttempt);
  }

  [Fact]
  public void AbandonBeforeFirstTeamDoesNotConsumeRunClosedPolicy()
  {
    var fixture = Fixture(teamCount: 1);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_400),
        PrivateServerTestData.Uid(10_401),
        fixture.Binding,
        fixture.OpenedAtUtc).Abandon(
            PrivateServerTestData.Uid(10_402),
            PrivateServerTestData.Uid(10_403),
            "client_exit",
            fixture.OpenedAtUtc.AddSeconds(1));

    Assert.False(run.AbandonmentConsumesAttempt);
    Assert.Equal("abandoned", ChallengeRun.StateCode(run.State));
  }

  [Fact]
  public void InactiveOwningSessionRecoverySealsServerOwnedReasonAndPreservesConsumption()
  {
    var fixture = Fixture(teamCount: 1);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_450),
        PrivateServerTestData.Uid(10_451),
        fixture.Binding,
        fixture.OpenedAtUtc).EnterTeam(
            PrivateServerTestData.Uid(10_452),
            1,
            fixture.OpenedAtUtc.AddSeconds(1));

    Assert.Equal(
        "challenge_abandon_reason_reserved_for_recovery",
        Assert.Throws<PrivateServerIntegrityException>(() => run.Abandon(
            PrivateServerTestData.Uid(10_453),
            PrivateServerTestData.Uid(10_454),
            ChallengeRun.OwningSessionInactiveRecoveryReasonCode,
            fixture.OpenedAtUtc.AddSeconds(2))).Code);

    var recovered = run.RecoverAfterOwningSessionInactive(
        PrivateServerTestData.Uid(10_455),
        PrivateServerTestData.Uid(10_456),
        fixture.OpenedAtUtc.AddSeconds(2));

    Assert.Equal(ChallengeRunState.Abandoned, recovered.State);
    Assert.Equal(
        ChallengeRun.OwningSessionInactiveRecoveryReasonCode,
        recovered.AbandonReasonCode);
    Assert.True(recovered.AbandonmentConsumesAttempt);
  }

  [Fact]
  public void RunPlanRejectsCharacterReuseAcrossTeams()
  {
    var profileData = PrivateServerTestData.ProfileWithSquads(1);
    var first = ChallengeTeamPin.Create(1, profileData.Profile, profileData.Squads[0]);
    var second = ChallengeTeamPin.Create(2, profileData.Profile, profileData.Squads[0]);

    Assert.Equal(
        "challenge_run_plan_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            new ChallengeRunPlan([first, second])).Code);
  }

  [Fact]
  public void PersistedBindingAndRunRevisionRestoreToExactCanonicalContent()
  {
    var fixture = Fixture(teamCount: 1);
    var binding = fixture.Binding;
    var restoredBinding = ChallengeRunBinding.Restore(
        new ChallengeRunBindingSnapshot(
            binding.AccountUid,
            binding.SessionUid,
            binding.ClientContextUid,
            binding.ClientContextRevisionUid,
            binding.ApplicationBuildUid,
            binding.ApplicationBuildSha256,
            binding.ApplicationContractId,
            binding.CapabilityManifestUid,
            binding.CapabilityManifestSha256,
            binding.DirectoryUid,
            binding.DirectoryContentSha256,
            binding.DailyStateUid,
            binding.DailyStateRevisionUid,
            binding.DailyStateContentSha256,
            binding.SelectedSeasonRevisionUid,
            binding.SelectedSeasonContentSha256,
            binding.RaidSnapshotUid,
            binding.RaidDatasetSnapshotUid,
            binding.RaidSnapshotContentSha256,
            binding.ProfileRevisionUid,
            binding.ProfileContentSha256,
            binding.AccountCombatStateRevisionUid,
            binding.RuntimeExecutionProfileRevisionUid,
            binding.RuntimeExecutionProfileContentSha256,
            binding.CombatControlProfileRevisionUid,
            binding.CombatControlProfileContentSha256,
            binding.OperationalPolicyUid,
            binding.OperationalPolicySha256,
            binding.EntryConsumptionPoint,
            binding.ActiveRunAtReset,
            binding.DailyCounterScope,
            binding.IsMockBattle,
            binding.RaidDayKey),
        binding.Plan);
    var run = ChallengeRun.Open(
        PrivateServerTestData.Uid(10_500),
        PrivateServerTestData.Uid(10_501),
        binding,
        fixture.OpenedAtUtc).EnterTeam(
            PrivateServerTestData.Uid(10_502),
            1,
            fixture.OpenedAtUtc.AddSeconds(1));
    run = run.AcceptTeamResult(
        PrivateServerTestData.Uid(10_503),
        Receipt(run, fixture, 1, "123", fixture.OpenedAtUtc.AddSeconds(2)));
    var restoredRun = ChallengeRun.Restore(
        run.RunUid,
        run.RunRevisionUid,
        run.RevisionNumber,
        run.PredecessorRevisionUid,
        restoredBinding,
        run.State,
        run.OpenedAtUtc,
        run.UpdatedAtUtc,
        run.Attempts,
        run.CumulativeDamage,
        run.FinalResultUid,
        run.AbandonmentUid,
        run.AbandonReasonCode);

    Assert.Equal(binding.ContentSha256, restoredBinding.ContentSha256);
    Assert.Equal(run.ContentSha256, restoredRun.ContentSha256);
    Assert.Equal(run.RunRevisionUid, restoredRun.RunRevisionUid);
  }

  private static RunFixture Fixture(
      int teamCount,
      DateTimeOffset? openedAtUtc = null,
      ActiveRunAtResetPolicy reset = ActiveRunAtResetPolicy.PinOpeningRaidDay)
  {
    var profileData = PrivateServerTestData.ProfileWithSquads(teamCount);
    var policy = PrivateServerTestData.ConfiguredPolicy(reset: reset);
    var lobby = PrivateServerTestData.LobbyReadyContext(
        profileData.Account.LocalAccountUid,
        policy);
    var openedAt = openedAtUtc ?? PrivateServerTestData.Instant.AddMinutes(5);
    var daily = ChallengeDailyStateRevision.Open(
        PrivateServerTestData.Uid(11_000),
        PrivateServerTestData.Uid(11_001),
        profileData.Account.LocalAccountUid,
        AsiaSeoulRaidDay.GetKey(openedAt),
        lobby.Selection.Member.RaidSnapshotUid,
        lobby.Directory,
        policy);
    var runtime = PrivateServerTestData.RuntimeProfile(profileData.Account.LocalAccountUid);
    var control = PrivateServerTestData.ControlProfile(profileData.Account.LocalAccountUid);
    var binding = ChallengeRunBinding.CreateForLabHarness(
        lobby.Context,
        lobby.Selection,
        lobby.Directory,
        daily,
        policy,
        lobby.Manifest,
        runtime,
        control,
        profileData.Profile,
        profileData.Squads,
        false,
        openedAt);
    return new RunFixture(binding, daily, runtime, control, openedAt);
  }

  private static LabHarnessTeamResultReceipt Receipt(
      ChallengeRun run,
      RunFixture fixture,
      int teamOrdinal,
      string damageDigits,
      DateTimeOffset observedAtUtc,
      EntityUid? runtimeRevisionUid = null)
  {
    var damage = NonNegativeIntegerDamage.Parse(damageDigits);
    var telemetry = new BattleFrameTelemetry(
        60,
        60,
        60,
        1_000_000,
        16m,
        17m,
        18m,
        0,
        0);
    var segment = new ExecutionSegment(
        1,
        runtimeRevisionUid ?? fixture.Runtime.RevisionUid,
        fixture.Control.RevisionUid,
        0,
        60,
        0,
        60,
        0,
        60,
        0,
        1_000_000,
        NonNegativeIntegerDamage.Zero,
        damage);
    return new LabHarnessTeamResultReceipt(
        PrivateServerTestData.Uid(12_000 + teamOrdinal),
        run.RunUid,
        fixture.Binding.Plan.Teams[teamOrdinal - 1],
        damage,
        telemetry,
        [segment],
        null,
        observedAtUtc);
  }

  private sealed record RunFixture(
      ChallengeRunBinding Binding,
      ChallengeDailyStateRevision Daily,
      RuntimeExecutionProfileRevision Runtime,
      CombatControlProfileRevision Control,
      DateTimeOffset OpenedAtUtc);
}
