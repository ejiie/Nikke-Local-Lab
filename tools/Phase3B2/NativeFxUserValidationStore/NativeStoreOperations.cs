using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using NikkeLocalLab.Phase3B2.LocalBootstrap;

namespace NikkeLocalLab.Phase3B2.UserValidation;

// Loaded by the source-reviewed controller, not a game launcher. Importing this
// assembly has no IO. The controller owns the global run lock and independently
// proves Job/service/related-process zero. A boolean is NOT an OS observation.
public static class NativeStoreOperations
{
  public static void AssertPhysicalFile(string path)
  {
    Require(OperatingSystem.IsWindows());
    UserValidationPinnedFiles.AssertNoReparse(path);
    using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    AssertPhysicalFile(file);
  }
  public static void AssertPhysicalFile(FileStream file)
  {
    Require(OperatingSystem.IsWindows());
    UserValidationPinnedFiles.AssertNoReparse(file.Name);
    Require(GetFileInformationByHandle(file.SafeFileHandle, out var info) && info.NumberOfLinks == 1 &&
        (info.FileAttributes & (uint)FileAttributes.ReparsePoint) == 0);
  }

  // Preparation only reads the client. A placeholder hash is never a launch
  // permit: replace it with the full-stream projected hash and seal a NEW plan.
  public static string Prepare(string inputPath, string inputSha256)
  {
    Require(OperatingSystem.IsWindows());
    using var input = UserValidationPinnedFiles.Open(inputPath, new FileInfo(inputPath).Length, inputSha256, 1048576);
    var bytes = new byte[checked((int)input.Length)]; input.ReadExactly(bytes);
    var plan = UserValidationStorePlan.Parse(bytes);
    Require(inputPath == plan.RunRoot + @"\native-store.input.json" && !File.Exists(plan.PlanPath) &&
        plan.CandidateStoreSha256 == (plan.Patches.Length == 0 ? plan.OriginalStore.Sha256 : new string('0', 64)));
    var leases = new List<FileStream>();
    try
    {
      var ranges = new List<UserValidationStoreRange>();
      foreach (var patch in plan.Patches)
      {
        byte[] Read(UserValidationFilePin pin)
        {
          var lease = UserValidationPinnedFiles.Open(pin.Path, pin.Length, pin.Sha256, 16777216); leases.Add(lease);
          var data = new byte[checked((int)lease.Length)]; lease.ReadExactly(data); return data;
        }
        ranges.Add(new(patch.Offset, Read(patch.Before), Read(patch.After)));
      }
      UserValidationPinnedFiles.AssertNoReparse(plan.OriginalStore.Path);
      using var store = new FileStream(plan.OriginalStore.Path, FileMode.Open, FileAccess.Read, FileShare.None, 1048576);
      Require(GetFileInformationByHandle(store.SafeFileHandle, out var info) && info.NumberOfLinks == 1 &&
          (info.FileAttributes & (uint)FileAttributes.ReparsePoint) == 0 && store.Length == plan.OriginalStore.Length);
      var digest = ranges.Count == 0 ? Hash(store) : UserValidationStoreTransaction.Prepare(store, ranges, plan.OriginalStore.Sha256).CandidateSha256;
      Require(ranges.Count != 0 || digest == plan.OriginalStore.Sha256);
      var prepared = plan with { CandidateStoreSha256 = digest };
      prepared.Validate(); Save(plan.PlanPath, prepared);
      return JsonSerializer.Serialize(new
      {
        contractId = "nll/native-fx-user-validation-store-prepared/v1",
        plan.TrialUid,
        plan.AssessmentUid,
        plan.WeaknessCode,
        candidateStoreSha256 = digest,
        clientModified = false,
        gameStarted = false,
        actualGameAcceptanceClaimed = false
      }, Json);
    }
    finally { foreach (var lease in leases) lease.Dispose(); }
  }

  public static string Execute(string planPath, string planSha256, string operation, bool scopeZeroVerified)
  {
    Require(OperatingSystem.IsWindows() && operation is "inspect" or "apply" or "restore" &&
        (operation == "inspect" || scopeZeroVerified));
    using var planLease = UserValidationPinnedFiles.Open(planPath, new FileInfo(planPath).Length, planSha256, 1048576);
    var bytes = new byte[checked((int)planLease.Length)]; planLease.ReadExactly(bytes);
    var plan = UserValidationStorePlan.Parse(bytes);
    Require(plan.PlanPath == planPath);
    UserValidationPinnedFiles.AssertNoReparse(plan.RunRoot);
    var leases = new List<FileStream>();
    UserValidationReadMeter? meter = null;
    try
    {
      var ranges = new List<UserValidationStoreRange>();
      foreach (var patch in plan.Patches)
      {
        byte[] Read(UserValidationFilePin pin)
        {
          var input = UserValidationPinnedFiles.Open(pin.Path, pin.Length, pin.Sha256, 16777216); leases.Add(input);
          var content = new byte[checked((int)input.Length)]; input.ReadExactly(content); return content;
        }
        ranges.Add(new(patch.Offset, Read(patch.Before), Read(patch.After)));
      }
      UserValidationPinnedFiles.AssertNoReparse(plan.OriginalStore.Path);
      using var store = new FileStream(plan.OriginalStore.Path, FileMode.Open,
          operation == "inspect" ? FileAccess.Read : FileAccess.ReadWrite, FileShare.None, 1048576);
      Require(GetFileInformationByHandle(store.SafeFileHandle, out var info) && info.NumberOfLinks == 1 &&
          (info.FileAttributes & (uint)FileAttributes.ReparsePoint) == 0 && store.Length == plan.OriginalStore.Length);
      var seal = new UserValidationStoreSeal(store.Length, plan.OriginalStore.Sha256, plan.CandidateStoreSha256);
      using var measured = new UserValidationReadMeter(store);
      meter = measured;
      var marker = plan.RunRoot + @"\native-store.started.json";
      var changed = false;
      string digest;
      if (operation == "inspect" || ranges.Count == 0)
      {
        digest = Hash(measured);
        Require(digest == plan.OriginalStore.Sha256 || digest == plan.CandidateStoreSha256);
      }
      else if (operation == "apply")
      {
        // Flush durable rollback identity BEFORE the first possible CDB write.
        // The before/after chunk leases remain locked throughout the operation.
        UserValidationStoreTransaction.Apply(measured, ranges, seal, () => Save(marker, new
        {
          contractId = "nll/native-fx-user-validation-store-started/v1",
          planSha256,
          plan.TrialUid,
          plan.AssessmentUid,
          rollbackInputsVerified = true,
          mutationComplete = false
        }));
        changed = true; digest = seal.CandidateSha256;
      }
      else
      {
        if (!File.Exists(marker))
        {
          digest = Hash(measured); Require(digest == seal.OriginalSha256);
        }
        else
        {
          UserValidationPinnedFiles.AssertNoReparse(marker);
          Require(new FileInfo(marker).Length is > 0 and <= 65536);
          using var started = JsonDocument.Parse(File.ReadAllBytes(marker));
          var root = started.RootElement; UserValidationBootstrapPlan.RejectDuplicates(root);
          Require(root.GetProperty("contractId").GetString() == "nll/native-fx-user-validation-store-started/v1" &&
              root.GetProperty("planSha256").GetString() == planSha256 &&
              root.GetProperty("trialUid").GetString() == plan.TrialUid && root.GetProperty("assessmentUid").GetString() == plan.AssessmentUid &&
              root.GetProperty("rollbackInputsVerified").GetBoolean());
          changed = UserValidationStoreTransaction.Restore(measured, ranges, seal); digest = seal.OriginalSha256;
        }
      }
      var receipt = new
      {
        contractId = "nll/native-fx-user-validation-store-operation/v1",
        planSha256,
        plan.TrialUid,
        plan.AssessmentUid,
        plan.WeaknessCode,
        plan.CaseCode,
        operation,
        storeSha256 = digest,
        storeBytesRead = measured.BytesRead,
        bytesChanged = changed,
        scopeZeroVerifiedByCaller = scopeZeroVerified,
        gameStarted = false,
        nativeAdmission = "not_assessed",
        actualGameAcceptanceClaimed = false
      };
      if (operation != "inspect") Save(plan.RunRoot + @"\native-store-" + operation + "-" + Guid.NewGuid().ToString("N") + ".receipt.json", receipt);
      return JsonSerializer.Serialize(receipt, Json);
    }
    catch (Exception error)
    {
      error.Data["userValidationStoreBytesRead"] = meter?.BytesRead ?? 0L;
      throw;
    }
    finally { foreach (var lease in leases) lease.Dispose(); }
  }
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  private static string Hash(Stream stream) { stream.Position = 0; return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
  private static void Save(string path, object value)
  {
    UserValidationPinnedFiles.AssertNoReparse(Path.GetDirectoryName(path)!);
    using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
    JsonSerializer.Serialize(output, value, Json); output.Flush(true);
  }
  private static void Require(bool value) { if (!value) throw new InvalidOperationException("user_validation_store_operation_rejected"); }
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
