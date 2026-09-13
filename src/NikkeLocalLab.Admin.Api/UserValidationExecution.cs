using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using static NikkeLocalLab.Admin.Api.FilesystemBossSeasonCatalogService;

namespace NikkeLocalLab.Admin.Api;

public sealed record UserValidationActionRequest(Guid OperationUid, int SeasonNumber, string WeaknessCode,
    string BindingSha256, string EntrySha256, string Mode);
public sealed record UserValidationActionView(int SchemaVersion, string ContractId, Guid? OperationUid,
    int SeasonNumber, string WeaknessCode, string StatusCode, string? FailureCode,
    bool ActualGameAcceptanceClaimed = false);
internal sealed record UserValidationOwner(string State, string ExecutablePath, int? ProcessId = null, long? CreatedFileTime = null, int? ExitCode = null);
public interface IUserValidationProcessLauncher
{
  Task<int> RunAsync(ProcessStartInfo info, string ownerPath);
  bool IsUnsettled(string ownerPath, string executablePath);
}

public sealed class UserValidationProcessLauncher : IUserValidationProcessLauncher
{
  public async Task<int> RunAsync(ProcessStartInfo info, string ownerPath)
  {
    Require(OperatingSystem.IsWindows() && info.UseShellExecute && info.Verb == "runas" &&
        info.WindowStyle == ProcessWindowStyle.Hidden && !info.RedirectStandardOutput && !info.RedirectStandardError);
    var owner = new UserValidationOwner("starting", info.FileName);
    await PhaseDAtomicFile.WriteAsync(ownerPath, owner, JsonOptions).ConfigureAwait(false);
    using var process = new Process { StartInfo = info };
    try { if (!process.Start()) throw new InvalidOperationException(); }
    catch (Exception error) when (error is Win32Exception or InvalidOperationException)
    {
      await PhaseDAtomicFile.WriteAsync(Path.Combine(Path.GetDirectoryName(ownerPath)!, "launch-error.json"),
          UserValidationExecution.ErrorDiagnostic("process_start", error), JsonOptions).ConfigureAwait(false);
      await PhaseDAtomicFile.WriteAsync(ownerPath, owner with { State = "exited" }, JsonOptions).ConfigureAwait(false);
      throw new PhaseDExecutionException(error is Win32Exception { NativeErrorCode: 1223 } ? "boss_validation_uac_cancelled" : "boss_validation_start_failed");
    }
    // Retain the returned process handle. Never attach to/terminate the game or
    // ACE here: the user-owned controller owns all privileged cleanup.
    owner = owner with { State = "running", ProcessId = process.Id, CreatedFileTime = process.StartTime.ToUniversalTime().ToFileTimeUtc() };
    await PhaseDAtomicFile.WriteAsync(ownerPath, owner, JsonOptions).ConfigureAwait(false);
    await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
    await PhaseDAtomicFile.WriteAsync(ownerPath, owner with { State = "exited", ExitCode = process.ExitCode }, JsonOptions).ConfigureAwait(false);
    return process.ExitCode;
  }
  public bool IsUnsettled(string ownerPath, string executablePath)
  {
    var owner = JsonSerializer.Deserialize<UserValidationOwner>(ReadFile(ownerPath, 16384), JsonOptions);
    Require(owner is not null && owner.ExecutablePath == executablePath && owner.State is "starting" or "running" or "exited");
    if (owner.State == "exited") return false;
    if (owner.State == "starting") return true; // Creation/publication gap: do not guess it was cancelled.
    Require(owner.ProcessId is > 0 && owner.CreatedFileTime is > 0);
    using var handle = OpenProcess(0x101000, false, owner.ProcessId.Value); // QUERY_LIMITED_INFORMATION | SYNCHRONIZE; no VM_READ.
    if (handle.IsInvalid) { Require(Marshal.GetLastWin32Error() == 87); return false; }
    var wait = WaitForSingleObject(handle, 0);
    if (wait == 0) return false;
    Require(wait == 258);
    Require(GetProcessTimes(handle, out var created, out _, out _, out _));
    if (created != owner.CreatedFileTime.Value) return false;
    var image = new StringBuilder(32768); uint size = 32768;
    Require(QueryFullProcessImageName(handle, 0, image, ref size) && string.Equals(image.ToString(), executablePath, StringComparison.OrdinalIgnoreCase));
    return true;
  }
  [DllImport("kernel32.dll", SetLastError = true)] private static extern Microsoft.Win32.SafeHandles.SafeFileHandle OpenProcess(uint access, bool inherit, int id);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(Microsoft.Win32.SafeHandles.SafeFileHandle process, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(Microsoft.Win32.SafeHandles.SafeFileHandle process, out long created, out long exited, out long kernel, out long user);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageName(Microsoft.Win32.SafeHandles.SafeFileHandle process, uint flags, StringBuilder path, ref uint size);
}

public sealed class UserValidationExecution(UserValidationDelivery delivery, IUserValidationProcessLauncher? launcher = null)
{
  private readonly IUserValidationProcessLauncher processes = launcher ?? new UserValidationProcessLauncher();
  private readonly SemaphoreSlim requests = new(1, 1);
  // Injectable storage adapter for source-only synthetic tests. Production uses
  // the same absolute, no-reparse policy as the other local admin services.
  internal Func<string, string> StorePath { get; init; } = Plain;
  internal static object ErrorDiagnostic(string stage, Exception error) => new
  {
    contractId = "nll/user-validation-process-diagnostic/v1",
    stage,
    observedAtUtc = DateTimeOffset.UtcNow,
    exceptionType = error.GetType().FullName,
    hResult = error.HResult,
    nativeErrorCode = (error as Win32Exception)?.NativeErrorCode,
    actualGameAcceptanceClaimed = false
  };
  internal static async Task WriteDiagnosticRunner(string path)
  {
    using var source = typeof(UserValidationExecution).Assembly.GetManifestResourceStream(
        "NikkeLocalLab.Admin.Api.UserValidationDiagnostics.ps1") ?? throw new InvalidOperationException("boss_validation_logger_missing");
    await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    await source.CopyToAsync(file).ConfigureAwait(false);
    file.Flush(flushToDisk: true);
  }
  private static UserValidationActionView View(UserValidationActionRequest request, string status, string? failure = null) =>
      new(1, "nll/user-validation-action/v1", request.OperationUid, request.SeasonNumber, request.WeaknessCode, status, failure);
  public async Task<UserValidationActionView> BeginAsync(UserValidationActionRequest request, CancellationToken cancellationToken)
  {
    if (request.OperationUid == Guid.Empty || request.Mode is not ("Start" or "Recover") || !IsWeakness(request.WeaknessCode) ||
        !IsHash(request.BindingSha256) || !IsHash(request.EntrySha256)) throw new ApiRequestException(422, "boss_validation_request_invalid");
    if (!await requests.WaitAsync(0, cancellationToken).ConfigureAwait(false)) throw new ApiRequestException(409, "boss_validation_action_busy");
    FileStream? lease = null;
    try
    {
      var bound = delivery.ReadBound();
      var selected = bound.View.Selections.SingleOrDefault(e => e.WeaknessCode == request.WeaknessCode);
      if (bound.View.SeasonNumber != request.SeasonNumber || bound.View.BindingSha256 != request.BindingSha256 || selected?.EntrySha256 != request.EntrySha256)
        throw new ApiRequestException(409, "boss_validation_inputs_changed");
      var run = bound.Entries[request.WeaknessCode].RunRoot;
      var actions = StorePath(run + @"\ui-actions"); Directory.CreateDirectory(actions);
      var actionRoot = StorePath(Path.Combine(actions, request.OperationUid.ToString("D")));
      if (Directory.Exists(actionRoot))
      {
        var previous = ReadRequest(actionRoot);
        if (previous != request) throw new ApiRequestException(409, "boss_validation_operation_conflict");
        return ReadAction(actionRoot, previous, run, bound.PowerShellPath);
      }
      var leasePath = StorePath(@"C:\NLL\Staging\NativeFxUserValidation\" + bound.TrialUid + @"\.ui-action.lock");
      try { lease = new FileStream(leasePath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
      catch (IOException) { throw new ApiRequestException(409, "boss_validation_action_busy"); }
      foreach (var entry in bound.Entries.Values)
      {
        var directory = StorePath(entry.RunRoot + @"\ui-actions");
        if (!Directory.Exists(directory)) continue;
        var prior = Directory.GetDirectories(directory); Require(prior.Length <= 32);
        foreach (var path in prior)
        {
          Require(Guid.TryParseExact(Path.GetFileName(path), "D", out _));
          // Missing/malformed owner evidence is UNKNOWN, never a free retry.
          if (processes.IsUnsettled(StorePath(Path.Combine(path, "owner.json")), bound.PowerShellPath))
            throw new ApiRequestException(409, "boss_validation_owner_unsettled");
        }
      }
      if (Directory.GetDirectories(actions).Length >= 32) throw new ApiRequestException(409, "boss_validation_action_limit");
      if (request.Mode == "Start" && File.Exists(StorePath(run + @"\execution.started.json")))
        throw new ApiRequestException(409, "boss_validation_attempt_consumed");
      if (request.Mode == "Recover" && (!File.Exists(StorePath(run + @"\execution.started.json")) || File.Exists(StorePath(run + @"\cleanup.receipt.json"))))
        throw new ApiRequestException(409, "boss_validation_recovery_not_required");
      Directory.CreateDirectory(actionRoot);
      await PhaseDAtomicFile.WriteAsync(Path.Combine(actionRoot, "request.json"), request, JsonOptions, overwrite: false).ConfigureAwait(false);
      var diagnosticRunner = Path.Combine(actionRoot, "diagnostic-runner.ps1");
      await WriteDiagnosticRunner(diagnosticRunner).ConfigureAwait(false);
      await PhaseDAtomicFile.WriteAsync(Path.Combine(actionRoot, "owner.json"), new UserValidationOwner("starting", bound.PowerShellPath), JsonOptions,
          overwrite: false).ConfigureAwait(false);
      var info = new ProcessStartInfo
      {
        FileName = bound.PowerShellPath,
        UseShellExecute = true,
        Verb = "runas",
        WindowStyle = ProcessWindowStyle.Hidden,
        WorkingDirectory = run
      };
      foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", diagnosticRunner,
          "-ControllerPath", bound.Entries[request.WeaknessCode].ControllerPath,
          "-EntryPath", run + @"\entry.private.json", "-EntrySha256", request.EntrySha256, "-Mode", request.Mode }) info.ArgumentList.Add(argument);
      var ownedLease = lease; lease = null;
      var task = Task.Run(async () =>
      {
        try
        {
          UserValidationActionView result;
          try
          {
            var code = await processes.RunAsync(info, Path.Combine(actionRoot, "owner.json")).ConfigureAwait(false);
            await PhaseDAtomicFile.WriteAsync(Path.Combine(actionRoot, "process-exit.json"), new
            {
              contractId = "nll/user-validation-process-diagnostic/v1",
              stage = "process_exit",
              observedAtUtc = DateTimeOffset.UtcNow,
              exitCode = code,
              controllerDiagnosticPresent = File.Exists(Path.Combine(actionRoot, "controller-diagnostic.json")),
              actualGameAcceptanceClaimed = false
            }, JsonOptions).ConfigureAwait(false);
            var restored = CleanupVerified(run, request.EntrySha256);
            result = View(request, restored ? "finished" : File.Exists(StorePath(run + @"\execution.started.json")) ? "cleanup_required" : "failed",
                code == 0 && restored ? null : "boss_validation_controller_failed");
          }
          catch (PhaseDExecutionException error) when (error.Message is "boss_validation_uac_cancelled" or "boss_validation_start_failed")
          { result = View(request, error.Message == "boss_validation_uac_cancelled" ? "uac_cancelled" : "failed", error.Message); }
          catch (Exception error)
          {
            await PhaseDAtomicFile.WriteAsync(Path.Combine(actionRoot, "action-error.json"),
                ErrorDiagnostic("action_completion", error), JsonOptions).ConfigureAwait(false);
            result = View(request, "status_unknown", "boss_validation_owner_unsettled");
          }
          await PhaseDAtomicFile.WriteAsync(Path.Combine(actionRoot, "result.json"), result, JsonOptions).ConfigureAwait(false);
        }
        finally { ownedLease.Dispose(); }
      }, CancellationToken.None);
      _ = task.ContinueWith(static t => { _ = t.Exception; }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
      return View(request, "awaiting_user_approval");
    }
    finally { lease?.Dispose(); requests.Release(); }
  }
  public UserValidationActionView Get(int season, string weakness)
  {
    if (!IsWeakness(weakness)) throw new ApiRequestException(422, "boss_validation_request_invalid");
    var bound = delivery.ReadBound();
    if (bound.View.SeasonNumber != season) throw new ApiRequestException(404, "boss_validation_not_prepared");
    var run = bound.Entries[weakness].RunRoot;
    var root = StorePath(run + @"\ui-actions");
    if (Directory.Exists(root))
    {
      var paths = Directory.GetDirectories(root); Require(paths.Length <= 32);
      var latest = paths.Select(path => (Path: StorePath(path), Modified: File.GetLastWriteTimeUtc(StorePath(Path.Combine(path, "request.json")))))
          .OrderByDescending(p => p.Modified).FirstOrDefault();
      if (latest.Path is not null)
      {
        var request = ReadRequest(latest.Path);
        Require(request.SeasonNumber == season && request.WeaknessCode == weakness && request.BindingSha256 == bound.View.BindingSha256 &&
            request.EntrySha256 == bound.View.Selections.Single(s => s.WeaknessCode == weakness).EntrySha256);
        return ReadAction(latest.Path, request, run, bound.PowerShellPath);
      }
    }
    var state = CleanupVerified(run, bound.View.Selections.Single(s => s.WeaknessCode == weakness).EntrySha256) ? "finished" : File.Exists(StorePath(run + @"\execution.started.json")) ? "cleanup_required" : "prepared";
    return new(1, "nll/user-validation-action/v1", null, season, weakness, state, null);
  }
  private UserValidationActionView ReadAction(string path, UserValidationActionRequest request, string run, string shell)
  {
    if (File.Exists(StorePath(Path.Combine(path, "result.json"))))
    {
      var result = JsonSerializer.Deserialize<UserValidationActionView>(ReadFile(Path.Combine(path, "result.json"), 16384), JsonOptions);
      Require(result is not null && result.ContractId == "nll/user-validation-action/v1" && result.OperationUid == request.OperationUid &&
          result.SeasonNumber == request.SeasonNumber && result.WeaknessCode == request.WeaknessCode && !result.ActualGameAcceptanceClaimed &&
          result.StatusCode is "finished" or "cleanup_required" or "failed" or "uac_cancelled" or "status_unknown");
      // A later successful explicit recovery supersedes this earlier failure.
      return CleanupVerified(run, request.EntrySha256) ? result with { StatusCode = "finished" } : result;
    }
    if (processes.IsUnsettled(StorePath(Path.Combine(path, "owner.json")), shell)) return View(request, "running");
    return View(request, CleanupVerified(run, request.EntrySha256) ? "finished" : File.Exists(StorePath(run + @"\execution.started.json")) ? "cleanup_required" : "failed",
        "boss_validation_controller_status_required");
  }
  private static UserValidationActionRequest ReadRequest(string path) => JsonSerializer.Deserialize<UserValidationActionRequest>(
      ReadFile(Path.Combine(path, "request.json"), 16384), JsonOptions) ?? throw new JsonException();
  private bool CleanupVerified(string run, string entryHash)
  {
    var path = StorePath(run + @"\cleanup.receipt.json");
    if (!File.Exists(path)) return false;
    using var started = JsonDocument.Parse(ReadFile(StorePath(run + @"\execution.started.json"), 16384));
    Require(started.RootElement.GetProperty("entrySha256").GetString() == entryHash);
    using var receipt = JsonDocument.Parse(ReadFile(path, 16384));
    var root = receipt.RootElement;
    return root.GetProperty("contractId").GetString() == "nll/user-validation-managed-scope-cleanup/v1" &&
        new[] { "jobZeroVerified", "serviceZeroVerified", "scopeZeroVerified", "serviceStartModeRestored", "driverBaselineRestored", "ownedInputsRestored", "isolationReleased" }
            .All(field => root.GetProperty(field).GetBoolean()) && !root.GetProperty("actualGameAcceptanceClaimed").GetBoolean();
  }
}
