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
      var marker = plan.RunRoot + @"\native-store.started.json";
      var changed = false;
      string digest;
      if (operation == "inspect" || ranges.Count == 0)
      {
        digest = Hash(store);
        Require(digest == plan.OriginalStore.Sha256 || digest == plan.CandidateStoreSha256);
      }
      else if (operation == "apply")
      {
        // Flush durable rollback identity BEFORE the first possible CDB write.
        // The before/after chunk leases remain locked throughout the operation.
        Require(UserValidationStoreTransaction.Prepare(store, ranges, seal.OriginalSha256) == seal);
        Save(marker, new
        {
          contractId = "nll/native-fx-user-validation-store-started/v1",
          planSha256,
          plan.TrialUid,
          plan.AssessmentUid,
          rollbackInputsVerified = true,
          mutationComplete = false
        });
        UserValidationStoreTransaction.Apply(store, ranges, seal); changed = true; digest = seal.CandidateSha256;
      }
      else
      {
        if (!File.Exists(marker))
        {
          digest = Hash(store); Require(digest == seal.OriginalSha256);
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
          changed = UserValidationStoreTransaction.Restore(store, ranges, seal); digest = seal.OriginalSha256;
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
        bytesChanged = changed,
        scopeZeroVerifiedByCaller = scopeZeroVerified,
        gameStarted = false,
        nativeAdmission = "not_assessed",
        actualGameAcceptanceClaimed = false
      };
      if (operation != "inspect") Save(plan.RunRoot + @"\native-store-" + operation + "-" + Guid.NewGuid().ToString("N") + ".receipt.json", receipt);
      return JsonSerializer.Serialize(receipt, Json);
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
