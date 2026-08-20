using NikkeLocalLab.Configuration;
using NikkeLocalLab.Import.Profile;

internal static class ProfileSanitizerCli
{
  internal const string SourcePathEnvironmentVariable = "NIKKE_LAB_PROFILE_RAW";

  public static Task<int> InspectAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot)
  {
    ArgumentNullException.ThrowIfNull(configuration);
    ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
    string sourcePath;
    try
    {
      sourcePath = ResolveSourcePath(configuration, repositoryRoot);
    }
    catch (LabConfigurationException exception)
    {
      return Task.FromResult(Fail(exception.Code));
    }

    try
    {
      using var stream = new FileStream(
          sourcePath,
          FileMode.Open,
          FileAccess.Read,
          FileShare.Read);
      var result = new CredentialBearingProfileSanitizer().InspectCoverage(stream);
      if (!result.Succeeded || result.Coverage is null)
      {
        var code = result.Diagnostics
            .Where(static item => item.Severity == ProfileImportDiagnosticSeverity.Error)
            .Select(static item => item.Code)
            .Order(StringComparer.Ordinal)
            .FirstOrDefault() ?? "profile_source_invalid";
        return Task.FromResult(Fail(code));
      }

      var coverage = result.Coverage;
      Console.WriteLine(
          $"profile_source_valid roster={coverage.RosterObservationCount} " +
          $"detail={coverage.DetailObservationCount} " +
          $"level_differences={coverage.CharacterLevelDifferenceCount} " +
          $"equipment_coordinates={coverage.EquipmentCoordinateCount} " +
          $"overload_references={coverage.OverloadReferenceCount} " +
          $"state_effect_resolutions={coverage.StateEffectResolvedReferenceCount} " +
          $"sparse_overload_equipment={coverage.SparseOverloadEquipmentCount} " +
          $"consoles={coverage.ConsoleObservationCount}");
      return Task.FromResult(0);
    }
    catch
    {
      return Task.FromResult(Fail("profile_source_unavailable"));
    }
  }

  internal static string ResolveSourcePath(
      ResolvedLabConfiguration configuration,
      string repositoryRoot)
  {
    ArgumentNullException.ThrowIfNull(configuration);
    ArgumentException.ThrowIfNullOrWhiteSpace(repositoryRoot);
    var sourcePath = PathBoundary.NormalizeAbsoluteLocalPath(
        Environment.GetEnvironmentVariable(SourcePathEnvironmentVariable),
        "profile_source_path_invalid");
    PathBoundary.EnsureNoReparsePoints(
        sourcePath,
        requireFinalExists: true,
        "profile_source_path_invalid");
    var normalizedRepository = PathBoundary.NormalizeAbsoluteLocalPath(
        repositoryRoot,
        "repository_root_invalid");
    if (PathBoundary.IsWithinOrEqual(sourcePath, normalizedRepository) ||
        PathBoundary.IsWithinOrEqual(sourcePath, configuration.RuntimeRoot))
    {
      throw new LabConfigurationException("profile_source_boundary_invalid");
    }

    return sourcePath;
  }

  private static int Fail(string code)
  {
    Console.Error.WriteLine($"error:{code}");
    return 1;
  }
}
