using Microsoft.AspNetCore.Builder;
using NikkeLocalLab.Automation;

namespace NikkeLocalLab.AssetDelivery;

/// <summary>Explicit local-only Epinel startup binding. Absence is inert; partial configuration fails closed.</summary>
public sealed class ExecutionAssetOverlayStartup : IDisposable
{
  public static IReadOnlyList<string> EnvironmentNames { get; } = Array.AsReadOnly<string>(
  [
    "EPINELPS_EXECUTION_FX_ROOT",
    "EPINELPS_EXECUTION_FX_MANIFEST_SHA256",
    "EPINELPS_EXECUTION_FX_EXECUTION_CODE",
    "EPINELPS_EXECUTION_FX_CANDIDATE_SHA256",
    "EPINELPS_EXECUTION_FX_PROFILE_SHA256",
    "EPINELPS_EXECUTION_FX_WEAKNESS_CODE"
  ]);
  private readonly ExecutionAssetOverlay overlay;

  private ExecutionAssetOverlayStartup(ExecutionAssetOverlay overlay) => this.overlay = overlay;

  public static ExecutionAssetOverlayStartup? OpenFromEnvironment(
      string runtimeRoot, bool localOnly, bool headless, bool officialOutboundEnabled,
      Func<string, string?>? readEnvironment = null)
  {
    readEnvironment ??= Environment.GetEnvironmentVariable;
    var values = EnvironmentNames.Select(readEnvironment).ToArray();
    if (values.All(value => value is null))
      return null;
    try
    {
      if (!localOnly || !headless || officialOutboundEnabled || values.Any(string.IsNullOrWhiteSpace))
        throw new InvalidDataException();
      // A fixed child of the independent execution runtime, never its shared cache junction.
      var expected = Path.GetFullPath(Path.Combine(runtimeRoot, "execution-fx"));
      var actual = Path.TrimEndingDirectorySeparator(Path.GetFullPath(values[0]!));
      if (!string.Equals(expected, actual,
          OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
        throw new InvalidDataException();
      var binding = new ExecutionAssetBinding(values[2]!, values[3]!, values[4]!, values[5]!);
      return new(ExecutionAssetOverlay.Open(actual, values[1]!, binding, officialOutboundEnabled));
    }
    catch (Exception ex) when (ex is IOException or InvalidDataException or ArgumentException or UnauthorizedAccessException)
    {
      // Do not emit private route/path data through the external server's fatal-error logger.
      throw new InvalidDataException("execution_fx_startup_rejected");
    }
  }

  /// <summary>Mount before static files, encryption and legacy asset routes. Dispose only after host shutdown.</summary>
  public void Mount(WebApplication app)
  {
    var http = new ExecutionAssetOverlayHttp(overlay);
    app.Use(async (context, next) =>
    {
      if (!await http.TryHandleAsync(context))
        await next(context);
    });
  }

  // Shutdown detaches/zeros the transport but does NOT retire copies. A server
  // exiting is not proof that its client/bootstrap/descendant processes exited.
  public void Dispose() => overlay.Dispose();
}
