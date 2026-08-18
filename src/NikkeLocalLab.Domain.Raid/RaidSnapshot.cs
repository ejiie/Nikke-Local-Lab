using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

public enum RaidCompatibilityTier
{
  StaticExact,
  BehaviorExact,
  AssetExactRuntimeCurrent,
  HistoricalRuntimeExact,
}

public enum RuntimeRelation
{
  NotEvaluated,
  CurrentRuntimeMatch,
  HistoricalRuntimeMatch,
}

public sealed class ClientRuntimeReference
{
  private ClientRuntimeReference(
      EntityUid? buildUid,
      string? localBuildLabel,
      Sha256Digest? sha256)
  {
    BuildUid = buildUid;
    LocalBuildLabel = localBuildLabel;
    Sha256 = sha256;
  }

  public EntityUid? BuildUid { get; }

  public string? LocalBuildLabel { get; }

  public Sha256Digest? Sha256 { get; }

  public bool IsResolved => BuildUid.HasValue;

  public static ClientRuntimeReference Unresolved() => new(null, null, null);

  public static ClientRuntimeReference Resolved(
      EntityUid buildUid,
      string localBuildLabel,
      Sha256Digest sha256) =>
      new(
          RaidDomainGuard.RequireUid(buildUid, nameof(buildUid)),
          ControlledCode.Require(localBuildLabel, nameof(localBuildLabel)),
          RaidDomainGuard.RequireDigest(sha256, nameof(sha256)));
}

public sealed class RaidSnapshotProvenance
{
  public RaidSnapshotProvenance(
      RaidArtifactReference staticData,
      IEnumerable<SelectedAssetBundle> selectedAssetBundles,
      RaidArtifactReference? behavior,
      IEnumerable<TimelineArtifactReference> timelines,
      ClientRuntimeReference clientRuntime,
      TimingProvenance timing)
  {
    StaticData = staticData ?? throw new ArgumentNullException(nameof(staticData));
    Behavior = behavior;
    ClientRuntime = clientRuntime ?? throw new ArgumentNullException(nameof(clientRuntime));
    Timing = timing ?? throw new ArgumentNullException(nameof(timing));

    ArgumentNullException.ThrowIfNull(selectedAssetBundles);
    var bundles = selectedAssetBundles
        .Select(static bundle => bundle ??
            throw new ArgumentException("Selected bundles cannot contain null entries.", nameof(selectedAssetBundles)))
        .ToArray();
    if (bundles.GroupBy(static bundle => bundle.ArtifactUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Selected bundles must contain unique artifact UIDs.",
          nameof(selectedAssetBundles));
    }

    SelectedAssetBundles = Array.AsReadOnly(bundles
        .OrderBy(static bundle => bundle.ArtifactUid.ToString(), StringComparer.Ordinal)
        .ToArray());
    AssetBundleSetSha256 = SelectedAssetBundles.Count == 0
        ? null
        : AssetBundleSetCanonicalizer.ComputeHash(SelectedAssetBundles);

    ArgumentNullException.ThrowIfNull(timelines);
    var timelineArray = timelines
        .Select(static timeline => timeline ??
            throw new ArgumentException("Timelines cannot contain null entries.", nameof(timelines)))
        .ToArray();
    if (timelineArray.GroupBy(static timeline => timeline.Artifact.ArtifactUid)
            .Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Timelines must contain unique artifact UIDs.",
          nameof(timelines));
    }

    Timelines = Array.AsReadOnly(timelineArray
        .OrderBy(static timeline => timeline.Artifact.ArtifactUid.ToString(), StringComparer.Ordinal)
        .ToArray());

    var timelineBases = Timelines
        .SelectMany(static timeline => timeline.ClockBases)
        .Distinct()
        .ToArray();
    foreach (var basis in timelineBases)
    {
      _ = Timing.Get(basis);
    }
  }

  public RaidArtifactReference StaticData { get; }

  public IReadOnlyList<SelectedAssetBundle> SelectedAssetBundles { get; }

  public Sha256Digest? AssetBundleSetSha256 { get; }

  public RaidArtifactReference? Behavior { get; }

  public IReadOnlyList<TimelineArtifactReference> Timelines { get; }

  public ClientRuntimeReference ClientRuntime { get; }

  public TimingProvenance Timing { get; }
}

public sealed class RaidCompatibility
{
  public RaidCompatibility(
      RaidCompatibilityTier tier,
      RuntimeRelation runtimeRelation,
      IEnumerable<string>? evidenceWarningCodes = null)
  {
    Tier = tier;
    RuntimeRelation = runtimeRelation;
    EvidenceWarningCodes = RaidDomainGuard.NormalizeCodes(
        evidenceWarningCodes,
        nameof(evidenceWarningCodes));
  }

  public RaidCompatibilityTier Tier { get; }

  public RuntimeRelation RuntimeRelation { get; }

  public IReadOnlyList<string> EvidenceWarningCodes { get; }

  internal void Validate(RaidSnapshotProvenance provenance)
  {
    ArgumentNullException.ThrowIfNull(provenance);

    if (RuntimeRelation != RuntimeRelation.NotEvaluated && !provenance.ClientRuntime.IsResolved)
    {
      throw new ArgumentException(
          "An evaluated runtime relation requires complete client runtime evidence.",
          nameof(provenance));
    }

    if (Tier == RaidCompatibilityTier.StaticExact)
    {
      if (EvidenceWarningCodes.Count == 0)
      {
        throw new ArgumentException(
            "Static-only compatibility must disclose unresolved higher-tier evidence.",
            nameof(provenance));
      }
    }
    else if (Tier == RaidCompatibilityTier.BehaviorExact)
    {
      RequireBehaviorEvidence(provenance);
    }
    else if (Tier == RaidCompatibilityTier.AssetExactRuntimeCurrent)
    {
      RequireRuntimeExactEvidence(provenance, RuntimeRelation.CurrentRuntimeMatch);
    }
    else if (Tier == RaidCompatibilityTier.HistoricalRuntimeExact)
    {
      RequireRuntimeExactEvidence(provenance, RuntimeRelation.HistoricalRuntimeMatch);
    }
  }

  private void RequireRuntimeExactEvidence(
      RaidSnapshotProvenance provenance,
      RuntimeRelation requiredRelation)
  {
    RequireBehaviorEvidence(provenance);
    if (RuntimeRelation != requiredRelation || !provenance.ClientRuntime.IsResolved)
    {
      throw new ArgumentException(
          "The selected compatibility tier requires matching runtime evidence.",
          nameof(provenance));
    }

    var scheduler = provenance.Timing.Scheduler;
    if (!scheduler.IsResolved)
    {
      throw new ArgumentException(
          "Runtime-exact compatibility requires resolved scheduler evidence.",
          nameof(provenance));
    }

    var timelineBases = provenance.Timelines
        .SelectMany(static timeline => timeline.ClockBases)
        .Distinct()
        .ToArray();
    if (timelineBases.Any(basis => !scheduler.RelatedClockBases.Contains(basis)) ||
        scheduler.RelatedClockBases.Any(basis =>
            provenance.Timing.Get(basis).Resolution == TimingEvidenceResolution.Unresolved))
    {
      throw new ArgumentException(
          "Runtime-exact compatibility requires clock-basis evidence for every scheduler relation.",
          nameof(provenance));
    }
  }

  private static void RequireBehaviorEvidence(RaidSnapshotProvenance provenance)
  {
    if (provenance.Behavior is null ||
        provenance.SelectedAssetBundles.Count == 0 ||
        !provenance.AssetBundleSetSha256.HasValue)
    {
      throw new ArgumentException(
          "Behavior-exact compatibility requires behavior and selected bundle evidence.",
          nameof(provenance));
    }
  }
}

public sealed class RaidSnapshot
{
  public const int SchemaVersion = 2;
  public const string Mode = "challenge";
  public const int ChallengeDifficultyType = 2;
  public const int ChallengeWaveOrder = 8;

  private RaidSnapshot(
      EntityUid raidSnapshotUid,
      EntityUid datasetSnapshotUid,
      EntityUid challengeEncounterUid,
      EntityUid bossVariantUid,
      EntityUid compatibilityMapUid,
      int seasonNumber,
      ChallengeAdmissionDecision admission,
      RaidStaticRelations staticRelations,
      RaidSnapshotProvenance provenance,
      RaidCompatibility compatibility,
      IReadOnlyList<string> readinessWarningCodes)
  {
    RaidSnapshotUid = raidSnapshotUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    ChallengeEncounterUid = challengeEncounterUid;
    BossVariantUid = bossVariantUid;
    CompatibilityMapUid = compatibilityMapUid;
    SeasonNumber = seasonNumber;
    Admission = admission;
    StaticRelations = staticRelations;
    Provenance = provenance;
    Compatibility = compatibility;
    ReadinessWarningCodes = readinessWarningCodes;
    ContentSha256 = RaidSnapshotCanonicalizer.ComputeContentHash(this);
  }

  public EntityUid RaidSnapshotUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public EntityUid ChallengeEncounterUid { get; }

  public EntityUid BossVariantUid { get; }

  public EntityUid CompatibilityMapUid { get; }

  public int SeasonNumber { get; }

  public ChallengeAdmissionDecision Admission { get; }

  public RaidStaticRelations StaticRelations { get; }

  public RaidSnapshotProvenance Provenance { get; }

  public RaidCompatibility Compatibility { get; }

  public string ReadinessStatus => "ready";

  public IReadOnlyList<string> ReadinessWarningCodes { get; }

  public Sha256Digest ContentSha256 { get; }

  public static RaidSnapshot Publish(
      EntityUid raidSnapshotUid,
      EntityUid datasetSnapshotUid,
      EntityUid challengeEncounterUid,
      EntityUid bossVariantUid,
      EntityUid compatibilityMapUid,
      int seasonNumber,
      ChallengeAdmissionDecision admission,
      RaidStaticRelations staticRelations,
      RaidSnapshotProvenance provenance,
      RaidCompatibility compatibility,
      IEnumerable<string>? readinessWarningCodes = null)
  {
    ArgumentNullException.ThrowIfNull(admission);
    ArgumentNullException.ThrowIfNull(staticRelations);
    ArgumentNullException.ThrowIfNull(provenance);
    ArgumentNullException.ThrowIfNull(compatibility);
    if (seasonNumber < 1)
    {
      throw new ArgumentOutOfRangeException(nameof(seasonNumber), "A season number must be positive.");
    }

    if (admission.SeasonNumber != seasonNumber || !admission.IsSupported || admission.Rule is null)
    {
      throw new ArgumentException(
          "Only a supported admission decision for the same season can be published.",
          nameof(admission));
    }

    compatibility.Validate(provenance);

    return new RaidSnapshot(
        RaidDomainGuard.RequireUid(raidSnapshotUid, nameof(raidSnapshotUid)),
        RaidDomainGuard.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid)),
        RaidDomainGuard.RequireUid(challengeEncounterUid, nameof(challengeEncounterUid)),
        RaidDomainGuard.RequireUid(bossVariantUid, nameof(bossVariantUid)),
        RaidDomainGuard.RequireUid(compatibilityMapUid, nameof(compatibilityMapUid)),
        seasonNumber,
        admission,
        staticRelations,
        provenance,
        compatibility,
        RaidDomainGuard.NormalizeCodes(readinessWarningCodes, nameof(readinessWarningCodes)));
  }
}
