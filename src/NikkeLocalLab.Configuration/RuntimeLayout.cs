namespace NikkeLocalLab.Configuration;

public sealed record RuntimeLayout(
    string Root,
    string Data,
    string Database,
    string Vault,
    string Cache,
    string Logs,
    string Secrets,
    string Staging);

public static class RuntimeRootInitializer
{
  private static readonly string[] DirectoryNames =
  [
      "data",
    "database",
    "vault",
    "cache",
    "logs",
    "secrets",
    "staging"
  ];

  public static RuntimeLayout Initialize(ResolvedLabConfiguration configuration, string repositoryRoot)
  {
    ArgumentNullException.ThrowIfNull(configuration);
    var normalizedRepositoryRoot = PathBoundary.NormalizeAbsoluteLocalPath(repositoryRoot, "repository_root_invalid");

    PathBoundary.EnsureDisjoint(configuration.GameRoot, configuration.RuntimeRoot, "source_runtime_overlap");
    PathBoundary.EnsureDisjoint(normalizedRepositoryRoot, configuration.RuntimeRoot, "repository_runtime_overlap");
    PathBoundary.EnsureNoReparsePoints(configuration.RuntimeRoot, false, "runtime_reparse_rejected");

    Directory.CreateDirectory(configuration.RuntimeRoot);
    PathBoundary.EnsureNoReparsePoints(configuration.RuntimeRoot, true, "runtime_reparse_rejected");

    var paths = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var name in DirectoryNames)
    {
      var path = Path.GetFullPath(Path.Combine(configuration.RuntimeRoot, name));
      if (!PathBoundary.IsWithinOrEqual(path, configuration.RuntimeRoot))
      {
        throw new LabConfigurationException("runtime_child_escape");
      }

      Directory.CreateDirectory(path);
      PathBoundary.EnsureNoReparsePoints(path, true, "runtime_reparse_rejected");
      paths.Add(name, path);
    }

    return new RuntimeLayout(
        configuration.RuntimeRoot,
        paths["data"],
        paths["database"],
        paths["vault"],
        paths["cache"],
        paths["logs"],
        paths["secrets"],
        paths["staging"]);
  }
}
