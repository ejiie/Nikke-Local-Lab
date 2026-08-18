using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.UnitTests;

public sealed class ProvenanceTests
{
  [Fact]
  public void SourceIdentityUsesUnambiguousLengthPrefixedComponents()
  {
    var secret = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();

    var first = SourceIdentityEncoder.Encode(secret, "alpha\0beta", "gamma", "delta");
    var same = SourceIdentityEncoder.Encode(secret, "alpha\0beta", "gamma", "delta");
    var oldDelimiterCollision = SourceIdentityEncoder.Encode(secret, "alpha", "beta\0gamma", "delta");

    Assert.Equal(first, same);
    Assert.NotEqual(first, oldDelimiterCollision);
    Assert.Throws<EncoderFallbackException>(() =>
        SourceIdentityEncoder.Encode(secret, "alpha", "gamma", "\ud800"));
  }

  [Fact]
  public void Sha256DigestUsesLowercaseCanonicalHex()
  {
    var digest = Sha256Digest.Compute(Encoding.UTF8.GetBytes("abc"));

    Assert.Equal("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest.Hex);
    Assert.Equal(digest, Sha256Digest.Parse(digest.Hex));
    Assert.Throws<FormatException>(() => Sha256Digest.Parse(digest.Hex.ToUpperInvariant()));
  }

  [Fact]
  public void DatasetManifestIsOrderInvariantAndPathFree()
  {
    var first = new SourceArtifactObservation("synthetic_catalog", Sha256Digest.ComputeUtf8("alpha"), 5);
    var second = new SourceArtifactObservation("synthetic_catalog", Sha256Digest.ComputeUtf8("beta"), 4);

    var forward = CanonicalDatasetManifest.Create(
    [
        new DatasetArtifactInput("secondary", second),
      new DatasetArtifactInput("primary", first)
    ]);
    var reverse = CanonicalDatasetManifest.Create(
    [
        new DatasetArtifactInput("primary", first),
      new DatasetArtifactInput("secondary", second)
    ]);

    Assert.Equal(forward.CanonicalText, reverse.CanonicalText);
    Assert.Equal(forward.CanonicalSha256, reverse.CanonicalSha256);
    Assert.Equal("b3dd7aa625a4cd185b81def8addf318555be84952556403910abb706827e6ffd", forward.CanonicalSha256.Hex);
    Assert.DoesNotContain("\\", forward.CanonicalText, StringComparison.Ordinal);
    Assert.DoesNotContain("C:\\", forward.CanonicalText, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("/home/", forward.CanonicalText, StringComparison.Ordinal);
    Assert.False(forward.CanonicalText.EndsWith('\n'));
  }

  [Fact]
  public void ExtractorVersionChangesRequestFingerprintWithoutChangingDataset()
  {
    var artifact = new SourceArtifactObservation("synthetic_catalog", Sha256Digest.ComputeUtf8("alpha"), 5);
    var manifest = CanonicalDatasetManifest.Create([new DatasetArtifactInput("primary", artifact)]);
    var v1 = new ExtractorDescriptor("synthetic_fixture", "v1", Sha256Digest.ComputeUtf8("contract"));
    var v2 = new ExtractorDescriptor("synthetic_fixture", "v2", Sha256Digest.ComputeUtf8("contract"));

    var requestV1 = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        v1.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var requestV2 = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        v2.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);

    Assert.NotEqual(requestV1, requestV2);
  }
}
