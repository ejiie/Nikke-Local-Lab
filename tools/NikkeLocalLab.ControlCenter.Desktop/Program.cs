using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace NikkeLocalLab.ControlCenter.Desktop;

internal static class Program
{
  private const string InstalledStart = @"C:\NLL\ControlCenter\Start-NLL-ControlCenter.ps1";
  private const string InstalledStop = @"C:\NLL\ControlCenter\Stop-NLL-ControlCenter.ps1";

  [STAThread]
  private static void Main()
  {
    ApplicationConfiguration.Initialize();
    try
    {
      Require(IsAdministrator() &&
              string.Equals(Environment.UserName, "nlloperator", StringComparison.Ordinal),
          "이 프로그램은 Micron의 nlloperator 관리자 환경에서만 실행할 수 있습니다.");
      Require(File.Exists(InstalledStart), "설치된 실행 스크립트를 찾을 수 없습니다.");
      Application.Run(new MainForm());
    }
    catch (Exception exception)
    {
      MessageBox.Show(exception.Message, "NLL 지휘관 관리 도구",
          MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
  }

  private static bool IsAdministrator()
  {
    using var identity = WindowsIdentity.GetCurrent();
    return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
  }

  private static void Require(bool condition, string message)
  {
    if (!condition) throw new InvalidOperationException(message);
  }

  private sealed class MainForm : Form
  {
    private readonly WebView2 webView = new() { Dock = DockStyle.Fill };
    private readonly Label loading = new()
    {
      Dock = DockStyle.Fill,
      Text = "지휘관 관리 도구를 준비하고 있습니다…",
      TextAlign = ContentAlignment.MiddleCenter,
      Font = new Font("Malgun Gothic", 14, FontStyle.Bold),
      ForeColor = Color.FromArgb(30, 63, 92),
      BackColor = Color.FromArgb(244, 248, 252)
    };
    private readonly string stopSignal = Path.Combine(
        Path.GetTempPath(), $"nll-control-center-stop-{Guid.NewGuid():N}.signal");
    private Process? host;
    private DesktopHostSession? hostSession;
    private readonly CancellationTokenSource closing = new();
    private string? bootstrapCode;
    private bool allowClose;
    private bool stopping;
    private readonly TaskCompletionSource<bool> navigation = new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal MainForm()
    {
      Text = "NLL 지휘관 관리 도구";
      Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
      StartPosition = FormStartPosition.CenterScreen;
      MinimumSize = new Size(1180, 760);
      Size = new Size(1500, 940);
      Controls.Add(loading);
      Shown += async (_, _) => await DesktopLifecycle.GuardAsync(StartAsync, StartupFailedAsync);
      FormClosing += OnClosing;
      FormClosed += (_, _) => { closing.Cancel(); hostSession?.Dispose(); host?.Dispose(); webView.Dispose(); closing.Dispose(); };
    }

    private async Task StartAsync()
    {
      host = StartHost();
      hostSession = new DesktopHostSession(host.StandardOutput, host.StandardError);
      bootstrapCode = await hostSession.ReadBootstrapAsync(TimeSpan.FromSeconds(90), closing.Token);
      await webView.EnsureCoreWebView2Async().WaitAsync(TimeSpan.FromSeconds(60), closing.Token);
      closing.Token.ThrowIfCancellationRequested();
      webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
      webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
      webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
      webView.CoreWebView2.NavigationCompleted += LoginAfterNavigation;
      Controls.Remove(loading);
      Controls.Add(webView);
      webView.BringToFront();
      webView.Source = new Uri("http://127.0.0.1:17878/editor/");
      Require(await navigation.Task.WaitAsync(TimeSpan.FromSeconds(60), closing.Token), "desktop_navigation_failed");
    }

    private Process StartHost()
    {
      var info = new ProcessStartInfo
      {
        FileName = "powershell.exe",
        Arguments = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{InstalledStart}\" " +
                    $"-DesktopHost -DesktopStopSignalPath \"{stopSignal}\"",
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8
      };
      return Process.Start(info) ?? throw new InvalidOperationException("로컬 서버를 시작하지 못했습니다.");
    }

    private Task StartupFailedAsync()
    {
      bootstrapCode = null;
      if (stopping || IsDisposed) return Task.CompletedTask;
      MessageBox.Show("관리 도구 초기화에 실패했습니다. 안전 종료를 시도합니다. 반복되면 desktop_start_failed를 알려 주세요.",
          "NLL 지휘관 관리 도구", MessageBoxButtons.OK, MessageBoxIcon.Error);
      Close();
      return Task.CompletedTask;
    }

    private async void LoginAfterNavigation(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
      navigation.TrySetResult(args.IsSuccess);
      if (stopping || string.IsNullOrWhiteSpace(bootstrapCode)) return;
      var encoded = JsonSerializer.Serialize(bootstrapCode);
      bootstrapCode = null;
      await DesktopLifecycle.GuardAsync(async () =>
      {
        Require(args.IsSuccess && webView.Source?.AbsoluteUri == "http://127.0.0.1:17878/editor/",
            "desktop_navigation_failed");
        await webView.ExecuteScriptAsync(
            $"document.getElementById('bootstrap-code').value={encoded};" +
            "document.getElementById('admin-login').click();").WaitAsync(TimeSpan.FromSeconds(30), closing.Token);
      }, StartupFailedAsync);
    }

    private void OnClosing(object? sender, FormClosingEventArgs args)
    {
      if (allowClose) return;
      args.Cancel = true;
      if (stopping) return;
      var gameRunning = new[] { "nikke", "EpinelPS", "NikkeLocalLab.Phase3B2.PhysicalBootstrap" }
          .Any(name => Process.GetProcessesByName(name).Length > 0);
      if (gameRunning)
      {
        args.Cancel = true;
        MessageBox.Show("게임 또는 로컬 전투 서버가 실행 중입니다. 먼저 게임을 종료해 주세요.",
            "종료할 수 없음", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return;
      }
      stopping = true;
      closing.Cancel();
      Enabled = false;
      loading.Text = "안전하게 종료하고 있습니다…";
      Controls.Clear();
      Controls.Add(loading);
      _ = StopAsync();
    }

    private async Task StopAsync()
    {
      var stopped = false;
      try
      {
        await File.WriteAllTextAsync(stopSignal, "stop\n", new UTF8Encoding(false));
        if (host is not null)
        {
          await DesktopLifecycle.RequireSuccessfulExitAsync(host, TimeSpan.FromSeconds(90));
          if (hostSession is not null) await hostSession.DrainAsync(TimeSpan.FromSeconds(5));
        }
        RequireDatabaseStopped();
        stopped = true;
      }
      catch (Exception)
      {
        try
        {
          await RunStopFallbackAsync();
          if (host is not null)
          {
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await host.WaitForExitAsync(cancellation.Token);
            if (hostSession is not null) await hostSession.DrainAsync(TimeSpan.FromSeconds(5));
          }
          RequireDatabaseStopped();
          stopped = true;
        }
        catch (Exception)
        {
          MessageBox.Show(
              "안전 종료를 확인하지 못했습니다(desktop_stop_unproven). 프로세스를 강제 종료하지 말고 복구를 요청해 주세요.",
              "NLL 지휘관 관리 도구", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
      }
      finally
      {
        // A late host must still see the stop request after a timeout.
        if (stopped)
        {
          try { if (File.Exists(stopSignal)) File.Delete(stopSignal); }
          catch (IOException) { }
          catch (UnauthorizedAccessException) { }
        }
        if (stopped)
        {
          allowClose = true;
          BeginInvoke(Close);
        }
        else
        {
          Enabled = true;
          stopping = false;
          Controls.Clear();
          Controls.Add(webView);
          webView.BringToFront();
        }
      }
    }

    private static async Task RunStopFallbackAsync()
    {
      Require(File.Exists(InstalledStop), "설치된 종료 스크립트를 찾을 수 없습니다.");
      using var process = Process.Start(new ProcessStartInfo
      {
        FileName = "powershell.exe",
        Arguments = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{InstalledStop}\"",
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8
      }) ?? throw new InvalidOperationException("복구 종료 프로세스를 시작하지 못했습니다.");
      using var pipes = new DesktopHostSession(process.StandardOutput, process.StandardError);
      await DesktopLifecycle.RequireSuccessfulExitAsync(process, TimeSpan.FromSeconds(90));
      await pipes.DrainAsync(TimeSpan.FromSeconds(5));
    }

    private static void RequireDatabaseStopped()
    {
      // Read-only admission check, never a name-based termination policy.
      foreach (var name in new[] { "postgres", "pg_ctl" })
      {
        var processes = Process.GetProcessesByName(name);
        try { Require(processes.Length == 0, "desktop_database_stop_unproven"); }
        finally { foreach (var process in processes) process.Dispose(); }
      }
    }
  }
}
