using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class CatalogLinkageProbeTests : IDisposable
{
    private const string Digest = "abcdef0123456789abcdef0123456789";
    private readonly string root = Path.Combine(Path.GetTempPath(), "nll-linkage-test-" + Guid.NewGuid().ToString("N"));
    private readonly SqliteConnection connection = new("Data Source=:memory:;Pooling=False");

    public CatalogLinkageProbeTests()
    {
        Directory.CreateDirectory(Path.Combine(root, "raw"));
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "CREATE TABLE files_rawtype(key TEXT,hash TEXT,extension TEXT,size INTEGER)";
        command.ExecuteNonQuery();
    }

    [Fact]
    public void LogicalKeyResolvesOnlyCatalogHashAndLeavesSourceUnchanged()
    {
        Add("logical.db", Digest.ToUpperInvariant(), ".db", 3);
        var path = Path.Combine(root, "raw", Digest + ".db");
        File.WriteAllBytes(path, [1, 2, 3]);
        Assert.Equal(path, CatalogLinkageProbe.ResolveRawFile(connection, root, "logical.db"));
        Assert.Equal(new byte[] { 1, 2, 3 }, File.ReadAllBytes(path));
        Assert.Single(Directory.GetFiles(Path.Combine(root, "raw")));
    }

    [Fact]
    public void AbsentReferenceCannotResolveToArbitraryRawFile()
    {
        Assert.Equal("resource_inner_catalog_reference_missing", Assert.Throws<PreflightException>(
            () => CatalogLinkageProbe.ResolveRawFile(connection, root, "missing")).Message);
    }

    [Fact]
    public void DuplicateReferencesAreAmbiguousEvenWithIdenticalContent()
    {
        Add("logical", Digest, "db", 3);
        Add("logical", Digest, "db", 3);
        Assert.Equal("resource_inner_catalog_reference_invalid", Assert.Throws<PreflightException>(
            () => CatalogLinkageProbe.ResolveRawFile(connection, root, "logical")).Message);
    }

    [Theory]
    [InlineData("../../escape", "db", 3)]
    [InlineData(Digest, "db/../../escape", 3)]
    [InlineData(Digest, "db", -1)]
    public void InvalidCatalogIdentityCannotFormPath(string hash, string extension, long size)
    {
        Add("logical", hash, extension, size);
        Assert.Equal("resource_inner_catalog_reference_invalid", Assert.Throws<PreflightException>(
            () => CatalogLinkageProbe.ResolveRawFile(connection, root, "logical")).Message);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void MissingOrTruncatedRawFileDoesNotPass(bool createTruncated)
    {
        Add("logical", Digest, "db", 3);
        if (createTruncated) File.WriteAllBytes(Path.Combine(root, "raw", Digest + ".db"), [1, 2]);
        Assert.Equal("resource_inner_catalog_file_missing_or_incomplete", Assert.Throws<PreflightException>(
            () => CatalogLinkageProbe.ResolveRawFile(connection, root, "logical")).Message);
    }

    private void Add(string key, string hash, string extension, long size)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO files_rawtype VALUES($key,$hash,$extension,$size)";
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$hash", hash);
        command.Parameters.AddWithValue("$extension", extension);
        command.Parameters.AddWithValue("$size", size);
        command.ExecuteNonQuery();
    }

    public void Dispose()
    {
        connection.Dispose();
        foreach (var path in Directory.GetFiles(Path.Combine(root, "raw"))) File.Delete(path);
        Directory.Delete(Path.Combine(root, "raw"));
        Directory.Delete(root);
    }
}
