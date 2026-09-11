using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.Admin.Api;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

static partial class Benchmark
{
  static readonly string[] ColdRoutes = ["service_accounts", "http_accounts", "http_accounts_and_lobbies"];
  static readonly JsonSerializerOptions ProtocolJson = new(JsonSerializerDefaults.Web)
  { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow };

  sealed record ColdFixture(int Accounts, int Roster, int History, Dictionary<string, string> Revisions);
  sealed record ColdRequest(Guid TrialUid, string Route, ColdFixture Fixture);
  sealed record ColdReady(Guid TrialUid, string Route, string FixtureSha256, int ProcessId,
      DateTime StartTimeUtc, [property: JsonRequired] long PriorCommands, [property: JsonRequired] int PriorOperations);
  sealed record ColdResult(Guid TrialUid, string Status, [property: JsonRequired] double RequestMs,
      [property: JsonRequired] long Commands, [property: JsonRequired] long AllocatedBytes, Observation? Output);
  sealed record ColdSample(int Iteration, ColdRequest Request, string FixtureSha256, int? ProcessId,
      DateTime? ProcessStartUtc, ColdReady? Ready, double? StartupMs, ColdResult? Result, double ParentWallMs,
      string Status, string? FailureStage, int? ExitCode, bool CleanupVerified);
  sealed record ColdCell(int Accounts, int Roster, int History, string FixtureSha256,
      IReadOnlyList<ColdSample> Samples, object[] Results, int Errors);

  static string FixtureHash(ColdFixture fixture) => Convert.ToHexString(SHA256.HashData(
      Encoding.UTF8.GetBytes(JsonSerializer.Serialize(fixture, ProtocolJson)))).ToLowerInvariant();

  static async Task<ColdCell> MeasureColdCellAsync(string output, int accounts, int roster, int history,
      Dictionary<EntityUid, EntityUid> expected, int repetitions)
  {
    // Fixture creation, verification and observer calibration belong only to this parent.
    // Every route/iteration starts a new process, service, data source and connection pool.
    var fixture = new ColdFixture(accounts, roster, history,
        expected.ToDictionary(row => row.Key.ToString(), row => row.Value.ToString()));
    var samples = new List<ColdSample>();
    foreach (var route in ColdRoutes)
      for (var iteration = 0; iteration < repetitions; iteration++)
      {
        var request = new ColdRequest(Guid.NewGuid(), route, fixture);
        var sample = await RunColdTrialAsync(request, iteration);
        samples.Add(sample);
        await File.WriteAllTextAsync(Path.Combine(output, $"s08-cold-{accounts}-{roster}-{history}-{route}-{iteration:D2}.json"),
            JsonSerializer.Serialize(sample, Json));
        Console.WriteLine($"S08 cold: {accounts}/{roster}/{history} {route} {iteration + 1}/{repetitions} {sample.Status}");
        // Never continue resetting the fixture if ownership/termination could not be proven.
        Require(sample.CleanupVerified);
      }
    var results = ColdRoutes.Select(route =>
    {
      var attempted = samples.Where(row => row.Request.Route == route).ToArray();
      var successful = attempted.Where(row => row.Status == "passed").ToArray();
      return (object)new
      {
        name = route,
        attempts = attempted.Length,
        successes = successful.Length,
        errors = attempted.Count(row => row.Status != "passed"),
        timeouts = attempted.Count(row => row.Status == "timeout" || row.Result?.Status == "timeout"),
        statisticsPopulation = "successful_attempts_only_all_failures_preserved_in_samples",
        startupP50Ms = ColdPercentile(successful.Select(row => row.StartupMs!.Value), .5),
        startupP95Ms = ColdPercentile(successful.Select(row => row.StartupMs!.Value), .95),
        requestP50Ms = ColdPercentile(successful.Select(row => row.Result!.RequestMs), .5),
        requestP95Ms = ColdPercentile(successful.Select(row => row.Result!.RequestMs), .95)
      };
    }).ToArray();
    var cell = new ColdCell(accounts, roster, history, FixtureHash(fixture), samples, results,
        samples.Count(row => row.Status != "passed"));
    await File.WriteAllTextAsync(Path.Combine(output, $"s08-cold-{accounts}-{roster}-{history}.json"),
        JsonSerializer.Serialize(cell, Json));
    return cell;
  }

  static double? ColdPercentile(IEnumerable<double> values, double percentile)
  {
    var samples = values.ToArray();
    return samples.Length == 0 ? null : Percentile(samples, percentile);
  }

  static ProcessStartInfo ColdStartInfo(string? probe)
  {
    var executable = Environment.ProcessPath ?? throw new InvalidOperationException();
    var info = new ProcessStartInfo(executable)
    {
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardInput = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true
    };
    if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
      info.ArgumentList.Add(typeof(Benchmark).Assembly.Location);
    info.ArgumentList.Add(probe is null ? "--cold-child" : "--cold-probe");
    if (probe is not null)
    {
      info.ArgumentList.Add(probe);
      // CI probes must not touch a DB even when launched from a developer's configured shell.
      info.Environment.Remove("NIKKE_LAB_TEST_DB");
      info.Environment.Remove("NIKKE_LAB_TEST_RESET_TOKEN");
    }
    // Connection/password travel only through the inherited environment, never arguments or JSON.
    return info;
  }

  static async Task<ColdSample> RunColdTrialAsync(ColdRequest request, int iteration, string? probe = null,
      TimeSpan? startupTimeout = null, TimeSpan? requestTimeout = null)
  {
    using var process = new Process { StartInfo = ColdStartInfo(probe) };
    var start = Stopwatch.GetTimestamp();
    int? processId = null, exitCode = null;
    DateTime? processStart = null;
    ColdReady? ready = null;
    double? startupMs = null;
    ColdResult? result = null;
    var stage = "start";
    var status = "failed";
    var cleanup = true;
    var started = false;
    Task? stderr = null;
    try
    {
      Require(process.Start());
      started = true;
      cleanup = false;
      processId = process.Id;
      processStart = process.StartTime.ToUniversalTime();
      stderr = DrainAsync(process.StandardError);
      stage = "startup";
      using var startupDeadline = new CancellationTokenSource(startupTimeout ?? TimeSpan.FromSeconds(60));
      await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request, ProtocolJson).AsMemory(), startupDeadline.Token);
      ready = await ReadProtocolAsync<ColdReady>(process.StandardOutput, startupDeadline.Token);
      ValidateReady(ready, request, processId.Value, processStart.Value);
      startupMs = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
      stage = "first_request";
      using var requestDeadline = new CancellationTokenSource(requestTimeout ?? TimeSpan.FromSeconds(60));
      await process.StandardInput.WriteLineAsync("GO".AsMemory(), requestDeadline.Token);
      result = await ReadProtocolAsync<ColdResult>(process.StandardOutput, requestDeadline.Token);
      ValidateResult(result, request);
      stage = "exit";
      using var exitDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
      // No additional operation/result is allowed. EOF plus exit zero completes one trial.
      Require(await process.StandardOutput.ReadLineAsync(exitDeadline.Token) is null);
      await process.WaitForExitAsync(exitDeadline.Token);
      exitCode = process.ExitCode;
      Require(exitCode == (result.Status == "passed" ? 0 : 1));
      status = result.Status;
      if (status != "passed") stage = "first_request";
    }
    catch (OperationCanceledException) { status = "timeout"; }
    catch (Exception) { status = "failed"; } // Do not echo child output, exception text, paths or DB values.
    finally
    {
      if (started)
      {
        try
        {
          // Only the exact Process handle created above. This executable starts no descendants.
          if (!process.HasExited) process.Kill();
          await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
          exitCode = process.ExitCode;
          cleanup = process.HasExited;
          if (stderr is not null) await stderr.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (Exception) { cleanup = false; status = "failed"; stage = "cleanup"; }
      }
    }
    return new(iteration, request, FixtureHash(request.Fixture), processId, processStart, ready, startupMs, result,
        Stopwatch.GetElapsedTime(start).TotalMilliseconds, status, status == "passed" ? null : stage, exitCode, cleanup);
  }

  static async Task DrainAsync(StreamReader reader)
  {
    // Bounded memory, no raw stderr persistence (it may contain framework diagnostics).
    var buffer = new char[1024];
    while (await reader.ReadAsync(buffer) != 0) { }
  }

  static async Task<T> ReadProtocolAsync<T>(TextReader reader, CancellationToken token) where T : class
  {
    var line = await reader.ReadLineAsync(token);
    Require(line is { Length: > 0 and <= 16384 });
    return JsonSerializer.Deserialize<T>(line!, ProtocolJson) ?? throw new InvalidOperationException();
  }

  static void ValidateReady(ColdReady ready, ColdRequest request, int processId, DateTime startTime)
  {
    Require(ready.TrialUid == request.TrialUid && ready.Route == request.Route &&
        ready.FixtureSha256 == FixtureHash(request.Fixture) && ready.ProcessId == processId &&
        ready.StartTimeUtc == startTime && ready.PriorCommands == 0 && ready.PriorOperations == 0);
  }

  static void ValidateResult(ColdResult result, ColdRequest request)
  {
    Require(result.TrialUid == request.TrialUid && double.IsFinite(result.RequestMs) && result.RequestMs >= 0 &&
        result.Commands >= 0 && result.AllocatedBytes >= 0 && result.Status is "passed" or "failed" or "timeout");
    if (result.Status != "passed")
    {
      Require(result.Output is null);
      return;
    }
    Require(result.Commands > 0 && result.Output is not null);
    var output = result.Output!;
    Require(output.ReturnedObjects == request.Fixture.Accounts);
    var httpRequests = request.Route == "service_accounts" ? 0 :
        request.Route == "http_accounts" ? 1 : 1 + request.Fixture.Accounts;
    Require(output.HttpRequests == httpRequests && (httpRequests == 0 ? output.Bytes == 0 : output.Bytes > 0));
  }

  static void ValidateColdRequest(ColdRequest request)
  {
    Require(request.TrialUid != Guid.Empty && ColdRoutes.Contains(request.Route) && request.Fixture is not null);
    var fixture = request.Fixture!;
    Require((fixture.Accounts is 1 or 10 && fixture.Roster == 50 && fixture.History == 10) ||
        (fixture.Accounts == 1 && fixture.Roster == 5 && fixture.History == 1));
    Require(fixture.Revisions is not null && fixture.Revisions.Count == fixture.Accounts &&
        fixture.Revisions.All(row => Guid.TryParseExact(row.Key, "D", out var uid) && uid != Guid.Empty &&
            Guid.TryParseExact(row.Value, "D", out var revision) && revision != Guid.Empty));
  }

  static async Task<int> RunColdChildAsync()
  {
    var protocol = Console.Out;
    Console.SetOut(TextWriter.Null);
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
    var request = await ReadProtocolAsync<ColdRequest>(Console.In, deadline.Token);
    ValidateColdRequest(request);
    var connection = DisposableConnection();
    // No SELECT 1, migrate, seed, count, preload or profile read in the child before GO.
    connection.Options = "-c default_transaction_read_only=on";
    using var commands = new CommandCounter();
    await using var source = new NpgsqlDataSourceBuilder(connection.ConnectionString).UseLoggerFactory(commands).Build();
    var service = (PostgreSqlProfileManagementService)Invoke("Service", source);
    Microsoft.AspNetCore.Builder.WebApplication? app = null;
    HttpClient? client = null;
    var exitCode = 0;
    try
    {
      if (request.Route != "service_accounts")
      {
        string? code = null;
        app = AdminApiHost.Build([], new AdminApiHostOptions
        {
          Port = 0,
          BootstrapCodeSink = value => code = value,
          ConfigureServices = services =>
          {
            services.AddSingleton<IProfileManagementService>(service);
            services.AddLogging(logging => logging.ClearProviders());
          }
        });
        await app.StartAsync(deadline.Token);
        var address = app.Urls.Single(value => value.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
        client = new HttpClient(new HttpClientHandler
        { UseProxy = false, CookieContainer = new CookieContainer(), AllowAutoRedirect = false })
        { BaseAddress = new Uri(address), Timeout = TimeSpan.FromSeconds(30) };
        using var login = new HttpRequestMessage(HttpMethod.Post, "/admin-auth/v1/bootstrap");
        login.Headers.Add("Origin", address);
        login.Content = JsonContent.Create(new { code });
        using var response = await client.SendAsync(login, deadline.Token);
        response.EnsureSuccessStatusCode();
        code = null;
      }
      using var identity = Process.GetCurrentProcess();
      Require(commands.Count == 0);
      await protocol.WriteLineAsync(JsonSerializer.Serialize(new ColdReady(request.TrialUid, request.Route,
          FixtureHash(request.Fixture), identity.Id, identity.StartTime.ToUniversalTime(), commands.Count, 0), ProtocolJson));
      Require(await Console.In.ReadLineAsync(deadline.Token) == "GO");
      var allocation = GC.GetTotalAllocatedBytes(false);
      var start = Stopwatch.GetTimestamp();
      Observation? observation = null;
      var status = "passed";
      try { observation = await ExecuteColdOperationAsync(request, service, client); }
      catch (OperationCanceledException) { status = "timeout"; }
      catch (Exception) { status = "failed"; }
      var elapsed = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
      var result = new ColdResult(request.TrialUid, status, elapsed, commands.Count,
          GC.GetTotalAllocatedBytes(false) - allocation, observation);
      await protocol.WriteLineAsync(JsonSerializer.Serialize(result, ProtocolJson));
      exitCode = status == "passed" ? 0 : 1;
    }
    finally
    {
      client?.Dispose();
      if (app is not null)
      {
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { await app.StopAsync(stop.Token); }
        finally { await app.DisposeAsync(); }
      }
    }
    return exitCode;
  }

  static async Task<Observation> ExecuteColdOperationAsync(ColdRequest request,
      PostgreSqlProfileManagementService service, HttpClient? client)
  {
    if (request.Route == "service_accounts")
    {
      var rows = await service.ListAccountsAsync();
      Require(rows.Count == request.Fixture.Accounts && rows.All(row =>
          request.Fixture.Revisions[row.AccountUid.ToString()] == row.ProfileRevision.RevisionUid.ToString()));
      return new(rows.Count, 0, 0);
    }
    using var response = await client!.GetAsync("/admin-api/v1/accounts");
    response.EnsureSuccessStatusCode();
    var bytes = await response.Content.ReadAsByteArrayAsync();
    using var document = JsonDocument.Parse(bytes);
    var rowsJson = document.RootElement.EnumerateArray().ToArray();
    Require(rowsJson.Length == request.Fixture.Accounts);
    var uids = rowsJson.Select(row => row.GetProperty("accountUid").GetString()!).ToArray();
    Require(uids.Distinct().Count() == request.Fixture.Accounts && rowsJson.All(row =>
        request.Fixture.Revisions[row.GetProperty("accountUid").GetString()!] ==
        row.GetProperty("profileRevision").GetProperty("revisionUid").GetString()));
    if (request.Route == "http_accounts") return new(rowsJson.Length, bytes.Length, 1);
    // Fan-out is part of ONE first list+lobbies operation, not independent cold lobby samples.
    var lobbies = await Task.WhenAll(uids.Select(async uid =>
    {
      using var lobbyResponse = await client.GetAsync($"/admin-api/v1/accounts/{uid}/lobby");
      lobbyResponse.EnsureSuccessStatusCode();
      var body = await lobbyResponse.Content.ReadAsByteArrayAsync();
      using var lobby = JsonDocument.Parse(body);
      Require(lobby.RootElement.GetProperty("accountUid").GetString() == uid);
      return body.Length;
    }));
    return new(rowsJson.Length, bytes.Length + lobbies.Sum(value => (long)value), 1 + uids.Length);
  }
}
