using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;
using Microsoft.Data.Sqlite;
using SQLitePCL;

if (args.Length != 3)
{
    throw new InvalidOperationException(
        "usage: SausCatalogMemoryInspector <role-code> <nkdb-body> <nds-signature>");
}

var roleCode = args[0];
var bodyPath = Path.GetFullPath(args[1]);
var signaturePath = Path.GetFullPath(args[2]);
if (!File.Exists(bodyPath) || !File.Exists(signaturePath))
    throw new FileNotFoundException("catalog body or detached signature is missing");

var encrypted = await File.ReadAllBytesAsync(bodyPath);
var signature = await File.ReadAllBytesAsync(signaturePath);
if (encrypted.Length < 4 || !encrypted.AsSpan(0, 4).SequenceEqual("NKDB"u8))
    throw new InvalidDataException("catalog body is not NKDB");
if (signature.Length != 96)
    throw new InvalidDataException("detached signature length is not 96 bytes");

var decrypted = NkdbDecryptor.Decrypt(encrypted);
if (decrypted.Length < 16 ||
    !decrypted.AsSpan(0, 16).SequenceEqual("SQLite format 3\0"u8))
{
    throw new InvalidDataException("catalog did not decrypt to SQLite");
}

Batteries_V2.Init();
IntPtr sqliteBuffer = IntPtr.Zero;
try
{
    using var connection = new SqliteConnection("Data Source=:memory:;Pooling=False");
    connection.Open();

    sqliteBuffer = Marshal.AllocHGlobal(decrypted.Length);
    Marshal.Copy(decrypted, 0, sqliteBuffer, decrypted.Length);
    var rc = raw.sqlite3_deserialize(
        connection.Handle,
        "main",
        sqliteBuffer,
        decrypted.LongLength,
        decrypted.LongLength,
        raw.SQLITE_DESERIALIZE_READONLY);
    if (rc != raw.SQLITE_OK)
        throw new InvalidDataException($"sqlite3_deserialize failed: {rc}");

    var tables = new List<object>();
    var schemaCanonical = new List<string>();
    foreach (var tableName in ReadTableNames(connection))
    {
        var columns = ReadColumns(connection, tableName);
        var rowCount = ReadInt64(connection,
            $"SELECT COUNT(*) FROM [{EscapeIdentifier(tableName)}]");
        tables.Add(new
        {
            name = tableName,
            rowCount,
            columns = columns.Select(column => new
            {
                column.Ordinal,
                column.Name,
                column.Type,
                column.NotNull,
                column.PrimaryKeyOrdinal
            }).ToArray()
        });
        schemaCanonical.AddRange(columns.Select(column =>
            $"{tableName}\t{column.Ordinal}\t{column.Name}\t{column.Type}\t" +
            $"{(column.NotNull ? 1 : 0)}\t{column.PrimaryKeyOrdinal}"));
    }

    var integrityCheck = ReadString(connection, "PRAGMA integrity_check");
    var quickCheck = ReadString(connection, "PRAGMA quick_check");
    var schemaCanonicalBytes = Encoding.UTF8.GetBytes(
        string.Join('\n', schemaCanonical) + "\n");

    WriteJson(new
    {
        schemaVersion = 1,
        contractId = "nll/phase3b2-saus-catalog-memory-inspection/v1",
        inspectedAtUtc = DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        roleCode,
        encryptedByteLength = encrypted.LongLength,
        encryptedSha256 = Sha256(encrypted),
        encryptedCrc32UnsignedDecimal = Crc32(encrypted).ToString(),
        detachedSignatureByteLength = signature.LongLength,
        detachedSignatureSha256 = Sha256(signature),
        detachedSignatureCrc32UnsignedDecimal = Crc32(signature).ToString(),
        decryptedSqliteByteLength = decrypted.LongLength,
        decryptedSqliteSha256 = Sha256(decrypted),
        decryptedSqliteCrc32UnsignedDecimal = Crc32(decrypted).ToString(),
        sqliteIntegrityCheck = integrityCheck,
        sqliteQuickCheck = quickCheck,
        sqliteUserVersion = ReadInt64(connection, "PRAGMA user_version"),
        sqliteApplicationId = ReadInt64(connection, "PRAGMA application_id"),
        sqliteSchemaVersion = ReadInt64(connection, "PRAGMA schema_version"),
        sqlitePageSize = ReadInt64(connection, "PRAGMA page_size"),
        sqlitePageCount = ReadInt64(connection, "PRAGMA page_count"),
        schemaCanonicalSha256 = Sha256(schemaCanonicalBytes),
        tableCount = tables.Count,
        tables,
        decryptedContentPersisted = false,
        rawTableRowsEmitted = false,
        sourceMutationPerformed = false
    });
}
finally
{
    if (sqliteBuffer != IntPtr.Zero)
        Marshal.FreeHGlobal(sqliteBuffer);
    CryptographicOperations.ZeroMemory(decrypted);
    CryptographicOperations.ZeroMemory(encrypted);
    CryptographicOperations.ZeroMemory(signature);
}

static string[] ReadTableNames(SqliteConnection connection)
{
    var result = new List<string>();
    using var command = connection.CreateCommand();
    command.CommandText =
        "SELECT name FROM sqlite_master " +
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name";
    using var reader = command.ExecuteReader();
    while (reader.Read()) result.Add(reader.GetString(0));
    return result.ToArray();
}

static ColumnInfo[] ReadColumns(SqliteConnection connection, string tableName)
{
    var result = new List<ColumnInfo>();
    using var command = connection.CreateCommand();
    command.CommandText = $"PRAGMA table_info([{EscapeIdentifier(tableName)}])";
    using var reader = command.ExecuteReader();
    while (reader.Read())
    {
        result.Add(new ColumnInfo(
            reader.GetInt32(0),
            reader.GetString(1),
            reader.IsDBNull(2) ? "" : reader.GetString(2),
            reader.GetInt32(3) != 0,
            reader.GetInt32(5)));
    }
    return result.ToArray();
}

static long ReadInt64(SqliteConnection connection, string sql)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    return Convert.ToInt64(command.ExecuteScalar());
}

static string ReadString(SqliteConnection connection, string sql)
{
    using var command = connection.CreateCommand();
    command.CommandText = sql;
    return Convert.ToString(command.ExecuteScalar()) ?? "";
}

static string EscapeIdentifier(string value) =>
    value.Replace("]", "]]", StringComparison.Ordinal);

static string Sha256(ReadOnlySpan<byte> bytes) =>
    Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

static uint Crc32(ReadOnlySpan<byte> bytes)
{
    uint crc = uint.MaxValue;
    foreach (var value in bytes)
    {
        crc ^= value;
        for (var bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320u & (uint)-(int)(crc & 1));
    }
    return ~crc;
}

static void WriteJson(object value) => Console.WriteLine(JsonSerializer.Serialize(
    value,
    new JsonSerializerOptions
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    }));

sealed record ColumnInfo(
    int Ordinal,
    string Name,
    string Type,
    bool NotNull,
    int PrimaryKeyOrdinal);
