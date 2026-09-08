using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class ProbeServerLocalesTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "nll-server-locale-test-" + Guid.NewGuid().ToString("D"));
  private readonly SqliteConnection connection = new("Data Source=:memory:;Pooling=False");
  public ProbeServerLocalesTests()
  {
    Directory.CreateDirectory(Path.Combine(root, "raw"));
    connection.Open();
    using var command = connection.CreateCommand();
    command.CommandText = "CREATE TABLE files_rawtype(key TEXT,hash BLOB,extension TEXT,size INTEGER)";
    command.ExecuteNonQuery();
  }
  [Fact]
  public void ExactFourInputsAreSelectedWithoutChangingBytesOrUsingVoiceCatalogs()
  {
    foreach (var name in ProbeServerLocales.RequiredNames) Add("lss/" + name);
    Add("lss/Unrelated.lsc");
    var members = ProbeServerLocales.Inspect(connection, root);
    Assert.Equal(ProbeServerLocales.RequiredNames, members.Select(member => member.Name));
    Assert.Equal(5, Directory.GetFiles(Path.Combine(root, "raw")).Length);
    Assert.All(members, member => Assert.StartsWith(Path.Combine(root, "raw"), member.SourcePath));
  }
  [Fact]
  public void MissingOrAmbiguousLocaleFailsClosed()
  {
    Assert.Throws<PreflightException>(() => ProbeServerLocales.Inspect(connection, root));
    foreach (var name in ProbeServerLocales.RequiredNames) Add(name);
    Add("other/" + ProbeServerLocales.RequiredNames[0]);
    Assert.Equal("resource_server_locale_ambiguous", Assert.Throws<PreflightException>(
        () => ProbeServerLocales.Inspect(connection, root)).Message);
  }
  [Theory]
  [InlineData("../Locale_Bgm.lsc")]
  [InlineData("a/../Locale_Bgm.lsc")]
  [InlineData("a//Locale_Bgm.lsc")]
  public void MalformedReferenceIsNotNormalized(string key)
  {
    Add(key);
    Assert.Throws<PreflightException>(() => ProbeServerLocales.Inspect(connection, root));
  }
  [Fact]
  public void ChangedRawContentFailsItsCatalogDigest()
  {
    var path = Add("Locale_Bgm.lsc");
    var bytes = File.ReadAllBytes(path);
    bytes[^1] ^= 1;
    File.WriteAllBytes(path, bytes);
    Assert.Equal("resource_patch_raw_digest_mismatch", Assert.Throws<PreflightException>(
        () => ProbeServerLocales.Inspect(connection, root)).Message);
  }
  private string Add(string key)
  {
    var bytes = new byte[256];
    "NKDB"u8.CopyTo(bytes);
    System.Text.Encoding.UTF8.GetBytes(key).CopyTo(bytes, 16);
    using var stream = new MemoryStream(bytes);
    var hash = SegmentedSpookyHash.Compute(stream, stream.Length);
    var path = Path.Combine(root, "raw", Convert.ToHexString(hash).ToLowerInvariant() + ".lsc");
    File.WriteAllBytes(path, bytes);
    using var command = connection.CreateCommand();
    command.CommandText = "INSERT INTO files_rawtype VALUES($key,$hash,'lsc',$size)";
    command.Parameters.AddWithValue("$key", key);
    command.Parameters.AddWithValue("$hash", hash);
    command.Parameters.AddWithValue("$size", bytes.Length);
    command.ExecuteNonQuery();
    return path;
  }
  public void Dispose()
  {
    connection.Dispose();
    if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
        !Path.GetFileName(root).StartsWith("nll-server-locale-test-", StringComparison.Ordinal) ||
        (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0)
      throw new InvalidOperationException("synthetic_fixture_cleanup_boundary_invalid");
    Directory.Delete(root, recursive: true);
  }
}
