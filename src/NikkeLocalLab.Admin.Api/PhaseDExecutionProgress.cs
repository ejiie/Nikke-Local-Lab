using System.Text.Json;

namespace NikkeLocalLab.Admin.Api;

public sealed record PhaseDProgressEvent(string StageCode, DateTimeOffset OccurredAtUtc,
    DateTimeOffset ObservedAtUtc, double CumulativeMilliseconds, double IntervalMilliseconds);
public sealed record PhaseDProgress(string ContractId, string LaunchContextUid, DateTimeOffset RequestReceivedAtUtc,
    string StageCode, DateTimeOffset UpdatedAtUtc, IReadOnlyList<PhaseDProgressEvent> Events);

// Display and timing only. This document never authorizes another launch or cleanup.
internal static class PhaseDExecutionProgress
{
  internal const string Contract = "nll/phase-d-execution-progress/v1";
  private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
  internal static readonly string[] Stages = ["api_preparation",
    "account_snapshot",
    "coordinator_preparation",
    "fx_stage",
    "runtime_preparation",
    "fx_apply",
    "server_start",
    "server_created",
    "resource_check",
    "game_start",
    "game_spawned",
    "health_observation",
    "running",
    "game_exited",
    "runtime_stopping",
    "fx_restore",
    "runtime_restore",
    "database_restart",
    "progress_save",
    "finalizing",
    "ready",
    "recovery_required"];

  internal static PhaseDProgress Initial(string uid, DateTimeOffset received, DateTimeOffset preparation,
      DateTimeOffset snapshot, DateTimeOffset prepared)
  {
    var events = new List<PhaseDProgressEvent>();
    var previous = received;
    foreach (var (code, at) in new[] { ("api_preparation", preparation), ("account_snapshot", snapshot), ("coordinator_preparation", prepared) })
    {
      events.Add(new(code, at, at, Math.Max(0, (at - received).TotalMilliseconds), Math.Max(0, (at - previous).TotalMilliseconds)));
      previous = at;
    }
    return new(Contract, uid, received, "coordinator_preparation", prepared, events);
  }

  internal static async Task<PhaseDProgress?> ReadAsync(string root, CancellationToken token)
  {
    var path = Path.Combine(root, "execution-progress.json");
    if (!File.Exists(path)) return null; // Older sealed runners have no progress contract.
    try
    {
      await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
      if (file.Length is <= 0 or > 131072) throw new InvalidDataException();
      var value = await JsonSerializer.DeserializeAsync<PhaseDProgress>(file, Json, token).ConfigureAwait(false);
      if (value is null || value.ContractId != Contract || value.LaunchContextUid != Path.GetFileName(root) ||
          !Stages.Contains(value.StageCode) || value.Events is not { Count: > 0 and <= 128 } ||
          value.Events.Any(e => e is null || !Stages.Contains(e.StageCode) ||
              !double.IsFinite(e.CumulativeMilliseconds) || e.CumulativeMilliseconds < 0 ||
              !double.IsFinite(e.IntervalMilliseconds) || e.IntervalMilliseconds < 0 ||
              e.OccurredAtUtc < value.RequestReceivedAtUtc || e.ObservedAtUtc < e.OccurredAtUtc) ||
          value.StageCode != value.Events.MaxBy(e => Array.IndexOf(Stages, e.StageCode))!.StageCode)
        throw new InvalidDataException();
      return value;
    }
    catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or ArgumentException or NullReferenceException)
    {
      // A bad display record must not change the admission state or break GET.
      return new(Contract, Path.GetFileName(root), DateTimeOffset.MinValue, "status_unknown", DateTimeOffset.UtcNow, []);
    }
  }
}
