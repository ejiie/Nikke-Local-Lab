using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Private asset keys never enter domain identities or public receipts. Exact
// catalog relations, not filename stems, choose the installed payload.
internal static class AddressableFxBinding
{
  internal sealed record Dependency(string Key, bool IsLocal);
  internal sealed record Binding(string AssetKey, Dependency[] Dependencies);

  internal static string ResolvePrefabName(SqliteConnection db, string name)
  {
    Require(Regex.IsMatch(name, @"\A[a-zA-Z0-9_-]{1,256}\z"), "prefab_name_invalid");
    using var command = db.CreateCommand();
    command.CommandText = """
        SELECT DISTINCT i.internal_id
        FROM keys k JOIN key_entries ke ON ke.key_rowid=k.rowid
        JOIN entries e ON e.rowid=ke.entry_rowid
        JOIN internal_ids i ON i.rowid=e.internal_id_rowid
        JOIN provider_ids p ON p.rowid=e.provider_id_rowid
        WHERE (lower(k.key)=lower($name) OR substr(lower(k.key),-length($name)-1)='/'||lower($name))
          AND p.provider_id='UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider'
        """;
    command.Parameters.AddWithValue("$name", name);
    using var reader = command.ExecuteReader();
    Require(reader.Read(), "asset_missing");
    var key = reader.GetString(0);
    Require(!reader.Read(), "asset_ambiguous");
    return key;
  }

  internal static Binding Resolve(SqliteConnection db, string assetKey)
  {
    Require(assetKey.Length is > 0 and <= 2048 && (assetKey.EndsWith(".prefab", StringComparison.Ordinal) ||
        Regex.IsMatch(assetKey, "\\A[0-9a-f]{32}\\z", RegexOptions.CultureInvariant)), "asset_key_invalid");
    using var command = db.CreateCommand();
    command.CommandText = """
        SELECT i.internal_id,p.provider_id,e.dependency_key_rowid
        FROM keys k LEFT JOIN key_entries ke ON ke.key_rowid=k.rowid
        LEFT JOIN entries e ON e.rowid=ke.entry_rowid
        LEFT JOIN internal_ids i ON i.rowid=e.internal_id_rowid
        LEFT JOIN provider_ids p ON p.rowid=e.provider_id_rowid
        WHERE k.key=$key COLLATE BINARY
        """;
    command.Parameters.AddWithValue("$key", assetKey);
    long dependency;
    using (var reader = command.ExecuteReader())
    {
      Require(reader.Read(), "asset_missing");
      Require(!reader.IsDBNull(0) && !reader.IsDBNull(1) && reader.GetString(0) == assetKey && reader.GetString(1) ==
          "UnityEngine.ResourceManagement.ResourceProviders.BundledAssetProvider" && !reader.IsDBNull(2), "asset_provider_invalid");
      dependency = reader.GetInt64(2);
      Require(!reader.Read(), "asset_ambiguous");
    }
    command.CommandText = """
        SELECT i.internal_id,p.provider_id,d.is_local
        FROM key_entries ke LEFT JOIN entries e ON e.rowid=ke.entry_rowid
        LEFT JOIN internal_ids i ON i.rowid=e.internal_id_rowid
        LEFT JOIN provider_ids p ON p.rowid=e.provider_id_rowid
        LEFT JOIN entry_data d ON d.rowid=e.data_rowid
        WHERE ke.key_rowid=$key ORDER BY i.internal_id COLLATE BINARY
        """;
    command.Parameters[0].Value = dependency;
    var rows = new List<Dependency>();
    using (var reader = command.ExecuteReader())
    {
      while (reader.Read())
      {
        Require(rows.Count < 32 && !reader.IsDBNull(0) && !reader.IsDBNull(1) && reader.GetString(1) ==
            "UnityEngine.ResourceManagement.ResourceProviders.AssetBundleProvider" && !reader.IsDBNull(2), "bundle_provider_invalid");
        var key = reader.GetString(0);
        Require(Regex.IsMatch(key, @"\A[A-Za-z0-9_-]{1,512}\.bundle\z", RegexOptions.CultureInvariant), "bundle_key_invalid");
        var local = reader.GetInt64(2);
        Require(local is 0 or 1 && rows.All(row => row.Key != key), "bundle_ambiguous");
        rows.Add(new(key, local == 1));
      }
    }
    // This bounded FX export contract handles exactly one owned remote bundle
    // plus local dependencies. Additional remote dependencies need a new review.
    Require(rows.Count > 0 && rows.Count(row => !row.IsLocal) == 1, "remote_bundle_ambiguous");
    return new(assetKey, rows.ToArray());
  }

  internal static byte[] Assemble(SqliteConnection db, string key, Func<string, int, int, byte[]> read)
  {
    using var command = db.CreateCommand();
    command.CommandText = "SELECT file_id FROM files_chunktype WHERE key=$key COLLATE BINARY";
    command.Parameters.AddWithValue("$key", key);
    long fileId;
    using (var reader = command.ExecuteReader())
    {
      Require(reader.Read(), "chunk_file_missing");
      fileId = reader.GetInt64(0);
      Require(!reader.Read(), "chunk_file_ambiguous");
    }
    command.CommandText = """
        SELECT m.file_offset,c.hash,c.original_size,c.compressed_size
        FROM chunk_file_map m LEFT JOIN chunks c ON c.chunk_id=m.chunk_id
        WHERE m.file_id=$key ORDER BY m.file_offset
        """;
    command.Parameters[0].Value = fileId;
    using var parts = command.ExecuteReader();
    using var output = new MemoryStream();
    while (parts.Read())
    {
      Require(!parts.IsDBNull(1) && parts.GetInt64(0) == output.Length, "chunk_layout_invalid");
      var hash = (byte[])parts.GetValue(1);
      var size = parts.GetInt32(2);
      var compressed = parts.GetInt32(3);
      Require(hash.Length == 16 && size is > 0 and <= 16 * 1024 * 1024 &&
          compressed is > 0 and <= 16 * 1024 * 1024 && output.Length + size <= 64 * 1024 * 1024, "chunk_size_invalid");
      var bytes = read(Convert.ToHexString(hash), size, compressed);
      try
      {
        Require(bytes.Length == size, "chunk_size_mismatch");
        output.Write(bytes);
      }
      finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    Require(output.Length > 0, "chunk_file_empty");
    return output.ToArray();
  }

  internal static void Require(bool value, string suffix)
  {
    if (!value) throw new PreflightException("resource_fx_" + suffix);
  }
}
