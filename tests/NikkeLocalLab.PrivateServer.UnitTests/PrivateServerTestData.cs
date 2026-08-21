namespace NikkeLocalLab.PrivateServer.UnitTests;

internal static class PrivateServerTestData
{
  internal static readonly DateTimeOffset Instant =
      new(2026, 8, 20, 0, 0, 0, TimeSpan.Zero);

  internal static EntityUid Uid(int value) =>
      new(new Guid(value, 0, 0, new byte[8]));

  internal static Sha256Digest Digest(string value) => Sha256Digest.ComputeUtf8(value);

  internal static ChallengeOperationalPolicy ConfiguredPolicy(
      int uid = 500,
      int limit = 3,
      ChallengeEntryConsumptionPoint consumption = ChallengeEntryConsumptionPoint.RunClosed,
      ActiveRunAtResetPolicy reset = ActiveRunAtResetPolicy.PinOpeningRaidDay,
      DailyCounterScope scope = DailyCounterScope.PerSeason,
      MockBattleCapability mock = MockBattleCapability.Unsupported,
      LocalRankingCapability ranking = LocalRankingCapability.Unsupported) =>
      ChallengeOperationalPolicy.CreateConfiguredV1(
          Uid(uid),
          "challenge-operational-policy/test/v1",
          limit,
          consumption,
          reset,
          scope,
          mock,
          ranking);

  internal static RaidSeasonDirectory Directory(int uid = 600)
  {
    var seasons = new[] { 7, 13, 26, 29, 34, 40 };
    return new RaidSeasonDirectory(
        Uid(uid),
        Instant,
        seasons.Select((season, index) => new RaidSeasonDirectoryMember(
            season,
            Uid(uid + 10 + index),
            Uid(uid + 20 + index),
            Uid(uid + 30 + index),
            Uid(uid + 40 + index),
            Digest($"raid-{season}"),
            "static_exact",
            SeasonPresentationBinding.Unresolved())));
  }

  internal static ClientFeatureManifestContent ClientFeatureV2()
  {
    var values = new Dictionary<string, ClientFeatureCapability>(StringComparer.Ordinal)
    {
      ["lobby.profile"] = ClientFeatureCapability.Supported,
      ["lobby.wallet"] = ClientFeatureCapability.Supported,
      ["lobby.nikke"] = ClientFeatureCapability.Supported,
      ["lobby.squad"] = ClientFeatureCapability.Supported,
      ["lobby.inventory"] = ClientFeatureCapability.Supported,
      ["lobby.recruit"] = ClientFeatureCapability.VisibleNoOp,
      ["lobby.messenger"] = ClientFeatureCapability.Hidden,
      ["lobby.tracing_the_stars"] = ClientFeatureCapability.Hidden,
      ["lobby.costume_pick"] = ClientFeatureCapability.Hidden,
      ["lobby.trail_marker"] = ClientFeatureCapability.Hidden,
      ["lobby.more"] = ClientFeatureCapability.Hidden,
      ["lobby.pickup_banner"] = ClientFeatureCapability.Hidden,
      ["lobby.right_side"] = ClientFeatureCapability.Hidden,
      ["lobby.shop"] = ClientFeatureCapability.Hidden,
      ["lobby.cash_shop"] = ClientFeatureCapability.Hidden,
      ["lobby.outpost"] = ClientFeatureCapability.Hidden,
      ["lobby.outpost_defense"] = ClientFeatureCapability.Hidden,
      ["lobby.solo_raid"] = ClientFeatureCapability.Supported,
      ["solo_raid.directory"] = ClientFeatureCapability.Supported,
      ["solo_raid.normal_battle"] = ClientFeatureCapability.NotSupported,
      ["solo_raid.quick_battle"] = ClientFeatureCapability.NotSupported,
      ["solo_raid.challenge"] = ClientFeatureCapability.Supported
    };
    return new ClientFeatureManifestContent(
        "nll/client-feature-manifest/v2",
        values.Select(static item => new ClientFeatureEntry(item.Key, item.Value)));
  }

  internal static PrivateServerCapabilityManifest CapabilityManifest(
      ChallengeOperationalPolicy policy,
      int uid = 700) =>
      PrivateServerCapabilityManifest.CreatePhase2B(
          Uid(uid),
          Uid(uid + 1),
          ClientFeatureV2(),
          policy);

  internal static (
      LocalClientContext Context,
      SelectedRaidSeasonRevision Selection,
      RaidSeasonDirectory Directory,
      PrivateServerCapabilityManifest Manifest) LobbyReadyContext(
          EntityUid accountUid,
          ChallengeOperationalPolicy policy)
  {
    var directory = Directory();
    var manifest = CapabilityManifest(policy);
    var sessionUid = Uid(800);
    var contextUid = Uid(801);
    var context = LocalClientContext.Open(
        contextUid,
        Uid(802),
        sessionUid,
        accountUid,
        Uid(803),
        Digest("lab-application-build"),
        "nll/private-server-application/lab/v1",
        manifest,
        Instant,
        Instant.AddDays(2));
    var selection = SelectedRaidSeasonRevision.CreateInitial(
        Uid(804),
        Uid(805),
        accountUid,
        sessionUid,
        contextUid,
        directory,
        directory.RequireMember(7).RaidSnapshotUid,
        Instant.AddMinutes(1));
    context = context.Connect(
        Uid(806),
        Instant.AddMinutes(1),
        selection.SelectionRevisionUid,
        selection.ContentSha256);
    context = context.BindLobby(
        Uid(807),
        Instant.AddMinutes(2),
        Digest("account-revision-set"),
        selection.SelectionRevisionUid,
        selection.ContentSha256);
    return (context, selection, directory, manifest);
  }

  internal static RuntimeGraphicsSettings Graphics(
      ExecutionFactStatus status = ExecutionFactStatus.Ready,
      bool appendExtra = false)
  {
    var fields = new[]
    {
      "anti_aliasing_enabled",
      "anti_aliasing_step",
      "battle_animation_physics_flags",
      "battle_effect_quality",
      "default_quality_level",
      "graphic_option_mode",
      "mesh_quality",
      "post_process_flags",
      "spine_resolution",
      "texture_quality",
      "volumetric_fog_quality"
    };
    var options = fields.Select(field => new RuntimeGraphicsOption(
        field,
        status switch
        {
          ExecutionFactStatus.Ready => ExecutionCodeFact.Ready("controlled"),
          ExecutionFactStatus.Unresolved => ExecutionCodeFact.Unresolved("setting_unresolved"),
          ExecutionFactStatus.NotApplicable => ExecutionCodeFact.NotApplicable(),
          _ => throw new ArgumentOutOfRangeException(nameof(status))
        })).ToList();
    if (appendExtra)
    {
      options.Add(new RuntimeGraphicsOption("unknown_extra", ExecutionCodeFact.Ready("controlled")));
    }

    return new RuntimeGraphicsSettings(options);
  }

  internal static RuntimeExecutionSettingsSnapshot RuntimeSettings(
      RuntimeGraphicsSettings? graphics = null) =>
      new(
          new RuntimeSchedulerSettings(
              ExecutionFact<TargetFrameRate>.Ready(TargetFrameRate.Fps60),
              ExecutionFact<int>.Ready(60),
              ExecutionFact<bool>.Ready(false),
              ExecutionFact<bool>.Ready(false),
              ExecutionFact<TimeScalePolicy>.Ready(TimeScalePolicy.NormalOneX)),
          new RuntimeDisplaySettings(
              ExecutionCodeFact.Ready("windows"),
              ExecutionCodeFact.Ready("fullscreen"),
              ExecutionFact<int>.Ready(1920),
              ExecutionFact<int>.Ready(1080),
              ExecutionFact<decimal>.Ready(60m)),
          graphics ?? Graphics());

  internal static RuntimeExecutionProfileRevision RuntimeProfile(EntityUid accountUid) =>
      RuntimeExecutionProfileRevision.Create(
          Uid(900),
          Uid(901),
          accountUid,
          Instant,
          new RuntimeExecutionProfileContent(
              OriginalClientRuntimeBuildBinding.Unresolved(),
              RuntimeSettings(),
              null));

  internal static CombatControlSettingsSnapshot ControlSettings() =>
      new(
          ExecutionFact<decimal>.Ready(1m),
          ExecutionFact<bool>.Ready(false),
          ExecutionFact<decimal>.NotApplicable(),
          ExecutionFact<bool>.Ready(false),
          ExecutionFact<bool>.Ready(true),
          ExecutionFact<bool>.Unresolved("optional_setting_unresolved"),
          ExecutionFact<bool>.Unresolved("optional_setting_unresolved"));

  internal static CombatControlProfileRevision ControlProfile(EntityUid accountUid) =>
      CombatControlProfileRevision.Create(
          Uid(910),
          Uid(911),
          accountUid,
          Instant,
          new CombatControlProfileContent(ControlSettings(), null));

  internal static (
      LocalAccount Account,
      ProfileTemplateRevision Profile,
      IReadOnlyList<SquadRevisionReference> Squads) ProfileWithSquads(int squadCount = 2)
  {
    var account = ProfileTestData.Account(1_000);
    var catalog = ProfileTestData.SupportCatalog();
    var characterCount = checked(squadCount * 5);
    var characters = Enumerable.Range(0, characterCount)
        .Select(index => ProfileTestData.CharacterVersion(
            2_000 + index,
            3_000 + index))
        .ToArray();
    var evidence = ProfileTestData.Evidence(characters, catalog.All);
    var builds = characters.Select((character, index) => ProfileTestData.ExplicitBuild(
        4_000 + index,
        5_000 + index,
        2_000 + index,
        catalog,
        account,
        characterVersionUid: 3_000 + index,
        characterDefinitionVersion: character,
        catalogEvidence: evidence)).ToArray();
    var accountState = ProfileTestData.AccountState(
        account,
        catalog,
        catalogEvidence: evidence);
    var squads = Enumerable.Range(0, squadCount).Select(index => SquadRevision.Create(
        Uid(6_000 + index),
        new Squad(Uid(6_100 + index), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        builds.Skip(index * 5).Take(5))).ToArray();
    var profile = ProfileTemplateRevision.Create(
        Uid(7_000),
        new ProfileTemplate(Uid(7_001), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        accountState,
        builds,
        squads[0]);
    return (account, profile, squads.Select(static squad => squad.ToReference()).ToArray());
  }
}
