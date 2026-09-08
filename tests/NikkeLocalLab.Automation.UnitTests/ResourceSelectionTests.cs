using NikkeLocalLab.Automation;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Xunit;

namespace NikkeLocalLab.Automation.UnitTests;

public sealed class ResourceSelectionTests
{
  [Theory]
  [InlineData("en", VoiceDownloadScope.Minimal)]
  [InlineData("en", VoiceDownloadScope.Full)]
  [InlineData("ko", VoiceDownloadScope.Minimal)]
  [InlineData("ko", VoiceDownloadScope.Full)]
  [InlineData("ja", VoiceDownloadScope.Minimal)]
  [InlineData("ja", VoiceDownloadScope.Full)]
  public void SelectedLanguageIsRequiredButOtherLanguagesAreNot(string language, VoiceDownloadScope scope)
  {
    var roles = new ResourceSelection(language, scope).RequiredCatalogRoles();
    Assert.Equal(5, roles.Count);
    Assert.Contains(language, roles);
    Assert.Equal(1, roles.Count(role => role is "ko" or "en" or "ja"));
  }

  [Fact]
  public void MinimalDoesNotMeanNoAudio()
  {
    Assert.Contains("en", new ResourceSelection("en", VoiceDownloadScope.Minimal).RequiredCatalogRoles());
    Assert.Equal("resource_no_audio_contract_unresolved", Assert.Throws<PipelineManifestException>(
        () => new ResourceSelection(null, VoiceDownloadScope.None).RequiredCatalogRoles()).FailureCode);
    Assert.Equal("resource_voice_selection_unresolved", Assert.Throws<PipelineManifestException>(
        () => new ResourceSelection(null, VoiceDownloadScope.Unresolved).RequiredCatalogRoles()).FailureCode);
  }

  [Fact]
  public void BindingChangesWithEitherLanguageOrScopeOrBuildOrContent()
  {
    var original = Binding("en", VoiceDownloadScope.Minimal);
    Assert.NotEqual(original.ContentSha256, Binding("ko", VoiceDownloadScope.Minimal).ContentSha256);
    Assert.NotEqual(original.ContentSha256, Binding("en", VoiceDownloadScope.Full).ContentSha256);
    Assert.NotEqual(original.ContentSha256, Binding("en", VoiceDownloadScope.Minimal, "b").ContentSha256);
    Assert.Equal(original.ContentSha256, Binding("en", VoiceDownloadScope.Minimal).ContentSha256);
  }

  [Fact]
  public async Task CatalogPresenceAloneNeverMeansPayloadClosure()
  {
    var binding = Binding("en", VoiceDownloadScope.Minimal);
    var plan = new ResourceClosurePlan(binding, Manifest(), Sha256Digest.ComputeUtf8("policy"),
        binding.Selection.RequiredCatalogRoles(), false);
    Assert.True(plan.CatalogClosureResolved);
    Assert.False(plan.PayloadClosureResolved);
    var error = await Assert.ThrowsAsync<PipelineManifestException>(
        () => plan.VerifyAsync("unused", binding));
    Assert.Equal("resource_payload_closure_unresolved", error.FailureCode);
  }

  [Fact]
  public async Task LanguageChangeInvalidatesAnExistingPlanBeforeFileIo()
  {
    var binding = Binding("en", VoiceDownloadScope.Minimal);
    var plan = new ResourceClosurePlan(binding, Manifest(), Sha256Digest.ComputeUtf8("policy"),
        binding.Selection.RequiredCatalogRoles(), true);
    var error = await Assert.ThrowsAsync<PipelineManifestException>(
        () => plan.VerifyAsync("unused", Binding("ko", VoiceDownloadScope.Minimal)));
    Assert.Equal("resource_preflight_binding_changed", error.FailureCode);
  }

  [Fact]
  public void LegacyClosureCannotCertifyChunkLayoutWithFiveCatalogs()
  {
    var binding = new ResourceBinding("synthetic_build", Sha256Digest.ComputeUtf8("client"),
        Sha256Digest.ComputeUtf8("server"), Sha256Digest.ComputeUtf8("config"), Sha256Digest.ComputeUtf8("static"),
        "chunk_catalog_v1", new("ko", VoiceDownloadScope.Minimal));
    Assert.Equal("resource_patch_binding_required", Assert.Throws<PipelineManifestException>(() =>
        new ResourceClosurePlan(binding, Manifest(), Sha256Digest.ComputeUtf8("policy"),
            binding.Selection.RequiredCatalogRoles(), true)).FailureCode);
  }

  private static ResourceBinding Binding(string language, VoiceDownloadScope scope, string seed = "a") =>
      new("synthetic_build", Sha256Digest.ComputeUtf8(seed), Sha256Digest.ComputeUtf8("server"),
          Sha256Digest.ComputeUtf8("config"), Sha256Digest.ComputeUtf8("static"), "legacy_catalog_v1",
          new ResourceSelection(language, scope));

  private static PipelineRunManifest Manifest() => new(EntityUid.New(),
      new PipelineTarget("resource", null, "synthetic_build", "challenge"),
      [new PipelineArtifactSpec("catalog", "catalog.body", 12, Sha256Digest.ComputeUtf8("synthetic"))],
      [new PipelineStepDefinition("inventory", PipelineStepKind.Inventory, false, [], [])]);
}
