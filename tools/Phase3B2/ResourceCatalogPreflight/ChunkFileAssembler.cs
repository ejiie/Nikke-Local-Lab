using System.Security.Cryptography;

namespace ResourceCatalogPreflight;

internal static class ChunkFileAssembler
{
    // Offline migration probe. A single catalog member is reconstructed into a
    // new, explicitly named private artifact, never into an installed client.
    internal static object AssembleSingle(CatalogDatabase catalog, string directory, string destination)
    {
        destination = ValidateDestination(directory, destination);
        if (CatalogInspection.Read(catalog).LayoutCode != "chunk_catalog_v1" ||
            catalog.Count("SELECT COUNT(*) FROM files_chunktype") != 1)
            throw new PreflightException("resource_single_chunk_file_required");
        using var store = new ChunkStoreReader(directory);
        using var command = catalog.Connection.CreateCommand();
        command.CommandText = """
            SELECT m.file_offset,c.hash,c.original_size,c.compressed_size
            FROM chunk_file_map m JOIN chunks c ON c.chunk_id=m.chunk_id ORDER BY m.file_offset
            """;
        using var reader = command.ExecuteReader();
        using var output = new MemoryStream();
        int verified = 0;
        while (reader.Read())
        {
            var hash = Convert.ToHexString((byte[])reader.GetValue(1));
            var originalSize = reader.GetInt32(2);
            if (reader.GetInt64(0) != output.Length || originalSize is < 1 or > 16 * 1024 * 1024 ||
                output.Length + originalSize > 128 * 1024 * 1024)
                throw new PreflightException("resource_chunk_file_layout_invalid");
            var decoded = store.ReadVerified(hash, originalSize, reader.GetInt32(3));
            output.Write(decoded);
            CryptographicOperations.ZeroMemory(decoded);
            verified++;
        }
        if (verified == 0) throw new PreflightException("resource_chunk_file_empty");
        output.Position = 0;
        var outputSha256 = Convert.ToHexString(SHA256.HashData(output)).ToLowerInvariant();
        // Source hierarchy and any existing destination are never overwritten.
        output.Position = 0;
        using (var target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) output.CopyTo(target);
        return new { statusCode = "single_member_reconstructed", outputSha256, outputByteLength = output.Length,
            verifiedCompressedChunkCount = verified, catalog.BodySha256, catalog.SignatureSha256,
            indexSha256 = store.IndexSha256, indexTrailerStatusCode = store.IndexTrailerVerified ? ChunkIndexDigest.VerifiedStatusCode : "unresolved",
            staticDataIdentityVerified = false, sourceMutationPerformed = false, actualPlayVerified = false };
    }

    internal static string ValidateDestination(string sourceDirectory, string destination)
    {
        destination = Path.GetFullPath(destination);
        var parent = new DirectoryInfo(Path.GetDirectoryName(destination)!);
        if (!parent.Exists || File.Exists(destination) || Directory.Exists(destination))
            throw new PreflightException("resource_export_destination_invalid");
        // Resolve each existing ancestor so an alias into the official tree
        // cannot defeat the read-only installation boundary.
        var suffix = Path.GetFileName(destination);
        while (parent is not null)
        {
            if ((parent.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                var target = parent.ResolveLinkTarget(returnFinalTarget: true);
                if (target is not DirectoryInfo resolved) throw new PreflightException("resource_export_destination_invalid");
                destination = Path.GetFullPath(Path.Combine(resolved.FullName, suffix));
                break;
            }
            suffix = Path.Combine(parent.Name, suffix);
            parent = parent.Parent;
        }
        foreach (var forbidden in new[] { sourceDirectory, @"C:\NIKKE", @"C:\NLL\Clients" })
        {
            var boundary = Path.GetFullPath(forbidden).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (destination.StartsWith(boundary, StringComparison.OrdinalIgnoreCase))
                throw new PreflightException("resource_export_destination_is_source");
        }
        return destination;
    }
}
