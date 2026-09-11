using System.Diagnostics;
using System.Text.Json;

static partial class Benchmark
{
  static async Task ColdSelfTestAsync()
  {
    var fixture = new ColdFixture(1, 50, 10,
        new() { ["11111111-1111-4111-8111-111111111111"] = "22222222-2222-4222-8222-222222222222" });
    var request = new ColdRequest(Guid.NewGuid(), "service_accounts", fixture);
    ValidateColdRequest(request);
    Require(ColdPercentile([], .95) is null && ColdPercentile(Enumerable.Range(1, 10).Select(x => (double)x), .95) == 10);
    var ready = new ColdReady(request.TrialUid, request.Route, FixtureHash(fixture), 42, DateTime.UnixEpoch, 0, 0);
    ValidateReady(ready, request, 42, DateTime.UnixEpoch);
    foreach (var invalid in new[] { ready with { TrialUid = Guid.NewGuid() }, ready with { Route = "http_accounts" },
        ready with { FixtureSha256 = new string('0', 64) }, ready with { ProcessId = 43 },
        ready with { StartTimeUtc = DateTime.UnixEpoch.AddSeconds(1) }, ready with { PriorCommands = 1 },
        ready with { PriorOperations = 1 } })
      Reject(() => ValidateReady(invalid, request, 42, DateTime.UnixEpoch));
    var result = new ColdResult(request.TrialUid, "passed", 10, 14, 1024, new(1, 0, 0));
    ValidateResult(result, request);
    foreach (var invalid in new[] { result with { TrialUid = Guid.NewGuid() }, result with { RequestMs = double.NaN },
        result with { RequestMs = double.PositiveInfinity }, result with { RequestMs = -1 },
        result with { Commands = 0 }, result with { AllocatedBytes = -1 }, result with { Output = new(2, 0, 0) },
        result with { Output = new(1, 10, 0) }, result with { Output = new(1, 0, 1) } })
      Reject(() => ValidateResult(invalid, request));
    Reject(() => ValidateColdRequest(request with { TrialUid = Guid.Empty }));
    Reject(() => ValidateColdRequest(request with { Route = "unsupported" }));
    Reject(() => ValidateColdRequest(request with { Fixture = fixture with { Accounts = 10 } }));
    Reject(() => ValidateColdRequest(request with { Fixture = fixture with { Roster = 200 } }));
    foreach (var cell in FullCells)
      foreach (var route in ColdRoutes)
      {
        var expanded = request with
        {
          Route = route,
          Fixture = new(cell.Accounts, cell.Roster, cell.History,
            Enumerable.Range(0, cell.Accounts).ToDictionary(_ => Guid.NewGuid().ToString(), _ => Guid.NewGuid().ToString()))
        };
        ValidateColdRequest(expanded);
        var http = route.StartsWith("http_", StringComparison.Ordinal);
        var objects = route is "service_workspace" or "service_export" or "service_history" ? 1 : cell.Accounts;
        ValidateResult(result with
        {
          Output = new(objects, http ? 100 : 0,
            !http ? 0 : route == "http_accounts" ? 1 : 1 + cell.Accounts)
        }, expanded);
      }
    Reject(() => JsonSerializer.Deserialize<ColdReady>("{}", ProtocolJson));
    Reject(() => JsonSerializer.Deserialize<ColdReady>(JsonSerializer.Serialize(ready, ProtocolJson)
        .Replace("\"priorCommands\":0", "\"unexpected\":0", StringComparison.Ordinal), ProtocolJson));

    // Real process/pipe/lifetime checks, but no PostgreSQL, HTTP, fixture seeding or timing threshold gate.
    var samples = new List<ColdSample>();
    foreach (var mode in new[] { "success", "success", "early_exit", "bad_ready", "warm_ready", "bad_result",
        "failed_exit", "extra_result", "failed_result", "timeout_result", "request_timeout", "startup_timeout" })
    {
      var sample = await RunColdTrialAsync(request with { TrialUid = Guid.NewGuid() }, samples.Count, mode,
          startupTimeout: mode == "startup_timeout" ? TimeSpan.FromSeconds(2) : null,
          requestTimeout: mode == "request_timeout" ? TimeSpan.FromMilliseconds(100) : null);
      samples.Add(sample);
      Require(sample.CleanupVerified);
      Require(sample.Status == (mode == "success" ? "passed" :
          mode.EndsWith("timeout", StringComparison.Ordinal) || mode == "timeout_result" ? "timeout" : "failed"));
      Require(sample.FailureStage == (mode == "success" ? null :
          mode is "early_exit" or "bad_ready" or "warm_ready" or "startup_timeout" ? "startup" :
          mode is "failed_exit" or "extra_result" ? "exit" : "first_request"));
    }
    Require(samples.Take(2).Select(row => (row.ProcessId, row.ProcessStartUtc)).Distinct().Count() == 2);
    Require(samples.Take(2).All(row => row.StartupMs >= 0 && row.Result?.RequestMs == 10 && row.ExitCode == 0));
    Require(samples.Count(row => row.Status == "passed") == 2 && samples.Count(row => row.Status == "timeout") == 3);
    Require(JsonSerializer.Serialize(samples, Json).Length > 0);
    Console.WriteLine("S08 cold: identity/zero-pre-read/metrics/strict-protocol checks and 12 DB-free subprocess trials passed.");
  }

  static void Reject(Action action)
  {
    var rejected = false;
    try { action(); }
    catch (Exception) { rejected = true; }
    Require(rejected);
  }

  static async Task<int> RunColdProbeAsync(string mode)
  {
    Require(new[] { "success", "early_exit", "bad_ready", "warm_ready", "bad_result", "failed_exit",
        "extra_result", "failed_result", "timeout_result", "request_timeout", "startup_timeout" }.Contains(mode));
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    var request = await ReadProtocolAsync<ColdRequest>(Console.In, deadline.Token);
    ValidateColdRequest(request);
    if (mode == "early_exit") return 2;
    if (mode == "startup_timeout") await Task.Delay(Timeout.Infinite, deadline.Token);
    using var identity = Process.GetCurrentProcess();
    var ready = new ColdReady(mode == "bad_ready" ? Guid.NewGuid() : request.TrialUid, request.Route,
        FixtureHash(request.Fixture), identity.Id, identity.StartTime.ToUniversalTime(), mode == "warm_ready" ? 1 : 0, 0);
    await Console.Out.WriteLineAsync(JsonSerializer.Serialize(ready, ProtocolJson));
    Require(await Console.In.ReadLineAsync(deadline.Token) == "GO");
    if (mode == "request_timeout") await Task.Delay(Timeout.Infinite, deadline.Token);
    var status = mode == "timeout_result" ? "timeout" : mode == "failed_result" ? "failed" : "passed";
    var result = new ColdResult(request.TrialUid, status, mode == "bad_result" ? -1 : 10, 14, 1024,
        status == "passed" ? new(1, 0, 0) : null);
    await Console.Out.WriteLineAsync(JsonSerializer.Serialize(result, ProtocolJson));
    if (mode == "extra_result") await Console.Out.WriteLineAsync(JsonSerializer.Serialize(result, ProtocolJson));
    return mode == "failed_exit" ? 2 : status == "passed" ? 0 : 1;
  }
}
