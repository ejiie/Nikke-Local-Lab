using System.Diagnostics;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

// The caller may stop waiting; only the operation itself releases ownership.
// File sharing also excludes another Admin process using this execution root.
public sealed class PhaseDOperationGate(string executionRoot, TimeSpan responseTimeout)
{
  private readonly SemaphoreSlim _gate = new(1, 1);

  public async Task<T> RunAsync<T>(Func<Task<T>> operation, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested();
    if (!await _gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
      throw new PhaseDExecutionException("phase_d_operation_in_progress");
    FileStream lease;
    try
    {
      lease = new FileStream(Path.Combine(executionRoot, ".lifecycle.lock"),
          FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    catch (IOException)
    {
      _gate.Release();
      throw new PhaseDExecutionException("phase_d_operation_in_progress");
    }
    catch
    {
      _gate.Release();
      throw;
    }

    var work = Task.Run(async () =>
    {
      try { return await operation().ConfigureAwait(false); }
      finally { lease.Dispose(); _gate.Release(); }
    }, CancellationToken.None);
    // Observe late failure even after the requesting connection has disappeared.
    _ = work.ContinueWith(static task => { _ = task.Exception; },
        CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
    try { return await work.WaitAsync(responseTimeout, cancellationToken).ConfigureAwait(false); }
    catch (TimeoutException)
    {
      // Not a terminal runtime state and not permission to start a second child.
      throw new PhaseDExecutionException("phase_d_operation_pending");
    }
  }
}

public interface IPhaseDProcessRunner
{
  Task<int> RunAsync(ProcessStartInfo startInfo, string identityPath);
  bool HasUnsettledOwner(string identityPath, string expectedExecutablePath);
  bool RuntimeProcessExists();
  bool ClientProcessExists();
}

public sealed class PhaseDProcessRunner : IPhaseDProcessRunner
{
  private sealed record Owner(int SchemaVersion, string State, int? ProcessId,
      DateTime? StartedAtUtc, string ExecutablePath);

  private sealed record Watcher(int SchemaVersion, string ContractId, int ProcessId,
      DateTime ProcessStartedAtUtc, string ExecutablePath);

  public async Task<int> RunAsync(ProcessStartInfo startInfo, string identityPath)
  {
    // Publication precedes creation. A crash inside the creation/publication gap
    // stays explicitly unknown instead of allowing recovery to race the child.
    var owner = new Owner(1, "starting", null, null, Path.GetFullPath(startInfo.FileName));
    await PhaseDAtomicFile.WriteAsync(identityPath, owner).ConfigureAwait(false);
    using var process = new Process { StartInfo = startInfo };
    try
    {
      if (!process.Start()) throw new PhaseDExecutionException("phase_d_child_start_failed");
    }
    catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or PhaseDExecutionException)
    {
      await PhaseDAtomicFile.WriteAsync(identityPath, owner with { State = "exited" }).ConfigureAwait(false);
      throw new PhaseDExecutionException("phase_d_child_start_failed");
    }

    using var drainCancellation = new CancellationTokenSource();
    var output = DrainAsync(process.StandardOutput.BaseStream, drainCancellation.Token);
    var error = DrainAsync(process.StandardError.BaseStream, drainCancellation.Token);
    owner = owner with { State = "running", ProcessId = process.Id, StartedAtUtc = process.StartTime.ToUniversalTime() };
    await PhaseDAtomicFile.WriteAsync(identityPath, owner).ConfigureAwait(false);
    // Observe the exact child, never all descendants. Response deadlines are
    // handled by the operation gate; an unproven timeout cannot release the lease.
    await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
    // Descendants may inherit either pipe. EOF is not proof of the exact child's
    // lifetime; stop our discarded-output reads only AFTER that child has exited.
    await drainCancellation.CancelAsync().ConfigureAwait(false);
    await Task.WhenAll(output, error).ConfigureAwait(false);
    await PhaseDAtomicFile.WriteAsync(identityPath, owner with { State = "exited" }).ConfigureAwait(false);
    return process.ExitCode;
  }

  private static async Task DrainAsync(Stream stream, CancellationToken cancellationToken)
  {
    try { await stream.CopyToAsync(Stream.Null, cancellationToken).ConfigureAwait(false); }
    catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
  }

  public bool HasUnsettledOwner(string identityPath, string expectedExecutablePath)
  {
    if (!File.Exists(identityPath)) return false; // legacy run; other admission proofs still apply
    try
    {
      Owner? owner;
      if (Path.GetFileName(identityPath) == "completion-watcher.identity.json")
      {
        var watcher = JsonSerializer.Deserialize<Watcher>(File.ReadAllText(identityPath),
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        if (watcher is null || watcher.SchemaVersion != 1 ||
            watcher.ContractId != "nll/phase-d-completion-watcher-identity/v1" ||
            watcher.ProcessId <= 0 || watcher.ProcessStartedAtUtc == default)
          throw new InvalidDataException();
        owner = new Owner(watcher.SchemaVersion, "running", watcher.ProcessId,
            watcher.ProcessStartedAtUtc, watcher.ExecutablePath);
      }
      else owner = JsonSerializer.Deserialize<Owner>(File.ReadAllText(identityPath));
      if (owner is null || owner.SchemaVersion != 1 ||
          !string.Equals(owner.ExecutablePath, Path.GetFullPath(expectedExecutablePath), StringComparison.OrdinalIgnoreCase) ||
          owner.State is not ("starting" or "running" or "exited"))
        throw new InvalidDataException();
      if (owner.State == "exited") return false;
      if (owner.State == "starting" || owner.ProcessId is null or <= 0 || owner.StartedAtUtc is null)
        throw new InvalidDataException();
      Process process;
      try { process = Process.GetProcessById(owner.ProcessId.Value); }
      catch (ArgumentException) { return false; }
      using (process)
      {
        if (process.HasExited) return false;
        if (process.StartTime.ToUniversalTime() != owner.StartedAtUtc.Value) return false;
        // A live same-start PID with inaccessible or unexpected path is unknown,
        // not cold. No process termination occurs here.
        if (!string.Equals(process.MainModule?.FileName, owner.ExecutablePath, StringComparison.OrdinalIgnoreCase))
          throw new InvalidDataException();
        return true;
      }
    }
    catch (Exception exception) when (exception is IOException or InvalidDataException or JsonException or
        UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
    {
      throw new PhaseDExecutionException("phase_d_owner_identity_unresolved");
    }
  }

  public bool RuntimeProcessExists()
  {
    return NamedProcessExists("EpinelPS") || ClientProcessExists();
  }

  public bool ClientProcessExists() => NamedProcessExists("nikke", "nikke_launcher", "NikkeLocalLab.Phase3B2.PhysicalBootstrap");

  private static bool NamedProcessExists(params string[] names)
  {
    foreach (var name in names)
    {
      var processes = Process.GetProcessesByName(name);
      try { if (processes.Length != 0) return true; }
      finally { foreach (var process in processes) process.Dispose(); }
    }
    return false;
  }
}

internal static class PhaseDAtomicFile
{
  public static async Task WriteAsync<T>(string path, T value,
      JsonSerializerOptions? options = null, CancellationToken cancellationToken = default,
      bool overwrite = true)
  {
    var temporary = path + ".partial-" + Guid.NewGuid().ToString("N");
    try
    {
      await using (var stream = new FileStream(temporary, FileMode.CreateNew,
          FileAccess.Write, FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
      {
        await JsonSerializer.SerializeAsync(stream, value, options, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync("\n"u8.ToArray(), cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
      }
      File.Move(temporary, path, overwrite);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
}

public sealed class PhaseDLifecycleWorker(
    IPhaseDExecutionService executions,
    ILogger<PhaseDLifecycleWorker> logger) : BackgroundService
{
  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    if (executions is not FilesystemPhaseDExecutionService lifecycle) return;
    string? previousFailure = null;
    while (!stoppingToken.IsCancellationRequested)
    {
      try
      {
        await lifecycle.ReconcileAsync(stoppingToken).ConfigureAwait(false);
        previousFailure = null;
      }
      catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
      catch (PhaseDExecutionException exception)
      {
        if (exception.Message != "phase_d_operation_in_progress" && exception.Message != previousFailure)
          logger.LogWarning("Phase D lifecycle: {Code}", exception.Message);
        previousFailure = exception.Message;
      }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
      {
        if (previousFailure != "phase_d_lifecycle_io_failed")
          logger.LogWarning("Phase D lifecycle: phase_d_lifecycle_io_failed");
        previousFailure = "phase_d_lifecycle_io_failed";
      }
      await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken).ConfigureAwait(false);
    }
  }
}
