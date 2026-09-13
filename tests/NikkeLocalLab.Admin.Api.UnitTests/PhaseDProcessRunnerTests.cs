using System.Diagnostics;
using System.Text.Json;

namespace NikkeLocalLab.Admin.Api.UnitTests;

[Collection(WindowsProcessCollection.Name)]
public sealed class PhaseDProcessRunnerTests
{
  [Theory]
  [InlineData("running", 0, false, true)]
  [InlineData("running", 1, false, false)]
  [InlineData("exited", 0, false, false)]
  [InlineData("starting", 0, false, null)]
  [InlineData("running", 0, true, null)]
  public void OwnerProofUsesStartTimeAndPath(string state, int shiftedSeconds, bool wrongPath, bool? expected)
  {
    var root = Directory.CreateTempSubdirectory("nll-owner-proof-").FullName;
    using var current = Process.GetCurrentProcess();
    try
    {
      var path = Path.Combine(root, "owner.json");
      var executable = current.MainModule!.FileName;
      File.WriteAllText(path, JsonSerializer.Serialize(new
      {
        SchemaVersion = 1,
        State = state,
        ProcessId = current.Id,
        StartedAtUtc = current.StartTime.ToUniversalTime().AddSeconds(shiftedSeconds),
        ExecutablePath = wrongPath ? Path.Combine(root, "different.exe") : executable
      }));
      var runner = new PhaseDProcessRunner();
      if (expected is null)
      {
        var failure = Assert.Throws<PhaseDExecutionException>(() => runner.HasUnsettledOwner(path, executable));
        Assert.Equal("phase_d_owner_identity_unresolved", failure.Message);
      }
      else Assert.Equal(expected.Value, runner.HasUnsettledOwner(path, executable));
      Assert.False(current.HasExited); // read-only proof; never a termination test
    }
    finally { Directory.Delete(root, recursive: true); }
  }

  [Fact]
  public void MalformedOwnerDoesNotMeanCold()
  {
    var root = Directory.CreateTempSubdirectory("nll-owner-proof-").FullName;
    try
    {
      var path = Path.Combine(root, "owner.json");
      File.WriteAllText(path, "{");
      Assert.Throws<PhaseDExecutionException>(() => new PhaseDProcessRunner().HasUnsettledOwner(path, Path.Combine(root, "fake.exe")));
    }
    finally { Directory.Delete(root, recursive: true); }
  }

  [Fact]
  public async Task FailedChildCreationPublishesNoLiveOwner()
  {
    var root = Directory.CreateTempSubdirectory("nll-owner-proof-").FullName;
    try
    {
      var executable = Path.Combine(root, "does-not-exist.exe");
      var owner = Path.Combine(root, "owner.json");
      var runner = new PhaseDProcessRunner();
      var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => runner.RunAsync(
          new ProcessStartInfo { FileName = executable, UseShellExecute = false, CreateNoWindow = true }, owner));
      Assert.Equal("phase_d_child_start_failed", failure.Message);
      Assert.False(runner.HasUnsettledOwner(owner, executable));
    }
    finally { Directory.Delete(root, recursive: true); }
  }

  [Fact]
  public async Task HarmlessExactChildExitPublishesExitedOwner()
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = Directory.CreateTempSubdirectory("nll-owner-proof-").FullName;
    try
    {
      var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
          "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      var info = new ProcessStartInfo
      {
        FileName = executable,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      };
      foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "exit 0" })
        info.ArgumentList.Add(argument);
      var owner = Path.Combine(root, "owner.json");
      var runner = new PhaseDProcessRunner();
      Assert.Equal(0, await runner.RunAsync(info, owner).WaitAsync(TimeSpan.FromSeconds(10)));
      Assert.False(runner.HasUnsettledOwner(owner, executable));
      using var state = JsonDocument.Parse(File.ReadAllText(owner));
      Assert.Equal("exited", state.RootElement.GetProperty("State").GetString());
      Assert.True(state.RootElement.GetProperty("ProcessId").GetInt32() > 0);
    }
    finally { Directory.Delete(root, recursive: true); }
  }

  [Fact]
  public async Task ExactChildExitDoesNotWaitForInheritedOutputHandles()
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = Directory.CreateTempSubdirectory("nll-child-pipe-").FullName;
    var release = Path.Combine(root, "release");
    var descendantStarted = Path.Combine(root, "descendant-started");
    var descendantEnded = Path.Combine(root, "descendant-ended");
    Task<int>? run = null;
    try
    {
      var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
          "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      static string Literal(string value) => "'" + value.Replace("'", "''") + "'";
      var descendant = $"[IO.File]::WriteAllText({Literal(descendantStarted)}, 'ready'); " +
          $"$deadline = [DateTime]::UtcNow.AddSeconds(20); while (-not [IO.File]::Exists({Literal(release)}) " +
          "-and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }; " +
          $"[IO.File]::WriteAllText({Literal(descendantEnded)}, 'done')";
      var encoded = Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(descendant));
      // UseShellExecute=false and no redirection: the grandchild inherits BOTH
      // output handles, but its lifetime must not own the coordinator lease.
      var parent = "$i = New-Object Diagnostics.ProcessStartInfo; " +
          $"$i.FileName = {Literal(executable)}; $i.Arguments = '-NoProfile -EncodedCommand {encoded}'; " +
          "$i.UseShellExecute = $false; $i.CreateNoWindow = $true; " +
          "$p = [Diagnostics.Process]::Start($i); $p.Dispose(); exit 7";
      var info = new ProcessStartInfo
      {
        FileName = executable,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      };
      foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-EncodedCommand",
          Convert.ToBase64String(System.Text.Encoding.Unicode.GetBytes(parent)) }) info.ArgumentList.Add(arg);
      var owner = Path.Combine(root, "owner.json");
      run = new PhaseDProcessRunner().RunAsync(info, owner);
      var descendantDeadline = DateTime.UtcNow.AddSeconds(5);
      while (!File.Exists(descendantStarted) && DateTime.UtcNow < descendantDeadline) await Task.Delay(25);
      Assert.True(File.Exists(descendantStarted));
      Assert.Equal(7, await run.WaitAsync(TimeSpan.FromSeconds(8)));
      using var state = JsonDocument.Parse(File.ReadAllText(owner));
      Assert.Equal("exited", state.RootElement.GetProperty("State").GetString());
      Assert.False(File.Exists(descendantEnded));
    }
    finally
    {
      // Cooperatively release only our synthetic child; never kill by name/PID.
      File.WriteAllText(release, "release");
      if (run is not null) await run.WaitAsync(TimeSpan.FromSeconds(25));
      var deadline = DateTime.UtcNow.AddSeconds(10);
      while (!File.Exists(descendantEnded) && DateTime.UtcNow < deadline) await Task.Delay(25);
      if (File.Exists(descendantEnded)) Directory.Delete(root, recursive: true);
    }
  }

  [Theory]
  [InlineData("test-nll-phase-d-process-identity.ps1")]
  [InlineData("test-nll-phase-d-access-rights.ps1")]
  [InlineData("test-nll-phase-d-residual-recovery.ps1")]
  [InlineData("test-nll-phase-d-native-process-handle.ps1")]
  [InlineData("test-nll-phase-d-recovery-database.ps1")]
  [InlineData("test-nll-phase-d-coordinator-failure.ps1")]
  [InlineData("test-nll-phase-d-watcher-failure.ps1")]
  [InlineData("test-nll-phase-d-exact-child-wait.ps1")]
  [InlineData("test-nll-phase-d-completion-diagnostics.ps1")]
  [InlineData("test-nll-phase-d-watcher-completion.ps1")]
  public async Task PowerShellLifecycleHelpersPassOfflineBehaviorChecks(string scriptName)
  {
    if (!OperatingSystem.IsWindows()) return;
    var root = new DirectoryInfo(AppContext.BaseDirectory);
    while (root is not null && !File.Exists(Path.Combine(root.FullName, "NikkeLocalLab.sln"))) root = root.Parent;
    Assert.NotNull(root);
    using var process = new Process
    {
      StartInfo = new ProcessStartInfo
      {
        FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      }
    };
    foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
        Path.Combine(root.FullName, "scripts", scriptName) })
      process.StartInfo.ArgumentList.Add(argument);
    // A pwsh-hosted test must not give Windows PowerShell the PS7 module path.
    process.StartInfo.Environment.Remove("PSModulePath");
    Assert.True(process.Start());
    var output = process.StandardOutput.ReadToEndAsync();
    var error = process.StandardError.ReadToEndAsync();
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(40));
    try { await process.WaitForExitAsync(timeout.Token); }
    catch (OperationCanceledException) { process.Kill(); throw; } // only this test-created helper handle
    Assert.True(process.ExitCode == 0, (await output) + (await error));
  }
}
