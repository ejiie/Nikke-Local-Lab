using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

// All IO is read-only. Keep the returned lease open while consuming small
// runtime inputs. Large client/cache files are hashed as streams, never arrays.
internal static class UserValidationPinnedFiles
{
  internal static FileStream Open(string path, long length, string sha256, long limit, Action<int>? observeRead = null)
  {
    Require(OperatingSystem.IsWindows() && length >= 0 && length <= limit &&
        UserValidationBootstrapPlan.IsHash(sha256) && Path.GetFullPath(path) == path);
    AssertNoReparse(path);
    var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
        1024 * 1024, FileOptions.SequentialScan);
    try
    {
      Require(GetFileInformationByHandle(stream.SafeFileHandle, out var info) && info.NumberOfLinks == 1 &&
          (info.FileAttributes & (uint)FileAttributes.ReparsePoint) == 0);
      Require(stream.Length == length);
      using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
      var buffer = new byte[1024 * 1024];
      int count;
      while ((count = stream.Read(buffer)) != 0) { observeRead?.Invoke(count); hash.AppendData(buffer, 0, count); }
      Require(Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() == sha256);
      AssertNoReparse(path);
      stream.Position = 0;
      return stream;
    }
    catch { stream.Dispose(); throw; }
  }

  internal static void AssertNoReparse(string path)
  {
    for (FileSystemInfo? entry = File.Exists(path) ? new FileInfo(path) : new DirectoryInfo(path);
        entry is not null; entry = entry is FileInfo file ? file.Directory : ((DirectoryInfo)entry).Parent)
      Require(entry.Exists && (entry.Attributes & FileAttributes.ReparsePoint) == 0);
  }

  internal static HashSet<string> Inventory(string root, int maximum)
  {
    AssertNoReparse(root);
    var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var pending = new Stack<string>();
    pending.Push(root);
    var count = 0;
    while (pending.TryPop(out var directory))
      foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos())
      {
        Require(++count <= maximum * 4 && (entry.Attributes & FileAttributes.ReparsePoint) == 0);
        if (entry is DirectoryInfo) pending.Push(entry.FullName);
        else Require(files.Add(entry.FullName) && files.Count <= maximum);
      }
    return files;
  }

  private static void Require(bool value)
  {
    if (!value) throw new InvalidOperationException("user_validation_file_pin_rejected");
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct FileInformation
  {
    public uint FileAttributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
    public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
  }
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
}

// Per-process evidence only, never a launch permit or reusable integrity seal.
internal sealed class UserValidationPreflightMeasurement(string stage, string parentPlanSha256, long plannedBytes)
{
  private readonly DateTimeOffset started = DateTimeOffset.UtcNow;
  private readonly Stopwatch watch = Stopwatch.StartNew();
  internal long CompletedReadBytes { get; private set; }
  internal void Observe(int bytes) => CompletedReadBytes = checked(CompletedReadBytes + bytes);
  internal void Save(string runRoot, bool passed)
  {
    UserValidationPinnedFiles.AssertNoReparse(runRoot);
    var path = Path.Combine(runRoot, stage + "-preflight-" + Guid.NewGuid().ToString("N") + ".json");
    var temporary = path + ".tmp";
    using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
    {
      JsonSerializer.Serialize(stream, new
      {
        contractId = "nll/user-validation-process-preflight/v1",
        stage,
        parentPlanSha256,
        startedAtUtc = started,
        completedAtUtc = DateTimeOffset.UtcNow,
        elapsedMilliseconds = watch.Elapsed.TotalMilliseconds,
        plannedReadBytes = plannedBytes,
        completedReadBytes = CompletedReadBytes,
        readAccountingScope = "runtime_and_client_pin_hashes",
        statusCode = passed ? "verified" : "failed",
        actualGameAcceptanceClaimed = false
      });
      stream.Flush(true);
    }
    File.Move(temporary, path);
  }
}
