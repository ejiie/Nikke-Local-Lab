using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Admin.Api;

public sealed record PhaseDLaunchRequest(
    EntityUid AccountUid,
    int SeasonNumber,
    string ValidationKind,
    string? WeaknessCode = null,
    string? PreparationBindingSha256 = null);

public sealed record PhaseDLaunchProjection(
    int SchemaVersion,
    string ContractId,
    EntityUid LaunchContextUid,
    DateTimeOffset CreatedAtUtc,
    EntityUid AccountUid,
    string AccountLabel,
    string AccountRevisionSetSha256,
    int SeasonNumber,
    string ValidationKind,
    string WeaknessCode,
    string StatusCode,
    int? ClientProcessId,
    int? WatcherProcessId,
    DateTimeOffset? WatcherProcessStartedAtUtc,
    string? StartReceiptSha256,
    string? CompletionReceiptSha256,
    string? FailureCode,
    DateTimeOffset UpdatedAtUtc,
    PhaseDProgress? Progress = null);

public interface IPhaseDExecutionService
{
  Task<PhaseDLaunchProjection> StartAsync(
      PhaseDLaunchRequest request,
      CancellationToken cancellationToken = default);

  Task<PhaseDLaunchProjection?> GetAsync(
      EntityUid launchContextUid,
      CancellationToken cancellationToken = default);

  Task<IReadOnlyList<PhaseDLaunchProjection>> ListAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default);
}

public sealed record PhaseDExecutionOptions(
    string RepositoryRoot,
    string ConfigurationPath,
    string ExecutionRoot,
    string SoloRaidStateRoot,
    string CoordinatorScriptPath,
    string RecoveryScriptPath,
    string PowerShellPath);

public sealed class PhaseDExecutionException : Exception
{
  public PhaseDExecutionException(string code) : base(code)
  {
  }
}

public sealed class UnavailablePhaseDExecutionService : IPhaseDExecutionService
{
  private static PhaseDExecutionException Failure() =>
      new("phase_d_execution_not_configured");

  public Task<PhaseDLaunchProjection> StartAsync(
      PhaseDLaunchRequest request,
      CancellationToken cancellationToken = default) => throw Failure();

  public Task<PhaseDLaunchProjection?> GetAsync(
      EntityUid launchContextUid,
      CancellationToken cancellationToken = default) => throw Failure();

  public Task<IReadOnlyList<PhaseDLaunchProjection>> ListAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default) => throw Failure();
}

public sealed class FilesystemPhaseDExecutionService : IPhaseDExecutionService
{
  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    WriteIndented = true
  };
  private static readonly JsonSerializerOptions RuntimeDocumentJsonOptions =
      PhaseDExecutionDocumentJson.CreateOptions(writeIndented: true);

  private readonly IProfileManagementService _profiles;
  private readonly PhaseDExecutionOptions _options;
  private readonly PhaseDOperationGate _operations;
  private readonly IPhaseDProcessRunner _processes;
  private readonly ILogger<FilesystemPhaseDExecutionService>? _logger;

  public FilesystemPhaseDExecutionService(
      IProfileManagementService profiles,
      PhaseDExecutionOptions options,
      IPhaseDProcessRunner? processes = null,
      ILogger<FilesystemPhaseDExecutionService>? logger = null,
      TimeSpan? responseTimeout = null)
  {
    _profiles = profiles;
    _options = options;
    _processes = processes ?? new PhaseDProcessRunner();
    _logger = logger;
    _operations = new PhaseDOperationGate(options.ExecutionRoot, responseTimeout ?? TimeSpan.FromMinutes(2));
    RequireAbsoluteDirectory(options.RepositoryRoot, "phase_d_repository_root_invalid");
    RequireAbsoluteDirectory(options.ExecutionRoot, "phase_d_execution_root_invalid", create: true);
    RequireAbsoluteDirectory(
        options.SoloRaidStateRoot,
        "phase_d_solo_raid_state_root_invalid",
        create: true);
    RequireAbsoluteFile(options.ConfigurationPath, "phase_d_configuration_missing");
    RequireAbsoluteFile(options.CoordinatorScriptPath, "phase_d_coordinator_missing");
    RequireAbsoluteFile(options.RecoveryScriptPath, "phase_d_recovery_script_missing");
    RequireAbsoluteFile(options.PowerShellPath, "phase_d_powershell_missing");
  }

  public async Task<PhaseDLaunchProjection> StartAsync(
      PhaseDLaunchRequest request,
      CancellationToken cancellationToken = default)
  {
    var requestReceivedAtUtc = DateTimeOffset.UtcNow;
    var weaknessCode = NormalizeWeaknessCode(request.WeaknessCode);
    if (request.AccountUid.Value == Guid.Empty ||
        request.SeasonNumber <= 0 ||
        request.ValidationKind is not ("challenge" or "practice") || weaknessCode is null ||
        request.PreparationBindingSha256 is not { Length: 64 } binding ||
        binding.Any(static c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
    {
      throw new PhaseDExecutionException("phase_d_launch_request_invalid");
    }

    var accepted = new TaskCompletionSource<PhaseDLaunchProjection>(TaskCreationOptions.RunContinuationsAsynchronously);
    var operation = _operations.RunAsync(async () =>
    {
      // Ownership is independent of the initiating HTTP request from here on.
      var operationToken = CancellationToken.None;
      var active = await ReadAdmissionStatesAsync(operationToken).ConfigureAwait(false);
      if (active.Count != 0 || _processes.RuntimeProcessExists())
      {
        throw new PhaseDExecutionException("phase_d_runtime_not_cold");
      }

      var snapshotStartedAtUtc = DateTimeOffset.UtcNow;
      var snapshot = await _profiles.GetRuntimeProjectionSnapshotAsync(
          request.AccountUid,
          operationToken).ConfigureAwait(false) ??
          throw new PhaseDExecutionException("phase_d_account_not_found");
      var candidate = snapshot.Candidate;
      var lobby = snapshot.Lobby ??
          throw new PhaseDExecutionException("phase_d_lobby_not_materialized");

      if (!string.Equals(candidate.ValidationStatusCode, "ready", StringComparison.Ordinal) ||
          candidate.ValidationReasonCodes.Count != 0 ||
          candidate.Values.Any(static value => value.Status == "unresolved"))
      {
        throw new PhaseDExecutionException("phase_d_account_candidate_not_ready");
      }

      var launchUid = EntityUid.New();
      var snapshotCompletedAtUtc = DateTimeOffset.UtcNow;
      var launchRoot = Path.Combine(_options.ExecutionRoot, launchUid.ToString());
      Directory.CreateDirectory(launchRoot);
      var candidatePath = Path.Combine(launchRoot, "runtime-candidate.json");
      var lobbyPath = Path.Combine(launchRoot, "lobby-projection.json");
      await WriteJsonAsync(
              candidatePath,
              CreateRuntimeCandidateDocument(candidate),
              RuntimeDocumentJsonOptions,
              operationToken)
          .ConfigureAwait(false);
      await WriteJsonAsync(
              lobbyPath,
              CreateLobbyDocument(lobby),
              RuntimeDocumentJsonOptions,
              operationToken)
          .ConfigureAwait(false);

      var now = DateTimeOffset.UtcNow;
      var initialState = new ExecutionStateDocument(1, "nll/phase-d-execution-state/v1",
          launchUid.ToString(), now, request.AccountUid.ToString(), candidate.AccountLabel,
          candidate.BaseRevisions.RevisionSetSha256.ToString(), request.SeasonNumber,
          request.ValidationKind, weaknessCode, "draft", null, null, null, null, null, null, now);
      var progress = PhaseDExecutionProgress.Initial(launchUid.ToString(), requestReceivedAtUtc,
          snapshotStartedAtUtc, snapshotCompletedAtUtc);
      await WriteJsonAsync(Path.Combine(launchRoot, "execution-progress.json"), progress,
          JsonOptions, operationToken).ConfigureAwait(false);
      await WriteJsonAsync(Path.Combine(launchRoot, "execution-state.json"), initialState,
          JsonOptions, operationToken).ConfigureAwait(false);
      accepted.TrySetResult(initialState.ToProjection() with { Progress = progress });

      var startInfo = new ProcessStartInfo
      {
        FileName = _options.PowerShellPath,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      };
      foreach (var argument in new[]
      {
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        _options.CoordinatorScriptPath,
        "-RepositoryRoot", _options.RepositoryRoot,
        "-ConfigurationPath", _options.ConfigurationPath,
        "-ExecutionRoot", _options.ExecutionRoot,
        "-LaunchContextUid", launchUid.ToString(),
        "-RuntimeCandidatePath", candidatePath,
        "-LobbyProjectionPath", lobbyPath,
        "-SeasonNumber", request.SeasonNumber.ToString(CultureInfo.InvariantCulture),
        "-ValidationKind", request.ValidationKind,
        "-WeaknessCode", weaknessCode,
        "-ExpectedPreparationBindingSha256", binding,
        "-AccountUid", candidate.AccountUid.ToString(),
        "-AccountLabel", candidate.AccountLabel,
        "-AccountRevisionSetSha256", candidate.BaseRevisions.RevisionSetSha256.ToString()
      })
      {
        startInfo.ArgumentList.Add(argument);
      }

      int exitCode;
      try
      {
        exitCode = await _processes.RunAsync(startInfo,
            Path.Combine(launchRoot, "coordinator.owner.json")).ConfigureAwait(false);
      }
      catch (PhaseDExecutionException exception) when (exception.Message == "phase_d_child_start_failed")
      {
        // Process.Start proved that no coordinator was created. No runtime state
        // has been mutated; publish a terminal failure for this pre-start case only.
        var failed = initialState with { StatusCode = "failed", FailureCode = exception.Message, UpdatedAtUtc = DateTimeOffset.UtcNow };
        await PhaseDAtomicFile.WriteAsync(Path.Combine(launchRoot, "execution-state.json"),
            JsonSerializer.SerializeToElement(failed, JsonOptions)).ConfigureAwait(false);
        throw;
      }
      if (exitCode != 0)
      {
        var failedProjection = await ReadProjectionAsync(launchRoot, operationToken).ConfigureAwait(false);
        var failureCode = failedProjection?.FailureCode;
        throw new PhaseDExecutionException(IsSafeFailureCode(failureCode)
            ? failureCode! : "phase_d_coordinator_failed");
      }

      return await ReadProjectionAsync(launchRoot, operationToken).ConfigureAwait(false) ??
          throw new PhaseDExecutionException("phase_d_execution_state_missing");
    }, cancellationToken);
    _ = operation.ContinueWith(task =>
    {
      var error = task.Exception?.GetBaseException();
      var code = error is PhaseDExecutionException && IsSafeFailureCode(error.Message)
          ? error.Message : "phase_d_launch_owner_failed";
      _logger?.LogWarning("Phase D launch owner: {Code}", code);
    }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
    var response = await Task.WhenAny(accepted.Task, operation).WaitAsync(cancellationToken).ConfigureAwait(false);
    return await response.ConfigureAwait(false);
  }

  public async Task<PhaseDLaunchProjection?> GetAsync(
      EntityUid launchContextUid,
      CancellationToken cancellationToken = default)
  {
    if (launchContextUid.Value == Guid.Empty)
    {
      throw new PhaseDExecutionException("phase_d_launch_uid_invalid");
    }

    return await ReadProjectionAsync(
        Path.Combine(_options.ExecutionRoot, launchContextUid.ToString()),
        cancellationToken).ConfigureAwait(false);
  }

  public async Task<IReadOnlyList<PhaseDLaunchProjection>> ListAsync(
      EntityUid accountUid,
      CancellationToken cancellationToken = default)
  {
    if (accountUid.Value == Guid.Empty)
    {
      throw new PhaseDExecutionException("phase_d_account_uid_invalid");
    }

    return (await ListAllAsync(cancellationToken).ConfigureAwait(false))
        .Where(item => item.AccountUid == accountUid)
        .OrderByDescending(static item => item.CreatedAtUtc)
        .ToArray();
  }

  private async Task<IReadOnlyList<PhaseDLaunchProjection>> ListAllAsync(
      CancellationToken cancellationToken)
  {
    var result = new List<PhaseDLaunchProjection>();
    foreach (var directory in Directory.EnumerateDirectories(_options.ExecutionRoot))
    {
      cancellationToken.ThrowIfCancellationRequested();
      if (!Guid.TryParseExact(Path.GetFileName(directory), "D", out _)) continue;
      try
      {
        var projection = await ReadProjectionAsync(directory, cancellationToken).ConfigureAwait(false);
        if (projection is not null) result.Add(projection);
      }
      catch (Exception exception) when (exception is PhaseDExecutionException or IOException or UnauthorizedAccessException)
      {
        // History is a read model, not admission authority. Keep the source file
        // intact; expose its precise failure through individual GET and safe logs.
        _logger?.LogWarning("Phase D history entry {LaunchUid}: phase_d_execution_state_invalid", Path.GetFileName(directory));
      }
    }

    return result;
  }

  public Task<bool> ReconcileAsync(CancellationToken cancellationToken = default) =>
      _operations.RunAsync(async () =>
      {
        var active = await ReadAdmissionStatesAsync(CancellationToken.None).ConfigureAwait(false);
        // A leftover server is what recovery may need to stop. The recovery
        // script proves its exact ownership before stopping it; live clients
        // and active coordinator/watcher owners still exclude recovery.
        if (active.Count == 0 || _processes.ClientProcessExists()) return false;
        foreach (var item in active)
        {
          var launchRoot = Path.Combine(_options.ExecutionRoot, item.LaunchContextUid.ToString());
          if (new[] { "coordinator.owner.json", "recovery.owner.json", "completion-watcher.identity.json" }.Any(name =>
              _processes.HasUnsettledOwner(Path.Combine(launchRoot, name), _options.PowerShellPath)))
            return false;
          var startInfo = new ProcessStartInfo
          {
            FileName = _options.PowerShellPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
          };
          foreach (var argument in new[]
          {
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            _options.RecoveryScriptPath, "-ExecutionRoot", _options.ExecutionRoot,
            "-LaunchContextUid", item.LaunchContextUid.ToString(),
            "-ConfigurationPath", _options.ConfigurationPath
          }) startInfo.ArgumentList.Add(argument);
          var exitCode = await _processes.RunAsync(startInfo,
              Path.Combine(launchRoot, "recovery.owner.json")).ConfigureAwait(false);
          // Exit 2 means the completion watcher still owns the transition.
          if (exitCode == 2) return false;
          if (exitCode != 0) throw new PhaseDExecutionException("phase_d_orphan_recovery_failed");
        }
        return true;
      }, cancellationToken);

  private sealed record ClosedExecution(int SchemaVersion, string LaunchContextUid, string StatusCode,
      string StateSha256, DateTimeOffset ClassifiedAtUtc);

  private async Task<IReadOnlyList<PhaseDLaunchProjection>> ReadAdmissionStatesAsync(CancellationToken cancellationToken)
  {
    var active = new List<PhaseDLaunchProjection>();
    var closedRoot = Path.Combine(_options.ExecutionRoot, ".lifecycle-closed");
    Directory.CreateDirectory(closedRoot);
    foreach (var directory in Directory.EnumerateDirectories(_options.ExecutionRoot))
    {
      var name = Path.GetFileName(directory);
      if (!Guid.TryParseExact(name, "D", out var guid) || guid == Guid.Empty) continue;
      if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
        throw new PhaseDExecutionException("phase_d_execution_owner_unresolved");
      var launchUid = new EntityUid(guid);
      var closedPath = Path.Combine(closedRoot, name + ".json");
      if (File.Exists(closedPath))
      {
        ClosedExecution? closed;
        try
        {
          closed = JsonSerializer.Deserialize<ClosedExecution>(await File.ReadAllTextAsync(closedPath, cancellationToken).ConfigureAwait(false));
          if (closed is null || closed.SchemaVersion != 1 || closed.LaunchContextUid != name ||
              closed.StateSha256 is not { Length: 64 } || closed.ClassifiedAtUtc == default ||
              closed.StatusCode is not ("completed" or "rolled_back" or "failed"))
            throw new JsonException();
        }
        catch (JsonException) { throw new PhaseDExecutionException("phase_d_execution_owner_unresolved"); }
        // A previously closed run cannot be revived by editing its history.
        // New pending evidence is nevertheless always an admission blocker.
        if (HasPendingEvidence(launchUid, includeReceipts: closed.StatusCode == "failed"))
          throw new PhaseDExecutionException("phase_d_execution_owner_unresolved");
        continue;
      }

      // A missing/malformed unclassified record must NOT be treated as history.
      var projection = await ReadProjectionAsync(directory, cancellationToken).ConfigureAwait(false) ??
          throw new PhaseDExecutionException("phase_d_execution_owner_unresolved");
      if (new[] { "coordinator.owner.json", "recovery.owner.json", "completion-watcher.identity.json" }.Any(owner =>
          _processes.HasUnsettledOwner(Path.Combine(directory, owner), _options.PowerShellPath)))
      {
        active.Add(projection);
      }
      else if (RequiresOrphanRecovery(projection)) active.Add(projection);
      else
      {
        // This small terminal index is written only by the mutation owner.
        // GET/List never classify records or alter evidence.
        await PhaseDAtomicFile.WriteAsync(closedPath,
            new ClosedExecution(1, name, projection.StatusCode,
                Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(
                    Path.Combine(directory, "execution-state.json"), cancellationToken).ConfigureAwait(false))).ToLowerInvariant(),
                DateTimeOffset.UtcNow)).ConfigureAwait(false);
      }
    }
    return active;
  }

  private bool RequiresOrphanRecovery(PhaseDLaunchProjection item)
  {
    if (item.StatusCode is "draft" or "validated" or "started")
    {
      return true;
    }

    return HasPendingEvidence(item.LaunchContextUid, includeReceipts: item.StatusCode == "failed");
  }

  private bool HasPendingEvidence(EntityUid launchContextUid, bool includeReceipts)
  {
    var evidenceRoot = Path.Combine(
        _options.ExecutionRoot,
        launchContextUid.ToString(),
        "evidence");
    var soloRaidLaunchRoot = Path.Combine(
        _options.SoloRaidStateRoot,
        launchContextUid.ToString());
    return (Directory.Exists(evidenceRoot) && Directory.EnumerateFiles(
            evidenceRoot,
            "active-run.pointer.json",
            SearchOption.AllDirectories).Any()) ||
        File.Exists(Path.Combine(soloRaidLaunchRoot, "payload.pending.json")) ||
        (includeReceipts && new[] { "capture.receipt.json", "persistence.receipt.json" }
            .Any(name => File.Exists(Path.Combine(soloRaidLaunchRoot, name))));
  }


  private static async Task<PhaseDLaunchProjection?> ReadProjectionAsync(
      string launchRoot,
      CancellationToken cancellationToken)
  {
    var statePath = Path.Combine(launchRoot, "execution-state.json");
    if (!File.Exists(statePath))
    {
      return null;
    }

    await using var stream = new FileStream(
        statePath,
        FileMode.Open,
        FileAccess.Read,
        FileShare.ReadWrite | FileShare.Delete,
        4096,
        FileOptions.Asynchronous | FileOptions.SequentialScan);
    ExecutionStateDocument document;
    try
    {
      document = await JsonSerializer.DeserializeAsync<ExecutionStateDocument>(
          stream,
          JsonOptions,
          cancellationToken).ConfigureAwait(false) ??
          throw new PhaseDExecutionException("phase_d_execution_state_invalid");
    }
    catch (JsonException)
    {
      // This document is coordinator-owned state, not the caller's request body.
      // Keep malformed or legacy-incompatible execution state from being exposed
      // through the global middleware as the misleading request_json_invalid.
      throw new PhaseDExecutionException("phase_d_execution_state_invalid");
    }
    var projection = document.ToProjection();
    if (projection.LaunchContextUid.ToString() != Path.GetFileName(launchRoot))
      throw new PhaseDExecutionException("phase_d_execution_state_invalid");
    return projection with { Progress = await PhaseDExecutionProgress.ReadAsync(launchRoot, cancellationToken).ConfigureAwait(false) };
  }

  private static Task WriteJsonAsync<T>(
      string path,
      T value,
      JsonSerializerOptions options,
      CancellationToken cancellationToken) =>
      PhaseDAtomicFile.WriteAsync(path, value, options, cancellationToken, overwrite: false);

  private static void RequireAbsoluteDirectory(string path, string code, bool create = false)
  {
    if (!Path.IsPathFullyQualified(path))
    {
      throw new PhaseDExecutionException(code);
    }

    if (create)
    {
      Directory.CreateDirectory(path);
    }

    if (!Directory.Exists(path))
    {
      throw new PhaseDExecutionException(code);
    }
  }

  private static void RequireAbsoluteFile(string path, string code)
  {
    if (!Path.IsPathFullyQualified(path) || !File.Exists(path))
    {
      throw new PhaseDExecutionException(code);
    }
  }

  private static bool IsSafeFailureCode(string? value) =>
      value is { Length: >= 3 and <= 128 } &&
      value.StartsWith("phase_d_", StringComparison.Ordinal) &&
      value.All(static character =>
          character is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '.' or '-');

  private static string? NormalizeWeaknessCode(string? value)
  {
    var normalized = string.IsNullOrWhiteSpace(value)
        ? "iron"
        : value.Trim().ToLowerInvariant();
    return normalized is "fire" or "water" or "wind" or "electric" or "iron"
        ? normalized
        : null;
  }

  private static PhaseDRuntimeCandidateDocument CreateRuntimeCandidateDocument(
      RuntimeProjectionCandidate value) => new(
      value.SchemaVersion,
      value.ContractId,
      value.CandidateSha256.ToString(),
      value.AccountUid.ToString(),
      value.AccountLabel,
      new PhaseDRuntimeCandidateRevisionsDocument(
          value.BaseRevisions.ProfileRevisionUid.ToString(),
          value.BaseRevisions.AccountStateRevisionUid.ToString(),
          value.BaseRevisions.ProgressionRevisionUid?.ToString(),
          value.BaseRevisions.RevisionSetSha256.ToString()),
      value.ValidationStatusCode,
      value.ValidationReasonCodes,
      value.Values.Select(static item => new PhaseDRuntimeCandidateValueDocument(
          item.FieldCode,
          item.SubjectUid?.ToString(),
          item.Status,
          item.IntegerValue,
          item.BooleanValue,
          item.ReferenceUid?.ToString(),
          item.UnscaledValue,
          item.DecimalScale,
          item.ControlledValue,
          item.ReasonCode)).ToArray());

  private static PhaseDLobbyDocument CreateLobbyDocument(
      LobbyPresentationProjection value) => new(
      1,
      "nll/phase-d-lobby-projection/v1",
      value.AccountUid.ToString(),
      value.Revision.RevisionUid.ToString(),
      value.Revision.ContentSha256.ToString(),
      value.DisplayName,
      value.CommanderLevel);

  private sealed record ExecutionStateDocument(
      int SchemaVersion,
      string ContractId,
      string LaunchContextUid,
      DateTimeOffset CreatedAtUtc,
      string AccountUid,
      string AccountLabel,
      string AccountRevisionSetSha256,
      int SeasonNumber,
      string ValidationKind,
      string? WeaknessCode,
      string StatusCode,
      int? ClientProcessId,
      int? WatcherProcessId,
      string? WatcherProcessStartedAtUtc,
      string? StartReceiptSha256,
      string? CompletionReceiptSha256,
      string? FailureCode,
      DateTimeOffset UpdatedAtUtc)
  {
    public PhaseDLaunchProjection ToProjection()
    {
      DateTimeOffset? watcherProcessStartedAtUtc = null;
      if (!string.IsNullOrWhiteSpace(WatcherProcessStartedAtUtc))
      {
        if (!DateTimeOffset.TryParse(
                WatcherProcessStartedAtUtc,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var parsedWatcherProcessStartedAtUtc))
        {
          throw new PhaseDExecutionException("phase_d_execution_state_invalid");
        }
        watcherProcessStartedAtUtc = parsedWatcherProcessStartedAtUtc;
      }

      if (SchemaVersion != 1 || ContractId != "nll/phase-d-execution-state/v1" ||
          !Guid.TryParse(LaunchContextUid, out var launchUid) || launchUid == Guid.Empty ||
          !Guid.TryParse(AccountUid, out var accountUid) || accountUid == Guid.Empty ||
          SeasonNumber <= 0 || ValidationKind is not ("challenge" or "practice") ||
          NormalizeWeaknessCode(WeaknessCode) is null ||
          StatusCode is not ("draft" or "validated" or "started" or "completed" or "failed" or "rolled_back"))
      {
        throw new PhaseDExecutionException("phase_d_execution_state_invalid");
      }

      return new PhaseDLaunchProjection(
          SchemaVersion,
          ContractId,
          new EntityUid(launchUid),
          CreatedAtUtc,
          new EntityUid(accountUid),
          AccountLabel,
          AccountRevisionSetSha256,
          SeasonNumber,
          ValidationKind,
          NormalizeWeaknessCode(WeaknessCode)!,
          StatusCode,
           ClientProcessId,
           WatcherProcessId,
           watcherProcessStartedAtUtc,
           StartReceiptSha256,
          CompletionReceiptSha256,
          FailureCode,
          UpdatedAtUtc);
    }
  }
}
