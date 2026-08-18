namespace NikkeLocalLab.Raid.UnitTests;

internal static class RaidTestData
{
  public static EntityUid Uid(int suffix) =>
      new(Guid.Parse($"10000000-0000-4000-8000-{suffix.ToString("D12", System.Globalization.CultureInfo.InvariantCulture)}"));

  public static Sha256Digest Digest(char value) => Sha256Digest.Parse(new string(value, 64));

  public static RaidArtifactReference Artifact(int uid, char digest) => new(Uid(uid), Digest(digest));

  public static RaidStaticRelations StaticRelations(bool reverseCollections = false)
  {
    var parts = new[]
    {
      new RaidPartStaticRelation(
          Uid(21),
          0,
          "core",
          10_000,
          10_000,
          10_000,
          10_000,
          10_000,
          10_000,
          10_000,
          isMainPart: true,
          isDamageable: true,
          isHpVisible: true,
          linkedPartUid: Uid(22)),
      new RaidPartStaticRelation(
          Uid(22),
          1,
          "weapon",
          5_000,
          2_500,
          10_000,
          10_000,
          10_000,
          10_000,
          10_000,
          isMainPart: false,
          isDamageable: true,
          isHpVisible: true,
          linkedPartUid: Uid(21)),
    };
    var skills = new[]
    {
      new RaidSkillStaticRelation(Uid(31), 0, "active"),
      new RaidSkillStaticRelation(Uid(32), 1, "passive"),
    };
    return new RaidStaticRelations(
        reverseCollections ? parts.Reverse() : parts,
        reverseCollections ? skills.Reverse() : skills);
  }

  public static TimingProvenance UnresolvedTiming(IEnumerable<ClockBasis>? order = null)
  {
    var bases = order?.ToArray() ?? Enum.GetValues<ClockBasis>();
    return new TimingProvenance(
        bases.Select(basis => ClockBasisEvidence.Unresolved(basis, $"{ClockCode(basis)}_not_evaluated")),
        SchedulerEvidence.Unresolved(Enum.GetValues<ClockBasis>(), "scheduler_not_evaluated"));
  }

  public static TimingProvenance ResolvedTiming(IEnumerable<ClockBasis>? order = null)
  {
    var bases = order?.ToArray() ?? Enum.GetValues<ClockBasis>();
    var artifactByBasis = new Dictionary<ClockBasis, RaidArtifactReference>
    {
      [ClockBasis.BehaviorTick] = Artifact(41, '1'),
      [ClockBasis.RenderFrame] = Artifact(42, '2'),
      [ClockBasis.FixedUpdate] = Artifact(43, '3'),
      [ClockBasis.WallClock] = Artifact(44, '4'),
    };
    return new TimingProvenance(
        bases.Select(basis => ClockBasisEvidence.Resolved(
            basis,
            TimingEvidenceResolution.RuntimeTrace,
            [artifactByBasis[basis]])),
        SchedulerEvidence.Resolved(
            TimingEvidenceResolution.RuntimeTrace,
            Enum.GetValues<ClockBasis>().Reverse(),
            [Artifact(45, '5')]));
  }

  public static RaidSnapshotProvenance Provenance(
      bool resolvedRuntime = false,
      bool reverseCollections = false,
      bool resolvedTiming = false)
  {
    var bundles = new[]
    {
      new SelectedAssetBundle(Uid(12), Digest('b'), [AssetBundleRole.Model, AssetBundleRole.Animation]),
      new SelectedAssetBundle(Uid(13), Digest('c'), [AssetBundleRole.Timeline, AssetBundleRole.Behavior]),
    };
    var timelines = new[]
    {
      new TimelineArtifactReference(Artifact(15, 'f'), [ClockBasis.BehaviorTick, ClockBasis.RenderFrame]),
      new TimelineArtifactReference(Artifact(16, '6'), [ClockBasis.WallClock, ClockBasis.FixedUpdate]),
    };
    var order = reverseCollections
        ? Enum.GetValues<ClockBasis>().Reverse()
        : Enum.GetValues<ClockBasis>();

    return new RaidSnapshotProvenance(
        Artifact(11, 'a'),
        reverseCollections ? bundles.Reverse() : bundles,
        Artifact(14, 'e'),
        reverseCollections ? timelines.Reverse() : timelines,
        resolvedRuntime
            ? ClientRuntimeReference.Resolved(Uid(17), "synthetic-runtime-1", Digest('7'))
            : ClientRuntimeReference.Unresolved(),
        resolvedTiming ? ResolvedTiming(order) : UnresolvedTiming(order));
  }

  public static RaidSnapshotProvenance StaticOnlyProvenance() => new(
      Artifact(11, 'a'),
      Array.Empty<SelectedAssetBundle>(),
      behavior: null,
      Array.Empty<TimelineArtifactReference>(),
      ClientRuntimeReference.Unresolved(),
      UnresolvedTiming());

  public static RaidSnapshot Snapshot(
      int snapshotUid = 1,
      bool reverseCollections = false,
      RaidCompatibilityTier tier = RaidCompatibilityTier.BehaviorExact,
      RuntimeRelation runtimeRelation = RuntimeRelation.NotEvaluated,
      bool resolvedRuntime = false,
      bool resolvedTiming = false,
      bool staticOnlyEvidence = false,
      IEnumerable<string>? evidenceWarnings = null,
      IEnumerable<string>? readinessWarnings = null)
  {
    var admission = ChallengeBossSupportPolicy.Evaluate(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        authoritativeChallengeChainResolved: true);
    return RaidSnapshot.Publish(
        Uid(snapshotUid),
        Uid(2),
        Uid(3),
        Uid(4),
        Uid(5),
        40,
        admission,
        StaticRelations(reverseCollections),
        staticOnlyEvidence
            ? StaticOnlyProvenance()
            : Provenance(resolvedRuntime, reverseCollections, resolvedTiming),
        new RaidCompatibility(tier, runtimeRelation, evidenceWarnings),
        readinessWarnings);
  }

  private static string ClockCode(ClockBasis basis) => basis switch
  {
    ClockBasis.BehaviorTick => "behavior_tick",
    ClockBasis.RenderFrame => "render_frame",
    ClockBasis.FixedUpdate => "fixed_update",
    ClockBasis.WallClock => "wall_clock",
    _ => throw new ArgumentOutOfRangeException(nameof(basis)),
  };
}
