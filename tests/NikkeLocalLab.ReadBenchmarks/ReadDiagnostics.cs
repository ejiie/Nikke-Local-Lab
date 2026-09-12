using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

static partial class Benchmark
{
  // Diagnostic-only tracing: typed synthetic parameters stay in memory. Never
  // enable Npgsql parameter logging or serialize commands, Activity tags or filters.
  sealed class QueryTrace : IDisposable
  {
    readonly object gate = new();
    readonly List<(Activity Activity, NpgsqlCommand Command)> queries = [];
    readonly ActivityListener listener = new()
    {
      ShouldListenTo = source => source.Name == "Npgsql",
      Sample = (ref ActivityCreationOptions<ActivityContext> _) => ActivitySamplingResult.AllData
    };
    public bool Enabled { get; set; }
    public QueryTrace() => ActivitySource.AddActivityListener(listener);
    public void Capture(Activity activity, NpgsqlCommand command)
    {
      if (!Enabled) return;
      // Copy parameters before command disposal/reuse; only SELECT is replayable.
      Require(IsReadQuery(command.CommandText));
      var copy = new NpgsqlCommand(command.CommandText);
      foreach (NpgsqlParameter parameter in command.Parameters)
        copy.Parameters.Add(parameter.Clone());
      lock (gate) queries.Add((activity, copy));
    }
    public (Activity Activity, NpgsqlCommand Command)[] Take()
    {
      lock (gate) { var result = queries.ToArray(); queries.Clear(); return result; }
    }
    public void Dispose()
    {
      listener.Dispose();
      foreach (var query in Take()) query.Command.Dispose();
    }
  }

  static bool IsReadQuery(string sql)
  {
    var trimmed = sql.Trim().TrimEnd(';');
    return trimmed.StartsWith("SELECT", StringComparison.OrdinalIgnoreCase) && !trimmed.Contains(';');
  }

  static async Task<object> MeasureDiagnosticCellAsync(string output, int accounts, int roster, int history,
      Dictionary<EntityUid, EntityUid> expected)
  {
    var connection = DisposableConnection();
    connection.Options = "-c default_transaction_read_only=on";
    using var trace = new QueryTrace();
    using var counter = new CommandCounter();
    await using var source = new NpgsqlDataSourceBuilder(connection.ConnectionString).UseLoggerFactory(counter)
        .ConfigureTracing(options => options.ConfigureCommandEnrichmentCallback(trace.Capture)).Build();
    await using var explainSource = NpgsqlDataSource.Create(connection.ConnectionString);
    var service = (PostgreSqlProfileManagementService)Invoke("Service", source);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var workspaceType = typeof(PostgreSqlProfileManagementService).Assembly.GetType(
        "NikkeLocalLab.Persistence.PostgreSql.PostgreSqlAccountWorkspaceStore")!;
    var workspace = Activator.CreateInstance(workspaceType, BindingFlags.NonPublic | BindingFlags.Instance,
        null, [source], null)!;
    var first = expected.Keys.First();
    var fixture = new ColdFixture(accounts, roster, history,
        expected.ToDictionary(row => row.Key.ToString(), row => row.Value.ToString()));
    var stages = new Dictionary<string, Func<Task>>
    {
      ["summary_rows_only"] = async () => await (Task)workspaceType.GetMethod("ListAsync",
          BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(workspace, [CancellationToken.None])!,
      ["one_current_profile_materialization"] = async () =>
      {
        var row = await store.GetCurrentAsync(first);
        Require(row?.Revision.ProfileTemplateRevisionUid == expected[first] && row.Profile.Builds.Count == roster);
      }
    };
    foreach (var route in ColdRoutes.Where(route => route.StartsWith("service_", StringComparison.Ordinal)))
      stages.Add(route, async () => await ExecuteColdOperationAsync(new(Guid.NewGuid(), route, fixture), service, null));
    var results = new List<object>();
    using var process = Process.GetCurrentProcess();
    foreach (var (name, operation) in stages)
    {
      await operation(); // Explicit warm-up; these are instrumented diagnostics, not cold latency samples.
      var samples = new List<object>();
      var plans = new List<object>();
      for (var iteration = 0; iteration < 3; iteration++)
      {
        counter.Reset();
        trace.Enabled = true;
        var cpu = process.TotalProcessorTime;
        var allocated = GC.GetTotalAllocatedBytes(true);
        var start = Stopwatch.GetTimestamp();
        try { await operation(); }
        finally { trace.Enabled = false; }
        var wallMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        var allocation = GC.GetTotalAllocatedBytes(true) - allocated;
        var cpuMs = (process.TotalProcessorTime - cpu).TotalMilliseconds;
        var captured = trace.Take();
        try
        {
          Require(captured.Length == counter.Count && captured.Length > 0);
          samples.Add(new
          {
            iteration,
            wallMs,
            cpuMs,
            allocatedBytes = allocation,
            commands = counter.Count,
            commandSpanMs = captured.Sum(query => query.Activity.Duration.TotalMilliseconds)
          });
          // Replay separately AFTER timing, once per captured command, including
          // every account's actual typed parameters. Read-only session is mandatory.
          if (iteration == 0)
            foreach (var (_, command) in captured)
            {
              var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(command.CommandText))).ToLowerInvariant();
              await using var replay = explainSource.CreateCommand("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + command.CommandText);
              foreach (NpgsqlParameter parameter in command.Parameters) replay.Parameters.Add(parameter.Clone());
              using var plan = JsonDocument.Parse((string)(await replay.ExecuteScalarAsync())!);
              var root = plan.RootElement[0];
              plans.Add(new
              {
                querySha256 = digest,
                executionMs = root.GetProperty("Execution Time").GetDouble(),
                planningMs = root.GetProperty("Planning Time").GetDouble(),
                plan = SanitizePlan(root.GetProperty("Plan"))
              });
            }
        }
        finally { foreach (var query in captured) await query.Command.DisposeAsync(); }
      }
      results.Add(new { name, samples, plans });
      await File.WriteAllTextAsync(Path.Combine(output, $"s08-diagnostic-progress-{accounts}-{roster}-{history}.json"),
          JsonSerializer.Serialize(new { accounts, roster, history, results, status = "partial_not_complete" }, Json));
      Console.WriteLine($"S08 diagnostic: {accounts}/{roster}/{history} {name}, {plans.Count} exact command replays");
    }
    var growth = await MeasureGrowthAsync(explainSource, accounts, history);
    var cell = new
    {
      accounts,
      roster,
      history,
      fixtureSha256 = FixtureHash(fixture),
      results,
      growth,
      boundary = "3 warmed instrumented stage samples; stages overlap and must not be added; CPU/allocation are process-wide",
      plansBoundary = "first sample commands replayed after timing in read-only sessions; replay rows/buffers are NOT original-request measurements",
      diskIo = "unresolved: PostgreSQL shared read blocks may be served by OS cache; physical device bytes not measured",
      operatingDatabaseTouched = false
    };
    await File.WriteAllTextAsync(Path.Combine(output, $"s08-diagnostic-{accounts}-{roster}-{history}.json"), JsonSerializer.Serialize(cell, Json));
    return cell;
  }

  static Dictionary<string, object> SanitizePlan(JsonElement node)
  {
    // Positive allowlist excludes Output, Filter, Index Cond, SQL and parameter values.
    var result = new Dictionary<string, object>();
    foreach (var name in new[] { "Node Type", "Relation Name", "Index Name", "Join Type", "Strategy" })
      if (node.TryGetProperty(name, out var value)) result.Add(name, value.GetString()!);
    foreach (var name in new[] { "Plan Rows", "Actual Rows", "Actual Loops", "Actual Startup Time", "Actual Total Time",
        "Rows Removed by Filter", "Rows Removed by Join Filter", "Shared Hit Blocks", "Shared Read Blocks",
        "Shared Dirtied Blocks", "Shared Written Blocks", "Temp Read Blocks", "Temp Written Blocks" })
      if (node.TryGetProperty(name, out var value)) result.Add(name, value.GetDouble());
    if (node.TryGetProperty("Plans", out var children)) result.Add("Plans", children.EnumerateArray().Select(SanitizePlan).ToArray());
    return result;
  }

  static async Task<object> MeasureGrowthAsync(NpgsqlDataSource source, int accounts, int history)
  {
    const string integritySql = """
        SELECT
          (SELECT count(*) FROM lab_profile.profile_template_revision),
          (SELECT count(*) FROM lab_profile.local_account a
             LEFT JOIN lab_profile.profile_template_revision r ON r.profile_template_revision_id = a.current_profile_template_revision_id
             WHERE r.profile_template_revision_id IS NULL OR r.local_account_id <> a.local_account_id),
          (SELECT count(*) FROM lab_profile.profile_template_revision r
             LEFT JOIN lab_profile.profile_template_revision p ON p.profile_template_revision_id = r.previous_profile_template_revision_id
             WHERE (r.revision_number > 1 AND p.profile_template_revision_id IS NULL)
                OR p.local_account_id <> r.local_account_id OR p.revision_number <> r.revision_number - 1),
          (SELECT count(*) FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
             WHERE n.nspname LIKE 'lab\_%' ESCAPE '\' AND NOT c.convalidated);
        """;
    await using var command = source.CreateCommand(integritySql);
    await using var reader = await command.ExecuteReaderAsync();
    Require(await reader.ReadAsync());
    var revisions = reader.GetInt64(0);
    var wrongHeads = reader.GetInt64(1);
    var brokenLineage = reader.GetInt64(2);
    var unvalidatedConstraints = reader.GetInt64(3);
    Require(revisions == accounts * history && wrongHeads == 0 && brokenLineage == 0);
    await reader.DisposeAsync();
    await using var sizes = source.CreateCommand("""
        SELECT n.nspname || '.' || c.relname, pg_relation_size(c.oid), pg_indexes_size(c.oid), pg_total_relation_size(c.oid)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname LIKE 'lab\_%' ESCAPE '\' AND c.relkind = 'r' ORDER BY 1;
        """);
    await using var sizeReader = await sizes.ExecuteReaderAsync();
    var relations = new List<object>();
    while (await sizeReader.ReadAsync()) relations.Add(new
    {
      name = sizeReader.GetString(0),
      heapBytes = sizeReader.GetInt64(1),
      indexBytes = sizeReader.GetInt64(2),
      totalBytes = sizeReader.GetInt64(3)
    });
    return new
    {
      revisions,
      wrongHeads,
      brokenLineage,
      unvalidatedConstraints,
      relations,
      pendingAndProvenanceBoundary = "fixture head/lineage/constraint check only; operational pending/provenance audit is not performed"
    };
  }

  static void DiagnosticSelfTest()
  {
    Require(IsReadQuery("SELECT 1;") && !IsReadQuery("DELETE FROM x") && !IsReadQuery("SELECT 1; DELETE FROM x"));
    using var document = JsonDocument.Parse("""
        {"Node Type":"Index Scan","Actual Rows":2,"Shared Read Blocks":3,"Filter":"private-value",
         "Plans":[{"Node Type":"Seq Scan","Actual Rows":4,"Output":["private-value"]}]}
        """);
    var sanitized = JsonSerializer.Serialize(SanitizePlan(document.RootElement));
    Require(!sanitized.Contains("private-value", StringComparison.Ordinal) && !sanitized.Contains("Filter", StringComparison.Ordinal) &&
        sanitized.Contains("Shared Read Blocks", StringComparison.Ordinal) && sanitized.Contains("Seq Scan", StringComparison.Ordinal));
    Console.WriteLine("S08 diagnostic: read-query guard and recursive plan redaction checks passed.");
  }
}
