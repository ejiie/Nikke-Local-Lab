namespace ResourceCatalogPreflight;

internal sealed record CatalogInspection(string LayoutCode, long RawFileCount, long ChunkFileCount,
    long ChunkCount, long BrokenReferenceCount, string PayloadClosureStatusCode)
{
    public static CatalogInspection Read(CatalogDatabase database)
    {
        var tables = database.Tables;
        if (tables.Contains("files_chunktype", StringComparer.Ordinal))
        {
            string[] required = ["chunk_file_map", "chunks", "files_chunktype", "files_rawtype",
                "groups_chunktype", "groups_rawtype", "paks"];
            if (!required.SequenceEqual(tables) || database.SchemaSha256() !=
                "b709086885a5dcb4eec098a810c80f5f2901bd5c07997a3f8d56f21436b37f85")
                throw new PreflightException("resource_catalog_schema_unsupported");
            var broken = database.Count("""
                SELECT COUNT(*) FROM chunk_file_map m
                LEFT JOIN chunks c ON c.chunk_id=m.chunk_id
                LEFT JOIN files_chunktype f ON f.file_id=m.file_id
                WHERE c.chunk_id IS NULL OR f.file_id IS NULL OR m.file_offset < 0
                """) + database.Count("""
                SELECT COUNT(*) FROM chunks c LEFT JOIN paks p ON p.pak_id=c.pak_id
                WHERE p.pak_id IS NULL OR c.original_size < 0 OR c.compressed_size < 0 OR c.pak_offset < 0
                """) + database.Count("""
                SELECT COUNT(*) FROM files_chunktype f LEFT JOIN groups_chunktype g ON g.group_id=f.group_id
                WHERE g.group_id IS NULL
                """) + database.Count("""
                SELECT COUNT(*) FROM files_rawtype f LEFT JOIN groups_rawtype g ON g.group_id=f.group_id
                WHERE g.group_id IS NULL OR f.size < 0
                """);
            if (broken != 0) throw new PreflightException("resource_chunk_reference_invalid");
            return new("chunk_catalog_v1", database.Count("SELECT COUNT(*) FROM files_rawtype"),
                database.Count("SELECT COUNT(*) FROM files_chunktype"), database.Count("SELECT COUNT(*) FROM chunks"),
                broken, "not_evaluated");
        }
        if (tables.Contains("AssetEntity", StringComparer.Ordinal) && tables.Contains("FileInfoEntity", StringComparer.Ordinal))
            return new("legacy_saus_v1", database.Count("SELECT COUNT(*) FROM FileInfoEntity"), 0, 0, 0, "not_evaluated");
        // Native addressable catalogs are a distinct schema/transport from
        // SAUS. Only accept the schema measured for the pinned legacy layout.
        if (database.SchemaSha256() is "4243899d4b51e5b79c5d65e6181acb66dde8f6f75476680b4654761829a3c595")
            return new("legacy_native_v1", 0, 0, 0, 0, "not_evaluated");
        throw new PreflightException("resource_catalog_schema_unsupported");
    }
}
