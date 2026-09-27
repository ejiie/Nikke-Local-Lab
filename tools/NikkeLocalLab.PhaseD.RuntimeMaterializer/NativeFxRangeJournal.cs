using System.Text.Json;
using static NikkeLocalLab.PhaseD.NativeFxRangeTransaction;

namespace NikkeLocalLab.PhaseD;

// One admitted path per physical store, selected by the installation/coordinator,
// never by an execution UID. The existing path/ACL policy belongs to the caller.
// Keep the lock file in place: deleting/recreating it could split lock ownership.
internal sealed class NativeFxRangeJournal(string path, Action<string>? checkpoint = null)
{
  internal void RegisterVerifiedBaseline(NativeFxBaseline baseline)
  {
    ValidateBaseline(baseline);
    using var lease = Acquire();
    // Installation only. A missing/corrupt journal in Execute is NOT an empty slot.
    using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    JsonSerializer.Serialize(file, new NativeFxLedger(LedgerContract, baseline, null, new()));
    file.Flush(flushToDisk: true);
  }

  internal Lease Acquire() => new(path, checkpoint);

  internal sealed class Lease : IDisposable
  {
    private readonly string path;
    private readonly Action<string>? checkpoint;
    private readonly FileStream storeLock;

    internal Lease(string path, Action<string>? checkpoint)
    {
      this.path = path;
      this.checkpoint = checkpoint;
      storeLock = new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    internal NativeFxLedger Read()
    {
      using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
      return JsonSerializer.Deserialize<NativeFxLedger>(file) ?? throw new InvalidOperationException("native_fx_range_empty_ledger");
    }

    internal void Save(NativeFxLedger ledger, string state)
    {
      var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
      try
      {
        using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
            4096, FileOptions.WriteThrough))
        {
          JsonSerializer.Serialize(file, ledger);
          file.Flush(flushToDisk: true);
        }
        checkpoint?.Invoke("before:" + state);
        // Same-directory replacement: readers get the previous complete state
        // or the new complete state, including rollback bytes and completion.
        File.Move(temporary, path, overwrite: true);
        checkpoint?.Invoke("after:" + state);
      }
      finally
      {
        if (File.Exists(temporary)) File.Delete(temporary);
      }
    }

    public void Dispose() => storeLock.Dispose();
  }
}
