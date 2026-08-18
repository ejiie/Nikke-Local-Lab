using System.Security.Cryptography;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.Importing;

public sealed class ImportCoordinator
{
  private readonly IImportLedger _ledger;
  private readonly IEntityUidGenerator _uidGenerator;
  private readonly TimeProvider _timeProvider;

  public ImportCoordinator(
      IImportLedger ledger,
      IEntityUidGenerator uidGenerator,
      TimeProvider? timeProvider = null)
  {
    _ledger = ledger ?? throw new ArgumentNullException(nameof(ledger));
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
    _timeProvider = timeProvider ?? TimeProvider.System;
  }

  public async Task<ImportReceipt> ImportSingleAsync(
      IImportArtifactSource source,
      string roleCode,
      IImportExtractor extractor,
      Sha256Digest? semanticOptionsSha256 = null,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(source);
    ArgumentNullException.ThrowIfNull(extractor);

    var startedAt = _timeProvider.GetUtcNow();
    var runUid = _uidGenerator.NewUid();
    var firstObservation = await source.ObserveAsync(cancellationToken).ConfigureAwait(false);
    var manifest = CanonicalDatasetManifest.Create(
    [
        new DatasetArtifactInput(roleCode, firstObservation)
    ]);
    var optionsSha256 = semanticOptionsSha256 ?? SemanticOptionsFingerprint.Empty;
    var requestSha256 = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.Descriptor.FingerprintSha256,
        optionsSha256);
    var artifacts = manifest.Artifacts
        .Select(item => new ArtifactRegistration(_uidGenerator.NewUid(), item))
        .ToArray();

    byte[]? canonicalOutput = null;
    try
    {
      var extraction = await source
          .ReadAsync(extractor.ExtractAsync, cancellationToken)
          .ConfigureAwait(false);
      canonicalOutput = extraction.CanonicalOutput;

      var finalObservation = await source.ObserveAsync(cancellationToken).ConfigureAwait(false);
      if (firstObservation != finalObservation)
      {
        throw new SafeImportFailureException("source", "source_changed_during_import");
      }

      var outputManifestSha256 = Sha256Digest.Compute(canonicalOutput);
      var completed = new CompletedImportAttempt(
          runUid,
          _uidGenerator.NewUid(),
          artifacts,
          manifest,
          extractor.Descriptor,
          optionsSha256,
          requestSha256,
          outputManifestSha256,
          extraction.Diagnostics,
          startedAt,
          _timeProvider.GetUtcNow());

      return await _ledger.RecordCompletedAsync(completed, cancellationToken).ConfigureAwait(false);
    }
    catch (SafeImportFailureException failure)
    {
      var diagnostic = new SafeDiagnostic(
          ImportDiagnosticSeverity.Error,
          failure.StageCode,
          failure.DiagnosticCode);
      var failed = new FailedImportAttempt(
          runUid,
          artifacts,
          manifest,
          extractor.Descriptor,
          optionsSha256,
          requestSha256,
          diagnostic,
          startedAt,
          _timeProvider.GetUtcNow());
      return await _ledger.RecordFailedAsync(failed, cancellationToken).ConfigureAwait(false);
    }
    finally
    {
      if (canonicalOutput is not null)
      {
        CryptographicOperations.ZeroMemory(canonicalOutput);
      }
    }
  }
}
