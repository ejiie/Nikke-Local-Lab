using System.Reflection;
using System.Security.Cryptography;
using App = NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlClassicSoloRaidRuntimeStateTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private static readonly DateTimeOffset TestInstant =
      new(2026, 8, 20, 1, 0, 0, TimeSpan.Zero);

  [Fact]
  public async Task PublishedCatalogBindingWorksWithoutBootAndFailsClosedWhenAmbiguous()
  {
    var connectionString = ConnectionString();
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var firstCatalog = await PublishSixSeasonRaidCatalogAsync(
        dataSource,
        "classic-solo-raid-state-first-catalog");
    var accountUid = await CreateInitializedAccountUidAsync(dataSource);
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);

    var binding = await store.ResolveOperationalBindingAsync(
        accountUid,
        seasonNumber: 26,
        observedAtUtc: TestInstant);
    var expected = Assert.Single(
        firstCatalog.Members,
        static member => member.SeasonNumber == 26);
    Assert.Equal(expected.RaidSnapshotUid.Value, binding.RaidSnapshotUid);
    Assert.Equal(expected.ContentSha256.ToByteArray(), binding.RaidSnapshotSha256);

    await using (var check = await dataSource.OpenConnectionAsync())
    {
      Assert.Equal(
          0L,
          await ScalarAsync(
              check,
              "SELECT count(*) FROM lab_private_server.private_server_boot_revision;"));
      Assert.Equal(
          0L,
          await ScalarAsync(
              check,
              "SELECT count(*) FROM lab_private_server.raid_season_directory;"));
    }

    _ = await PublishSixSeasonRaidCatalogAsync(
        dataSource,
        "classic-solo-raid-state-second-catalog");
    var ambiguous = await Assert.ThrowsAsync<InvalidOperationException>(() =>
        store.ResolveOperationalBindingAsync(
            accountUid,
            seasonNumber: 26,
            observedAtUtc: TestInstant));
    Assert.Equal(
        "phase_d_raid_state_operational_binding_cardinality_invalid",
        ambiguous.Message);
  }

  [Fact]
  public async Task CurrentRaidDayBindingAndRuntimeStateRevisionsAreDurableAndIdempotent()
  {
    var connectionString = ConnectionString();
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    Assert.Equal(0, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    await PublishSixSeasonRaidCatalogAsync(dataSource);

    var accountUid = await CreateInitializedAccountUidAsync(dataSource);
    await using var runtime = await PostgreSqlPrivateServerRuntime.CreateAsync(
        connectionString,
        new ManualTimeProvider(TestInstant));
    var service = runtime.Service;
    var currentBoot = await service.GetBootAsync(new App.BootQuery(TestInstant));
    var currentSeason = currentBoot.Directory.Directory.RequireMember(26);

    var currentPolicy = await service.GetChallengeOperationalPolicyAsync(
        new App.ChallengePolicyStateQuery(TestInstant));
    var nextInstant = TestInstant.AddDays(1);
    var configured = PrivateServerDomain.ChallengeOperationalPolicy.CreateConfiguredV1(
        EntityUid.New(),
        "challenge-operational-policy/raid-state-integration/v1",
        dailyEntryLimit: 3,
        PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed,
        PrivateServerDomain.ActiveRunAtResetPolicy.PinOpeningRaidDay,
        PrivateServerDomain.DailyCounterScope.PerSeason,
        PrivateServerDomain.MockBattleCapability.Unsupported,
        PrivateServerDomain.LocalRankingCapability.LocalRecordsOnly);
    _ = await service.PublishChallengeOperationalPolicyAsync(
        new App.PublishChallengeOperationalPolicyCommand(
            EntityUid.New(),
            configured,
            TestInstant));
    _ = await service.ActivateChallengeOperationalPolicyAsync(
        new App.ActivateChallengeOperationalPolicyCommand(
            EntityUid.New(),
            configured.PolicyUid,
            configured.ContentSha256,
            PrivateServerDomain.AsiaSeoulRaidDay.GetKey(nextInstant),
            currentPolicy.Activation.Revision.RevisionUid,
            TestInstant));
    var futureBoot = await service.GetBootAsync(new App.BootQuery(nextInstant));
    Assert.NotEqual(currentBoot.Revision.RevisionUid, futureBoot.Revision.RevisionUid);

    var latestScheduled = await ReadLatestScheduledBootAsync(dataSource);
    Assert.Equal(futureBoot.Revision.RevisionUid.Value, latestScheduled.RevisionUid);
    Assert.True(
        latestScheduled.EffectiveRaidDay >
        PrivateServerDomain.AsiaSeoulRaidDay.GetKey(TestInstant).Date);

    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    var binding = await store.ResolveOperationalBindingAsync(
        accountUid,
        seasonNumber: 26,
        observedAtUtc: TestInstant);
    Assert.Equal(accountUid, binding.LocalAccountUid);
    Assert.Equal(26, binding.SeasonNumber);
    Assert.Equal(currentSeason.RaidSnapshotUid.Value, binding.RaidSnapshotUid);
    Assert.Equal(
        currentSeason.RaidSnapshotContentSha256.ToByteArray(),
        binding.RaidSnapshotSha256);

    _ = await PublishSixSeasonRaidCatalogAsync(
        dataSource,
        "classic-solo-raid-state-post-boot-second-catalog");
    var bindingWithAmbiguousCatalogs = await store.ResolveOperationalBindingAsync(
        accountUid,
        seasonNumber: 26,
        observedAtUtc: TestInstant);
    Assert.Equal(binding.RaidSnapshotUid, bindingWithAmbiguousCatalogs.RaidSnapshotUid);
    Assert.Equal(
        binding.RaidSnapshotSha256,
        bindingWithAmbiguousCatalogs.RaidSnapshotSha256);

    var key = new ClassicSoloRaidRuntimeStateKey(
        accountUid,
        26,
        binding.RaidSnapshotUid,
        binding.RaidSnapshotSha256,
        "nikke-2026.08.20",
        Hash("client-executable"));
    Assert.Null(await store.GetHeadAsync(key));

    var abandonedPartialCapture = Capture(
        key,
        Guid.NewGuid(),
        expectedHeadRevisionUid: null,
        payloadMarker: 0x10,
        stateMarker: "abandoned-partial",
        completedBestTotalDamage: 24_972_784_671,
        capturedAtUtc: TestInstant.AddMinutes(2),
        completedBestTeamCount: 1);
    var abandonedFailure = await Assert.ThrowsAsync<InvalidOperationException>(
        () => store.PersistAsync(abandonedPartialCapture));
    Assert.Equal("phase_d_raid_state_capture_invalid", abandonedFailure.Message);

    var firstCapture = Capture(
        key,
        Guid.NewGuid(),
        expectedHeadRevisionUid: null,
        payloadMarker: 0x11,
        stateMarker: "state-one",
        completedBestTotalDamage: 24_972_784_671,
        capturedAtUtc: TestInstant.AddMinutes(3));
    var first = await store.PersistAsync(firstCapture);
    Assert.Equal("state_advanced", first.ResultCode);
    Assert.True(first.StateAdvanced);
    Assert.False(first.Quarantined);
    Assert.False(first.ExactReplay);
    var firstRevisionUid = Assert.IsType<Guid>(first.HeadRevisionUid);

    var replay = await store.PersistAsync(firstCapture);
    Assert.Equal("state_advanced", replay.ResultCode);
    Assert.Equal(firstRevisionUid, replay.HeadRevisionUid);
    Assert.True(replay.StateAdvanced);
    Assert.False(replay.Quarantined);
    Assert.True(replay.ExactReplay);

    var unchangedCapture = Capture(
        key,
        Guid.NewGuid(),
        firstRevisionUid,
        payloadMarker: 0x11,
        stateMarker: "state-one",
        completedBestTotalDamage: 24_972_784_671,
        capturedAtUtc: TestInstant.AddMinutes(4));
    var unchanged = await store.PersistAsync(unchangedCapture);
    Assert.Equal("state_unchanged", unchanged.ResultCode);
    Assert.Equal(firstRevisionUid, unchanged.HeadRevisionUid);
    Assert.False(unchanged.StateAdvanced);
    Assert.False(unchanged.Quarantined);
    Assert.False(unchanged.ExactReplay);

    var secondCapture = Capture(
        key,
        Guid.NewGuid(),
        firstRevisionUid,
        payloadMarker: 0x22,
        stateMarker: "state-two",
        completedBestTotalDamage: 30_000_000_000,
        capturedAtUtc: TestInstant.AddMinutes(5));
    var second = await store.PersistAsync(secondCapture);
    Assert.Equal("state_advanced", second.ResultCode);
    Assert.True(second.StateAdvanced);
    var secondRevisionUid = Assert.IsType<Guid>(second.HeadRevisionUid);
    Assert.NotEqual(firstRevisionUid, secondRevisionUid);

    var revertedContentCapture = Capture(
        key,
        Guid.NewGuid(),
        secondRevisionUid,
        payloadMarker: 0x55,
        stateMarker: "state-one",
        completedBestTotalDamage: 30_000_000_000,
        capturedAtUtc: TestInstant.AddMinutes(6));
    var revertedContent = await store.PersistAsync(revertedContentCapture);
    Assert.Equal("state_advanced", revertedContent.ResultCode);
    Assert.True(revertedContent.StateAdvanced);
    var thirdRevisionUid = Assert.IsType<Guid>(revertedContent.HeadRevisionUid);
    Assert.NotEqual(firstRevisionUid, thirdRevisionUid);
    Assert.NotEqual(secondRevisionUid, thirdRevisionUid);

    var staleCapture = Capture(
        key,
        Guid.NewGuid(),
        firstRevisionUid,
        payloadMarker: 0x33,
        stateMarker: "state-three",
        completedBestTotalDamage: 31_000_000_000,
        capturedAtUtc: TestInstant.AddMinutes(7));
    var stale = await store.PersistAsync(staleCapture);
    Assert.Equal("stale_head_quarantined", stale.ResultCode);
    Assert.Equal(thirdRevisionUid, stale.HeadRevisionUid);
    Assert.False(stale.StateAdvanced);
    Assert.True(stale.Quarantined);
    Assert.False(stale.ExactReplay);

    var regressedCapture = Capture(
        key,
        Guid.NewGuid(),
        thirdRevisionUid,
        payloadMarker: 0x44,
        stateMarker: "state-regressed",
        completedBestTotalDamage: 29_000_000_000,
        capturedAtUtc: TestInstant.AddMinutes(8));
    var regressed = await store.PersistAsync(regressedCapture);
    Assert.Equal("completed_best_regression_quarantined", regressed.ResultCode);
    Assert.Equal(thirdRevisionUid, regressed.HeadRevisionUid);
    Assert.False(regressed.StateAdvanced);
    Assert.True(regressed.Quarantined);
    Assert.False(regressed.ExactReplay);

    var head = Assert.IsType<ClassicSoloRaidRuntimeStateHead>(await store.GetHeadAsync(key));
    Assert.Equal(thirdRevisionUid, head.RevisionUid);
    Assert.Equal(3, head.RevisionNumber);
    Assert.Equal(revertedContentCapture.StateContentSha256, head.StateContentSha256);
    Assert.Equal(30_000_000_000, head.CompletedBestTotalDamage);
    Assert.Equal(5, head.CompletedBestTeamCount);

    await using var check = await dataSource.OpenConnectionAsync();
    Assert.Equal(
        1L,
        await ScalarAsync(
            check,
            "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state;"));
    Assert.Equal(
        3L,
        await ScalarAsync(
            check,
            "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state_revision;"));
    Assert.Equal(
        6L,
        await ScalarAsync(
            check,
            "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state_operation;"));
  }

  [Fact]
  public async Task FailureAfterRevisionInsertRollsBackAllStateAndSameCaptureCanRetry()
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(ConnectionString());
    var key = await CreateFailureTestKeyAsync(dataSource);
    var capture = Capture(key, Guid.NewGuid(), null, 1, "rollback-state", 125, TestInstant);
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    // Test-only trigger: fail between revision insertion and transaction commit.
    await using (var install = dataSource.CreateCommand("""
        CREATE FUNCTION lab_private_server.synthetic_fail_head() RETURNS trigger
        LANGUAGE plpgsql AS $$ BEGIN
          RAISE EXCEPTION 'synthetic_head_failure' USING ERRCODE = 'P0001';
        END $$;
        CREATE TRIGGER synthetic_fail_head BEFORE UPDATE OF current_classic_solo_raid_runtime_state_revision_id
        ON lab_private_server.classic_solo_raid_runtime_state
        FOR EACH ROW EXECUTE FUNCTION lab_private_server.synthetic_fail_head();
        """))
      await install.ExecuteNonQueryAsync();
    try
    {
      var failure = await Assert.ThrowsAsync<PostgresException>(() => store.PersistAsync(capture));
      Assert.Equal("P0001", failure.SqlState);
      Assert.Equal("synthetic_head_failure", failure.MessageText);
      Assert.Null(await store.GetHeadAsync(key));
      await AssertStateCountsAsync(dataSource, 0, 0, 0);
    }
    finally
    {
      await using var remove = dataSource.CreateCommand("""
          DROP TRIGGER synthetic_fail_head ON lab_private_server.classic_solo_raid_runtime_state;
          DROP FUNCTION lab_private_server.synthetic_fail_head();
          """);
      await remove.ExecuteNonQueryAsync();
    }
    var retry = await store.PersistAsync(capture);
    Assert.True(retry.StateAdvanced);
    Assert.False(retry.ExactReplay);
    Assert.True((await store.PersistAsync(capture)).ExactReplay);
    await AssertStateCountsAsync(dataSource, 1, 1, 1);
  }

  [Fact]
  public async Task CommittedCaptureSurvivesLostReceiptAndNewConnectionPool()
  {
    var connectionString = ConnectionString();
    ClassicSoloRaidRuntimeStateCapture capture;
    await using (var first = PostgreSqlDataSourceFactory.Create(connectionString))
    {
      var key = await CreateFailureTestKeyAsync(first);
      capture = Capture(key, Guid.NewGuid(), null, 2, "lost-receipt-state", 150, TestInstant);
      // Deliberately discard the committed response (no completion receipt).
      _ = await new ClassicSoloRaidRuntimeStateStore(first).PersistAsync(capture);
    }
    await using var reopened = PostgreSqlDataSourceFactory.Create(connectionString);
    var store = new ClassicSoloRaidRuntimeStateStore(reopened);
    var replay = await store.PersistAsync(capture);
    Assert.True(replay.ExactReplay);
    Assert.False(replay.Quarantined);
    var head = Assert.IsType<ClassicSoloRaidRuntimeStateHead>(await store.GetHeadAsync(capture.Key));
    Assert.Equal(replay.HeadRevisionUid, head.RevisionUid);
    Assert.Equal(capture.ProtectedPayload, head.ProtectedPayload);
    Assert.Equal(150, head.CompletedBestTotalDamage);
    await AssertStateCountsAsync(reopened, 1, 1, 1);
  }

  [Fact]
  public async Task CompetingCapturesPreserveOneHeadAndQuarantineStaleRetry()
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(ConnectionString());
    var key = await CreateFailureTestKeyAsync(dataSource);
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    var initial = await store.PersistAsync(Capture(key, Guid.NewGuid(), null, 1, "initial", 125, TestInstant));
    var first = Capture(key, Guid.NewGuid(), initial.HeadRevisionUid, 2, "competitor-a", 125, TestInstant.AddSeconds(1));
    var second = Capture(key, Guid.NewGuid(), initial.HeadRevisionUid, 3, "competitor-b", 125, TestInstant.AddSeconds(2));
    async Task<ClassicSoloRaidRuntimeStatePersistResult> PersistWithSerializationRetry(ClassicSoloRaidRuntimeStateCapture value)
    {
      try { return await store.PersistAsync(value); }
      catch (PostgresException exception) when (exception.SqlState == PostgresErrorCodes.SerializationFailure)
      {
        // Re-use the exact request after PostgreSQL aborts a concurrent transaction.
        return await store.PersistAsync(value);
      }
    }
    var results = await Task.WhenAll(PersistWithSerializationRetry(first), PersistWithSerializationRetry(second));
    var winner = Assert.Single(results, result => result.StateAdvanced);
    var loser = Assert.Single(results, result => result.Quarantined);
    Assert.Equal("stale_head_quarantined", loser.ResultCode);
    Assert.Equal(winner.HeadRevisionUid, (await store.GetHeadAsync(key))!.RevisionUid);
    Assert.True((await store.PersistAsync(first)).ExactReplay);
    Assert.True((await store.PersistAsync(second)).ExactReplay);
    await AssertStateCountsAsync(dataSource, 1, 2, 3);
  }

  [Fact]
  public async Task SelectedWeaknessSeparatesScoresReplayAndLegacyWithoutRelabeling()
  {
    await using var dataSource = PostgreSqlDataSourceFactory.Create(ConnectionString());
    var legacy = await CreateFailureTestKeyAsync(dataSource);
    var store = new ClassicSoloRaidRuntimeStateStore(dataSource);
    var oldCapture = Capture(legacy, Guid.NewGuid(), null, 1, "legacy", 999, TestInstant);
    var old = await store.PersistAsync(oldCapture);
    var iron = legacy with { SelectedWeaknessCode = "iron" };
    var water = legacy with { SelectedWeaknessCode = "water" };
    Assert.Null(await store.GetHeadAsync(iron));
    Assert.Null(await store.GetHeadAsync(water));
    var ironCapture = Capture(iron, Guid.NewGuid(), null, 2, "iron", 150, TestInstant);
    var ironResult = await store.PersistAsync(ironCapture);
    Assert.Null(await store.GetHeadAsync(water));
    var waterCapture = Capture(water, Guid.NewGuid(), null, 3, "water", 100, TestInstant);
    var waterResult = await store.PersistAsync(waterCapture);
    Assert.False(waterResult.Quarantined);
    Assert.Equal(150, (await store.GetHeadAsync(iron))!.CompletedBestTotalDamage);
    Assert.Equal(100, (await store.GetHeadAsync(water))!.CompletedBestTotalDamage);
    Assert.Equal(old.HeadRevisionUid, (await store.GetHeadAsync(legacy))!.RevisionUid);
    Assert.True((await store.PersistAsync(oldCapture)).ExactReplay);
    Assert.True((await store.PersistAsync(waterCapture)).ExactReplay);
    var swapped = waterCapture with { Key = iron };
    swapped = swapped with { RequestSha256 = ClassicSoloRaidRuntimeStateStore.ComputeRequestSha256(swapped) };
    Assert.NotEqual(waterCapture.RequestSha256, swapped.RequestSha256);
    var reused = await Assert.ThrowsAsync<InvalidOperationException>(() => store.PersistAsync(swapped));
    Assert.Equal("phase_d_raid_state_operation_uid_reuse", reused.Message);
    var stale = Capture(water, Guid.NewGuid(), ironResult.HeadRevisionUid, 4, "wrong-head", 110, TestInstant);
    var crossScope = await Assert.ThrowsAsync<PostgresException>(() => store.PersistAsync(stale));
    Assert.Equal(PostgresErrorCodes.ForeignKeyViolation, crossScope.SqlState);
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var mutate = new NpgsqlCommand("""
        UPDATE lab_private_server.classic_solo_raid_runtime_state
           SET selected_weakness_code = 'fire' WHERE selected_weakness_code = 'iron';
        """, connection);
    await Assert.ThrowsAsync<PostgresException>(() => mutate.ExecuteNonQueryAsync());
    Assert.Equal(ironResult.HeadRevisionUid, (await store.GetHeadAsync(iron))!.RevisionUid);
    await AssertStateCountsAsync(dataSource, 3, 3, 3);
    // The old 1 MiB ceiling must not silently truncate a full battle history.
    var largePayload = Enumerable.Repeat((byte)7, 1048577).ToArray();
    var large = Capture(iron, Guid.NewGuid(), ironResult.HeadRevisionUid, 7, "large-history", 150, TestInstant)
        with
    { ProtectedPayload = largePayload, ProtectedPayloadSha256 = SHA256.HashData(largePayload) };
    large = large with { RequestSha256 = ClassicSoloRaidRuntimeStateStore.ComputeRequestSha256(large) };
    var largeResult = await store.PersistAsync(large);
    Assert.False(largeResult.Quarantined);
    Assert.Equal(largePayload, (await store.GetHeadAsync(iron))!.ProtectedPayload);
    Assert.True((await store.PersistAsync(large)).ExactReplay);
    await RuntimePersistenceAdapterProbe.RunIfRequestedAsync(legacy with { ClientBuildCode = "synthetic-roundtrip" });
  }

  private static async Task<ClassicSoloRaidRuntimeStateKey> CreateFailureTestKeyAsync(NpgsqlDataSource dataSource)
  {
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    await PublishSixSeasonRaidCatalogAsync(dataSource);
    var account = await CreateInitializedAccountUidAsync(dataSource);
    var binding = await new ClassicSoloRaidRuntimeStateStore(dataSource).ResolveOperationalBindingAsync(account, 26, TestInstant);
    return new ClassicSoloRaidRuntimeStateKey(account, 26, binding.RaidSnapshotUid,
        binding.RaidSnapshotSha256, "synthetic-lifecycle-client", Hash("synthetic-lifecycle-client"));
  }

  private static async Task AssertStateCountsAsync(NpgsqlDataSource dataSource, long states, long revisions, long operations)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    Assert.Equal(states, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state;"));
    Assert.Equal(revisions, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state_revision;"));
    Assert.Equal(operations, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state_operation;"));
  }

  private static ClassicSoloRaidRuntimeStateCapture Capture(
      ClassicSoloRaidRuntimeStateKey key,
      Guid launchContextUid,
      Guid? expectedHeadRevisionUid,
      byte payloadMarker,
      string stateMarker,
      long completedBestTotalDamage,
      DateTimeOffset capturedAtUtc,
      int completedBestTeamCount = 5)
  {
    var payload = Enumerable.Repeat(payloadMarker, 64).ToArray();
    var capture = new ClassicSoloRaidRuntimeStateCapture(
        key,
        launchContextUid,
        expectedHeadRevisionUid,
        new byte[32],
        Hash("profile-revision-set"),
        payload,
        SHA256.HashData(payload),
        Hash(stateMarker),
        StatePresent: true,
        HasOpenRun: false,
        CompletedBestTotalDamage: completedBestTotalDamage,
        CompletedBestTeamCount: completedBestTeamCount,
        OpenTeamCount: 0,
        RaidDateDay: 1,
        capturedAtUtc);
    return capture with
    {
      RequestSha256 = ClassicSoloRaidRuntimeStateStore.ComputeRequestSha256(capture)
    };
  }

  private static async Task<RaidCatalogImportReceipt> PublishSixSeasonRaidCatalogAsync(
      NpgsqlDataSource dataSource,
      string artifactMarker = "classic-solo-raid-state-static-data")
  {
    var testType = typeof(PostgreSqlRaidSnapshotTests);
    var artifact = (RaidEvidenceArtifactPublication)testType.GetMethod(
        "Artifact",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null, [artifactMarker])!;
    var publication = (RaidCatalogPublication)testType.GetMethod(
        "CreateStaticPublication",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [artifact, "phase2b_higher_tier_evidence_unresolved"])!;
    var attempt = (CompletedImportAttempt)testType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(
            null,
            [publication, new[] { artifact }, artifactMarker, null, null])!;
    var receipt = await new PostgreSqlRaidSnapshotImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            attempt,
            publication);
    Assert.Equal(6, receipt.Members.Count);
    return receipt;
  }

  [Fact]
  public async Task PreferencesAreAccountScopedImmutableReplayableAndQuarantineConcurrentCaptures()
  {
    await using var source = PostgreSqlDataSourceFactory.Create(ConnectionString());
    await ResetSchemasAsync(source);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(source));
    var account = await CreateInitializedAccountUidAsync(source);
    var key = new RuntimePreferencesKey(account, "synthetic", Hash("preferences-client"));
    var store = new RuntimePreferencesStore(source);
    Assert.Null(await store.GetHeadAsync(key));
    RuntimePreferencesCapture Capture(string value, Guid? previous = null)
    {
      var payload = System.Text.Encoding.UTF8.GetBytes(value.PadRight(60, '_'));
      return new RuntimePreferencesCapture(key, Guid.NewGuid(), previous, payload, SHA256.HashData(payload), Hash(value), TestInstant);
    }
    var firstCapture = Capture("first");
    var first = await store.PersistAsync(firstCapture);
    Assert.Equal("state_advanced", first.ResultCode);
    Assert.False(first.ExactReplay);
    var replay = await store.PersistAsync(firstCapture);
    Assert.Equal(first with { ExactReplay = true }, replay);
    var firstHead = await store.GetHeadAsync(key);
    Assert.Equal(1, firstHead!.RevisionNumber);
    Assert.Equal(firstCapture.ProtectedPayload, firstHead.ProtectedPayload);
    Assert.Null(await store.GetHeadAsync(key with { AccountUid = Guid.NewGuid() }));
    Assert.Null(await store.GetHeadAsync(key with { ClientBuildCode = "another" }));
    Assert.Null(await store.GetHeadAsync(key with { ClientExecutableSha256 = Hash("another") }));
    var unchanged = await store.PersistAsync(Capture("first", first.RevisionUid));
    Assert.Equal("state_unchanged", unchanged.ResultCode);
    Assert.Equal(first.RevisionUid, unchanged.RevisionUid);
    var a = Capture("changed-a", first.RevisionUid);
    var b = Capture("changed-b", first.RevisionUid);
    var outcomes = await Task.WhenAll(store.PersistAsync(a), store.PersistAsync(b));
    Assert.Single(outcomes, outcome => outcome.ResultCode == "state_advanced");
    Assert.Single(outcomes, outcome => outcome.Quarantined);
    var finalHead = await store.GetHeadAsync(key);
    Assert.Equal(2, finalHead!.RevisionNumber);
    Assert.Equal(outcomes.Single(outcome => !outcome.Quarantined).RevisionUid, finalHead.RevisionUid);
    var replayA = await store.PersistAsync(a);
    var replayB = await store.PersistAsync(b);
    Assert.Equal(outcomes[0] with { ExactReplay = true }, replayA);
    Assert.Equal(outcomes[1] with { ExactReplay = true }, replayB);
    var reuse = await Assert.ThrowsAsync<InvalidOperationException>(() => store.PersistAsync(
        Capture("wrong") with { LaunchContextUid = firstCapture.LaunchContextUid }));
    Assert.Equal("runtime_preferences_operation_reuse", reuse.Message);
    await using var connection = await source.OpenConnectionAsync();
    Assert.Equal(2, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.runtime_preferences_revision;"));
    Assert.Equal(4, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.runtime_preferences_operation;"));
    Assert.Equal(1, await ScalarAsync(connection, "SELECT count(*) FROM lab_private_server.runtime_preferences_operation WHERE quarantined_payload IS NOT NULL;"));
    foreach (var sql in new[]
    {
      "UPDATE lab_private_server.runtime_preferences SET client_build_code = 'rewrite';",
      "DELETE FROM lab_private_server.runtime_preferences;",
      "UPDATE lab_private_server.runtime_preferences_revision SET content_sha256 = decode(repeat('aa',32),'hex');",
      "DELETE FROM lab_private_server.runtime_preferences_operation;",
    })
    {
      await using var command = new NpgsqlCommand(sql, connection);
      await Assert.ThrowsAsync<PostgresException>(() => command.ExecuteNonQueryAsync());
    }
  }

  private static async Task<Guid> CreateInitializedAccountUidAsync(
      NpgsqlDataSource dataSource)
  {
    var method = typeof(PostgreSqlPrivateServerTests).GetMethod(
        "CreateInitializedAccountAsync",
        BindingFlags.NonPublic | BindingFlags.Static) ??
        throw new InvalidOperationException("Initialized account fixture method was not found.");
    var task = (Task)(method.Invoke(null, [dataSource]) ??
        throw new InvalidOperationException("Initialized account fixture task was not created."));
    await task.ConfigureAwait(false);
    var fixture = task.GetType().GetProperty("Result")?.GetValue(task) ??
        throw new InvalidOperationException("Initialized account fixture did not return a value.");
    var accountUid = (EntityUid)(fixture.GetType().GetProperty("AccountUid")?.GetValue(fixture) ??
        throw new InvalidOperationException("Initialized account UID was not found."));
    return accountUid.Value;
  }

  private static async Task<(Guid RevisionUid, DateOnly EffectiveRaidDay)>
      ReadLatestScheduledBootAsync(NpgsqlDataSource dataSource)
  {
    await using var command = dataSource.CreateCommand(
        """
        SELECT revision.private_server_boot_revision_uid,
               revision.effective_raid_day_key
          FROM lab_private_server.private_server_boot_state state
          JOIN lab_private_server.private_server_boot_revision revision
            ON revision.private_server_boot_revision_id =
               state.latest_scheduled_boot_revision_id
         WHERE state.singleton;
        """);
    await using var reader = await command.ExecuteReaderAsync();
    Assert.True(await reader.ReadAsync());
    var result = (reader.GetGuid(0), reader.GetFieldValue<DateOnly>(1));
    Assert.False(await reader.ReadAsync());
    return result;
  }

  private static byte[] Hash(string value) =>
      SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(value));

  private static string ConnectionString()
  {
    var source = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB") ??
        throw new InvalidOperationException(
            "NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(source);
    PostgreSqlTestDatabaseGuard.RequireDisposableDatabase(
        new NpgsqlConnectionStringBuilder(validated));
    return validated;
  }

  private static async Task ResetSchemasAsync(NpgsqlDataSource dataSource)
  {
    if (!string.Equals(
            Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN"),
            ResetToken,
            StringComparison.Ordinal))
    {
      throw new InvalidOperationException("The disposable PostgreSQL reset token is required.");
    }

    await using var command = dataSource.CreateCommand(
        """
        DROP SCHEMA IF EXISTS lab_private_server CASCADE;
        DROP SCHEMA IF EXISTS lab_local_game CASCADE;
        DROP SCHEMA IF EXISTS lab_profile CASCADE;
        DROP SCHEMA IF EXISTS lab_combat_support CASCADE;
        DROP SCHEMA IF EXISTS lab_raid CASCADE;
        DROP SCHEMA IF EXISTS lab_private CASCADE;
        DROP SCHEMA IF EXISTS lab_catalog CASCADE;
        DROP SCHEMA IF EXISTS lab_import CASCADE;
        DROP SCHEMA IF EXISTS lab_meta CASCADE;
        """);
    _ = await command.ExecuteNonQueryAsync();
  }

  private static async Task<long> ScalarAsync(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private sealed class ManualTimeProvider(DateTimeOffset value) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => value;
  }
}
