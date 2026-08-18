using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.UnitTests;

internal sealed class TemporaryDirectory : IDisposable
{
  public TemporaryDirectory()
  {
    Path = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(),
        "nikke-local-lab-tests",
        Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(Path);
  }

  public string Path { get; }

  public string CreateDirectory(string relativePath)
  {
    var path = System.IO.Path.Combine(Path, relativePath);
    Directory.CreateDirectory(path);
    return path;
  }

  public void Dispose()
  {
    if (Directory.Exists(Path))
    {
      Directory.Delete(Path, recursive: true);
    }
  }
}

internal sealed class InMemoryImportLedger : IImportLedger
{
  private readonly object _gate = new();
  private readonly Dictionary<string, (EntityUid Uid, string Kind, long Length)> _artifacts = new(StringComparer.Ordinal);
  private readonly Dictionary<string, (EntityUid Uid, string Membership)> _snapshots = new(StringComparer.Ordinal);
  private readonly Dictionary<string, (EntityUid RunUid, Sha256Digest Output)> _successfulRequests = new(StringComparer.Ordinal);
  private readonly List<ImportReceipt> _receipts = [];

  public IReadOnlyList<ImportReceipt> Receipts
  {
    get
    {
      lock (_gate)
      {
        return _receipts.ToArray();
      }
    }
  }

  public int ArtifactCount => _artifacts.Count;

  public int SnapshotCount => _snapshots.Count;

  public Task<ImportReceipt> RecordCompletedAsync(
      CompletedImportAttempt attempt,
      CancellationToken cancellationToken = default)
  {
    lock (_gate)
    {
      var artifactUids = RegisterArtifacts(attempt.Artifacts);
      var snapshotUid = RegisterSnapshot(
          attempt.CandidateDatasetSnapshotUid,
          attempt.DatasetManifest,
          artifactUids);
      var requestKey = attempt.RequestSha256.Hex;
      var status = ImportReceiptStatus.Succeeded;
      if (_successfulRequests.TryGetValue(requestKey, out var existing))
      {
        if (existing.Output != attempt.OutputManifestSha256)
        {
          throw new InvalidOperationException("extractor_nondeterministic_output");
        }

        status = ImportReceiptStatus.Reused;
      }
      else
      {
        _successfulRequests.Add(requestKey, (attempt.ImportRunUid, attempt.OutputManifestSha256));
      }

      var receipt = new ImportReceipt(
          attempt.ImportRunUid,
          snapshotUid,
          artifactUids,
          attempt.DatasetManifest.CanonicalSha256,
          attempt.OutputManifestSha256,
          status,
          attempt.Diagnostics.Select(item => item.DiagnosticCode).ToArray());
      _receipts.Add(receipt);
      return Task.FromResult(receipt);
    }
  }

  public Task<ImportReceipt> RecordFailedAsync(
      FailedImportAttempt attempt,
      CancellationToken cancellationToken = default)
  {
    lock (_gate)
    {
      var artifactUids = RegisterArtifacts(attempt.Artifacts);
      var receipt = new ImportReceipt(
          attempt.ImportRunUid,
          null,
          artifactUids,
          attempt.DatasetManifest.CanonicalSha256,
          null,
          ImportReceiptStatus.Failed,
          [attempt.Diagnostic.DiagnosticCode]);
      _receipts.Add(receipt);
      return Task.FromResult(receipt);
    }
  }

  public string SafeProjectionJson()
  {
    lock (_gate)
    {
      return JsonSerializer.Serialize(new
      {
        artifacts = _artifacts.Select(item => new
        {
          sha256 = item.Key,
          uid = item.Value.Uid.ToString(),
          kind = item.Value.Kind,
          byteLength = item.Value.Length
        }),
        snapshots = _snapshots.Select(item => new
        {
          sha256 = item.Key,
          uid = item.Value.Uid.ToString()
        }),
        runs = _receipts
      });
    }
  }

  private IReadOnlyList<EntityUid> RegisterArtifacts(IReadOnlyList<ArtifactRegistration> registrations)
  {
    var result = new List<EntityUid>(registrations.Count);
    foreach (var registration in registrations.OrderBy(item => item.ManifestArtifact.Ordinal))
    {
      var observation = registration.ManifestArtifact.Artifact;
      if (_artifacts.TryGetValue(observation.ContentSha256.Hex, out var existing))
      {
        if (!string.Equals(existing.Kind, observation.ArtifactKind, StringComparison.Ordinal) ||
            existing.Length != observation.ByteLength)
        {
          throw new InvalidOperationException("artifact_digest_collision");
        }

        result.Add(existing.Uid);
      }
      else
      {
        _artifacts.Add(
            observation.ContentSha256.Hex,
            (registration.CandidateArtifactUid, observation.ArtifactKind, observation.ByteLength));
        result.Add(registration.CandidateArtifactUid);
      }
    }

    return result;
  }

  private EntityUid RegisterSnapshot(
      EntityUid candidateUid,
      CanonicalDatasetManifest manifest,
      IReadOnlyList<EntityUid> artifactUids)
  {
    var membership = string.Join(
        "\n",
        manifest.Artifacts.Select((item, index) =>
            $"{item.RoleCode}\t{item.Ordinal}\t{artifactUids[index]}"));
    if (_snapshots.TryGetValue(manifest.CanonicalSha256.Hex, out var existing))
    {
      if (!string.Equals(existing.Membership, membership, StringComparison.Ordinal))
      {
        throw new InvalidOperationException("snapshot_membership_mismatch");
      }

      return existing.Uid;
    }

    _snapshots.Add(manifest.CanonicalSha256.Hex, (candidateUid, membership));
    return candidateUid;
  }
}

internal sealed class SyntheticFixtureExtractor : IImportExtractor
{
  private static readonly byte[] SyntheticSecret = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();

  public ExtractorDescriptor Descriptor { get; } = new(
      "synthetic_fixture",
      "v1",
      Sha256Digest.ComputeUtf8("nll/synthetic-fixture-contract/v1"));

  public async Task<ExtractionResult> ExtractAsync(
      Stream source,
      CancellationToken cancellationToken = default)
  {
    using var document = await JsonDocument.ParseAsync(source, cancellationToken: cancellationToken).ConfigureAwait(false);
    var root = document.RootElement;
    if (root.GetProperty("fixtureKind").GetString() != "phase1a-catalog")
    {
      throw new SafeImportFailureException("extract", "fixture_kind_invalid");
    }

    var entities = root.GetProperty("entities")
        .EnumerateArray()
        .Select(entity => new
        {
          entityUid = SourceIdentityEncoder.Encode(
                SyntheticSecret,
                "phase1a.synthetic",
                entity.GetProperty("kind").GetString()!,
                entity.GetProperty("sourceAlias").GetString()!).ToString(),
          kind = entity.GetProperty("kind").GetString(),
          label = entity.GetProperty("label").GetString()
        })
        .OrderBy(entity => entity.entityUid, StringComparer.Ordinal)
        .ToArray();
    var canonical = JsonSerializer.SerializeToUtf8Bytes(new
    {
      schemaVersion = 1,
      entities
    });
    return ExtractionResult.Create(canonical);
  }
}

internal sealed class ControlledFailureExtractor : IImportExtractor
{
  public ExtractorDescriptor Descriptor { get; } = new(
      "synthetic_failure",
      "v1",
      Sha256Digest.ComputeUtf8("nll/synthetic-failure-contract/v1"));

  public Task<ExtractionResult> ExtractAsync(Stream source, CancellationToken cancellationToken = default)
  {
    throw new SafeImportFailureException("extract", "synthetic_parse_failed");
  }
}
