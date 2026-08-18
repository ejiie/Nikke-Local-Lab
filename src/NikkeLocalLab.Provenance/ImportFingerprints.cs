namespace NikkeLocalLab.Provenance;

public sealed class ExtractorDescriptor
{
  public ExtractorDescriptor(string extractorId, string extractorVersion, Sha256Digest contractSha256)
  {
    ExtractorId = ControlledCode.Require(extractorId, nameof(extractorId));
    ExtractorVersion = ControlledCode.Require(extractorVersion, nameof(extractorVersion));
    ContractSha256 = contractSha256;

    var canonical = string.Join(
        '\n',
        "nll/extractor-fingerprint/v1",
        $"id={ExtractorId}",
        $"version={ExtractorVersion}",
        $"contract={ContractSha256.Hex}");
    FingerprintSha256 = Sha256Digest.ComputeUtf8(canonical);
  }

  public string ExtractorId { get; }

  public string ExtractorVersion { get; }

  public Sha256Digest ContractSha256 { get; }

  public Sha256Digest FingerprintSha256 { get; }
}

public static class SemanticOptionsFingerprint
{
  public static Sha256Digest Empty { get; } = Sha256Digest.ComputeUtf8(
      "nll/semantic-options/v1\ncount=0");
}

public static class ImportRequestFingerprint
{
  public static Sha256Digest Create(
      Sha256Digest datasetManifestSha256,
      Sha256Digest extractorFingerprintSha256,
      Sha256Digest semanticOptionsSha256)
  {
    var canonical = string.Join(
        '\n',
        "nll/import-request/v1",
        $"dataset={datasetManifestSha256.Hex}",
        $"extractor={extractorFingerprintSha256.Hex}",
        $"options={semanticOptionsSha256.Hex}");
    return Sha256Digest.ComputeUtf8(canonical);
  }
}
