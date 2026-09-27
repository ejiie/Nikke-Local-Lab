using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class BossImageExportTests
{
  [Fact]
  public void ExactAliasUsesInstalledSdWhenHdIsMissing()
  {
    using var db = Fixture();
    var rows = BossImageExport.Find(db, "full_synthetic");
    Assert.Equal(new[] { "hd", "sd" }, rows.Select(r => r.Quality));
    Assert.Equal("sd", BossImageExport.Select(rows, key => key.Contains("(sd)"))!.Quality);
    Assert.Equal("hd", BossImageExport.Select(rows, _ => true)!.Quality);
    Assert.Null(BossImageExport.Select(rows, _ => false));
    Assert.Empty(BossImageExport.Find(db, "full_synthetic_other"));
    Assert.Empty(BossImageExport.Find(db, "full_Synthetic"));
  }

  [Fact]
  public void AmbiguousQualityIsNotChosenByOrder()
  {
    using var db = Fixture();
    using var cmd = db.CreateCommand();
    cmd.CommandText = "INSERT INTO internal_ids VALUES('another(sd).bundle'); INSERT INTO entries VALUES(3,2,NULL,1); INSERT INTO key_entries VALUES(2,4)";
    cmd.ExecuteNonQuery();
    Assert.Throws<PreflightException>(() => BossImageExport.Find(db, "full_synthetic"));
  }

  private static SqliteConnection Fixture()
  {
    var db = new SqliteConnection("Data Source=:memory:"); db.Open();
    using var cmd = db.CreateCommand();
    cmd.CommandText = """
        CREATE TABLE keys(key TEXT);
        CREATE TABLE key_entries(key_rowid INTEGER,entry_rowid INTEGER);
        CREATE TABLE entries(internal_id_rowid INTEGER,provider_id_rowid INTEGER,dependency_key_rowid INTEGER,data_rowid INTEGER);
        CREATE TABLE internal_ids(internal_id TEXT);
        CREATE TABLE provider_ids(provider_id TEXT);
        CREATE TABLE entry_data(is_local INTEGER);
        INSERT INTO keys VALUES('full_synthetic'),('dependency');
        INSERT INTO key_entries VALUES(1,1),(2,2),(2,3),(2,2);
        INSERT INTO entries VALUES(NULL,1,2,NULL),(1,2,NULL,1),(2,2,NULL,1);
        INSERT INTO internal_ids VALUES('boss(sd).bundle'),('boss(hd).bundle');
        INSERT INTO provider_ids VALUES('UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider'),
          ('UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider');
        INSERT INTO entry_data VALUES(0);
        """;
    cmd.ExecuteNonQuery(); return db;
  }
}
