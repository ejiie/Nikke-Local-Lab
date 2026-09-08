using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class PairValidationTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "nll-resource-test-" + Guid.NewGuid().ToString("N"));
    public PairValidationTests() => Directory.CreateDirectory(root);

    [Fact]
    public void MissingSelectedCatalogFailsBeforeDecoding()
    {
        Assert.Equal("resource_catalog_body_missing", Assert.Throws<PreflightException>(
            () => new CatalogDatabase(Path.Combine(root, "body"), Path.Combine(root, "signature"))).Message);
    }

    [Fact]
    public void MissingDetachedSignatureIsDistinctFromMissingBody()
    {
        File.WriteAllBytes(Path.Combine(root, "body"), new byte[80]);
        Assert.Equal("resource_catalog_signature_missing", Assert.Throws<PreflightException>(
            () => new CatalogDatabase(Path.Combine(root, "body"), Path.Combine(root, "signature"))).Message);
    }

    [Theory]
    [InlineData(0, 96)]
    [InlineData(12, 96)]
    [InlineData(40, 0)]
    [InlineData(40, 95)]
    [InlineData(40, 97)]
    public void ZeroByteAndPartialPairsCannotPass(int bodyLength, int signatureLength)
    {
        File.WriteAllBytes(Path.Combine(root, "body"), new byte[bodyLength]);
        File.WriteAllBytes(Path.Combine(root, "signature"), new byte[signatureLength]);
        Assert.Equal("resource_catalog_pair_shape_invalid", Assert.Throws<PreflightException>(
            () => new CatalogDatabase(Path.Combine(root, "body"), Path.Combine(root, "signature"))).Message);
    }

    [Fact]
    public void SameExtensionDoesNotMakeAnUnknownContainerSupported()
    {
        File.WriteAllBytes(Path.Combine(root, "body"), new byte[64]);
        File.WriteAllBytes(Path.Combine(root, "signature"), new byte[96]);
        Assert.Equal("resource_catalog_container_unsupported", Assert.Throws<PreflightException>(
            () => new CatalogDatabase(Path.Combine(root, "body"), Path.Combine(root, "signature"))).Message);
    }

    [Fact]
    public void UnreasonableNkdbDimensionsAreRejected()
    {
        var body = new byte[64];
        new byte[] { 78, 75, 68, 66, 0, 0, 0, 1 }.CopyTo(body, 0);
        Array.Fill(body, (byte)255, 24, 8);
        File.WriteAllBytes(Path.Combine(root, "body"), body);
        File.WriteAllBytes(Path.Combine(root, "signature"), new byte[96]);
        Assert.Equal("resource_catalog_dimensions_invalid", Assert.Throws<PreflightException>(
            () => new CatalogDatabase(Path.Combine(root, "body"), Path.Combine(root, "signature"))).Message);
    }

    public void Dispose()
    {
        foreach (var file in Directory.GetFiles(root)) File.Delete(file);
        Directory.Delete(root);
    }
}
