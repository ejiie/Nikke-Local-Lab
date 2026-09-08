using System.Security.Cryptography;
using Microsoft.Data.Sqlite;

namespace ResourceCatalogPreflight;

// Offline source primitive. No URL construction, network fallback, HTTP route,
// catalog conversion or index writes. Native request mapping is a separate gate.
internal static class VirtualPakReader
{
  internal readonly record struct Span(long Offset, int Length, string Hash);
  internal const int MaximumRangeBytes = 16 * 1024 * 1024;

  internal static byte[] ReadRange(SqliteConnection catalog, ChunkStoreReader store,
      long pakId, long start, int length)
  {
    ValidateRange(start, length);
    using var command = catalog.CreateCommand();
    command.CommandText = """
        SELECT pak_offset,compressed_size,hex(hash) FROM chunks
        WHERE pak_id=$pak AND pak_offset<$end AND pak_offset+compressed_size>$start
        ORDER BY pak_offset
        """;
    command.Parameters.AddWithValue("$pak", pakId);
    command.Parameters.AddWithValue("$start", start);
    command.Parameters.AddWithValue("$end", checked(start + length));
    using var reader = command.ExecuteReader();
    var spans = new List<Span>();
    while (reader.Read()) spans.Add(new(reader.GetInt64(0), reader.GetInt32(1), reader.GetString(2)));
    return ReadRange(spans, start, length, store.ReadCompressedVerified);
  }

  internal static byte[] ReadRange(IReadOnlyList<Span> spans, long start, int length,
      Func<string, int, byte[]> readVerifiedChunk)
  {
    ValidateRange(start, length);
    var end = checked(start + length);
    long cursor = start;
    long previousEnd = -1;
    foreach (var span in spans)
    {
      if (span.Offset < 0 || span.Length is < 1 or > MaximumRangeBytes || span.Offset > long.MaxValue - span.Length ||
          span.Offset < previousEnd || span.Offset > cursor || span.Offset >= end || span.Offset + span.Length <= cursor)
        throw new PreflightException("resource_pak_range_layout_invalid");
      previousEnd = span.Offset + span.Length;
      cursor = Math.Min(previousEnd, end);
    }
    if (cursor != end) throw new PreflightException("resource_pak_range_unavailable");

    var output = new byte[length];
    try
    {
      foreach (var span in spans)
      {
        var compressed = readVerifiedChunk(span.Hash, span.Length);
        try
        {
          if (compressed.Length != span.Length) throw new PreflightException("resource_pak_chunk_length_mismatch");
          var from = Math.Max(start, span.Offset);
          var to = Math.Min(end, span.Offset + span.Length);
          compressed.AsSpan(checked((int)(from - span.Offset)), checked((int)(to - from)))
              .CopyTo(output.AsSpan(checked((int)(from - start))));
        }
        finally { CryptographicOperations.ZeroMemory(compressed); }
      }
      return output;
    }
    catch { CryptographicOperations.ZeroMemory(output); throw; }
  }

  private static void ValidateRange(long start, int length)
  {
    if (start < 0 || length is < 1 or > MaximumRangeBytes || start > long.MaxValue - length)
      throw new PreflightException("resource_pak_range_invalid");
  }
}
