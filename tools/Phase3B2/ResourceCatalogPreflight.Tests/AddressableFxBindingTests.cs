using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class AddressableFxBindingTests : IDisposable
{
  private readonly SqliteConnection db = new("Data Source=:memory:;Pooling=False");

  public AddressableFxBindingTests()
  {
    db.Open();
    Sql("""
        CREATE TABLE keys(key TEXT);
        CREATE TABLE key_entries(key_rowid INTEGER,entry_rowid INTEGER);
        CREATE TABLE entries(internal_id_rowid INTEGER,provider_id_rowid INTEGER,dependency_key_rowid INTEGER,data_rowid INTEGER);
        CREATE TABLE internal_ids(internal_id TEXT);
        CREATE TABLE provider_ids(provider_id TEXT);
        CREATE TABLE entry_data(is_local INTEGER);
        INSERT INTO keys VALUES('synthetic/shield.prefab'),('synthetic-dependency');
        INSERT INTO key_entries VALUES(1,1),(2,2),(2,3);
        INSERT INTO entries VALUES(1,1,2,NULL),(2,2,NULL,1),(3,2,NULL,2);
        INSERT INTO internal_ids VALUES('synthetic/shield.prefab'),('synthetic-current.bundle'),('synthetic-local.bundle');
        INSERT INTO provider_ids VALUES('UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider'),
        ('UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider');
        INSERT INTO entry_data VALUES(0),(1);
        CREATE TABLE files_chunktype(file_id INTEGER,key TEXT);
        CREATE TABLE chunk_file_map(file_id INTEGER,chunk_id INTEGER,file_offset INTEGER);
        CREATE TABLE chunks(chunk_id INTEGER,hash BLOB,original_size INTEGER,compressed_size INTEGER);
        INSERT INTO files_chunktype VALUES(7,'synthetic-current.bundle'),(8,'synthetic-other.bundle');
        INSERT INTO chunk_file_map VALUES(7,1,0),(7,2,3),(8,3,0);
        INSERT INTO chunks VALUES(1,zeroblob(16),3,2),(2,zeroblob(16),2,2),(3,zeroblob(16),999,2);
        """);
  }

  [Fact]
  public void ExactKeyUsesCurrentBundleAndPreservesLocalDependencies()
  {
    var binding = Resolve();
    Assert.Equal("synthetic/shield.prefab", binding.AssetKey);
    Assert.Equal(new[] { new AddressableFxBinding.Dependency("synthetic-current.bundle", false),
      new AddressableFxBinding.Dependency("synthetic-local.bundle", true) }, binding.Dependencies);
  }

  [Fact]
  public void PrefabAliasResolvesCurrentInternalKeyWithoutGuessingBundleNames()
  {
    Sql("INSERT INTO keys VALUES('assets/synthetic_shield'); INSERT INTO key_entries VALUES(3,1)");
    var key = AddressableFxBinding.ResolvePrefabName(db, "synthetic_shield");
    Assert.Equal("synthetic/shield.prefab", key);
    Assert.Equal("synthetic-current.bundle", AddressableFxBinding.Resolve(db, key).Dependencies[0].Key);
    Assert.Throws<PreflightException>(() => AddressableFxBinding.ResolvePrefabName(db, "shield"));
  }

  [Fact]
  public void ConflictingPrefabAliasesRejectInsteadOfPickingFirst()
  {
    Sql("""
        INSERT INTO keys VALUES('assets/synthetic_shield'),('other/synthetic_shield');
        INSERT INTO key_entries VALUES(3,1),(4,4);
        INSERT INTO internal_ids VALUES('other/shield.prefab');
        INSERT INTO entries VALUES(4,1,2,NULL);
        """);
    Assert.Throws<PreflightException>(() => AddressableFxBinding.ResolvePrefabName(db, "synthetic_shield"));
  }

  [Theory]
  [InlineData("Synthetic/shield.prefab")]
  [InlineData("synthetic/other.prefab")]
  public void CaseOrSimilarNameNeverFallsBack(string key)
    => Assert.Throws<PreflightException>(() => AddressableFxBinding.Resolve(db, key));

  [Fact]
  public void OpaqueInternalContainerKeyResolvesWithoutInventingPrefabPath()
  {
    var key = new string('a', 32);
    Sql($"UPDATE keys SET key='{key}' WHERE rowid=1; UPDATE internal_ids SET internal_id='{key}' WHERE rowid=1");
    Assert.Equal(key, AddressableFxBinding.Resolve(db, key).AssetKey);
  }

  [Theory]
  [InlineData("INSERT INTO key_entries VALUES(1,1)")]
  [InlineData("INSERT INTO key_entries VALUES(2,2)")]
  [InlineData("UPDATE entries SET provider_id_rowid=2 WHERE rowid=1")]
  [InlineData("UPDATE entries SET provider_id_rowid=1 WHERE rowid=2")]
  [InlineData("UPDATE entry_data SET is_local=2 WHERE rowid=1")]
  [InlineData("UPDATE entry_data SET is_local=1")]
  [InlineData("UPDATE entry_data SET is_local=0")]
  [InlineData("UPDATE entries SET data_rowid=NULL WHERE rowid=2")]
  [InlineData("UPDATE internal_ids SET internal_id='../synthetic.bundle' WHERE rowid=2")]
  [InlineData("DELETE FROM key_entries WHERE key_rowid=2")]
  [InlineData("DELETE FROM internal_ids WHERE rowid=3")]
  [InlineData("INSERT INTO key_entries VALUES(2,99)")]
  [InlineData("INSERT INTO key_entries VALUES(1,99)")]
  public void BadOrAmbiguousBindingFailsWithoutChoosingFirst(string mutation)
  {
    Sql(mutation);
    Assert.Throws<PreflightException>(() => Resolve());
  }

  [Fact]
  public void FileSpecificOrderedChunksExcludeUnrelatedFilesAndClearReadBuffers()
  {
    var buffers = new List<byte[]>();
    var output = AddressableFxBinding.Assemble(db, "synthetic-current.bundle", (hash, size, compressed) =>
    {
      Assert.Equal(new string('0', 32), hash);
      Assert.Equal(2, compressed);
      var bytes = Enumerable.Repeat((byte)size, size).ToArray();
      buffers.Add(bytes);
      return bytes;
    });
    Assert.Equal(new byte[] { 3, 3, 3, 2, 2 }, output);
    Assert.Equal(2, buffers.Count);
    Assert.All(buffers, bytes => Assert.All(bytes, value => Assert.Equal(0, value)));
  }

  [Theory]
  [InlineData("DELETE FROM files_chunktype WHERE file_id=7")]
  [InlineData("INSERT INTO files_chunktype VALUES(9,'synthetic-current.bundle')")]
  [InlineData("DELETE FROM chunks WHERE chunk_id=2")]
  [InlineData("UPDATE chunk_file_map SET file_offset=4 WHERE chunk_id=2")]
  [InlineData("UPDATE chunks SET original_size=0 WHERE chunk_id=1")]
  [InlineData("UPDATE chunks SET hash=zeroblob(15) WHERE chunk_id=1")]
  [InlineData("DELETE FROM chunk_file_map WHERE file_id=7")]
  public void InvalidChunkClosureFails(string mutation)
  {
    Sql(mutation);
    Assert.Throws<PreflightException>(() => AddressableFxBinding.Assemble(db, "synthetic-current.bundle", (_, size, _) => new byte[size]));
  }

  [Fact]
  public void ShortDecodedChunkCannotPass()
    => Assert.Throws<PreflightException>(() => AddressableFxBinding.Assemble(db, "synthetic-current.bundle", (_, _, _) => [0]));

  private AddressableFxBinding.Binding Resolve() => AddressableFxBinding.Resolve(db, "synthetic/shield.prefab");
  private void Sql(string sql) { using var command = db.CreateCommand(); command.CommandText = sql; command.ExecuteNonQuery(); }
  public void Dispose() => db.Dispose();
}
