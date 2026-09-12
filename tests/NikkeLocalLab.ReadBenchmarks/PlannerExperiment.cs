using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

static partial class Benchmark
{
  static LocalAccountProfileWrite MeasurementProfile(object catalogs, int? level, bool dense)
  {
    var profile = (LocalAccountProfileWrite)Invoke("CreateSyntheticProfileWithOwnedCube", catalogs, level);
    if (!dense) return profile;
    T Property<T>(string name) => (T)catalogs.GetType().GetProperty(name)!.GetValue(catalogs)!;
    var equipment = Property<IReadOnlyDictionary<LocalEquipmentSlot, EntityUid>>("Equipment");
    var option = Property<EntityUid>("OptionUid");
    var unit = Property<LocalProfileValueUnit>("OptionUnit");
    var value = Property<long>("OptionRawValue1");
    var builds = profile.Builds.Select(build => new LocalCharacterBuildWrite(build.CharacterUid, build.CharacterLevel,
        build.LimitBreak, build.CoreLevel, build.BondLevel, build.Skill1Level, build.Skill2Level, build.BurstLevel,
        Enum.GetValues<LocalEquipmentSlot>().Select(slot => new LocalEquipmentWrite(slot, LocalEquipmentState.Equipped,
            equipment[slot], LocalProfileFact<int>.Ready(5), LocalProfileFact<bool>.Ready(true),
            Enumerable.Range(1, 3).Select(line => new LocalOverloadLineWrite(line, option, unit, new(value, 4))))),
        build.Cube, build.Collection, build.ValidationMode, build.MaterializationPolicy, build.Origin));
    return new(profile.CharacterCatalog, profile.CombatSupportCatalog, profile.AccountState, builds,
        profile.SquadCharacterUids, profile.SquadOrigin, profile.ProfileTemplateOrigin);
  }

  static async Task<object> MeasurePlannerAsync(string output, int accounts, int roster, int history,
      bool dense, Dictionary<EntityUid, EntityUid> expected)
  {
    // Only the guarded disposable connection may ANALYZE. No production stats,
    // indexes, schema or data are modified by this controlled experiment.
    var connection = DisposableConnection();
    await using var writer = NpgsqlDataSource.Create(connection.ConnectionString);
    connection.Options = "-c default_transaction_read_only=on";
    using var trace = new QueryTrace();
    using var counter = new CommandCounter();
    using var disk = new PhysicalDiskCounters();
    await using var source = new NpgsqlDataSourceBuilder(connection.ConnectionString).UseLoggerFactory(counter)
        .ConfigureTracing(options => options.ConfigureCommandEnrichmentCallback(trace.Capture)).Build();
    var phases = new List<object>();
    foreach (var phase in new[] { "before_explicit_analyze", "after_explicit_analyze" })
    {
      if (phase == "after_explicit_analyze")
      {
        await using var analyze = writer.CreateCommand("ANALYZE");
        await analyze.ExecuteNonQueryAsync();
      }
      // Fresh service each call deliberately bypasses the readiness cache. This
      // isolates the still-required first-read path; JIT/DB/OS are warmed, not flushed.
      async Task ReadAsync()
      {
        var service = (PostgreSqlProfileManagementService)Invoke("Service", source);
        var rows = await service.ListAccountsAsync();
        Require(rows.Count == accounts && rows.All(row => expected[row.AccountUid] == row.ProfileRevision.RevisionUid));
      }
      for (var warm = 0; warm < 2; warm++) await ReadAsync();
      var samples = new List<object>();
      var plans = new List<object>();
      for (var iteration = 0; iteration < 3; iteration++)
      {
        counter.Reset();
        trace.Enabled = true;
        var before = disk.Read();
        var allocation = GC.GetTotalAllocatedBytes(true);
        var start = Stopwatch.GetTimestamp();
        try { await ReadAsync(); } finally { trace.Enabled = false; }
        var wallMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        var allocatedBytes = GC.GetTotalAllocatedBytes(true) - allocation;
        var after = disk.Read();
        Require(counter.Count == 1 + 13L * accounts && after.Read >= before.Read && after.Write >= before.Write);
        samples.Add(new
        {
          iteration,
          wallMs,
          allocatedBytes,
          commands = counter.Count,
          physicalDiskReadBytesSystemTotal = after.Read - before.Read,
          physicalDiskWriteBytesSystemTotal = after.Write - before.Write
        });
        var captured = trace.Take();
        try
        {
          // Explain only the equipment graph: exact typed synthetic parameters
          // are retained in memory and never emitted into an artifact.
          if (iteration == 0)
            foreach (var (_, query) in captured.Where(row => row.Command.CommandText.Contains("build_equipment_state", StringComparison.Ordinal)))
            {
              await using var command = source.CreateCommand("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query.CommandText);
              foreach (NpgsqlParameter parameter in query.Parameters) command.Parameters.Add(parameter.Clone());
              using var document = JsonDocument.Parse((string)(await command.ExecuteScalarAsync())!);
              var result = document.RootElement[0];
              plans.Add(new
              {
                querySha256 = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(query.CommandText))).ToLowerInvariant(),
                executionMs = result.GetProperty("Execution Time").GetDouble(),
                plan = SanitizePlan(result.GetProperty("Plan"))
              });
            }
        }
        finally { foreach (var row in captured) row.Command.Dispose(); }
      }
      phases.Add(new { phase, samples, plans });
      Console.WriteLine($"S08 planner: {accounts} accounts, dense={dense}, {phase}, 3 samples");
    }
    var resultCell = new
    {
      accounts,
      roster,
      history,
      dense,
      phases,
      physicalDiskBoundary = "PDH PhysicalDisk(_Total) raw cumulative bytes across the host; actual disk-stack I/O, NOT attributable to this request/DB and NOT SSD NAND bytes; other processes/background writes may contribute",
      statisticsBoundary = "two warmed fresh-service phases in fixed before/after order; ANALYZE intervention, not randomized causal proof; no OS/PG cache eviction",
      operatingDatabaseTouched = false
    };
    await File.WriteAllTextAsync(Path.Combine(output, $"s08-planner-{accounts}-{dense}.json"), JsonSerializer.Serialize(resultCell, Json));
    return resultCell;
  }

  sealed class PhysicalDiskCounters : IDisposable
  {
    IntPtr query;
    readonly IntPtr reads;
    readonly IntPtr writes;
    public PhysicalDiskCounters()
    {
      Require(OperatingSystem.IsWindows());
      Check(PdhOpenQuery(null, IntPtr.Zero, out query));
      try
      {
        Check(PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec", IntPtr.Zero, out reads));
        Check(PdhAddEnglishCounter(query, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec", IntPtr.Zero, out writes));
      }
      catch { Dispose(); throw; }
    }
    public (long Read, long Write) Read()
    {
      Check(PdhCollectQueryData(query));
      return (Value(reads), Value(writes));
    }
    static long Value(IntPtr counter)
    {
      Check(PdhGetRawCounterValue(counter, out _, out var value));
      Require(value.Status is 0 or 1 && value.First >= 0);
      return value.First;
    }
    static void Check(uint code) { if (code != 0) throw new InvalidOperationException("s08_physical_disk_counter_unavailable"); }
    public void Dispose() { if (query != IntPtr.Zero) { PdhCloseQuery(query); query = IntPtr.Zero; } }
    [StructLayout(LayoutKind.Sequential)]
    struct RawCounter
    {
      public uint Status;
      public System.Runtime.InteropServices.ComTypes.FILETIME Time;
      public long First;
      public long Second;
      public uint MultiCount;
    }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhOpenQueryW")]
    static extern uint PdhOpenQuery(string? source, IntPtr data, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode, EntryPoint = "PdhAddEnglishCounterW")]
    static extern uint PdhAddEnglishCounter(IntPtr query, string path, IntPtr data, out IntPtr counter);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhGetRawCounterValue(IntPtr counter, out uint type, out RawCounter value);
    [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
  }
}
