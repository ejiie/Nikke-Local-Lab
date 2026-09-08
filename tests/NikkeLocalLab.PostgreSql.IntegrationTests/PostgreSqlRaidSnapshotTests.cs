using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlRaidSnapshotTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private const string StaticDataArtifactKind = "staticdata_archive";
  private const string EvidenceObjectArtifactKind = "raid_evidence_object";
  private static readonly int[] SupportedSeasons = [7, 13, 26, 29, 34, 40];

  [Fact]
  public async Task StaticExactCatalogIsAtomicReusableImmutableAndTierGuarded()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    Assert.Equal(0, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var staticArtifact = Artifact("synthetic-static-data");
    var characterLaneReceipt = await new PostgreSqlImportLedger(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAsync(
            CreateLaneAttempt(staticArtifact, "staticdata_catalog", "character-lane"));
    Assert.Equal(ImportReceiptStatus.Succeeded, characterLaneReceipt.Status);

    var staticPublication = CreateStaticPublication(staticArtifact);
    var store = new PostgreSqlRaidSnapshotImportStore(
        dataSource,
        new RandomEntityUidGenerator());
    var concurrent = await Task.WhenAll(Enumerable.Range(0, 4).Select(index =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(staticPublication, [staticArtifact], $"static-{index}"),
            staticPublication)));

    Assert.Single(concurrent, static receipt => receipt.Import.Status == ImportReceiptStatus.Succeeded);
    Assert.Equal(3, concurrent.Count(static receipt => receipt.Import.Status == ImportReceiptStatus.Reused));
    Assert.All(concurrent, receipt => Assert.Equal(SupportedSeasons, receipt.Members.Select(static member => member.SeasonNumber)));
    Assert.All(concurrent.Skip(1), receipt =>
    {
      Assert.Equal(concurrent[0].RaidCatalogSnapshotUid, receipt.RaidCatalogSnapshotUid);
      Assert.Equal(concurrent[0].CatalogManifestSha256, receipt.CatalogManifestSha256);
      Assert.Equal(concurrent[0].Members, receipt.Members);
      Assert.Equal(concurrent[0].Import.DatasetSnapshotUid, receipt.Import.DatasetSnapshotUid);
    });

    await using var connection = await dataSource.OpenConnectionAsync();
    Assert.Equal(1L, await ScalarAsync(
        connection,
        $"SELECT count(*) FROM lab_import.source_artifact WHERE content_sha256 = decode('{staticArtifact.Sha256.Hex}', 'hex');"));
    Assert.Equal(6L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.challenge_encounter_entity;"));
    Assert.Equal(6L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.boss_variant_entity;"));
    Assert.Equal(1L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.compatibility_map;"));
    Assert.Equal(1L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_catalog_snapshot;"));
    Assert.Equal(6L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot;"));
    Assert.Equal(12L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_part;"));
    Assert.Equal(6L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_skill;"));
    Assert.Equal(24L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_timing_clock;"));
    Assert.Equal(6L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_scheduler;"));
    Assert.Equal(8L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_catalog_import_diagnostic;"));
    Assert.Equal(4L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_raid.raid_catalog_import_projection;"));
    Assert.Equal(0L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_raid.raid_snapshot WHERE season_number IN (14, 39);"));
    Assert.Equal(6L, await ScalarAsync(
        connection,
        """
        SELECT count(*) FROM lab_raid.raid_snapshot
        WHERE compatibility_tier = 'static_exact'
          AND behavior_source_artifact_id IS NULL
          AND asset_bundle_set_sha256 IS NULL
          AND client_runtime_build_id IS NULL;
        """));

    var runCount = await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;");
    var changedPublication = CreateStaticPublication(
        staticArtifact,
        evidenceWarning: "different_safe_warning");
    var mismatch = await Assert.ThrowsAsync<RaidSnapshotIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(staticPublication, [staticArtifact], "mismatch"),
            changedPublication));
    Assert.Equal("raid_publication_hash_mismatch", mismatch.Code);
    Assert.Equal(runCount, await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var wrongRoleAttempt = CreateAttempt(
        staticPublication,
        [staticArtifact],
        "wrong-static-role",
        provenanceOverrides: new Dictionary<Sha256Digest, ArtifactProvenance>
        {
          [staticArtifact.Sha256] = new("raid_evidence_behavior", StaticDataArtifactKind)
        });
    var wrongRole = await Assert.ThrowsAsync<RaidSnapshotIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(wrongRoleAttempt, staticPublication));
    Assert.Equal("raid_artifact_provenance_mismatch", wrongRole.Code);

    var wrongKindAttempt = CreateAttempt(
        staticPublication,
        [staticArtifact],
        "wrong-static-kind",
        provenanceOverrides: new Dictionary<Sha256Digest, ArtifactProvenance>
        {
          [staticArtifact.Sha256] = new("raid_staticdata", EvidenceObjectArtifactKind)
        });
    var wrongKind = await Assert.ThrowsAsync<RaidSnapshotIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(wrongKindAttempt, staticPublication));
    Assert.Equal("raid_artifact_provenance_mismatch", wrongKind.Code);

    var crossRoleArtifact = Artifact("cross-role-evidence");
    var crossRolePublication = CreateCrossRolePublication(staticArtifact, crossRoleArtifact);
    var crossRole = await Assert.ThrowsAsync<RaidSnapshotIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(
                crossRolePublication,
                [staticArtifact, crossRoleArtifact],
                "cross-role"),
            crossRolePublication));
    Assert.Equal("raid_artifact_role_conflict", crossRole.Code);
    Assert.Equal(runCount, await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var runtimeArtifacts = CreateRuntimeArtifacts();
    var runtimePublication = CreateRuntimeExactPublication(staticArtifact, runtimeArtifacts);
    var runtimeReceipt = await store.RecordCompletedAndPublishAsync(
        CreateAttempt(
            runtimePublication,
            [staticArtifact, .. runtimeArtifacts],
            "runtime-exact"),
        runtimePublication);
    Assert.Equal(ImportReceiptStatus.Succeeded, runtimeReceipt.Import.Status);
    Assert.Single(runtimeReceipt.Members);
    Assert.Equal(40, runtimeReceipt.Members[0].SeasonNumber);
    Assert.Equal(1L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.client_runtime_build;"));
    Assert.Equal(
        "synthetic-runtime-1",
        await StringScalarAsync(
            connection,
            $"""
            SELECT runtime.local_build_label
            FROM lab_raid.client_runtime_build AS runtime
            JOIN lab_import.source_artifact AS artifact
              ON artifact.source_artifact_id = runtime.source_artifact_id
            WHERE artifact.content_sha256 = decode('{runtimeArtifacts[3].Sha256.Hex}', 'hex');
            """));
    Assert.Equal(1L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_selected_bundle;"));
    Assert.Equal(1L, await ScalarAsync(connection, "SELECT count(*) FROM lab_raid.raid_snapshot_timeline;"));
    Assert.Equal(4L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_raid.raid_snapshot_timing_clock_evidence;"));
    Assert.Equal(1L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_raid.raid_snapshot_scheduler_evidence;"));

    var reverseArtifacts = CreateRuntimeArtifacts("reverse", timingArtifactCount: 2);
    var reversePublication = CreateRuntimeExactPublication(
        staticArtifact,
        reverseArtifacts,
        "synthetic-runtime-reverse");
    var timingBySha = reverseArtifacts.Skip(4)
        .OrderBy(static artifact => artifact.Sha256.Hex, StringComparer.Ordinal)
        .ToArray();
    var sourceUids = new Dictionary<Sha256Digest, EntityUid>
    {
      [timingBySha[0].Sha256] = new(Guid.Parse("f0000000-0000-4000-8000-000000000001")),
      [timingBySha[1].Sha256] = new(Guid.Parse("10000000-0000-4000-8000-000000000001"))
    };
    var reverseReceipt = await store.RecordCompletedAndPublishAsync(
        CreateAttempt(
            reversePublication,
            [staticArtifact, .. reverseArtifacts],
            "reverse-timing-order",
            artifactUids: sourceUids),
        reversePublication);
    Assert.Equal(ImportReceiptStatus.Succeeded, reverseReceipt.Import.Status);
    var expectedTimingUids = sourceUids.Values
        .OrderBy(static uid => uid.ToString(), StringComparer.Ordinal)
        .Select(static uid => uid.Value)
        .ToArray();
    Assert.Equal(
        expectedTimingUids,
        await UuidListAsync(
            connection,
            """
            SELECT artifact.source_artifact_uid
            FROM lab_raid.raid_snapshot_timing_clock_evidence AS evidence
            JOIN lab_raid.raid_snapshot AS snapshot
              ON snapshot.raid_snapshot_id = evidence.raid_snapshot_id
            JOIN lab_raid.client_runtime_build AS runtime
              ON runtime.client_runtime_build_id = snapshot.client_runtime_build_id
            JOIN lab_import.source_artifact AS artifact
              ON artifact.source_artifact_id = evidence.source_artifact_id
            WHERE runtime.local_build_label = 'synthetic-runtime-reverse'
              AND evidence.clock_basis = 'behavior_tick'
            ORDER BY evidence.ordinal;
            """));
    Assert.Equal(
        expectedTimingUids,
        await UuidListAsync(
            connection,
            """
            SELECT artifact.source_artifact_uid
            FROM lab_raid.raid_snapshot_scheduler_evidence AS evidence
            JOIN lab_raid.raid_snapshot AS snapshot
              ON snapshot.raid_snapshot_id = evidence.raid_snapshot_id
            JOIN lab_raid.client_runtime_build AS runtime
              ON runtime.client_runtime_build_id = snapshot.client_runtime_build_id
            JOIN lab_import.source_artifact AS artifact
              ON artifact.source_artifact_id = evidence.source_artifact_id
            WHERE runtime.local_build_label = 'synthetic-runtime-reverse'
            ORDER BY evidence.ordinal;
            """));

    var relabeledRuntimePublication = CreateRuntimeExactPublication(
        staticArtifact,
        runtimeArtifacts,
        "synthetic-runtime-2");
    var discriminator = Artifact("runtime-label-mismatch-dataset");
    var runtimeBindingMismatch = await Assert.ThrowsAsync<RaidSnapshotIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(
                relabeledRuntimePublication,
                [staticArtifact, .. runtimeArtifacts, discriminator],
                "runtime-label-mismatch"),
            relabeledRuntimePublication));
    Assert.Equal("raid_runtime_binding_mismatch", runtimeBindingMismatch.Code);
    Assert.Equal(
        "synthetic-runtime-1",
        await StringScalarAsync(
            connection,
            $"""
            SELECT runtime.local_build_label
            FROM lab_raid.client_runtime_build AS runtime
            JOIN lab_import.source_artifact AS artifact
              ON artifact.source_artifact_id = runtime.source_artifact_id
            WHERE artifact.content_sha256 = decode('{runtimeArtifacts[3].Sha256.Hex}', 'hex');
            """));

    await AssertSqlTierConstraintAsync(connection);
    await AssertPublishedAppendRejectedAsync(connection);
    await AssertImmutableTablesAsync(connection);
    await AssertLeakSafeSchemaAsync(connection);
  }

  [Fact]
  public void StaticAndHigherTierPublicationContractsAreGuarded()
  {
    var staticArtifact = Artifact("contract-static-data");
    var staticSnapshot = new RaidSnapshotPublication(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        staticArtifact,
        Parts(),
        Skills(),
        RaidCompatibilityTier.StaticExact,
        RuntimeRelation.NotEvaluated,
        evidenceWarningCodes: ["higher_tier_evidence_not_current_authoritative"]);

    Assert.Null(staticSnapshot.Behavior);
    Assert.Empty(staticSnapshot.SelectedAssetBundles);
    Assert.Empty(staticSnapshot.Timelines);
    Assert.Null(staticSnapshot.ClientRuntime);
    Assert.Equal(
        Enum.GetValues<ClockBasis>().Order(),
        staticSnapshot.ClockEvidence.Select(static item => item.ClockBasis).Order());
    Assert.All(staticSnapshot.ClockEvidence, static item =>
        Assert.Equal(TimingEvidenceResolution.Unresolved, item.Resolution));
    Assert.Equal(TimingEvidenceResolution.Unresolved, staticSnapshot.SchedulerEvidence.Resolution);

    Assert.Throws<RaidSnapshotIntegrityException>(() => new RaidSnapshotPublication(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        staticArtifact,
        Parts(),
        Skills(),
        RaidCompatibilityTier.StaticExact,
        RuntimeRelation.NotEvaluated));
    Assert.Throws<RaidSnapshotIntegrityException>(() => new RaidSnapshotPublication(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        staticArtifact,
        Parts(),
        Skills(),
        RaidCompatibilityTier.BehaviorExact,
        RuntimeRelation.NotEvaluated));
    Assert.Throws<RaidSnapshotIntegrityException>(() => new RaidSnapshotPublication(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        staticArtifact,
        Parts(),
        Skills(),
        RaidCompatibilityTier.AssetExactRuntimeCurrent,
        RuntimeRelation.CurrentRuntimeMatch,
        behavior: Artifact("incomplete-behavior"),
        selectedAssetBundles:
        [
          new RaidAssetBundlePublication(
              Artifact("incomplete-bundle"),
              [AssetBundleRole.Behavior])
        ],
        clientRuntime: new RaidClientRuntimePublication(
            Artifact("incomplete-runtime"),
            "synthetic-runtime-incomplete")));
    var missingPartLink = Assert.Throws<RaidSnapshotIntegrityException>(() =>
        new RaidSnapshotPublication(
            40,
            RaidElement.Wind,
            RaidElement.Fire,
            staticArtifact,
            [
              new RaidStaticPartPublication(
                  0, "body", 10000, 10000, 10000, 10000, 10000, 10000, 10000,
                  true, true, true, linkedPartOrdinal: 1)
            ],
            Skills(),
            RaidCompatibilityTier.StaticExact,
            RuntimeRelation.NotEvaluated,
            evidenceWarningCodes: ["behavior_unresolved"]));
    Assert.Equal("raid_part_link_invalid", missingPartLink.Code);

    var runtimeArtifacts = CreateRuntimeArtifacts();
    var first = CreateRuntimeExactPublication(
        staticArtifact,
        runtimeArtifacts,
        "synthetic-runtime-1");
    var second = CreateRuntimeExactPublication(
        staticArtifact,
        runtimeArtifacts,
        "synthetic-runtime-2");
    Assert.NotEqual(first.CanonicalSha256, second.CanonicalSha256);
    Assert.Throws<ArgumentException>(() => new RaidClientRuntimePublication(
        runtimeArtifacts[3],
        "C:/private/runtime"));
  }

  private static RaidCatalogPublication CreateStaticPublication(
      RaidEvidenceArtifactPublication staticArtifact,
      string evidenceWarning = "higher_tier_evidence_not_current_authoritative") =>
      new(
          SupportedSeasons.Select(season => new RaidSnapshotPublication(
              season,
              season == 40 ? RaidElement.Wind : RaidElement.Electric,
              season == 40 ? RaidElement.Fire : RaidElement.Iron,
              staticArtifact,
              Parts(),
              Skills(),
              RaidCompatibilityTier.StaticExact,
              RuntimeRelation.NotEvaluated,
              evidenceWarningCodes: [evidenceWarning],
              readinessWarningCodes: ["synthetic_fixture_only"])),
          [
            new RaidCatalogImportDiagnosticPublication("excluded_by_policy", 14),
            new RaidCatalogImportDiagnosticPublication("excluded_by_policy", 39)
          ]);

  private static RaidCatalogPublication CreateRuntimeExactPublication(
      RaidEvidenceArtifactPublication staticArtifact,
      IReadOnlyList<RaidEvidenceArtifactPublication> runtimeArtifacts,
      string localBuildLabel = "synthetic-runtime-1")
  {
    var behavior = runtimeArtifacts[0];
    var bundle = runtimeArtifacts[1];
    var timeline = runtimeArtifacts[2];
    var runtime = runtimeArtifacts[3];
    var timing = runtimeArtifacts.Skip(4).ToArray();
    if (timing.Length == 0)
    {
      throw new ArgumentException("At least one timing artifact is required.", nameof(runtimeArtifacts));
    }

    var clocks = Enum.GetValues<ClockBasis>().Select(basis =>
        new RaidClockEvidencePublication(
            basis,
            TimingEvidenceResolution.RuntimeTrace,
            timing));
    var scheduler = new RaidSchedulerEvidencePublication(
        TimingEvidenceResolution.RuntimeTrace,
        Enum.GetValues<ClockBasis>(),
        timing);
    return new RaidCatalogPublication(
    [
      new RaidSnapshotPublication(
          40,
          RaidElement.Wind,
          RaidElement.Fire,
          staticArtifact,
          Parts(),
          Skills(),
          RaidCompatibilityTier.AssetExactRuntimeCurrent,
          RuntimeRelation.CurrentRuntimeMatch,
          behavior,
          [new RaidAssetBundlePublication(bundle, [AssetBundleRole.Behavior, AssetBundleRole.Model])],
          [new RaidTimelinePublication(timeline, [ClockBasis.BehaviorTick, ClockBasis.RenderFrame])],
          new RaidClientRuntimePublication(runtime, localBuildLabel),
          clocks,
          scheduler,
          readinessWarningCodes: ["synthetic_fixture_only"])
    ]);
  }

  private static RaidCatalogPublication CreateCrossRolePublication(
      RaidEvidenceArtifactPublication staticArtifact,
      RaidEvidenceArtifactPublication crossRoleArtifact) =>
      new(
      [
        new RaidSnapshotPublication(
            40,
            RaidElement.Wind,
            RaidElement.Fire,
            staticArtifact,
            Parts(),
            Skills(),
            RaidCompatibilityTier.BehaviorExact,
            RuntimeRelation.NotEvaluated,
            behavior: crossRoleArtifact,
            selectedAssetBundles:
            [
              new RaidAssetBundlePublication(crossRoleArtifact, [AssetBundleRole.Behavior])
            ])
      ]);

  private static IReadOnlyList<RaidEvidenceArtifactPublication> CreateRuntimeArtifacts(
      string suffix = "",
      int timingArtifactCount = 1)
  {
    var discriminator = string.IsNullOrEmpty(suffix) ? string.Empty : $"-{suffix}";
    return
    [
      Artifact($"synthetic-behavior{discriminator}"),
      Artifact($"synthetic-bundle{discriminator}"),
      Artifact($"synthetic-timeline{discriminator}"),
      Artifact($"synthetic-runtime{discriminator}"),
      .. Enumerable.Range(0, timingArtifactCount)
          .Select(index => Artifact($"synthetic-timing-trace{discriminator}-{index}"))
    ];
  }

  private static IReadOnlyList<RaidStaticPartPublication> Parts() =>
  [
      new RaidStaticPartPublication(
          0, "body", 10000, 10000, 10000, 10000, 10000, 10000, 10000,
          true, true, true),
    new RaidStaticPartPublication(
        1, "breakable-part", 12000, 2500, 9000, 10000, 10000, 10000, 10000,
        false, true, true, linkedPartOrdinal: 0)
  ];

  private static IReadOnlyList<RaidStaticSkillPublication> Skills() =>
  [
      new RaidStaticSkillPublication(0, "primary_pattern")
  ];

  private static RaidEvidenceArtifactPublication Artifact(string content) =>
      new(Sha256Digest.ComputeUtf8(content), System.Text.Encoding.UTF8.GetByteCount(content));

  private static CompletedImportAttempt CreateAttempt(
      RaidCatalogPublication publication,
      IEnumerable<RaidEvidenceArtifactPublication> sourceArtifacts,
      string runLabel,
      IReadOnlyDictionary<Sha256Digest, EntityUid>? artifactUids = null,
      IReadOnlyDictionary<Sha256Digest, ArtifactProvenance>? provenanceOverrides = null)
  {
    var inputs = new Dictionary<Sha256Digest, DatasetArtifactInput>();
    foreach (var snapshot in publication.Snapshots)
    {
      Add(snapshot.StaticData, "raid_staticdata", StaticDataArtifactKind);
      Add(snapshot.Behavior, "raid_evidence_behavior", EvidenceObjectArtifactKind);
      foreach (var bundle in snapshot.SelectedAssetBundles)
      {
        Add(bundle.Artifact, "raid_evidence_bundle", EvidenceObjectArtifactKind);
      }

      foreach (var timeline in snapshot.Timelines)
      {
        Add(timeline.Artifact, "raid_evidence_timeline", EvidenceObjectArtifactKind);
      }

      Add(snapshot.ClientRuntime?.Artifact, "raid_evidence_runtime", EvidenceObjectArtifactKind);
    }

    foreach (var snapshot in publication.Snapshots)
    {
      foreach (var artifact in snapshot.ClockEvidence.SelectMany(static clock => clock.EvidenceArtifacts)
                   .Concat(snapshot.SchedulerEvidence.EvidenceArtifacts))
      {
        Add(artifact, "raid_evidence_timing", EvidenceObjectArtifactKind);
      }
    }

    foreach (var artifact in sourceArtifacts)
    {
      Add(artifact, "raid_auxiliary", EvidenceObjectArtifactKind);
    }

    if (provenanceOverrides is not null)
    {
      foreach (var (digest, provenance) in provenanceOverrides)
      {
        var existing = inputs[digest];
        inputs[digest] = new DatasetArtifactInput(
            provenance.RoleCode,
            new SourceArtifactObservation(
                provenance.ArtifactKind,
                existing.Artifact.ContentSha256,
                existing.Artifact.ByteLength));
      }
    }

    var manifest = CanonicalDatasetManifest.Create(inputs.Values);
    var extractor = new ExtractorDescriptor(
        "synthetic_raid_catalog",
        "v1",
        Sha256Digest.ComputeUtf8("nll/synthetic-raid-catalog-contract/v1"));
    var request = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var now = DateTimeOffset.UtcNow;
    _ = runLabel;
    return new CompletedImportAttempt(
        EntityUid.New(),
        EntityUid.New(),
        manifest.Artifacts.Select(artifact => new ArtifactRegistration(
            artifactUids is not null && artifactUids.TryGetValue(
                artifact.Artifact.ContentSha256,
                out var artifactUid)
                ? artifactUid
                : EntityUid.New(),
            artifact)).ToArray(),
        manifest,
        extractor,
        SemanticOptionsFingerprint.Empty,
        request,
        publication.CanonicalSha256,
        [],
        now,
        now.AddMilliseconds(1));

    void Add(RaidEvidenceArtifactPublication? artifact, string roleCode, string artifactKind)
    {
      if (artifact is null || inputs.ContainsKey(artifact.Sha256))
      {
        return;
      }

      inputs.Add(
          artifact.Sha256,
          new DatasetArtifactInput(
              roleCode,
              new SourceArtifactObservation(artifactKind, artifact.Sha256, artifact.ByteLength)));
    }
  }

  private static CompletedImportAttempt CreateLaneAttempt(
      RaidEvidenceArtifactPublication artifact,
      string roleCode,
      string runLabel)
  {
    var manifest = CanonicalDatasetManifest.Create(
    [
      new DatasetArtifactInput(
          roleCode,
          new SourceArtifactObservation(
              StaticDataArtifactKind,
              artifact.Sha256,
              artifact.ByteLength))
    ]);
    var extractor = new ExtractorDescriptor(
        "synthetic_character_catalog",
        "v1",
        Sha256Digest.ComputeUtf8("nll/synthetic-character-catalog-contract/v1"));
    var request = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var now = DateTimeOffset.UtcNow;
    return new CompletedImportAttempt(
        EntityUid.New(),
        EntityUid.New(),
        [new ArtifactRegistration(EntityUid.New(), manifest.Artifacts[0])],
        manifest,
        extractor,
        SemanticOptionsFingerprint.Empty,
        request,
        Sha256Digest.ComputeUtf8($"nll/synthetic-lane-output/{runLabel}"),
        [],
        now,
        now.AddMilliseconds(1));
  }

  private static async Task AssertSqlTierConstraintAsync(NpgsqlConnection connection)
  {
    var exception = await Assert.ThrowsAsync<PostgresException>(async () =>
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_snapshot
              (raid_snapshot_uid, dataset_snapshot_id,
               challenge_encounter_id, boss_variant_id, compatibility_map_id,
               season_number, schema_version, mode, difficulty_type, wave_order,
               admission_policy_id, admission_rule, boss_element, weakness_code,
               admission_status, static_data_source_artifact_id,
               behavior_source_artifact_id, asset_bundle_set_sha256,
               client_runtime_build_id, compatibility_tier, runtime_relation,
               readiness_status, content_sha256, created_at_utc)
          SELECT '20000000-0000-4000-8000-000000000001'::uuid,
                 dataset_snapshot_id, challenge_encounter_id, boss_variant_id,
                 compatibility_map_id, season_number, schema_version, mode,
                 difficulty_type, wave_order, admission_policy_id, admission_rule,
                 boss_element, weakness_code, admission_status,
                 static_data_source_artifact_id, NULL, NULL, NULL,
                 'asset_exact_runtime_current', 'current_runtime_match',
                 readiness_status, decode(repeat('ff', 32), 'hex'), created_at_utc
          FROM lab_raid.raid_snapshot
          WHERE compatibility_tier = 'static_exact'
          ORDER BY raid_snapshot_id
          LIMIT 1;
          """,
          connection);
      await command.ExecuteNonQueryAsync();
    });
    Assert.Equal(PostgresErrorCodes.CheckViolation, exception.SqlState);
  }

  private static async Task AssertPublishedAppendRejectedAsync(NpgsqlConnection connection)
  {
    await AssertImmutableInsertAsync(
        connection,
        """
        INSERT INTO lab_raid.raid_snapshot_skill
            (raid_snapshot_id, ordinal, skill_uid, role_code)
        SELECT snapshot.raid_snapshot_id, 999,
               '30000000-0000-4000-8000-000000000001'::uuid,
               'late_skill'
        FROM lab_raid.raid_snapshot AS snapshot
        JOIN lab_raid.raid_catalog_snapshot_member AS member
          ON member.raid_snapshot_id = snapshot.raid_snapshot_id
        ORDER BY snapshot.raid_snapshot_id
        LIMIT 1;
        """);
    await AssertImmutableInsertAsync(
        connection,
        """
        INSERT INTO lab_raid.raid_catalog_snapshot_member
            (raid_catalog_snapshot_id, raid_snapshot_id, ordinal)
        SELECT catalog.raid_catalog_snapshot_id, member.raid_snapshot_id,
               catalog.member_count
        FROM lab_raid.raid_catalog_snapshot AS catalog
        JOIN lab_raid.raid_catalog_snapshot_member AS member
          ON member.raid_catalog_snapshot_id = catalog.raid_catalog_snapshot_id
        ORDER BY catalog.raid_catalog_snapshot_id, member.ordinal
        LIMIT 1;
        """);
    await AssertImmutableInsertAsync(
        connection,
        """
        INSERT INTO lab_raid.raid_catalog_import_diagnostic
            (raid_catalog_import_diagnostic_uid, import_run_id, sequence_number,
             season_number, diagnostic_code, occurrence_count, created_at_utc)
        SELECT '30000000-0000-4000-8000-000000000002'::uuid,
               projection.import_run_id, projection.diagnostic_count,
               40, 'late_diagnostic', 1, now()
        FROM lab_raid.raid_catalog_import_projection AS projection
        ORDER BY projection.import_run_id
        LIMIT 1;
        """);
  }

  private static async Task AssertImmutableInsertAsync(NpgsqlConnection connection, string sql)
  {
    var exception = await Assert.ThrowsAsync<PostgresException>(async () =>
    {
      await using var command = new NpgsqlCommand(sql, connection);
      await command.ExecuteNonQueryAsync();
    });
    Assert.Equal("P0001", exception.SqlState);
    Assert.Contains("immutable_raid_row", exception.MessageText, StringComparison.Ordinal);
  }

  private static async Task AssertImmutableTablesAsync(NpgsqlConnection connection)
  {
    var tables = new[]
    {
      "challenge_encounter_entity",
      "boss_variant_entity",
      "compatibility_map",
      "client_runtime_build",
      "raid_catalog_snapshot",
      "raid_catalog_import_projection",
      "raid_snapshot",
      "raid_catalog_snapshot_member",
      "raid_snapshot_part",
      "raid_snapshot_skill",
      "raid_snapshot_selected_bundle",
      "raid_snapshot_selected_bundle_role",
      "raid_snapshot_timeline",
      "raid_snapshot_timeline_clock_basis",
      "raid_snapshot_timing_clock",
      "raid_snapshot_timing_clock_evidence",
      "raid_snapshot_scheduler",
      "raid_snapshot_scheduler_clock_basis",
      "raid_snapshot_scheduler_evidence",
      "raid_snapshot_compatibility_warning",
      "raid_snapshot_readiness_warning",
      "raid_catalog_import_diagnostic"
    };
    foreach (var table in tables)
    {
      var exception = await Assert.ThrowsAsync<PostgresException>(async () =>
      {
        await using var command = new NpgsqlCommand(
            $"UPDATE lab_raid.{table} SET " + FirstColumn(table) + " = " + FirstColumn(table) + ";",
            connection);
        await command.ExecuteNonQueryAsync();
      });
      Assert.Equal("P0001", exception.SqlState);
      Assert.Contains("immutable_raid_row", exception.MessageText, StringComparison.Ordinal);
    }

    static string FirstColumn(string table) => table switch
    {
      "challenge_encounter_entity" => "season_number",
      "boss_variant_entity" => "challenge_encounter_id",
      "compatibility_map" => "dataset_snapshot_id",
      "client_runtime_build" => "local_build_label",
      "raid_catalog_snapshot" => "request_sha256",
      "raid_catalog_import_projection" => "diagnostic_count",
      "raid_snapshot" => "readiness_status",
      "raid_catalog_snapshot_member" => "ordinal",
      "raid_snapshot_part" => "ordinal",
      "raid_snapshot_skill" => "ordinal",
      "raid_snapshot_selected_bundle" => "ordinal",
      "raid_snapshot_selected_bundle_role" => "role_code",
      "raid_snapshot_timeline" => "ordinal",
      "raid_snapshot_timeline_clock_basis" => "clock_basis",
      "raid_snapshot_timing_clock" => "resolution",
      "raid_snapshot_timing_clock_evidence" => "ordinal",
      "raid_snapshot_scheduler" => "resolution",
      "raid_snapshot_scheduler_clock_basis" => "clock_basis",
      "raid_snapshot_scheduler_evidence" => "ordinal",
      "raid_snapshot_compatibility_warning" => "warning_code",
      "raid_snapshot_readiness_warning" => "warning_code",
      "raid_catalog_import_diagnostic" => "diagnostic_code",
      _ => throw new InvalidOperationException()
    };
  }

  private static async Task AssertLeakSafeSchemaAsync(NpgsqlConnection connection)
  {
    var forbidden = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
      "source_path",
      "file_name",
      "raw_id",
      "source_identifier",
      "payload",
      "json",
      "message",
      "details"
    };
    await using var command = new NpgsqlCommand(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'lab_raid';
        """,
        connection);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      Assert.DoesNotContain(reader.GetString(0), forbidden);
      Assert.DoesNotContain(reader.GetString(1), new[] { "json", "jsonb" });
    }
  }

  private static NpgsqlDataSource CreateDataSource()
  {
    var connectionString = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB")
        ?? throw new InvalidOperationException(
            "NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(connectionString);
    var builder = new NpgsqlConnectionStringBuilder(validated);
    PostgreSqlTestDatabaseGuard.RequireDisposableDatabase(builder);
    return PostgreSqlDataSourceFactory.Create(validated);
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
    await command.ExecuteNonQueryAsync();
  }

  private static async Task<long> ScalarAsync(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task<string> StringScalarAsync(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToString(
        await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture)!;
  }

  private static async Task<IReadOnlyList<Guid>> UuidListAsync(
      NpgsqlConnection connection,
      string sql)
  {
    var result = new List<Guid>();
    await using var command = new NpgsqlCommand(sql, connection);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      result.Add(reader.GetGuid(0));
    }

    return result;
  }

  private sealed record ArtifactProvenance(string RoleCode, string ArtifactKind);
}
