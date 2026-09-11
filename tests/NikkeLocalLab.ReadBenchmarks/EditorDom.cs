using System.Diagnostics;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using NikkeLocalLab.Admin.Api;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

static partial class Benchmark
{
  static async Task<object> MeasureDomCellAsync(string output, int accounts, int roster, int history,
      Dictionary<EntityUid, EntityUid> expected)
  {
    var connection = DisposableConnection();
    connection.Options = "-c default_transaction_read_only=on";
    using var counter = new CommandCounter();
    await using var source = new NpgsqlDataSourceBuilder(connection.ConnectionString).UseLoggerFactory(counter).Build();
    var service = (PostgreSqlProfileManagementService)Invoke("Service", source);
    var samples = new List<object>();
    for (var iteration = 0; iteration < 3; iteration++)
    {
      string? code = null;
      await using var app = AdminApiHost.Build([], new AdminApiHostOptions
      {
        Port = 0,
        BootstrapCodeSink = value => code = value,
        ConfigureServices = services => { services.AddSingleton<IProfileManagementService>(service); services.AddLogging(log => log.ClearProviders()); }
      });
      await app.StartAsync();
      var address = app.Urls.Single(value => value.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
      var startInfo = new ProcessStartInfo(Environment.GetEnvironmentVariable("NLL_S08_NODE")!)
      { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
      startInfo.ArgumentList.Add(Environment.GetEnvironmentVariable("NLL_S08_DOM_SCRIPT")!);
      foreach (var key in startInfo.Environment.Keys.Where(key => key.StartsWith("NIKKE_", StringComparison.Ordinal) || key == "PGPASSWORD").ToArray())
        startInfo.Environment.Remove(key);
      using var process = new Process { StartInfo = startInfo };
      Require(process.Start());
      var drain = DrainAsync(process.StandardError);
      JsonElement result = default;
      var status = "failed";
      var cleanup = false;
      long commands = 0;
      try
      {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new
        {
          address,
          code,
          accountUids = expected.Keys.Select(uid => uid.ToString()).ToArray()
        }, ProtocolJson));
        code = null;
        counter.Reset();
        Require(await process.StandardOutput.ReadLineAsync(deadline.Token) == "READY");
        Require(counter.Count == 0); // Browser navigation/bootstrap performs no account reads.
        await process.StandardInput.WriteLineAsync("GO");
        using var document = await ReadProtocolAsync<JsonDocument>(process.StandardOutput, deadline.Token);
        result = document.RootElement.Clone();
        Require(result.GetProperty("status").GetString() == "passed" && result.GetProperty("accounts").GetInt32() == accounts);
        commands = counter.Count;
        Require(commands == 1 + (iteration == 0 ? 15L : 2L) * accounts);
        await process.WaitForExitAsync(deadline.Token);
        Require(process.ExitCode == 0 && await process.StandardOutput.ReadLineAsync(deadline.Token) is null);
        status = "passed";
      }
      catch (OperationCanceledException) { status = "timeout"; }
      catch (Exception) { status = "failed"; }
      finally
      {
        // The Node helper owns only its freshly created headless browser tree.
        // Do not touch pre-existing browser, desktop, PostgreSQL or game processes.
        if (!process.HasExited) process.Kill(entireProcessTree: true);
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
        await drain.WaitAsync(TimeSpan.FromSeconds(5));
        cleanup = process.HasExited && result.ValueKind == JsonValueKind.Object &&
            result.TryGetProperty("cleanupVerified", out var proof) && proof.GetBoolean();
        await app.StopAsync();
      }
      var sample = new
      {
        iteration,
        status,
        commands,
        cleanupVerified = cleanup,
        result = result.ValueKind == JsonValueKind.Undefined ? (JsonElement?)null : result
      };
      samples.Add(sample);
      await File.WriteAllTextAsync(Path.Combine(output, $"s08-dom-{accounts}-{roster}-{history}-{iteration}.json"), JsonSerializer.Serialize(sample, Json));
      Require(status == "passed" && cleanup);
      Console.WriteLine($"S08 DOM: {accounts}/{roster}/{history} {iteration + 1}/3 passed");
    }
    return new
    {
      accounts,
      roster,
      history,
      samples,
      boundary = "fresh headless Edge profiles; real checked-in editor refresh handler/DOM and isolated AdminApiHost; 3 trials, no latency threshold",
      excluded = "browser/host startup, full login workflow and presentation catalog, installed WebView2 scheduling, original game UI"
    };
  }
}
