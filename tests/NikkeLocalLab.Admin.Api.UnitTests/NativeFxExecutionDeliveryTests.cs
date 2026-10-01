using System.Text.Json;
using NikkeLocalLab.PhaseD;
using Xunit;
using static CommonDeliveryFiles;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class NativeFxExecutionDeliveryTests
{
  public static IEnumerable<object[]> Profiles()
  {
    foreach (var season in new[] { 26, 29, 41 })
      foreach (var weakness in new[] { "fire", "water", "wind", "electric", "iron" })
        yield return new object[] { season, weakness };
  }

  [Theory]
  [MemberData(nameof(Profiles))]
  public void Common_delivery_handles_all_elements_and_distinct_profiles_without_whole_store_io(int season, string weakness)
  {
    using var fixture = new Fixture(weakness, season.ToString());
    // These two synthetic variants model reuse; the caller's assembly evidence,
    // rather than season or this transport, selects the empty patch set.
    var reuse = weakness is "electric" or "iron";
    var staged = fixture.Stage(reuse);
    Assert.Equal(0, fixture.Opens);
    using (var lease = fixture.Journal.Acquire()) Assert.Null(lease.Read().Active);
    if (reuse)
    {
      Assert.Null(staged);
      Assert.False(Directory.Exists(fixture.FxRoot));
      return;
    }
    var manifest = fixture.Manifest();
    Assert.Equal(NativeFxRangeTransaction.Contract, manifest.ContractId);
    using (var raw = JsonDocument.Parse(File.ReadAllBytes(fixture.ManifestPath)))
      Assert.False(raw.RootElement.TryGetProperty("candidateStoreSha256", out _));
    var applied = fixture.Run();
    Assert.Equal(120, applied.Receipt.BytesRead);
    Assert.Equal(60, applied.Receipt.BytesWritten);
    Assert.Equal(120, fixture.Store.ReadBytes);
    Assert.Equal(60, fixture.Store.WriteBytes);
    var repeated = fixture.Run();
    Assert.Equal(0, repeated.Receipt.BytesWritten);
    var restored = fixture.Run(restore: true);
    Assert.Equal(120, restored.Receipt.BytesRead);
    Assert.Equal(60, restored.Receipt.BytesWritten);
    fixture.Store.AssertOriginal();
    var receiptBefore = File.ReadAllBytes(Path.Combine(fixture.FxRoot, "retired.json"));
    var opens = fixture.Opens;
    var late = fixture.Run(restore: true);
    Assert.True(late.Historical);
    Assert.Equal(opens, fixture.Opens);
    Assert.Equal(receiptBefore, File.ReadAllBytes(Path.Combine(fixture.FxRoot, "retired.json")));
    Assert.Equal(0, fixture.Store.ReadBytes);
  }

  [Fact]
  public void Failure_after_staging_reserves_nothing_and_unapplied_cleanup_is_a_no_write_retirement()
  {
    using var fixture = new Fixture();
    fixture.Stage();
    var result = fixture.Run(restore: true);
    Assert.Equal(60, result.Receipt.BytesRead);
    Assert.Equal(0, result.Receipt.BytesWritten);
    Assert.True(File.Exists(Path.Combine(fixture.FxRoot, "retired.json")));
  }

  [Theory]
  [InlineData(false, "exited")]
  [InlineData(true, "exited")]
  [InlineData(false, "retirement_self")]
  [InlineData(false, "runtime_alive")]
  [InlineData(true, "child_alive")]
  [InlineData(false, "pid_reused")]
  [InlineData(false, "reservation")]
  public void Absent_job_retirement_checks_identities_before_native_ranges(bool applied, string identityState)
  {
    if (!OperatingSystem.IsWindows()) return; // Actual Windows Job API, no installed resources.
    using var fixture = new Fixture(); fixture.Stage();
    if (applied) fixture.Run();
    var uid = Path.GetFileName(fixture.Launch);
    var nonce = Guid.NewGuid().ToString("N");
    var runner = Path.Combine(fixture.Launch, "tools", "runner");
    var runtime = Path.Combine(fixture.Launch, "runtime");
    Directory.CreateDirectory(runner);
    var manifest = fixture.Manifest();
    void Write(string path, object value) => File.WriteAllText(path, JsonSerializer.Serialize(value, Json));
    Write(Path.Combine(runner, "runner.input.json"), new
    {
      contractId = "nll/phase-d-runner-input/v3",
      launchRoot = fixture.Launch,
      launchContextUid = uid,
      jobNonce = nonce,
      weaknessCode = manifest.WeaknessCode,
      bossRuntimeVariantProfileSha256 = manifest.ProfileSha256,
      executionFx = new { manifestSha256 = FileHash(fixture.ManifestPath), manifest.CandidateSealSha256, manifest.ProfileSha256, manifest.WeaknessCode }
    });
    foreach (var name in new[] { "Nll.PhaseDJob.cs", "Nll.PhaseDJob.ps1" })
      File.WriteAllText(Path.Combine(runner, name), "synthetic unexecuted code");
    File.WriteAllText(Path.Combine(runtime, "synthetic.dll"), "synthetic unexecuted binary");
    var bundlePath = Path.Combine(runner, "runner.bundle.json");
    Write(bundlePath, new
    {
      contractId = "nll/phase-d-runner-bundle/v2",
      launchContextUid = uid,
      engineCode = "parameterized/v1",
      members = Directory.GetFiles(runner).Select(path => new { name = Path.GetFileName(path), sha256 = FileHash(path) }).ToArray(),
      runtimeCode = new[] { new { name = "synthetic.dll", sha256 = FileHash(Path.Combine(runtime, "synthetic.dll")) } }
    });
    var bundleSha = FileHash(bundlePath);
    var proofPath = Path.Combine(fixture.Launch, "job-zero.receipt.json");
    Write(proofPath, new
    {
      contractId = "nll/phase-d-job-zero/v1",
      launchContextUid = uid,
      runnerBundleSha256 = bundleSha,
      jobNonce = nonce,
      activeProcesses = 0,
      runtimeRoot = runtime
    });
    File.WriteAllText(Path.Combine(fixture.Launch, "job-reservation.json"), "");
    using (var job = Nll.PhaseD.ExecutionJob.Create("Local\\NLL.PhaseD." + nonce))
    {
      var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
      using var child = job.Start(executable, "/c exit 0");
      Write(Path.Combine(fixture.Launch, "phase-d-child-start.identity.json"), new
      {
        contractId = "nll/phase-d-child-deadline/v1",
        processId = child.Id,
        processStartedAtUtc = child.StartTime.ToUniversalTime(),
        executablePath = executable
      });
      job.TerminateAndWait(10000);
      Assert.True(child.WaitForExit(10000));
    }
    using var self = System.Diagnostics.Process.GetCurrentProcess();
    object identity = new { processId = self.Id, processStartedAtUtc = self.StartTime.ToUniversalTime(), executablePath = self.MainModule!.FileName };
    if (identityState == "pid_reused") identity = new { processId = self.Id, processStartedAtUtc = self.StartTime.ToUniversalTime().AddSeconds(-1), executablePath = self.MainModule!.FileName };
    if (identityState == "reservation") identity = new { processId = 0, processStartedAtUtc = (string?)null, executablePath = self.MainModule!.FileName };
    if (identityState != "exited")
    {
      if (identityState == "runtime_alive")
        Write(Path.Combine(fixture.Launch, "runtime-processes.identity.json"), new
        {
          contractId = "nll/phase-d-runtime-process-identities/v1",
          launchContextUid = uid,
          client = identity,
          bootstrap = (object?)null,
          server = (object?)null
        });
      else
      {
        var child = JsonSerializer.SerializeToElement(identity, Json);
        Write(Path.Combine(fixture.Launch, identityState == "retirement_self" ? "phase-d-child-fx-retirement.identity.json" : "phase-d-child-start.identity.json"), new
        {
          contractId = "nll/phase-d-child-deadline/v1",
          processId = child.GetProperty("processId"),
          processStartedAtUtc = child.GetProperty("processStartedAtUtc"),
          executablePath = child.GetProperty("executablePath")
        });
      }
    }
    var proofSha = FileHash(proofPath);
    var entered = false;
    void Retire() => NikkeLocalLab.Automation.ExecutionAssetRetirement.Retire(fixture.Launch, bundleSha, proofSha,
        (_, _, _, termination, verify) => { entered = true; fixture.Run(true, verify, termination); }, allowAbsentJob: true);
    if (identityState is "exited" or "retirement_self")
    {
      Retire(); Assert.True(entered); fixture.Store.AssertOriginal();
      var receipt = JsonSerializer.Deserialize<CommonNativeRangeCompletion>(File.ReadAllBytes(Path.Combine(fixture.FxRoot, "retired.json")), Json)!;
      Assert.Equal("restored", receipt.RangeReceipt.State);
      Assert.Equal(applied ? 60 : 0, receipt.RangeReceipt.BytesWritten);
      Assert.Equal(proofSha, receipt.TerminationReceiptSha256);
      Retire(); // Retry after completion uses the same receipt.
    }
    else
    {
      Assert.ThrowsAny<Exception>(Retire); Assert.False(entered);
      Assert.False(File.Exists(Path.Combine(fixture.FxRoot, "retired.json")));
    }
  }

  public static IEnumerable<object[]> VerificationFailures()
  {
    for (var step = 1; step <= 5; step++)
      foreach (var restore in new[] { false, true }) yield return new object[] { step, restore };
  }

  [Theory]
  [MemberData(nameof(VerificationFailures))]
  public void Job_or_pin_check_failure_cannot_publish_false_completion_and_can_resume(int step, bool restore)
  {
    using var fixture = new Fixture(); fixture.Stage();
    if (restore) fixture.Run();
    var checks = 0;
    Assert.Throws<IOException>(() => fixture.Run(restore, () =>
    { if (++checks == step) throw new IOException("synthetic_job_or_pin_failure"); }));
    Assert.False(File.Exists(Path.Combine(fixture.FxRoot, restore ? "retired.json" : "applied.json")));
    if (step <= 3) Assert.Equal(0, fixture.Store.WriteBytes);
    var completed = fixture.Run(restore: true);
    Assert.Equal("restored", completed.Receipt.State);
    fixture.Store.AssertOriginal();
  }

  [Theory]
  [InlineData("profile")]
  [InlineData("candidate")]
  [InlineData("recipe")]
  [InlineData("uid")]
  [InlineData("weakness")]
  [InlineData("planHash")]
  [InlineData("role")]
  [InlineData("chunkPath")]
  [InlineData("registrationPath")]
  [InlineData("journalPath")]
  [InlineData("missingChunk")]
  [InlineData("corruptChunk")]
  [InlineData("missingJournal")]
  [InlineData("oldContract")]
  public void Invalid_delivery_has_no_store_access_or_slow_fallback(string failure)
  {
    using var fixture = new Fixture(); fixture.Stage();
    var manifest = fixture.Manifest();
    switch (failure)
    {
      case "profile": manifest = manifest with { ProfileSha256 = new string('a', 64) }; break;
      case "candidate": manifest = manifest with { CandidateSealSha256 = new string('a', 64) }; break;
      case "recipe": manifest = manifest with { RecipeSha256 = new string('a', 64) }; break;
      case "uid": manifest = manifest with { ExecutionUid = Guid.NewGuid().ToString("N") }; break;
      case "weakness": manifest = manifest with { WeaknessCode = "iron" }; break;
      case "planHash": manifest = manifest with { RangePlanSha256 = new string('a', 64) }; break;
      case "role": manifest.Patches[0] = manifest.Patches[0] with { RoleCode = "electric" }; break;
      case "chunkPath": manifest.Patches[0] = manifest.Patches[0] with { Before = fixture.Patches[0].Before }; break;
      case "registrationPath":
        var other = Path.Combine(fixture.Root, "other-registration.json");
        File.Copy(fixture.BaselinePin.Path, other);
        manifest = manifest with { BaselineRegistration = Pin(other) }; break;
      case "journalPath":
        File.Delete(fixture.BaselinePin.Path);
        Save(fixture.BaselinePin.Path, fixture.Registration with { JournalPath = Path.Combine(fixture.Root, "another-slot.json") });
        manifest = manifest with { BaselineRegistration = Pin(fixture.BaselinePin.Path) }; break;
      case "missingChunk": File.Delete(manifest.Patches[0].Before.Path); break;
      case "corruptChunk": File.AppendAllText(manifest.Patches[0].After.Path, "x"); break;
      case "missingJournal": File.Delete(fixture.Registration.JournalPath); break;
      case "oldContract": manifest = manifest with { ContractId = "nll/common-native-fx-execution/v1" }; break;
    }
    File.Delete(fixture.ManifestPath); Save(fixture.ManifestPath, manifest);
    Assert.ThrowsAny<Exception>(() => fixture.Run());
    Assert.Equal(0, fixture.Opens);
    Assert.Equal(0, fixture.Store.ReadBytes);
    Assert.Equal(0, fixture.Store.WriteBytes);
  }

  [Fact]
  public void Completed_old_delivery_does_not_open_the_next_executions_store()
  {
    using var fixture = new Fixture(); fixture.Stage(); fixture.Run(); fixture.Run(true);
    var previousLaunch = fixture.Launch;
    fixture.Launch = Path.Combine(fixture.Root, Guid.NewGuid().ToString("D"));
    fixture.Stage(); fixture.Run();
    var opens = fixture.Opens;
    var nextLaunch = fixture.Launch;
    fixture.Launch = previousLaunch;
    Assert.True(fixture.Run(true).Historical);
    Assert.Equal(opens, fixture.Opens);
    fixture.Launch = nextLaunch; fixture.Run(true); fixture.Store.AssertOriginal();
  }

  [Fact]
  public void Another_execution_cannot_apply_or_cleanup_an_owned_store()
  {
    using var fixture = new Fixture(); fixture.Stage(); fixture.Run();
    var first = fixture.Launch;
    fixture.Launch = Path.Combine(fixture.Root, Guid.NewGuid().ToString("D"));
    fixture.Stage();
    var opens = fixture.Opens;
    Assert.Throws<InvalidOperationException>(() => fixture.Run());
    Assert.Throws<InvalidOperationException>(() => fixture.Run(true));
    Assert.Equal(opens, fixture.Opens);
    fixture.Launch = first; fixture.Run(true);
  }

  [Fact]
  public void Retirement_is_bound_to_termination_and_range_scope()
  {
    using var fixture = new Fixture(); fixture.Stage(); fixture.Run(); fixture.Run(true);
    var receiptPath = Path.Combine(fixture.FxRoot, "retired.json");
    var original = File.ReadAllBytes(receiptPath);
    var receipt = JsonSerializer.Deserialize<CommonNativeRangeCompletion>(original, Json)!;
    foreach (var changed in new[]
    {
      receipt with { TerminationReceiptSha256 = new string('a', 64) },
      receipt with { RangeReceipt = receipt.RangeReceipt with { ValidationScope = "whole_store" } },
      receipt with { RangeReceipt = receipt.RangeReceipt with { BytesWritten = long.MaxValue } }
    })
    {
      File.Delete(receiptPath); Save(receiptPath, changed);
      var opens = fixture.Opens;
      Assert.Throws<InvalidDataException>(() => fixture.Run(true));
      Assert.Equal(opens, fixture.Opens);
    }
    File.WriteAllBytes(receiptPath, original);
  }

  private sealed class Fixture : IDisposable
  {
    internal string Root { get; } = Path.Combine(Path.GetTempPath(), "nll-delivery-synthetic-" + Guid.NewGuid().ToString("N"));
    internal string Launch { get; set; }
    internal string FxRoot => Path.Combine(Launch, "runtime", "execution-fx");
    internal string ManifestPath => Path.Combine(FxRoot, "manifest.private.json");
    internal CommonNativeRegistration Registration { get; }
    internal CommonFilePin BaselinePin { get; }
    internal NativeFxRangeJournal Journal { get; }
    internal CommonNativePatch[] Patches { get; }
    internal RangeOnlyStore Store { get; }
    internal int Opens { get; private set; }
    private readonly string weakness, profile;
    private const string Candidate = "2222222222222222222222222222222222222222222222222222222222222222";
    private const string Recipe = "3333333333333333333333333333333333333333333333333333333333333333";

    internal Fixture(string weakness = "water", string profileName = "synthetic")
    {
      this.weakness = weakness; profile = Hash(System.Text.Encoding.UTF8.GetBytes(profileName));
      Directory.CreateDirectory(Root); Launch = Path.Combine(Root, Guid.NewGuid().ToString("D"));
      var baseline = new NativeFxBaseline("synthetic-install", "synthetic-version", new("volume", "file", 6574364321L), new string('0', 64));
      Registration = new(NativeFxExecutionDelivery.RegistrationContract,
          new(Path.Combine(Root, "never-created.cdb"), baseline.Store.Length, baseline.OriginalSha256), baseline, Path.Combine(Root, "journal.json"));
      var baselinePath = Path.Combine(Root, "baseline.json"); Save(baselinePath, Registration); BaselinePin = Pin(baselinePath);
      Journal = new(Registration.JournalPath); Journal.RegisterVerifiedBaseline(baseline);
      CommonNativePatch Patch(long offset, int length)
      {
        CommonFilePin Chunk(byte value, string kind)
        {
          var path = Path.Combine(Root, $"{offset}.{kind}.chunk");
          File.WriteAllBytes(path, Enumerable.Repeat(value, length).ToArray()); return Pin(path);
        }
        return new(NativeFxExecutionDelivery.Target(weakness), offset, Chunk(17, "before"), Chunk(23, "after"));
      }
      Patches = new[] { Patch(512, 20), Patch(6000000000L, 40) };
      Store = new(Registration.Baseline.Store.Length, Patches);
    }

    internal object? Stage(bool reuse = false) => NativeFxExecutionDelivery.Stage(Launch, profile, Candidate, Recipe,
        weakness, BaselinePin, Registration, reuse ? Array.Empty<CommonNativePatch>() : Patches);
    internal CommonNativeExecutionV2 Manifest() => JsonSerializer.Deserialize<CommonNativeExecutionV2>(File.ReadAllBytes(ManifestPath), Json)!;
    internal NativeFxRangeResult Run(bool restore = false, Action? verify = null, string? termination = null)
    {
      Store.ReadBytes = Store.WriteBytes = 0;
      return NativeFxExecutionDelivery.Execute(FxRoot, FileHash(ManifestPath), Guid.Parse(Path.GetFileName(Launch)).ToString("N"),
          profile, Candidate, weakness, restore ? termination ?? new string('4', 64) : "", !restore, verify ?? (() => { }), (pin, registration) =>
          {
            Require(pin.Path == BaselinePin.Path && registration.JournalPath == Registration.JournalPath);
          }, _ => { Opens++; return new(Store, Registration.Baseline.Store); });
    }
    public void Dispose()
    {
      var parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
      Assert.Equal(parent, Path.GetDirectoryName(Path.GetFullPath(Root)));
      Directory.Delete(Root, true);
    }
  }

  private sealed class RangeOnlyStore(long length, CommonNativePatch[] patches) : Stream
  {
    private readonly byte[][] contents = patches.Select(x => CommonDeliveryFiles.Read(x.Before, 16777216)).ToArray();
    internal long ReadBytes, WriteBytes;
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => true;
    public override long Length => length;
    public override long Position { get; set; }
    private int Locate(int count)
    {
      for (var i = 0; i < patches.Length; i++)
        if (Position == patches[i].Offset && count == contents[i].Length) return i;
      throw new IOException("synthetic_outside_range_access");
    }
    public override int Read(Span<byte> buffer)
    { contents[Locate(buffer.Length)].CopyTo(buffer); Position += buffer.Length; ReadBytes += buffer.Length; return buffer.Length; }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override void Write(ReadOnlySpan<byte> buffer)
    { buffer.CopyTo(contents[Locate(buffer.Length)]); Position += buffer.Length; WriteBytes += buffer.Length; }
    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { }
    internal void AssertOriginal() { foreach (var bytes in contents) Assert.All(bytes, value => Assert.Equal(17, value)); }
  }
}
