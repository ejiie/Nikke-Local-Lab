namespace NikkeLocalLab.PrivateServer.UnitTests;

public sealed class ExecutionAndDamageTests
{
  [Fact]
  public void RuntimeGraphicsRequiresExactFieldSetAndEveryMandatoryFieldReady()
  {
    Assert.Equal(
        "runtime_graphics_option_set_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            PrivateServerTestData.Graphics(appendExtra: true)).Code);

    var notApplicable = PrivateServerTestData.Graphics(ExecutionFactStatus.NotApplicable);
    Assert.False(notApplicable.IsLaunchReady);
    var unresolved = PrivateServerTestData.Graphics(ExecutionFactStatus.Unresolved);
    Assert.False(unresolved.IsLaunchReady);
    Assert.True(PrivateServerTestData.Graphics().IsLaunchReady);
  }

  [Fact]
  public void ExecutionCodeFactsMatchTheSixtyFourCharacterStorageBoundary()
  {
    var maximum = new string('a', 64);

    Assert.Equal(maximum, ExecutionCodeFact.Ready(maximum).ValueCode);
    Assert.Equal(
        "private_server_code_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            ExecutionCodeFact.Ready(new string('a', 65))).Code);
  }

  [Fact]
  public void LabHarnessReadinessDoesNotManufactureOriginalRuntimeEvidence()
  {
    var requested = PrivateServerTestData.RuntimeSettings();
    var unresolved = new RuntimeExecutionProfileContent(
        OriginalClientRuntimeBuildBinding.Unresolved(),
        requested,
        null);
    var ready = new RuntimeExecutionProfileContent(
        OriginalClientRuntimeBuildBinding.Ready(
            PrivateServerTestData.Uid(1),
            PrivateServerTestData.Digest("original-runtime-build")),
        requested,
        null);

    Assert.True(unresolved.IsHarnessValidationReady);
    Assert.False(unresolved.IsOriginalClientLaunchReady);
    Assert.True(ready.IsOriginalClientLaunchReady);
    Assert.NotEqual(unresolved.ContentSha256, ready.ContentSha256);
  }

  [Fact]
  public void ManualControlReadinessRequiresManualFactsButLeavesOptionalAutomationUnresolved()
  {
    var manual = PrivateServerTestData.ControlSettings();
    Assert.True(manual.IsManualBattleReady);

    Assert.Equal(
        "aim_assistant_intensity_required",
        Assert.Throws<PrivateServerIntegrityException>(() => new CombatControlSettingsSnapshot(
            ExecutionFact<decimal>.Ready(1m),
            ExecutionFact<bool>.Ready(true),
            ExecutionFact<decimal>.Unresolved("setting_unresolved"),
            ExecutionFact<bool>.Ready(false),
            ExecutionFact<bool>.Ready(true),
            ExecutionFact<bool>.Unresolved("optional_setting_unresolved"),
            ExecutionFact<bool>.Unresolved("optional_setting_unresolved"))).Code);
  }

  [Fact]
  public void StorageDecimalWidthsAndScalesFailClosedBeforePersistence()
  {
    Assert.Equal(
        "battle_frame_time_storage_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => new BattleFrameTelemetry(
            1, 1, 1, 1, 0.0001m, 0.0001m, 0.0001m, 0, 0)).Code);
    Assert.Equal(
        "runtime_refresh_rate_storage_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => new RuntimeDisplaySettings(
            ExecutionCodeFact.Ready("windows"),
            ExecutionCodeFact.Ready("fullscreen"),
            ExecutionFact<int>.Ready(1920),
            ExecutionFact<int>.Ready(1080),
            ExecutionFact<decimal>.Ready(60.0000000000001m))).Code);
    Assert.Equal(
        "combat_control_aim_intensity_storage_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => new CombatControlSettingsSnapshot(
            ExecutionFact<decimal>.Ready(1m),
            ExecutionFact<bool>.Ready(true),
            ExecutionFact<decimal>.Ready(0.000000001m),
            ExecutionFact<bool>.Ready(false),
            ExecutionFact<bool>.Ready(true),
            ExecutionFact<bool>.Unresolved("optional_setting_unresolved"),
            ExecutionFact<bool>.Unresolved("optional_setting_unresolved"))).Code);
  }

  [Theory]
  [InlineData("")]
  [InlineData("-1")]
  [InlineData("01")]
  [InlineData("1.0")]
  public void DamageObservationRejectsNonCanonicalValues(string value)
  {
    Assert.Equal(
        "damage_observation_value_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            NonNegativeIntegerDamage.Parse(value)).Code);
  }

  [Fact]
  public void DamageUsesExplicitDecimalContractAndDetectsLabStorageOverflow()
  {
    var maximum = NonNegativeIntegerDamage.Parse(new string('9', 78));
    Assert.Equal("nonnegative_integer_decimal/v1", NonNegativeIntegerDamage.ContractId);
    Assert.Equal(78, maximum.CanonicalDigits.Length);
    Assert.Equal(
        "damage_observation_sum_exceeds_lab_limit",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            NonNegativeIntegerDamage.Add(maximum, NonNegativeIntegerDamage.Parse("1"))).Code);
  }

  [Fact]
  public void ReceiptIsServerTypedAsLabHarnessAndSegmentsMustMatchTelemetry()
  {
    var profileData = PrivateServerTestData.ProfileWithSquads(1);
    var team = ChallengeTeamPin.Create(1, profileData.Profile, profileData.Squads[0]);
    var runtimeRevision = PrivateServerTestData.Uid(20);
    var controlRevision = PrivateServerTestData.Uid(21);
    var telemetry = new BattleFrameTelemetry(60, 60, 60, 1_000_000, 16m, 17m, 18m, 0, 0);
    var damage = NonNegativeIntegerDamage.Parse("12345678901234567890");
    var segment = new ExecutionSegment(
        1,
        runtimeRevision,
        controlRevision,
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
    var receipt = new LabHarnessTeamResultReceipt(
        PrivateServerTestData.Uid(22),
        PrivateServerTestData.Uid(23),
        team,
        damage,
        telemetry,
        [segment],
        null,
        PrivateServerTestData.Instant);

    Assert.Equal("lab_harness_observation/v1", receipt.ObservationSourceCode);
    Assert.False(receipt.IsOriginalClientRuntimeObservation);
    Assert.Equal(
        "challenge_result_segment_set_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            new LabHarnessTeamResultReceipt(
                PrivateServerTestData.Uid(24),
                PrivateServerTestData.Uid(23),
                team,
                damage,
                new BattleFrameTelemetry(61, 60, 60, 1_000_000, 16m, 17m, 18m, 0, 0),
                [segment],
                null,
                PrivateServerTestData.Instant)).Code);
  }

  [Fact]
  public void TelemetryAndReceiptWarningSetsAllowAtMostSixtyFourDistinctCodes()
  {
    var sixtyFour = Enumerable.Range(1, 64)
        .Select(static number => $"warning_{number:00}")
        .ToArray();
    var sixtyFive = sixtyFour.Append("warning_65").ToArray();
    var telemetry = new BattleFrameTelemetry(
        60,
        60,
        60,
        1_000_000,
        16m,
        17m,
        18m,
        0,
        0,
        sixtyFour);
    Assert.Equal(64, telemetry.WarningCodes.Count);
    Assert.Equal(
        "private_server_code_set_too_large",
        Assert.Throws<PrivateServerIntegrityException>(() => new BattleFrameTelemetry(
            60, 60, 60, 1_000_000, 16m, 17m, 18m, 0, 0, sixtyFive)).Code);

    var profileData = PrivateServerTestData.ProfileWithSquads(1);
    var team = ChallengeTeamPin.Create(1, profileData.Profile, profileData.Squads[0]);
    var damage = NonNegativeIntegerDamage.Parse("1");
    var segment = new ExecutionSegment(
        1,
        PrivateServerTestData.Uid(30),
        PrivateServerTestData.Uid(31),
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
    var receipt = new LabHarnessTeamResultReceipt(
        PrivateServerTestData.Uid(32),
        PrivateServerTestData.Uid(33),
        team,
        damage,
        telemetry,
        [segment],
        sixtyFour,
        PrivateServerTestData.Instant);
    Assert.Equal(64, receipt.WarningCodes.Count);
    Assert.Equal(
        "private_server_code_set_too_large",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            new LabHarnessTeamResultReceipt(
                PrivateServerTestData.Uid(34),
                PrivateServerTestData.Uid(33),
                team,
                damage,
                telemetry,
                [segment],
                sixtyFive,
                PrivateServerTestData.Instant)).Code);
  }

  [Theory]
  [InlineData("path/code")]
  [InlineData("UPPER")]
  public void ApplicationFailureCodesRemainControlled(string code)
  {
    Assert.Throws<ArgumentException>(() =>
        new PrivateServerApplicationException(PrivateServerFailureKind.InvalidRequest, code));
  }
}
