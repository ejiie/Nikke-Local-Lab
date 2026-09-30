using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PhaseDExecutionStateTests
{
  [Fact]
  public void InitialProgressIntervalsBelongToTheirNamedPhase()
  {
    var received = DateTimeOffset.Parse("2026-09-01T00:00:00Z");
    var progress = PhaseDExecutionProgress.Initial("synthetic", received, received.AddMilliseconds(50),
        received.AddMilliseconds(2450), received.AddMilliseconds(2530));
    Assert.Equal(new[] { "api_preparation", "account_snapshot", "coordinator_preparation" }, progress.Events.Select(e => e.StageCode));
    Assert.Equal(new double[] { 2400, 80, 0 }, progress.Events.Select(e => e.IntervalMilliseconds));
    Assert.Equal(new double[] { 50, 2450, 2530 }, progress.Events.Select(e => e.CumulativeMilliseconds));
  }

  [Theory]
  [InlineData("game_exited")]
  [InlineData("fx_restore")]
  [InlineData("progress_save")]
  [InlineData("ready")]
  public async Task DisplayProgressDoesNotChangeAdmissionState(string stage)
  {
    using var fixture = new ExecutionStateFixture();
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    var root = Path.Combine(fixture.ExecutionRoot, uid.ToString());
    var now = DateTimeOffset.UtcNow;
    var progress = new PhaseDProgress("nll/phase-d-execution-progress/v1", uid.ToString(), now.AddSeconds(-10),
        stage, now, [new(stage, now, now, 10000, 10000)]);
    File.WriteAllText(Path.Combine(root, "execution-progress.json"),
        JsonSerializer.Serialize(progress, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    var before = Directory.GetFiles(root).ToDictionary(path => path, File.ReadAllText);
    var result = await fixture.Service.GetAsync(uid);
    Assert.Equal("started", result!.StatusCode);
    Assert.Equal(stage, result.Progress!.StageCode);
    Assert.Equal(10000, Assert.Single(result.Progress.Events).CumulativeMilliseconds);
    Assert.Equal("phase_d_test_failure", result.FailureCode);
    foreach (var (path, contents) in before) Assert.Equal(contents, File.ReadAllText(path));
  }

  [Theory]
  [InlineData(null)]
  [InlineData("{")]
  [InlineData("{}")]
  public async Task MissingOrCorruptProgressNeverBreaksStatusRead(string? contents)
  {
    using var fixture = new ExecutionStateFixture();
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    if (contents is not null)
      File.WriteAllText(Path.Combine(fixture.ExecutionRoot, uid.ToString(), "execution-progress.json"), contents);
    var result = await fixture.Service.GetAsync(uid);
    Assert.Equal("started", result!.StatusCode);
    Assert.Equal(contents is null ? null : "status_unknown", result.Progress?.StageCode);
  }

  [Fact]
  public async Task StatusReadIsIsolatedFromCorruptHistoryAndDoesNotWriteFiles()
  {
    using var fixture = new ExecutionStateFixture();
    var target = EntityUid.New();
    var corrupt = EntityUid.New();
    fixture.WriteState(target, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure");
    fixture.WriteState(corrupt, "\"watcherProcessStartedAtUtc\": {}", "phase_d_test_failure");
    var before = Directory.GetFiles(fixture.ExecutionRoot, "*", SearchOption.AllDirectories)
        .ToDictionary(path => path, File.ReadAllText);

    var result = await fixture.Service.GetAsync(target).WaitAsync(TimeSpan.FromSeconds(2));

    Assert.Equal(target, result!.LaunchContextUid);
    Assert.Equal(before.Count, Directory.GetFiles(fixture.ExecutionRoot, "*", SearchOption.AllDirectories).Length);
    foreach (var (path, contents) in before) Assert.Equal(contents, File.ReadAllText(path));
  }

  [Fact]
  public async Task CorruptHistoryDoesNotRemoveHealthyAccountHistory()
  {
    using var fixture = new ExecutionStateFixture();
    var target = EntityUid.New();
    fixture.WriteState(target, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure");
    var account = (await fixture.Service.GetAsync(target))!.AccountUid;
    fixture.WriteState(EntityUid.New(), "\"watcherProcessStartedAtUtc\": {}", "phase_d_test_failure");
    var history = await fixture.Service.ListAsync(account);
    Assert.Equal(target, Assert.Single(history).LaunchContextUid);
  }

  [Fact]
  public async Task LegacyEmptyWatcherTimestampPreservesCoordinatorFailureCode()
  {
    using var fixture = new ExecutionStateFixture();
    var launchUid = EntityUid.New();
    const string failureCode = "phase_d_raid_state_operational_binding_missing";
    fixture.WriteState(
        launchUid,
        "\"watcherProcessStartedAtUtc\": \"\"",
        failureCode);

    var projection = await fixture.Service.GetAsync(launchUid);

    Assert.NotNull(projection);
    Assert.Null(projection.WatcherProcessStartedAtUtc);
    Assert.Equal(failureCode, projection.FailureCode);
    Assert.Equal("failed", projection.StatusCode);
  }

  [Fact]
  public async Task MalformedCoordinatorStateIsNotReportedAsRequestJsonFailure()
  {
    using var fixture = new ExecutionStateFixture();
    var launchUid = EntityUid.New();
    fixture.WriteState(
        launchUid,
        "\"watcherProcessStartedAtUtc\": {}",
        "phase_d_test_failure");

    var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(
        () => fixture.Service.GetAsync(launchUid));

    Assert.Equal("phase_d_execution_state_invalid", failure.Message);
  }

  [Fact]
  public async Task RecoveryCanWaitWhileStatusReturnsAndAnotherInstanceCannotRecover()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    var recovery = fixture.Service.ReconcileAsync();
    await runner.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
    try
    {
      var projection = await fixture.Service.GetAsync(uid).WaitAsync(TimeSpan.FromSeconds(2));
      Assert.Equal("started", projection!.StatusCode);
      var other = new FilesystemPhaseDExecutionService(new UnavailableProfileManagementService(), fixture.Options, runner);
      var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => other.ReconcileAsync());
      Assert.Equal("phase_d_operation_in_progress", failure.Message);
      Assert.Equal(1, runner.Calls);
    }
    finally { runner.Exit.TrySetResult(2); await recovery; }
    Assert.False(await recovery); // watcher ownership is not a runtime failure
  }

  [Fact]
  public async Task BackgroundReconciliationSettlesStateWithoutAGetRequest()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    var recovery = fixture.Service.ReconcileAsync();
    await runner.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
    fixture.ChangeStatus(uid, "rolled_back");
    runner.Exit.TrySetResult(0);
    Assert.True(await recovery);
    Assert.Equal("rolled_back", (await fixture.Service.GetAsync(uid))!.StatusCode);
    await fixture.Service.ReconcileAsync();
    Assert.Equal(1, runner.Calls);
  }

  [Fact]
  public async Task HostedWorkerRunsRecoveryWithoutStatusPolling()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    using var worker = new PhaseDLifecycleWorker(fixture.Service,
        Microsoft.Extensions.Logging.Abstractions.NullLogger<PhaseDLifecycleWorker>.Instance);
    await worker.StartAsync(CancellationToken.None);
    await runner.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
    fixture.ChangeStatus(uid, "rolled_back");
    runner.Exit.TrySetResult(0);
    // Allow the exact operation to settle before disposing its fixture.
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
    var gate = new PhaseDOperationGate(fixture.ExecutionRoot, TimeSpan.FromSeconds(1));
    while (true)
    {
      try { await gate.RunAsync(() => Task.FromResult(true), deadline.Token); break; }
      catch (PhaseDExecutionException exception) when (exception.Message == "phase_d_operation_in_progress")
      { await Task.Delay(10, deadline.Token); }
    }
    await worker.StopAsync(deadline.Token);
    Assert.Equal(1, runner.Calls);
    Assert.Equal("rolled_back", (await fixture.Service.GetAsync(uid))!.StatusCode);
  }

  [Theory]
  [InlineData(false, true)]
  [InlineData(true, false)]
  public async Task ResidualServerDoesNotPreventRecoveryButLiveClientDoes(bool clientActive, bool expectedRecovery)
  {
    var runner = new FakeProcessRunner { RuntimeActive = true, ClientsActive = clientActive };
    runner.Exit.TrySetResult(0);
    using var fixture = new ExecutionStateFixture(runner);
    fixture.WriteState(EntityUid.New(), "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    Assert.Equal(expectedRecovery, await fixture.Service.ReconcileAsync());
    Assert.Equal(expectedRecovery ? 1 : 0, runner.Calls);
  }

  [Fact]
  public async Task PreviouslyClosedCorruptHistoryIsIsolatedButUnknownCorruptionBlocksAdmission()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var closed = EntityUid.New();
    fixture.WriteState(closed, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "completed");
    await fixture.Service.ReconcileAsync(); // records terminal evidence in the separate index
    fixture.WriteState(closed, "\"watcherProcessStartedAtUtc\": {}", "phase_d_test_failure");
    Assert.False(await fixture.Service.ReconcileAsync());
    var unknown = EntityUid.New();
    fixture.WriteState(unknown, "\"watcherProcessStartedAtUtc\": {}", "phase_d_test_failure");
    await Assert.ThrowsAsync<PhaseDExecutionException>(() => fixture.Service.ReconcileAsync());
    Assert.Equal(0, runner.Calls);
    Assert.True(File.Exists(Path.Combine(fixture.ExecutionRoot, unknown.ToString(), "execution-state.json")));
  }

  [Fact]
  public async Task PendingEvidenceCannotBeHiddenByClosedIndex()
  {
    using var fixture = new ExecutionStateFixture(new FakeProcessRunner());
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "completed");
    await fixture.Service.ReconcileAsync();
    var pending = Directory.CreateDirectory(Path.Combine(fixture.Options.SoloRaidStateRoot, uid.ToString()));
    File.WriteAllText(Path.Combine(pending.FullName, "payload.pending.json"), "{}");
    var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => fixture.Service.ReconcileAsync());
    Assert.Equal("phase_d_execution_owner_unresolved", failure.Message);
  }

  [Fact]
  public async Task CompletedRunRetainsReceiptsWithoutBecomingActiveAgain()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "completed");
    var pending = Directory.CreateDirectory(Path.Combine(fixture.Options.SoloRaidStateRoot, uid.ToString()));
    foreach (var name in new[] { "capture.receipt.json", "persistence.receipt.json" })
      File.WriteAllText(Path.Combine(pending.FullName, name), "{}");
    Assert.False(await fixture.Service.ReconcileAsync());
    Assert.False(await fixture.Service.ReconcileAsync()); // same behavior after classification
    Assert.Equal(0, runner.Calls);
    Assert.Equal(2, Directory.GetFiles(pending.FullName).Length);
  }

  [Fact]
  public async Task CompletedStateWithPendingPayloadStillRequestsExactReplay()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "completed");
    var pending = Directory.CreateDirectory(Path.Combine(fixture.Options.SoloRaidStateRoot, uid.ToString()));
    var payloadPath = Path.Combine(pending.FullName, "payload.pending.json");
    File.WriteAllText(payloadPath, "{}");
    var recovery = fixture.Service.ReconcileAsync();
    await runner.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
    Assert.True(File.Exists(payloadPath));
    File.Delete(payloadPath); // fake child's successful exact replay/cleanup boundary
    runner.Exit.TrySetResult(0);
    Assert.True(await recovery);
    Assert.False(await fixture.Service.ReconcileAsync());
    Assert.Equal(1, runner.Calls);
  }

  [Fact]
  public async Task LiveOwnerAndLiveRuntimeNeverInvokeRecovery()
  {
    var runner = new FakeProcessRunner { OwnerActive = true };
    using var fixture = new ExecutionStateFixture(runner);
    fixture.WriteState(EntityUid.New(), "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    Assert.False(await fixture.Service.ReconcileAsync());
    runner.OwnerActive = false;
    runner.RuntimeActive = true;
    Assert.False(await fixture.Service.ReconcileAsync());
    Assert.Equal(0, runner.Calls);
  }

  [Fact]
  public async Task RecoveryFailurePreservesActiveStateAndEvidence()
  {
    var runner = new FakeProcessRunner();
    runner.Exit.SetResult(1);
    using var fixture = new ExecutionStateFixture(runner);
    var uid = EntityUid.New();
    fixture.WriteState(uid, "\"watcherProcessStartedAtUtc\": null", "phase_d_test_failure", "started");
    var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => fixture.Service.ReconcileAsync());
    Assert.Equal("phase_d_orphan_recovery_failed", failure.Message);
    Assert.Equal("started", (await fixture.Service.GetAsync(uid))!.StatusCode);
  }

  [Fact]
  public async Task LaunchIsAcceptedBeforeChildExitAndDisconnectDoesNotReleaseOwnership()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var profiles = DispatchProxy.Create<IProfileManagementService, LaunchProfiles>();
    var service = new FilesystemPhaseDExecutionService(profiles, fixture.Options, runner, preparation: new FakePreparation());
    var registryRoot = Directory.CreateDirectory(Path.Combine(fixture.Options.RepositoryRoot, "config", "boss-runtime-variants"));
    File.WriteAllText(Path.Combine(registryRoot.FullName, "registry.json"),
        """{"schemaVersion":1,"contractId":"nll/boss-runtime-variant-registry/v1","profiles":[{"seasonNumber":26,"operationalStatusCode":"enabled"}]}""");
    using var caller = new CancellationTokenSource();
    var request = new PhaseDLaunchRequest(EntityUid.New(), 26, "challenge", "water");
    var launch = await service.StartAsync(request, caller.Token).WaitAsync(TimeSpan.FromSeconds(2));
    await runner.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
    caller.Cancel();
    try
    {
      Assert.Equal("draft", launch.StatusCode);
      Assert.Equal("water", launch.WeaknessCode);
      Assert.Equal("coordinator_preparation", launch.Progress!.StageCode);
      Assert.Equal(new[] { "api_preparation", "account_snapshot", "coordinator_preparation" },
          launch.Progress.Events.Select(e => e.StageCode));
      Assert.All(launch.Progress.Events, e =>
      {
        Assert.True(e.OccurredAtUtc >= launch.Progress.RequestReceivedAtUtc);
        Assert.True(e.CumulativeMilliseconds >= 0 && e.IntervalMilliseconds >= 0);
      });
      Assert.Equal("draft", (await service.GetAsync(launch.LaunchContextUid))!.StatusCode);
      var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => service.StartAsync(request));
      Assert.Equal("phase_d_operation_in_progress", failure.Message);
      Assert.Equal(1, runner.Calls);
      var snapshot = ((LaunchProfiles)(object)profiles).Snapshot!;
      var launchRoot = Path.Combine(fixture.ExecutionRoot, launch.LaunchContextUid.ToString());
      var options = PhaseDExecutionDocumentJson.CreateOptions();
      var candidate = JsonSerializer.Deserialize<PhaseDRuntimeCandidateDocument>(
          File.ReadAllText(Path.Combine(launchRoot, "runtime-candidate.json")), options)!;
      var lobby = JsonSerializer.Deserialize<PhaseDLobbyDocument>(
          File.ReadAllText(Path.Combine(launchRoot, "lobby-projection.json")), options)!;
      Assert.Equal(1, ((LaunchProfiles)(object)profiles).SnapshotCalls);
      Assert.Equal(snapshot.Candidate.BaseRevisions.ProfileRevisionUid.ToString(), candidate.BaseRevisions.ProfileRevisionUid);
      Assert.Equal(snapshot.Candidate.CandidateSha256.ToString(), candidate.CandidateSha256);
      Assert.Equal(snapshot.Lobby!.Revision.RevisionUid.ToString(), lobby.RevisionUid);
      Assert.Equal(snapshot.Lobby.DisplayName, lobby.DisplayName);
    }
    finally
    {
      runner.Exit.TrySetResult(1);
      // Wait for the owner to drain, not for the already completed HTTP response.
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
      var gate = new PhaseDOperationGate(fixture.ExecutionRoot, TimeSpan.FromSeconds(1));
      while (true)
      {
        try { await gate.RunAsync(() => Task.FromResult(true), deadline.Token); break; }
        catch (PhaseDExecutionException exception) when (exception.Message == "phase_d_operation_in_progress")
        { await Task.Delay(10, deadline.Token); }
      }
    }
  }

  [Fact]
  public async Task PendingSaveDoesNotCreateLaunchFilesOrStartCoordinator()
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var profiles = DispatchProxy.Create<IProfileManagementService, LaunchProfiles>();
    ((LaunchProfiles)(object)profiles).PendingSave = true;
    var service = new FilesystemPhaseDExecutionService(profiles, fixture.Options, runner, preparation: new FakePreparation());
    var registryRoot = Directory.CreateDirectory(Path.Combine(fixture.Options.RepositoryRoot, "config", "boss-runtime-variants"));
    File.WriteAllText(Path.Combine(registryRoot.FullName, "registry.json"),
        """{"schemaVersion":1,"contractId":"nll/boss-runtime-variant-registry/v1","profiles":[{"seasonNumber":26,"operationalStatusCode":"enabled"}]}""");
    var failure = await Assert.ThrowsAsync<ProfileManagementException>(() => service.StartAsync(
        new PhaseDLaunchRequest(EntityUid.New(), 26, "challenge", "water")));
    Assert.Equal(ProfileManagementFailureKind.Conflict, failure.Kind);
    Assert.Equal("account_workspace_save_pending", failure.Code);
    Assert.Equal(0, runner.Calls);
    Assert.DoesNotContain(Directory.GetDirectories(fixture.ExecutionRoot),
        path => Guid.TryParseExact(Path.GetFileName(path), "D", out _));
    Assert.Empty(Directory.GetFiles(fixture.ExecutionRoot, "execution-state.json", SearchOption.AllDirectories));
    Assert.Empty(Directory.GetFiles(fixture.ExecutionRoot, "runtime-candidate.json", SearchOption.AllDirectories));
    // Rejection releases only the launch operation, not another process or Save.
    var gate = new PhaseDOperationGate(fixture.ExecutionRoot, TimeSpan.FromSeconds(1));
    Assert.True(await gate.RunAsync(() => Task.FromResult(true), CancellationToken.None));
  }

  [Fact]
  public async Task CoordinatorSerializesUnsetOptionalStateAsJsonNull()
  {
    if (!OperatingSystem.IsWindows())
    {
      return;
    }

    var repositoryRoot = FindRepositoryRoot();
    var coordinatorPath = Path.Combine(
        repositoryRoot,
        "scripts",
        "invoke-nll-phase-d-execution.ps1");
    var temporaryRoot = Path.Combine(
        Path.GetTempPath(),
        "nll-phase-d-state-test-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(temporaryRoot);
    try
    {
      var statePath = Path.Combine(temporaryRoot, "execution-state.json");
      var command = """
          $ErrorActionPreference = 'Stop'
          $source = Get-Content -LiteralPath $env:NLL_TEST_COORDINATOR -Raw -Encoding UTF8
          $source += "`n" + (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $env:NLL_TEST_COORDINATOR) 'Nll.PhaseDProcessIdentity.ps1') -Raw -Encoding UTF8)
          $tokens = $null
          $errors = $null
          $ast = [Management.Automation.Language.Parser]::ParseInput(
              $source, [ref]$tokens, [ref]$errors)
          if ($errors.Count -ne 0) { throw 'coordinator_parse_failed' }
          foreach ($name in @('Write-AtomicJson', 'Set-ExecutionState')) {
              $definition = $ast.Find({
                  param($node)
                  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                      $node.Name -ceq $name
              }, $true)
              if ($null -eq $definition) { throw ('function_missing_' + $name) }
              . ([scriptblock]::Create($definition.Extent.Text))
          }
          $candidate = [pscustomobject]@{
              accountUid = '11111111-1111-1111-1111-111111111111'
              accountLabel = 'state-test'
              baseRevisions = [pscustomobject]@{
                  revisionSetSha256 = ('a' * 64)
              }
          }
          $LaunchContextUid = '22222222-2222-2222-2222-222222222222'
          $createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
          $SeasonNumber = 26
          $ValidationKind = 'challenge'
          $WeaknessCode = 'water'
          $statePath = $env:NLL_TEST_STATE_PATH
          Set-ExecutionState -StatusCode 'failed' -FailureCode 'phase_d_test_failure'
          $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 |
              ConvertFrom-Json
          if ($null -ne $state.watcherProcessStartedAtUtc -or
              $null -ne $state.startReceiptSha256 -or
              $null -ne $state.completionReceiptSha256) {
              throw 'optional_state_not_null'
          }
          """;
      var encodedCommand = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
      using var process = new Process
      {
        StartInfo = new ProcessStartInfo
        {
          FileName = Path.Combine(
              Environment.GetFolderPath(Environment.SpecialFolder.Windows),
              "System32",
              "WindowsPowerShell",
              "v1.0",
              "powershell.exe"),
          UseShellExecute = false,
          CreateNoWindow = true,
          RedirectStandardOutput = true,
          RedirectStandardError = true
        }
      };
      process.StartInfo.ArgumentList.Add("-NoLogo");
      process.StartInfo.ArgumentList.Add("-NoProfile");
      process.StartInfo.ArgumentList.Add("-NonInteractive");
      process.StartInfo.ArgumentList.Add("-EncodedCommand");
      process.StartInfo.ArgumentList.Add(encodedCommand);
      process.StartInfo.Environment["NLL_TEST_COORDINATOR"] = coordinatorPath;
      process.StartInfo.Environment["NLL_TEST_STATE_PATH"] = statePath;

      Assert.True(process.Start());
      var standardOutput = process.StandardOutput.ReadToEndAsync();
      var standardError = process.StandardError.ReadToEndAsync();
      await process.WaitForExitAsync();
      var output = await standardOutput;
      var error = await standardError;

      Assert.True(
          process.ExitCode == 0,
          $"PowerShell state serialization failed. stdout={output} stderr={error}");
      using var document = JsonDocument.Parse(await File.ReadAllTextAsync(statePath));
      var root = document.RootElement;
      Assert.Equal(JsonValueKind.Null, root.GetProperty("watcherProcessStartedAtUtc").ValueKind);
      Assert.Equal("water", root.GetProperty("weaknessCode").GetString());
      Assert.Equal(JsonValueKind.Null, root.GetProperty("startReceiptSha256").ValueKind);
      Assert.Equal(JsonValueKind.Null, root.GetProperty("completionReceiptSha256").ValueKind);
    }
    finally
    {
      Directory.Delete(temporaryRoot, recursive: true);
    }
  }

  private static string FindRepositoryRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null && !File.Exists(Path.Combine(current.FullName, "NikkeLocalLab.sln")))
    {
      current = current.Parent;
    }

    return current?.FullName ?? throw new InvalidOperationException("repository_root_not_found");
  }

  private sealed class ExecutionStateFixture : IDisposable
  {
    private readonly string _root;

    public ExecutionStateFixture(IPhaseDProcessRunner? runner = null)
    {
      _root = Path.Combine(
          Path.GetTempPath(),
          "nll-phase-d-projection-test-" + Guid.NewGuid().ToString("N"));
      var repositoryRoot = Directory.CreateDirectory(Path.Combine(_root, "repository")).FullName;
      var executionRoot = Directory.CreateDirectory(Path.Combine(_root, "executions")).FullName;
      var soloRaidRoot = Directory.CreateDirectory(Path.Combine(_root, "solo-raid")).FullName;
      var configurationPath = WritePlaceholder("config.json");
      var coordinatorPath = WritePlaceholder("coordinator.ps1");
      var recoveryPath = WritePlaceholder("recovery.ps1");
      var powerShellPath = WritePlaceholder("powershell.exe");
      ExecutionRoot = executionRoot;
      Options = new PhaseDExecutionOptions(
              repositoryRoot,
              configurationPath,
              executionRoot,
              soloRaidRoot,
              coordinatorPath,
              recoveryPath,
              powerShellPath);
      Service = new FilesystemPhaseDExecutionService(new UnavailableProfileManagementService(), Options, runner);
    }

    public string ExecutionRoot { get; }

    public FilesystemPhaseDExecutionService Service { get; }
    public PhaseDExecutionOptions Options { get; }

    public void ChangeStatus(EntityUid uid, string status)
    {
      var path = Path.Combine(ExecutionRoot, uid.ToString(), "execution-state.json");
      File.WriteAllText(path, File.ReadAllText(path).Replace("\"statusCode\": \"started\"", $"\"statusCode\": \"{status}\"", StringComparison.Ordinal));
    }

    public void WriteState(
        EntityUid launchUid,
        string watcherTimestampProperty,
        string failureCode,
        string statusCode = "failed")
    {
      var launchRoot = Directory.CreateDirectory(
          Path.Combine(ExecutionRoot, launchUid.ToString())).FullName;
      var accountUid = EntityUid.New();
      var json = $$"""
          {
            "schemaVersion": 1,
            "contractId": "nll/phase-d-execution-state/v1",
            "launchContextUid": "{{launchUid}}",
            "createdAtUtc": "2026-08-31T10:24:10.0887474+00:00",
            "accountUid": "{{accountUid}}",
            "accountLabel": "state-test",
            "accountRevisionSetSha256": "{{new string('a', 64)}}",
            "seasonNumber": 26,
            "validationKind": "challenge",
            "statusCode": "{{statusCode}}",
            "clientProcessId": null,
            "watcherProcessId": null,
            {{watcherTimestampProperty}},
            "startReceiptSha256": null,
            "completionReceiptSha256": null,
            "failureCode": "{{failureCode}}",
            "updatedAtUtc": "2026-08-31T10:24:14.9016944+00:00"
          }
          """;
      File.WriteAllText(
          Path.Combine(launchRoot, "execution-state.json"),
          json,
          new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
    }

    public void Dispose()
    {
      Directory.Delete(_root, recursive: true);
    }

    private string WritePlaceholder(string name)
    {
      var path = Path.Combine(_root, name);
      File.WriteAllText(path, string.Empty);
      return path;
    }
  }

  [Theory]
  [InlineData("phase_d_boss_variant_profile_drifted", null)]
  [InlineData("phase_d_bundle_file_drifted", null)]
  [InlineData(null, "different-binding")]
  public async Task PreparationFailureCreatesNoLaunchOrProfileSnapshot(string? code, string? binding)
  {
    var runner = new FakeProcessRunner();
    using var fixture = new ExecutionStateFixture(runner);
    var profiles = DispatchProxy.Create<IProfileManagementService, LaunchProfiles>();
    var preparation = new FakePreparation { FailureCode = code };
    var service = new FilesystemPhaseDExecutionService(profiles, fixture.Options, runner, preparation: preparation);
    var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => service.StartAsync(
        new PhaseDLaunchRequest(EntityUid.New(), 26, "challenge", "water", binding)));
    Assert.Equal(code ?? "phase_d_preparation_changed", failure.Message);
    Assert.Equal(0, runner.Calls);
    Assert.Equal(0, ((LaunchProfiles)(object)profiles).SnapshotCalls);
    Assert.Empty(Directory.GetFiles(fixture.ExecutionRoot, "execution-state.json", SearchOption.AllDirectories));
    Assert.Equal(1, preparation.Calls);
  }

  private sealed class FakePreparation : IPhaseDPreparationService
  {
    public string? FailureCode { get; init; }
    public int Calls { get; private set; }
    public Task<PhaseDPreparationProjection> PrepareAsync(int season, string weakness, CancellationToken cancellationToken = default)
    {
      Calls++;
      return Task.FromResult(FailureCode is null
          ? new PhaseDPreparationProjection(1, "nll/phase-d-preparation/v1", season, weakness, "ready", null, new string('a', 64), "build_151.8.5")
          : PhaseDPreparationProjection.Blocked(season, weakness, FailureCode));
    }
  }

  private sealed class FakeProcessRunner : IPhaseDProcessRunner
  {
    public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource<int> Exit { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public int Calls { get; private set; }
    public bool OwnerActive { get; set; }
    public bool RuntimeActive { get; set; }
    public bool? ClientsActive { get; set; }
    public Task<int> RunAsync(ProcessStartInfo startInfo, string identityPath)
    {
      Calls++;
      Entered.TrySetResult();
      return Exit.Task;
    }
    public bool HasUnsettledOwner(string path, string executable) => OwnerActive;
    public bool RuntimeProcessExists() => RuntimeActive;
    public bool ClientProcessExists() => ClientsActive ?? RuntimeActive;
  }

  public class LaunchProfiles : DispatchProxy
  {
    public RuntimeProjectionSnapshot? Snapshot { get; private set; }
    public int SnapshotCalls { get; private set; }
    public bool PendingSave { get; set; }

    protected override object? Invoke(MethodInfo? targetMethod, object?[]? args)
    {
      if (targetMethod!.Name != nameof(IProfileManagementService.GetRuntimeProjectionSnapshotAsync))
        throw new InvalidOperationException("split_profile_read_not_allowed");
      SnapshotCalls++;
      if (PendingSave) throw new ProfileManagementException(ProfileManagementFailureKind.Conflict, "account_workspace_save_pending");
      var uid = (EntityUid)args![0]!;
      var hash = Sha256Digest.ComputeUtf8("synthetic-lifecycle");
      Snapshot = new RuntimeProjectionSnapshot(
          new RuntimeProjectionCandidate(1, "nll/runtime-projection-candidate/v1", hash, uid, "synthetic",
              new AccountWorkspaceBaseRevisions(EntityUid.New(), EntityUid.New(), null, hash), "ready", [], []),
          new LobbyPresentationProjection(uid, new RevisionReference(EntityUid.New(), hash, 1), "synthetic", 1, null, null, null, null));
      return Task.FromResult<RuntimeProjectionSnapshot?>(Snapshot);
    }
  }
}
