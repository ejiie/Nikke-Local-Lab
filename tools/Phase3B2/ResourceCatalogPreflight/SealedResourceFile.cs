using System.Security.Cryptography;

namespace ResourceCatalogPreflight;

// Exact manifest-bound raw/catalog bytes. Never apply the legacy NKDB -> SQLite
// projection to 151 patch catalogs or hash-named raw objects.
internal sealed class SealedResourceFile : IDisposable
{
  private readonly FileStream stream;
  private readonly object gate = new();
  internal long Length => stream.Length;

  internal SealedResourceFile(string path, long expectedLength, string expectedSha256,
      string? expectedPatchRawHash = null)
  {
    if (expectedLength < 0 || expectedLength > 512L * 1024 * 1024 ||
        !System.Text.RegularExpressions.Regex.IsMatch(expectedSha256, "\\A[a-f0-9]{64}\\z") ||
        (expectedPatchRawHash is not null &&
         !System.Text.RegularExpressions.Regex.IsMatch(expectedPatchRawHash, "\\A[A-Fa-f0-9]{32}\\z")))
      throw new PreflightException("resource_sealed_file_identity_invalid");
    var full = Path.GetFullPath(path);
    for (FileSystemInfo? entry = new FileInfo(full); entry is not null;
         entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
    {
      if (!entry.Exists || (entry.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new PreflightException("resource_sealed_file_path_invalid");
    }

    stream = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read);
    try
    {
      if (stream.Length != expectedLength ||
          Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != expectedSha256)
        throw new PreflightException("resource_sealed_file_drift");
      if (expectedPatchRawHash is not null)
      {
        stream.Position = 0;
        if (!Convert.ToHexString(SegmentedSpookyHash.Compute(stream, stream.Length))
            .Equals(expectedPatchRawHash, StringComparison.OrdinalIgnoreCase))
          throw new PreflightException("resource_patch_raw_digest_mismatch");
      }
    }
    catch { stream.Dispose(); throw; }
  }

  internal byte[] ReadRange(long start, int length)
  {
    lock (gate)
    {
      if (start < 0 || length is < 1 or > VirtualPakReader.MaximumRangeBytes || start > stream.Length - length)
        throw new PreflightException("resource_sealed_file_range_invalid");
      var bytes = new byte[length];
      stream.Position = start;
      stream.ReadExactly(bytes);
      return bytes;
    }
  }

  public void Dispose() { lock (gate) stream.Dispose(); }
}
