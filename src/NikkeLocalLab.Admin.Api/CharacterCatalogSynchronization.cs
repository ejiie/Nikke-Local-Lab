using System.Text;
using System.Text.Json;
using Nll.PhaseD;
using static NikkeLocalLab.Admin.Api.FilesystemBossSeasonCatalogService;

namespace NikkeLocalLab.Admin.Api;

public sealed record CharacterCatalogSyncToolPin(string Path, string Sha256);
public sealed record CharacterCatalogSyncOptions(string Root, string ScriptPath, string ScriptSha256,
    string MaterializerPath, string ImporterPath, string GameConfigArchivePath, string PresentationPath,
    CharacterCatalogSyncToolPin[] ToolPins);
public sealed record CharacterCatalogSyncResult(string StatusCode, int AddedCharacterCount = 0,
    int MissingPortraitCount = 0, string? FailureCode = null);
public interface ICharacterCatalogSynchronizer
{
  Task<CharacterCatalogSyncResult> SynchronizeAsync(CancellationToken token);
}

public sealed class CharacterCatalogSynchronization(CharacterCatalogSyncOptions options,
    string configurationPath, string configurationSha256, string powerShellPath, string powerShellSha256)
    : ICharacterCatalogSynchronizer
{
  private readonly SemaphoreSlim gate = new(1, 1);
  public async Task<CharacterCatalogSyncResult> SynchronizeAsync(CancellationToken token)
  {
    if (!await gate.WaitAsync(0, token).ConfigureAwait(false)) return new("busy");
    try
    {
      foreach (var (path, hash, limit) in new[] { (options.ScriptPath, options.ScriptSha256, 1048576),
          (configurationPath, configurationSha256, 1048576), (powerShellPath, powerShellSha256, 10485760) })
        Require(IsHash(hash) && Hash(ReadFile(path, limit)) == hash);
      var output = Plain(Path.Combine(options.Root, "runs", Guid.NewGuid().ToString("N")));
      Directory.CreateDirectory(output);
      string Q(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
      var command = "$ErrorActionPreference='Stop'; try { & " + Q(options.ScriptPath) +
          " -ConfigurationPath " + Q(configurationPath) + " -ExpectedConfigurationSha256 " + Q(configurationSha256) +
          " -OutputRoot " + Q(output) + " *> $null; exit 0 } catch { [IO.File]::WriteAllText(" +
          Q(Path.Combine(output, "failure-code.txt")) + ",'character_catalog_sync_failed'); exit 1 }";
      using var owner = ExecutionJob.Create("Local\\NLL.CharacterCatalogSync." + Guid.NewGuid().ToString("N"));
      using var child = owner.Start(powerShellPath, "-NoProfile -NonInteractive -EncodedCommand " +
          Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
      using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
      timeout.CancelAfter(TimeSpan.FromMinutes(5));
      try
      {
        await child.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
        if (child.ExitCode != 0) return new("failed", FailureCode: "character_catalog_sync_failed");
        return JsonSerializer.Deserialize<CharacterCatalogSyncResult>(ReadFile(Path.Combine(output, "sync-result.json"), 8192), JsonOptions)
            ?? new("failed", FailureCode: "character_catalog_sync_result_invalid");
      }
      catch (OperationCanceledException) when (!token.IsCancellationRequested)
      { return new("failed", FailureCode: "character_catalog_sync_timeout"); }
      finally { owner.TerminateAndWait(15000); }
    }
    catch (Exception error) when (IsReadFailure(error) || error is System.ComponentModel.Win32Exception)
    { return new("failed", FailureCode: "character_catalog_sync_unavailable"); }
    finally { gate.Release(); }
  }
}
