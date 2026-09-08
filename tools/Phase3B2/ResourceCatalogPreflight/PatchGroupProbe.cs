using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

internal static class PatchGroupProbe
{
    internal sealed record GroupCounts(long ChunkCount, long CompressedChunkBytes, long RawFileCount,
        long RawBytes, long ColdDownloadBytes, long ChunkInsertBytes);
    internal sealed record Coverage(long SelectedChunkCount, long MissingSelectedChunkCount,
        long InstalledOutsideSelectionCount, long LengthMismatchCount);

    internal static object Inspect(string role, string directory)
    {
        using var catalog = new CatalogDatabase(Path.Combine(directory, "catalog.ndb"), Path.Combine(directory, "catalog.ndb.nds"));
        CatalogInspection.Read(catalog);
        var groupNames = catalog.Strings("SELECT group_name FROM groups_chunktype UNION SELECT group_name FROM groups_rawtype ORDER BY group_name");
        var groups = groupNames.Select(group => new
        {
            groupCode = Regex.IsMatch(group, "^[A-Za-z_-]{1,48}$") ? group.ToLowerInvariant() : "unresolved",
            counts = Count(catalog.Connection, [group])
        }).ToArray();
        var qualitySelections = new List<object>();
        foreach (var lod in new[] { "hd", "sd" })
        foreach (var texture in new[] { "hd", "sd" })
        foreach (var spine in new[] { "hd", "sd" })
        {
            var selection = new[] { "required", "requiredquality_lod_" + lod,
                "requiredquality_texture_" + texture, "requiredquality_spine_" + spine };
            var selectedNames = groupNames.Where(name => selection.Contains(name, StringComparer.OrdinalIgnoreCase)).ToArray();
            qualitySelections.Add(new { qualityCode = $"lod_{lod}_texture_{texture}_spine_{spine}",
                selectedGroupCount = selectedNames.Length, counts = Count(catalog.Connection, selectedNames) });
        }
        var observedSelection = new[] { "required", "requiredquality_lod_sd", "requiredquality_texture_sd",
            "requiredquality_spine_sd", role + "_required" };
        var selected = groupNames.Where(name => observedSelection.Contains(name, StringComparer.OrdinalIgnoreCase)).ToArray();
        Coverage? installedCoverage = null;
        if (File.Exists(Path.Combine(directory, "chunk", "store.cdb.idx")))
        {
            using var store = new ChunkStoreReader(directory);
            installedCoverage = CompareInstalled(catalog.Connection, selected, store.Entries);
        }
        return new { roleCode = role, catalog.BodySha256, catalog.SignatureSha256, groups,
            allGroups = Count(catalog.Connection, groupNames), qualitySelections,
            observedSelectionCode = "sd_base_or_role_required", installedCoverage, nativeReadiness = "not_evaluated" };
    }

    internal static GroupCounts Count(SqliteConnection connection, string[] names)
    {
        using var command = connection.CreateCommand();
        var selection = BindGroups(command, names);
        command.CommandText = $"""
            SELECT COUNT(*),COALESCE(SUM(compressed_size),0) FROM chunks WHERE chunk_id IN (
              SELECT DISTINCT m.chunk_id FROM chunk_file_map m
              JOIN files_chunktype f ON f.file_id=m.file_id
              JOIN groups_chunktype g ON g.group_id=f.group_id WHERE g.group_name IN ({selection}))
            """;
        long chunks, compressedBytes;
        using (var reader = command.ExecuteReader()) { reader.Read(); chunks = reader.GetInt64(0); compressedBytes = reader.GetInt64(1); }
        command.CommandText = $"""
            SELECT COUNT(*),COALESCE(SUM(size),0) FROM files_rawtype f
            JOIN groups_rawtype g ON g.group_id=f.group_id WHERE g.group_name IN ({selection})
            """;
        long rawFiles, rawBytes;
        using (var reader = command.ExecuteReader()) { reader.Read(); rawFiles = reader.GetInt64(0); rawBytes = reader.GetInt64(1); }
        return new(chunks, compressedBytes, rawFiles, rawBytes, checked(compressedBytes + rawBytes), compressedBytes);
    }

    internal static Coverage CompareInstalled(SqliteConnection connection, string[] names,
        IReadOnlyDictionary<string, ChunkStoreReader.Location> installed)
    {
        using var command = connection.CreateCommand();
        var selection = BindGroups(command, names);
        command.CommandText = $"""
            SELECT hex(hash),compressed_size FROM chunks WHERE chunk_id IN (
              SELECT DISTINCT m.chunk_id FROM chunk_file_map m
              JOIN files_chunktype f ON f.file_id=m.file_id
              JOIN groups_chunktype g ON g.group_id=f.group_id WHERE g.group_name IN ({selection}))
            """;
        using var reader = command.ExecuteReader();
        var hashes = new HashSet<string>(StringComparer.Ordinal);
        long missing = 0, mismatch = 0;
        while (reader.Read())
        {
            var hash = reader.GetString(0);
            hashes.Add(hash);
            if (!installed.TryGetValue(hash, out var entry)) missing++;
            else if (entry.Length != reader.GetInt64(1)) mismatch++;
        }
        return new(hashes.Count, missing, installed.Keys.Count(hash => !hashes.Contains(hash)), mismatch);
    }

    private static string BindGroups(SqliteCommand command, string[] names)
    {
        // Empty selection deliberately yields no rows; never substitute all groups.
        if (names.Length == 0) return "NULL";
        return string.Join(',', names.Distinct(StringComparer.Ordinal).Select((name, index) =>
        {
            var parameter = "$group" + index;
            command.Parameters.AddWithValue(parameter, name);
            return parameter;
        }));
    }
}
