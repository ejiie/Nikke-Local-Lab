using System.Text;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

// Download volume is independent of playback volume/mute and of UI language.
public enum VoiceDownloadScope { Minimal, Full, None, Unresolved }

public sealed record ResourceSelection
{
  public ResourceSelection(string? voiceLanguage, VoiceDownloadScope downloadScope)
  {
    if (voiceLanguage is not (null or "en" or "ko" or "ja"))
    {
      throw new PipelineManifestException("resource_voice_language_unsupported");
    }

    if (!Enum.IsDefined(downloadScope) ||
        (downloadScope is VoiceDownloadScope.Minimal or VoiceDownloadScope.Full && voiceLanguage is null) ||
        (downloadScope == VoiceDownloadScope.None && voiceLanguage is not null))
    {
      throw new PipelineManifestException("resource_voice_selection_invalid");
    }

    VoiceLanguage = voiceLanguage;
    DownloadScope = downloadScope;
  }

  public string? VoiceLanguage { get; }

  public VoiceDownloadScope DownloadScope { get; }

  public string ScopeCode => DownloadScope switch
  {
    VoiceDownloadScope.Minimal => "minimal",
    VoiceDownloadScope.Full => "full",
    VoiceDownloadScope.None => "none",
    _ => "unresolved"
  };

  public IReadOnlyList<string> RequiredCatalogRoles()
  {
    if (DownloadScope == VoiceDownloadScope.Unresolved)
    {
      throw new PipelineManifestException("resource_voice_selection_unresolved");
    }

    // No-audio is not a fallback for an incomplete installation. Its native
    // startup contract has not been proven for either supported layout yet.
    if (DownloadScope == VoiceDownloadScope.None)
    {
      throw new PipelineManifestException("resource_no_audio_contract_unresolved");
    }

    return Array.AsReadOnly(new[] { "core", "dp", "fd", "saus", VoiceLanguage! });
  }
}

public sealed record ResourceBinding
{
  public ResourceBinding(
      string clientBuildCode,
      Sha256Digest clientExecutableSha256,
      Sha256Digest serverAssemblySha256,
      Sha256Digest serverConfigurationSha256,
      Sha256Digest staticDataSha256,
      string layoutCode,
      ResourceSelection selection)
  {
    ClientBuildCode = ControlledCode.Require(clientBuildCode, nameof(clientBuildCode));
    ClientExecutableSha256 = RequireDigest(clientExecutableSha256);
    ServerAssemblySha256 = RequireDigest(serverAssemblySha256);
    ServerConfigurationSha256 = RequireDigest(serverConfigurationSha256);
    StaticDataSha256 = RequireDigest(staticDataSha256);
    LayoutCode = layoutCode is "legacy_catalog_v1" or "chunk_catalog_v1"
        ? layoutCode
        : throw new PipelineManifestException("resource_layout_unsupported");
    Selection = selection ?? throw new ArgumentNullException(nameof(selection));
    ContentSha256 = Sha256Digest.ComputeUtf8(new StringBuilder("nll/resource-binding/v1\n")
        .Append(ClientBuildCode).Append('\n')
        .Append(ClientExecutableSha256.Hex).Append('\n')
        .Append(ServerAssemblySha256.Hex).Append('\n')
        .Append(ServerConfigurationSha256.Hex).Append('\n')
        .Append(StaticDataSha256.Hex).Append('\n')
        .Append(LayoutCode).Append('\n')
        .Append(Selection.VoiceLanguage ?? "none").Append('\n')
        .Append(Selection.ScopeCode).Append('\n').ToString());
  }

  public string ClientBuildCode { get; }
  public Sha256Digest ClientExecutableSha256 { get; }
  public Sha256Digest ServerAssemblySha256 { get; }
  public Sha256Digest ServerConfigurationSha256 { get; }
  public Sha256Digest StaticDataSha256 { get; }
  public string LayoutCode { get; }
  public ResourceSelection Selection { get; }
  public Sha256Digest ContentSha256 { get; }

  private static Sha256Digest RequireDigest(Sha256Digest digest) =>
      string.IsNullOrEmpty(digest.Hex)
          ? throw new PipelineManifestException("resource_binding_digest_missing")
          : digest;
}

public sealed class ResourceClosurePlan
{
  public ResourceClosurePlan(ResourceBinding binding, PipelineRunManifest manifest,
      Sha256Digest policyEvidenceSha256, IEnumerable<string> resolvedCatalogRoles,
      bool payloadClosureResolved)
  {
    Binding = binding ?? throw new ArgumentNullException(nameof(binding));
    if (binding.LayoutCode != "legacy_catalog_v1")
    {
      // Never validate a 151 plan using the legacy five-catalog rule.
      throw new PipelineManifestException("resource_patch_binding_required");
    }
    Manifest = manifest ?? throw new ArgumentNullException(nameof(manifest));
    if (string.IsNullOrEmpty(policyEvidenceSha256.Hex) ||
        manifest.Target.ClientBuildCode != binding.ClientBuildCode)
    {
      throw new PipelineManifestException("resource_closure_binding_invalid");
    }

    PolicyEvidenceSha256 = policyEvidenceSha256;
    var roles = resolvedCatalogRoles.ToArray();
    CatalogClosureResolved = binding.Selection.RequiredCatalogRoles()
        .All(role => roles.Contains(role, StringComparer.Ordinal));
    PayloadClosureResolved = payloadClosureResolved;
    ContentSha256 = Sha256Digest.ComputeUtf8(string.Join('\n',
        "nll/resource-closure-plan/v1", binding.ContentSha256.Hex,
        manifest.ContentSha256.Hex, policyEvidenceSha256.Hex,
        CatalogClosureResolved ? "catalog_resolved" : "catalog_unresolved",
        payloadClosureResolved ? "payload_resolved" : "payload_unresolved") + "\n");
  }

  public ResourceBinding Binding { get; }
  public PipelineRunManifest Manifest { get; }
  public Sha256Digest PolicyEvidenceSha256 { get; }
  public bool CatalogClosureResolved { get; }
  public bool PayloadClosureResolved { get; }
  public Sha256Digest ContentSha256 { get; }

  public async Task<InventoryObservationSet> VerifyAsync(string root, ResourceBinding effectiveBinding,
      CancellationToken cancellationToken = default)
  {
    if (effectiveBinding.ContentSha256 != Binding.ContentSha256)
    {
      throw new PipelineManifestException("resource_preflight_binding_changed");
    }

    if (!CatalogClosureResolved || !PayloadClosureResolved)
    {
      throw new PipelineManifestException(!CatalogClosureResolved
          ? "resource_catalog_closure_unresolved" : "resource_payload_closure_unresolved");
    }

    return await FileInventoryVerifier.ObserveAsync(Manifest, root, cancellationToken).ConfigureAwait(false);
  }
}
