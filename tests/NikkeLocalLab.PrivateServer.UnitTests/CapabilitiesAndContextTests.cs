namespace NikkeLocalLab.PrivateServer.UnitTests;

public sealed class CapabilitiesAndContextTests
{
  [Fact]
  public void FixedSoloRaidCapabilitiesMatchDeclaredPrivateServerSurface()
  {
    var value = SoloRaidFixedCapabilities.V1;

    Assert.False(value.NormalStagesImplemented);
    Assert.Equal(7, value.NormalLastClearLevel);
    Assert.True(value.ChallengeUnlocked);
    Assert.Equal("unsupported", value.NormalCombatCapabilityCode);
    Assert.Equal("unsupported", value.QuickBattleCapabilityCode);
    Assert.Equal("permanent", value.SeasonAvailabilityCode);
    Assert.Null(value.SeasonEndsAtUtc);
  }

  [Fact]
  public void DirectoryIsExactlySixPermanentSeasonsAndHasNoImplicitSelection()
  {
    var directory = PrivateServerTestData.Directory();

    Assert.Equal(new[] { 7, 13, 26, 29, 34, 40 },
        directory.Members.Select(static member => member.SeasonNumber));
    Assert.All(directory.Members, member =>
    {
      Assert.Equal(SeasonAvailability.Permanent, member.Availability);
      Assert.Null(member.SeasonEndsAtUtc);
    });
    Assert.Equal(
        "raid_season_not_in_directory",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            directory.RequireMember(PrivateServerTestData.Uid(999_999))).Code);

    var omitted = directory.Members.Take(5);
    Assert.Equal(
        "raid_season_directory_v1_members_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() => new RaidSeasonDirectory(
            PrivateServerTestData.Uid(1),
            PrivateServerTestData.Instant,
            omitted)).Code);
  }

  [Fact]
  public void Phase2BCapabilityManifestRequiresExactV2RoutesAndBindsPolicy()
  {
    var configured = PrivateServerTestData.ConfiguredPolicy(uid: 100);
    var first = PrivateServerTestData.CapabilityManifest(configured, uid: 101);
    var changed = PrivateServerTestData.CapabilityManifest(
        PrivateServerTestData.ConfiguredPolicy(uid: 102, limit: 4),
        uid: 101);

    Assert.Equal("nll/client-feature-manifest/v2", first.ClientFeatureManifest.ContractVersion);
    Assert.Equal(22, first.ClientFeatureManifest.Entries.Count);
    Assert.True(first.IsBackendChallengeStateSupported);
    Assert.True(first.IsOriginalClientPresentationAdapterBlocked);
    Assert.Equal(configured.PolicyUid, first.OperationalPolicyUid);
    Assert.NotEqual(first.ContentSha256, changed.ContentSha256);

    var v1 = new ClientFeatureManifestContent(
        "nll/client-feature-manifest/v1",
        PrivateServerTestData.ClientFeatureV2().Entries);
    Assert.Equal(
        "phase2b_client_feature_manifest_contract_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            PrivateServerCapabilityManifest.CreatePhase2B(
                PrivateServerTestData.Uid(103),
                PrivateServerTestData.Uid(104),
                v1,
                configured)).Code);

    var wrongRoutes = new ClientFeatureManifestContent(
        "nll/client-feature-manifest/v2",
        PrivateServerTestData.ClientFeatureV2().Entries.Where(static entry =>
            entry.RouteCode != "solo_raid.directory"));
    Assert.Equal(
        "phase2b_client_feature_manifest_entries_invalid",
        Assert.Throws<PrivateServerIntegrityException>(() =>
            PrivateServerCapabilityManifest.CreatePhase2B(
                PrivateServerTestData.Uid(105),
                PrivateServerTestData.Uid(106),
                wrongRoutes,
                configured)).Code);
  }

  [Fact]
  public void LoadingContextRequiresExplicitSelectionThenSupportsLobbyReadyRebind()
  {
    var policy = PrivateServerTestData.ConfiguredPolicy();
    var manifest = PrivateServerTestData.CapabilityManifest(policy);
    var directory = PrivateServerTestData.Directory();
    var account = PrivateServerTestData.Uid(200);
    var session = PrivateServerTestData.Uid(201);
    var contextUid = PrivateServerTestData.Uid(202);
    var context = LocalClientContext.Open(
        contextUid,
        PrivateServerTestData.Uid(203),
        session,
        account,
        PrivateServerTestData.Uid(204),
        PrivateServerTestData.Digest("lab-build"),
        "nll/private-server-application/test/v1",
        manifest,
        PrivateServerTestData.Instant,
        PrivateServerTestData.Instant.AddHours(1));

    Assert.Equal(ClientContextStage.Loading, context.Stage);
    Assert.Null(context.SelectedSeasonRevisionUid);
    var selection = SelectedRaidSeasonRevision.CreateInitial(
        PrivateServerTestData.Uid(205),
        PrivateServerTestData.Uid(206),
        account,
        session,
        contextUid,
        directory,
        directory.RequireMember(13).RaidSnapshotUid,
        PrivateServerTestData.Instant.AddMinutes(1));
    context = context.Connect(
        PrivateServerTestData.Uid(207),
        PrivateServerTestData.Instant.AddMinutes(1),
        selection.SelectionRevisionUid,
        selection.ContentSha256);
    Assert.Equal(ClientContextStage.LocalConnected, context.Stage);
    Assert.Equal(2, context.RevisionNumber);
    Assert.Equal(PrivateServerTestData.Uid(203), context.PredecessorRevisionUid);
    context = context.BindLobby(
        PrivateServerTestData.Uid(208),
        PrivateServerTestData.Instant.AddMinutes(2),
        PrivateServerTestData.Digest("account-set"),
        selection.SelectionRevisionUid,
        selection.ContentSha256);
    var changedSelection = selection.Select(
        PrivateServerTestData.Uid(209),
        directory,
        directory.RequireMember(40).RaidSnapshotUid,
        PrivateServerTestData.Instant.AddMinutes(3));
    var rebound = context.RebindSelectedSeason(
        PrivateServerTestData.Uid(210),
        PrivateServerTestData.Instant.AddMinutes(3),
        changedSelection.SelectionRevisionUid,
        changedSelection.ContentSha256);

    Assert.Equal(ClientContextStage.LobbyReady, rebound.Stage);
    Assert.Equal(changedSelection.SelectionRevisionUid, rebound.SelectedSeasonRevisionUid);
    Assert.Equal(context.RevisionNumber + 1, rebound.RevisionNumber);
  }

  [Fact]
  public void ContextTransitionsFailClosedAtExpiryAndOnWrongSelectionPin()
  {
    var policy = PrivateServerTestData.ConfiguredPolicy();
    var manifest = PrivateServerTestData.CapabilityManifest(policy);
    var context = LocalClientContext.Open(
        PrivateServerTestData.Uid(300),
        PrivateServerTestData.Uid(301),
        PrivateServerTestData.Uid(302),
        PrivateServerTestData.Uid(303),
        PrivateServerTestData.Uid(304),
        PrivateServerTestData.Digest("lab-build"),
        "nll/private-server-application/test/v1",
        manifest,
        PrivateServerTestData.Instant,
        PrivateServerTestData.Instant.AddMinutes(1));

    Assert.Equal(
        "private_server_local_session_not_active",
        Assert.Throws<PrivateServerIntegrityException>(() => context.Connect(
            PrivateServerTestData.Uid(305),
            PrivateServerTestData.Instant.AddMinutes(1),
            PrivateServerTestData.Uid(306),
            PrivateServerTestData.Digest("selection"))).Code);
  }

  [Fact]
  public void ContextTimestampsCanonicalizeToUtcMicroseconds()
  {
    var policy = PrivateServerTestData.ConfiguredPolicy();
    var manifest = PrivateServerTestData.CapabilityManifest(policy);
    var baseInstant = new DateTimeOffset(638913312000000000L, TimeSpan.Zero);
    var withSubMicrosecond = baseInstant.AddTicks(7).ToOffset(TimeSpan.FromHours(9));
    var first = LocalClientContext.Open(
        PrivateServerTestData.Uid(350),
        PrivateServerTestData.Uid(351),
        PrivateServerTestData.Uid(352),
        PrivateServerTestData.Uid(353),
        PrivateServerTestData.Uid(354),
        PrivateServerTestData.Digest("lab-build"),
        "nll/private-server-application/test/v1",
        manifest,
        withSubMicrosecond,
        withSubMicrosecond.AddHours(1));
    var second = LocalClientContext.Open(
        PrivateServerTestData.Uid(350),
        PrivateServerTestData.Uid(351),
        PrivateServerTestData.Uid(352),
        PrivateServerTestData.Uid(353),
        PrivateServerTestData.Uid(354),
        PrivateServerTestData.Digest("lab-build"),
        "nll/private-server-application/test/v1",
        manifest,
        baseInstant,
        baseInstant.AddHours(1));

    Assert.Equal(0, first.IssuedAtUtc.Ticks % 10);
    Assert.Equal(TimeSpan.Zero, first.IssuedAtUtc.Offset);
    Assert.Equal(second.ContentSha256, first.ContentSha256);
  }

  [Fact]
  public void RestoredContextRequiresCompleteSelectedSeasonPin()
  {
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.Closed,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(370)));
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.Closed,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection")));
  }

  [Fact]
  public void RestoredActiveContextTimesMustBeInsideSessionLifetime()
  {
    var expiresAtUtc = PrivateServerTestData.Instant.AddHours(1);

    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.LocalConnected,
        connectedAtUtc: expiresAtUtc,
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(371),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection")));
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.LobbyReady,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        lobbyReadyAtUtc: expiresAtUtc,
        accountRevisionSetSha256: PrivateServerTestData.Digest("account-set"),
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(372),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection")));

    var atLowerBound = RestoreContext(
        ClientContextStage.LocalConnected,
        connectedAtUtc: PrivateServerTestData.Instant,
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(373),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection"));
    Assert.Equal(PrivateServerTestData.Instant, atLowerBound.ConnectedAtUtc);
  }

  [Fact]
  public void RestoredContextTimesMustFollowTransitionOrder()
  {
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.LobbyReady,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(2),
        lobbyReadyAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        accountRevisionSetSha256: PrivateServerTestData.Digest("account-set"),
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(374),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection")));
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.Closed,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        lobbyReadyAtUtc: PrivateServerTestData.Instant.AddMinutes(2),
        accountRevisionSetSha256: PrivateServerTestData.Digest("account-set"),
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(375),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection"),
        closedAtUtc: PrivateServerTestData.Instant.AddMinutes(1)));
  }

  [Fact]
  public void RestoredClosedContextRequiresAValidPredecessorShape()
  {
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.Closed,
        accountRevisionSetSha256: PrivateServerTestData.Digest("account-set"),
        closedAtUtc: PrivateServerTestData.Instant.AddMinutes(1)));
    AssertContextShapeInvalid(() => RestoreContext(
        ClientContextStage.Closed,
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(376),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection"),
        closedAtUtc: PrivateServerTestData.Instant.AddMinutes(1)));
  }

  [Fact]
  public void ClosedContextMayBeMaterializedAfterSessionExpiry()
  {
    var closedAtUtc = PrivateServerTestData.Instant.AddHours(2);
    var context = RestoreContext(
        ClientContextStage.Closed,
        connectedAtUtc: PrivateServerTestData.Instant.AddMinutes(1),
        lobbyReadyAtUtc: PrivateServerTestData.Instant.AddMinutes(2),
        accountRevisionSetSha256: PrivateServerTestData.Digest("account-set"),
        selectedSeasonRevisionUid: PrivateServerTestData.Uid(377),
        selectedSeasonContentSha256: PrivateServerTestData.Digest("selection"),
        closedAtUtc: closedAtUtc);

    Assert.Equal(ClientContextStage.Closed, context.Stage);
    Assert.Equal(closedAtUtc, context.ClosedAtUtc);
  }

  [Theory]
  [InlineData("nll/private-server-application/name/extra/v1")]
  [InlineData("nll/private-server-application/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/v1")]
  [InlineData("nll/private-server-application/name/vx")]
  public void ApplicationContractMatchesPersistenceGrammar(string invalidContract)
  {
    var policy = PrivateServerTestData.ConfiguredPolicy();
    var manifest = PrivateServerTestData.CapabilityManifest(policy);

    Assert.Throws<PrivateServerIntegrityException>(() => LocalClientContext.Open(
        PrivateServerTestData.Uid(400),
        PrivateServerTestData.Uid(401),
        PrivateServerTestData.Uid(402),
        PrivateServerTestData.Uid(403),
        PrivateServerTestData.Uid(404),
        PrivateServerTestData.Digest("lab-build"),
        invalidContract,
        manifest,
        PrivateServerTestData.Instant,
        PrivateServerTestData.Instant.AddMinutes(1)));
  }

  private static LocalClientContext RestoreContext(
      ClientContextStage stage,
      DateTimeOffset? connectedAtUtc = null,
      DateTimeOffset? lobbyReadyAtUtc = null,
      Sha256Digest? accountRevisionSetSha256 = null,
      EntityUid? selectedSeasonRevisionUid = null,
      Sha256Digest? selectedSeasonContentSha256 = null,
      DateTimeOffset? closedAtUtc = null)
  {
    var manifest = PrivateServerTestData.CapabilityManifest(
        PrivateServerTestData.ConfiguredPolicy());
    return LocalClientContext.Restore(
        PrivateServerTestData.Uid(380),
        PrivateServerTestData.Uid(381),
        2,
        PrivateServerTestData.Uid(382),
        PrivateServerTestData.Uid(383),
        PrivateServerTestData.Uid(384),
        PrivateServerTestData.Uid(385),
        PrivateServerTestData.Digest("lab-build"),
        "nll/private-server-application/test/v1",
        manifest.ManifestUid,
        manifest.ContentSha256,
        PrivateServerTestData.Instant,
        PrivateServerTestData.Instant.AddHours(1),
        stage,
        connectedAtUtc,
        lobbyReadyAtUtc,
        accountRevisionSetSha256,
        selectedSeasonRevisionUid,
        selectedSeasonContentSha256,
        closedAtUtc);
  }

  private static void AssertContextShapeInvalid(Action action) =>
      Assert.Equal(
          "private_server_client_context_shape_invalid",
          Assert.Throws<PrivateServerIntegrityException>(action).Code);
}
