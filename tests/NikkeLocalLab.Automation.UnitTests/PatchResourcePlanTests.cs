using System.Text;
using NikkeLocalLab.Automation;
using NikkeLocalLab.Provenance;
using Xunit;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class PatchResourcePlanTests
{
  [Theory]
  [InlineData("en", VoiceDownloadScope.Minimal, 5, 1)]
  [InlineData("ko", VoiceDownloadScope.Minimal, 5, 1)]
  [InlineData("ja", VoiceDownloadScope.Minimal, 5, 1)]
  [InlineData("en", VoiceDownloadScope.Full, 6, 2)]
  [InlineData("ko", VoiceDownloadScope.Full, 6, 2)]
  [InlineData("ja", VoiceDownloadScope.Full, 6, 2)]
  [InlineData(null, VoiceDownloadScope.None, 4, 0)]
  public void AllMetadataProjectsAreIndependentOfSelectedVoicePayload(string? language,
      VoiceDownloadScope scope, int groupCount, int voiceGroups)
  {
    var plan = Plan(language, scope);
    Assert.Equal(7, PatchResourcePlan.MetadataRoles.Count);
    Assert.Equal(groupCount, plan.PayloadGroups.Count);
    foreach (var role in new[] { "en", "ko", "ja" })
    {
      Assert.Equal(role == language ? voiceGroups : 0, plan.GroupsForRole(role).Count);
    }

    Assert.Equal(scope != VoiceDownloadScope.None, plan.NoAudioPreferenceContractResolved);
  }

  [Fact]
  public void ThreeQualityAxesVaryIndependentlyAndChangeIdentity()
  {
    var hashes = new HashSet<Sha256Digest>();
    foreach (var lod in Enum.GetValues<ResourceQuality>())
    {
      foreach (var texture in Enum.GetValues<ResourceQuality>())
      {
        foreach (var spine in Enum.GetValues<ResourceQuality>())
        {
          var plan = new PatchResourcePlan(new("ko", VoiceDownloadScope.Minimal), lod, texture, spine);
          Assert.Equal(lod == ResourceQuality.Hd ? 2 : 1, plan.GroupsForRole("fd").Count);
          Assert.Single(plan.GroupsForRole("saus"));
          Assert.Single(plan.GroupsForRole("ko"));
          Assert.Equal(3, plan.GroupsForRole("core").Count);
          Assert.Equal(3, plan.GroupsForRole("dp").Count);
          hashes.Add(plan.ContentSha256);
        }
      }
    }

    Assert.Equal(8, hashes.Count);
  }

  [Fact]
  public void UnknownQualityScopeOrRoleDoesNotSelectEverything()
  {
    Assert.Throws<PipelineManifestException>(() => new PatchResourcePlan(new("ko", VoiceDownloadScope.Minimal),
        (ResourceQuality)99, ResourceQuality.Sd, ResourceQuality.Sd));
    Assert.Throws<PipelineManifestException>(() => Plan(null, VoiceDownloadScope.Unresolved));
    Assert.Throws<PipelineManifestException>(() => Plan().GroupsForRole("../other"));
  }

  [Fact]
  public void CatalogBindingRequiresSevenExactUniquePairs()
  {
    var pairs = Pairs();
    Assert.Throws<PipelineManifestException>(() => Bind(pairs.Skip(1), pairs));
    Assert.Throws<PipelineManifestException>(() => Bind(pairs.Append(pairs[0]), pairs));
    Assert.Throws<PipelineManifestException>(() => Bind(pairs.Select(pair => pair with { RoleCode = "core" }), pairs));
    var changed = pairs.Select(pair => pair.RoleCode == "ja" ? pair with { SignatureSha256 = Digest("changed") } : pair);
    Assert.Equal("resource_catalog_revision_mismatch", Assert.Throws<PipelineManifestException>(
        () => Bind(pairs, changed)).FailureCode);
    Assert.Equal(Bind(pairs, pairs).ContentSha256, Bind(pairs.Reverse(), pairs.Reverse()).ContentSha256);
  }

  [Fact]
  public void MetadataReceiptOverlayAndQualityAreBoundNotOnlyBaseRuntime()
  {
    var pairs = Pairs();
    var original = Bind(pairs, pairs);
    Assert.NotEqual(original.ContentSha256, Bind(pairs, pairs, metadata: "new").ContentSha256);
    Assert.NotEqual(original.ContentSha256, Bind(pairs, pairs, overlay: "new").ContentSha256);
    Assert.NotEqual(original.ContentSha256, Bind(pairs, pairs, receipt: "new").ContentSha256);
    var qualityPlan = new PatchResourcePlan(new("ko", VoiceDownloadScope.Minimal),
        ResourceQuality.Hd, ResourceQuality.Sd, ResourceQuality.Sd);
    Assert.NotEqual(original.ContentSha256, Bind(pairs, pairs, plan: qualityPlan).ContentSha256);
    Assert.Throws<PipelineManifestException>(() => new PatchResourceBinding(Runtime(Plan()), Plan(), default,
        Digest("receipt"), Digest("overlay"), pairs, pairs));
  }

  [Fact]
  public void MetadataRetainsBothRevisionAndPublicationAndExactSourceDigest()
  {
    const string text = "root1\ncore:151.8.b1,10\ndp:abc,20\nfd:def,30\nsaus:ghi,40\nko:jkl,50\nen:mno,60\nja:pqr,70\n";
    var original = PatchVersionMetadata.Parse(Encoding.UTF8.GetBytes(text));
    Assert.Equal("root1", original.RootRevision);
    Assert.Equal(new PatchProjectVersion("151.8.b1", "10"), original.Projects["core"]);
    var changed = PatchVersionMetadata.Parse(Encoding.UTF8.GetBytes(text.Replace(",10", ",11", StringComparison.Ordinal)));
    Assert.NotEqual(original.SourceSha256, changed.SourceSha256);
    Assert.Equal(original.Projects["core"].Revision, changed.Projects["core"].Revision);
    Assert.NotEqual(original.Projects["core"].Publication, changed.Projects["core"].Publication);
    Assert.Throws<PipelineManifestException>(() => PatchVersionMetadata.Parse([255]));
    Assert.Throws<PipelineManifestException>(() => PatchVersionMetadata.Parse(new byte[65537]));
  }

  private static PatchResourcePlan Plan(string? language = "ko", VoiceDownloadScope scope = VoiceDownloadScope.Minimal) =>
      new(new(language, scope), ResourceQuality.Sd, ResourceQuality.Sd, ResourceQuality.Sd);

  private static Sha256Digest Digest(string seed) => Sha256Digest.ComputeUtf8(seed);

  private static CatalogPairIdentity[] Pairs() => PatchResourcePlan.MetadataRoles.Select(role =>
      new CatalogPairIdentity(role, Digest(role + "body"), Digest(role + "signature"))).ToArray();

  private static ResourceBinding Runtime(PatchResourcePlan plan) => new("synthetic_build", Digest("client"),
      Digest("server"), Digest("config"), Digest("static"), "chunk_catalog_v1", plan.Voice);

  private static PatchResourceBinding Bind(IEnumerable<CatalogPairIdentity> local, IEnumerable<CatalogPairIdentity> origin,
      string metadata = "metadata", string overlay = "overlay", string receipt = "receipt", PatchResourcePlan? plan = null)
  {
    plan ??= Plan();
    return new(Runtime(plan), plan, Digest(metadata), Digest(receipt), Digest(overlay), local, origin);
  }
}
