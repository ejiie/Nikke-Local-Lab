using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace NikkeLocalLab.Automation;

/// <summary>
/// Sealed-run retirement consumer. Opens (never creates or assigns to) the exact
/// Windows Job and retains it throughout cleanup. The coordinator must also hold
/// its proof lock, prohibit relaunch, and keep completion/PG workers outside it.
/// Explicit recovery may instead verify native NOT_FOUND and exited recorded
/// identities; applying never accepts an absent Job. This verifies exit, not
/// network isolation or native asset delivery.
/// </summary>
public static class ExecutionAssetRetirement
{
  public static void Retire(string launchRoot, string bundleSha256, string terminationSha256,
      Action<string, string, ExecutionAssetBinding, string, Action>? nativeOperation = null, bool applying = false,
      bool allowAbsentJob = false)
  {
    Require(OperatingSystem.IsWindows(), "platform_unsupported");
    launchRoot = Plain(launchRoot);
    var uid = Path.GetFileName(launchRoot);
    Require(Guid.TryParseExact(uid, "D", out var parsed) && parsed != Guid.Empty &&
        uid == parsed.ToString("D"), "execution_invalid");
    var runner = Path.Combine(launchRoot, "tools", "runner");
    var pins = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    JsonDocument Pinned(string path, string hash)
    {
      Require(IsSha(hash), "pin_invalid");
      var raw = Small(path);
      Require(Hash(raw) == hash, "metadata_drifted");
      pins.Add(Plain(path), hash);
      return JsonDocument.Parse(raw);
    }
    using var bundle = Pinned(Path.Combine(runner, "runner.bundle.json"), bundleSha256);
    var manifest = bundle.RootElement;
    Require(Text(manifest, "contractId") == "nll/phase-d-runner-bundle/v2" &&
        Text(manifest, "launchContextUid") == uid && Text(manifest, "engineCode") == "parameterized/v1",
        "bundle_invalid");
    var codePins = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var member in manifest.GetProperty("members").EnumerateArray())
    {
      var name = Text(member, "name");
      var hash = Text(member, "sha256");
      Require(Regex.IsMatch(name, "\\A[A-Za-z0-9_.-]+\\z") && IsSha(hash) && codePins.TryAdd(name, hash), "member_invalid");
      var path = Plain(Path.Combine(runner, name));
      Require(FileHash(path) == hash, "code_drifted");
      pins.Add(path, hash);
    }
    Require(codePins.ContainsKey("runner.input.json") && codePins.ContainsKey("Nll.PhaseDJob.ps1") &&
        codePins.ContainsKey("Nll.PhaseDJob.cs"), "job_closure_missing");
    var runtime = Plain(Path.Combine(launchRoot, "runtime"));
    var runtimeNames = new HashSet<string>(StringComparer.Ordinal);
    foreach (var member in manifest.GetProperty("runtimeCode").EnumerateArray())
    {
      var name = Text(member, "name");
      var hash = Text(member, "sha256");
      Require(Regex.IsMatch(name, "\\A[A-Za-z0-9_.-]+\\z") && IsSha(hash) && runtimeNames.Add(name), "runtime_member_invalid");
      var path = Plain(Path.Combine(runtime, name));
      Require(FileHash(path) == hash, "runtime_code_drifted");
      pins.Add(path, hash);
    }
    var actualCode = Directory.EnumerateFiles(runtime).Select(Path.GetFileName).OfType<string>()
        .Where(name => name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
            name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ||
            name.EndsWith(".deps.json", StringComparison.OrdinalIgnoreCase) ||
            name.EndsWith(".runtimeconfig.json", StringComparison.OrdinalIgnoreCase)).ToArray();
    Require(runtimeNames.Count > 0 && runtimeNames.SetEquals(actualCode), "runtime_closure_drifted");
    using var input = JsonDocument.Parse(Small(Path.Combine(runner, "runner.input.json")));
    var spec = input.RootElement;
    Require(Text(spec, "contractId") == "nll/phase-d-runner-input/v3" && Text(spec, "launchContextUid") == uid &&
        Plain(Text(spec, "launchRoot")) == launchRoot, "input_invalid");
    var nonce = Text(spec, "jobNonce");
    Require(Regex.IsMatch(nonce, "\\A[0-9a-f]{32}\\z"), "nonce_invalid");
    var fx = spec.GetProperty("executionFx");
    var binding = new ExecutionAssetBinding(parsed.ToString("N"), Text(fx, "candidateSealSha256"),
        Text(fx, "profileSha256"), Text(fx, "weaknessCode"));
    var fxSha = Text(fx, "manifestSha256");
    Require(binding.ProfileSha256 == Text(spec, "bossRuntimeVariantProfileSha256") &&
        binding.WeaknessCode == Text(spec, "weaknessCode"), "fx_binding_invalid");
    if (!applying)
    {
      using var termination = Pinned(Path.Combine(launchRoot, "job-zero.receipt.json"), terminationSha256);
      var proof = termination.RootElement;
      Require(Text(proof, "contractId") == "nll/phase-d-job-zero/v1" && Text(proof, "launchContextUid") == uid &&
          Text(proof, "runnerBundleSha256") == bundleSha256 && Text(proof, "jobNonce") == nonce &&
          proof.GetProperty("activeProcesses").GetInt32() == 0 && Plain(Text(proof, "runtimeRoot")) == runtime,
          "exit_proof_invalid");
    }
    else Require(!File.Exists(Path.Combine(launchRoot, "job-zero.receipt.json")), "execution_already_closed");
    using var job = OpenJobObject(0x0004, false, "Local\\NLL.PhaseD." + nonce); // QUERY only.
    var absent = job.IsInvalid && Marshal.GetLastWin32Error() == 2;
    Require(!job.IsInvalid || (absent && allowAbsentJob && !applying), "job_absent_or_inaccessible");
    void Verify()
    {
      foreach (var pin in pins) Require(FileHash(Plain(pin.Key)) == pin.Value, "sealed_input_drifted");
      if (absent)
      {
        using var probe = OpenJobObject(0x0004, false, "Local\\NLL.PhaseD." + nonce);
        Require(probe.IsInvalid && Marshal.GetLastWin32Error() == 2, "job_absent_or_inaccessible");
        Require(File.Exists(Plain(Path.Combine(launchRoot, "job-reservation.json"))), "job_reservation_missing");
        VerifyRecordedProcessesExited(launchRoot, uid);
        return;
      }
      Require(QueryLimits(job, 9, out var limits, (uint)Marshal.SizeOf<Extended>(), IntPtr.Zero) &&
          limits.Basic.Flags == 0x2000, "job_limits_invalid");
      Require(QueryAccounting(job, 1, out var accounting, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero) &&
          (applying ? accounting.ActiveProcesses > 0 : accounting.ActiveProcesses == 0), "job_zero_unproven");
      Require(IsProcessInJob(GetCurrentProcess(), job, out var inside) && inside == applying, "owner_membership_invalid");
    }
    Verify();
    var fxRoot = Path.Combine(runtime, "execution-fx");
    using var delivery = Pinned(Path.Combine(fxRoot, "manifest.private.json"), fxSha);
    if (Text(delivery.RootElement, "contractId") is "nll/common-native-fx-execution/v1" or "nll/common-native-fx-execution/v2")
    {
      Require(nativeOperation is not null, "native_consumer_missing");
      nativeOperation!(fxRoot, fxSha, binding, terminationSha256, Verify);
    }
    else
    {
      Require(!applying, "apply_contract_invalid");
      ExecutionAssetOverlay.RetireAfterProcessTreeExit(fxRoot, fxSha, binding, terminationSha256, Verify);
    }
  }

  private static void VerifyRecordedProcessesExited(string launchRoot, string uid)
  {
    void Exited(JsonElement identity, bool retirementWorker = false)
    {
      var pid = identity.GetProperty("processId").GetInt32();
      Require(pid > 0, "process_identity_unresolved");
      var path = Plain(Text(identity, "executablePath"));
      var exitedBeforeCapture = identity.TryGetProperty("exitedBeforeCapture", out var early) && early.ValueKind == JsonValueKind.True;
      DateTime started = default;
      Require(exitedBeforeCapture || identity.GetProperty("processStartedAtUtc").TryGetDateTime(out started), "process_identity_unresolved");
      Process process;
      try { process = Process.GetProcessById(pid); }
      catch (ArgumentException) { return; }
      using (process)
      {
        // Access errors and PID reuse remain unresolved, as in the PowerShell reader.
        _ = process.Handle;
        Require(!exitedBeforeCapture && process.StartTime.ToUniversalTime().Ticks == started.ToUniversalTime().Ticks,
            "process_identity_mismatch");
        if (process.HasExited) return;
        // The parent checked all former workers before creating THIS consumer.
        // Only its exact PID/start/path in the retirement identity may be alive.
        Require(retirementWorker && pid == Environment.ProcessId &&
            string.Equals(process.MainModule?.FileName, path, StringComparison.OrdinalIgnoreCase), "process_still_running");
      }
    }
    foreach (var path in Directory.EnumerateFiles(launchRoot, "phase-d-child-*.identity.json"))
    {
      using var child = JsonDocument.Parse(Small(path));
      Require(Text(child.RootElement, "contractId") == "nll/phase-d-child-deadline/v1", "process_identity_unresolved");
      Exited(child.RootElement, Path.GetFileName(path) == "phase-d-child-fx-retirement.identity.json");
    }
    var runtimePath = Path.Combine(launchRoot, "runtime-processes.identity.json");
    if (!File.Exists(runtimePath)) return;
    using var runtime = JsonDocument.Parse(Small(runtimePath));
    var identities = runtime.RootElement;
    Require(Text(identities, "contractId") == "nll/phase-d-runtime-process-identities/v1" &&
        Text(identities, "launchContextUid") == uid, "process_identity_unresolved");
    foreach (var role in new[] { "client", "bootstrap", "server" })
      if (identities.GetProperty(role).ValueKind != JsonValueKind.Null) Exited(identities.GetProperty(role));
  }

  private static string Text(JsonElement value, string name) => value.GetProperty(name).GetString()
      ?? throw new InvalidDataException("phase_d_fx_retirement_field_invalid");
  private static bool IsSha(string value) => Regex.IsMatch(value, "\\A[0-9a-f]{64}\\z");
  private static void Require(bool value, string code)
  {
    if (!value) throw new InvalidDataException("phase_d_fx_retirement_" + code);
  }
  private static string Plain(string path)
  {
    Require(Path.IsPathFullyQualified(path) && !path.StartsWith(@"\\", StringComparison.Ordinal), "path_invalid");
    path = Path.GetFullPath(path);
    Require(!path[Path.GetPathRoot(path)!.Length..].Contains(':'), "path_invalid");
    for (var current = path; current is not null; current = Path.GetDirectoryName(current))
      if (File.Exists(current) || Directory.Exists(current))
        Require((File.GetAttributes(current) & FileAttributes.ReparsePoint) == 0, "path_reparse");
    return path;
  }
  private static byte[] Small(string path)
  {
    using var file = new FileStream(Plain(path), FileMode.Open, FileAccess.Read, FileShare.Read);
    Require(file.Length is > 0 and <= 1024 * 1024, "metadata_size_invalid");
    var raw = new byte[(int)file.Length];
    file.ReadExactly(raw);
    Require(file.ReadByte() == -1, "metadata_size_drifted");
    return raw;
  }
  private static string Hash(byte[] raw) => Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
  private static string FileHash(string path)
  {
    using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    return Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct Basic
  {
    public long ProcessTime, JobTime;
    public uint Flags;
    public UIntPtr MinWorking, MaxWorking;
    public uint ActiveLimit;
    public UIntPtr Affinity;
    public uint Priority, Scheduling;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct Io { public ulong A, B, C, D, E, F; }
  [StructLayout(LayoutKind.Sequential)]
  private struct Extended
  {
    public Basic Basic;
    public Io Io;
    public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct Accounting
  {
    public long A, B, C, D;
    public uint PageFaults, TotalProcesses, ActiveProcesses, TotalTerminated;
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle OpenJobObject(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)]
  private static extern bool QueryAccounting(SafeFileHandle job, int kind, out Accounting info, uint size, IntPtr returned);
  [DllImport("kernel32.dll", EntryPoint = "QueryInformationJobObject", SetLastError = true)]
  private static extern bool QueryLimits(SafeFileHandle job, int kind, out Extended info, uint size, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool IsProcessInJob(IntPtr process, SafeFileHandle job, out bool result);
  [DllImport("kernel32.dll")]
  private static extern IntPtr GetCurrentProcess();
}
