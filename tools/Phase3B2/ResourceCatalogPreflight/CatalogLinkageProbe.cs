using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

internal static class CatalogLinkageProbe
{
    internal static string ResolveRawFile(CatalogDatabase outer, string directory, string logicalName)
        => ResolveRawFile(outer.Connection, directory, logicalName);

    internal static string ResolveRawFile(SqliteConnection connection, string directory, string logicalName)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT hash,extension,size FROM files_rawtype WHERE key=$key";
        command.Parameters.AddWithValue("$key", logicalName);
        using var reader = command.ExecuteReader();
        if (!reader.Read()) throw new PreflightException("resource_inner_catalog_reference_missing");
        var hash = reader.GetValue(0) is byte[] bytes ? Convert.ToHexString(bytes) : reader.GetString(0);
        var extension = reader.GetString(1).TrimStart('.');
        var size = reader.GetInt64(2);
        if (reader.Read() || size < 0 || !Regex.IsMatch(hash, "^[a-fA-F0-9]{32}$") || !Regex.IsMatch(extension, "^[a-zA-Z0-9]{1,8}$"))
            throw new PreflightException("resource_inner_catalog_reference_invalid");
        var path = Path.Combine(directory, "raw", hash.ToLowerInvariant() + "." + extension);
        if (!File.Exists(path) || new FileInfo(path).Length != size)
            throw new PreflightException("resource_inner_catalog_file_missing_or_incomplete");
        return path;
    }

    internal static object Inspect(string role, string directory)
    {
        using var outer = new CatalogDatabase(Path.Combine(directory, "catalog.ndb"), Path.Combine(directory, "catalog.ndb.nds"));
        CatalogInspection.Read(outer);
        var logicalName = role is "core" or "dp" or "fd" ? "catalog.db" : "asset-catalog.cat";
        var body = ResolveRawFile(outer, directory, logicalName);
        var signature = ResolveRawFile(outer, directory, logicalName + ".nds");
        using var inner = new CatalogDatabase(body, signature);
        if (!inner.Tables.Contains("FileInfoEntity"))
            return new { roleCode = role, statusCode = "native_addressables_inner_catalog", outer.BodySha256,
                innerCatalogSha256 = inner.BodySha256, innerSchemaSha256 = inner.SchemaSha256(),
                payloadClosureStatusCode = "not_evaluated" };

        var installed = File.Exists(Path.Combine(directory, "chunk", "store.cdb.idx"))
            ? new ChunkStoreReader(directory) : null;
        try
        {
            var chunks = new Dictionary<string, (long Size, string Group, List<string> Hashes)>(StringComparer.Ordinal);
            using (var command = outer.Connection.CreateCommand())
            {
                command.CommandText = """
                    SELECT f.key,g.group_name,c.original_size,hex(c.hash)
                    FROM files_chunktype f JOIN groups_chunktype g ON g.group_id=f.group_id
                    JOIN chunk_file_map m ON m.file_id=f.file_id JOIN chunks c ON c.chunk_id=m.chunk_id
                    ORDER BY f.file_id,m.file_offset
                    """;
                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    var key = reader.GetString(0);
                    if (!chunks.TryGetValue(key, out var file)) file = (0, reader.GetString(1), []);
                    file.Hashes.Add(reader.GetString(3));
                    chunks[key] = (checked(file.Size + reader.GetInt64(2)), file.Group, file.Hashes);
                }
            }
            var rows = new List<(string Group, bool SizeMatches, bool Complete)>();
            long unmatched = 0;
            using (var command = inner.Connection.CreateCommand())
            {
                command.CommandText = "SELECT RelativePath,Size FROM FileInfoEntity WHERE IsLocal=0";
                using var reader = command.ExecuteReader();
                while (reader.Read())
                {
                    if (!chunks.TryGetValue(reader.GetString(0), out var file)) { unmatched++; continue; }
                    rows.Add((file.Group, file.Size == reader.GetInt64(1),
                        installed is not null && file.Hashes.All(installed.Entries.ContainsKey)));
                }
            }
            var labels = inner.Strings("SELECT DISTINCT Label FROM LabelToUnionEntity ORDER BY Label");
            return new
            {
                roleCode = role, statusCode = "inner_outer_catalog_linkage_inspected", outer.BodySha256,
                innerCatalogSha256 = inner.BodySha256, innerSignatureSha256 = inner.SignatureSha256,
                innerSchemaSha256 = inner.SchemaSha256(), chunkFileCount = chunks.Count,
                innerFileCount = inner.Count("SELECT COUNT(*) FROM FileInfoEntity"),
                localInnerFileCount = inner.Count("SELECT COUNT(*) FROM FileInfoEntity WHERE IsLocal<>0"),
                linkedRemoteFileCount = rows.Count, unmatchedRemoteFileCount = unmatched,
                linkedGroups = rows.GroupBy(row => row.Group).Select(group => new
                {
                    groupCode = Regex.IsMatch(group.Key.ToLowerInvariant(), "^(ko|en|ja)_(required|add)$") ? group.Key.ToLowerInvariant() : "other",
                    fileCount = group.Count(), lengthMismatchCount = group.Count(row => !row.SizeMatches),
                    completeInstalledFileCount = group.Count(row => row.Complete)
                }).ToArray(),
                innerLabelCount = labels.Length,
                recognizedDownloadLabels = labels.Where(label => Regex.IsMatch(label, "^(ko|en|ja)_(required|add)$")).ToArray(),
                nativeReadiness = "not_evaluated"
            };
        }
        finally { installed?.Dispose(); }
    }
}
