using System.Collections.ObjectModel;
using System.Text;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Automation;

public sealed record PatchProjectVersion(string Revision, string Publication);

public sealed class PatchVersionMetadata
{
  private PatchVersionMetadata(string rootRevision, IDictionary<string, PatchProjectVersion> projects,
      Sha256Digest sourceSha256)
  {
    RootRevision = rootRevision;
    Projects = new ReadOnlyDictionary<string, PatchProjectVersion>(projects);
    SourceSha256 = sourceSha256;
  }

  public string RootRevision { get; }
  public IReadOnlyDictionary<string, PatchProjectVersion> Projects { get; }
  public Sha256Digest SourceSha256 { get; }

  public static PatchVersionMetadata Parse(byte[] source)
  {
    ArgumentNullException.ThrowIfNull(source);
    if (source.Length is < 1 or > 65536)
    {
      throw new PipelineManifestException("resource_version_header_size_invalid");
    }

    string text;
    try
    {
      text = new UTF8Encoding(false, true).GetString(source);
    }
    catch (DecoderFallbackException)
    {
      throw new PipelineManifestException("resource_version_header_invalid");
    }

    LegacyVersionHeader.Parse(text);
    var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd('\n').Split('\n');
    var projects = new Dictionary<string, PatchProjectVersion>(StringComparer.Ordinal);
    foreach (var line in lines.Skip(1))
    {
      var parts = line.Split(':', ',');
      // Preserve the publication selector as well as the revision. Legacy Parse
      // intentionally returned only revisions; that loses 151 binding evidence.
      projects.Add(parts[0], new PatchProjectVersion(parts[1], parts[2]));
    }

    return new PatchVersionMetadata(lines[0], projects, Sha256Digest.Compute(source));
  }
}
