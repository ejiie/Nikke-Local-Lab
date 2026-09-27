using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace NikkeLocalLab.Phase3B2.UserValidation;

// Feasibility prototype, deliberately not referenced by a launcher/store/bootstrap.
// A successful comparison is NOT a production admission or a cross-process permit.
internal sealed record UserValidationGenerationWitness(uint Volume, ulong FileId, long Length, long FileUsn,
    ulong JournalId, long FirstUsn, long NextUsn, long LowestValidUsn, Guid BootId);
internal sealed record UserValidationGenerationSample(string ContentSha256, UserValidationGenerationWitness Witness);

internal static class UserValidationGenerationPrototype
{
  internal static UserValidationGenerationSample Prepare(string path)
  {
    using var stream = OpenExclusive(path);
    var before = Observe(stream);
    var digest = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    var after = Observe(stream);
    Require(Reusable(before, after));
    return new(digest, after);
  }

  internal static UserValidationGenerationWitness Verify(string path, UserValidationGenerationSample sample)
  {
    using var stream = OpenExclusive(path);
    var current = Observe(stream);
    Require(Reusable(sample.Witness, current));
    return current;
  }

  internal static bool Reusable(UserValidationGenerationWitness before, UserValidationGenerationWitness current) =>
      before.BootId != Guid.Empty && current.BootId == before.BootId && before.Volume == current.Volume &&
      before.FileId != 0 && before.FileId == current.FileId && before.Length >= 0 && before.Length == current.Length &&
      before.FileUsn >= 0 && before.FileUsn == current.FileUsn && before.JournalId == current.JournalId &&
      before.NextUsn > before.FileUsn && current.NextUsn >= before.NextUsn &&
      current.FirstUsn <= before.NextUsn && current.LowestValidUsn <= before.NextUsn &&
      current.FirstUsn >= 0 && current.LowestValidUsn >= 0;

  private static FileStream OpenExclusive(string path)
  {
    Require(OperatingSystem.IsWindows() && Path.GetFullPath(path) == path);
    for (FileSystemInfo? item = new FileInfo(path); item is not null;
        item = item is FileInfo file ? file.Directory : ((DirectoryInfo)item).Parent)
      Require(item.Exists && (item.Attributes & FileAttributes.ReparsePoint) == 0);
    return new(path, FileMode.Open, FileAccess.Read, FileShare.None);
  }

  private static UserValidationGenerationWitness Observe(FileStream stream)
  {
    if (!GetFileInformationByHandle(stream.SafeFileHandle, out var info)) throw new Win32Exception(Marshal.GetLastWin32Error());
    Require(info.Links == 1 && (info.Attributes & 0x400) == 0);
    var root = Path.GetPathRoot(stream.Name)!;
    Require(new DriveInfo(root).DriveFormat == "NTFS");
    using var volume = CreateFile(@"\\.\" + root.TrimEnd('\\'), 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (volume.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    var journal = new byte[128];
    if (!DeviceIoControl(volume, 0x900f4, null, 0, journal, journal.Length, out var count, IntPtr.Zero))
      throw new Win32Exception(Marshal.GetLastWin32Error());
    Require(count >= 56);
    var record = new byte[4096]; byte[] versions = [2, 0, 2, 0];
    if (!DeviceIoControl(stream.SafeFileHandle, 0x900eb, versions, versions.Length, record, record.Length, out count, IntPtr.Zero))
      throw new Win32Exception(Marshal.GetLastWin32Error());
    Require(count >= 60 && BitConverter.ToUInt16(record, 4) == 2);
    var boot = new byte[32];
    Require(NtQuerySystemInformation(90, boot, boot.Length, out count) == 0 && count >= 20);
    return new(info.Volume, ((ulong)info.IndexHigh << 32) | info.IndexLow, stream.Length,
        BitConverter.ToInt64(record, 24), BitConverter.ToUInt64(journal, 0), BitConverter.ToInt64(journal, 8),
        BitConverter.ToInt64(journal, 16), BitConverter.ToInt64(journal, 24), new Guid(boot.AsSpan(0, 16)));
  }
  private static void Require(bool value)
  { if (!value) throw new InvalidOperationException("user_validation_generation_reverification_required"); }
  [StructLayout(LayoutKind.Sequential)]
  private struct FileInformation
  {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation info);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint mode, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool DeviceIoControl(SafeFileHandle file, uint code, byte[]? input, int inputSize, byte[] output, int outputSize, out uint returned, IntPtr overlapped);
  [DllImport("ntdll.dll")] private static extern int NtQuerySystemInformation(int infoClass, byte[] output, int size, out uint returned);
}
