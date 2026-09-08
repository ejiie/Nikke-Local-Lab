using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace NikkeLocalLab.Admin.Api;

public sealed record PhaseDPreparationRequest(int SeasonNumber, string WeaknessCode);

// Configuration readiness only; never proof of a cold runtime or account readiness.
public sealed record PhaseDPreparationProjection(
    int SchemaVersion, string ContractId, int SeasonNumber, string WeaknessCode,
    string StatusCode, string? FailureCode, string? BindingSha256, string? ClientBuildCode)
{
  public static PhaseDPreparationProjection Blocked(int season, string weakness, string code) =>
      new(1, "nll/phase-d-preparation/v1", season, weakness, "blocked", code, null, null);
}

public interface IPhaseDPreparationService
{
  Task<PhaseDPreparationProjection> PrepareAsync(int season, string weakness, CancellationToken cancellationToken = default);
}

public sealed class UnavailablePhaseDPreparationService : IPhaseDPreparationService
{
  public Task<PhaseDPreparationProjection> PrepareAsync(int season, string weakness, CancellationToken cancellationToken = default) =>
      Task.FromResult(PhaseDPreparationProjection.Blocked(season, weakness, "phase_d_execution_not_configured"));
}

public sealed class PowerShellPhaseDPreparationService(string repositoryRoot, string powerShellPath) : IPhaseDPreparationService
{
  private static readonly JsonSerializerOptions JsonOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
  };
  private readonly SemaphoreSlim _reader = new(1, 1);

  public async Task<PhaseDPreparationProjection> PrepareAsync(int season, string weakness, CancellationToken cancellationToken = default)
  {
    if (season <= 0 || weakness is not ("fire" or "water" or "wind" or "electric" or "iron"))
      return PhaseDPreparationProjection.Blocked(season, weakness, "phase_d_launch_request_invalid");

    // No cache: Start must re-read pins even if an earlier UI query was ready.
    // Serialize expensive local hash checks; cancelled/obsolete queries do not own a launch.
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    timeout.CancelAfter(TimeSpan.FromSeconds(90));
    var entered = false;
    using var process = new Process();
    var started = false;
    try
    {
      await _reader.WaitAsync(timeout.Token).ConfigureAwait(false);
      entered = true;
      process.StartInfo = new ProcessStartInfo(powerShellPath)
      {
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      };
      foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
          Path.Combine(repositoryRoot, "scripts", "get-nll-phase-d-preparation.ps1"), "-RepositoryRoot", repositoryRoot,
          "-SeasonNumber", season.ToString(CultureInfo.InvariantCulture), "-WeaknessCode", weakness })
        process.StartInfo.ArgumentList.Add(argument);
      started = process.Start();
      if (!started) throw new InvalidOperationException();
      var output = ReadBoundedAsync(process.StandardOutput, timeout.Token);
      var error = ReadBoundedAsync(process.StandardError, timeout.Token);
      await Task.WhenAll(output, error, process.WaitForExitAsync(timeout.Token)).ConfigureAwait(false);
      if (process.ExitCode != 0 || !string.IsNullOrWhiteSpace(error.Result)) throw new InvalidOperationException();
      return ParseProjection(output.Result, season, weakness);
    }
    catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
    {
      return PhaseDPreparationProjection.Blocked(season, weakness, "phase_d_preparation_timeout");
    }
    catch (OperationCanceledException) { throw; }
    catch (Exception exception) when (exception is IOException or System.ComponentModel.Win32Exception or InvalidOperationException or JsonException)
    {
      return PhaseDPreparationProjection.Blocked(season, weakness, "phase_d_preparation_unavailable");
    }
    finally
    {
      // This handle owns only the read-only preparation process, never a game/server.
      if (started)
      {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
      }
      if (entered) _reader.Release();
    }
  }

  public static PhaseDPreparationProjection ParseProjection(string json, int season, string weakness)
  {
    var result = JsonSerializer.Deserialize<PhaseDPreparationProjection>(json, JsonOptions);
    if (result is null || result.SchemaVersion != 1 || result.ContractId != "nll/phase-d-preparation/v1" ||
        result.SeasonNumber != season || result.WeaknessCode != weakness ||
        (result.StatusCode == "ready" ? result.FailureCode is not null || !IsHash(result.BindingSha256) ||
            result.ClientBuildCode is not ("build_150.6.9" or "build_151.8.5") :
            result.StatusCode != "blocked" || result.BindingSha256 is not null || result.ClientBuildCode is not null ||
            result.FailureCode is null || !Regex.IsMatch(result.FailureCode, "\\Aphase_d_[a-z0-9_]{3,120}\\z", RegexOptions.CultureInvariant)))
      throw new JsonException("phase_d_preparation_projection_invalid");
    return result;
  }

  private static bool IsHash(string? value) => value is not null && Regex.IsMatch(value, "\\A[0-9a-f]{64}\\z", RegexOptions.CultureInvariant);

  private static async Task<string> ReadBoundedAsync(StreamReader reader, CancellationToken cancellationToken)
  {
    var text = new StringBuilder();
    var buffer = new char[1024];
    int count;
    while ((count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false)) != 0)
    {
      if (text.Length + count > 16384) throw new IOException("phase_d_preparation_output_invalid");
      text.Append(buffer, 0, count);
    }
    return text.ToString();
  }
}
