using System.Diagnostics;
using System.Globalization;
using System.Text;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Admin.Api;

public sealed record AccountImportRequest(string Uid);

public sealed record AccountImportProjection(
    int SchemaVersion,
    string ContractId,
    EntityUid AccountUid,
    string AccountLabel,
    string DisplayName,
    int CommanderLevel,
    int CharacterCount,
    DateTimeOffset CompletedAtUtc,
    string StatusCode);

public sealed record AccountImportOptions(
    string RepositoryRoot,
    string ConfigurationPath,
    string FetchScriptPath,
    string ImportCliPath,
    string DotnetPath,
    string PowerShellPath,
    string RawFetchPath,
    string RuntimeRoot);

public sealed class AccountImportException : Exception
{
  public AccountImportException(string code) : base(code)
  {
  }
}

public interface IAccountImportService
{
  Task<AccountImportProjection> ImportAsync(
      AccountImportRequest request,
      CancellationToken cancellationToken = default);
}

public sealed class UnavailableAccountImportService : IAccountImportService
{
  public Task<AccountImportProjection> ImportAsync(
      AccountImportRequest request,
      CancellationToken cancellationToken = default) =>
      throw new AccountImportException("account_import_not_configured");
}

public sealed class FilesystemAccountImportService : IAccountImportService
{
  private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'";
  private static readonly IReadOnlyList<string> FullProfileScope = ["full_profile"];
  private readonly IProfileManagementService _profiles;
  private readonly AccountImportOptions _options;
  private readonly SemaphoreSlim _gate = new(1, 1);

  public FilesystemAccountImportService(
      IProfileManagementService profiles,
      AccountImportOptions options)
  {
    _profiles = profiles;
    _options = options;
  }

  public async Task<AccountImportProjection> ImportAsync(
      AccountImportRequest request,
      CancellationToken cancellationToken = default)
  {
    if (request is null || string.IsNullOrWhiteSpace(request.Uid) ||
        request.Uid.Length is < 4 or > 32 || request.Uid.Any(static value => !char.IsAsciiDigit(value)))
    {
      throw new AccountImportException("account_import_uid_invalid");
    }

    // Import is an optional operator action. Validate its external collector
    // dependencies at the moment it is requested so a missing Playwright/CLI
    // component cannot prevent the rest of Control Center from starting.
    RequireDirectory(_options.RepositoryRoot, "account_import_repository_missing");
    RequireDirectory(_options.RuntimeRoot, "account_import_runtime_root_missing");
    foreach (var (path, code) in new[]
    {
      (_options.ConfigurationPath, "account_import_configuration_missing"),
      (_options.FetchScriptPath, "account_import_fetch_script_missing"),
      (_options.ImportCliPath, "account_import_cli_missing"),
      (_options.DotnetPath, "account_import_dotnet_missing"),
      (_options.PowerShellPath, "account_import_powershell_missing")
    })
    {
      RequireFile(path, code);
    }

    await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
    try
    {
      var operationUid = EntityUid.New();
      var snapshotUid = EntityUid.New();
      var workRoot = Path.Combine(_options.RuntimeRoot, "AccountImports", operationUid.ToString());
      Directory.CreateDirectory(workRoot);
      var draftPath = Path.Combine(workRoot, "sanitized-profile.draft.json");
      var rawBefore = File.Exists(_options.RawFetchPath)
          ? File.GetLastWriteTimeUtc(_options.RawFetchPath)
          : DateTime.MinValue;

      await RunAsync(
          _options.PowerShellPath,
          [
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            _options.FetchScriptPath,
            "-Uid",
            request.Uid
          ],
          environment: null,
          "account_import_fetch_failed").ConfigureAwait(false);

      if (!File.Exists(_options.RawFetchPath) ||
          File.GetLastWriteTimeUtc(_options.RawFetchPath) <= rawBefore)
      {
        throw new AccountImportException("account_import_fresh_raw_missing");
      }

      var capturedAt = DateTimeOffset.UtcNow;
      capturedAt = new DateTimeOffset(capturedAt.UtcTicks - capturedAt.UtcTicks % 10, TimeSpan.Zero);
      var capturedAtText = capturedAt.ToString(TimestampFormat, CultureInfo.InvariantCulture);
      var importOutput = await RunAsync(
          _options.DotnetPath,
          [
            _options.ImportCliPath,
            "profile-draft-import",
            "--config",
            _options.ConfigurationPath,
            "--repository-root",
            _options.RepositoryRoot,
            "--level-authority",
            "roster_observation/v1",
            "--operation-uid",
            operationUid.ToString(),
            "--imported-at-utc",
            capturedAtText,
            "--output-draft",
            draftPath
          ],
          new Dictionary<string, string?> { ["NIKKE_LAB_PROFILE_RAW"] = _options.RawFetchPath },
          "account_import_draft_materialization_failed").ConfigureAwait(false);
      var draftUid = ParseOutputUid(importOutput, "draft_uid", "account_import_draft_uid_missing");

      await RunAsync(
          _options.DotnetPath,
          [
            _options.ImportCliPath,
            "fetched-account-snapshot-materialize",
            "--config",
            _options.ConfigurationPath,
            "--repository-root",
            _options.RepositoryRoot,
            "--sanitized-draft",
            draftPath,
            "--snapshot-uid",
            snapshotUid.ToString(),
            "--captured-at-utc",
            capturedAtText
          ],
          new Dictionary<string, string?> { ["NIKKE_LAB_PROFILE_RAW"] = _options.RawFetchPath },
          "account_import_snapshot_materialization_failed").ConfigureAwait(false);

      var snapshotPath = Path.Combine(
          _options.RuntimeRoot,
          "FetchedAccountSnapshots",
          snapshotUid.ToString(),
          "fetched-account.snapshot.json");
      RequireFile(draftPath, "account_import_draft_output_missing");
      RequireFile(snapshotPath, "account_import_snapshot_output_missing");
      var canonicalDraft = await File.ReadAllTextAsync(draftPath).ConfigureAwait(false);
      var canonicalSnapshot = await File.ReadAllTextAsync(snapshotPath).ConfigureAwait(false);

      var draft = await _profiles.GetImportDraftAsync(draftUid, CancellationToken.None)
          .ConfigureAwait(false) ??
          throw new AccountImportException("account_import_draft_not_registered");
      var previewOperationUid = EntityUid.New();
      var preview = await _profiles.PreviewCreateFromImportAsync(
          new CreateImportDiffCommand(
              previewOperationUid,
              draft.DraftUid,
              draft.DraftSha256,
              "roster_observation/v1",
              FullProfileScope),
          CancellationToken.None).ConfigureAwait(false);
      if (preview.Issues.Any(static issue => issue.Severity == "error"))
      {
        throw new AccountImportException("account_import_profile_not_materializable");
      }

      var created = await _profiles.CreateFromImportAsync(
          new CreateFromImportCommand(
              previewOperationUid,
              draft.DraftUid,
              draft.DraftSha256,
              preview.DiffSha256,
              "roster_observation/v1",
              FullProfileScope),
          CancellationToken.None).ConfigureAwait(false);
      var registered = await _profiles.RegisterFetchedAccountSnapshotAsync(
          new RegisterFetchedAccountSnapshotCommand(
              created.AccountUid,
              created.ProfileRevision.RevisionUid,
              canonicalSnapshot,
              canonicalDraft),
          CancellationToken.None).ConfigureAwait(false);

      var displayName = string.IsNullOrWhiteSpace(registered.DisplayName)
          ? "가져온 계정"
          : registered.DisplayName;
      var accounts = await _profiles.ListAccountsAsync(CancellationToken.None).ConfigureAwait(false);
      var createdSummary = accounts.Single(item => item.AccountUid == created.AccountUid);
      var accountLabel = UniqueAccountLabel(displayName, accounts, created.AccountUid);
      if (!string.Equals(createdSummary.AccountLabel, accountLabel, StringComparison.Ordinal))
      {
        createdSummary = await _profiles.RenameAccountAsync(
            new RenameAccountCommand(
                created.AccountUid,
                createdSummary.AccountLabel,
                accountLabel),
            CancellationToken.None).ConfigureAwait(false);
      }

      var featureManifest = await _profiles.GetFeatureManifestAsync(CancellationToken.None)
          .ConfigureAwait(false);
      await _profiles.InitializeLocalStateAsync(
          new InitializeLocalStateCommand(
              EntityUid.New(),
              created.AccountUid,
              created.ProfileRevision.RevisionUid,
              featureManifest.ManifestUid,
              featureManifest.ContentSha256,
              displayName,
              registered.CommanderLevel ?? 1,
              null,
              null,
              null,
              null,
              [new WalletBalanceProjection("jewel", 0), new WalletBalanceProjection("credit", 0)]),
          CancellationToken.None).ConfigureAwait(false);

      return new AccountImportProjection(
          1,
          "nll/control-center-account-import/v1",
          created.AccountUid,
          createdSummary.AccountLabel,
          displayName,
          registered.CommanderLevel ?? 1,
          registered.CharacterDetailCount,
          DateTimeOffset.UtcNow,
          "completed");
    }
    finally
    {
      _gate.Release();
    }
  }

  private static string UniqueAccountLabel(
      string displayName,
      IReadOnlyList<AccountSummaryProjection> accounts,
      EntityUid currentUid)
  {
    var occupied = accounts
        .Where(item => item.AccountUid != currentUid)
        .Select(static item => item.AccountLabel)
        .ToHashSet(StringComparer.Ordinal);
    if (!occupied.Contains(displayName)) return displayName;
    for (var suffix = 2; suffix < 1000; suffix++)
    {
      var candidate = $"{displayName} ({suffix})";
      if (!occupied.Contains(candidate)) return candidate;
    }
    throw new AccountImportException("account_import_label_space_exhausted");
  }

  private static EntityUid ParseOutputUid(string output, string name, string failureCode)
  {
    var prefix = name + "=";
    var text = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)
        .SingleOrDefault(line => line.StartsWith(prefix, StringComparison.Ordinal));
    if (text is null || !Guid.TryParseExact(text[prefix.Length..], "D", out var guid) ||
        guid == Guid.Empty)
    {
      throw new AccountImportException(failureCode);
    }
    return new EntityUid(guid);
  }

  private static async Task<string> RunAsync(
      string fileName,
      IReadOnlyList<string> arguments,
      IReadOnlyDictionary<string, string?>? environment,
      string failureCode)
  {
    using var process = new Process
    {
      StartInfo = new ProcessStartInfo
      {
        FileName = fileName,
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        StandardOutputEncoding = Encoding.UTF8,
        StandardErrorEncoding = Encoding.UTF8
      }
    };
    foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
    if (environment is not null)
    {
      foreach (var pair in environment) process.StartInfo.Environment[pair.Key] = pair.Value;
    }
    if (!process.Start()) throw new AccountImportException(failureCode);
    var stdoutTask = process.StandardOutput.ReadToEndAsync();
    var stderrTask = process.StandardError.ReadToEndAsync();
    await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
    var stdout = await stdoutTask.ConfigureAwait(false);
    _ = await stderrTask.ConfigureAwait(false);
    if (process.ExitCode != 0) throw new AccountImportException(failureCode);
    return stdout;
  }

  private static void RequireFile(string path, string code)
  {
    if (!Path.IsPathFullyQualified(path) || !File.Exists(path)) throw new AccountImportException(code);
  }

  private static void RequireDirectory(string path, string code)
  {
    if (!Path.IsPathFullyQualified(path) || !Directory.Exists(path)) throw new AccountImportException(code);
  }
}
