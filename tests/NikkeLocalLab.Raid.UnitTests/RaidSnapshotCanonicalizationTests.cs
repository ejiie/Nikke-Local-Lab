namespace NikkeLocalLab.Raid.UnitTests;

public sealed class RaidSnapshotCanonicalizationTests
{
  [Fact]
  public void Snapshot_content_hash_is_stable_across_input_order_and_snapshot_identity()
  {
    var first = RaidTestData.Snapshot(
        snapshotUid: 1,
        evidenceWarnings: ["z_warning", "a_warning", "z_warning"],
        readinessWarnings: ["z_ready", "a_ready"]);
    var reordered = RaidTestData.Snapshot(
        snapshotUid: 99,
        reverseCollections: true,
        evidenceWarnings: ["a_warning", "z_warning"],
        readinessWarnings: ["a_ready", "z_ready"]);

    var canonical = RaidSnapshotCanonicalizer.ToCanonicalText(first);
    Assert.Equal(canonical, RaidSnapshotCanonicalizer.ToCanonicalText(reordered));
    Assert.Equal(first.ContentSha256, reordered.ContentSha256);
    Assert.Equal(Sha256Digest.ComputeUtf8(canonical), first.ContentSha256);
    Assert.StartsWith("nll/raid-snapshot/v2\n", canonical, StringComparison.Ordinal);
    Assert.DoesNotContain(first.RaidSnapshotUid.ToString(), canonical, StringComparison.Ordinal);
    Assert.False(canonical.EndsWith('\n'));
    Assert.Contains("static-relations.part-count=2", canonical, StringComparison.Ordinal);
    Assert.Contains("static-relations.skill-count=2", canonical, StringComparison.Ordinal);
    Assert.DoesNotContain("part-category-", canonical, StringComparison.Ordinal);
  }

  [Fact]
  public void Bundle_set_hash_is_digest_only_deduplicated_and_lexically_sorted()
  {
    var bundles = new[]
    {
      new SelectedAssetBundle(RaidTestData.Uid(1), RaidTestData.Digest('c'), [AssetBundleRole.Model]),
      new SelectedAssetBundle(RaidTestData.Uid(2), RaidTestData.Digest('b'), [AssetBundleRole.Behavior]),
      new SelectedAssetBundle(RaidTestData.Uid(3), RaidTestData.Digest('b'), [AssetBundleRole.Animation]),
    };

    var expected = Sha256Digest.ComputeUtf8($"{RaidTestData.Digest('b')}\n{RaidTestData.Digest('c')}");
    Assert.Equal(expected, AssetBundleSetCanonicalizer.ComputeHash(bundles));
    Assert.Equal(
        "1a886cd7ef02d09cea034689e09d98571345ba5d614fb0ff05ef8e10bfb043e8",
        expected.ToString());
  }

  [Fact]
  public void Canonical_snapshot_records_normalized_elements_and_all_clock_basis_claims()
  {
    var canonical = RaidSnapshotCanonicalizer.ToCanonicalText(RaidTestData.Snapshot());

    Assert.Contains("admission.boss-element=wind", canonical, StringComparison.Ordinal);
    Assert.Contains("admission.weakness-code=fire", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.timing.clock.behavior_tick.resolution=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.timing.clock.render_frame.resolution=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.timing.clock.fixed_update.resolution=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.timing.clock.wall_clock.resolution=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.timing.scheduler.resolution=unresolved", canonical, StringComparison.Ordinal);
  }

  [Fact]
  public void Static_only_snapshot_canonicalizes_absent_higher_tier_evidence_explicitly()
  {
    var canonical = RaidSnapshotCanonicalizer.ToCanonicalText(RaidTestData.Snapshot(
        tier: RaidCompatibilityTier.StaticExact,
        staticOnlyEvidence: true,
        evidenceWarnings: ["higher_tier_evidence_unresolved"]));

    Assert.Contains("provenance.asset-bundle-set-sha256=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.behavior=unresolved", canonical, StringComparison.Ordinal);
    Assert.Contains("provenance.client-runtime=unresolved", canonical, StringComparison.Ordinal);
  }
}
