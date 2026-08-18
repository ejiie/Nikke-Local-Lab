using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.Import.CharacterCatalog;

public sealed record CharacterCatalogRuntimeCaps
{
  public CharacterCatalogRuntimeCaps(int normalMaximumBond, int overspecMaximumBond)
  {
    if (normalMaximumBond <= 0 || overspecMaximumBond < normalMaximumBond)
    {
      throw new CharacterCatalogSourceException("runtime_caps_invalid");
    }

    NormalMaximumBond = normalMaximumBond;
    OverspecMaximumBond = overspecMaximumBond;
  }

  public int NormalMaximumBond { get; }

  public int OverspecMaximumBond { get; }

  public int? ForCorporationSubtype(int subtype) => subtype switch
  {
    0 => NormalMaximumBond,
    1 => OverspecMaximumBond,
    _ => null
  };
}

public sealed class SdBinCharacterConfigReader
{
  private static readonly ZipArchiveLimits ArchiveLimits = new(
      MaximumEntryCount: 32,
      MaximumEntryBytes: 4 * 1024 * 1024,
      MaximumTotalBytes: 8 * 1024 * 1024,
      MaximumCompressionRatio: 100m);

  public CharacterCatalogRuntimeCaps Read(Stream sdBin)
  {
    ArgumentNullException.ThrowIfNull(sdBin);
    if (!sdBin.CanRead || !sdBin.CanSeek)
    {
      throw new CharacterCatalogSourceException("game_config_stream_invalid");
    }

    if (sdBin.Length is <= 0 or > 16L * 1024 * 1024)
    {
      throw new CharacterCatalogSourceException("game_config_archive_size_invalid");
    }

    try
    {
      using var archive = new ZipArchive(sdBin, ZipArchiveMode.Read, leaveOpen: true);
      var entries = ZipArchiveGuard.Validate(archive, ArchiveLimits);
      var matches = entries.Where(entry =>
          string.Equals(
              Path.GetFileNameWithoutExtension(ZipArchiveGuard.FileName(entry)),
              "ConfigGameTable",
              StringComparison.Ordinal) &&
          string.Equals(
              Path.GetExtension(ZipArchiveGuard.FileName(entry)),
              ".json",
              StringComparison.OrdinalIgnoreCase)).ToArray();
      if (matches.Length != 1)
      {
        throw new CharacterCatalogSourceException("game_config_table_invalid");
      }

      var bytes = ZipArchiveGuard.ReadExactly(matches[0]);
      try
      {
        return ReadConfigTable(bytes);
      }
      finally
      {
        CryptographicOperations.ZeroMemory(bytes);
      }
    }
    catch (CharacterCatalogSourceException)
    {
      throw;
    }
    catch (Exception exception) when (exception is InvalidDataException or IOException or JsonException)
    {
      throw new CharacterCatalogSourceException("game_config_archive_invalid");
    }
  }

  private static CharacterCatalogRuntimeCaps ReadConfigTable(ReadOnlyMemory<byte> bytes)
  {
    using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions
    {
      AllowTrailingCommas = false,
      CommentHandling = JsonCommentHandling.Disallow,
      MaxDepth = 8
    });
    if (document.RootElement.ValueKind != JsonValueKind.Object ||
        !document.RootElement.TryGetProperty("records", out var records) ||
        records.ValueKind != JsonValueKind.Array ||
        records.GetArrayLength() is < 1 or > 2_000)
    {
      throw new CharacterCatalogSourceException("game_config_schema_invalid");
    }

    int? normal = null;
    int? overspec = null;
    var identifiers = new HashSet<string>(StringComparer.Ordinal);
    foreach (var record in records.EnumerateArray())
    {
      if (record.ValueKind != JsonValueKind.Object ||
          !record.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String ||
          !record.TryGetProperty("value", out var value))
      {
        throw new CharacterCatalogSourceException("game_config_schema_invalid");
      }

      var identifier = id.GetString();
      if (string.IsNullOrEmpty(identifier) || identifier.Length > 256 || !identifiers.Add(identifier))
      {
        throw new CharacterCatalogSourceException("game_config_identifier_invalid");
      }

      switch (identifier)
      {
        case "AttractiveNormalMaxLv":
          normal = ReadPositiveInteger(value);
          break;
        case "AttractiveOverspecMaxLv":
          overspec = ReadPositiveInteger(value);
          break;
      }
    }

    if (normal is null || overspec is null || overspec < normal)
    {
      throw new CharacterCatalogSourceException("bond_caps_missing");
    }

    return new CharacterCatalogRuntimeCaps(normal.Value, overspec.Value);
  }

  private static int ReadPositiveInteger(JsonElement value)
  {
    int parsed;
    if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out parsed) && parsed > 0)
    {
      return parsed;
    }

    if (value.ValueKind == JsonValueKind.String &&
        int.TryParse(
            value.GetString(),
            System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture,
            out parsed) && parsed > 0)
    {
      return parsed;
    }

    throw new CharacterCatalogSourceException("bond_cap_value_invalid");
  }
}
