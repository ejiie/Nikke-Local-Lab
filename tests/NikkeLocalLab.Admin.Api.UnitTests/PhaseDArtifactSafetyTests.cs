namespace NikkeLocalLab.Admin.Api.UnitTests;

// Lifecycle, capture/restore ordering, identity and Job ownership are exercised
// by the runner, watcher, recovery and shared-isolation behavior tests. Keep only
// small source guards for boundaries that cannot safely use operational inputs.
public sealed class PhaseDArtifactSafetyTests
{
  [Fact]
  public void ExecutionArtifactsDoNotTargetTheOfficialInstallation()
  {
    var root = FindRepositoryRoot();
    var scripts = string.Join("\n", new[]
    {
      "invoke-nll-phase-d-execution.ps1", "Nll.PhaseDRunnerStart.ps1",
      "Nll.PhaseDRunnerComplete.ps1", "Nll.PhaseDPreparation.ps1",
      "watch-nll-phase-d-execution.ps1", "recover-nll-phase-d-orphaned-execution.ps1",
      "deploy-nll-phase-d-control-center-offline.ps1",
      "start-nll-phase-d-control-center.ps1", "stop-nll-phase-d-control-center.ps1"
    }.Select(name => File.ReadAllText(Path.Combine(root, "scripts", name))));
    var materializer = File.ReadAllText(Path.Combine(root, "tools",
        "NikkeLocalLab.PhaseD.RuntimeMaterializer", "Program.cs"));
    materializer = System.Text.RegularExpressions.Regex.Replace(materializer, @"\s+", " ");
    const string officialPathGuard =
        "Require(!path.StartsWith(@\"C:\\NIKKE\", StringComparison.OrdinalIgnoreCase), " +
        "\"phase_d_user_validation_official_path_rejected\");";

    // The materializer may name the official installation only to reject it.
    Assert.Contains(officialPathGuard, materializer, StringComparison.Ordinal);
    var execution = scripts + materializer.Replace(officialPathGuard, "", StringComparison.Ordinal);
    Assert.DoesNotContain(@"C:\NIKKE", execution, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain(@"D:\", execution, StringComparison.OrdinalIgnoreCase);
    Assert.Contains("AssetDownloadUtil.ConfigureOfficialOutbound(false)", materializer, StringComparison.Ordinal);
  }

  [Fact]
  public void LocalManagementSecretsRemainProtectedWithoutPersistentServices()
  {
    var root = FindRepositoryRoot();
    var installer = File.ReadAllText(Path.Combine(root, "scripts", "deploy-nll-phase-d-control-center-offline.ps1"));
    var start = File.ReadAllText(Path.Combine(root, "scripts", "start-nll-phase-d-control-center.ps1"));
    Assert.Contains("ProtectedData]::Protect", installer, StringComparison.Ordinal);
    Assert.Contains("ProtectedData]::Unprotect", start, StringComparison.Ordinal);
    Assert.DoesNotContain("New-Service", installer + start, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("ScheduledTask", installer + start, StringComparison.OrdinalIgnoreCase);
  }

  private static string FindRepositoryRoot()
  {
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null && !File.Exists(Path.Combine(current.FullName, "NikkeLocalLab.sln")))
    {
      current = current.Parent;
    }

    return current?.FullName ?? throw new InvalidOperationException("repository_root_not_found");
  }
}
