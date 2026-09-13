using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;
using NikkeLocalLab.Phase3B2.LocalBootstrap;
using NikkeLocalLab.Phase3B2.UserValidation;

// Only the user-owned, elevated controller's non-breakaway Job may start this
// child. There is deliberately no agent, diagnostic or uncontained start mode.
if (args.Length != 6 || args[0] != "--user-start" ||
    !Guid.TryParseExact(args[1], "D", out var trial) || trial == Guid.Empty || args[1] != trial.ToString("D") ||
    !Guid.TryParseExact(args[2], "D", out var uid) || uid == Guid.Empty || args[2] != uid.ToString("D") || uid == trial ||
    args.Skip(3).Any(value => !UserValidationBootstrapPlan.IsHash(value))) return 64;
var childRoot = @"C:\NLL\Runtime\NativeFxUserValidationChild\" + uid;
if (Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory) != childRoot) return 64;
var jobName = "Local\\NLL.FxValidation." + uid.ToString("N");
using var job = Native.OpenJobObject(4, false, jobName);
if (job.IsInvalid || !Native.IsProcessInJob(new IntPtr(-1), job, out var member) || !member) return 64;
var token = ExecutionTokenObservation.Current();
if (token.Process.Token is not { Status: "observed", Token: { Elevated: 1, IntegrityRid: >= 12288 } } ||
    token.Thread.Status != "no_thread_token" || token.CompatRunAsInvoker) return 64;

var runRoot = @"C:\NLL\Staging\NativeFxUserValidation\" + trial + @"\runs\" + uid;
Process? server = null, bootstrap = null;
var drains = new List<Task<long>>();
var stage = "inputs";
var result = 1;
try
{
  UserValidationPinnedFiles.AssertNoReparse(runRoot);
  var bootstrapRoot = UserValidationBootstrapPlan.RuntimeParent + "\\" + uid;
  var bootstrapPath = bootstrapRoot + @"\bootstrap.private.json";
  using var bootstrapLease = Pinned(bootstrapPath, args[4], 1048576);
  var bytes = new byte[checked((int)bootstrapLease.Length)];
  bootstrapLease.ReadExactly(bytes);
  var plan = UserValidationBootstrapPlan.Parse(bytes);
  Require(plan.AssessmentUid == args[2] && plan.TrialUid == args[1] && plan.ParentPlanSha256 == args[3]);
  using var parentLease = Pinned(plan.ParentPlanPath, args[3], 1048576);
  using var parent = JsonDocument.Parse(parentLease);
  UserValidationLaunchEvidence.ValidateParent(plan, parent.RootElement);
  Require(parent.RootElement.GetProperty("runtimeStagingSha256").GetString() == args[5]);
  using var stageLease = Pinned(runRoot + @"\runtime-staging.receipt.json", args[5], 1048576);
  using var staging = JsonDocument.Parse(stageLease);
  var inputs = UserValidationProcessInputs.Bind(plan, staging.RootElement);
  foreach (var pin in inputs.ServerFiles.Concat(plan.RuntimeFiles))
    using (UserValidationPinnedFiles.Open(pin.Path, pin.Length, pin.Sha256, 536870912)) { }
  Require(UserValidationPinnedFiles.Inventory(inputs.ServerRoot, 128).SetEquals(inputs.ServerFiles.Select(p => p.Path)));
  var childPins = parent.RootElement.GetProperty("childFiles").EnumerateArray().ToArray();
  var names = new HashSet<string>(StringComparer.Ordinal);
  foreach (var pin in childPins)
  {
    var path = pin.GetProperty("path").GetString()!;
    Require(UserValidationBootstrapPlan.IsMember(path, childRoot) && names.Add(path));
    using (UserValidationPinnedFiles.Open(path, pin.GetProperty("length").GetInt64(), pin.GetProperty("sha256").GetString()!, 536870912)) { }
  }
  Require(childPins.Length == 4 && UserValidationPinnedFiles.Inventory(childRoot, 4).SetEquals(names));
  foreach (var suffix in new[] { ".exe", ".dll", ".deps.json", ".runtimeconfig.json" })
    Require(names.Contains(childRoot + @"\NikkeLocalLab.NativeFxUserValidationChild" + suffix));
  var accountPin = inputs.ServerFiles.Single(p => p.Path == inputs.ServerRoot + @"\db.json");
  ulong accountId;
  using (var seed = UserValidationPinnedFiles.Open(accountPin.Path, accountPin.Length, accountPin.Sha256, 33554432))
  using (var database = JsonDocument.Parse(seed)) accountId = UserValidationProcessInputs.ReadLocalAccountId(database.RootElement);
  // Marker creation is exclusively the reviewed outer controller's action.
  using (var armed = Marker("isolation.armed.json"))
  {
    RequireBinding(armed.RootElement, "nll/native-fx-user-validation-armed/v1");
    foreach (var field in new[] { "allProgramsBlocked", "rollbackPrepared", "systemChangesVerified",
        "managedServiceBaselineVerified", "managedDriverBaselineVerified", "protectedInputsUnchanged" })
      Require(armed.RootElement.GetProperty(field).GetBoolean());
  }
  Directory.CreateDirectory(inputs.ServerRoot + @"\scratch");
  Directory.CreateDirectory(runRoot + @"\scratch");
  using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(plan.DurationSeconds + 120));
  stage = "server_start";
  server = Start(inputs.ServerStart(accountId), "server");
  stage = "server_ready";
  var watch = Stopwatch.StartNew();
  while (!File.Exists(runRoot + @"\server.ready.json"))
  {
    Require(!server.HasExited && watch.Elapsed < TimeSpan.FromSeconds(60));
    await Task.Delay(100, timeout.Token);
  }
  using (var ready = Marker("server.ready.json"))
  {
    RequireBinding(ready.RootElement, "nll/native-fx-user-validation-server-ready/v1");
    Require(ready.RootElement.GetProperty("processId").GetInt32() == server.Id &&
        ready.RootElement.GetProperty("createdFileTime").GetInt64() == server.StartTime.ToUniversalTime().ToFileTimeUtc() &&
        ready.RootElement.GetProperty("loopbackListenersVerified").GetBoolean());
  }
  using (var isolation = Marker("isolation.ready.json"))
    UserValidationLaunchEvidence.ValidateIsolation(plan, args[4], isolation.RootElement, DateTimeOffset.UtcNow);
  Require(!server.HasExited);
  stage = "bootstrap_start";
  bootstrap = Start(inputs.BootstrapStart(args[4]), "bootstrap");
  stage = "bootstrap_wait";
  var bootstrapExit = bootstrap.WaitForExitAsync(timeout.Token);
  var serverExit = server.WaitForExitAsync(timeout.Token);
  Require(await Task.WhenAny(bootstrapExit, serverExit) == bootstrapExit);
  await bootstrapExit;
  Require(bootstrap.ExitCode == 0);
  result = 0;
}
catch
{
  // Never serialize exception messages, environment, account contents or tokens.
  Write("child-failure.json", new { contractId = "nll/native-fx-user-validation-child-failure/v1", stageCode = stage });
}
finally
{
  var ownedStopped = true;
  foreach (var process in new[] { bootstrap, server }) if (process is not null)
  {
    try { if (!process.HasExited) process.Kill(); if (!process.WaitForExit(10000)) ownedStopped = false; }
    catch { ownedStopped = false; }
    finally { process.Dispose(); }
  }
  try { await Task.WhenAll(drains).WaitAsync(TimeSpan.FromSeconds(5)); } catch { ownedStopped = false; }
  if (!ownedStopped) result = 1;
  Write("child-exit.json", new
  {
    contractId = "nll/native-fx-user-validation-child-exit/v1",
    assessmentUid = uid,
    trialUid = trial,
    executionOwnerCode = "user",
    exitCode = result,
    ownedProcessHandlesStopped = ownedStopped,
    cleanupRequired = true,
    nativeAdmission = "not_assessed",
    actualGameAcceptanceClaimed = false,
    logBytesDiscarded = drains.Where(t => t.IsCompletedSuccessfully).Sum(t => t.Result)
  });
}
return result;

FileStream Pinned(string path, string hash, long limit) =>
    UserValidationPinnedFiles.Open(path, new FileInfo(path).Length, hash, limit);
JsonDocument Marker(string name)
{
  var path = runRoot + "\\" + name;
  UserValidationPinnedFiles.AssertNoReparse(path);
  Require(new FileInfo(path).Length is > 0 and <= 65536);
  return JsonDocument.Parse(File.ReadAllBytes(path));
}
void RequireBinding(JsonElement root, string contract)
{
  UserValidationBootstrapPlan.RejectDuplicates(root);
  var age = DateTimeOffset.UtcNow - root.GetProperty("verifiedAtUtc").GetDateTimeOffset();
  Require(root.GetProperty("contractId").GetString() == contract &&
      root.GetProperty("assessmentUid").GetString() == args[2] && root.GetProperty("trialUid").GetString() == args[1] &&
      root.GetProperty("parentPlanSha256").GetString() == args[3] && root.GetProperty("bootstrapPlanSha256").GetString() == args[4] &&
      root.GetProperty("runtimeStagingSha256").GetString() == args[5] &&
      root.GetProperty("executionOwnerCode").GetString() == "user" && root.GetProperty("jobName").GetString() == jobName &&
      age >= TimeSpan.Zero && age < TimeSpan.FromMinutes(5));
}
Process Start(ProcessStartInfo info, string role)
{
  var process = Process.Start(info) ?? throw new InvalidOperationException();
  try
  {
    Require(Native.IsProcessInJob(process.Handle, job, out var contained) && contained);
    Write(role + "-identity.private.json", new { processId = process.Id, createdFileTime = process.StartTime.ToUniversalTime().ToFileTimeUtc(), jobName });
    drains.Add(Drain(process.StandardOutput.BaseStream, runRoot + "\\" + role + ".stdout.private.log"));
    drains.Add(Drain(process.StandardError.BaseStream, runRoot + "\\" + role + ".stderr.private.log"));
    return process;
  }
  catch { try { if (!process.HasExited) process.Kill(); } finally { process.Dispose(); } throw; }
}
void Write(string name, object value)
{
  UserValidationPinnedFiles.AssertNoReparse(runRoot);
  using var stream = new FileStream(runRoot + "\\" + name, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
  JsonSerializer.Serialize(stream, value); stream.Flush(true);
}
static async Task<long> Drain(Stream input, string path)
{
  using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
  var buffer = new byte[8192]; var written = 0; long dropped = 0; int count;
  while ((count = await input.ReadAsync(buffer)) != 0)
  {
    var keep = Math.Min(count, Math.Max(0, 8 * 1024 * 1024 - written));
    if (keep > 0) { await output.WriteAsync(buffer.AsMemory(0, keep)); written += keep; }
    dropped += count - keep;
  }
  output.Flush(true);
  return dropped;
}
static void Require(bool value) { if (!value) throw new InvalidOperationException("user_validation_child_rejected"); }
internal static class Native
{
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  internal static extern SafeFileHandle OpenJobObject(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  internal static extern bool IsProcessInJob(IntPtr process, SafeFileHandle job, out bool member);
}
