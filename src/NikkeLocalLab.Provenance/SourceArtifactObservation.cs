namespace NikkeLocalLab.Provenance;

public sealed record SourceArtifactObservation
{
  public SourceArtifactObservation(string artifactKind, Sha256Digest contentSha256, long byteLength)
  {
    if (byteLength < 0)
    {
      throw new ArgumentOutOfRangeException(nameof(byteLength));
    }

    ArtifactKind = ControlledCode.Require(artifactKind, nameof(artifactKind));
    ContentSha256 = contentSha256;
    ByteLength = byteLength;
  }

  public string ArtifactKind { get; }

  public Sha256Digest ContentSha256 { get; }

  public long ByteLength { get; }
}
