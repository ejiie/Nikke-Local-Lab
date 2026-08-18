using System.IO.Compression;
using System.Security.Cryptography;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.RaidCatalog;

internal sealed record ChallengeEvidencePackage(
    IReadOnlyDictionary<int, ChallengeCompatibilityEvidence> BySeasonNumber,
    IReadOnlySet<Sha256Digest> ObjectDigests,
    Sha256Digest? ArchiveSha256)
{
  public static ChallengeEvidencePackage Empty { get; } = new(
      new Dictionary<int, ChallengeCompatibilityEvidence>(),
      new HashSet<Sha256Digest>(),
      null);
}

internal static class ChallengeBehaviorEvidenceArchiveReader
{
  internal const string ContractId = "nll/challenge-evidence-package/v2";
  internal const string ManifestEntryName = "ChallengeEvidencePackage.v2.mpk";

  private static readonly ZipArchiveLimits ArchiveLimits = new(
      MaximumEntryCount: 20_000,
      MaximumEntryBytes: 512L * 1024 * 1024,
      MaximumTotalBytes: 4L * 1024 * 1024 * 1024,
      MaximumCompressionRatio: 1_000m);

  public static ChallengeEvidencePackage Read(Stream source)
  {
    ArgumentNullException.ThrowIfNull(source);
    if (!source.CanRead || !source.CanSeek || source.Length is <= 0 or > 8L * 1024 * 1024 * 1024)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_archive_invalid");
    }

    var originalPosition = source.Position;
    try
    {
      var archiveSha256 = ComputeArchiveHash(source);
      source.Position = 0;
      using var archive = new ZipArchive(source, ZipArchiveMode.Read, leaveOpen: true);
      var entries = ZipArchiveGuard.Validate(archive, ArchiveLimits);
      var manifest = ReadSingleEntry(entries, ManifestEntryName);
      var evidence = ReadManifest(manifest);
      var expectedObjects = BuildObjectExpectations(evidence.Values);

      var objectDigests = new HashSet<Sha256Digest>();
      foreach (var entry in entries.Where(entry =>
                   !string.Equals(entry.FullName, ManifestEntryName, StringComparison.Ordinal)))
      {
        var identity = ParseObjectEntry(entry.FullName);
        if (!expectedObjects.TryGetValue(identity.Digest, out var expected))
        {
          throw new ChallengeRaidCatalogSourceException("compatibility_object_unreferenced");
        }

        if (identity.Kind != expected.Kind)
        {
          throw new ChallengeRaidCatalogSourceException("compatibility_object_role_invalid");
        }

        if (entry.Length != expected.ByteLength)
        {
          throw new ChallengeRaidCatalogSourceException("compatibility_object_length_invalid");
        }

        var bytes = ZipArchiveGuard.ReadExactly(entry);
        try
        {
          var digest = Sha256Digest.Compute(bytes);
          if (digest != identity.Digest || !objectDigests.Add(digest))
          {
            throw new ChallengeRaidCatalogSourceException(
                digest == identity.Digest
                    ? "compatibility_object_duplicate"
                    : "compatibility_object_digest_invalid");
          }
        }
        finally
        {
          CryptographicOperations.ZeroMemory(bytes);
        }
      }

      if (!expectedObjects.Keys.ToHashSet().SetEquals(objectDigests))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_reference_invalid");
      }

      return new ChallengeEvidencePackage(evidence, objectDigests, archiveSha256);
    }
    catch (ChallengeRaidCatalogSourceException)
    {
      throw;
    }
    catch (Exception exception) when (exception is InvalidDataException or IOException or OverflowException)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_archive_invalid");
    }
    finally
    {
      source.Position = originalPosition;
    }
  }

  private static IReadOnlyDictionary<int, ChallengeCompatibilityEvidence> ReadManifest(byte[] bytes)
  {
    try
    {
      var reader = new MemoryPackReader(bytes);
      reader.RequireObject(2);
      if (!string.Equals(reader.ReadString(), ContractId, StringComparison.Ordinal))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_contract_invalid");
      }

      var count = reader.ReadCollectionLength(maximumLength: 10_000);
      var result = new Dictionary<int, ChallengeCompatibilityEvidence>();
      for (var index = 0; index < count; index++)
      {
        reader.RequireObject(12);
        var season = reader.ReadInt32();
        var staticArchive = ParseDigest(reader.ReadString());
        var tier = ChallengeEvidenceCodes.ParseTier(reader.ReadString());
        var runtimeRelation = ChallengeEvidenceCodes.ParseRuntimeRelation(reader.ReadString());
        var behaviorDigestValue = reader.ReadString();
        var behaviorByteLength = reader.ReadInt64();
        var behavior = ParseOptionalArtifact(behaviorDigestValue, behaviorByteLength);
        var timelines = ReadTimelines(reader);
        var bundles = ReadBundles(reader);
        var runtime = ReadRuntime(reader);
        var clockClaims = ReadClockClaims(reader);
        var scheduler = ReadSchedulerClaim(reader);
        var warnings = ReadControlledCodes(reader.ReadStringArray(), "compatibility_warning_invalid");

        var evidence = new ChallengeCompatibilityEvidence(
            staticArchive,
            tier,
            runtimeRelation,
            behavior,
            timelines,
            bundles,
            runtime,
            new ChallengeTimingClaims(clockClaims, scheduler),
            warnings);
        if (season <= 0 || bundles.Count == 0 || !evidence.IsValid || !result.TryAdd(season, evidence))
        {
          throw new ChallengeRaidCatalogSourceException("compatibility_evidence_invariant_invalid");
        }
      }

      reader.EnsureEnd();
      return result;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes);
    }
  }

  private static ChallengeArtifactEvidence? ParseOptionalArtifact(string? digestValue, long byteLength)
  {
    if (digestValue is null)
    {
      if (byteLength != 0)
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_length_invalid");
      }

      return null;
    }

    return new ChallengeArtifactEvidence(ParseDigest(digestValue), RequireByteLength(byteLength));
  }

  private static IReadOnlyList<ChallengeTimelineEvidence> ReadTimelines(MemoryPackReader reader)
  {
    var count = reader.ReadCollectionLength(maximumLength: 10_000);
    var result = new ChallengeTimelineEvidence[count];
    var digests = new HashSet<Sha256Digest>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(3);
      var digest = ParseDigest(reader.ReadString());
      var byteLength = RequireByteLength(reader.ReadInt64());
      var clockBases = ReadClockBases(reader.ReadStringArray(), allowEmpty: false);
      if (!digests.Add(digest))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_duplicate");
      }

      result[index] = new ChallengeTimelineEvidence(digest, byteLength, clockBases);
    }

    return Array.AsReadOnly(result
        .OrderBy(static timeline => timeline.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());
  }

  private static IReadOnlyList<ChallengeAssetBundleEvidence> ReadBundles(MemoryPackReader reader)
  {
    var count = reader.ReadCollectionLength(maximumLength: 10_000);
    var result = new ChallengeAssetBundleEvidence[count];
    var digests = new HashSet<Sha256Digest>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(3);
      var digest = ParseDigest(reader.ReadString());
      var byteLength = RequireByteLength(reader.ReadInt64());
      var roles = ReadBundleRoles(reader.ReadStringArray());
      if (!digests.Add(digest))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_duplicate");
      }

      result[index] = new ChallengeAssetBundleEvidence(digest, byteLength, roles);
    }

    return Array.AsReadOnly(result
        .OrderBy(static bundle => bundle.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());
  }

  private static ChallengeRuntimeArtifactEvidence? ReadRuntime(MemoryPackReader reader)
  {
    reader.RequireObject(3);
    var digestValue = reader.ReadString();
    var byteLength = reader.ReadInt64();
    var label = reader.ReadString();
    if (digestValue is null && label is null && byteLength == 0)
    {
      return null;
    }

    if (digestValue is null || label is null || !IsControlledCode(label))
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_runtime_invalid");
    }

    return new ChallengeRuntimeArtifactEvidence(
        ParseDigest(digestValue),
        RequireByteLength(byteLength),
        label);
  }

  private static IReadOnlyList<ChallengeClockBasisClaim> ReadClockClaims(MemoryPackReader reader)
  {
    var count = reader.ReadCollectionLength(maximumLength: 16);
    var result = new ChallengeClockBasisClaim[count];
    var bases = new HashSet<ClockBasis>();
    for (var index = 0; index < count; index++)
    {
      reader.RequireObject(4);
      var basis = ChallengeEvidenceCodes.ParseClockBasis(reader.ReadString());
      var resolution = ChallengeEvidenceCodes.ParseTimingResolution(reader.ReadString());
      var objectDigests = ReadDigests(reader.ReadStringArray());
      var reason = ReadOptionalControlledCode(reader.ReadString(), "compatibility_timing_claim_invalid");
      if (!bases.Add(basis))
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_timing_claim_invalid");
      }

      result[index] = new ChallengeClockBasisClaim(basis, resolution, objectDigests, reason);
    }

    return Array.AsReadOnly(result
        .OrderBy(static claim => ChallengeEvidenceCodes.ClockBasisCode(claim.Basis), StringComparer.Ordinal)
        .ToArray());
  }

  private static ChallengeSchedulerClaim ReadSchedulerClaim(MemoryPackReader reader)
  {
    reader.RequireObject(4);
    var resolution = ChallengeEvidenceCodes.ParseTimingResolution(reader.ReadString());
    var relatedClockBases = ReadClockBases(reader.ReadStringArray(), allowEmpty: false);
    var objectDigests = ReadDigests(reader.ReadStringArray());
    var reason = ReadOptionalControlledCode(reader.ReadString(), "compatibility_scheduler_claim_invalid");
    return new ChallengeSchedulerClaim(resolution, relatedClockBases, objectDigests, reason);
  }

  private static IReadOnlyList<Sha256Digest> ReadDigests(string?[]? values)
  {
    if (values is null)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_digest_invalid");
    }

    var result = values.Select(ParseDigest)
        .OrderBy(static digest => digest.Hex, StringComparer.Ordinal)
        .ToArray();
    if (result.Distinct().Count() != result.Length)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_object_duplicate");
    }

    return Array.AsReadOnly(result);
  }

  private static IReadOnlyList<ClockBasis> ReadClockBases(string?[]? values, bool allowEmpty)
  {
    if (values is null || (!allowEmpty && values.Length == 0))
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_clock_basis_invalid");
    }

    var result = values.Select(ChallengeEvidenceCodes.ParseClockBasis)
        .OrderBy(ChallengeEvidenceCodes.ClockBasisCode, StringComparer.Ordinal)
        .ToArray();
    if (result.Distinct().Count() != result.Length)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_clock_basis_invalid");
    }

    return Array.AsReadOnly(result);
  }

  private static IReadOnlyList<AssetBundleRole> ReadBundleRoles(string?[]? values)
  {
    if (values is null || values.Length == 0)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_bundle_role_invalid");
    }

    var result = values.Select(ChallengeEvidenceCodes.ParseBundleRole)
        .OrderBy(ChallengeEvidenceCodes.BundleRoleCode, StringComparer.Ordinal)
        .ToArray();
    if (result.Distinct().Count() != result.Length)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_bundle_role_invalid");
    }

    return Array.AsReadOnly(result);
  }

  private static IReadOnlyList<string> ReadControlledCodes(string?[]? values, string errorCode)
  {
    if (values is null || values.Any(static value => !IsControlledCode(value)))
    {
      throw new ChallengeRaidCatalogSourceException(errorCode);
    }

    var result = values.Cast<string>().OrderBy(static value => value, StringComparer.Ordinal).ToArray();
    if (result.Distinct(StringComparer.Ordinal).Count() != result.Length)
    {
      throw new ChallengeRaidCatalogSourceException(errorCode);
    }

    return Array.AsReadOnly(result);
  }

  private static string? ReadOptionalControlledCode(string? value, string errorCode)
  {
    if (value is not null && !IsControlledCode(value))
    {
      throw new ChallengeRaidCatalogSourceException(errorCode);
    }

    return value;
  }

  private static Dictionary<Sha256Digest, ObjectExpectation> BuildObjectExpectations(
      IEnumerable<ChallengeCompatibilityEvidence> evidenceRows)
  {
    var result = new Dictionary<Sha256Digest, ObjectExpectation>();
    foreach (var evidence in evidenceRows)
    {
      if (evidence.Behavior is not null)
      {
        AddExpectation(
            result,
            evidence.Behavior.Sha256,
            new ObjectExpectation(EvidenceObjectKind.Behavior, evidence.Behavior.ByteLength, string.Empty));
      }

      foreach (var timeline in evidence.Timelines)
      {
        AddExpectation(
            result,
            timeline.Sha256,
            new ObjectExpectation(
                EvidenceObjectKind.Timeline,
                timeline.ByteLength,
                string.Join(',', timeline.ClockBases.Select(ChallengeEvidenceCodes.ClockBasisCode))));
      }

      foreach (var bundle in evidence.AssetBundles)
      {
        AddExpectation(
            result,
            bundle.Sha256,
            new ObjectExpectation(
                EvidenceObjectKind.Bundle,
                bundle.ByteLength,
                string.Join(',', bundle.Roles.Select(ChallengeEvidenceCodes.BundleRoleCode))));
      }

      if (evidence.Runtime is not null)
      {
        AddExpectation(
            result,
            evidence.Runtime.Sha256,
            new ObjectExpectation(
                EvidenceObjectKind.Runtime,
                evidence.Runtime.ByteLength,
                evidence.Runtime.LocalBuildLabel));
      }
    }

    return result;
  }

  private static void AddExpectation(
      IDictionary<Sha256Digest, ObjectExpectation> expectations,
      Sha256Digest digest,
      ObjectExpectation expectation)
  {
    if (expectations.TryGetValue(digest, out var existing))
    {
      if (existing != expectation)
      {
        throw new ChallengeRaidCatalogSourceException("compatibility_object_role_invalid");
      }

      return;
    }

    expectations.Add(digest, expectation);
  }

  private static ObjectEntryIdentity ParseObjectEntry(string fullName)
  {
    var segments = fullName.Split('/');
    if (segments.Length != 3 || !string.Equals(segments[0], "objects", StringComparison.Ordinal) ||
        !segments[2].EndsWith(".bin", StringComparison.Ordinal))
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_object_name_invalid");
    }

    var digest = ParseDigest(segments[2][..^4]);
    var kind = segments[1] switch
    {
      "behavior" => EvidenceObjectKind.Behavior,
      "timeline" => EvidenceObjectKind.Timeline,
      "bundle" => EvidenceObjectKind.Bundle,
      "runtime" => EvidenceObjectKind.Runtime,
      _ => throw new ChallengeRaidCatalogSourceException("compatibility_object_role_invalid")
    };
    return new ObjectEntryIdentity(kind, digest);
  }

  private static long RequireByteLength(long value)
  {
    if (value <= 0 || value > ArchiveLimits.MaximumEntryBytes)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_object_length_invalid");
    }

    return value;
  }

  private static Sha256Digest ParseDigest(string? value)
  {
    if (!Sha256Digest.TryParse(value, out var digest))
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_digest_invalid");
    }

    return digest;
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

  private static byte[] ReadSingleEntry(
      IReadOnlyList<ZipArchiveEntry> entries,
      string entryName)
  {
    var matches = entries.Where(entry =>
        string.Equals(entry.FullName, entryName, StringComparison.Ordinal)).ToArray();
    if (matches.Length != 1)
    {
      throw new ChallengeRaidCatalogSourceException("compatibility_manifest_invalid");
    }

    return ZipArchiveGuard.ReadExactly(matches[0]);
  }

  private static Sha256Digest ComputeArchiveHash(Stream source)
  {
    source.Position = 0;
    return Sha256Digest.FromBytes(SHA256.HashData(source));
  }

  private enum EvidenceObjectKind
  {
    Behavior,
    Timeline,
    Bundle,
    Runtime
  }

  private sealed record ObjectExpectation(
      EvidenceObjectKind Kind,
      long ByteLength,
      string SemanticRole);

  private readonly record struct ObjectEntryIdentity(
      EvidenceObjectKind Kind,
      Sha256Digest Digest);
}

internal static class ChallengeEvidenceCodes
{
  public static RaidCompatibilityTier ParseTier(string? value) => value switch
  {
    "static_exact" => RaidCompatibilityTier.StaticExact,
    "behavior_exact" => RaidCompatibilityTier.BehaviorExact,
    "asset_exact_runtime_current" => RaidCompatibilityTier.AssetExactRuntimeCurrent,
    "historical_runtime_exact" => RaidCompatibilityTier.HistoricalRuntimeExact,
    _ => throw new ChallengeRaidCatalogSourceException("compatibility_tier_invalid")
  };

  public static string TierCode(RaidCompatibilityTier value) => value switch
  {
    RaidCompatibilityTier.StaticExact => "static_exact",
    RaidCompatibilityTier.BehaviorExact => "behavior_exact",
    RaidCompatibilityTier.AssetExactRuntimeCurrent => "asset_exact_runtime_current",
    RaidCompatibilityTier.HistoricalRuntimeExact => "historical_runtime_exact",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static RuntimeRelation ParseRuntimeRelation(string? value) => value switch
  {
    "not_evaluated" => RuntimeRelation.NotEvaluated,
    "current_runtime_match" => RuntimeRelation.CurrentRuntimeMatch,
    "historical_runtime_match" => RuntimeRelation.HistoricalRuntimeMatch,
    _ => throw new ChallengeRaidCatalogSourceException("compatibility_runtime_relation_invalid")
  };

  public static string RuntimeRelationCode(RuntimeRelation value) => value switch
  {
    NikkeLocalLab.Domain.Raid.RuntimeRelation.NotEvaluated => "not_evaluated",
    NikkeLocalLab.Domain.Raid.RuntimeRelation.CurrentRuntimeMatch => "current_runtime_match",
    NikkeLocalLab.Domain.Raid.RuntimeRelation.HistoricalRuntimeMatch => "historical_runtime_match",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static ClockBasis ParseClockBasis(string? value) => value switch
  {
    "behavior_tick" => Domain.Raid.ClockBasis.BehaviorTick,
    "render_frame" => Domain.Raid.ClockBasis.RenderFrame,
    "fixed_update" => Domain.Raid.ClockBasis.FixedUpdate,
    "wall_clock" => Domain.Raid.ClockBasis.WallClock,
    _ => throw new ChallengeRaidCatalogSourceException("compatibility_clock_basis_invalid")
  };

  public static string ClockBasisCode(ClockBasis value) => value switch
  {
    NikkeLocalLab.Domain.Raid.ClockBasis.BehaviorTick => "behavior_tick",
    NikkeLocalLab.Domain.Raid.ClockBasis.RenderFrame => "render_frame",
    NikkeLocalLab.Domain.Raid.ClockBasis.FixedUpdate => "fixed_update",
    NikkeLocalLab.Domain.Raid.ClockBasis.WallClock => "wall_clock",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static TimingEvidenceResolution ParseTimingResolution(string? value) => value switch
  {
    "unresolved" => TimingEvidenceResolution.Unresolved,
    "static_analysis" => TimingEvidenceResolution.StaticAnalysis,
    "runtime_trace" => TimingEvidenceResolution.RuntimeTrace,
    _ => throw new ChallengeRaidCatalogSourceException("compatibility_timing_resolution_invalid")
  };

  public static string TimingResolutionCode(TimingEvidenceResolution value) => value switch
  {
    TimingEvidenceResolution.Unresolved => "unresolved",
    TimingEvidenceResolution.StaticAnalysis => "static_analysis",
    TimingEvidenceResolution.RuntimeTrace => "runtime_trace",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };

  public static AssetBundleRole ParseBundleRole(string? value) => value switch
  {
    "stage" => AssetBundleRole.Stage,
    "model" => AssetBundleRole.Model,
    "behavior" => AssetBundleRole.Behavior,
    "timeline" => AssetBundleRole.Timeline,
    "animation" => AssetBundleRole.Animation,
    "audio" => AssetBundleRole.Audio,
    "other" => AssetBundleRole.Other,
    _ => throw new ChallengeRaidCatalogSourceException("compatibility_bundle_role_invalid")
  };

  public static string BundleRoleCode(AssetBundleRole value) => value switch
  {
    AssetBundleRole.Stage => "stage",
    AssetBundleRole.Model => "model",
    AssetBundleRole.Behavior => "behavior",
    AssetBundleRole.Timeline => "timeline",
    AssetBundleRole.Animation => "animation",
    AssetBundleRole.Audio => "audio",
    AssetBundleRole.Other => "other",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}
