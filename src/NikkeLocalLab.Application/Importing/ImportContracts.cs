using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.Importing;

public interface IImportArtifactSource
{
  Task<SourceArtifactObservation> ObserveAsync(CancellationToken cancellationToken = default);

  Task<T> ReadAsync<T>(
      Func<Stream, CancellationToken, Task<T>> reader,
      CancellationToken cancellationToken = default);
}

public interface IImportExtractor
{
  ExtractorDescriptor Descriptor { get; }

  Task<ExtractionResult> ExtractAsync(Stream source, CancellationToken cancellationToken = default);
}

public sealed record ExtractionResult(byte[] CanonicalOutput, IReadOnlyList<SafeDiagnostic> Diagnostics)
{
  public static ExtractionResult Create(byte[] canonicalOutput, params SafeDiagnostic[] diagnostics)
  {
    ArgumentNullException.ThrowIfNull(canonicalOutput);
    return new ExtractionResult(canonicalOutput, diagnostics ?? []);
  }
}

public enum ImportDiagnosticSeverity
{
  Info,
  Warning,
  Error
}

public static class ImportDiagnosticCatalog
{
  private static readonly HashSet<string> StageCodes = new(StringComparer.Ordinal)
    {
        "catalog",
        "combat_support_catalog",
        "extract",
        "raid_catalog",
        "source"
    };

  private static readonly HashSet<string> DiagnosticCodes = new(StringComparer.Ordinal)
    {
        "character_progression_unresolved",
        "character_skill_unresolved",
        "character_variant_conflict",
        "character_weapon_unresolved",
        "collection_weapon_class_unknown",
        "combat_stat_unknown",
        "cube_stat_unit_unresolved",
        "affinity_unresolved",
        "authoritative_challenge_chain_unresolved",
        "behavior_evidence_unresolved",
        "compatibility_evidence_unmatched",
        "compatibility_static_binding_mismatch",
        "cube_maximum_unresolved",
        "excluded_by_policy",
        "fixture_kind_invalid",
        "favorite_character_relation_unresolved",
        "monster_skill_relations_unresolved",
        "part_topology_unresolved",
        "part_type_unresolved",
        "source_changed_during_import",
        "skill_definition_catalog_not_imported",
        "spot_behavior_unresolved",
        "synthetic_parse_failed",
        "unsupported_by_policy",
        "overload_duplicate_policy_unresolved"
    };

  public static string RequireStageCode(string value) =>
      RequireKnown(value, StageCodes, nameof(value));

  public static string RequireDiagnosticCode(string value) =>
      RequireKnown(value, DiagnosticCodes, nameof(value));

  private static string RequireKnown(string value, HashSet<string> catalog, string parameterName)
  {
    var controlled = ControlledCode.Require(value, parameterName);
    if (!catalog.Contains(controlled))
    {
      throw new ArgumentException("The import diagnostic code is not in the controlled catalog.", parameterName);
    }

    return controlled;
  }
}

public sealed record SafeDiagnostic
{
  public SafeDiagnostic(
      ImportDiagnosticSeverity severity,
      string stageCode,
      string diagnosticCode,
      int occurrenceCount = 1)
  {
    if (occurrenceCount < 1)
    {
      throw new ArgumentOutOfRangeException(nameof(occurrenceCount));
    }

    Severity = severity;
    StageCode = ImportDiagnosticCatalog.RequireStageCode(stageCode);
    DiagnosticCode = ImportDiagnosticCatalog.RequireDiagnosticCode(diagnosticCode);
    OccurrenceCount = occurrenceCount;
  }

  public ImportDiagnosticSeverity Severity { get; }

  public string StageCode { get; }

  public string DiagnosticCode { get; }

  public int OccurrenceCount { get; }
}

public sealed class SafeImportFailureException : Exception
{
  public SafeImportFailureException(string stageCode, string diagnosticCode)
      : base("The import extractor reported a controlled failure.")
  {
    StageCode = ImportDiagnosticCatalog.RequireStageCode(stageCode);
    DiagnosticCode = ImportDiagnosticCatalog.RequireDiagnosticCode(diagnosticCode);
  }

  public string StageCode { get; }

  public string DiagnosticCode { get; }
}

public sealed record ArtifactRegistration(
    EntityUid CandidateArtifactUid,
    CanonicalDatasetArtifact ManifestArtifact);

public sealed record CompletedImportAttempt(
    EntityUid ImportRunUid,
    EntityUid CandidateDatasetSnapshotUid,
    IReadOnlyList<ArtifactRegistration> Artifacts,
    CanonicalDatasetManifest DatasetManifest,
    ExtractorDescriptor Extractor,
    Sha256Digest SemanticOptionsSha256,
    Sha256Digest RequestSha256,
    Sha256Digest OutputManifestSha256,
    IReadOnlyList<SafeDiagnostic> Diagnostics,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset FinishedAtUtc);

public sealed record FailedImportAttempt(
    EntityUid ImportRunUid,
    IReadOnlyList<ArtifactRegistration> Artifacts,
    CanonicalDatasetManifest DatasetManifest,
    ExtractorDescriptor Extractor,
    Sha256Digest SemanticOptionsSha256,
    Sha256Digest RequestSha256,
    SafeDiagnostic Diagnostic,
    DateTimeOffset StartedAtUtc,
    DateTimeOffset FinishedAtUtc);

public enum ImportReceiptStatus
{
  Succeeded,
  Reused,
  Failed
}

public sealed record ImportReceipt(
    EntityUid ImportRunUid,
    EntityUid? DatasetSnapshotUid,
    IReadOnlyList<EntityUid> SourceArtifactUids,
    Sha256Digest DatasetManifestSha256,
    Sha256Digest? OutputManifestSha256,
    ImportReceiptStatus Status,
    IReadOnlyList<string> DiagnosticCodes);

public interface IImportLedger
{
  Task<ImportReceipt> RecordCompletedAsync(
      CompletedImportAttempt attempt,
      CancellationToken cancellationToken = default);

  Task<ImportReceipt> RecordFailedAsync(
      FailedImportAttempt attempt,
      CancellationToken cancellationToken = default);
}
