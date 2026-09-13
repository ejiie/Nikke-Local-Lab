using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace NikkeLocalLab.Phase3B2.LocalBootstrap;

internal sealed class UserValidationBootstrapSettings : IDisposable
{
  private readonly List<FileStream> leases = [];
  internal UserValidationBootstrapPlan Plan { get; }
  internal string AssessmentUid => Plan.AssessmentUid;
  internal int DurationSeconds => Plan.DurationSeconds;
  internal bool AuthOnly => false; // No registration/auth-only diagnostic mode in this executable.
  internal string ContextPath => Plan.RuntimeRoot + @"\synthetic-context.json";
  internal string RunRoot => Plan.RunRoot;
  internal string ClientPath => Plan.ClientRoot + @"\NIKKE\game\nikke.exe";
  internal string ResourcePath => Plan.ClientRoot + @"\Unity\com_proximabeta_NIKKE\";
  private UserValidationBootstrapSettings(UserValidationBootstrapPlan plan) => Plan = plan;

  internal static UserValidationBootstrapSettings Load(bool inspectOnly)
  {
    Require(OperatingSystem.IsWindows());
    var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
    var uid = Path.GetRelativePath(UserValidationBootstrapPlan.RuntimeParent, directory);
    Require(Guid.TryParseExact(uid, "D", out var guid) && guid != Guid.Empty && uid == guid.ToString("D") &&
        directory == UserValidationBootstrapPlan.RuntimeParent + @"\" + uid);
    var digest = Environment.GetEnvironmentVariable("NLL_USER_VALIDATION_BOOTSTRAP_SHA256") ?? "";
    var planPath = directory + @"\bootstrap.private.json";
    using var planInput = UserValidationPinnedFiles.Open(planPath, new FileInfo(planPath).Length, digest, 1048576);
    var bytes = new byte[checked((int)planInput.Length)];
    planInput.ReadExactly(bytes);
    var plan = UserValidationBootstrapPlan.Parse(bytes);
    Require(plan.AssessmentUid == uid && plan.RuntimeRoot == directory);
    var settings = new UserValidationBootstrapSettings(plan);
    UserValidationPreflightMeasurement? measurement = null;
    var verified = false;
    try
    {
      // Refuse normal-token or off-Job launch before lengthy cache hashing.
      if (!inspectOnly) RequireLaunchContext(plan.JobName);
      measurement = new("bootstrap", plan.ParentPlanSha256, plan.RuntimeFiles.Sum(p => p.Length) + plan.ClientFiles.Sum(p => p.Length));
      foreach (var pin in plan.RuntimeFiles)
        settings.leases.Add(UserValidationPinnedFiles.Open(pin.Path, pin.Length, pin.Sha256, 512L * 1024 * 1024, measurement.Observe));
      foreach (var pin in plan.ClientFiles)
        using (UserValidationPinnedFiles.Open(pin.Path, pin.Length, pin.Sha256, 16L * 1024 * 1024 * 1024, measurement.Observe)) { }
      Require(UserValidationPinnedFiles.Inventory(directory, 65).SetEquals(
          plan.RuntimeFiles.Select(pin => pin.Path).Append(planPath)));
      Require(UserValidationPinnedFiles.Inventory(plan.ClientRoot, 10000).SetEquals(plan.ClientFiles.Select(pin => pin.Path)));
      UserValidationPinnedFiles.AssertNoReparse(plan.RunRoot);
      var parentPath = plan.ParentPlanPath;
      using var parentInput = UserValidationPinnedFiles.Open(parentPath, new FileInfo(parentPath).Length, plan.ParentPlanSha256, 1048576);
      using var parent = JsonDocument.Parse(parentInput);
      UserValidationLaunchEvidence.ValidateParent(plan, parent.RootElement);
      if (!inspectOnly) settings.RequireIsolation(digest);
      verified = true;
      return settings;
    }
    catch { settings.Dispose(); throw; }
    finally
    {
      if (!inspectOnly && measurement is not null)
        try { measurement.Save(plan.RunRoot, verified); }
        catch { settings.Dispose(); throw; }
    }
  }

  private static void RequireLaunchContext(string name)
  {
    using var job = OpenJobObject(4, false, name);
    Require(!job.IsInvalid && IsProcessInJob(new IntPtr(-1), job, out var member) && member);
    var context = ExecutionTokenObservation.Current();
    Require(context.Process.Token is { Status: "observed", Token: { Elevated: 1, IntegrityRid: >= 12288 } } &&
        context.Thread.Status == "no_thread_token" && !context.CompatRunAsInvoker);
  }

  private void RequireIsolation(string bootstrapHash)
  {
    var path = RunRoot + @"\isolation.ready.json";
    UserValidationPinnedFiles.AssertNoReparse(path);
    Require(new FileInfo(path).Length is > 0 and <= 65536);
    using var ready = JsonDocument.Parse(File.ReadAllBytes(path));
    UserValidationLaunchEvidence.ValidateIsolation(Plan, bootstrapHash, ready.RootElement, DateTimeOffset.UtcNow);
  }

  internal HttpClient CreateClient()
  {
    using var certificate = X509CertificateLoader.LoadCertificateFromFile(Plan.RuntimeRoot + @"\trust-root.cer");
    var handler = new SocketsHttpHandler
    {
      UseProxy = false,
      UseCookies = false,
      AllowAutoRedirect = false,
      AutomaticDecompression = DecompressionMethods.None,
      ConnectCallback = ResourceProbeBootstrapSettings.ConnectLoopbackAsync,
      SslOptions = new SslClientAuthenticationOptions
      {
        CertificateChainPolicy = ResourceProbeBootstrapSettings.CreateChainPolicy(certificate)
      }
    };
    return new(handler) { Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 1048576 };
  }

  public void Dispose() { foreach (var lease in leases) lease.Dispose(); leases.Clear(); }
  private static void Require(bool value)
  {
    if (!value) throw new InvalidOperationException("user_validation_bootstrap_boundary_rejected");
  }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle OpenJobObject(uint access, bool inherit, string name);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool IsProcessInJob(IntPtr process, SafeFileHandle job, out bool member);
}
