using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.PhaseD;

internal sealed record NativeFxStoreIdentity(string VolumeId, string FileId, long Length);
internal sealed record NativeFxBaseline(string InstallationId, string Version,
    NativeFxStoreIdentity Store, string OriginalSha256);
internal sealed record NativeFxRange(long Offset, byte[] Before, byte[] After,
    string BeforeSha256, string AfterSha256);
internal sealed record NativeFxRangePlan(string ContractId, Guid ExecutionUid, NativeFxBaseline Baseline,
    string ProfileSha256, string RecipeSha256, string CandidateSealSha256, NativeFxRange[] Ranges);
internal sealed record NativeFxRangeReceipt(string ContractId, Guid ExecutionUid, string PlanSha256,
    string State, string ValidationScope, long SelectedBytes, long BytesRead, long BytesWritten);
internal sealed record NativeFxRangeResult(NativeFxRangeReceipt Receipt, bool Historical);
internal sealed record NativeFxActive(NativeFxRangePlan Plan, string PlanSha256, string State);
internal sealed record NativeFxLedger(string ContractId, NativeFxBaseline Baseline, NativeFxActive? Active,
    Dictionary<Guid, NativeFxRangeReceipt> Completed);

// The caller supplies an exclusive, admitted physical file handle, its identity
// measured from that SAME handle, and the existing cold/Job/manifest checks.
// No handle survives this small transaction. This is not a launch permission.
internal sealed class NativeFxStoreAccess(Stream stream, NativeFxStoreIdentity identity) : IDisposable
{
  internal Stream Stream { get; } = stream;
  internal NativeFxStoreIdentity Identity { get; } = identity;
  public void Dispose() => Stream.Dispose();
}

internal static class NativeFxRangeTransaction
{
  internal const string Contract = "nll/common-native-fx-execution/v2";
  internal const string ReceiptContract = "nll/common-native-fx-range-receipt/v2";
  internal const string LedgerContract = "nll/common-native-fx-range-ledger/v2";

  // This reserves the common store slot and durably saves rollback bytes without
  // opening or reading the CDB. Only a verified installation can initialize it.
  internal static void Prepare(NativeFxRangeJournal journal, NativeFxRangePlan input, bool allowCompleted = false)
  {
    var plan = Snapshot(input);
    var hash = Digest(plan);
    using var lease = journal.Acquire();
    var ledger = lease.Read();
    ValidateLedger(ledger, plan.Baseline);
    if (ledger.Completed.TryGetValue(plan.ExecutionUid, out var completed))
    {
      Require(allowCompleted && completed.PlanSha256 == hash, "retired_execution");
      return;
    }
    if (ledger.Active is { } active)
    {
      Require(active.Plan.ExecutionUid == plan.ExecutionUid && active.PlanSha256 == hash, "store_owned");
      return;
    }
    lease.Save(ledger with { Active = new(plan, hash, "prepared") }, "prepared");
  }

  internal static NativeFxRangeResult Execute(NativeFxRangeJournal journal, NativeFxRangePlan input,
      bool restore, Func<NativeFxStoreAccess> openStore, Action? verifyBeforeCommit = null)
  {
    var plan = Snapshot(input);
    var hash = Digest(plan);
    using var lease = journal.Acquire();
    var ledger = lease.Read();
    ValidateLedger(ledger, plan.Baseline);
    // A late cleanup must not even open a store now owned by another execution.
    if (ledger.Completed.TryGetValue(plan.ExecutionUid, out var completed))
    {
      Require(restore && completed.PlanSha256 == hash, "retired_execution");
      return new(completed, Historical: true);
    }
    var active = ledger.Active;
    Require(active is not null && active.Plan.ExecutionUid == plan.ExecutionUid &&
        active.PlanSha256 == hash, "store_owned_or_unprepared");
    using var access = openStore();
    var stream = access.Stream;
    Require(access.Identity == plan.Baseline.Store && stream.CanRead && stream.CanSeek &&
        stream.Length == plan.Baseline.Store.Length, "store_identity");
    var originals = true;
    var targets = true;
    long bytesRead = 0, bytesWritten = 0;
    var needsWrite = new bool[plan.Ranges.Length];
    // Validate ALL selected bytes before publishing intent or writing anything.
    for (var r = 0; r < plan.Ranges.Length; r++)
    {
      var range = plan.Ranges[r];
      var bytes = Read(stream, range);
      bytesRead += bytes.Length;
      var before = bytes.AsSpan().SequenceEqual(range.Before);
      var after = bytes.AsSpan().SequenceEqual(range.After);
      originals &= before;
      targets &= after;
      if (active!.State == "prepared") Require(before, "prepared_bytes");
      else if (active.State == "applied") Require(after, "applied_bytes");
      else
        for (var i = 0; i < bytes.Length; i++)
          Require(bytes[i] == range.Before[i] || bytes[i] == range.After[i], "unknown_byte");
      needsWrite[r] = restore ? !before : !after;
    }
    var desired = restore ? originals : targets;
    Require(desired || stream.CanWrite, "store_not_writable");
    var intent = restore ? "restoring" : "applying";
    verifyBeforeCommit?.Invoke();
    // Persist all rollback inputs and the direction BEFORE the first write.
    // Even a no-write transition is durable before its completion is published.
    ledger = ledger with { Active = active! with { State = intent } };
    lease.Save(ledger, intent);
    if (!desired)
    {
      for (var r = 0; r < plan.Ranges.Length; r++)
      {
        if (!needsWrite[r]) continue;
        var range = plan.Ranges[r];
        stream.Position = range.Offset;
        stream.Write(restore ? range.Before : range.After);
        bytesWritten += range.Before.Length;
      }
    }
    // Flush even when a retry finds all desired bytes: a preceding write may
    // have failed after its last byte but before flushing to disk.
    if (stream is FileStream file) file.Flush(flushToDisk: true); else stream.Flush();
    if (!desired)
      foreach (var range in plan.Ranges)
      {
        var bytes = Read(stream, range);
        bytesRead += bytes.Length;
        Require(bytes.AsSpan().SequenceEqual(restore ? range.Before : range.After), "readback");
      }
    var state = restore ? "restored" : "applied";
    verifyBeforeCommit?.Invoke();
    var receipt = new NativeFxRangeReceipt(ReceiptContract, plan.ExecutionUid, hash, state,
        "patched_ranges", plan.Ranges.Sum(x => (long)x.Before.Length), bytesRead, bytesWritten);
    if (restore)
    {
      // One atomic publication both preserves the old completion and frees the
      // slot; no two-file window can lose ownership while rollback is unfinished.
      ledger.Completed.Add(plan.ExecutionUid, receipt);
      ledger = ledger with { Active = null };
    }
    else ledger = ledger with { Active = active! with { State = state } };
    lease.Save(ledger, state);
    return new(receipt, Historical: false);
  }

  private static byte[] Read(Stream stream, NativeFxRange range)
  {
    var bytes = new byte[range.Before.Length];
    stream.Position = range.Offset;
    stream.ReadExactly(bytes);
    return bytes;
  }

  internal static NativeFxRangePlan Snapshot(NativeFxRangePlan plan)
  {
    Require(plan is not null && plan.ContractId == Contract && plan.ExecutionUid != Guid.Empty &&
        IsHash(plan.ProfileSha256) && IsHash(plan.RecipeSha256) && IsHash(plan.CandidateSealSha256), "plan");
    ValidateBaseline(plan!.Baseline);
    Require(plan.Ranges is { Length: > 0 and <= 32 }, "ranges");
    long end = 256, total = 0;
    var ranges = new List<NativeFxRange>();
    foreach (var range in plan.Ranges!)
    {
      Require(range is not null && range.Before is { Length: > 0 and <= 16777216 } &&
          range.After is not null && range.After.Length == range.Before.Length &&
          range.Offset >= end && range.Offset <= plan.Baseline.Store.Length - range.Before.Length,
          "range_bounds");
      var copy = range! with { Before = (byte[])range.Before.Clone(), After = (byte[])range.After.Clone() };
      Require(IsHash(copy.BeforeSha256) && IsHash(copy.AfterSha256) &&
          Hex(copy.Before) == copy.BeforeSha256 && Hex(copy.After) == copy.AfterSha256 &&
          !copy.Before.AsSpan().SequenceEqual(copy.After), "range_hash");
      end = copy.Offset + copy.Before.Length;
      total += copy.Before.Length;
      ranges.Add(copy);
    }
    Require(total <= 67108864, "range_budget");
    return plan with { Ranges = ranges.ToArray() };
  }

  internal static void ValidateBaseline(NativeFxBaseline baseline)
  {
    Require(baseline is not null && !string.IsNullOrWhiteSpace(baseline.InstallationId) &&
        !string.IsNullOrWhiteSpace(baseline.Version) && IsHash(baseline.OriginalSha256) &&
        baseline.Store is not null && baseline.Store.Length > 256 &&
        !string.IsNullOrWhiteSpace(baseline.Store.VolumeId) && !string.IsNullOrWhiteSpace(baseline.Store.FileId), "baseline");
  }

  private static void ValidateLedger(NativeFxLedger ledger, NativeFxBaseline baseline)
  {
    Require(ledger.ContractId == LedgerContract && ledger.Baseline == baseline && ledger.Completed is not null, "ledger");
    if (ledger.Active is { } active)
    {
      Require(active.Plan is not null && active.Plan.Baseline == baseline &&
          Digest(Snapshot(active.Plan)) == active.PlanSha256 &&
          active.State is "prepared" or "applying" or "applied" or "restoring" &&
          !ledger.Completed!.ContainsKey(active.Plan.ExecutionUid), "active_record");
    }
    foreach (var (uid, receipt) in ledger.Completed!)
      Require(uid != Guid.Empty && receipt is not null && receipt.ExecutionUid == uid &&
          receipt.ContractId == ReceiptContract && receipt.State == "restored" &&
          receipt.ValidationScope == "patched_ranges" && IsHash(receipt.PlanSha256) &&
          receipt.SelectedBytes is > 0 and <= 67108864 && receipt.BytesRead >= receipt.SelectedBytes &&
          receipt.BytesRead <= 2 * receipt.SelectedBytes && receipt.BytesWritten >= 0 &&
          receipt.BytesWritten <= receipt.SelectedBytes, "completed_record");
  }

  internal static string Digest(NativeFxRangePlan plan) => Hex(JsonSerializer.SerializeToUtf8Bytes(plan));
  internal static string Hex(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
  private static bool IsHash(string? value) => value is { Length: 64 } && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
  internal static void Require([DoesNotReturnIf(false)] bool ok, string code)
  {
    if (!ok) throw new InvalidOperationException("native_fx_range_" + code);
  }
}
