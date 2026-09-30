using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using NikkeLocalLab.Automation;
using NikkeLocalLab.Phase3B2.UserValidation;
using static CommonDeliveryFiles;

// Uses the existing tested byte-range transaction. No executable, service,
// driver, voice, catalog or index modification is part of this operation.
internal static class CommonNativeFx
{
  private static void Require(bool ok) => CommonDeliveryFiles.Require(ok);
  internal static FileStream OpenStore(CommonFilePin pin, bool write, int bufferSize = 1048576)
  {
    Require(OperatingSystem.IsWindows());
    var path = Plain(pin.Path);
    _ = InstalledStoreBuild(path);
    var file = new FileStream(path, FileMode.Open, write ? FileAccess.ReadWrite : FileAccess.Read, FileShare.None, bufferSize);
    try
    {
      Require(GetFileInformationByHandle(file.SafeFileHandle, out var info) && info.Links == 1 && file.Length == pin.Length &&
          (info.Attributes & (uint)FileAttributes.ReparsePoint) == 0);
      return file;
    }
    catch { file.Dispose(); throw; }
  }
  internal static void Cold()
  {
    foreach (var name in new[] { "nikke", "nikke_launcher", "EpinelPS", "ACE-Service64", "NikkeLocalLab.Phase3B2.PhysicalBootstrap" })
    {
      var processes = Process.GetProcessesByName(name);
      try { Require(processes.Length == 0); } finally { foreach (var process in processes) process.Dispose(); }
    }
  }
  internal static void Apply(string root, string hash, ExecutionAssetBinding binding, string _, Action verify) =>
      Execute(root, hash, binding, "", verify, true);
  internal static void Restore(string root, string hash, ExecutionAssetBinding binding, string termination, Action verify) =>
      Execute(root, hash, binding, termination, verify, false);

  private static void Execute(string root, string hash, ExecutionAssetBinding binding, string termination, Action verify, bool apply)
  {
    root = Plain(root); verify(); Cold();
    var manifestPath = Path.Combine(root, "manifest.private.json");
    using var manifest = ReadJson(manifestPath, hash);
    if (Text(manifest.RootElement, "contractId") == NikkeLocalLab.PhaseD.NativeFxRangeTransaction.Contract)
    {
      NativeFxExecutionDelivery.Execute(root, hash, binding.ExecutionCode, binding.ProfileSha256,
          binding.CandidateSealSha256, binding.WeaknessCode, termination, apply,
          () => { verify(); Cold(); }, CommonNativeFxBaseline.ValidateRegistration,
          registration =>
          {
            // Disable FileStream read-ahead: a tiny selected range must not
            // cause the old 1MiB buffer to fetch unrelated CDB contents.
            var stream = OpenStore(registration.OriginalStore, true, bufferSize: 1);
            try { return new(stream, Identity(stream)); } catch { stream.Dispose(); throw; }
          });
      return;
    }
    var plan = manifest.RootElement.Deserialize<CommonNativeExecution>(Json)!;
    Require(plan.ContractId == "nll/common-native-fx-execution/v1" && plan.ExecutionUid == binding.ExecutionCode &&
        plan.ProfileSha256 == binding.ProfileSha256 && plan.CandidateSealSha256 == binding.CandidateSealSha256 && plan.WeaknessCode == binding.WeaknessCode &&
        plan.Patches.Length is > 0 and <= 32);
    var target = plan.WeaknessCode switch { "fire" => "wind", "water" => "fire", "wind" => "iron", "electric" => "water", "iron" => "electric", _ => "" };
    var leases = new List<FileStream>();
    try
    {
      byte[] Chunk(CommonFilePin pin, int index, string kind)
      {
        Require(Plain(pin.Path) == Path.Combine(root, $"{index}.{kind}.chunk") && pin.Length is > 0 and <= 16777216);
        var input = new FileStream(pin.Path, FileMode.Open, FileAccess.Read, FileShare.Read); leases.Add(input);
        Require(input.Length == pin.Length); var bytes = new byte[checked((int)input.Length)]; input.ReadExactly(bytes);
        Require(Hash(bytes) == pin.Sha256); return bytes;
      }
      var ranges = plan.Patches.Select((row, index) =>
      {
        Require(row.RoleCode == target);
        return new UserValidationStoreRange(row.Offset, Chunk(row.Before, index, "before"), Chunk(row.After, index, "after"));
      }).ToArray();
      var marker = Path.Combine(root, "applied-started.json"); var retired = Path.Combine(root, "retired.json");
      using var store = OpenStore(plan.OriginalStore, true);
      var seal = new UserValidationStoreSeal(store.Length, plan.OriginalStore.Sha256, plan.CandidateStoreSha256);
      if (apply)
      {
        Require(!File.Exists(marker) && !File.Exists(retired));
        UserValidationStoreTransaction.Apply(store, ranges, seal, () =>
        {
          verify(); Cold(); Require(FileHash(manifestPath) == hash);
          Save(marker, new { contractId = "nll/common-native-fx-started/v1", manifestSha256 = hash, plan.ExecutionUid });
        });
        Save(Path.Combine(root, "applied.json"), new { manifestSha256 = hash, storeSha256 = seal.CandidateSha256 });
      }
      else
      {
        if (File.Exists(marker))
        {
          using var started = JsonDocument.Parse(File.ReadAllBytes(Plain(marker)));
          Require(Text(started.RootElement, "contractId") == "nll/common-native-fx-started/v1" &&
              Text(started.RootElement, "manifestSha256") == hash && Text(started.RootElement, "executionUid") == plan.ExecutionUid);
          UserValidationStoreTransaction.Restore(store, ranges, seal);
        }
        else Require(Convert.ToHexString(SHA256.HashData(store)).ToLowerInvariant() == seal.OriginalSha256);
        verify(); Cold();
        if (!File.Exists(retired)) Save(retired, new
        {
          contractId = "nll/common-native-fx-retired/v1",
          manifestSha256 = hash,
          terminationReceiptSha256 = termination,
          storeSha256 = seal.OriginalSha256,
          actualGameAcceptanceClaimed = false
        });
        else
        {
          using var old = JsonDocument.Parse(File.ReadAllBytes(Plain(retired)));
          Require(Text(old.RootElement, "manifestSha256") == hash && Text(old.RootElement, "storeSha256") == seal.OriginalSha256);
        }
      }
      verify();
    }
    finally { foreach (var lease in leases) lease.Dispose(); }
  }
  internal static NikkeLocalLab.PhaseD.NativeFxStoreIdentity Identity(FileStream stream)
  {
    Require(GetFileInformationByHandle(stream.SafeFileHandle, out var info) && info.Links == 1 &&
        (info.Attributes & (uint)FileAttributes.ReparsePoint) == 0);
    return new(info.Volume.ToString("x8"), info.IndexHigh.ToString("x8") + info.IndexLow.ToString("x8"), stream.Length);
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct FileInformation
  {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);
}
