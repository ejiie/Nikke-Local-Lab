using System.Runtime.InteropServices;
using System.Security.Cryptography;
using EpinelPS.Data;
using Microsoft.Data.Sqlite;
using SQLitePCL;

namespace ResourceCatalogPreflight;

internal sealed class CatalogDatabase : IDisposable
{
    private IntPtr buffer;
    public SqliteConnection Connection { get; }
    public string BodySha256 { get; }
    public string SignatureSha256 { get; }
    public long BodyByteLength { get; }
    public string SqliteSha256 { get; }
    public long SqliteByteLength { get; }
    public string[] Tables { get; }

    public CatalogDatabase(string bodyPath, string signaturePath)
    {
        if (!File.Exists(bodyPath)) throw new PreflightException("resource_catalog_body_missing");
        if (!File.Exists(signaturePath)) throw new PreflightException("resource_catalog_signature_missing");
        var size = new FileInfo(bodyPath).Length;
        if (size < 36 || size > 64 * 1024 * 1024 || new FileInfo(signaturePath).Length != 96)
            throw new PreflightException("resource_catalog_pair_shape_invalid");
        var body = File.ReadAllBytes(bodyPath);
        var signature = File.ReadAllBytes(signaturePath);
        byte[]? sqlite = null;
        try
        {
            if (!body.AsSpan(0, 8).SequenceEqual(new byte[] { 78, 75, 68, 66, 0, 0, 0, 1 }))
                throw new PreflightException("resource_catalog_container_unsupported");
            // Reject unreasonable container dimensions before using the pinned
            // external NKDB decoder; source files are read-only, not fetched.
            var segmentSize = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(24, 4));
            var segmentCount = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(body.AsSpan(28, 4));
            if (segmentSize == 0 || segmentCount == 0 || (ulong)segmentSize * segmentCount > 512UL * 1024 * 1024 ||
                36UL + segmentCount * 4UL > (ulong)body.Length)
                throw new PreflightException("resource_catalog_dimensions_invalid");
            BodySha256 = Hash(body);
            SignatureSha256 = Hash(signature);
            BodyByteLength = body.Length;
            sqlite = BoundedCatalogDecoder.Decode(body);
            if (sqlite.Length < 16 || !sqlite.AsSpan(0, 16).SequenceEqual("SQLite format 3\0"u8))
                throw new PreflightException("resource_catalog_sqlite_invalid");
            SqliteSha256 = Hash(sqlite);
            SqliteByteLength = sqlite.Length;
            Batteries_V2.Init();
            Connection = new SqliteConnection("Data Source=:memory:;Pooling=False");
            Connection.Open();
            buffer = Marshal.AllocHGlobal(sqlite.Length);
            Marshal.Copy(sqlite, 0, buffer, sqlite.Length);
            if (raw.sqlite3_deserialize(Connection.Handle, "main", buffer, sqlite.Length, sqlite.Length,
                raw.SQLITE_DESERIALIZE_READONLY) != raw.SQLITE_OK)
                throw new PreflightException("resource_catalog_deserialize_failed");
            Execute("PRAGMA trusted_schema=OFF");
            if (Scalar("PRAGMA integrity_check") != "ok")
                throw new PreflightException("resource_catalog_integrity_failed");
            Tables = Strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name");
        }
        catch
        {
            Dispose();
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(body);
            CryptographicOperations.ZeroMemory(signature);
            if (sqlite is not null) CryptographicOperations.ZeroMemory(sqlite);
        }
    }

    public void Execute(string sql)
    {
        using var command = Connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    public string Scalar(string sql)
    {
        using var command = Connection.CreateCommand();
        command.CommandText = sql;
        return Convert.ToString(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) ?? "";
    }

    public long Count(string sql) => long.Parse(Scalar(sql), System.Globalization.CultureInfo.InvariantCulture);

    public string[] Strings(string sql)
    {
        using var command = Connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        var values = new List<string>();
        while (reader.Read()) values.Add(reader.GetString(0));
        return values.ToArray();
    }

    public string SchemaSha256()
    {
        var lines = new List<string>();
        foreach (var table in Tables)
        {
            using var command = Connection.CreateCommand();
            command.CommandText = "SELECT cid,name,type,\"notnull\",pk FROM pragma_table_info($table) ORDER BY cid";
            command.Parameters.AddWithValue("$table", table);
            using var reader = command.ExecuteReader();
            while (reader.Read()) lines.Add(string.Join('\t', table, reader.GetInt64(0), reader.GetString(1),
                reader.GetString(2), reader.GetInt64(3), reader.GetInt64(4)));
        }
        return Hash(System.Text.Encoding.UTF8.GetBytes(string.Join('\n', lines) + "\n"));
    }

    public void Dispose()
    {
        Connection?.Dispose();
        if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); buffer = IntPtr.Zero; }
    }

    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}

internal sealed class PreflightException(string code) : Exception(code);
