using System.Diagnostics;
using System.Text.Json;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.Admin.Api;

public sealed record AccountConnectionRequest(int Area, EntityUid ExpectedProfileRevisionUid);
public sealed record AccountServerChoice(int Area, string Label, int CharacterCount);

public sealed class AccountConnectionService(IProfileManagementService profiles, AccountDirectoryStore directory,
    AccountImportOptions options)
{
  private readonly SemaphoreSlim _gate = new(1, 1);
  private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
  private string Root(EntityUid account) => Path.Combine(options.RuntimeRoot, "AccountConnections", account.ToString());

  public async Task<object> ConnectAsync(EntityUid account, CancellationToken token)
  {
    _ = await profiles.GetAccountWorkspaceAsync(account, token).ConfigureAwait(false) ??
        throw new ApiRequestException(404, "account_not_found");
    await _gate.WaitAsync(token).ConfigureAwait(false);
    try
    {
      var root = Root(account);
      Directory.CreateDirectory(root);
      var result = Path.Combine(root, "choices.json");
      await RunCollectorAsync(["connect", "--root", root, "--result", result], token).ConfigureAwait(false);
      using var document = JsonDocument.Parse(await File.ReadAllTextAsync(result, token).ConfigureAwait(false));
      var choices = document.RootElement.GetProperty("choices").Deserialize<AccountServerChoice[]>(Json);
      return new { Choices = choices };
    }
    finally { _gate.Release(); }
  }

  public async Task<AccountImportProjection> ImportAsync(EntityUid account, AccountConnectionRequest request, CancellationToken token)
  {
    await _gate.WaitAsync(token).ConfigureAwait(false);
    try
    {
      var workspace = await profiles.GetAccountWorkspaceAsync(account, token).ConfigureAwait(false);
      if (workspace?.BaseRevisions.ProfileRevisionUid != request.ExpectedProfileRevisionUid)
        throw new ApiRequestException(409, "account_import_revision_changed");
      var root = Root(account);
      var result = Path.Combine(root, "presentation.private.json");
      // Keep the read-only sanitizer's raw input outside the repository and runtime tree.
      var raw = Path.Combine(Path.GetDirectoryName(options.RawFetchPath)!, $"nll-connection-{account}.json");
      await RunCollectorAsync(["collect",
        "--root",
        root,
        "--result",
        result,
        "--raw",
        raw,
        "--area",
        request.Area.ToString(System.Globalization.CultureInfo.InvariantCulture)], token).ConfigureAwait(false);
      using var document = JsonDocument.Parse(await File.ReadAllTextAsync(result, token).ConfigureAwait(false));
      var meta = document.RootElement;
      string? Optional(string field) => meta.TryGetProperty(field, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
      var status = meta.GetProperty("status").GetString()!;
      var portrait = CopyArt(meta.GetProperty("portrait").GetString()!, account, "portrait");
      var emblem = Optional("emblem") is { } art ? CopyArt(art, account, "emblem") : null;
      var frame = Optional("frame") is { } frameArt ? CopyArt(frameArt, account, "frame") : null;
      var presentation = new ImportedDirectoryPresentation(status, Optional("name"),
          meta.TryGetProperty("level", out var level) ? level.GetInt32() : null, Optional("fingerprint"), portrait, emblem, frame);
      var importer = new FilesystemAccountImportService(profiles, options with { RawFetchPath = raw });
      var imported = await importer.ImportPreparedAsync(new("", account, request.ExpectedProfileRevisionUid), CancellationToken.None)
          .ConfigureAwait(false);
      await directory.ApplyImportedAsync(account, presentation, CancellationToken.None).ConfigureAwait(false);
      return imported;
    }
    finally { _gate.Release(); }
  }

  private string CopyArt(string source, EntityUid account, string kind)
  {
    var full = Path.GetFullPath(source);
    var allowed = Path.GetFullPath(Path.Combine(options.RuntimeRoot, "AccountConnections")) + Path.DirectorySeparatorChar;
    if (!full.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) || !File.Exists(full) ||
        new FileInfo(full).Length is < 8 or > 16777216 || (File.GetAttributes(full) & FileAttributes.ReparsePoint) != 0)
      throw new ApiRequestException(422, "account_art_invalid");
    var bytes = File.ReadAllBytes(full);
    if (!bytes.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
      throw new ApiRequestException(422, "account_art_invalid");
    var artRoot = Path.Combine(options.RuntimeRoot, "AccountArtwork"); Directory.CreateDirectory(artRoot);
    var digest = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();
    var leaf = $"{account}-{kind}-{digest}.png";
    File.WriteAllBytes(Path.Combine(artRoot, leaf), bytes);
    return $"/admin-api/v1/account-art/{leaf}";
  }

  public IResult Artwork(string name)
  {
    if (!System.Text.RegularExpressions.Regex.IsMatch(name,
        "^[a-f0-9-]{36}-(portrait|emblem|frame)-[a-f0-9]{64}\\.png$")) return Results.NotFound();
    var file = Path.Combine(options.RuntimeRoot, "AccountArtwork", name);
    return File.Exists(file) ? Results.File(file, "image/png") : Results.NotFound();
  }

  private async Task RunCollectorAsync(string[] arguments, CancellationToken token)
  {
    var python = Environment.GetEnvironmentVariable("NLL_ACCOUNT_PYTHON") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "NLL-Imported-Samsung", ".venv", "Scripts", "python.exe");
    var script = Path.Combine(options.RepositoryRoot, "tools", "AccountCollector", "nll.py");
    using var process = new Process
    {
      StartInfo = new(python)
      {
        UseShellExecute = false,
        CreateNoWindow = true,
        RedirectStandardOutput = true,
        RedirectStandardError = true
      }
    };
    process.StartInfo.ArgumentList.Add(script);
    foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
    if (!process.Start()) throw new ApiRequestException(503, "account_collector_start_failed");
    var output = process.StandardOutput.ReadToEndAsync(token);
    var error = process.StandardError.ReadToEndAsync(token);
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
    timeout.CancelAfter(TimeSpan.FromMinutes(12));
    try { await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false); }
    catch (OperationCanceledException)
    {
      if (!process.HasExited) process.Kill(entireProcessTree: true);
      throw new ApiRequestException(408, "account_collection_cancelled");
    }
    var result = await output.ConfigureAwait(false); _ = await error.ConfigureAwait(false);
    if (process.ExitCode != 0)
    {
      var code = result.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
      throw new ApiRequestException(422, code is "reauth_required" or "account_changed_during_import" or
          "union_area_mismatch" or "account_portrait_missing" or "union_emblem_missing" or "login_closed" or "login_timeout"
          ? code : "account_collection_failed");
    }
  }
}

public static class AccountConnectionEndpoints
{
  public static IEndpointRouteBuilder MapAccountConnectionEndpoints(this IEndpointRouteBuilder endpoints)
  {
    AccountConnectionService Require(IServiceProvider provider) => provider.GetService<AccountConnectionService>() ??
        throw new ApiRequestException(503, "account_connection_unavailable");
    endpoints.MapPost("/admin-api/v1/accounts/{accountUid:guid}/connection", async (Guid accountUid,
        IServiceProvider provider, CancellationToken token) => Results.Json(await Require(provider)
          .ConnectAsync(new(accountUid), token).ConfigureAwait(false)));
    endpoints.MapPost("/admin-api/v1/accounts/{accountUid:guid}/synchronize", async (Guid accountUid,
        AccountConnectionRequest request, IServiceProvider provider, CancellationToken token) => Results.Json(await Require(provider)
          .ImportAsync(new(accountUid), request, token).ConfigureAwait(false)));
    endpoints.MapGet("/admin-api/v1/account-art/{name}", (string name, IServiceProvider provider) => Require(provider).Artwork(name));
    return endpoints;
  }
}
