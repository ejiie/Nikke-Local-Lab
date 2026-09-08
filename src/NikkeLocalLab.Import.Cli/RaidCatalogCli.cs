using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.RaidCatalog;
using NikkeLocalLab.Import.Sources;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;

internal static class RaidCatalogCli
{
  private static readonly ExtractorDescriptor Extractor = new(
      "challenge_raid_catalog",
      "v2",
      Sha256Digest.ComputeUtf8("nll/challenge-raid-catalog-extractor-contract/v2"));

  public static async Task<int> InspectAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    var input = RequireInput(configuration, repositoryRoot, options);
    var result = await ReadStableAsync(input).ConfigureAwait(false);
    Console.WriteLine("raid_catalog_valid");
    Console.WriteLine($"source_artifact_count={CreateDatasetInputs(result).Count}");
    Console.WriteLine($"raid_count={result.Extraction.PublishableCandidateCount}");
    Console.WriteLine($"candidate_sha256={result.Extraction.CanonicalCandidateSha256}");
    foreach (var candidate in result.Extraction.Candidates.Where(static candidate => candidate.CanPublish))
    {
      Console.WriteLine($"season={candidate.SeasonNumber}:tier={TierCode(candidate.Evidence.Tier)}");
    }

    foreach (var diagnostic in result.Extraction.Diagnostics)
    {
      Console.WriteLine(
          $"diagnostic={diagnostic.Code}:{diagnostic.SeasonNumber?.ToString() ?? "none"}:{diagnostic.OccurrenceCount}");
    }

    return 0;
  }

  public static async Task<int> ImportAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
    var input = RequireInput(configuration, repositoryRoot, options);
    var startedAt = DateTimeOffset.UtcNow;
    var result = await ReadStableAsync(input).ConfigureAwait(false);
    var datasetManifest = CanonicalDatasetManifest.Create(CreateDatasetInputs(result));
    var publication = ToPublication(result.Extraction, result.StaticDataObservation.ByteLength);
    var requestSha256 = ImportRequestFingerprint.Create(
        datasetManifest.CanonicalSha256,
        Extractor.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var uidGenerator = new RandomEntityUidGenerator();
    var attempt = new CompletedImportAttempt(
        uidGenerator.NewUid(),
        uidGenerator.NewUid(),
        datasetManifest.Artifacts
            .Select(item => new ArtifactRegistration(uidGenerator.NewUid(), item))
            .ToArray(),
        datasetManifest,
        Extractor,
        SemanticOptionsFingerprint.Empty,
        requestSha256,
        publication.CanonicalSha256,
        result.Extraction.Diagnostics.Select(ToSafeDiagnostic).ToArray(),
        startedAt,
        DateTimeOffset.UtcNow);

    var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment(
        configuration.DatabaseConnectionStringEnvironmentVariable);
    await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
    await new PostgreSqlMigrationRunner().MigrateAsync(dataSource).ConfigureAwait(false);
    var store = new PostgreSqlRaidSnapshotImportStore(dataSource, uidGenerator);
    var receipt = await store.RecordCompletedAndPublishAsync(attempt, publication).ConfigureAwait(false);
    Console.WriteLine("raid_catalog_imported");
    Console.WriteLine($"status={receipt.Import.Status.ToString().ToLowerInvariant()}");
    Console.WriteLine($"raid_catalog_snapshot_uid={receipt.RaidCatalogSnapshotUid}");
    Console.WriteLine($"catalog_manifest_sha256={receipt.CatalogManifestSha256}");
    Console.WriteLine($"raid_count={receipt.Members.Count}");
    foreach (var member in receipt.Members)
    {
      Console.WriteLine($"season={member.SeasonNumber}:raid_snapshot_uid={member.RaidSnapshotUid}");
    }

    return 0;
  }

  private static async Task<RaidCatalogReadResult> ReadStableAsync(RaidCatalogInput input)
  {
    var staticBefore = await input.StaticDataSource.ObserveAsync().ConfigureAwait(false);
    SourceArtifactObservation? evidenceBefore = null;
    if (input.EvidenceSource is not null)
    {
      evidenceBefore = await input.EvidenceSource.ObserveAsync().ConfigureAwait(false);
    }

    ChallengeRaidCatalogExtraction extraction;
    if (input.EvidenceSource is null)
    {
      extraction = await input.StaticDataSource.ReadAsync(
          (stream, _) => Task.FromResult(new StaticDataChallengeRaidCatalogReader().Read(stream)))
          .ConfigureAwait(false);
    }
    else
    {
      extraction = await input.StaticDataSource.ReadAsync(
          (staticStream, _) => input.EvidenceSource.ReadAsync(
              (evidenceStream, _) => Task.FromResult(
                  new StaticDataChallengeRaidCatalogReader().Read(staticStream, evidenceStream))))
          .ConfigureAwait(false);
    }

    var staticAfter = await input.StaticDataSource.ObserveAsync().ConfigureAwait(false);
    SourceArtifactObservation? evidenceAfter = null;
    if (input.EvidenceSource is not null)
    {
      evidenceAfter = await input.EvidenceSource.ObserveAsync().ConfigureAwait(false);
    }

    if (staticBefore != staticAfter || evidenceBefore != evidenceAfter ||
        extraction.StaticDataArchiveSha256 != staticBefore.ContentSha256 ||
        extraction.CompatibilityArchiveSha256 != evidenceBefore?.ContentSha256)
    {
      throw new ChallengeRaidCatalogSourceException("source_changed_during_import");
    }

    return new RaidCatalogReadResult(extraction, staticBefore, evidenceBefore);
  }

  private static IReadOnlyList<DatasetArtifactInput> CreateDatasetInputs(RaidCatalogReadResult result)
  {
    return CreateDatasetInputs(
        result.Extraction,
        result.StaticDataObservation,
        result.EvidenceArchiveObservation);
  }

  internal static IReadOnlyList<DatasetArtifactInput> CreateDatasetInputs(
      ChallengeRaidCatalogExtraction extraction,
      SourceArtifactObservation staticDataObservation,
      SourceArtifactObservation? evidenceArchiveObservation)
  {
    ArgumentNullException.ThrowIfNull(extraction);
    ArgumentNullException.ThrowIfNull(staticDataObservation);
    var inputs = new List<DatasetArtifactInput>
    {
      new("raid_staticdata", staticDataObservation)
    };
    if (evidenceArchiveObservation is not null)
    {
      inputs.Add(new DatasetArtifactInput("raid_evidence_archive", evidenceArchiveObservation));
    }

    var evidenceObjects = new Dictionary<Sha256Digest, EvidenceObjectInput>();
    foreach (var candidate in extraction.Candidates)
    {
      AddEvidenceObject(evidenceObjects, "raid_evidence_behavior", candidate.Evidence.Behavior);
      foreach (var timeline in candidate.Evidence.Timelines)
      {
        AddEvidenceObject(
            evidenceObjects,
            "raid_evidence_timeline",
            new ChallengeArtifactEvidence(timeline.Sha256, timeline.ByteLength));
      }

      foreach (var bundle in candidate.Evidence.AssetBundles)
      {
        AddEvidenceObject(
            evidenceObjects,
            "raid_evidence_bundle",
            new ChallengeArtifactEvidence(bundle.Sha256, bundle.ByteLength));
      }

      if (candidate.Evidence.Runtime is { } runtime)
      {
        AddEvidenceObject(
            evidenceObjects,
            "raid_evidence_runtime",
            new ChallengeArtifactEvidence(runtime.Sha256, runtime.ByteLength));
      }
    }

    inputs.AddRange(evidenceObjects.Values.Select(item => new DatasetArtifactInput(
        item.RoleCode,
        new SourceArtifactObservation("raid_evidence_object", item.Sha256, item.ByteLength))));
    return inputs;
  }

  private static void AddEvidenceObject(
      IDictionary<Sha256Digest, EvidenceObjectInput> objects,
      string roleCode,
      ChallengeArtifactEvidence? artifact)
  {
    if (artifact is null)
    {
      return;
    }

    if (objects.TryGetValue(artifact.Sha256, out var existing))
    {
      if (existing.ByteLength != artifact.ByteLength ||
          !string.Equals(existing.RoleCode, roleCode, StringComparison.Ordinal))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_role_invalid");
      }

      return;
    }

    objects.Add(
        artifact.Sha256,
        new EvidenceObjectInput(roleCode, artifact.Sha256, artifact.ByteLength));
  }

  internal static RaidCatalogPublication ToPublication(
      ChallengeRaidCatalogExtraction extraction,
      long staticDataByteLength)
  {
    var snapshots = extraction.Candidates
        .Where(static candidate => candidate.CanPublish)
        .Select(candidate => ToPublication(candidate, staticDataByteLength))
        .ToArray();
    if (snapshots.Length == 0)
    {
      throw new RaidSnapshotIntegrityException("raid_catalog_no_publishable_snapshot");
    }

    return new RaidCatalogPublication(
        snapshots,
        extraction.Diagnostics.Select(diagnostic => new RaidCatalogImportDiagnosticPublication(
            diagnostic.Code,
            diagnostic.SeasonNumber,
            diagnostic.OccurrenceCount)));
  }

  private static RaidSnapshotPublication ToPublication(
      NormalizedChallengeRaidCandidate candidate,
      long staticDataByteLength)
  {
    var evidence = candidate.Evidence;
    var artifacts = CreateArtifactLookup(evidence);
    return new RaidSnapshotPublication(
        candidate.SeasonNumber,
        ParseElement(candidate.Affinity!.Element),
        ParseElement(candidate.Affinity.Weakness),
        new RaidEvidenceArtifactPublication(evidence.StaticDataArchiveSha256, staticDataByteLength),
        candidate.Parts.Select(part => new RaidStaticPartPublication(
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
            part.LinkedPartOrdinal)),
        Enumerable.Range(0, candidate.MonsterSkillRelationCount!.Value)
            .Select(static ordinal => new RaidStaticSkillPublication(ordinal, "monster_skill_slot")),
        evidence.Tier,
        evidence.RuntimeRelation,
        evidence.Behavior is null ? null : Artifact(evidence.Behavior),
        evidence.AssetBundles.Select(bundle => new RaidAssetBundlePublication(
            new RaidEvidenceArtifactPublication(bundle.Sha256, bundle.ByteLength),
            bundle.Roles)),
        evidence.Timelines.Select(timeline => new RaidTimelinePublication(
            new RaidEvidenceArtifactPublication(timeline.Sha256, timeline.ByteLength),
            timeline.ClockBases)),
        evidence.Runtime is null
            ? null
            : new RaidClientRuntimePublication(
                new RaidEvidenceArtifactPublication(
                    evidence.Runtime.Sha256,
                    evidence.Runtime.ByteLength),
                evidence.Runtime.LocalBuildLabel),
        evidence.Timing.ClockBases.Select(claim => new RaidClockEvidencePublication(
            claim.Basis,
            claim.Resolution,
            claim.EvidenceObjectSha256.Select(digest => artifacts[digest]),
            claim.ReasonCode)),
        new RaidSchedulerEvidencePublication(
            evidence.Timing.Scheduler.Resolution,
            evidence.Timing.Scheduler.RelatedClockBases,
            evidence.Timing.Scheduler.EvidenceObjectSha256.Select(digest => artifacts[digest]),
            evidence.Timing.Scheduler.ReasonCode),
        evidence.WarningCodes,
        Array.Empty<string>());
  }

  private static IReadOnlyDictionary<Sha256Digest, RaidEvidenceArtifactPublication> CreateArtifactLookup(
      ChallengeCompatibilityEvidence evidence)
  {
    var result = new Dictionary<Sha256Digest, RaidEvidenceArtifactPublication>();
    AddArtifact(result, evidence.Behavior);
    foreach (var timeline in evidence.Timelines)
    {
      AddArtifact(result, new ChallengeArtifactEvidence(timeline.Sha256, timeline.ByteLength));
    }

    foreach (var bundle in evidence.AssetBundles)
    {
      AddArtifact(result, new ChallengeArtifactEvidence(bundle.Sha256, bundle.ByteLength));
    }

    if (evidence.Runtime is { } runtime)
    {
      AddArtifact(result, new ChallengeArtifactEvidence(runtime.Sha256, runtime.ByteLength));
    }

    return result;
  }

  private static void AddArtifact(
      IDictionary<Sha256Digest, RaidEvidenceArtifactPublication> artifacts,
      ChallengeArtifactEvidence? artifact)
  {
    if (artifact is not null)
    {
      artifacts.Add(artifact.Sha256, Artifact(artifact));
    }
  }

  private static RaidEvidenceArtifactPublication Artifact(ChallengeArtifactEvidence artifact) =>
      new(artifact.Sha256, artifact.ByteLength);

  internal static SafeDiagnostic ToSafeDiagnostic(ChallengeRaidImportDiagnostic diagnostic) => new(
      ImportDiagnosticSeverity.Warning,
      "raid_catalog",
      diagnostic.Code,
      diagnostic.OccurrenceCount);

  private static RaidElement ParseElement(string value) => value switch
  {
    "fire" => RaidElement.Fire,
    "water" => RaidElement.Water,
    "wind" => RaidElement.Wind,
    "electric" => RaidElement.Electric,
    "iron" => RaidElement.Iron,
    _ => throw new RaidSnapshotIntegrityException("raid_element_invalid")
  };

  private static string TierCode(RaidCompatibilityTier value) => value switch
  {
    RaidCompatibilityTier.StaticExact => "static_exact",
    RaidCompatibilityTier.BehaviorExact => "behavior_exact",
    RaidCompatibilityTier.AssetExactRuntimeCurrent => "asset_exact_runtime_current",
    RaidCompatibilityTier.HistoricalRuntimeExact => "historical_runtime_exact",
    _ => throw new RaidSnapshotIntegrityException("raid_compatibility_tier_invalid")
  };

  private static RaidCatalogInput RequireInput(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    if (!options.TryGetValue("static-root", out var staticRoot) ||
        !options.TryGetValue("static-file", out var staticFile))
    {
      throw new LabConfigurationException("raid_catalog_source_option_missing");
    }

    var hasEvidenceRoot = options.TryGetValue("evidence-root", out var evidenceRoot);
    var hasEvidenceFile = options.TryGetValue("evidence-file", out var evidenceFile);
    if (hasEvidenceRoot != hasEvidenceFile)
    {
      throw new LabConfigurationException("raid_catalog_evidence_option_incomplete");
    }

    var staticSource = new ReadOnlySourceRoot(
        staticRoot,
        repositoryRoot,
        configuration.RuntimeRoot)
        .Bind(SourceRelativePath.Parse(staticFile), "staticdata_archive");
    IImportArtifactSource? evidenceSource = null;
    if (hasEvidenceRoot)
    {
      evidenceSource = new ReadOnlySourceRoot(
          evidenceRoot!,
          repositoryRoot,
          configuration.RuntimeRoot)
          .Bind(SourceRelativePath.Parse(evidenceFile!), "raid_evidence_archive");
    }

    return new RaidCatalogInput(staticSource, evidenceSource);
  }

  private sealed record RaidCatalogInput(
      IImportArtifactSource StaticDataSource,
      IImportArtifactSource? EvidenceSource);

  private sealed record RaidCatalogReadResult(
      ChallengeRaidCatalogExtraction Extraction,
      SourceArtifactObservation StaticDataObservation,
      SourceArtifactObservation? EvidenceArchiveObservation);

  private sealed record EvidenceObjectInput(
      string RoleCode,
      Sha256Digest Sha256,
      long ByteLength);
}
