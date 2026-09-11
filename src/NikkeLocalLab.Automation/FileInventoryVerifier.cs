using System.Collections.ObjectModel;
using System.Globalization;
using System.Text;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public enum ArtifactMatchStatus
{
  Matched,
  Missing,
  LengthMismatch,
  DigestMismatch
}

public sealed record ArtifactObservation(
    string RoleCode,
    long? ObservedByteLength,
    Sha256Digest? ObservedSha256,
    ArtifactMatchStatus Status);

public sealed class InventoryObservationSet
{
  public InventoryObservationSet(IEnumerable<ArtifactObservation> observations)
  {
    Observations = Array.AsReadOnly(observations.ToArray());
    AllMatched = Observations.All(static observation => observation.Status == ArtifactMatchStatus.Matched);
    CanonicalSha256 = ComputeHash(Observations);
  }

  public IReadOnlyList<ArtifactObservation> Observations { get; }

  public bool AllMatched { get; }

  public Sha256Digest CanonicalSha256 { get; }

  private static Sha256Digest ComputeHash(IEnumerable<ArtifactObservation> observations)
  {
    var canonical = new StringBuilder("nll/pipeline-inventory-observation-set/v1\n");
    foreach (var item in observations.OrderBy(static item => item.RoleCode, StringComparer.Ordinal))
    {
      canonical.Append(item.RoleCode).Append('\t')
          .Append(item.ObservedByteLength?.ToString(CultureInfo.InvariantCulture) ?? "null").Append('\t')
          .Append(item.ObservedSha256?.Hex ?? "null").Append('\t')
          .Append(StatusCode(item.Status)).Append('\n');
    }

    return Sha256Digest.ComputeUtf8(canonical.ToString());
  }

  public static string StatusCode(ArtifactMatchStatus value) => value switch
  {
    ArtifactMatchStatus.Matched => "matched",
    ArtifactMatchStatus.Missing => "missing",
    ArtifactMatchStatus.LengthMismatch => "length_mismatch",
    ArtifactMatchStatus.DigestMismatch => "digest_mismatch",
    _ => throw new ArgumentOutOfRangeException(nameof(value))
  };
}

public static class FileInventoryVerifier
{
  public static async Task<InventoryObservationSet> ObserveAsync(
      PipelineRunManifest manifest,
      string inventoryRoot,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    var root = Path.GetFullPath(inventoryRoot ?? throw new ArgumentNullException(nameof(inventoryRoot)));
    if (!Directory.Exists(root))
    {
      throw new DirectoryNotFoundException("The pipeline inventory root does not exist.");
    }
    RequirePlainPath(root);

    var boundary = root.EndsWith(Path.DirectorySeparatorChar)
        ? root
        : root + Path.DirectorySeparatorChar;
    var observations = new List<ArtifactObservation>(manifest.Inputs.Count);
    foreach (var input in manifest.Inputs)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var path = Path.GetFullPath(Path.Combine(root, input.RelativePath.Replace('/', Path.DirectorySeparatorChar)));
      if (!path.StartsWith(boundary, StringComparison.OrdinalIgnoreCase))
      {
        throw new PipelineManifestException("pipeline_input_path_escaped_root");
      }
      RequirePlainPath(path);

      if (!File.Exists(path))
      {
        observations.Add(new ArtifactObservation(input.RoleCode, null, null, ArtifactMatchStatus.Missing));
        continue;
      }

      var length = new FileInfo(path).Length;
      if (length != input.ByteLength)
      {
        observations.Add(new ArtifactObservation(input.RoleCode, length, null, ArtifactMatchStatus.LengthMismatch));
        continue;
      }

      await using var stream = new FileStream(
          path,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read,
          1024 * 128,
          FileOptions.Asynchronous | FileOptions.SequentialScan);
      var digest = await Sha256Digest.ComputeAsync(stream, cancellationToken).ConfigureAwait(false);
      observations.Add(new ArtifactObservation(
          input.RoleCode,
          length,
          digest,
          digest == input.Sha256 ? ArtifactMatchStatus.Matched : ArtifactMatchStatus.DigestMismatch));
    }

    return new InventoryObservationSet(observations);
  }

  private static void RequirePlainPath(string path)
  {
    // A lexical root check does not constrain a junction/symlink target. Check
    // every existing ancestor before opening bytes, including the root itself.
    // Concurrent hostile reparse replacement remains outside the local threat model.
    for (string? current = path; current is not null; current = Path.GetDirectoryName(current))
    {
      if ((File.Exists(current) || Directory.Exists(current)) &&
          (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
        throw new PipelineManifestException("pipeline_input_reparse_rejected");
    }
  }
}
