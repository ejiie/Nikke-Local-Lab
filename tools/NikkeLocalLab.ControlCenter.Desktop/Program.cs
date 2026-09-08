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
    private string? bootstrapCode;
    private bool allowClose;

    internal MainForm()
    {
      Text = "NLL 지휘관 관리 도구";
      Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
      StartPosition = FormStartPosition.CenterScreen;
      MinimumSize = new Size(1180, 760);
      Size = new Size(1500, 940);
      Controls.Add(loading);
      Shown += async (_, _) => await StartAsync();
      FormClosing += OnClosing;
    }

    private async Task StartAsync()
    {
      host = StartHost();
      bootstrapCode = await ReadBootstrapAsync(host, TimeSpan.FromSeconds(90));
      await webView.EnsureCoreWebView2Async();
      webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
      webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
      webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
      webView.CoreWebView2.NavigationCompleted += LoginAfterNavigation;
      Controls.Remove(loading);
      Controls.Add(webView);
      webView.BringToFront();
      webView.Source = new Uri("http://127.0.0.1:17878/editor/");
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

    private static async Task<string> ReadBootstrapAsync(Process process, TimeSpan timeout)
    {
      using var cancellation = new CancellationTokenSource(timeout);
      while (!process.HasExited)
      {
        var line = await process.StandardOutput.ReadLineAsync(cancellation.Token);
        if (line is null) break;
        const string marker = "NLL_DESKTOP_BOOTSTRAP:";
        if (!line.StartsWith(marker, StringComparison.Ordinal)) continue;
        return Encoding.UTF8.GetString(Convert.FromBase64String(line[marker.Length..]));
      }
      var error = await process.StandardError.ReadToEndAsync(cancellation.Token);
      throw new InvalidOperationException(string.IsNullOrWhiteSpace(error)
          ? "로컬 관리 서버가 시작되지 않았습니다."
          : $"로컬 관리 서버 시작 실패: {error.Trim()}");
    }

    private async void LoginAfterNavigation(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
      if (!args.IsSuccess || string.IsNullOrWhiteSpace(bootstrapCode)) return;
      var encoded = JsonSerializer.Serialize(bootstrapCode);
      await webView.ExecuteScriptAsync(
          $"document.getElementById('bootstrap-code').value={encoded};" +
          "document.getElementById('admin-login').click();");
      bootstrapCode = null;
    }

    private void OnClosing(object? sender, FormClosingEventArgs args)
    {
      if (allowClose) return;
      var gameRunning = new[] { "nikke", "EpinelPS", "NikkeLocalLab.Phase3B2.PhysicalBootstrap" }
          .Any(name => Process.GetProcessesByName(name).Length > 0);
      if (gameRunning)
      {
        args.Cancel = true;
        MessageBox.Show("게임 또는 로컬 전투 서버가 실행 중입니다. 먼저 게임을 종료해 주세요.",
            "종료할 수 없음", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        return;
      }
      args.Cancel = true;
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
        if (host is not null && !host.HasExited)
        {
          using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(90));
          await host.WaitForExitAsync(cancellation.Token);
        }
        stopped = true;
      }
      catch (Exception exception)
      {
        try
        {
          await RunStopFallbackAsync();
          stopped = true;
        }
        catch (Exception fallbackException)
        {
          MessageBox.Show(
              $"종료 정리 중 오류가 발생했습니다: {exception.Message}\n" +
              $"복구 종료도 실패했습니다: {fallbackException.Message}",
              "NLL 지휘관 관리 도구", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
      }
      finally
      {
        if (File.Exists(stopSignal)) File.Delete(stopSignal);
        if (stopped)
        {
          allowClose = true;
          BeginInvoke(Close);
        }
        else
        {
          Enabled = true;
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
      var outputTask = process.StandardOutput.ReadToEndAsync();
      var errorTask = process.StandardError.ReadToEndAsync();
      using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(90));
      await process.WaitForExitAsync(cancellation.Token);
      var output = await outputTask;
      var error = await errorTask;
      Require(process.ExitCode == 0,
          string.IsNullOrWhiteSpace(error) ? output.Trim() : error.Trim());
    }
  }
}
