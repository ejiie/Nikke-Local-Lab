namespace NikkeLocalLab.Raid.UnitTests;

public sealed class RaidSnapshotValidationTests
{
  [Fact]
  public void Publishing_rejects_excluded_or_unresolved_admission()
  {
    var excluded = ChallengeBossSupportPolicy.Evaluate(
        39,
        RaidElement.Electric,
        RaidElement.Iron,
        authoritativeChallengeChainResolved: true);
    var unresolved = ChallengeBossSupportPolicy.Evaluate(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        authoritativeChallengeChainResolved: false);

    Assert.Throws<ArgumentException>(() => Publish(39, excluded));
    Assert.Throws<ArgumentException>(() => Publish(40, unresolved));
  }

  [Fact]
  public void Timing_provenance_requires_one_explicit_claim_for_each_clock_basis()
  {
    var incomplete = Enum.GetValues<ClockBasis>()
        .Where(static basis => basis != ClockBasis.FixedUpdate)
        .Select(basis => ClockBasisEvidence.Unresolved(basis, "not_evaluated"));

    Assert.Throws<ArgumentException>(() => new TimingProvenance(
        incomplete,
        SchedulerEvidence.Unresolved(Enum.GetValues<ClockBasis>(), "not_evaluated")));
    Assert.Throws<ArgumentException>(() => ClockBasisEvidence.Resolved(
        ClockBasis.RenderFrame,
        TimingEvidenceResolution.StaticAnalysis,
        Array.Empty<RaidArtifactReference>()));
    Assert.Throws<ArgumentException>(() => SchedulerEvidence.Unresolved(
        [ClockBasis.RenderFrame],
        "not_evaluated"));
  }

  [Fact]
  public void Runtime_exact_tiers_require_matching_runtime_and_scheduler_evidence()
  {
    Assert.Throws<ArgumentException>(() => RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.AssetExactRuntimeCurrent,
        runtimeRelation: RuntimeRelation.CurrentRuntimeMatch,
        resolvedRuntime: true,
        resolvedTiming: false));
    Assert.Throws<ArgumentException>(() => RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.AssetExactRuntimeCurrent,
        runtimeRelation: RuntimeRelation.HistoricalRuntimeMatch,
        resolvedRuntime: true,
        resolvedTiming: true));

    var valid = RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.AssetExactRuntimeCurrent,
        runtimeRelation: RuntimeRelation.CurrentRuntimeMatch,
        resolvedRuntime: true,
        resolvedTiming: true);
    Assert.Equal(RaidCompatibilityTier.AssetExactRuntimeCurrent, valid.Compatibility.Tier);
  }

  [Fact]
  public void Static_exact_accepts_static_relations_without_higher_tier_evidence_but_requires_a_warning()
  {
    Assert.Throws<ArgumentException>(() => RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.StaticExact,
        staticOnlyEvidence: true));

    var snapshot = RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.StaticExact,
        staticOnlyEvidence: true,
        evidenceWarnings: ["higher_tier_evidence_unresolved"]);

    Assert.Null(snapshot.Provenance.Behavior);
    Assert.Empty(snapshot.Provenance.SelectedAssetBundles);
    Assert.Null(snapshot.Provenance.AssetBundleSetSha256);
    Assert.Empty(snapshot.Provenance.Timelines);
    Assert.False(snapshot.Provenance.ClientRuntime.IsResolved);
    Assert.Equal(
        TimingEvidenceResolution.Unresolved,
        snapshot.Provenance.Timing.Scheduler.Resolution);
  }

  [Fact]
  public void Behavior_exact_requires_behavior_and_selected_bundle_evidence()
  {
    Assert.Throws<ArgumentException>(() => RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.BehaviorExact,
        staticOnlyEvidence: true));
  }

  [Fact]
  public void Static_relations_require_source_free_identity_and_closed_link_topology()
  {
    Assert.Throws<ArgumentException>(() => new RaidStaticRelations(
        [new RaidPartStaticRelation(
            RaidTestData.Uid(21),
            0,
            "core",
            1,
            1,
            1,
            1,
            1,
            1,
            1,
            true,
            true,
            true,
            RaidTestData.Uid(99))],
        Array.Empty<RaidSkillStaticRelation>()));
    Assert.Throws<ArgumentException>(() => new RaidStaticRelations(
        Array.Empty<RaidPartStaticRelation>(),
        [
          new RaidSkillStaticRelation(RaidTestData.Uid(31), 0, "active"),
          new RaidSkillStaticRelation(RaidTestData.Uid(32), 2, "passive"),
        ]));
    Assert.Throws<ArgumentOutOfRangeException>(() => new RaidPartStaticRelation(
        RaidTestData.Uid(21),
        0,
        "core",
        -1,
        1,
        1,
        1,
        1,
        1,
        1,
        true,
        true,
        true));
  }

  [Fact]
  public void Constructor_inputs_are_defensively_copied()
  {
    var roles = new List<AssetBundleRole> { AssetBundleRole.Model };
    var bundle = new SelectedAssetBundle(RaidTestData.Uid(1), RaidTestData.Digest('a'), roles);
    roles.Add(AssetBundleRole.Audio);

    Assert.Single(bundle.Roles);
    Assert.Equal(AssetBundleRole.Model, bundle.Roles[0]);
  }

  private static RaidSnapshot Publish(int season, ChallengeAdmissionDecision admission) =>
      RaidSnapshot.Publish(
          RaidTestData.Uid(1),
          RaidTestData.Uid(2),
          RaidTestData.Uid(3),
          RaidTestData.Uid(4),
          RaidTestData.Uid(5),
          season,
          admission,
          RaidTestData.StaticRelations(),
          RaidTestData.Provenance(),
          new RaidCompatibility(RaidCompatibilityTier.BehaviorExact, RuntimeRelation.NotEvaluated));
}
