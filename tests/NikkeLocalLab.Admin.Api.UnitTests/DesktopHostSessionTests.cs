using System.Diagnostics;
using System.Text;
using NikkeLocalLab.ControlCenter.Desktop;

namespace NikkeLocalLab.Admin.Api.UnitTests;

[Collection(WindowsProcessCollection.Name)]
public sealed class DesktopHostSessionTests
{
  [Fact]
  public async Task StartupAndNavigationFailuresAreObservedOnce()
  {
    var failures = 0;
    Assert.False(await DesktopLifecycle.GuardAsync(async () =>
    {
      await Task.Yield();
      throw new InvalidOperationException("synthetic_private_error");
    }, () => { failures++; return Task.CompletedTask; }));
    Assert.Equal(1, failures);
    Assert.True(await DesktopLifecycle.GuardAsync(() => Task.CompletedTask,
        () => { failures++; return Task.CompletedTask; }));
    Assert.Equal(1, failures);
  }

  [Theory]
  [InlineData("")]
  [InlineData("NLL_DESKTOP_BOOTSTRAP:!invalid!\n")]
  [InlineData("NLL_DESKTOP_BOOTSTRAP:Cg==\n")]
  [InlineData("NLL_DESKTOP_BOOTSTRAP://8=\n")]
  public async Task BadBootstrapIsControlledAndDoesNotExposeInput(string text)
  {
    using var session = new DesktopHostSession(new StringReader(text), new StringReader("synthetic_secret"));
    var error = await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReadBootstrapAsync(TimeSpan.FromSeconds(2)));
    Assert.StartsWith("desktop_host_bootstrap_", error.Message);
    Assert.DoesNotContain("synthetic_secret", error.ToString());
    await session.DrainAsync(TimeSpan.FromSeconds(2));
  }

  [Fact]
  public async Task OversizedLineFailsWithoutRetainingUnboundedOutput()
  {
    using var session = new DesktopHostSession(new StringReader(new string('x', 100_000)), TextReader.Null);
    var error = await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReadBootstrapAsync(TimeSpan.FromSeconds(2)));
    Assert.Equal("desktop_host_bootstrap_invalid", error.Message);
  }

  [Fact]
  public async Task ExitedChildOutputIsReadAndLargeStderrCannotBlockBootstrap()
  {
    if (!OperatingSystem.IsWindows()) return;
    using var child = StartChild("[Console]::Error.Write(('x' * 1048576)); [Console]::Out.WriteLine('NLL_DESKTOP_BOOTSTRAP:c3ludGhldGlj'); [Console]::Out.Write(('y' * 1048576)); exit 0");
    try
    {
      using var session = new DesktopHostSession(child.StandardOutput, child.StandardError);
      Assert.Equal("synthetic", await session.ReadBootstrapAsync(TimeSpan.FromSeconds(15)));
      await DesktopLifecycle.RequireSuccessfulExitAsync(child, TimeSpan.FromSeconds(15));
      await session.DrainAsync(TimeSpan.FromSeconds(5));
    }
    finally { await CleanupOwnedChildAsync(child); }
    using var alreadyExited = new DesktopHostSession(new StringReader("NLL_DESKTOP_BOOTSTRAP:c3ludGhldGlj\n"), TextReader.Null);
    Assert.Equal("synthetic", await alreadyExited.ReadBootstrapAsync(TimeSpan.FromSeconds(1)));
  }

  [Fact]
  public async Task DeadlineAndCancellationLeaveUnprovenHostAlive()
  {
    if (!OperatingSystem.IsWindows()) return;
    using var child = StartChild("Start-Sleep -Seconds 30");
    try
    {
      using var session = new DesktopHostSession(child.StandardOutput, child.StandardError);
      await Assert.ThrowsAsync<TimeoutException>(() => session.ReadBootstrapAsync(TimeSpan.FromMilliseconds(50)));
      using var canceled = new CancellationTokenSource();
      canceled.Cancel();
      await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.ReadBootstrapAsync(TimeSpan.FromSeconds(10), canceled.Token));
      await Assert.ThrowsAnyAsync<OperationCanceledException>(() => DesktopLifecycle.RequireSuccessfulExitAsync(child, TimeSpan.FromMilliseconds(50)));
      Assert.False(child.HasExited);
    }
    finally { await CleanupOwnedChildAsync(child); }
  }

  [Fact]
  public async Task FailedHostExitCannotBeReportedAsSuccessfulStop()
  {
    if (!OperatingSystem.IsWindows()) return;
    using var child = StartChild("exit 7");
    try
    {
      var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
          DesktopLifecycle.RequireSuccessfulExitAsync(child, TimeSpan.FromSeconds(10)));
      Assert.Equal("desktop_host_exit_failed", error.Message);
    }
    finally { await CleanupOwnedChildAsync(child); }
  }

  private static Process StartChild(string command)
  {
    var info = new ProcessStartInfo("powershell.exe")
    {
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true
    };
    foreach (var value in new[] { "-NoLogo", "-NoProfile", "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(command)) })
      info.ArgumentList.Add(value);
    return Process.Start(info)!;
  }

  private static async Task CleanupOwnedChildAsync(Process child)
  {
    // Test fixture ownership only. Production never kills the host on deadline.
    if (!child.HasExited) child.Kill();
    await child.WaitForExitAsync();
  }
}
