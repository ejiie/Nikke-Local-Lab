namespace ResourceCatalogPreflight;

internal static class ChunkStoreProbe
{
    // CID X v1 observed in the official-current installation. This read-only
    // probe does NOT certify the still-unresolved index trailer checksum.
    public static object Inspect(CatalogDatabase catalog, string directory, bool verifyAll = false)
    {
        if (CatalogInspection.Read(catalog).LayoutCode != "chunk_catalog_v1")
            throw new PreflightException("resource_chunk_layout_required");
        var indexPath = Path.Combine(directory, "chunk", "store.cdb.idx");
        var storePath = Path.Combine(directory, "chunk", "store.cdb");
        if (!File.Exists(indexPath) || !File.Exists(storePath))
            return new { statusCode = "payload_not_installed", payloadClosureResolved = false };
        using var store = new ChunkStoreReader(directory);
        var knownHashes = new HashSet<string>(StringComparer.Ordinal);
        var installed = store.Entries;
        using var command = catalog.Connection.CreateCommand();
        command.CommandText = "SELECT hash,original_size,compressed_size FROM chunks";
        using var reader = command.ExecuteReader();
        long present = 0, absent = 0, verified = 0;
        while (reader.Read())
        {
            var hash = Convert.ToHexString((byte[])reader.GetValue(0));
            knownHashes.Add(hash);
            if (!installed.TryGetValue(hash, out var item)) { absent++; continue; }
            present++;
            var originalLength = reader.GetInt32(1);
            if (item.Length != reader.GetInt32(2)) throw new PreflightException("resource_chunk_catalog_size_mismatch");
            if (!verifyAll && verified >= 3) continue;
            var decoded = store.ReadVerified(hash, originalLength, item.Length);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(decoded);
            verified++;
        }
        return new
        {
            statusCode = "index_inspected", indexVersion = 1, indexMemberCount = installed.Count,
            catalogChunkCount = present + absent, installedCatalogChunkCount = present,
            missingCatalogChunkCount = absent, unreferencedIndexMemberCount = installed.Keys.Count(hash => !knownHashes.Contains(hash)),
            verifiedCompressedChunkCount = verified, verificationScopeCode = verifyAll ? "all_installed" : "sample_three",
            chunkDigestAlgorithmCode = "compressed_spooky_hash_v2_128",
            chunkFileKinds = InspectFileKinds(catalog),
            groups = InspectGroups(catalog, installed.Keys.ToHashSet(StringComparer.Ordinal)),
            indexIntegrityStatusCode = store.IndexTrailerVerified ? "spooky_prefix_verified" : "trailer_unresolved", payloadClosureResolved = false
        };
    }

    private static object[] InspectFileKinds(CatalogDatabase catalog) => catalog.Strings("SELECT key FROM files_chunktype")
        .Select(key => key.EndsWith("StaticData.pack", StringComparison.OrdinalIgnoreCase) ? "static_data_pack" :
            key.Contains("static", StringComparison.OrdinalIgnoreCase) ? "possible_static_data" :
            key.EndsWith(".pack", StringComparison.OrdinalIgnoreCase) ? "encrypted_pack" :
            key.EndsWith(".cat", StringComparison.OrdinalIgnoreCase) ? "catalog_container" :
            key.EndsWith(".db", StringComparison.OrdinalIgnoreCase) ? "database_container" :
            key.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) ? "video" :
            key.EndsWith("asset-catalog.cat", StringComparison.OrdinalIgnoreCase) ? "asset_catalog" :
            key.EndsWith(".bundle", StringComparison.OrdinalIgnoreCase) ? "asset_bundle" :
            key.EndsWith(".bank", StringComparison.OrdinalIgnoreCase) ? "audio_bank" : "unresolved")
        .GroupBy(kind => kind).Select(group => (object)new { kindCode = group.Key, fileCount = group.Count() }).ToArray();

    private static object[] InspectGroups(CatalogDatabase catalog, HashSet<string> installed)
    {
        using var command = catalog.Connection.CreateCommand();
        command.CommandText = """
            SELECT g.group_name,f.file_id,hex(c.hash)
            FROM groups_chunktype g
            LEFT JOIN files_chunktype f ON f.group_id=g.group_id
            LEFT JOIN chunk_file_map m ON m.file_id=f.file_id
            LEFT JOIN chunks c ON c.chunk_id=m.chunk_id
            ORDER BY g.group_name,f.file_id,m.file_offset
            """;
        using var reader = command.ExecuteReader();
        var groups = new Dictionary<string, Dictionary<long, List<string>>>(StringComparer.Ordinal);
        while (reader.Read())
        {
            var name = reader.GetString(0);
            if (!groups.TryGetValue(name, out var files)) groups[name] = files = [];
            if (reader.IsDBNull(1)) continue;
            var file = reader.GetInt64(1);
            if (!files.TryGetValue(file, out var chunks)) files[file] = chunks = [];
            var hash = reader.GetString(2);
            if (hash.Length != 0) chunks.Add(hash);
        }
        // Source group IDs/file keys remain private. Only explicit generic
        // download labels, counts and digests are allowed in the observation.
        return groups.Select(group => (object)new
        {
            groupNameCode = System.Text.RegularExpressions.Regex.IsMatch(group.Key, "^[A-Za-z_-]{1,48}$")
                ? group.Key.ToLowerInvariant() : "unresolved",
            groupNameSha256 = CatalogDatabase.Hash(System.Text.Encoding.UTF8.GetBytes(group.Key)),
            fileCount = group.Value.Count,
            completeFileCount = group.Value.Values.Count(hashes => hashes.Count > 0 && hashes.All(installed.Contains)),
            absentFileCount = group.Value.Values.Count(hashes => hashes.Count > 0 && hashes.All(hash => !installed.Contains(hash))),
            partialFileCount = group.Value.Values.Count(hashes => hashes.Any(installed.Contains) && hashes.Any(hash => !installed.Contains(hash))),
            unmappedFileCount = group.Value.Values.Count(hashes => hashes.Count == 0)
        }).ToArray();
    }
}
