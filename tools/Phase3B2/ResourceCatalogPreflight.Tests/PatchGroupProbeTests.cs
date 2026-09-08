using Microsoft.Data.Sqlite;
using ResourceCatalogPreflight;
using Xunit;

namespace ResourceCatalogPreflight.Tests;

public sealed class PatchGroupProbeTests
{
    [Fact]
    public void SharedChunksAreCountedOnceAcrossFilesAndGroups()
    {
        using var connection = SyntheticCatalog();
        var result = PatchGroupProbe.Count(connection, ["required", "optional", "required"]);
        Assert.Equal(new PatchGroupProbe.GroupCounts(3, 60, 2, 12, 72, 60), result);
        Assert.Equal(new PatchGroupProbe.GroupCounts(2, 30, 1, 5, 35, 30),
            PatchGroupProbe.Count(connection, ["required"]));
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("required') OR 1=1 --")]
    public void UnknownAndSqlLookingNamesDoNotExpandSelection(string name)
    {
        using var connection = SyntheticCatalog();
        Assert.Equal(new PatchGroupProbe.GroupCounts(0, 0, 0, 0, 0, 0),
            PatchGroupProbe.Count(connection, [name]));
    }

    [Fact]
    public void EmptySelectionDoesNotMeanAllGroups()
    {
        using var connection = SyntheticCatalog();
        Assert.Equal(new PatchGroupProbe.GroupCounts(0, 0, 0, 0, 0, 0),
            PatchGroupProbe.Count(connection, []));
        Assert.Equal(new PatchGroupProbe.Coverage(0, 0, 1, 0),
            PatchGroupProbe.CompareInstalled(connection, [], Installed((1, 10))));
    }

    [Fact]
    public void CoverageComparesExactHashSetsAndLengthsNotOnlyByteTotals()
    {
        using var connection = SyntheticCatalog();
        Assert.Equal(new PatchGroupProbe.Coverage(2, 0, 0, 0),
            PatchGroupProbe.CompareInstalled(connection, ["required"], Installed((1, 10), (2, 20))));
        Assert.Equal(new PatchGroupProbe.Coverage(2, 1, 1, 1),
            PatchGroupProbe.CompareInstalled(connection, ["required"], Installed((1, 11), (3, 19))));
    }

    private static Dictionary<string, ChunkStoreReader.Location> Installed(params (byte Hash, int Length)[] items) =>
        items.ToDictionary(item => Convert.ToHexString([item.Hash]), item => new ChunkStoreReader.Location(256, item.Length));

    private static SqliteConnection SyntheticCatalog()
    {
        var connection = new SqliteConnection("Data Source=:memory:;Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE chunks(chunk_id INTEGER PRIMARY KEY,hash BLOB,compressed_size INTEGER);
            CREATE TABLE chunk_file_map(chunk_id INTEGER,file_id INTEGER);
            CREATE TABLE files_chunktype(file_id INTEGER,group_id INTEGER);
            CREATE TABLE groups_chunktype(group_id INTEGER,group_name TEXT);
            CREATE TABLE files_rawtype(file_id INTEGER,group_id INTEGER,size INTEGER);
            CREATE TABLE groups_rawtype(group_id INTEGER,group_name TEXT);
            INSERT INTO chunks VALUES(1,X'01',10),(2,X'02',20),(3,X'03',30);
            INSERT INTO groups_chunktype VALUES(1,'required'),(2,'optional');
            INSERT INTO groups_rawtype VALUES(1,'required'),(2,'optional');
            INSERT INTO files_chunktype VALUES(1,1),(2,1),(3,2);
            INSERT INTO chunk_file_map VALUES(1,1),(2,1),(1,2),(2,3),(3,3);
            INSERT INTO files_rawtype VALUES(1,1,5),(2,2,7);
            PRAGMA query_only=ON;
            """;
        command.ExecuteNonQuery();
        return connection;
    }
}
