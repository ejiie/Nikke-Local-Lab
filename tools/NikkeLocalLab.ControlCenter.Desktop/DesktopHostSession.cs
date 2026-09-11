using System.Diagnostics;
using System.Text;

namespace NikkeLocalLab.ControlCenter.Desktop;

// No UI or installed-runtime dependency: the same pipe supervisor is exercised
// with synthetic streams/processes in the source-only regression suite.
internal sealed class DesktopHostSession : IDisposable
{
  private readonly CancellationTokenSource lifetime = new();
  private readonly TaskCompletionSource<string> bootstrap = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly Task output;
  private readonly Task error;

  internal DesktopHostSession(TextReader stdout, TextReader stderr)
  {
    output = DrainOutputAsync(stdout);
    error = DrainErrorAsync(stderr);
  }

  internal Task<string> ReadBootstrapAsync(TimeSpan timeout, CancellationToken cancellation = default) =>
      bootstrap.Task.WaitAsync(timeout, cancellation);

  private async Task DrainOutputAsync(TextReader reader)
  {
    var buffer = new char[2048];
    var line = new StringBuilder();
    const string marker = "NLL_DESKTOP_BOOTSTRAP:";
    try
    {
      int count;
      while ((count = await reader.ReadAsync(buffer.AsMemory(), lifetime.Token).ConfigureAwait(false)) != 0)
      {
        for (var index = 0; index < count; index++)
        {
          var character = buffer[index];
          // After bootstrap, keep draining without retaining any host output.
          if (bootstrap.Task.IsCompleted) continue;
          if (character != '\n')
          {
            if (line.Length >= 4096)
            {
              bootstrap.TrySetException(new InvalidOperationException("desktop_host_bootstrap_invalid"));
              line.Clear();
              continue;
            }
            line.Append(character);
            continue;
          }
          var text = line.ToString().TrimEnd('\r');
          line.Clear();
          if (!text.StartsWith(marker, StringComparison.Ordinal)) continue;
          try
          {
            var code = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(text[marker.Length..]));
            if (string.IsNullOrWhiteSpace(code) || code.Length > 256 || code.Any(char.IsControl))
              throw new InvalidOperationException();
            bootstrap.TrySetResult(code);
          }
          catch (Exception) { bootstrap.TrySetException(new InvalidOperationException("desktop_host_bootstrap_invalid")); }
        }
      }
      bootstrap.TrySetException(new InvalidOperationException("desktop_host_bootstrap_missing"));
    }
    catch (Exception)
    {
      // Never surface raw stdout, paths, bootstrap bytes, or decoder exceptions.
      bootstrap.TrySetException(new InvalidOperationException("desktop_host_bootstrap_invalid"));
    }
  }

  private async Task DrainErrorAsync(TextReader reader)
  {
    var buffer = new char[4096];
    try { while (await reader.ReadAsync(buffer.AsMemory(), lifetime.Token).ConfigureAwait(false) != 0) { } }
    catch (Exception) { bootstrap.TrySetException(new InvalidOperationException("desktop_host_stderr_failed")); }
  }

  internal async Task DrainAsync(TimeSpan timeout) => await Task.WhenAll(output, error).WaitAsync(timeout).ConfigureAwait(false);

  public void Dispose()
  {
    lifetime.Cancel();
    bootstrap.TrySetCanceled();
    _ = bootstrap.Task.Exception; // Observe unused fallback-pipe bootstrap failures.
    lifetime.Dispose();
  }
}

internal static class DesktopLifecycle
{
  internal static async Task<bool> GuardAsync(Func<Task> action, Func<Task> onFailure)
  {
    try { await action(); return true; }
    catch (Exception) { await onFailure(); return false; }
  }

  internal static async Task RequireSuccessfulExitAsync(Process process, TimeSpan timeout)
  {
    using var cancellation = new CancellationTokenSource(timeout);
    await process.WaitForExitAsync(cancellation.Token).ConfigureAwait(false);
    if (process.ExitCode != 0) throw new InvalidOperationException("desktop_host_exit_failed");
    // Timeout does NOT authorize killing a host or its PostgreSQL descendants.
  }
}
