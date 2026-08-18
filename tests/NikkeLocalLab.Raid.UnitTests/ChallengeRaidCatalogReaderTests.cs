namespace NikkeLocalLab.Raid.UnitTests;

public sealed class ChallengeRaidCatalogReaderTests
{
  [Fact]
  public void OneStaticArchivePublishesFiveStaticExactAndOneBehaviorExactCandidate()
  {
    using var archives = SyntheticChallengeRaidArchives.Create();

    var extraction = Read(archives);

    Assert.Equal(SyntheticChallengeRaidArchives.SupportedSeasons, extraction.Candidates.Select(static row => row.SeasonNumber));
    Assert.Equal(6, extraction.PublishableCandidateCount);
    Assert.All(extraction.Candidates, candidate =>
    {
      Assert.True(candidate.CanPublish);
      Assert.Equal(ChallengeCandidateReadiness.Ready, candidate.Readiness);
      Assert.Equal(extraction.StaticDataArchiveSha256, candidate.Evidence.StaticDataArchiveSha256);
      Assert.True(candidate.Evidence.IsValid);
      Assert.Equal(2, candidate.Parts.Count);
      Assert.True(candidate.HasClosedPartTopology);
      var root = Assert.Single(candidate.Parts, static part => part.LinkedPartOrdinal is null);
      var dependent = Assert.Single(candidate.Parts, static part => part.LinkedPartOrdinal.HasValue);
      Assert.Equal(root.Ordinal, dependent.LinkedPartOrdinal);
      Assert.DoesNotContain(
          candidate.Parts,
          static part => part.TypeCode.StartsWith("part-category-", StringComparison.Ordinal));
      Assert.Equal(
          ["arm-left", "arm-right"],
          candidate.Parts.Select(static part => part.TypeCode).Order(StringComparer.Ordinal));
      Assert.Equal(3, candidate.MonsterSkillRelationCount);
      Assert.Equal(1, candidate.SpotBehaviorVariantCount);
    });

    Assert.All(
        extraction.Candidates.Where(static row => row.SeasonNumber != 40),
        static candidate =>
        {
          Assert.Equal(RaidCompatibilityTier.StaticExact, candidate.Evidence.Tier);
          Assert.Contains("behavior_unresolved", candidate.Evidence.WarningCodes);
          Assert.Null(candidate.Evidence.Behavior);
          Assert.Empty(candidate.Evidence.AssetBundles);
        });

    var season40 = extraction.Candidates.Single(static row => row.SeasonNumber == 40);
    Assert.Equal(RaidCompatibilityTier.BehaviorExact, season40.Evidence.Tier);
    Assert.NotNull(season40.Evidence.Behavior);
    Assert.Equal(2, season40.Evidence.AssetBundles.Count);
    Assert.Contains(season40.Evidence.AssetBundles, static bundle => bundle.Roles.Contains(AssetBundleRole.Behavior));
    Assert.Contains("timeline_unresolved", season40.Evidence.WarningCodes);
    Assert.Contains("runtime_not_evaluated", season40.Evidence.WarningCodes);
    Assert.Empty(season40.Evidence.Timelines);
    Assert.Null(season40.Evidence.Runtime);
    Assert.Equal("wind", season40.Affinity!.Element);
    Assert.Equal("fire", season40.Affinity.Weakness);
  }

  [Fact]
  public void CanonicalCandidateHashIgnoresCompatibilityZipOrderButBindsExactStaticBytes()
  {
    using var firstArchives = SyntheticChallengeRaidArchives.Create();
    using var reorderedCompatibility = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(ReverseCompatibilityEntries: true));
    using var reorderedStatic = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(ReverseStaticEntries: true));
    var first = Read(firstArchives);
    var second = Read(reorderedCompatibility);
    var third = Read(reorderedStatic);

    Assert.Equal(first.StaticDataArchiveSha256, second.StaticDataArchiveSha256);
    Assert.Equal(first.CanonicalCandidateSha256, second.CanonicalCandidateSha256);
    Assert.NotEqual(first.CompatibilityArchiveSha256, second.CompatibilityArchiveSha256);
    Assert.NotEqual(first.StaticDataArchiveSha256, third.StaticDataArchiveSha256);
    Assert.NotEqual(first.CanonicalCandidateSha256, third.CanonicalCandidateSha256);

    var canonical = ChallengeRaidCandidateCanonicalizer.ToCanonicalText(first.Candidates);
    Assert.DoesNotContain("9000007", canonical, StringComparison.Ordinal);
    Assert.DoesNotContain("bt_synthetic", canonical, StringComparison.Ordinal);
    Assert.DoesNotContain("WaveDataTable", canonical, StringComparison.Ordinal);
  }

  [Fact]
  public void MissingBehaviorEvidenceFallsBackToPublishableStaticExact()
  {
    using var archives = SyntheticChallengeRaidArchives.Create();

    var extraction = new StaticDataChallengeRaidCatalogReader().Read(archives.StaticData);

    Assert.Equal(6, extraction.PublishableCandidateCount);
    Assert.Null(extraction.CompatibilityArchiveSha256);
    Assert.All(extraction.Candidates, static candidate =>
    {
      Assert.Equal(RaidCompatibilityTier.StaticExact, candidate.Evidence.Tier);
      Assert.Contains("behavior_unresolved", candidate.Evidence.WarningCodes);
    });
  }

  [Fact]
  public void StaticBindingMismatchIsUnmatchedEvidenceAndFallsBackToStaticExact()
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(StaticBindingMismatchSeason: 40));

    var extraction = Read(archives);
    var season40 = Assert.Single(extraction.Candidates, static row => row.SeasonNumber == 40);

    Assert.True(season40.CanPublish);
    Assert.Equal(RaidCompatibilityTier.StaticExact, season40.Evidence.Tier);
    Assert.Equal(extraction.StaticDataArchiveSha256, season40.Evidence.StaticDataArchiveSha256);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "compatibility_static_binding_mismatch" && row.SeasonNumber == 40);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "compatibility_evidence_unmatched" && row.SeasonNumber == 40);
  }

  [Fact]
  public void UnknownElementRowsOnlyMakeReferencingCandidateUnresolved()
  {
    using var unrelated = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(AddUnknownElementRow: true));
    using var referenced = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(UnknownElementSeason: 34));

    Assert.Equal(6, Read(unrelated).PublishableCandidateCount);
    var extraction = Read(referenced);
    var season34 = Assert.Single(extraction.Candidates, static row => row.SeasonNumber == 34);
    Assert.False(season34.CanPublish);
    Assert.Null(season34.Affinity);
    Assert.Equal(5, extraction.PublishableCandidateCount);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "affinity_unresolved" && row.SeasonNumber == 34);
  }

  [Fact]
  public void BrokenLinkedPartTopologyIsRetainedAsAnIncompleteNormalizedFact()
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(BrokenLinkedPartSeason: 29));

    var extraction = Read(archives);
    var season29 = Assert.Single(extraction.Candidates, static row => row.SeasonNumber == 29);

    Assert.False(season29.HasClosedPartTopology);
    Assert.False(season29.CanPublish);
    Assert.Equal(5, extraction.PublishableCandidateCount);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "part_topology_unresolved" && row.SeasonNumber == 29);
  }

  [Fact]
  public void UnknownPartTypeIsControlledUnresolvedAndCannotPublish()
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(UnknownPartTypeSeason: 34));

    var extraction = Read(archives);
    var season34 = Assert.Single(extraction.Candidates, static row => row.SeasonNumber == 34);

    Assert.True(season34.HasClosedPartTopology);
    Assert.False(season34.CanPublish);
    Assert.Contains(season34.Parts, static part => part.TypeCode == "unresolved");
    Assert.DoesNotContain(
        season34.Parts,
        static part => part.TypeCode.Contains("999", StringComparison.Ordinal));
    Assert.Equal(5, extraction.PublishableCandidateCount);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "part_type_unresolved" && row.SeasonNumber == 34);
  }

  [Fact]
  public void AmbiguousBossIntersectionCannotPublish()
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(AmbiguousBossSeason: 7));

    var extraction = Read(archives);

    Assert.DoesNotContain(extraction.Candidates, static row => row.SeasonNumber == 7);
    Assert.Equal(5, extraction.PublishableCandidateCount);
    Assert.Contains(extraction.Diagnostics, static row =>
        row.Code == "authoritative_challenge_chain_unresolved" && row.SeasonNumber == 7);
  }

  [Theory]
  [InlineData(RaidCompatibilityTier.AssetExactRuntimeCurrent, RuntimeRelation.CurrentRuntimeMatch)]
  [InlineData(RaidCompatibilityTier.HistoricalRuntimeExact, RuntimeRelation.HistoricalRuntimeMatch)]
  public void RuntimeExactPackagesRequireAndPreserveTypedRuntimeTiming(
      RaidCompatibilityTier tier,
      RuntimeRelation relation)
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(S40Tier: tier));

    var season40 = Assert.Single(Read(archives).Candidates, static row => row.SeasonNumber == 40);

    Assert.True(season40.CanPublish);
    Assert.Equal(tier, season40.Evidence.Tier);
    Assert.Equal(relation, season40.Evidence.RuntimeRelation);
    Assert.NotNull(season40.Evidence.Runtime);
    Assert.NotEmpty(season40.Evidence.Timelines);
    Assert.NotEqual(TimingEvidenceResolution.Unresolved, season40.Evidence.Timing.Scheduler.Resolution);
  }

  [Theory]
  [InlineData(SyntheticEvidenceMutation.OldV1Shape, "memorypack_schema_mismatch")]
  [InlineData(SyntheticEvidenceMutation.BehaviorTierWithoutBehavior, "compatibility_evidence_invariant_invalid")]
  [InlineData(SyntheticEvidenceMutation.RuntimeTierWithoutRuntime, "compatibility_evidence_invariant_invalid")]
  [InlineData(SyntheticEvidenceMutation.RuntimeRelationMismatch, "compatibility_evidence_invariant_invalid")]
  [InlineData(SyntheticEvidenceMutation.ObjectLengthMismatch, "compatibility_object_length_invalid")]
  [InlineData(SyntheticEvidenceMutation.ObjectRoleMismatch, "compatibility_object_role_invalid")]
  [InlineData(SyntheticEvidenceMutation.UnreferencedObject, "compatibility_object_unreferenced")]
  [InlineData(SyntheticEvidenceMutation.DuplicateBundleReference, "compatibility_object_duplicate")]
  public void V2RejectsOldShapeInvalidTierAndObjectIntegrityViolations(
      SyntheticEvidenceMutation mutation,
      string expectedCode)
  {
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(EvidenceMutation: mutation));

    var exception = Assert.Throws<ChallengeRaidCatalogSourceException>(() => Read(archives));

    Assert.Equal(expectedCode, exception.Code);
  }

  [Fact]
  public void ControlledFailureDoesNotEchoALocalLabelOrPath()
  {
    const string sensitiveLookingValue = "C:/private/raw/999999";
    using var archives = SyntheticChallengeRaidArchives.Create(
        new SyntheticRaidArchiveOptions(EvidenceMutation: SyntheticEvidenceMutation.InvalidLocalBuildLabel));

    var exception = Assert.Throws<ChallengeRaidCatalogSourceException>(() => Read(archives));

    Assert.Equal("compatibility_runtime_invalid", exception.Code);
    Assert.DoesNotContain(sensitiveLookingValue, exception.Message, StringComparison.Ordinal);
    Assert.Equal("The Challenge raid catalog source failed a controlled validation.", exception.Message);
  }

  [Fact]
  public void RetainedAug13InputsCanBuildS40BehaviorEvidenceInMemoryWhenConfigured()
  {
    var paths = new[]
    {
      EnvironmentValue("NLL_RETAINED_STATICDATA_SMOKE", "STATIC"),
      EnvironmentValue("NLL_S40_BEHAVIOR_JSON", "S40_BEHAVIOR_JSON"),
      EnvironmentValue("NLL_S40_BEHAVIOR_BUNDLE", "S40_BEHAVIOR_BUNDLE"),
      EnvironmentValue("NLL_S40_SPOT_BUNDLE", "S40_SPOT_BUNDLE")
    };
    if (paths.All(string.IsNullOrWhiteSpace))
    {
      return;
    }

    Assert.All(paths, static path => Assert.False(string.IsNullOrWhiteSpace(path)));
    using var staticData = File.OpenRead(paths[0]!);
    using var behavior = File.OpenRead(paths[1]!);
    using var behaviorBundle = File.OpenRead(paths[2]!);
    using var spotBundle = File.OpenRead(paths[3]!);
    using var compatibility = SyntheticChallengeRaidArchives.CreateBehaviorExactCompatibility(
        staticData,
        behavior,
        behaviorBundle,
        spotBundle);

    var extraction = new StaticDataChallengeRaidCatalogReader().Read(staticData, compatibility);

    Assert.Equal(SyntheticChallengeRaidArchives.SupportedSeasons, extraction.Candidates.Select(static row => row.SeasonNumber));
    Assert.Equal(6, extraction.PublishableCandidateCount);
    Assert.Equal(
        RaidCompatibilityTier.BehaviorExact,
        extraction.Candidates.Single(static row => row.SeasonNumber == 40).Evidence.Tier);
    Assert.All(
        extraction.Candidates.Where(static row => row.SeasonNumber != 40),
        static row => Assert.Equal(RaidCompatibilityTier.StaticExact, row.Evidence.Tier));
  }

  private static ChallengeRaidCatalogExtraction Read(SyntheticRaidArchives archives) =>
      new StaticDataChallengeRaidCatalogReader().Read(archives.StaticData, archives.Compatibility);

  private static string? EnvironmentValue(string preferred, string fallback) =>
      Environment.GetEnvironmentVariable(preferred) ?? Environment.GetEnvironmentVariable(fallback);
}
