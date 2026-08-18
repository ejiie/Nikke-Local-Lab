using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.RaidCatalog;

public enum ChallengeCandidateReadiness
{
  Ready,
  Incomplete
}

public sealed record NormalizedRaidAffinity(string Element, string Weakness);

public sealed record NormalizedRaidPart(
    int Ordinal,
    string TypeCode,
    int DamageHpRatio,
    int HpRatio,
    int DefenceRatio,
    int EnergyResistRatio,
    int MetalResistRatio,
    int BioResistRatio,
    int AttackRatio,
    bool IsMainPart,
    bool IsDamageable,
    bool IsHpVisible,
    int? LinkedPartOrdinal)
{
  public bool HasLinkedPart => LinkedPartOrdinal.HasValue;
}

public sealed record ChallengeArtifactEvidence(
    Sha256Digest Sha256,
    long ByteLength);

public sealed record ChallengeTimelineEvidence(
    Sha256Digest Sha256,
    long ByteLength,
    IReadOnlyList<ClockBasis> ClockBases);

public sealed record ChallengeAssetBundleEvidence(
    Sha256Digest Sha256,
    long ByteLength,
    IReadOnlyList<AssetBundleRole> Roles);

public sealed record ChallengeRuntimeArtifactEvidence(
    Sha256Digest Sha256,
    long ByteLength,
    string LocalBuildLabel);

public sealed record ChallengeClockBasisClaim(
    ClockBasis Basis,
    TimingEvidenceResolution Resolution,
    IReadOnlyList<Sha256Digest> EvidenceObjectSha256,
    string? ReasonCode);

public sealed record ChallengeSchedulerClaim(
    TimingEvidenceResolution Resolution,
    IReadOnlyList<ClockBasis> RelatedClockBases,
    IReadOnlyList<Sha256Digest> EvidenceObjectSha256,
    string? ReasonCode);

public sealed record ChallengeTimingClaims(
    IReadOnlyList<ChallengeClockBasisClaim> ClockBases,
    ChallengeSchedulerClaim Scheduler)
{
  internal bool IsValid(IReadOnlySet<Sha256Digest> rowObjectDigests)
  {
    if (ClockBases is null || Scheduler is null)
    {
      return false;
    }

    var expected = Enum.GetValues<ClockBasis>();
    if (ClockBases.Count != expected.Length ||
        ClockBases.Any(static claim => claim is null) ||
        ClockBases.GroupBy(static claim => claim.Basis).Any(static group => group.Count() != 1) ||
        expected.Any(basis => ClockBases.All(claim => claim.Basis != basis)) ||
        ClockBases.Any(claim => !ClaimIsValid(
            claim.Resolution,
            claim.EvidenceObjectSha256,
            claim.ReasonCode,
            rowObjectDigests)))
    {
      return false;
    }

    if (Scheduler.RelatedClockBases is null ||
        Scheduler.RelatedClockBases.Count < 2 ||
        Scheduler.RelatedClockBases.Distinct().Count() != Scheduler.RelatedClockBases.Count ||
        Scheduler.RelatedClockBases.Any(static basis => !Enum.IsDefined(basis)) ||
        !ClaimIsValid(
            Scheduler.Resolution,
            Scheduler.EvidenceObjectSha256,
            Scheduler.ReasonCode,
            rowObjectDigests))
    {
      return false;
    }

    return true;
  }

  internal bool IsRuntimeExact(IReadOnlyList<ChallengeTimelineEvidence> timelines)
  {
    if (Scheduler.Resolution == TimingEvidenceResolution.Unresolved)
    {
      return false;
    }

    var related = Scheduler.RelatedClockBases.ToHashSet();
    if (timelines.SelectMany(static timeline => timeline.ClockBases).Any(basis => !related.Contains(basis)))
    {
      return false;
    }

    return related.All(basis =>
        ClockBases.Single(claim => claim.Basis == basis).Resolution != TimingEvidenceResolution.Unresolved);
  }

  private static bool ClaimIsValid(
      TimingEvidenceResolution resolution,
      IReadOnlyList<Sha256Digest>? evidence,
      string? reasonCode,
      IReadOnlySet<Sha256Digest> rowObjectDigests)
  {
    if (!Enum.IsDefined(resolution) || evidence is null ||
        evidence.Distinct().Count() != evidence.Count ||
        evidence.Any(digest => digest == default || !rowObjectDigests.Contains(digest)))
    {
      return false;
    }

    if (resolution == TimingEvidenceResolution.Unresolved)
    {
      return evidence.Count == 0 && IsControlledCode(reasonCode);
    }

    return evidence.Count > 0 && reasonCode is null;
  }

  private static bool IsControlledCode(string? value)
  {
    try
    {
      _ = ControlledCode.Require(value, nameof(value));
      return true;
    }
    catch (ArgumentException)
    {
      return false;
    }
  }
}

public sealed record ChallengeCompatibilityEvidence(
    Sha256Digest StaticDataArchiveSha256,
    RaidCompatibilityTier Tier,
    RuntimeRelation RuntimeRelation,
    ChallengeArtifactEvidence? Behavior,
    IReadOnlyList<ChallengeTimelineEvidence> Timelines,
    IReadOnlyList<ChallengeAssetBundleEvidence> AssetBundles,
    ChallengeRuntimeArtifactEvidence? Runtime,
    ChallengeTimingClaims Timing,
    IReadOnlyList<string> WarningCodes)
{
  public Sha256Digest? AssetBundleSetSha256 =>
      AssetBundles is { Count: > 0 }
          ? ComputeDigestSet(AssetBundles.Select(static bundle => bundle.Sha256))
          : null;

  public bool IsValid
  {
    get
    {
      if (StaticDataArchiveSha256 == default || !Enum.IsDefined(Tier) || !Enum.IsDefined(RuntimeRelation) ||
          Timelines is null || AssetBundles is null || Timing is null || WarningCodes is null ||
          WarningCodes.Distinct(StringComparer.Ordinal).Count() != WarningCodes.Count ||
          WarningCodes.Any(static warning => !IsControlledCode(warning)) ||
          !ArtifactIsValid(Behavior) ||
          Timelines.Any(static timeline => timeline is null || timeline.Sha256 == default ||
              timeline.ByteLength <= 0 || timeline.ClockBases is null || timeline.ClockBases.Count == 0 ||
              timeline.ClockBases.Distinct().Count() != timeline.ClockBases.Count ||
              timeline.ClockBases.Any(static basis => !Enum.IsDefined(basis))) ||
          AssetBundles.Any(static bundle => bundle is null || bundle.Sha256 == default ||
              bundle.ByteLength <= 0 || bundle.Roles is null || bundle.Roles.Count == 0 ||
              bundle.Roles.Distinct().Count() != bundle.Roles.Count ||
              bundle.Roles.Any(static role => !Enum.IsDefined(role))) ||
          (Runtime is not null && (Runtime.Sha256 == default || Runtime.ByteLength <= 0 ||
                                   !IsControlledCode(Runtime.LocalBuildLabel))))
      {
        return false;
      }

      var typedArtifacts = new List<(Sha256Digest Digest, string Kind)>();
      if (Behavior is not null)
      {
        typedArtifacts.Add((Behavior.Sha256, "behavior"));
      }

      typedArtifacts.AddRange(Timelines.Select(static timeline => (timeline.Sha256, "timeline")));
      typedArtifacts.AddRange(AssetBundles.Select(static bundle => (bundle.Sha256, "bundle")));
      if (Runtime is not null)
      {
        typedArtifacts.Add((Runtime.Sha256, "runtime"));
      }

      if (typedArtifacts.GroupBy(static artifact => artifact.Digest)
          .Any(static group => group.Count() != 1))
      {
        return false;
      }

      var rowDigests = typedArtifacts.Select(static artifact => artifact.Digest).ToHashSet();
      if (!Timing.IsValid(rowDigests) ||
          (Timelines.Count > 0 && Behavior is null) ||
          (Runtime is not null && Behavior is null) ||
          (RuntimeRelation != RuntimeRelation.NotEvaluated && Runtime is null))
      {
        return false;
      }

      return Tier switch
      {
        RaidCompatibilityTier.StaticExact =>
            WarningCodes.Contains("behavior_unresolved", StringComparer.Ordinal),
        RaidCompatibilityTier.BehaviorExact =>
            Behavior is not null && AssetBundles.Count > 0,
        RaidCompatibilityTier.AssetExactRuntimeCurrent =>
            Behavior is not null && AssetBundles.Count > 0 && Runtime is not null &&
            RuntimeRelation == RuntimeRelation.CurrentRuntimeMatch && Timing.IsRuntimeExact(Timelines),
        RaidCompatibilityTier.HistoricalRuntimeExact =>
            Behavior is not null && AssetBundles.Count > 0 && Runtime is not null &&
            RuntimeRelation == RuntimeRelation.HistoricalRuntimeMatch && Timing.IsRuntimeExact(Timelines),
        _ => false
      };
    }
  }

  public static ChallengeCompatibilityEvidence StaticExact(
      Sha256Digest staticDataArchiveSha256,
      string warningCode = "behavior_unresolved") =>
      new(
          staticDataArchiveSha256,
          RaidCompatibilityTier.StaticExact,
          RuntimeRelation.NotEvaluated,
          null,
          Array.Empty<ChallengeTimelineEvidence>(),
          Array.Empty<ChallengeAssetBundleEvidence>(),
          null,
          UnresolvedTiming(),
          Array.AsReadOnly(new[] { ControlledCode.Require(warningCode, nameof(warningCode)) }));

  private static bool ArtifactIsValid(ChallengeArtifactEvidence? artifact) =>
      artifact is null || (artifact.Sha256 != default && artifact.ByteLength > 0);

  private static ChallengeTimingClaims UnresolvedTiming()
  {
    var clocks = Enum.GetValues<ClockBasis>()
        .Select(static basis => new ChallengeClockBasisClaim(
            basis,
            TimingEvidenceResolution.Unresolved,
            Array.Empty<Sha256Digest>(),
            "not_evaluated"))
        .ToArray();
    return new ChallengeTimingClaims(
        Array.AsReadOnly(clocks),
        new ChallengeSchedulerClaim(
            TimingEvidenceResolution.Unresolved,
            Array.AsReadOnly(Enum.GetValues<ClockBasis>()),
            Array.Empty<Sha256Digest>(),
            "not_evaluated"));
  }

  private static Sha256Digest ComputeDigestSet(IEnumerable<Sha256Digest> digests) =>
      Sha256Digest.ComputeUtf8(string.Join(
          '\n',
          digests.Select(static digest => digest.ToString())
              .Distinct(StringComparer.Ordinal)
              .OrderBy(static digest => digest, StringComparer.Ordinal)));

  private static bool IsControlledCode(string? value)
  {
    try
    {
      _ = ControlledCode.Require(value, nameof(value));
      return true;
    }
    catch (ArgumentException)
    {
      return false;
    }
  }
}

public sealed record NormalizedChallengeRaidCandidate(
    int SeasonNumber,
    string AdmissionRuleCode,
    NormalizedRaidAffinity? Affinity,
    IReadOnlyList<NormalizedRaidPart> Parts,
    bool HasClosedPartTopology,
    int SpotBehaviorVariantCount,
    int? MonsterSkillRelationCount,
    ChallengeCompatibilityEvidence Evidence)
{
  public ChallengeCandidateReadiness Readiness => HasValidStaticFacts() && Evidence.IsValid
      ? ChallengeCandidateReadiness.Ready
      : ChallengeCandidateReadiness.Incomplete;

  public bool CanPublish => Readiness == ChallengeCandidateReadiness.Ready;

  private bool HasValidStaticFacts()
  {
    if (SeasonNumber <= 0 ||
        AdmissionRuleCode is not ("electric_weak_to_iron" or "season_40_explicit") ||
        Affinity is null || Parts is null || Evidence is null ||
        SpotBehaviorVariantCount != 1 ||
        !MonsterSkillRelationCount.HasValue || MonsterSkillRelationCount.Value < 0 ||
        !HasClosedPartTopology)
    {
      return false;
    }

    var ordinals = Parts.Select(static part => part.Ordinal).ToArray();
    return ordinals.Distinct().Count() == ordinals.Length &&
           ordinals.Order().SequenceEqual(Enumerable.Range(0, Parts.Count)) &&
           Parts.All(part => !part.LinkedPartOrdinal.HasValue ||
               (part.LinkedPartOrdinal.Value >= 0 &&
                part.LinkedPartOrdinal.Value < Parts.Count &&
                part.LinkedPartOrdinal.Value != part.Ordinal)) &&
           Parts.All(static part => !string.Equals(
               part.TypeCode,
               "unresolved",
               StringComparison.Ordinal));
  }
}

public sealed record ChallengeRaidImportDiagnostic(
    string Code,
    int? SeasonNumber,
    int OccurrenceCount);

public sealed record ChallengeRaidCatalogExtraction(
    IReadOnlyList<NormalizedChallengeRaidCandidate> Candidates,
    IReadOnlyList<ChallengeRaidImportDiagnostic> Diagnostics,
    Sha256Digest StaticDataArchiveSha256,
    Sha256Digest? CompatibilityArchiveSha256,
    Sha256Digest CanonicalCandidateSha256)
{
  public int PublishableCandidateCount => Candidates.Count(candidate => candidate.CanPublish);
}

public sealed class ChallengeRaidCatalogSourceException : Exception
{
  public ChallengeRaidCatalogSourceException(string code)
      : base("The Challenge raid catalog source failed a controlled validation.")
  {
    Code = ControlledCode.Require(code, nameof(code));
  }

  public string Code { get; }
}
