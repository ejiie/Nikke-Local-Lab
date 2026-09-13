using System.Runtime.InteropServices;
using System.Security.Cryptography;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationPinnedFilesTests
{
  [Fact]
  public void ReadOnlyPinRejectsDriftHardlinksAndOversizeAndLeasePreventsOverwrite()
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = Directory.CreateTempSubdirectory("nll-user-validation-files-").FullName;
    try
    {
      var path = Path.Combine(root, "synthetic.bin");
      byte[] data = [1, 2, 3];
      File.WriteAllBytes(path, data);
      var hash = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
      using (var lease = UserValidationPinnedFiles.Open(path, 3, hash, 3))
      {
        Assert.Equal(1, lease.ReadByte());
        Assert.Throws<IOException>(() => File.WriteAllBytes(path, [4, 5, 6]));
      }
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(path, 3, hash, 2));
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(path, 2, hash, 3));
      File.WriteAllBytes(path, [4, 5, 6]);
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(path, 3, hash, 3));
      File.WriteAllBytes(path, data);
      var link = Path.Combine(root, "synthetic-alias.bin");
      Assert.True(CreateHardLink(link, path, IntPtr.Zero));
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(path, 3, hash, 3));
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Open(link, 3, hash, 3));
      var inventory = UserValidationPinnedFiles.Inventory(root, 2);
      Assert.Equal(2, inventory.Count);
      Assert.Contains(path, inventory);
      Assert.Contains(link, inventory);
      Assert.Throws<InvalidOperationException>(() => UserValidationPinnedFiles.Inventory(root, 1));
      var emptyPath = Path.Combine(root, "empty.txt");
      File.WriteAllBytes(emptyPath, []);
      using var emptyLease = UserValidationPinnedFiles.Open(emptyPath, 0,
          "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", 1);
      Assert.Equal(-1, emptyLease.ReadByte());
    }
    finally
    {
      if (Path.GetDirectoryName(root) != Path.TrimEndingDirectorySeparator(Path.GetTempPath()) ||
          !Path.GetFileName(root).StartsWith("nll-user-validation-files-", StringComparison.Ordinal) ||
          (File.GetAttributes(root) & FileAttributes.ReparsePoint) != 0) throw new InvalidOperationException("synthetic_cleanup_boundary_invalid");
      Directory.Delete(root, recursive: true);
    }
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool CreateHardLink(string link, string existing, IntPtr security);
}
