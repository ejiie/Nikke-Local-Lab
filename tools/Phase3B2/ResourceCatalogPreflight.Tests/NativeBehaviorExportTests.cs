using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class NativeBehaviorExportTests : IDisposable
{
  private readonly SqliteConnection db = new("Data Source=:memory:;Pooling=False");
  public NativeBehaviorExportTests()
  {
    db.Open();
    Sql("""
        CREATE TABLE entries(internal_id_rowid INTEGER,provider_id_rowid INTEGER,data_rowid INTEGER);
        CREATE TABLE internal_ids(internal_id TEXT);
        CREATE TABLE provider_ids(provider_id TEXT);
        CREATE TABLE entry_data(is_local INTEGER);
        INSERT INTO provider_ids VALUES('UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider');
        INSERT INTO entry_data VALUES(0);
        INSERT INTO internal_ids VALUES('externalbehavior_assets_all_ab12.bundle');
        INSERT INTO entries VALUES(1,1,1);
        """);
  }
  [Fact]
  public void CurrentCatalogSelectsBundleWithoutSeasonSpecificKnowledge()
    => Assert.Equal(new NativeBehaviorExport.Bundle("externalbehavior_assets_all_ab12.bundle", false), NativeBehaviorExport.Resolve(db));
  [Theory]
  [InlineData("DELETE FROM entries")]
  [InlineData("UPDATE entry_data SET is_local=2")]
  [InlineData("UPDATE internal_ids SET internal_id='externalbehavior_assets_all_other.bundle'")]
  [InlineData("UPDATE provider_ids SET provider_id='UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider'")]
  [InlineData("INSERT INTO internal_ids VALUES('externalbehavior_assets_all_cd34.bundle'); INSERT INTO entries VALUES(2,1,1)")]
  public void MissingOrAmbiguousCatalogNeverSelectsAnArbitraryBundle(string sql)
  {
    Sql(sql);
    Assert.Throws<PreflightException>(() => NativeBehaviorExport.Resolve(db));
  }
  [Fact]
  public void RepeatedCatalogReferencesToSameBundleAreNotAmbiguous()
  {
    Sql("INSERT INTO entries VALUES(1,1,1)");
    Assert.Equal("externalbehavior_assets_all_ab12.bundle", NativeBehaviorExport.Resolve(db).Key);
  }
  private void Sql(string sql) { using var c = db.CreateCommand(); c.CommandText = sql; c.ExecuteNonQuery(); }
  public void Dispose() => db.Dispose();
}
