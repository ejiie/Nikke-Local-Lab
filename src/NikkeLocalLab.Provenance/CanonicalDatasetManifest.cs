using System.Globalization;
using System.Text;

namespace NikkeLocalLab.Provenance;

public sealed record DatasetArtifactInput(
    string RoleCode,
    SourceArtifactObservation Artifact);

public sealed record CanonicalDatasetArtifact(
    int Ordinal,
    string RoleCode,
    SourceArtifactObservation Artifact);

public sealed class CanonicalDatasetManifest
{
  private CanonicalDatasetManifest(
      IReadOnlyList<CanonicalDatasetArtifact> artifacts,
      string canonicalText,
      Sha256Digest canonicalSha256)
  {
    Artifacts = artifacts;
    CanonicalText = canonicalText;
    CanonicalSha256 = canonicalSha256;
  }

  public IReadOnlyList<CanonicalDatasetArtifact> Artifacts { get; }

  public string CanonicalText { get; }

  public Sha256Digest CanonicalSha256 { get; }

  public static CanonicalDatasetManifest Create(IEnumerable<DatasetArtifactInput> inputs)
  {
    ArgumentNullException.ThrowIfNull(inputs);

    var normalized = inputs
        .Select(input => new DatasetArtifactInput(
            ControlledCode.Require(input.RoleCode, nameof(input.RoleCode)),
            input.Artifact ?? throw new ArgumentException("A dataset artifact is required.", nameof(inputs))))
        .OrderBy(input => input.RoleCode, StringComparer.Ordinal)
        .ThenBy(input => input.Artifact.ArtifactKind, StringComparer.Ordinal)
        .ThenBy(input => input.Artifact.ContentSha256.Hex, StringComparer.Ordinal)
        .ThenBy(input => input.Artifact.ByteLength)
        .ToArray();

    if (normalized.Length == 0)
    {
      throw new ArgumentException("A dataset manifest must contain at least one artifact.", nameof(inputs));
    }

    var duplicateCount = normalized
        .GroupBy(
            input => $"{input.RoleCode}\0{input.Artifact.ArtifactKind}\0{input.Artifact.ContentSha256.Hex}\0{input.Artifact.ByteLength}",
            StringComparer.Ordinal)
        .Any(group => group.Count() > 1);
    if (duplicateCount)
    {
      throw new ArgumentException("A dataset manifest cannot contain duplicate artifact tuples.", nameof(inputs));
    }

    var canonicalArtifacts = normalized
        .Select((input, index) => new CanonicalDatasetArtifact(index, input.RoleCode, input.Artifact))
        .ToArray();

    var lines = new List<string>(canonicalArtifacts.Length + 2)
        {
            "nll/dataset-input-manifest/v1",
            $"count={canonicalArtifacts.Length.ToString(CultureInfo.InvariantCulture)}"
        };

    lines.AddRange(canonicalArtifacts.Select(item => string.Join(
        '\t',
        item.RoleCode,
        item.Artifact.ArtifactKind,
        item.Artifact.ContentSha256.Hex,
        item.Artifact.ByteLength.ToString(CultureInfo.InvariantCulture))));

    var canonicalText = string.Join('\n', lines);
    return new CanonicalDatasetManifest(
        canonicalArtifacts,
        canonicalText,
        Sha256Digest.Compute(Encoding.UTF8.GetBytes(canonicalText)));
  }
}
