using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace NikkeLocalLab.Import.RaidCatalog;

internal readonly record struct ZipArchiveLimits(
    int MaximumEntryCount,
    long MaximumEntryBytes,
    long MaximumTotalBytes,
    decimal MaximumCompressionRatio);

internal static class ZipArchiveGuard
{
  public static IReadOnlyList<ZipArchiveEntry> Validate(ZipArchive archive, ZipArchiveLimits limits)
  {
    ArgumentNullException.ThrowIfNull(archive);
    if (archive.Entries.Count < 1 || archive.Entries.Count > limits.MaximumEntryCount)
    {
      throw new ChallengeRaidCatalogSourceException("archive_entry_count_invalid");
    }

    var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var entries = new ZipArchiveEntry[archive.Entries.Count];
    long totalBytes = 0;
    for (var index = 0; index < archive.Entries.Count; index++)
    {
      var entry = archive.Entries[index];
      var name = ValidateName(entry.FullName);
      if (!names.Add(name))
      {
        throw new ChallengeRaidCatalogSourceException("archive_entry_duplicate");
      }

      if (entry.Length <= 0 || entry.Length > limits.MaximumEntryBytes)
      {
        throw new ChallengeRaidCatalogSourceException("archive_entry_size_invalid");
      }

      try
      {
        totalBytes = checked(totalBytes + entry.Length);
      }
      catch (OverflowException)
      {
        throw new ChallengeRaidCatalogSourceException("archive_total_size_invalid");
      }

      if (totalBytes > limits.MaximumTotalBytes)
      {
        throw new ChallengeRaidCatalogSourceException("archive_total_size_invalid");
      }

      if (entry.CompressedLength <= 0 ||
          (decimal)entry.Length / entry.CompressedLength > limits.MaximumCompressionRatio)
      {
        throw new ChallengeRaidCatalogSourceException("archive_compression_ratio_invalid");
      }

      entries[index] = entry;
    }

    return Array.AsReadOnly(entries);
  }

  public static byte[] ReadExactly(ZipArchiveEntry entry)
  {
    if (entry.Length is <= 0 or > int.MaxValue)
    {
      throw new ChallengeRaidCatalogSourceException("archive_entry_size_invalid");
    }

    var result = GC.AllocateUninitializedArray<byte>((int)entry.Length);
    try
    {
      using var source = entry.Open();
      var offset = 0;
      while (offset < result.Length)
      {
        var read = source.Read(result, offset, result.Length - offset);
        if (read == 0)
        {
          throw new ChallengeRaidCatalogSourceException("archive_entry_length_mismatch");
        }

        offset += read;
      }

      if (source.ReadByte() != -1)
      {
        throw new ChallengeRaidCatalogSourceException("archive_entry_length_mismatch");
      }

      return result;
    }
    catch
    {
      CryptographicOperations.ZeroMemory(result);
      throw;
    }
  }

  public static string FileName(ZipArchiveEntry entry)
  {
    var separator = entry.FullName.LastIndexOf('/');
    return separator < 0 ? entry.FullName : entry.FullName[(separator + 1)..];
  }

  private static string ValidateName(string value)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 512 || value[0] == '/' ||
        value.Contains('\\', StringComparison.Ordinal) ||
        value.Contains(':', StringComparison.Ordinal) || value.Any(char.IsControl))
    {
      throw new ChallengeRaidCatalogSourceException("archive_entry_name_invalid");
    }

    var segments = value.Split('/');
    if (segments.Any(segment => segment.Length == 0 || segment is "." or ".."))
    {
      throw new ChallengeRaidCatalogSourceException("archive_entry_name_invalid");
    }

    return value.Normalize(NormalizationForm.FormC);
  }
}
