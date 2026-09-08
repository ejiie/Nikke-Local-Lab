using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public enum ResourceQuality { Sd, Hd }

// A payload plan is not launch admission. In particular, base-only/no-audio is
// observable in the native planner but its persisted preference contract is unknown.
public sealed class PatchResourcePlan
{
  public const string ProfileCode = "shiftup_patch_v1";
  public static IReadOnlyList<string> MetadataRoles { get; } =
      Array.AsReadOnly(new[] { "core", "dp", "fd", "saus", "ko", "en", "ja" });

  public PatchResourcePlan(ResourceSelection voice, ResourceQuality lod,
      ResourceQuality texture, ResourceQuality spine)
  {
    ArgumentNullException.ThrowIfNull(voice);
    if (!Enum.IsDefined(lod) || !Enum.IsDefined(texture) || !Enum.IsDefined(spine))
    {
      throw new PipelineManifestException("resource_quality_invalid");
    }

    if (voice.DownloadScope == VoiceDownloadScope.Unresolved)
    {
      throw new PipelineManifestException("resource_voice_selection_unresolved");
    }

    Voice = voice;
    Lod = lod;
    Texture = texture;
    Spine = spine;
    var groups = new List<string>
    {
      "required", "requiredquality_lod_" + Code(lod),
      "requiredquality_texture_" + Code(texture), "requiredquality_spine_" + Code(spine)
    };
    if (voice.VoiceLanguage is not null)
    {
      groups.Add(voice.VoiceLanguage + "_required");
      if (voice.DownloadScope == VoiceDownloadScope.Full)
      {
        groups.Add(voice.VoiceLanguage + "_add");
      }
    }

    PayloadGroups = Array.AsReadOnly(groups.ToArray());
    ContentSha256 = Sha256Digest.ComputeUtf8(string.Join('\n',
        new[] { "nll/patch-resource-plan/v1", ProfileCode, voice.VoiceLanguage ?? "none", voice.ScopeCode }
        .Concat(PayloadGroups)) + "\n");
  }

  public ResourceSelection Voice { get; }
  public ResourceQuality Lod { get; }
  public ResourceQuality Texture { get; }
  public ResourceQuality Spine { get; }
  public IReadOnlyList<string> PayloadGroups { get; }
  public Sha256Digest ContentSha256 { get; }
  public bool NoAudioPreferenceContractResolved => Voice.DownloadScope != VoiceDownloadScope.None;

  public IReadOnlyList<string> GroupsForRole(string role)
  {
    RequireRole(role);
    IEnumerable<string> groups = role switch
    {
      "core" => ["required", "requiredquality_lod_" + Code(Lod), "requiredquality_texture_" + Code(Texture)],
      "dp" => ["required", "requiredquality_spine_" + Code(Spine), "requiredquality_texture_" + Code(Texture)],
      "fd" when Lod == ResourceQuality.Hd => ["required", "requiredquality_lod_hd"],
      "fd" or "saus" => ["required"],
      _ when role == Voice.VoiceLanguage => Voice.DownloadScope == VoiceDownloadScope.Full
          ? [role + "_required", role + "_add"] : [role + "_required"],
      _ => []
    };
    return Array.AsReadOnly(groups.ToArray());
  }

  public static void RequireRole(string role)
  {
    if (!MetadataRoles.Contains(role, StringComparer.Ordinal))
    {
      throw new PipelineManifestException("resource_role_invalid");
    }
  }

  private static string Code(ResourceQuality quality) => quality == ResourceQuality.Sd ? "sd" : "hd";
}

public sealed record CatalogPairIdentity(string RoleCode, Sha256Digest BodySha256, Sha256Digest SignatureSha256);

// Source-free, immutable comparison of an installed set against separately
// acquired, header-bound catalog pairs. Construction cannot establish provenance
// by itself: the acquisition receipt must be verified before supplying its digest.
public sealed class PatchResourceBinding
{
  public PatchResourceBinding(ResourceBinding effectiveRuntime, PatchResourcePlan plan,
      Sha256Digest metadataSha256, Sha256Digest acquisitionReceiptSha256,
      Sha256Digest effectiveOverlaySha256, IEnumerable<CatalogPairIdentity> installed,
      IEnumerable<CatalogPairIdentity> acquired)
  {
    ArgumentNullException.ThrowIfNull(effectiveRuntime);
    ArgumentNullException.ThrowIfNull(plan);
    if (effectiveRuntime.LayoutCode != "chunk_catalog_v1" || effectiveRuntime.Selection != plan.Voice)
    {
      throw new PipelineManifestException("resource_patch_binding_invalid");
    }

    foreach (var digest in new[] { metadataSha256, acquisitionReceiptSha256, effectiveOverlaySha256 })
    {
      if (string.IsNullOrEmpty(digest.Hex))
      {
        throw new PipelineManifestException("resource_patch_binding_evidence_missing");
      }
    }

    var local = ValidateSet(installed);
    var origin = ValidateSet(acquired);
    if (!local.SequenceEqual(origin))
    {
      throw new PipelineManifestException("resource_catalog_revision_mismatch");
    }

    Runtime = effectiveRuntime;
    Plan = plan;
    MetadataSha256 = metadataSha256;
    AcquisitionReceiptSha256 = acquisitionReceiptSha256;
    EffectiveOverlaySha256 = effectiveOverlaySha256;
    Catalogs = Array.AsReadOnly(local);
    ContentSha256 = Sha256Digest.ComputeUtf8(string.Join('\n', new[]
    {
      "nll/patch-resource-binding/v1", effectiveRuntime.ContentSha256.Hex, plan.ContentSha256.Hex,
      metadataSha256.Hex, acquisitionReceiptSha256.Hex, effectiveOverlaySha256.Hex
    }.Concat(local.SelectMany(pair => new[] { pair.RoleCode, pair.BodySha256.Hex, pair.SignatureSha256.Hex }))) + "\n");
  }

  public ResourceBinding Runtime { get; }
  public PatchResourcePlan Plan { get; }
  public Sha256Digest MetadataSha256 { get; }
  public Sha256Digest AcquisitionReceiptSha256 { get; }
  public Sha256Digest EffectiveOverlaySha256 { get; }
  public IReadOnlyList<CatalogPairIdentity> Catalogs { get; }
  public Sha256Digest ContentSha256 { get; }

  private static CatalogPairIdentity[] ValidateSet(IEnumerable<CatalogPairIdentity> source)
  {
    ArgumentNullException.ThrowIfNull(source);
    var pairs = source.ToArray();
    if (pairs.Length != 7 || pairs.Any(pair => pair is null ||
        !PatchResourcePlan.MetadataRoles.Contains(pair.RoleCode, StringComparer.Ordinal) ||
        string.IsNullOrEmpty(pair.BodySha256.Hex) || string.IsNullOrEmpty(pair.SignatureSha256.Hex)) ||
        pairs.Select(pair => pair.RoleCode).Distinct(StringComparer.Ordinal).Count() != 7)
    {
      throw new PipelineManifestException("resource_catalog_set_invalid");
    }

    return pairs.OrderBy(pair => pair.RoleCode, StringComparer.Ordinal).ToArray();
  }
}
