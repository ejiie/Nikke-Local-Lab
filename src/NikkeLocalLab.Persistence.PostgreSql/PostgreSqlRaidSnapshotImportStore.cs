using System.Globalization;
using System.Text;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlRaidSnapshotImportStore
{
  private const string StaticDataArtifactKind = "staticdata_archive";
  private const string EvidenceObjectArtifactKind = "raid_evidence_object";
  private const string StaticDataRole = "raid_staticdata";
  private const string BehaviorRole = "raid_evidence_behavior";
  private const string BundleRole = "raid_evidence_bundle";
  private const string TimelineRole = "raid_evidence_timeline";
  private const string RuntimeRole = "raid_evidence_runtime";
  private const string TimingRole = "raid_evidence_timing";
  private static readonly Sha256Digest CompatibilityMapContractSha256 =
      Sha256Digest.ComputeUtf8("nll/challenge-compatibility-map-binding/v1");
  private readonly PostgreSqlImportLedger _ledger;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlRaidSnapshotImportStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    ArgumentNullException.ThrowIfNull(dataSource);
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
    _ledger = new PostgreSqlImportLedger(dataSource, uidGenerator);
  }

  public async Task<RaidCatalogImportReceipt> RecordCompletedAndPublishAsync(
      CompletedImportAttempt attempt,
      RaidCatalogPublication publication,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(attempt);
    ArgumentNullException.ThrowIfNull(publication);
    ValidatePublication(attempt, publication);

    PublishedRaidCatalog? published = null;
    var importReceipt = await _ledger.RecordCompletedAtomicallyAsync(
        attempt,
        async (context, token) =>
        {
          published = await PublishWithinTransactionAsync(
              context,
              attempt,
              publication,
              token).ConfigureAwait(false);
        },
        cancellationToken).ConfigureAwait(false);

    if (published is null)
    {
      throw new RaidSnapshotIntegrityException("raid_publication_missing");
    }

    return new RaidCatalogImportReceipt(
        importReceipt,
        published.CatalogUid,
        published.CatalogManifestSha256,
        published.Members);
  }

  private static void ValidatePublication(
      CompletedImportAttempt attempt,
      RaidCatalogPublication publication)
  {
    if (attempt.Diagnostics.Any(static diagnostic =>
            diagnostic.Severity == ImportDiagnosticSeverity.Error))
    {
      throw new RaidSnapshotIntegrityException("raid_error_diagnostic");
    }

    if (attempt.OutputManifestSha256 != publication.CanonicalSha256)
    {
      throw new RaidSnapshotIntegrityException("raid_publication_hash_mismatch");
    }

    var artifacts = CollectArtifactClaims(publication);
    if (artifacts.Count == 0)
    {
      throw new RaidSnapshotIntegrityException("raid_artifact_set_empty");
    }

    var manifestArtifacts = attempt.DatasetManifest.Artifacts
        .GroupBy(static artifact => artifact.Artifact.ContentSha256)
        .ToDictionary(static group => group.Key, static group => group.ToArray());
    foreach (var claim in artifacts.Values)
    {
      if (!manifestArtifacts.TryGetValue(claim.Artifact.Sha256, out var memberships) ||
          memberships.Length != 1 ||
          memberships[0].Artifact.ByteLength != claim.Artifact.ByteLength ||
          !string.Equals(memberships[0].RoleCode, claim.RoleCode, StringComparison.Ordinal) ||
          !string.Equals(
              memberships[0].Artifact.ArtifactKind,
              claim.ArtifactKind,
              StringComparison.Ordinal))
      {
        throw new RaidSnapshotIntegrityException("raid_artifact_provenance_mismatch");
      }
    }
  }

  private async Task<PublishedRaidCatalog> PublishWithinTransactionAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      RaidCatalogPublication publication,
      CancellationToken cancellationToken)
  {
    var existing = await ReadCatalogByRequestAsync(
        context,
        attempt,
        publication,
        cancellationToken).ConfigureAwait(false);
    if (existing is not null)
    {
      await InsertImportProjectionAsync(
          context,
          existing.CatalogId,
          publication.Diagnostics.Count,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      await InsertDetailedDiagnosticsAsync(
          context,
          publication.Diagnostics,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      return existing;
    }

    if (context.IsReusedImport)
    {
      throw new RaidSnapshotIntegrityException("raid_reused_import_missing_publication");
    }

    var storedArtifacts = await ResolveArtifactsAsync(
        context,
        CollectArtifactClaims(publication),
        cancellationToken).ConfigureAwait(false);
    var storedMembers = new List<StoredRaidMember>(publication.Snapshots.Count);
    for (var ordinal = 0; ordinal < publication.Snapshots.Count; ordinal++)
    {
      var snapshot = publication.Snapshots[ordinal];
      var encounter = await ResolveEncounterAsync(
          context,
          snapshot.SeasonNumber,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var boss = await ResolveBossVariantAsync(
          context,
          encounter,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var compatibilityMap = await ResolveCompatibilityMapAsync(
          context,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var runtime = snapshot.ClientRuntime is null
          ? null
          : await ResolveRuntimeAsync(
              context,
              snapshot.ClientRuntime,
              RequireArtifact(storedArtifacts, snapshot.ClientRuntime.Artifact),
              attempt.FinishedAtUtc,
              cancellationToken).ConfigureAwait(false);

      storedMembers.Add(await InsertRaidSnapshotAsync(
          context,
          ordinal,
          snapshot,
          encounter,
          boss,
          compatibilityMap,
          runtime,
          storedArtifacts,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false));
    }

    var catalogManifestSha256 = ComputeCatalogManifest(
        context.DatasetSnapshotUid,
        storedMembers);
    var catalog = await InsertCatalogAsync(
        context,
        attempt,
        catalogManifestSha256,
        storedMembers,
        cancellationToken).ConfigureAwait(false);
    await InsertImportProjectionAsync(
        context,
        catalog.Id,
        publication.Diagnostics.Count,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await InsertDetailedDiagnosticsAsync(
        context,
        publication.Diagnostics,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);

    return new PublishedRaidCatalog(
        catalog.Id,
        catalog.Uid,
        catalogManifestSha256,
        ToReceipts(storedMembers));
  }

  private async Task<PublishedRaidCatalog?> ReadCatalogByRequestAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      RaidCatalogPublication publication,
      CancellationToken cancellationToken)
  {
    long catalogId;
    EntityUid catalogUid;
    Sha256Digest catalogManifest;
    await using (var command = new NpgsqlCommand(
                     """
                     SELECT raid_catalog_snapshot_id, raid_catalog_snapshot_uid,
                            dataset_snapshot_id, output_manifest_sha256,
                            catalog_manifest_sha256
                     FROM lab_raid.raid_catalog_snapshot
                     WHERE request_sha256 = $1;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      command.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return null;
      }

      if (reader.GetInt64(2) != context.DatasetSnapshotId ||
          !((byte[])reader[3]).AsSpan().SequenceEqual(attempt.OutputManifestSha256.ToByteArray()))
      {
        throw new RaidSnapshotIntegrityException("raid_catalog_provenance_mismatch");
      }

      catalogId = reader.GetInt64(0);
      catalogUid = new EntityUid(reader.GetGuid(1));
      catalogManifest = Sha256Digest.FromBytes((byte[])reader[4]);
    }

    var members = new List<StoredRaidMember>();
    await using (var command = new NpgsqlCommand(
                     """
                     SELECT member.ordinal, snapshot.raid_snapshot_id,
                            snapshot.raid_snapshot_uid, snapshot.season_number,
                            snapshot.content_sha256
                     FROM lab_raid.raid_catalog_snapshot_member AS member
                     JOIN lab_raid.raid_snapshot AS snapshot
                       ON snapshot.raid_snapshot_id = member.raid_snapshot_id
                     WHERE member.raid_catalog_snapshot_id = $1
                     ORDER BY member.ordinal;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      command.Parameters.AddWithValue(catalogId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        members.Add(new StoredRaidMember(
            reader.GetInt32(0),
            reader.GetInt64(1),
            new EntityUid(reader.GetGuid(2)),
            reader.GetInt32(3),
            Sha256Digest.FromBytes((byte[])reader[4])));
      }
    }

    if (members.Count != publication.Snapshots.Count ||
        !members.Select(static member => member.Ordinal)
            .SequenceEqual(Enumerable.Range(0, publication.Snapshots.Count)) ||
        !members.Select(static member => member.SeasonNumber)
            .SequenceEqual(publication.Snapshots.Select(static snapshot => snapshot.SeasonNumber)))
    {
      throw new RaidSnapshotIntegrityException("raid_catalog_membership_mismatch");
    }

    var computedManifest = ComputeCatalogManifest(context.DatasetSnapshotUid, members);
    if (computedManifest != catalogManifest)
    {
      throw new RaidSnapshotIntegrityException("raid_catalog_manifest_mismatch");
    }

    return new PublishedRaidCatalog(catalogId, catalogUid, catalogManifest, ToReceipts(members));
  }

  private async Task<StoredRaidMember> InsertRaidSnapshotAsync(
      PostgreSqlCompletedImportContext context,
      int catalogOrdinal,
      RaidSnapshotPublication publication,
      StoredEncounter encounter,
      StoredBossVariant boss,
      StoredCompatibilityMap compatibilityMap,
      StoredRuntime? runtime,
      IReadOnlyDictionary<Sha256Digest, StoredArtifact> artifacts,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var staticArtifact = RequireArtifact(artifacts, publication.StaticData);
    var behaviorArtifact = publication.Behavior is null
        ? null
        : RequireArtifact(artifacts, publication.Behavior);
    var bundles = publication.SelectedAssetBundles
        .Select(bundle => new StoredBundle(
            RequireArtifact(artifacts, bundle.Artifact),
            bundle.Roles))
        .OrderBy(static bundle => bundle.Artifact.Uid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var timelines = publication.Timelines
        .Select(timeline => new StoredTimeline(
            RequireArtifact(artifacts, timeline.Artifact),
            timeline.ClockBases))
        .OrderBy(static timeline => timeline.Artifact.Uid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var partIdentities = publication.Parts.ToDictionary(
        static part => part.Ordinal,
        _ => _uidGenerator.NewUid());
    var skillIdentities = publication.Skills.ToDictionary(
        static skill => skill.Ordinal,
        _ => _uidGenerator.NewUid());
    var snapshotUid = _uidGenerator.NewUid();
    var contentSha256 = ComputeSnapshotContent(
        context.DatasetSnapshotUid,
        snapshotUid,
        publication,
        encounter,
        boss,
        compatibilityMap,
        runtime,
        staticArtifact,
        behaviorArtifact,
        bundles,
        timelines,
        partIdentities,
        skillIdentities,
        artifacts);

    long snapshotId;
    await using (var command = new NpgsqlCommand(
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
                     VALUES
                         ($1, $2, $3, $4, $5, $6, 2, 'challenge', 2, 8,
                          'challenge-boss-support/v1', $7, $8, $9, 'supported',
                          $10, $11, $12, $13, $14, $15, 'ready', $16, $17)
                     RETURNING raid_snapshot_id;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      command.Parameters.AddWithValue(snapshotUid.Value);
      command.Parameters.AddWithValue(context.DatasetSnapshotId);
      command.Parameters.AddWithValue(encounter.Id);
      command.Parameters.AddWithValue(boss.Id);
      command.Parameters.AddWithValue(compatibilityMap.Id);
      command.Parameters.AddWithValue(publication.SeasonNumber);
      command.Parameters.AddWithValue(RaidPublicationCodes.AdmissionRule(publication.AdmissionRule));
      command.Parameters.AddWithValue(RaidPublicationCodes.Element(publication.BossElement));
      command.Parameters.AddWithValue(RaidPublicationCodes.Element(publication.WeaknessCode));
      command.Parameters.AddWithValue(staticArtifact.Id);
      command.Parameters.AddWithValue((object?)behaviorArtifact?.Id ?? DBNull.Value);
      command.Parameters.AddWithValue((object?)ComputeAssetBundleSetHash(bundles)?.ToByteArray() ?? DBNull.Value);
      command.Parameters.AddWithValue((object?)runtime?.Id ?? DBNull.Value);
      command.Parameters.AddWithValue(RaidPublicationCodes.CompatibilityTier(publication.CompatibilityTier));
      command.Parameters.AddWithValue(RaidPublicationCodes.RuntimeRelation(publication.RuntimeRelation));
      command.Parameters.AddWithValue(contentSha256.ToByteArray());
      command.Parameters.AddWithValue(createdAt);
      var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      snapshotId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }

    await InsertPartsAsync(
        context,
        snapshotId,
        publication.Parts,
        partIdentities,
        cancellationToken).ConfigureAwait(false);
    await InsertSkillsAsync(
        context,
        snapshotId,
        publication.Skills,
        skillIdentities,
        cancellationToken).ConfigureAwait(false);
    await InsertBundlesAsync(context, snapshotId, bundles, cancellationToken).ConfigureAwait(false);
    await InsertTimelinesAsync(context, snapshotId, timelines, cancellationToken).ConfigureAwait(false);
    await InsertTimingAsync(
        context,
        snapshotId,
        publication,
        artifacts,
        cancellationToken).ConfigureAwait(false);
    await InsertWarningsAsync(
        context,
        snapshotId,
        "raid_snapshot_compatibility_warning",
        publication.EvidenceWarningCodes,
        cancellationToken).ConfigureAwait(false);
    await InsertWarningsAsync(
        context,
        snapshotId,
        "raid_snapshot_readiness_warning",
        publication.ReadinessWarningCodes,
        cancellationToken).ConfigureAwait(false);

    return new StoredRaidMember(
        catalogOrdinal,
        snapshotId,
        snapshotUid,
        publication.SeasonNumber,
        contentSha256);
  }

  private static async Task InsertPartsAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      IReadOnlyList<RaidStaticPartPublication> parts,
      IReadOnlyDictionary<int, EntityUid> identities,
      CancellationToken cancellationToken)
  {
    foreach (var part in parts)
    {
      if (part.LinkedPartOrdinal is { } linked && !identities.ContainsKey(linked))
      {
        throw new RaidSnapshotIntegrityException("raid_part_link_invalid");
      }

      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_snapshot_part
              (raid_snapshot_id, ordinal, part_uid, type_code,
               damage_hp_ratio, hp_ratio, defence_ratio,
               energy_resist_ratio, metal_resist_ratio, bio_resist_ratio, attack_ratio,
               is_main_part, is_damageable, is_hp_visible, linked_part_ordinal)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(part.Ordinal);
      command.Parameters.AddWithValue(identities[part.Ordinal].Value);
      command.Parameters.AddWithValue(part.TypeCode);
      command.Parameters.AddWithValue(part.DamageHpRatio);
      command.Parameters.AddWithValue(part.HpRatio);
      command.Parameters.AddWithValue(part.DefenceRatio);
      command.Parameters.AddWithValue(part.EnergyResistRatio);
      command.Parameters.AddWithValue(part.MetalResistRatio);
      command.Parameters.AddWithValue(part.BioResistRatio);
      command.Parameters.AddWithValue(part.AttackRatio);
      command.Parameters.AddWithValue(part.IsMainPart);
      command.Parameters.AddWithValue(part.IsDamageable);
      command.Parameters.AddWithValue(part.IsHpVisible);
      command.Parameters.AddWithValue((object?)part.LinkedPartOrdinal ?? DBNull.Value);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task InsertSkillsAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      IReadOnlyList<RaidStaticSkillPublication> skills,
      IReadOnlyDictionary<int, EntityUid> identities,
      CancellationToken cancellationToken)
  {
    foreach (var skill in skills)
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_snapshot_skill
              (raid_snapshot_id, ordinal, skill_uid, role_code)
          VALUES ($1, $2, $3, $4);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(skill.Ordinal);
      command.Parameters.AddWithValue(identities[skill.Ordinal].Value);
      command.Parameters.AddWithValue(skill.RoleCode);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task InsertBundlesAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      IReadOnlyList<StoredBundle> bundles,
      CancellationToken cancellationToken)
  {
    for (var ordinal = 0; ordinal < bundles.Count; ordinal++)
    {
      var bundle = bundles[ordinal];
      await using (var command = new NpgsqlCommand(
                       """
                       INSERT INTO lab_raid.raid_snapshot_selected_bundle
                           (raid_snapshot_id, ordinal, source_artifact_id)
                       VALUES ($1, $2, $3);
                       """,
                       context.Connection,
                       context.Transaction))
      {
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(ordinal);
        command.Parameters.AddWithValue(bundle.Artifact.Id);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      foreach (var role in bundle.Roles)
      {
        await using var command = new NpgsqlCommand(
            """
            INSERT INTO lab_raid.raid_snapshot_selected_bundle_role
                (raid_snapshot_id, bundle_ordinal, role_code)
            VALUES ($1, $2, $3);
            """,
            context.Connection,
            context.Transaction);
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(ordinal);
        command.Parameters.AddWithValue(RaidAssetBundlePublication.ToCode(role));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }
  }

  private static async Task InsertTimelinesAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      IReadOnlyList<StoredTimeline> timelines,
      CancellationToken cancellationToken)
  {
    for (var ordinal = 0; ordinal < timelines.Count; ordinal++)
    {
      var timeline = timelines[ordinal];
      await using (var command = new NpgsqlCommand(
                       """
                       INSERT INTO lab_raid.raid_snapshot_timeline
                           (raid_snapshot_id, ordinal, source_artifact_id)
                       VALUES ($1, $2, $3);
                       """,
                       context.Connection,
                       context.Transaction))
      {
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(ordinal);
        command.Parameters.AddWithValue(timeline.Artifact.Id);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      foreach (var basis in timeline.ClockBases)
      {
        await using var command = new NpgsqlCommand(
            """
            INSERT INTO lab_raid.raid_snapshot_timeline_clock_basis
                (raid_snapshot_id, timeline_ordinal, clock_basis)
            VALUES ($1, $2, $3);
            """,
            context.Connection,
            context.Transaction);
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(ordinal);
        command.Parameters.AddWithValue(RaidPublicationCodes.ClockBasis(basis));
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }
  }

  private static async Task InsertTimingAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      RaidSnapshotPublication publication,
      IReadOnlyDictionary<Sha256Digest, StoredArtifact> artifacts,
      CancellationToken cancellationToken)
  {
    foreach (var clock in publication.ClockEvidence)
    {
      await using (var command = new NpgsqlCommand(
                       """
                       INSERT INTO lab_raid.raid_snapshot_timing_clock
                           (raid_snapshot_id, clock_basis, resolution, reason_code)
                       VALUES ($1, $2, $3, $4);
                       """,
                       context.Connection,
                       context.Transaction))
      {
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(RaidPublicationCodes.ClockBasis(clock.ClockBasis));
        command.Parameters.AddWithValue(RaidPublicationCodes.TimingResolution(clock.Resolution));
        command.Parameters.AddWithValue((object?)clock.ReasonCode ?? DBNull.Value);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      var clockArtifacts = clock.EvidenceArtifacts
          .Select(artifact => RequireArtifact(artifacts, artifact))
          .OrderBy(static artifact => artifact.Uid.ToString(), StringComparer.Ordinal)
          .ToArray();
      for (var ordinal = 0; ordinal < clockArtifacts.Length; ordinal++)
      {
        await using var command = new NpgsqlCommand(
            """
            INSERT INTO lab_raid.raid_snapshot_timing_clock_evidence
                (raid_snapshot_id, clock_basis, ordinal, source_artifact_id)
            VALUES ($1, $2, $3, $4);
            """,
            context.Connection,
            context.Transaction);
        command.Parameters.AddWithValue(snapshotId);
        command.Parameters.AddWithValue(RaidPublicationCodes.ClockBasis(clock.ClockBasis));
        command.Parameters.AddWithValue(ordinal);
        command.Parameters.AddWithValue(clockArtifacts[ordinal].Id);
        await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }

    var scheduler = publication.SchedulerEvidence;

    await using (var command = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.raid_snapshot_scheduler
                         (raid_snapshot_id, resolution, reason_code)
                     VALUES ($1, $2, $3);
                     """,
                     context.Connection,
                     context.Transaction))
    {
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(RaidPublicationCodes.TimingResolution(scheduler.Resolution));
      command.Parameters.AddWithValue((object?)scheduler.ReasonCode ?? DBNull.Value);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    foreach (var basis in scheduler.RelatedClockBases)
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_snapshot_scheduler_clock_basis
              (raid_snapshot_id, clock_basis)
          VALUES ($1, $2);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(RaidPublicationCodes.ClockBasis(basis));
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    var schedulerArtifacts = scheduler.EvidenceArtifacts
        .Select(artifact => RequireArtifact(artifacts, artifact))
        .OrderBy(static artifact => artifact.Uid.ToString(), StringComparer.Ordinal)
        .ToArray();
    for (var ordinal = 0; ordinal < schedulerArtifacts.Length; ordinal++)
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_snapshot_scheduler_evidence
              (raid_snapshot_id, ordinal, source_artifact_id)
          VALUES ($1, $2, $3);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(ordinal);
      command.Parameters.AddWithValue(schedulerArtifacts[ordinal].Id);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task InsertWarningsAsync(
      PostgreSqlCompletedImportContext context,
      long snapshotId,
      string tableName,
      IReadOnlyList<string> warningCodes,
      CancellationToken cancellationToken)
  {
    if (tableName is not ("raid_snapshot_compatibility_warning" or
        "raid_snapshot_readiness_warning"))
    {
      throw new RaidSnapshotIntegrityException("raid_warning_table_invalid");
    }

    for (var ordinal = 0; ordinal < warningCodes.Count; ordinal++)
    {
      await using var command = new NpgsqlCommand(
          $"INSERT INTO lab_raid.{tableName} " +
          "(raid_snapshot_id, ordinal, warning_code) VALUES ($1, $2, $3);",
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(snapshotId);
      command.Parameters.AddWithValue(ordinal);
      command.Parameters.AddWithValue(warningCodes[ordinal]);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private async Task<StoredCatalog> InsertCatalogAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      Sha256Digest catalogManifestSha256,
      IReadOnlyList<StoredRaidMember> members,
      CancellationToken cancellationToken)
  {
    var uid = _uidGenerator.NewUid();
    long id;
    await using (var command = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.raid_catalog_snapshot
                         (raid_catalog_snapshot_uid, dataset_snapshot_id, request_sha256,
                          output_manifest_sha256, catalog_manifest_sha256,
                          published_by_import_run_id, member_count, created_at_utc)
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                     RETURNING raid_catalog_snapshot_id;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      command.Parameters.AddWithValue(uid.Value);
      command.Parameters.AddWithValue(context.DatasetSnapshotId);
      command.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
      command.Parameters.AddWithValue(attempt.OutputManifestSha256.ToByteArray());
      command.Parameters.AddWithValue(catalogManifestSha256.ToByteArray());
      command.Parameters.AddWithValue(context.ImportRunId);
      command.Parameters.AddWithValue(members.Count);
      command.Parameters.AddWithValue(attempt.FinishedAtUtc);
      var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      id = Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }

    foreach (var member in members.OrderBy(static member => member.Ordinal))
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_catalog_snapshot_member
              (raid_catalog_snapshot_id, raid_snapshot_id, ordinal)
          VALUES ($1, $2, $3);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(id);
      command.Parameters.AddWithValue(member.Id);
      command.Parameters.AddWithValue(member.Ordinal);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return new StoredCatalog(id, uid);
  }

  private async Task InsertDetailedDiagnosticsAsync(
      PostgreSqlCompletedImportContext context,
      IReadOnlyList<RaidCatalogImportDiagnosticPublication> diagnostics,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    for (var sequence = 0; sequence < diagnostics.Count; sequence++)
    {
      var diagnostic = diagnostics[sequence];
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_raid.raid_catalog_import_diagnostic
              (raid_catalog_import_diagnostic_uid, import_run_id, sequence_number,
               season_number, diagnostic_code, occurrence_count, created_at_utc)
          VALUES ($1, $2, $3, $4, $5, $6, $7);
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(_uidGenerator.NewUid().Value);
      command.Parameters.AddWithValue(context.ImportRunId);
      command.Parameters.AddWithValue(sequence);
      command.Parameters.AddWithValue((object?)diagnostic.SeasonNumber ?? DBNull.Value);
      command.Parameters.AddWithValue(diagnostic.DiagnosticCode);
      command.Parameters.AddWithValue(diagnostic.OccurrenceCount);
      command.Parameters.AddWithValue(createdAt);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task InsertImportProjectionAsync(
      PostgreSqlCompletedImportContext context,
      long catalogId,
      int diagnosticCount,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_raid.raid_catalog_import_projection
            (import_run_id, raid_catalog_snapshot_id, diagnostic_count, created_at_utc)
        VALUES ($1, $2, $3, $4);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(context.ImportRunId);
    command.Parameters.AddWithValue(catalogId);
    command.Parameters.AddWithValue(diagnosticCount);
    command.Parameters.AddWithValue(createdAt);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private async Task<StoredEncounter> ResolveEncounterAsync(
      PostgreSqlCompletedImportContext context,
      int seasonNumber,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var candidateUid = _uidGenerator.NewUid();
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.challenge_encounter_entity
                         (challenge_encounter_uid, season_number, created_at_utc)
                     VALUES ($1, $2, $3)
                     ON CONFLICT (season_number) DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(candidateUid.Value);
      insert.Parameters.AddWithValue(seasonNumber);
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var read = new NpgsqlCommand(
        """
        SELECT challenge_encounter_id, challenge_encounter_uid
        FROM lab_raid.challenge_encounter_entity
        WHERE season_number = $1;
        """,
        context.Connection,
        context.Transaction);
    read.Parameters.AddWithValue(seasonNumber);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new RaidSnapshotIntegrityException("raid_encounter_resolution_failed");
    }

    return new StoredEncounter(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
  }

  private async Task<StoredBossVariant> ResolveBossVariantAsync(
      PostgreSqlCompletedImportContext context,
      StoredEncounter encounter,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var candidateUid = _uidGenerator.NewUid();
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.boss_variant_entity
                         (boss_variant_uid, challenge_encounter_id, created_at_utc)
                     VALUES ($1, $2, $3)
                     ON CONFLICT (challenge_encounter_id) DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(candidateUid.Value);
      insert.Parameters.AddWithValue(encounter.Id);
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var read = new NpgsqlCommand(
        """
        SELECT boss_variant_id, boss_variant_uid
        FROM lab_raid.boss_variant_entity
        WHERE challenge_encounter_id = $1;
        """,
        context.Connection,
        context.Transaction);
    read.Parameters.AddWithValue(encounter.Id);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new RaidSnapshotIntegrityException("raid_boss_resolution_failed");
    }

    return new StoredBossVariant(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
  }

  private async Task<StoredCompatibilityMap> ResolveCompatibilityMapAsync(
      PostgreSqlCompletedImportContext context,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var candidateUid = _uidGenerator.NewUid();
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.compatibility_map
                         (compatibility_map_uid, dataset_snapshot_id,
                          map_contract_sha256, created_at_utc)
                     VALUES ($1, $2, $3, $4)
                     ON CONFLICT (dataset_snapshot_id) DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(candidateUid.Value);
      insert.Parameters.AddWithValue(context.DatasetSnapshotId);
      insert.Parameters.AddWithValue(CompatibilityMapContractSha256.ToByteArray());
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var read = new NpgsqlCommand(
        """
        SELECT compatibility_map_id, compatibility_map_uid, map_contract_sha256
        FROM lab_raid.compatibility_map
        WHERE dataset_snapshot_id = $1;
        """,
        context.Connection,
        context.Transaction);
    read.Parameters.AddWithValue(context.DatasetSnapshotId);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new RaidSnapshotIntegrityException("raid_compatibility_map_resolution_failed");
    }

    if (!((byte[])reader[2]).AsSpan().SequenceEqual(CompatibilityMapContractSha256.ToByteArray()))
    {
      throw new RaidSnapshotIntegrityException("raid_compatibility_map_contract_mismatch");
    }

    return new StoredCompatibilityMap(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
  }

  private async Task<StoredRuntime> ResolveRuntimeAsync(
      PostgreSqlCompletedImportContext context,
      RaidClientRuntimePublication publication,
      StoredArtifact artifact,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var candidateUid = _uidGenerator.NewUid();
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_raid.client_runtime_build
                         (client_runtime_build_uid, source_artifact_id,
                          local_build_label, created_at_utc)
                     VALUES ($1, $2, $3, $4)
                     ON CONFLICT DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(candidateUid.Value);
      insert.Parameters.AddWithValue(artifact.Id);
      insert.Parameters.AddWithValue(publication.LocalBuildLabel);
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var read = new NpgsqlCommand(
        """
        SELECT client_runtime_build_id, client_runtime_build_uid,
               source_artifact_id, local_build_label
        FROM lab_raid.client_runtime_build
        WHERE source_artifact_id = $1 OR local_build_label = $2
        ORDER BY client_runtime_build_id;
        """,
        context.Connection,
        context.Transaction);
    read.Parameters.AddWithValue(artifact.Id);
    read.Parameters.AddWithValue(publication.LocalBuildLabel);
    await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new RaidSnapshotIntegrityException("raid_runtime_resolution_failed");
    }

    var id = reader.GetInt64(0);
    var uid = new EntityUid(reader.GetGuid(1));
    var sourceArtifactId = reader.GetInt64(2);
    var storedLabel = reader.GetString(3);
    if (sourceArtifactId != artifact.Id ||
        !string.Equals(storedLabel, publication.LocalBuildLabel, StringComparison.Ordinal) ||
        await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new RaidSnapshotIntegrityException("raid_runtime_binding_mismatch");
    }

    return new StoredRuntime(id, uid, storedLabel, artifact);
  }

  private static async Task<IReadOnlyDictionary<Sha256Digest, StoredArtifact>> ResolveArtifactsAsync(
      PostgreSqlCompletedImportContext context,
      IReadOnlyDictionary<Sha256Digest, RaidArtifactClaim> claims,
      CancellationToken cancellationToken)
  {
    var stored = new Dictionary<Sha256Digest, StoredArtifact>();
    await using var command = new NpgsqlCommand(
        """
        SELECT artifact.source_artifact_id, artifact.source_artifact_uid,
               artifact.content_sha256, artifact.byte_length,
               member.role_code, artifact.artifact_kind
        FROM lab_import.dataset_snapshot_source_artifact AS member
        JOIN lab_import.source_artifact AS artifact
          ON artifact.source_artifact_id = member.source_artifact_id
        WHERE member.dataset_snapshot_id = $1;
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(context.DatasetSnapshotId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      var digest = Sha256Digest.FromBytes((byte[])reader[2]);
      if (claims.TryGetValue(digest, out var claim))
      {
        var length = reader.GetInt64(3);
        if (length != claim.Artifact.ByteLength ||
            !string.Equals(reader.GetString(4), claim.RoleCode, StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(5), claim.ArtifactKind, StringComparison.Ordinal) ||
            !stored.TryAdd(
                digest,
                new StoredArtifact(
                    reader.GetInt64(0),
                    new EntityUid(reader.GetGuid(1)),
                    digest,
                    length)))
        {
          throw new RaidSnapshotIntegrityException("raid_artifact_provenance_mismatch");
        }
      }
    }

    if (stored.Count != claims.Count)
    {
      throw new RaidSnapshotIntegrityException("raid_artifact_not_in_dataset");
    }

    return stored;
  }

  private static IReadOnlyDictionary<Sha256Digest, RaidArtifactClaim> CollectArtifactClaims(
      RaidCatalogPublication publication)
  {
    var result = new Dictionary<Sha256Digest, RaidArtifactClaim>();
    foreach (var snapshot in publication.Snapshots)
    {
      AddPrimary(snapshot.StaticData, StaticDataRole, StaticDataArtifactKind);
      AddPrimary(snapshot.Behavior, BehaviorRole, EvidenceObjectArtifactKind);
      foreach (var bundle in snapshot.SelectedAssetBundles)
      {
        AddPrimary(bundle.Artifact, BundleRole, EvidenceObjectArtifactKind);
      }

      foreach (var timeline in snapshot.Timelines)
      {
        AddPrimary(timeline.Artifact, TimelineRole, EvidenceObjectArtifactKind);
      }

      AddPrimary(snapshot.ClientRuntime?.Artifact, RuntimeRole, EvidenceObjectArtifactKind);
    }

    foreach (var snapshot in publication.Snapshots)
    {
      foreach (var artifact in snapshot.ClockEvidence.SelectMany(static clock => clock.EvidenceArtifacts)
                   .Concat(snapshot.SchedulerEvidence.EvidenceArtifacts))
      {
        AddTiming(artifact);
      }
    }

    return result;

    void AddPrimary(
        RaidEvidenceArtifactPublication? artifact,
        string roleCode,
        string artifactKind)
    {
      if (artifact is null)
      {
        return;
      }

      if (result.TryGetValue(artifact.Sha256, out var existing))
      {
        if (existing.Artifact.ByteLength != artifact.ByteLength)
        {
          throw new RaidSnapshotIntegrityException("raid_artifact_claim_mismatch");
        }

        if (!string.Equals(existing.RoleCode, roleCode, StringComparison.Ordinal) ||
            !string.Equals(existing.ArtifactKind, artifactKind, StringComparison.Ordinal))
        {
          throw new RaidSnapshotIntegrityException("raid_artifact_role_conflict");
        }

        return;
      }

      result.Add(artifact.Sha256, new RaidArtifactClaim(artifact, roleCode, artifactKind));
    }

    void AddTiming(RaidEvidenceArtifactPublication artifact)
    {
      if (result.TryGetValue(artifact.Sha256, out var existing))
      {
        if (existing.Artifact.ByteLength != artifact.ByteLength)
        {
          throw new RaidSnapshotIntegrityException("raid_artifact_claim_mismatch");
        }

        return;
      }

      result.Add(
          artifact.Sha256,
          new RaidArtifactClaim(artifact, TimingRole, EvidenceObjectArtifactKind));
    }
  }

  private static StoredArtifact RequireArtifact(
      IReadOnlyDictionary<Sha256Digest, StoredArtifact> artifacts,
      RaidEvidenceArtifactPublication publication)
  {
    if (!artifacts.TryGetValue(publication.Sha256, out var artifact) ||
        artifact.ByteLength != publication.ByteLength)
    {
      throw new RaidSnapshotIntegrityException("raid_artifact_not_in_dataset");
    }

    return artifact;
  }

  private static Sha256Digest? ComputeAssetBundleSetHash(IReadOnlyList<StoredBundle> bundles)
  {
    if (bundles.Count == 0)
    {
      return null;
    }

    return Sha256Digest.ComputeUtf8(string.Join('\n', bundles
        .Select(static bundle => bundle.Artifact.Sha256.Hex)
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static value => value, StringComparer.Ordinal)));
  }

  private static Sha256Digest ComputeSnapshotContent(
      EntityUid datasetSnapshotUid,
      EntityUid snapshotUid,
      RaidSnapshotPublication publication,
      StoredEncounter encounter,
      StoredBossVariant boss,
      StoredCompatibilityMap compatibilityMap,
      StoredRuntime? runtime,
      StoredArtifact staticArtifact,
      StoredArtifact? behaviorArtifact,
      IReadOnlyList<StoredBundle> bundles,
      IReadOnlyList<StoredTimeline> timelines,
      IReadOnlyDictionary<int, EntityUid> partIdentities,
      IReadOnlyDictionary<int, EntityUid> skillIdentities,
      IReadOnlyDictionary<Sha256Digest, StoredArtifact> artifacts)
  {
    try
    {
      var staticRelations = new RaidStaticRelations(
          publication.Parts.Select(part => new RaidPartStaticRelation(
              partIdentities[part.Ordinal],
              part.Ordinal,
              part.TypeCode,
              part.DamageHpRatio,
              part.HpRatio,
              part.DefenceRatio,
              part.EnergyResistRatio,
              part.MetalResistRatio,
              part.BioResistRatio,
              part.AttackRatio,
              part.IsMainPart,
              part.IsDamageable,
              part.IsHpVisible,
              part.LinkedPartOrdinal is { } linked ? partIdentities[linked] : null)),
          publication.Skills.Select(skill => new RaidSkillStaticRelation(
              skillIdentities[skill.Ordinal],
              skill.Ordinal,
              skill.RoleCode)));
      var timing = new TimingProvenance(
          publication.ClockEvidence.Select(clock =>
              clock.Resolution == TimingEvidenceResolution.Unresolved
                  ? ClockBasisEvidence.Unresolved(clock.ClockBasis, clock.ReasonCode!)
                  : ClockBasisEvidence.Resolved(
                      clock.ClockBasis,
                      clock.Resolution,
                      clock.EvidenceArtifacts.Select(artifact =>
                          ToDomainArtifact(RequireArtifact(artifacts, artifact))))),
          publication.SchedulerEvidence.Resolution == TimingEvidenceResolution.Unresolved
              ? SchedulerEvidence.Unresolved(
                  publication.SchedulerEvidence.RelatedClockBases,
                  publication.SchedulerEvidence.ReasonCode!)
              : SchedulerEvidence.Resolved(
                  publication.SchedulerEvidence.Resolution,
                  publication.SchedulerEvidence.RelatedClockBases,
                  publication.SchedulerEvidence.EvidenceArtifacts.Select(artifact =>
                      ToDomainArtifact(RequireArtifact(artifacts, artifact)))));
      var provenance = new RaidSnapshotProvenance(
          ToDomainArtifact(staticArtifact),
          bundles.Select(bundle => new SelectedAssetBundle(
              bundle.Artifact.Uid,
              bundle.Artifact.Sha256,
              bundle.Roles)),
          behaviorArtifact is null ? null : ToDomainArtifact(behaviorArtifact),
          timelines.Select(timeline => new TimelineArtifactReference(
              ToDomainArtifact(timeline.Artifact),
              timeline.ClockBases)),
          runtime is null
              ? ClientRuntimeReference.Unresolved()
              : ClientRuntimeReference.Resolved(
                  runtime.Uid,
                  runtime.LocalLabel,
                  runtime.Artifact.Sha256),
          timing);
      var admission = ChallengeBossSupportPolicy.Evaluate(
          publication.SeasonNumber,
          publication.BossElement,
          publication.WeaknessCode,
          authoritativeChallengeChainResolved: true);
      return RaidSnapshot.Publish(
          snapshotUid,
          datasetSnapshotUid,
          encounter.Uid,
          boss.Uid,
          compatibilityMap.Uid,
          publication.SeasonNumber,
          admission,
          staticRelations,
          provenance,
          new RaidCompatibility(
              publication.CompatibilityTier,
              publication.RuntimeRelation,
              publication.EvidenceWarningCodes),
          publication.ReadinessWarningCodes).ContentSha256;
    }
    catch (RaidSnapshotIntegrityException)
    {
      throw;
    }
    catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
    {
      throw new RaidSnapshotIntegrityException("raid_domain_publication_invalid");
    }
  }

  private static RaidArtifactReference ToDomainArtifact(StoredArtifact artifact) =>
      new(artifact.Uid, artifact.Sha256);

  private static Sha256Digest ComputeSnapshotContentLegacy(
      EntityUid datasetSnapshotUid,
      EntityUid ignoredSnapshotUid,
      RaidSnapshotPublication publication,
      StoredEncounter encounter,
      StoredBossVariant boss,
      StoredCompatibilityMap compatibilityMap,
      StoredRuntime? runtime,
      StoredArtifact staticArtifact,
      StoredArtifact? behaviorArtifact,
      IReadOnlyList<StoredBundle> bundles,
      IReadOnlyList<StoredTimeline> timelines,
      IReadOnlyDictionary<int, EntityUid> partIdentities,
      IReadOnlyDictionary<int, EntityUid> skillIdentities,
      IReadOnlyDictionary<Sha256Digest, StoredArtifact> artifacts)
  {
    _ = ignoredSnapshotUid;
    var lines = new List<string>
    {
      "nll/raid-snapshot/v2",
      $"dataset-snapshot-uid={datasetSnapshotUid}",
      $"challenge-encounter-uid={encounter.Uid}",
      $"boss-variant-uid={boss.Uid}",
      $"compatibility-map-uid={compatibilityMap.Uid}",
      $"season-number={publication.SeasonNumber.ToString(CultureInfo.InvariantCulture)}",
      "mode=challenge",
      "challenge.difficulty-type=2",
      "challenge.wave-order=8",
      "admission.policy-id=challenge-boss-support/v1",
      $"admission.rule={RaidPublicationCodes.AdmissionRule(publication.AdmissionRule)}",
      $"admission.boss-element={RaidPublicationCodes.Element(publication.BossElement)}",
      $"admission.weakness-code={RaidPublicationCodes.Element(publication.WeaknessCode)}",
      "admission.status=supported"
    };

    foreach (var part in publication.Parts)
    {
      lines.Add($"static.part.{part.Ordinal.ToString(CultureInfo.InvariantCulture)}=" + string.Join('\t',
          partIdentities[part.Ordinal],
          part.TypeCode,
          part.DamageHpRatio.ToString(CultureInfo.InvariantCulture),
          part.HpRatio.ToString(CultureInfo.InvariantCulture),
          part.DefenceRatio.ToString(CultureInfo.InvariantCulture),
          part.EnergyResistRatio.ToString(CultureInfo.InvariantCulture),
          part.MetalResistRatio.ToString(CultureInfo.InvariantCulture),
          part.BioResistRatio.ToString(CultureInfo.InvariantCulture),
          part.AttackRatio.ToString(CultureInfo.InvariantCulture),
          part.IsMainPart ? "true" : "false",
          part.IsDamageable ? "true" : "false",
          part.IsHpVisible ? "true" : "false",
          part.LinkedPartOrdinal is { } linked ? partIdentities[linked].ToString() : "none"));
    }

    foreach (var skill in publication.Skills)
    {
      lines.Add($"static.skill.{skill.Ordinal.ToString(CultureInfo.InvariantCulture)}=" +
          $"{skillIdentities[skill.Ordinal]}\t{skill.RoleCode}");
    }

    lines.Add($"provenance.static-data={Artifact(staticArtifact)}");
    lines.Add($"provenance.asset-bundle-set-sha256={ComputeAssetBundleSetHash(bundles)?.Hex ?? "unresolved"}");
    for (var index = 0; index < bundles.Count; index++)
    {
      var bundle = bundles[index];
      lines.Add($"provenance.asset-bundle.{index.ToString(CultureInfo.InvariantCulture)}=" +
          $"{Artifact(bundle.Artifact)}\t{string.Join(',', bundle.Roles.Select(RaidAssetBundlePublication.ToCode))}");
    }

    lines.Add(behaviorArtifact is null
        ? "provenance.behavior=unresolved"
        : $"provenance.behavior={Artifact(behaviorArtifact)}");
    for (var index = 0; index < timelines.Count; index++)
    {
      var timeline = timelines[index];
      lines.Add($"provenance.timeline.{index.ToString(CultureInfo.InvariantCulture)}=" +
          $"{Artifact(timeline.Artifact)}\t" +
          string.Join(',', timeline.ClockBases.Select(RaidPublicationCodes.ClockBasis)));
    }

    lines.Add(runtime is null
        ? "provenance.client-runtime=unresolved"
        : $"provenance.client-runtime={runtime.Uid}\t{runtime.LocalLabel}\t{runtime.Artifact.Sha256}");
    foreach (var clock in publication.ClockEvidence)
    {
      var prefix = $"provenance.timing.clock.{RaidPublicationCodes.ClockBasis(clock.ClockBasis)}";
      lines.Add($"{prefix}.resolution={RaidPublicationCodes.TimingResolution(clock.Resolution)}");
      if (clock.ReasonCode is not null)
      {
        lines.Add($"{prefix}.reason={clock.ReasonCode}");
      }
      else
      {
        for (var index = 0; index < clock.EvidenceArtifacts.Count; index++)
        {
          lines.Add($"{prefix}.evidence.{index.ToString(CultureInfo.InvariantCulture)}=" +
              Artifact(RequireArtifact(artifacts, clock.EvidenceArtifacts[index])));
        }
      }
    }

    if (publication.SchedulerEvidence is { } scheduler)
    {
      lines.Add("provenance.timing.scheduler.resolution=" +
          RaidPublicationCodes.TimingResolution(scheduler.Resolution));
      lines.Add("provenance.timing.scheduler.clock-bases=" +
          string.Join(',', scheduler.RelatedClockBases.Select(RaidPublicationCodes.ClockBasis)));
      if (scheduler.ReasonCode is not null)
      {
        lines.Add($"provenance.timing.scheduler.reason={scheduler.ReasonCode}");
      }
      else
      {
        for (var index = 0; index < scheduler.EvidenceArtifacts.Count; index++)
        {
          lines.Add($"provenance.timing.scheduler.evidence.{index.ToString(CultureInfo.InvariantCulture)}=" +
              Artifact(RequireArtifact(artifacts, scheduler.EvidenceArtifacts[index])));
        }
      }
    }
    else
    {
      lines.Add("provenance.timing.scheduler.resolution=unresolved");
      lines.Add("provenance.timing.scheduler.clock-bases=");
      lines.Add("provenance.timing.scheduler.reason=timing_not_evaluated");
    }

    lines.Add($"compatibility.tier={RaidPublicationCodes.CompatibilityTier(publication.CompatibilityTier)}");
    lines.Add($"compatibility.runtime-relation={RaidPublicationCodes.RuntimeRelation(publication.RuntimeRelation)}");
    for (var index = 0; index < publication.EvidenceWarningCodes.Count; index++)
    {
      lines.Add($"compatibility.warning.{index.ToString(CultureInfo.InvariantCulture)}=" +
          publication.EvidenceWarningCodes[index]);
    }

    lines.Add("readiness.status=ready");
    for (var index = 0; index < publication.ReadinessWarningCodes.Count; index++)
    {
      lines.Add($"readiness.warning.{index.ToString(CultureInfo.InvariantCulture)}=" +
          publication.ReadinessWarningCodes[index]);
    }

    return Sha256Digest.ComputeUtf8(string.Join('\n', lines));
  }

  private static Sha256Digest ComputeCatalogManifest(
      EntityUid datasetSnapshotUid,
      IReadOnlyList<StoredRaidMember> members)
  {
    var builder = new StringBuilder("nll/raid-catalog-manifest/v1")
        .Append('\n').Append("dataset-snapshot-uid=").Append(datasetSnapshotUid)
        .Append('\n').Append("count=").Append(members.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var member in members.OrderBy(static member => member.Ordinal))
    {
      builder.Append('\n')
          .Append(member.Ordinal.ToString(CultureInfo.InvariantCulture)).Append('\t')
          .Append(member.SeasonNumber.ToString(CultureInfo.InvariantCulture)).Append('\t')
          .Append(member.Uid).Append('\t')
          .Append(member.ContentSha256);
    }

    return Sha256Digest.ComputeUtf8(builder.ToString());
  }

  private static IReadOnlyList<RaidSnapshotMemberReceipt> ToReceipts(
      IEnumerable<StoredRaidMember> members) => members
      .OrderBy(static member => member.Ordinal)
      .Select(static member => new RaidSnapshotMemberReceipt(
          member.Ordinal,
          member.SeasonNumber,
          member.Uid,
          member.ContentSha256))
      .ToArray();

  private static string Artifact(StoredArtifact artifact) =>
      $"{artifact.Uid}\t{artifact.Sha256}";

  private sealed record StoredArtifact(
      long Id,
      EntityUid Uid,
      Sha256Digest Sha256,
      long ByteLength);

  private sealed record RaidArtifactClaim(
      RaidEvidenceArtifactPublication Artifact,
      string RoleCode,
      string ArtifactKind);

  private sealed record StoredEncounter(long Id, EntityUid Uid);

  private sealed record StoredBossVariant(long Id, EntityUid Uid);

  private sealed record StoredCompatibilityMap(long Id, EntityUid Uid);

  private sealed record StoredRuntime(
      long Id,
      EntityUid Uid,
      string LocalLabel,
      StoredArtifact Artifact);

  private sealed record StoredBundle(
      StoredArtifact Artifact,
      IReadOnlyList<AssetBundleRole> Roles);

  private sealed record StoredTimeline(
      StoredArtifact Artifact,
      IReadOnlyList<ClockBasis> ClockBases);

  private sealed record StoredRaidMember(
      int Ordinal,
      long Id,
      EntityUid Uid,
      int SeasonNumber,
      Sha256Digest ContentSha256);

  private sealed record StoredCatalog(long Id, EntityUid Uid);

  private sealed record PublishedRaidCatalog(
      long CatalogId,
      EntityUid CatalogUid,
      Sha256Digest CatalogManifestSha256,
      IReadOnlyList<RaidSnapshotMemberReceipt> Members);
}
