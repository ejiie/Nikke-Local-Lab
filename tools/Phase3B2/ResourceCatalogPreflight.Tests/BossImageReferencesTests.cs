using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class BossImageReferencesTests
{
  [Fact]
  public void OnlyExactBasenameMatchesAndDuplicatesRemainAmbiguous()
  {
    using var db = new SqliteConnection("Data Source=:memory:");
    db.Open();
    using var command = db.CreateCommand();
    command.CommandText = """
      CREATE TABLE keys(key TEXT);
      INSERT INTO keys VALUES('images/full_synthetic.png'),('images/full_synthetic_other.png'),
        ('images/prefix_full_synthetic.png'),('images/FULL_SYNTHETIC.png'),('images/../full_synthetic.png');
      """;
    command.ExecuteNonQuery();
    Assert.Equal(new[] { "images/full_synthetic.png" }, BossImageReferences.Find(db, "full_synthetic"));
    command.CommandText = "INSERT INTO keys VALUES('images/full_synthetic.png')";
    command.ExecuteNonQuery();
    Assert.Equal(2, BossImageReferences.Find(db, "full_synthetic").Length);
    Assert.Empty(BossImageReferences.Find(db, null));
    Assert.Empty(BossImageReferences.Find(db, "full_missing"));
  }

  [Theory]
  [InlineData("")]
  [InlineData("../full_synthetic")]
  [InlineData("full_synthetic.png")]
  [InlineData("full_x'; DROP TABLE keys;--")]
  public void InvalidSourceHintFailsWithoutQuery(string name)
  {
    using var db = new SqliteConnection("Data Source=:memory:");
    Assert.Throws<PreflightException>(() => BossImageReferences.Find(db, name));
  }
}
