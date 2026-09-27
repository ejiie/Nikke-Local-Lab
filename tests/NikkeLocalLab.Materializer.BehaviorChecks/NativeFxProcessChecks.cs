using System.Diagnostics;
using System.Text.Json;
using NikkeLocalLab.PhaseD;
using static CommonDeliveryFiles;

// Source-linked production delivery/transaction code. Only our newly created,
// 64KiB synthetic stores are opened. Job/installation checks are test adapters.
internal static class NativeFxProcessChecks
{
  private sealed record Input(string Launch, CommonFilePin Baseline, string Profile, string Weakness,
      bool Reuse, CommonNativePatch[] Patches);
  private sealed record Sample(string Mode, string Operation, double BodyMilliseconds, double? ProcessMilliseconds,
      long Reads, long Writes, int Opens, bool Historical);
  private const string Candidate = "2222222222222222222222222222222222222222222222222222222222222222";
  private const string Recipe = "3333333333333333333333333333333333333333333333333333333333333333";
  private const string Termination = "4444444444444444444444444444444444444444444444444444444444444444";
  private const int CrashExit = 73;

  internal static int Run(string[] args)
  {
    if (args[0] == "--native-fx-step")
    {
      Require(args.Length == 4);
      var input = JsonSerializer.Deserialize<Input>(File.ReadAllBytes(Plain(args[1])), Json)!;
      var sample = Step(input, args[2], int.Parse(args[3]));
      Console.WriteLine(JsonSerializer.Serialize(sample, Json));
      return 0;
    }
    Require(args.Length == 3 && int.TryParse(args[2], out var count) && count is >= 5 and <= 100);
    var samples = int.Parse(args[2]);
    var root = Plain(args[1]);
    Require(!Directory.Exists(root));
    Directory.CreateDirectory(root);
    var work = Path.Combine(root, "synthetic-work");
    Directory.CreateDirectory(work);
    var rows = new List<Sample>();
    var crashCases = 0;
    var matrixCases = 0;
    try
    {
      // Each direction and each byte boundary of a 12-byte, two-range change.
      // Exit(73) bypasses finally/Dispose; the next operation runs in a new process.
      for (var cut = 0; cut <= 12; cut++)
        foreach (var interruptRestore in new[] { false, true })
          foreach (var resumeRestore in new[] { false, true })
          {
            var input = Create(work, 12, "fire", "restart", false);
            Step(input, "stage");
            if (interruptRestore) Child(input, "apply");
            Child(input, interruptRestore ? "restore" : "apply", cut);
            var recovered = Child(input, resumeRestore ? "restore" : "apply")!;
            Require(recovered.Reads is >= 12 and <= 24 && recovered.Writes is >= 0 and <= 12);
            VerifyStore(input, !resumeRestore);
            if (!resumeRestore) Child(input, "restore");
            VerifyStore(input, false);
            crashCases++;
          }
      // Real file + separate-process coverage of common profiles and every weakness.
      foreach (var profile in new[] { "26", "29", "41" })
        foreach (var weakness in new[] { "fire", "water", "wind", "electric", "iron" })
        {
          var input = Create(work, 24153, weakness, profile, weakness is "electric" or "iron");
          Child(input, "stage");
          if (!input.Reuse)
          {
            Child(input, "apply"); VerifyStore(input, true); Child(input, "restore");
            var late = Child(input, "restore")!;
            Require(late.Historical && late.Opens == 0 && late.Reads == 0 && late.Writes == 0);
          }
          VerifyStore(input, false); matrixCases++;
        }
      // Warm in-process code once. Process samples always load a new runtime.
      var warm = Create(work, 24153, "fire", "warmup", false);
      Step(warm, "stage"); Step(warm, "apply"); Step(warm, "restore");
      foreach (var mode in new[] { "in_process", "fresh_process" })
        for (var i = 0; i < samples; i++)
          foreach (var reuse in new[] { false, true })
          {
            var input = Create(work, 24153, reuse ? "iron" : "fire", "timing", reuse);
            foreach (var operation in reuse ? new[] { "stage_reuse" } : new[] { "stage", "apply", "restore" })
            {
              var result = mode == "fresh_process" ? Child(input, operation)! : Step(input, operation);
              if (operation is "apply" or "restore")
                Require(result.Reads == 48306 && result.Writes == 24153 && result.Opens == 1);
              rows.Add(result with { Mode = mode });
              if (operation == "apply") VerifyStore(input, true);
            }
            VerifyStore(input, false);
          }
      var summaries = rows.GroupBy(x => new { x.Mode, x.Operation }).Select(group => new
      {
        group.Key.Mode,
        group.Key.Operation,
        count = group.Count(),
        body = Percentiles(group.Select(x => x.BodyMilliseconds)),
        processInclusive = group.Key.Mode == "fresh_process" ? Percentiles(group.Select(x => x.ProcessMilliseconds!.Value)) : null,
        maximumStoreReads = group.Max(x => x.Reads),
        maximumStoreWrites = group.Max(x => x.Writes)
      }).ToArray();
      Save(Path.Combine(root, "receipt.json"), new
      {
        contractId = "nll/synthetic-native-fx-process-performance/v1",
        completedAtUtc = DateTimeOffset.UtcNow,
        crashCases,
        matrixCases,
        samplesPerOperation = samples,
        storeLength = 65536,
        selectedBytes = 24153,
        productionSourceLinked = true,
        physicalIdentityAndJobChecksSynthetic = true,
        processExitNotPowerLoss = true,
        productionPreparationMeasured = false,
        actualGameAcceptanceClaimed = false,
        allSamplesBelowFiveSeconds = rows.All(x => (x.ProcessMilliseconds ?? x.BodyMilliseconds) < 5000),
        stopwatchFrequency = Stopwatch.Frequency,
        framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
        operatingSystem = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
        summaries,
        samples = rows
      });
      Console.WriteLine($"Native FX: {crashCases} process interruption cases, {matrixCases} profile/weakness cases, {rows.Count} timing samples passed.");
      return 0;
    }
    finally
    {
      // Delete only the synthetic directory this invocation created beneath its new output root.
      Require(Path.GetDirectoryName(Path.GetFullPath(work)) == root && Path.GetFileName(work) == "synthetic-work");
      Directory.Delete(Plain(work), recursive: true);
    }
  }

  private static object Percentiles(IEnumerable<double> values)
  {
    var ordered = values.Order().ToArray();
    return new
    {
      p50Milliseconds = ordered[(int)Math.Ceiling(ordered.Length * .5) - 1],
      p95Milliseconds = ordered[(int)Math.Ceiling(ordered.Length * .95) - 1],
      maximumMilliseconds = ordered[^1]
    };
  }

  private static Input Create(string work, int bytes, string weakness, string profile, bool reuse)
  {
    var root = Path.Combine(work, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
    var store = Path.Combine(root, "synthetic.store");
    var original = Enumerable.Repeat((byte)90, 65536).ToArray();
    CommonNativePatch Patch(int offset, int length)
    {
      CommonFilePin Chunk(byte value, string suffix)
      {
        var path = Path.Combine(root, offset + suffix);
        File.WriteAllBytes(path, Enumerable.Repeat(value, length).ToArray()); return Pin(path);
      }
      Array.Fill(original, (byte)17, offset, length);
      return new(NativeFxExecutionDelivery.Target(weakness), offset, Chunk(17, ".before"), Chunk(23, ".after"));
    }
    var patches = new[] { Patch(256, bytes / 2), Patch(40000, bytes - bytes / 2) };
    File.WriteAllBytes(store, original);
    var baseline = new NativeFxBaseline("synthetic", "synthetic", new("synthetic-volume", "synthetic-file", original.Length), Hash(original));
    var journal = Path.Combine(root, "journal.json");
    new NativeFxRangeJournal(journal).RegisterVerifiedBaseline(baseline);
    var registration = new CommonNativeRegistration(NativeFxExecutionDelivery.RegistrationContract, Pin(store), baseline, journal);
    var registrationPath = Path.Combine(root, "baseline.json"); Save(registrationPath, registration);
    var input = new Input(Path.Combine(root, Guid.NewGuid().ToString("D")), Pin(registrationPath),
        Hash(System.Text.Encoding.UTF8.GetBytes(profile)), weakness, reuse, patches);
    Save(Path.Combine(root, "input.json"), input);
    return input;
  }

  private static Sample Step(Input input, string operation, int cut = -1)
  {
    var watch = Stopwatch.StartNew();
    var registration = NativeFxExecutionDelivery.Registration(input.Baseline);
    var opens = 0;
    MeteredStore? meter = null;
    NativeFxRangeResult? result = null;
    if (operation is "stage" or "stage_reuse")
    {
      var staged = NativeFxExecutionDelivery.Stage(input.Launch, input.Profile, Candidate, Recipe,
          input.Weakness, input.Baseline, registration, input.Reuse ? [] : input.Patches);
      Require((staged is null) == input.Reuse);
    }
    else
    {
      Require(operation is "apply" or "restore");
      var root = Path.Combine(input.Launch, "runtime", "execution-fx");
      result = NativeFxExecutionDelivery.Execute(root, FileHash(Path.Combine(root, "manifest.private.json")),
          Guid.Parse(Path.GetFileName(input.Launch)).ToString("N"), input.Profile, Candidate, input.Weakness,
          operation == "restore" ? Termination : "", operation == "apply", () => { },
          (pin, value) => Require(pin == input.Baseline && value == registration), value =>
          {
            opens++;
            meter = new MeteredStore(new FileStream(value.OriginalStore.Path, FileMode.Open,
                FileAccess.ReadWrite, FileShare.None, 1), input.Patches, cut);
            return new(meter, value.Baseline.Store);
          });
    }
    watch.Stop();
    var reads = meter?.Reads ?? 0; var writes = meter?.Writes ?? 0;
    var selected = input.Patches.Sum(x => x.Before.Length);
    Require(reads <= 2 * selected && writes <= selected);
    if (result is { Historical: false })
      Require(reads == result.Receipt.BytesRead && writes == result.Receipt.BytesWritten);
    return new("in_process", operation, watch.Elapsed.TotalMilliseconds, null, reads, writes, opens, result?.Historical ?? false);
  }

  private static Sample? Child(Input input, string operation, int cut = -1)
  {
    var info = new ProcessStartInfo(Environment.ProcessPath!)
    { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
      info.ArgumentList.Add(typeof(NativeFxProcessChecks).Assembly.Location);
    foreach (var arg in new[] { "--native-fx-step", Path.Combine(Path.GetDirectoryName(input.Launch)!, "input.json"), operation, cut.ToString() })
      info.ArgumentList.Add(arg);
    var watch = Stopwatch.StartNew();
    using var child = Process.Start(info)!;
    var stdout = child.StandardOutput.ReadToEndAsync(); var stderr = child.StandardError.ReadToEndAsync();
    if (!child.WaitForExit(30000)) { child.Kill(entireProcessTree: true); child.WaitForExit(); throw new IOException("synthetic_child_timeout"); }
    watch.Stop();
    Require(child.ExitCode == (cut >= 0 ? CrashExit : 0));
    _ = stderr.GetAwaiter().GetResult();
    if (cut >= 0) return null;
    return JsonSerializer.Deserialize<Sample>(stdout.GetAwaiter().GetResult(), Json)! with { ProcessMilliseconds = watch.Elapsed.TotalMilliseconds };
  }

  private static void VerifyStore(Input input, bool applied)
  {
    // Full comparison of the tiny test fixture is outside measured production operations.
    var expected = Enumerable.Repeat((byte)90, 65536).ToArray();
    foreach (var patch in input.Patches) Array.Fill(expected, applied ? (byte)23 : (byte)17, (int)patch.Offset, (int)patch.Before.Length);
    var registration = NativeFxExecutionDelivery.Registration(input.Baseline);
    Require(File.ReadAllBytes(registration.OriginalStore.Path).SequenceEqual(expected));
  }

  private sealed class MeteredStore(FileStream file, CommonNativePatch[] patches, int cut) : Stream
  {
    internal long Reads, Writes;
    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => true;
    public override long Length => file.Length;
    public override long Position { get => file.Position; set => file.Position = value; }
    private void Within(int count) => Require(patches.Any(p => Position >= p.Offset && Position + count <= p.Offset + p.Before.Length));
    public override int Read(Span<byte> buffer)
    { Within(buffer.Length); var n = file.Read(buffer); Reads += n; return n; }
    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));
    public override void Write(ReadOnlySpan<byte> buffer)
    {
      Within(buffer.Length);
      if (cut >= 0 && Writes + buffer.Length >= cut)
      {
        var partial = checked((int)(cut - Writes));
        file.Write(buffer[..partial]); file.Flush(true);
        Environment.Exit(CrashExit);
      }
      file.Write(buffer); Writes += buffer.Length;
    }
    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));
    public override void Flush() => file.Flush(true);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) file.Dispose(); base.Dispose(disposing); }
  }
}
