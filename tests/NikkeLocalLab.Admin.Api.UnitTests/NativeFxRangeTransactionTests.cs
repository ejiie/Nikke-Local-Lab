using NikkeLocalLab.PhaseD;
using Xunit;
using static NikkeLocalLab.PhaseD.NativeFxRangeTransaction;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class NativeFxRangeTransactionTests
{
  [Theory]
  [InlineData(100000L)]
  [InlineData(6574364321L)]
  public void Work_is_bounded_by_selected_bytes_and_completed_cleanup_never_opens_store(long length)
  {
    using var fixture = new Fixture(length, 24153);
    Prepare(fixture.Journal, fixture.Plan);
    Assert.Equal(0, fixture.Stream.ReadCount);
    Assert.Equal(0, fixture.OpenCount);
    var applied = fixture.Run();
    Assert.Equal("patched_ranges", applied.Receipt.ValidationScope);
    Assert.Equal(48306, applied.Receipt.BytesRead);
    Assert.Equal(24153, applied.Receipt.BytesWritten);
    fixture.AssertCounts(applied);
    var repeated = fixture.Run();
    Assert.Equal(24153, repeated.Receipt.BytesRead);
    Assert.Equal(0, repeated.Receipt.BytesWritten);
    fixture.AssertCounts(repeated);
    var restored = fixture.Run(restore: true);
    Assert.Equal(48306, restored.Receipt.BytesRead);
    Assert.Equal(24153, restored.Receipt.BytesWritten);
    fixture.AssertCounts(restored);
    fixture.Stream.AssertOriginal();
    var opens = fixture.OpenCount;
    var late = fixture.Run(restore: true);
    Assert.True(late.Historical);
    Assert.Equal(restored.Receipt, late.Receipt);
    Assert.Equal(opens, fixture.OpenCount);
    Assert.Equal(0, fixture.Stream.ReadCount);
    Assert.Equal(0, fixture.Stream.WriteCount);
  }

  [Fact]
  public void Prepared_cancellation_reads_only_original_ranges_and_writes_nothing()
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    var result = fixture.Run(restore: true);
    Assert.Equal("restored", result.Receipt.State);
    Assert.Equal(12, result.Receipt.BytesRead);
    Assert.Equal(0, result.Receipt.BytesWritten);
    fixture.AssertCounts(result);
    Assert.Throws<InvalidOperationException>(() => fixture.Run());
    Assert.Throws<InvalidOperationException>(() => Prepare(fixture.Journal, fixture.Plan));
  }

  public static IEnumerable<object[]> Interruptions()
  {
    for (var cut = 0; cut <= 12; cut++)
      foreach (var interruptedRestore in new[] { false, true })
        foreach (var resumeRestore in new[] { false, true })
          yield return new object[] { cut, interruptedRestore, resumeRestore };
  }

  [Theory]
  [MemberData(nameof(Interruptions))]
  public void Every_byte_interruption_can_resume_in_either_direction_after_reopening_journal(
      int cut, bool interruptedRestore, bool resumeRestore)
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    if (interruptedRestore) fixture.Run();
    fixture.Stream.FailAfterBytes = cut;
    Assert.Throws<IOException>(() => fixture.Run(interruptedRestore));
    fixture.Stream.FailAfterBytes = null;
    var result = fixture.Run(resumeRestore, new NativeFxRangeJournal(fixture.Path));
    Assert.Equal(resumeRestore ? "restored" : "applied", result.Receipt.State);
    if (resumeRestore) fixture.Stream.AssertOriginal(); else fixture.Stream.AssertTarget();
    Assert.InRange(result.Receipt.BytesRead, 12, 24);
    Assert.InRange(result.Receipt.BytesWritten, 0, 12);
    fixture.AssertCounts(result);
  }

  [Theory]
  [InlineData("before:prepared")]
  [InlineData("after:prepared")]
  [InlineData("before:applying")]
  [InlineData("after:applying")]
  [InlineData("before:applied")]
  [InlineData("after:applied")]
  [InlineData("before:restoring")]
  [InlineData("after:restoring")]
  [InlineData("before:restored")]
  [InlineData("after:restored")]
  public void Publication_failure_preserves_a_complete_recoverable_state(string point)
  {
    using var fixture = new Fixture();
    var faultJournal = new NativeFxRangeJournal(fixture.Path, current =>
    {
      if (current == point) throw new IOException("synthetic_publication_interruption");
    });
    if (point.EndsWith("prepared", StringComparison.Ordinal))
      Assert.Throws<IOException>(() => Prepare(faultJournal, fixture.Plan));
    else
    {
      Prepare(fixture.Journal, fixture.Plan);
      var restoring = point.EndsWith("restoring", StringComparison.Ordinal) ||
          point.EndsWith("restored", StringComparison.Ordinal);
      if (restoring) fixture.Run();
      Assert.Throws<IOException>(() => fixture.Run(restoring, faultJournal));
    }
    if (point.Contains("prepared", StringComparison.Ordinal) || point.Contains("applying", StringComparison.Ordinal))
      Assert.Equal(0, fixture.Stream.WriteCount);
    var restarted = new NativeFxRangeJournal(fixture.Path);
    if (point == "before:prepared") Prepare(restarted, fixture.Plan);
    var result = fixture.Run(restore: true, restarted);
    fixture.Stream.AssertOriginal();
    Assert.Equal("restored", result.Receipt.State);
    Assert.Empty(Directory.GetFiles(fixture.Directory, "*.tmp"));
  }

  [Fact]
  public void Another_execution_cannot_claim_store_and_old_cleanup_cannot_touch_new_execution()
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    fixture.Run();
    var next = fixture.Plan with { ExecutionUid = Guid.NewGuid(), ProfileSha256 = new string('a', 64) };
    var opens = fixture.OpenCount;
    Assert.Throws<InvalidOperationException>(() => Prepare(fixture.Journal, next));
    Assert.Throws<InvalidOperationException>(() => fixture.Run(true, plan: next));
    Assert.Equal(opens, fixture.OpenCount);
    var previous = fixture.Run(true);
    Prepare(fixture.Journal, next);
    fixture.Run(plan: next);
    opens = fixture.OpenCount;
    var late = fixture.Run(true);
    Assert.True(late.Historical);
    Assert.Equal(previous.Receipt, late.Receipt);
    Assert.Equal(opens, fixture.OpenCount);
    fixture.Stream.AssertTarget();
    Assert.Throws<InvalidOperationException>(() => fixture.Run());
    fixture.Run(true, plan: next);
  }

  [Fact]
  public void Concurrent_journal_access_is_rejected_before_opening_store()
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    using var held = fixture.Journal.Acquire();
    Assert.Throws<IOException>(() => Prepare(new NativeFxRangeJournal(fixture.Path), fixture.Plan));
    Assert.Throws<IOException>(() => fixture.Run());
    Assert.Equal(0, fixture.OpenCount);
  }

  [Fact]
  public void Interrupted_record_does_not_authorize_a_third_byte_value()
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    fixture.Stream.FailAfterBytes = 5;
    Assert.Throws<IOException>(() => fixture.Run());
    fixture.Stream.FailAfterBytes = null;
    fixture.Stream.ChangeLastByte(255);
    Assert.Throws<InvalidOperationException>(() => fixture.Run(true));
    Assert.Equal(0, fixture.Stream.WriteCount);
  }

  [Fact]
  public void Unprepared_execution_cannot_open_store()
  {
    using var fixture = new Fixture();
    Assert.Throws<InvalidOperationException>(() => fixture.Run());
    Assert.Equal(0, fixture.OpenCount);
  }

  [Fact]
  public void Small_real_file_roundtrip_uses_exclusive_handles_and_releases_them()
  {
    using var fixture = new Fixture(4096);
    var storePath = System.IO.Path.Combine(fixture.Directory, "synthetic-store.bin");
    var original = Enumerable.Repeat((byte)37, 4096).ToArray();
    foreach (var range in fixture.Plan.Ranges) range.Before.CopyTo(original, (int)range.Offset);
    File.WriteAllBytes(storePath, original);
    var plan = fixture.Plan;
    Prepare(fixture.Journal, plan);
    NativeFxStoreAccess Open()
    {
      var stream = new FileStream(storePath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
      try
      {
        Assert.Throws<IOException>(() => File.OpenRead(storePath));
        return new(stream, fixture.ActualIdentity);
      }
      catch { stream.Dispose(); throw; }
    }
    Execute(fixture.Journal, plan, false, Open);
    var modified = File.ReadAllBytes(storePath);
    foreach (var range in plan.Ranges)
      Assert.Equal(range.After, modified.AsSpan((int)range.Offset, range.After.Length).ToArray());
    modified[100] = 38;
    File.WriteAllBytes(storePath, modified);
    Execute(new NativeFxRangeJournal(fixture.Path), plan, true, Open);
    original[100] = 38;
    Assert.Equal(original, File.ReadAllBytes(storePath));
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void Unknown_byte_in_last_range_refuses_all_writes(bool restoring)
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    if (restoring) fixture.Run();
    fixture.Stream.ChangeLastByte(255);
    Assert.Throws<InvalidOperationException>(() => fixture.Run(restoring));
    Assert.Equal(0, fixture.Stream.WriteCount);
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void Mixed_bytes_without_an_in_progress_record_are_rejected(bool wasApplied)
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    if (wasApplied) fixture.Run();
    fixture.Stream.ChangeLastByte(wasApplied ? fixture.Plan.Ranges[^1].Before[^1] : fixture.Plan.Ranges[^1].After[^1]);
    Assert.Throws<InvalidOperationException>(() => fixture.Run(restore: true));
    Assert.Equal(0, fixture.Stream.WriteCount);
  }

  [Fact]
  public void Outside_range_mutation_is_ignored_and_preserved()
  {
    using var fixture = new Fixture();
    fixture.Stream.OutsideByte = 251;
    Prepare(fixture.Journal, fixture.Plan);
    fixture.Run();
    fixture.Stream.OutsideByte = 252;
    fixture.Run(true);
    Assert.Equal(252, fixture.Stream.OutsideByte);
    fixture.Stream.AssertOriginal();
  }

  [Theory]
  [InlineData("identity")]
  [InlineData("length")]
  [InlineData("plan")]
  [InlineData("rangeHash")]
  [InlineData("overlap")]
  [InlineData("bounds")]
  [InlineData("rollbackMissing")]
  [InlineData("journalMissing")]
  [InlineData("journalCorrupt")]
  public void Invalid_inputs_and_missing_records_refuse_before_any_write(string failure)
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    var plan = fixture.Plan;
    switch (failure)
    {
      case "identity": fixture.ActualIdentity = fixture.ActualIdentity with { FileId = "replaced-file" }; break;
      case "length": fixture.Stream.LogicalLength++; break;
      case "plan": plan = plan with { RecipeSha256 = new string('b', 64) }; break;
      case "rangeHash": plan = plan with { Ranges = new[] { plan.Ranges[0] with { AfterSha256 = new string('a', 64) } } }; break;
      case "overlap": plan = plan with { Ranges = new[] { plan.Ranges[0], plan.Ranges[1] with { Offset = plan.Ranges[0].Offset } } }; break;
      case "bounds": plan = plan with { Ranges = new[] { plan.Ranges[0] with { Offset = long.MaxValue } } }; break;
      case "rollbackMissing":
        using (var lease = fixture.Journal.Acquire())
        {
          var ledger = lease.Read();
          var missing = ledger.Active!.Plan with { Ranges = Array.Empty<NativeFxRange>() };
          lease.Save(ledger with { Active = ledger.Active with { Plan = missing } }, "synthetic_missing_rollback");
        }
        break;
      case "journalMissing": File.Delete(fixture.Path); break;
      case "journalCorrupt": File.WriteAllText(fixture.Path, "{"); break;
    }
    Assert.ThrowsAny<Exception>(() => fixture.Run(plan: plan));
    Assert.Equal(0, fixture.Stream.WriteCount);
    Assert.Equal(0, fixture.Stream.ReadCount);
  }

  [Fact]
  public void Missing_journal_is_not_automatically_registered_and_existing_registration_cannot_be_reset()
  {
    using var fixture = new Fixture();
    Assert.Throws<IOException>(() => fixture.Journal.RegisterVerifiedBaseline(fixture.Plan.Baseline));
    File.Delete(fixture.Path);
    Assert.Throws<FileNotFoundException>(() => Prepare(fixture.Journal, fixture.Plan));
    Assert.False(File.Exists(fixture.Path));
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void Failed_flush_or_readback_does_not_publish_completion(bool corruptReadback)
  {
    using var fixture = new Fixture();
    Prepare(fixture.Journal, fixture.Plan);
    fixture.Stream.OnFlush = () =>
    {
      if (corruptReadback) fixture.Stream.ChangeLastByte(255);
      else throw new IOException("synthetic_flush_failure");
    };
    Assert.ThrowsAny<Exception>(() => fixture.Run());
    using (var lease = fixture.Journal.Acquire()) Assert.Equal("applying", lease.Read().Active!.State);
    fixture.Stream.OnFlush = null;
    if (corruptReadback)
    {
      Assert.Throws<InvalidOperationException>(() => fixture.Run(true));
      Assert.Equal(0, fixture.Stream.WriteCount);
    }
    else
    {
      var applied = fixture.Run();
      Assert.Equal(0, applied.Receipt.BytesWritten);
      Assert.Equal(1, fixture.Stream.FlushCount);
      fixture.Run(true);
      fixture.Stream.AssertOriginal();
    }
  }

  private sealed class Fixture : IDisposable
  {
    internal string Directory { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "nll-range-synthetic-" + Guid.NewGuid().ToString("N"));
    internal string Path => System.IO.Path.Combine(Directory, "store-state.json");
    internal NativeFxRangeJournal Journal { get; }
    internal NativeFxRangePlan Plan { get; }
    internal SparseRangeStream Stream { get; }
    internal NativeFxStoreIdentity ActualIdentity { get; set; }
    internal int OpenCount { get; private set; }

    internal Fixture(long length = 10000, int bytes = 12)
    {
      System.IO.Directory.CreateDirectory(Directory);
      NativeFxRange Range(long offset, int count)
      {
        var before = Enumerable.Range(0, count).Select(x => (byte)(x % 50)).ToArray();
        var after = before.Select(x => x % 3 == 0 ? x : (byte)(x + 100)).ToArray();
        return new(offset, before, after, Hex(before), Hex(after));
      }
      ActualIdentity = new("synthetic-volume", "synthetic-file", length);
      Plan = new(Contract, Guid.NewGuid(), new("synthetic-install", "synthetic-build", ActualIdentity, new string('0', 64)),
          new string('1', 64), new string('2', 64), new string('3', 64),
          new[] { Range(256, bytes / 2), Range(length - bytes, bytes - bytes / 2) });
      Stream = new(Plan);
      Journal = new(Path);
      Journal.RegisterVerifiedBaseline(Plan.Baseline);
    }

    internal NativeFxRangeResult Run(bool restore = false, NativeFxRangeJournal? journal = null, NativeFxRangePlan? plan = null)
    {
      Stream.ResetCounts();
      return Execute(journal ?? Journal, plan ?? Plan, restore, () =>
      {
        OpenCount++;
        return new(Stream, ActualIdentity);
      });
    }

    internal void AssertCounts(NativeFxRangeResult result)
    {
      Assert.Equal(result.Receipt.BytesRead, Stream.ReadCount);
      Assert.Equal(result.Receipt.BytesWritten, Stream.WriteCount);
    }

    public void Dispose() => System.IO.Directory.Delete(Directory, recursive: true);
  }

  // A 6.6GB logical stream holds only the selected synthetic bytes in memory.
  // Any attempt to scan a header, gap, trailer or other chunk fails immediately.
  private sealed class SparseRangeStream : Stream
  {
    private readonly NativeFxRange[] ranges;
    private readonly byte[][] contents;
    internal long LogicalLength { get; set; }
    internal long ReadCount { get; private set; }
    internal long WriteCount { get; private set; }
    internal int FlushCount { get; private set; }
    internal int? FailAfterBytes { get; set; }
    internal Action? OnFlush { get; set; }
    internal byte OutsideByte { get; set; }

    internal SparseRangeStream(NativeFxRangePlan plan)
    {
      LogicalLength = plan.Baseline.Store.Length;
      ranges = plan.Ranges;
      contents = ranges.Select(x => (byte[])x.Before.Clone()).ToArray();
    }

    internal void ResetCounts() { ReadCount = 0; WriteCount = 0; FlushCount = 0; }
    internal void ChangeLastByte(byte value) => contents[^1][^1] = value;
    internal void AssertOriginal() { for (var i = 0; i < ranges.Length; i++) Assert.Equal(ranges[i].Before, contents[i]); }
    internal void AssertTarget() { for (var i = 0; i < ranges.Length; i++) Assert.Equal(ranges[i].After, contents[i]); }
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => true;
    public override long Length => LogicalLength;
    public override long Position { get; set; }
    private (int Range, int Offset) Locate(int count)
    {
      for (var i = 0; i < ranges.Length; i++)
        if (Position >= ranges[i].Offset && Position <= ranges[i].Offset + contents[i].Length - count)
          return (i, checked((int)(Position - ranges[i].Offset)));
      throw new InvalidOperationException("synthetic_outside_range_access");
    }
    public override int Read(Span<byte> buffer)
    {
      var (r, offset) = Locate(buffer.Length);
      contents[r].AsSpan(offset, buffer.Length).CopyTo(buffer);
      Position += buffer.Length;
      ReadCount += buffer.Length;
      return buffer.Length;
    }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override void Write(ReadOnlySpan<byte> buffer)
    {
      var (r, offset) = Locate(buffer.Length);
      var count = FailAfterBytes.HasValue ? Math.Min(FailAfterBytes.Value, buffer.Length) : buffer.Length;
      buffer[..count].CopyTo(contents[r].AsSpan(offset));
      Position += count;
      WriteCount += count;
      if (FailAfterBytes.HasValue)
      {
        FailAfterBytes -= count;
        if (FailAfterBytes == 0) throw new IOException("synthetic_torn_write");
      }
    }
    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
    public override void Flush() { FlushCount++; OnFlush?.Invoke(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { } // reopen the same simulated file after a crash
  }
}
