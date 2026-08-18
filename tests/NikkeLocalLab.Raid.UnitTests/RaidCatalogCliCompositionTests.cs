using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.Raid.UnitTests;

public sealed class RaidCatalogCliCompositionTests
{
  [Fact]
  public void Synthetic_extraction_maps_six_supported_snapshots_and_all_safe_diagnostics()
  {
    using var archives = SyntheticChallengeRaidArchives.Create();
    var extraction = new StaticDataChallengeRaidCatalogReader().Read(
        archives.StaticData,
        archives.Compatibility);
    var staticObservation = new SourceArtifactObservation(
        "staticdata_archive",
        extraction.StaticDataArchiveSha256,
        archives.StaticData.Length);
    var evidenceObservation = new SourceArtifactObservation(
        "raid_evidence_archive",
        extraction.CompatibilityArchiveSha256!.Value,
        archives.Compatibility.Length);

    var datasetInputs = RaidCatalogCli.CreateDatasetInputs(
        extraction,
        staticObservation,
        evidenceObservation);
    var publication = RaidCatalogCli.ToPublication(extraction, staticObservation.ByteLength);

    Assert.Equal(SyntheticChallengeRaidArchives.SupportedSeasons, publication.Snapshots
        .Select(static snapshot => snapshot.SeasonNumber));
    Assert.Equal(6, publication.Snapshots.Count);
    AssertPublicationMatchesCandidates(extraction, publication);
    AssertPublicationArtifactsBelongToDataset(publication, datasetInputs);

    var safeDiagnostics = extraction.Diagnostics
        .Select(RaidCatalogCli.ToSafeDiagnostic)
        .ToArray();
    Assert.Equal(extraction.Diagnostics.Count, safeDiagnostics.Length);
    for (var index = 0; index < safeDiagnostics.Length; index++)
    {
      Assert.Equal(ImportDiagnosticSeverity.Warning, safeDiagnostics[index].Severity);
      Assert.Equal("raid_catalog", safeDiagnostics[index].StageCode);
      Assert.Equal(extraction.Diagnostics[index].Code, safeDiagnostics[index].DiagnosticCode);
      Assert.Equal(extraction.Diagnostics[index].OccurrenceCount, safeDiagnostics[index].OccurrenceCount);
    }

    Assert.Equal(
        extraction.Diagnostics.Select(static diagnostic => (
            diagnostic.Code,
            diagnostic.SeasonNumber,
            diagnostic.OccurrenceCount)),
        publication.Diagnostics.Select(static diagnostic => (
            diagnostic.DiagnosticCode,
            diagnostic.SeasonNumber,
            diagnostic.OccurrenceCount)));
  }

  [Fact]
  public void Runtime_exact_synthetic_evidence_preserves_every_typed_artifact_role()
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(
            S40Tier: RaidCompatibilityTier.AssetExactRuntimeCurrent));
    var extraction = new StaticDataChallengeRaidCatalogReader().Read(
        archives.StaticData,
        archives.Compatibility);
    var staticObservation = new SourceArtifactObservation(
        "staticdata_archive",
        extraction.StaticDataArchiveSha256,
        archives.StaticData.Length);
    var evidenceObservation = new SourceArtifactObservation(
        "raid_evidence_archive",
        extraction.CompatibilityArchiveSha256!.Value,
        archives.Compatibility.Length);

    var datasetInputs = RaidCatalogCli.CreateDatasetInputs(
        extraction,
        staticObservation,
        evidenceObservation);
    var publication = RaidCatalogCli.ToPublication(extraction, staticObservation.ByteLength);
    var season40 = publication.Snapshots.Single(static snapshot => snapshot.SeasonNumber == 40);

    Assert.Equal(RaidCompatibilityTier.AssetExactRuntimeCurrent, season40.CompatibilityTier);
    Assert.NotNull(season40.Behavior);
    Assert.NotNull(season40.ClientRuntime);
    Assert.NotEmpty(season40.SelectedAssetBundles);
    Assert.NotEmpty(season40.Timelines);
    Assert.Contains(datasetInputs, static input => input.RoleCode == "raid_evidence_behavior");
    Assert.Contains(datasetInputs, static input => input.RoleCode == "raid_evidence_bundle");
    Assert.Contains(datasetInputs, static input => input.RoleCode == "raid_evidence_timeline");
    Assert.Contains(datasetInputs, static input => input.RoleCode == "raid_evidence_runtime");
    AssertPublicationArtifactsBelongToDataset(publication, datasetInputs);
  }

  private static void AssertPublicationMatchesCandidates(
      ChallengeRaidCatalogExtraction extraction,
      RaidCatalogPublication publication)
  {
    foreach (var candidate in extraction.Candidates.Where(static candidate => candidate.CanPublish))
    {
      var snapshot = publication.Snapshots.Single(item => item.SeasonNumber == candidate.SeasonNumber);
      Assert.Equal(candidate.Evidence.Tier, snapshot.CompatibilityTier);
      Assert.Equal(candidate.Evidence.RuntimeRelation, snapshot.RuntimeRelation);
      Assert.Equal(candidate.Evidence.WarningCodes.Order(StringComparer.Ordinal), snapshot.EvidenceWarningCodes);
      Assert.Equal(candidate.Parts.Count, snapshot.Parts.Count);
      Assert.Equal(candidate.MonsterSkillRelationCount, snapshot.Skills.Count);

      for (var ordinal = 0; ordinal < candidate.Parts.Count; ordinal++)
      {
        var expected = candidate.Parts[ordinal];
        var actual = snapshot.Parts[ordinal];
        Assert.Equal(expected.Ordinal, actual.Ordinal);
        Assert.Equal(expected.TypeCode, actual.TypeCode);
        Assert.Equal(expected.LinkedPartOrdinal, actual.LinkedPartOrdinal);
      }

      Assert.Equal(
          Enumerable.Range(0, snapshot.Skills.Count),
          snapshot.Skills.Select(static skill => skill.Ordinal));
      Assert.All(snapshot.Skills, static skill => Assert.Equal("monster_skill_slot", skill.RoleCode));
    }

    Assert.All(
        publication.Snapshots.Where(static snapshot => snapshot.SeasonNumber != 40),
        static snapshot =>
        {
          Assert.Equal(RaidCompatibilityTier.StaticExact, snapshot.CompatibilityTier);
          Assert.Equal(["behavior_unresolved"], snapshot.EvidenceWarningCodes);
          Assert.Null(snapshot.Behavior);
          Assert.Empty(snapshot.SelectedAssetBundles);
        });
    var season40 = publication.Snapshots.Single(static snapshot => snapshot.SeasonNumber == 40);
    Assert.Equal(RaidCompatibilityTier.BehaviorExact, season40.CompatibilityTier);
    Assert.Equal(
        ["runtime_not_evaluated", "timeline_unresolved"],
        season40.EvidenceWarningCodes);
  }

  private static void AssertPublicationArtifactsBelongToDataset(
      RaidCatalogPublication publication,
      IReadOnlyList<DatasetArtifactInput> inputs)
  {
    foreach (var snapshot in publication.Snapshots)
    {
      AssertDatasetArtifact(inputs, "raid_staticdata", snapshot.StaticData);
      if (snapshot.Behavior is not null)
      {
        AssertDatasetArtifact(inputs, "raid_evidence_behavior", snapshot.Behavior);
      }

      foreach (var bundle in snapshot.SelectedAssetBundles)
      {
        AssertDatasetArtifact(inputs, "raid_evidence_bundle", bundle.Artifact);
      }

      foreach (var timeline in snapshot.Timelines)
      {
        AssertDatasetArtifact(inputs, "raid_evidence_timeline", timeline.Artifact);
      }

      if (snapshot.ClientRuntime is not null)
      {
        AssertDatasetArtifact(inputs, "raid_evidence_runtime", snapshot.ClientRuntime.Artifact);
      }

      foreach (var artifact in snapshot.ClockEvidence.SelectMany(static clock => clock.EvidenceArtifacts)
                   .Concat(snapshot.SchedulerEvidence.EvidenceArtifacts))
      {
        Assert.Contains(inputs, input =>
            input.Artifact.ContentSha256 == artifact.Sha256 &&
            input.Artifact.ByteLength == artifact.ByteLength &&
            input.RoleCode.StartsWith("raid_evidence_", StringComparison.Ordinal));
      }
    }
  }

  private static void AssertDatasetArtifact(
      IReadOnlyList<DatasetArtifactInput> inputs,
      string roleCode,
      RaidEvidenceArtifactPublication artifact)
  {
    var input = Assert.Single(inputs, input =>
        input.RoleCode == roleCode && input.Artifact.ContentSha256 == artifact.Sha256);
    Assert.Equal(artifact.ByteLength, input.Artifact.ByteLength);
    Assert.Equal(
        roleCode == "raid_staticdata" ? "staticdata_archive" : "raid_evidence_object",
        input.Artifact.ArtifactKind);
  }
}
