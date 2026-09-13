using System.Diagnostics;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationExecutionTests
{
  [Theory]
  [InlineData("Start", "invalid")]
  [InlineData("unknown", "water")]
  public async Task InvalidActionsNeverLaunchAProcess(string mode, string weakness)
  {
    var fake = new FakeLauncher(); var service = new UserValidationExecution(new DeliveryFixture().Service, fake);
    await Assert.ThrowsAsync<ApiRequestException>(() => service.BeginAsync(new(Guid.NewGuid(), 29, weakness, new string('a', 64), new string('b', 64), mode), default));
    Assert.Equal(0, fake.Starts);
  }
  [Fact]
  public async Task UserRequestIsBoundIdempotentAndDoesNotCancelWhenHttpDisappears()
  {
    using var fixture = new ExecutionFixture();
    var request = fixture.Request();
    var accepted = await fixture.Service.BeginAsync(request, default);
    Assert.Equal("awaiting_user_approval", accepted.StatusCode);
    await fixture.Launcher.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    var replay = await fixture.Service.BeginAsync(request, default);
    Assert.Equal(request.OperationUid, replay.OperationUid); Assert.Equal(1, fixture.Launcher.Starts);
    var info = fixture.Launcher.Info!;
    Assert.True(info.UseShellExecute); Assert.Equal("runas", info.Verb); Assert.Equal(ProcessWindowStyle.Hidden, info.WindowStyle);
    Assert.Contains("Start", info.ArgumentList); Assert.Contains(request.EntrySha256, info.ArgumentList);
    Assert.False(info.RedirectStandardOutput); Assert.DoesNotContain("-Command", info.ArgumentList);
    var runner = info.ArgumentList[info.ArgumentList.IndexOf("-File") + 1];
    Assert.Equal("diagnostic-runner.ps1", Path.GetFileName(runner));
    Assert.Contains("controller-diagnostic.json", await File.ReadAllTextAsync(runner));
    Assert.Contains("-ControllerPath", info.ArgumentList);
    var other = request with { OperationUid = Guid.NewGuid(), WeaknessCode = "fire", EntrySha256 = fixture.Delivery.Service.Get(29).Selections.Single(s => s.WeaknessCode == "fire").EntrySha256 };
    await Assert.ThrowsAsync<ApiRequestException>(() => fixture.Service.BeginAsync(other, default));
    await fixture.Finish(); Assert.Equal("failed", fixture.Service.Get(29, "water").StatusCode);
    using var diagnostic = JsonDocument.Parse(await File.ReadAllBytesAsync(Path.Combine(Path.GetDirectoryName(runner)!, "process-exit.json")));
    Assert.Equal(1, diagnostic.RootElement.GetProperty("exitCode").GetInt32());
    Assert.False(diagnostic.RootElement.GetProperty("controllerDiagnosticPresent").GetBoolean());
  }
  [Fact]
  public async Task UacCancellationIsKnownNoStartAndAllowsANewExplicitAttempt()
  {
    using var fixture = new ExecutionFixture(); fixture.Launcher.Cancel = true;
    await fixture.Service.BeginAsync(fixture.Request(), default); await fixture.Finish();
    Assert.Equal("uac_cancelled", fixture.Service.Get(29, "water").StatusCode);
    Assert.False(File.Exists(fixture.Map(fixture.Run + @"\execution.started.json")));
    fixture.Launcher.Reset(); fixture.Launcher.Cancel = true;
    await fixture.Service.BeginAsync(fixture.Request(), default); await fixture.Finish(); Assert.Equal(2, fixture.Launcher.Starts);
  }
  [Fact]
  public async Task RestoredControllerFailureIsNotHiddenOrPromotedToAcceptance()
  {
    using var fixture = new ExecutionFixture(); var request = fixture.Request();
    await fixture.Service.BeginAsync(request, default);
    await fixture.Launcher.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    fixture.Save(fixture.Run + @"\execution.started.json", new { entrySha256 = request.EntrySha256 });
    fixture.Save(fixture.Run + @"\cleanup.receipt.json", new
    {
      contractId = "nll/user-validation-managed-scope-cleanup/v1",
      jobZeroVerified = true,
      serviceZeroVerified = true,
      scopeZeroVerified = true,
      serviceStartModeRestored = true,
      driverBaselineRestored = true,
      ownedInputsRestored = true,
      isolationReleased = true,
      actualGameAcceptanceClaimed = false
    });
    await fixture.Finish(); var view = fixture.Service.Get(29, "water");
    Assert.Equal("finished", view.StatusCode); Assert.Equal("boss_validation_controller_failed", view.FailureCode);
    Assert.False(view.ActualGameAcceptanceClaimed);
    await Assert.ThrowsAsync<ApiRequestException>(() => fixture.Service.BeginAsync(fixture.Request(), default));
  }
  [Fact]
  public async Task UnrestoredAttemptCannotRestartAndRecoveryRequiresAnExplicitRequest()
  {
    using var fixture = new ExecutionFixture(); var request = fixture.Request();
    fixture.Save(fixture.Run + @"\execution.started.json", new { entrySha256 = request.EntrySha256 });
    Assert.Equal("cleanup_required", fixture.Service.Get(29, "water").StatusCode); Assert.Equal(0, fixture.Launcher.Starts);
    await Assert.ThrowsAsync<ApiRequestException>(() => fixture.Service.BeginAsync(request, default));
    await fixture.Service.BeginAsync(request with { Mode = "Recover" }, default);
    await fixture.Launcher.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
    Assert.Contains("Recover", fixture.Launcher.Info!.ArgumentList);
    await fixture.Finish(); Assert.Equal("cleanup_required", fixture.Service.Get(29, "water").StatusCode);
  }
  [Fact]
  public async Task RealLauncherRejectsNonUserModeBeforeAnyProcessOrOwnerWrite()
  {
    var path = Path.Combine(Path.GetTempPath(), "nll-no-owner-" + Guid.NewGuid().ToString("N"));
    await Assert.ThrowsAsync<JsonException>(() => new UserValidationProcessLauncher().RunAsync(new() { FileName = "not-an-executable", UseShellExecute = false }, path));
    Assert.False(File.Exists(path));
  }
  [Fact]
  public void LaunchDiagnosticPreservesSystemCodeWithoutExceptionMessageOrTarget()
  {
    var error = new System.ComponentModel.Win32Exception(5, "SYNTHETIC_SECRET_MUST_NOT_APPEAR");
    var text = JsonSerializer.Serialize(UserValidationExecution.ErrorDiagnostic("process_start", error));
    Assert.DoesNotContain("SYNTHETIC_SECRET_MUST_NOT_APPEAR", text);
    using var value = JsonDocument.Parse(text);
    Assert.Equal(5, value.RootElement.GetProperty("nativeErrorCode").GetInt32());
    Assert.Equal(error.HResult, value.RootElement.GetProperty("hResult").GetInt32());
  }
  [Fact]
  public async Task UnexpectedCompletionErrorIsPersistedWithoutRawMessage()
  {
    using var fixture = new ExecutionFixture(); fixture.Launcher.Unexpected = true;
    var request = fixture.Request();
    await fixture.Service.BeginAsync(request, default); await fixture.Finish();
    Assert.Equal("status_unknown", fixture.Service.Get(29, "water").StatusCode);
    var path = fixture.Map(fixture.Run + @"\ui-actions\" + request.OperationUid.ToString("D") + @"\action-error.json");
    var text = await File.ReadAllTextAsync(path);
    Assert.Contains("System.IO.IOException", text); Assert.DoesNotContain("SYNTHETIC_SECRET_MUST_NOT_APPEAR", text);
  }
  private sealed class ExecutionFixture : IDisposable
  {
    private readonly string root = Path.Combine(Path.GetTempPath(), "nll-validation-actions-" + Guid.NewGuid().ToString("N"));
    internal DeliveryFixture Delivery { get; } = new();
    internal FakeLauncher Launcher { get; } = new();
    internal UserValidationExecution Service { get; }
    internal string Run => Delivery.Service.ReadBound().Entries["water"].RunRoot;
    internal ExecutionFixture()
    {
      Directory.CreateDirectory(root); Service = new(Delivery.Service, Launcher) { StorePath = Map };
    }
    internal string Map(string path)
    {
      if (path.StartsWith(Delivery.TrialRoot, StringComparison.Ordinal))
        path = root + path[Delivery.TrialRoot.Length..].Replace('\\', Path.DirectorySeparatorChar);
      path = Path.GetFullPath(path);
      Assert.True(path == root || path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal));
      return path;
    }
    internal UserValidationActionRequest Request()
    {
      var view = Delivery.Service.Get(29); return new(Guid.NewGuid(), 29, "water", view.BindingSha256!, view.Selections.Single(s => s.WeaknessCode == "water").EntrySha256, "Start");
    }
    internal void Save(string path, object value)
    {
      path = Map(path); Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllBytes(path, JsonSerializer.SerializeToUtf8Bytes(value));
    }
    internal async Task Finish()
    {
      Launcher.Done.TrySetResult();
      var deadline = Stopwatch.StartNew();
      while (deadline.Elapsed < TimeSpan.FromSeconds(5))
      {
        if (Service.Get(29, "water").StatusCode is not ("running" or "awaiting_user_approval") &&
            Directory.GetFiles(root, "result.json", SearchOption.AllDirectories).Length == Launcher.Starts) return;
        await Task.Delay(20);
      }
      throw new TimeoutException("synthetic_action_did_not_settle");
    }
    public void Dispose()
    {
      Launcher.Done.TrySetResult();
      // Only this exact newly created synthetic test root, never a user lane.
      Assert.StartsWith(Path.GetFullPath(Path.GetTempPath()) + "nll-validation-actions-", Path.GetFullPath(root), StringComparison.Ordinal);
      if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
    }
  }
  private sealed class FakeLauncher : IUserValidationProcessLauncher
  {
    internal int Starts; internal bool Cancel; internal bool Unexpected;
    internal ProcessStartInfo? Info;
    internal TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal TaskCompletionSource Done = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal void Reset() { Entered = new(TaskCreationOptions.RunContinuationsAsynchronously); Done = new(TaskCreationOptions.RunContinuationsAsynchronously); }
    public async Task<int> RunAsync(ProcessStartInfo info, string ownerPath)
    {
      Starts++; Info = info; Entered.TrySetResult(); await Done.Task;
      await PhaseDAtomicFile.WriteAsync(ownerPath, new UserValidationOwner("exited", info.FileName), FilesystemBossSeasonCatalogService.JsonOptions);
      if (Cancel) throw new PhaseDExecutionException("boss_validation_uac_cancelled");
      if (Unexpected) throw new IOException("SYNTHETIC_SECRET_MUST_NOT_APPEAR");
      return 1;
    }
    public bool IsUnsettled(string ownerPath, string executablePath)
    {
      var owner = JsonSerializer.Deserialize<UserValidationOwner>(File.ReadAllBytes(ownerPath), FilesystemBossSeasonCatalogService.JsonOptions);
      Assert.Equal(executablePath, owner!.ExecutablePath); return owner.State != "exited";
    }
  }
}
