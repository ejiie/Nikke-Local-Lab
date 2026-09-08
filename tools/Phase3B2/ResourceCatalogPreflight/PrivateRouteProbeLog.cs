using System.Security.Cryptography;
using System.Text.Json;

namespace ResourceCatalogPreflight;

internal sealed class PrivateRouteProbeLog : IDisposable
{
  private readonly FileStream stream;
  private readonly object gate = new();
  private const int MaximumBytes = 256 * 1024;
  private int count;
  private bool writeFailed;

  // allowedParent is fixed by the host, never read from an untrusted manifest.
  internal PrivateRouteProbeLog(string directory, string allowedParent)
  {
    var full = Path.GetFullPath(directory);
    var parent = Path.GetFullPath(allowedParent).TrimEnd(Path.DirectorySeparatorChar);
    if (!full.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
        !Guid.TryParseExact(Path.GetRelativePath(parent, full), "D", out _))
      throw new PreflightException("resource_probe_evidence_path_invalid");
    for (DirectoryInfo? entry = new DirectoryInfo(full); entry is not null; entry = entry.Parent)
      if (!entry.Exists || (entry.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new PreflightException("resource_probe_evidence_path_invalid");
    stream = new FileStream(Path.Combine(full, "requests.private.jsonl"),
        FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
  }

  internal bool TryRecord(ResourceRouteProbe.Observation observation)
  {
    var bytes = JsonSerializer.SerializeToUtf8Bytes(observation);
    lock (gate)
    {
      if (writeFailed || bytes.Length > 8192 || stream.Length + bytes.Length + 1 > MaximumBytes || count >= 256)
        return false;
      try
      {
        stream.Write(bytes);
        stream.WriteByte((byte)'\n');
        stream.Flush(flushToDisk: true);
      }
      catch (Exception error) when (error is IOException or UnauthorizedAccessException)
      {
        writeFailed = true;
        throw;
      }
      count++;
      return true;
    }
  }

  internal object Summary()
  {
    lock (gate)
    {
      stream.Flush(flushToDisk: true);
      stream.Position = 0;
      var digest = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
      stream.Position = stream.Length;
      return new
      {
        contractId = "nll/resource-route-probe-observation/v1",
        requestCount = count,
        status = writeFailed ? "private_log_io_failed" : "bounded_observation_finished",
        byteLength = stream.Length,
        sha256 = digest,
        rawPathEmitted = false,
        nativeAdmission = "not_evaluated"
      };
    }
  }

  public void Dispose() => stream.Dispose();
}
