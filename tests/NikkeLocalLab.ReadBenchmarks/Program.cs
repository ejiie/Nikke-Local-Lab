using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.Admin.Api;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.PostgreSql.IntegrationTests;
using Npgsql;

// Explicit local measurement executable, not a unit test or product entry point.
// The lifecycle wrapper alone supplies a newly-created disposable DB and output root.
try { return await Benchmark.RunAsync(args); }
catch (Exception exception)
{
  var failure = exception.GetBaseException();
  var frame = new StackTrace(failure, true).GetFrames().FirstOrDefault(item =>
      item.GetFileName()?.EndsWith("ReadBenchmarks\\Program.cs", StringComparison.Ordinal) == true);
  Console.Error.WriteLine($"s08_measurement_failed:{failure.GetType().Name}:line_{frame?.GetFileLineNumber()}");
  if (failure is ProfileManagementException controlled) Console.Error.WriteLine(controlled.Code);
  if (System.Text.RegularExpressions.Regex.IsMatch(failure.Message, "^s08_assertion_line_[0-9]+$")) Console.Error.WriteLine(failure.Message);
  return 1;
}

static class Benchmark
{
  static readonly DateTimeOffset Instant = new(2026, 8, 20, 1, 0, 0, TimeSpan.Zero);
  static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
  static readonly Type Fixture = typeof(PostgreSqlLocalGameStateTests);
  static object Invoke(string name, params object?[] arguments) => Fixture.GetMethod(name,
      BindingFlags.NonPublic | BindingFlags.Static)!.Invoke(null, arguments)!;
  static async Task<object> InvokeAsync(string name, params object?[] arguments)
  {
    var task = (Task)Invoke(name, arguments); await task;
    return task.GetType().GetProperty("Result")?.GetValue(task) ?? new object();
  }
  static void Require(bool value, [CallerLineNumber] int line = 0)
  { if (!value) throw new InvalidOperationException($"s08_assertion_line_{line}"); }

  public static async Task<int> RunAsync(string[] args)
  {
    if (args.SequenceEqual(new[] { "--self-test" }))
    {
      Require(Percentile(Enumerable.Range(1, 20).Select(value => (double)value), .95) == 19);
      Require(Percentile(new[] { 3d, 1d, 2d }, .5) == 2);
      using var counter = new CommandCounter();
      counter.Log(LogLevel.Information, new EventId(1, "CommandExecutionCompleted"), "unused", null, (_, _) => throw new Exception());
      counter.Log(LogLevel.Information, new EventId(2, "unrelated"), "unused", null, (_, _) => throw new Exception());
      Require(counter.Count == 1); counter.Reset(); Require(counter.Count == 0);
      Console.WriteLine("S08 source-only statistics/counter checks passed; no DB measurement executed.");
      return 0;
    }
    Require(args.Length == 0 || args.SequenceEqual(new[] { "--full" }) || args.SequenceEqual(new[] { "--smoke" }));
    var full = args.Contains("--full");
    var smoke = args.Contains("--smoke");
    var connection = new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB"));
    Require(connection.Host == "127.0.0.1" && connection.Port == 55432 &&
        connection.Database == "nikke_local_lab_lifecycle_test" && connection.Username == "nll_lifecycle_test" &&
        Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN") == "allow-phase1a-disposable-schema-reset");
    // The disposable cluster allows 40 connections. Keep 100-account fan-out
    // inside that boundary; pooling wait is part of the end-to-end observation.
    connection.MaxPoolSize = 32;
    var output = Path.GetFullPath(Environment.GetEnvironmentVariable("NLL_S08_OUTPUT") ?? throw new InvalidOperationException());
    Require(Directory.Exists(output));
    using var commands = new CommandCounter();
    await using var source = new NpgsqlDataSourceBuilder(connection.ConnectionString).UseLoggerFactory(commands).Build();
    // Validate the observer itself with known commands; never format/log command text or parameters.
    commands.Reset();
    await using (var probe = source.CreateCommand("SELECT 1")) await probe.ExecuteScalarAsync();
    Require(commands.Count == 1);
    var fullCells = new[] { (1, 50, 10), (10, 50, 10), (50, 50, 10), (100, 50, 10),
        (10, 5, 10), (10, 200, 10), (10, 50, 1), (10, 50, 100) };
    var cells = smoke ? new[] { (1, 5, 1) } : full ? fullCells : fullCells.Take(2).ToArray();
    var completed = new List<object>();
    foreach (var (accounts, roster, history) in cells)
    {
      Console.WriteLine($"S08 fixture: accounts={accounts}, roster={roster}, history={history}");
      await InvokeAsync("ResetAndMigrateAsync", source);
      var catalogs = await InvokeAsync("PublishCatalogFixtureAsync", source, roster);
      var profile = (LocalAccountProfileWrite)Invoke("CreateSyntheticProfileWithOwnedCube", catalogs, null);
      Require(profile.Builds.Count == roster);
      var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
      var service = (PostgreSqlProfileManagementService)Invoke("Service", source);
      var manifest = await service.EnsureBuiltInFeatureManifestAsync();
      var expected = new Dictionary<EntityUid, EntityUid>();
      for (var account = 0; account < accounts; account++)
      {
        var saved = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), profile, Instant,
            $"synthetic-{account:D3}"));
        for (var revision = 1; revision < history; revision++)
          saved = await store.SaveAsync(new SaveLocalAccountProfileCommand(EntityUid.New(), saved.AccountUid,
              saved.ProfileTemplateRevisionUid,
              (LocalAccountProfileWrite)Invoke("CreateSyntheticProfileWithOwnedCube", catalogs, 200 + revision),
              Instant.AddSeconds(revision)));
        expected.Add(saved.AccountUid, saved.ProfileTemplateRevisionUid);
        await service.InitializeLocalStateAsync(new InitializeLocalStateCommand(EntityUid.New(), saved.AccountUid,
            saved.ProfileTemplateRevisionUid, manifest.ManifestUid, manifest.ContentSha256, $"synthetic-{account:D3}",
            100, null, null, profile.Builds.First().CharacterUid, null, [new("credit", 100), new("jewel", 100)]));
      }
      var first = expected.Keys.First();
      var listed = await service.ListAccountsAsync();
      Require(listed.Count == accounts && listed.All(row => expected[row.AccountUid] == row.ProfileRevision.RevisionUid));
      Require((await store.GetCurrentAsync(first))!.Profile.Builds.Count == roster);
      // History row count is checked directly, outside timing; do not infer it from requested fixture size.
      await using (var count = source.CreateCommand("SELECT count(*) FROM lab_profile.profile_template_revision"))
        Require(Convert.ToInt64(await count.ExecuteScalarAsync()) == accounts * history);

      string? code = null;
      await using var app = AdminApiHost.Build([], new AdminApiHostOptions
      {
        Port = 0,
        BootstrapCodeSink = value => code = value,
        ConfigureServices = services => services.AddSingleton<IProfileManagementService>(service)
      });
      await app.StartAsync();
      var address = app.Urls.Single(value => value.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
      using var client = new HttpClient(new HttpClientHandler
      {
        UseProxy = false,
        CookieContainer = new CookieContainer(),
        AllowAutoRedirect = false
      })
      { BaseAddress = new Uri(address), Timeout = TimeSpan.FromSeconds(30) };
      using (var login = new HttpRequestMessage(HttpMethod.Post, "/admin-auth/v1/bootstrap"))
      {
        login.Headers.Add("Origin", address); login.Content = JsonContent.Create(new { code });
        using var response = await client.SendAsync(login); response.EnsureSuccessStatusCode();
      }
      code = null;
      var operations = new Dictionary<string, Func<Task<Observation>>>
      {
        ["service_accounts"] = async () =>
        {
          var rows = await service.ListAccountsAsync();
          Require(rows.Count == accounts && rows.All(row => expected[row.AccountUid] == row.ProfileRevision.RevisionUid));
          return new(rows.Count, 0, 0);
        },
        ["http_accounts"] = async () => await ReadHttpAsync(client, "/admin-api/v1/accounts", accounts),
        // Mirrors editor list+Promise.all request graph; excludes DOM/rendering and WebView scheduling.
        ["http_accounts_and_lobbies"] = async () =>
        {
          var listing = await ReadHttpAsync(client, "/admin-api/v1/accounts", accounts);
          var lobbies = await Task.WhenAll(expected.Keys.Select(uid => ReadHttpAsync(client,
              $"/admin-api/v1/accounts/{uid}/lobby", null)));
          return new(accounts, listing.Bytes + lobbies.Sum(row => row.Bytes), 1 + accounts);
        },
        ["service_workspace"] = async () =>
        {
          var row = await service.GetAccountWorkspaceAsync(first);
          Require(row?.BaseRevisions.ProfileRevisionUid == expected[first]); return new(1, 0, 0);
        },
        ["service_export"] = async () =>
        {
          var row = await service.ExportRuntimeProjectionCandidateAsync(first);
          Require(row is not null); return new(1, 0, 0);
        },
        ["service_history"] = async () =>
        {
          var row = await service.GetAccountRevisionHistoryAsync(first);
          Require(row is not null); return new(1, 0, 0);
        }
      };
      var results = new List<object>();
      foreach (var (name, operation) in operations)
      {
        for (var warm = 0; warm < (smoke ? 1 : 5); warm++) await operation();
        var samples = new List<Sample>();
        for (var group = 0; group < (smoke ? 1 : 3); group++)
          for (var iteration = 0; iteration < (smoke ? 2 : 50); iteration++)
          {
            commands.Reset();
            var allocation = GC.GetTotalAllocatedBytes(false);
            var start = Stopwatch.GetTimestamp();
            var observation = await operation();
            samples.Add(new(group, iteration, Stopwatch.GetElapsedTime(start).TotalMilliseconds,
                commands.Count, GC.GetTotalAllocatedBytes(false) - allocation, observation));
          }
        var groups = samples.GroupBy(row => row.Group).Select(group => new
        {
          group = group.Key,
          p50Ms = Percentile(group.Select(row => row.Ms), .5),
          p95Ms = Percentile(group.Select(row => row.Ms), .95),
          minCommands = group.Min(row => row.Commands),
          maxCommands = group.Max(row => row.Commands)
        }).ToArray();
        results.Add(new { name, samples, groups });
        Console.WriteLine($"S08 measured: {accounts}/{roster}/{history} {name}, p50={groups[0].p50Ms:F2}ms, commands={groups[0].minCommands}");
      }
      await app.StopAsync();
      var cell = new { accounts, roster, history, results, correctness = "fixture_and_read_revision_checks_passed" };
      completed.Add(cell);
      await File.WriteAllTextAsync(Path.Combine(output, $"s08-{accounts}-{roster}-{history}.json"), JsonSerializer.Serialize(cell, Json));
      // Stop at a completed cell without terminating the process/losing its cleanup receipt.
      if (File.Exists(Path.Combine(output, "stop-after-cell"))) break;
    }
    await File.WriteAllTextAsync(Path.Combine(output, "s08-summary.json"), JsonSerializer.Serialize(new
    {
      contractId = "nll/synthetic-read-baseline/v1",
      status = completed.Count == cells.Length ? "passed_selected_scope" : "stopped_after_cell",
      scope = smoke ? "smoke_not_a_baseline" : full ? "full_warm_matrix" : "accounts_1_and_10_warm",
      plannedCells = cells.Length,
      cells = completed,
      runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
      os = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
      instrumentation = "Npgsql completed command events; not SQL statement or disk read count",
      maxPoolSize = connection.MaxPoolSize,
      processColdMeasured = false,
      domRenderingMeasured = false,
      diskReadBytesMeasured = false,
      originalClientExecuted = false,
      operatingDatabaseTouched = false,
      fixtureIdentity = "synthetic semantic values; per-run random UUIDs, no original identifiers",
      errors = 0,
      completedAtUtc = DateTimeOffset.UtcNow
    }, Json));
    return 0;
  }

  static async Task<Observation> ReadHttpAsync(HttpClient client, string path, int? count)
  {
    using var response = await client.GetAsync(path); response.EnsureSuccessStatusCode();
    var bytes = await response.Content.ReadAsByteArrayAsync();
    using var json = JsonDocument.Parse(bytes);
    if (count is { } expected) Require(json.RootElement.GetArrayLength() == expected);
    return new(count ?? 1, bytes.Length, 1);
  }
  static double Percentile(IEnumerable<double> values, double percentile)
  {
    var sorted = values.Order().ToArray(); return sorted[(int)Math.Ceiling(percentile * sorted.Length) - 1];
  }
  sealed record Observation(int ReturnedObjects, long Bytes, int HttpRequests);
  sealed record Sample(int Group, int Iteration, double Ms, long Commands, long AllocatedBytes, Observation Output);
}

sealed class CommandCounter : ILoggerFactory, ILogger
{
  long count;
  public long Count => Interlocked.Read(ref count);
  public void Reset() => Interlocked.Exchange(ref count, 0);
  public ILogger CreateLogger(string categoryName) => this;
  public void AddProvider(ILoggerProvider provider) => throw new NotSupportedException();
  public void Dispose() { }
  public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
  public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;
  public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
      Func<TState, Exception?, string> formatter)
  {
    if (eventId.Name is "CommandExecutionCompleted" or "CommandExecutionCompletedWithParameters") Interlocked.Increment(ref count);
  }
}
