namespace NikkeLocalLab.Configuration;

public static class PathBoundary
{
  private static StringComparison PathComparison => OperatingSystem.IsWindows()
      ? StringComparison.OrdinalIgnoreCase
      : StringComparison.Ordinal;

  public static string NormalizeAbsoluteLocalPath(string? path, string errorCode)
  {
    if (string.IsNullOrWhiteSpace(path) ||
        path.StartsWith("\\\\", StringComparison.Ordinal) ||
        path.StartsWith("//", StringComparison.Ordinal) ||
        path.StartsWith("\\\\?\\", StringComparison.Ordinal) ||
        path.StartsWith("\\\\.\\", StringComparison.Ordinal) ||
        !Path.IsPathFullyQualified(path))
    {
      throw new LabConfigurationException(errorCode);
    }

    string fullPath;
    try
    {
      fullPath = Path.GetFullPath(path);
    }
    catch
    {
      throw new LabConfigurationException(errorCode);
    }

    if (OperatingSystem.IsWindows())
    {
      if (fullPath.Length < 3 || fullPath[1] != ':' ||
          (fullPath[2] != Path.DirectorySeparatorChar && fullPath[2] != Path.AltDirectorySeparatorChar) ||
          fullPath.AsSpan(2).Contains(':'))
      {
        throw new LabConfigurationException(errorCode);
      }
    }

    return Path.TrimEndingDirectorySeparator(fullPath);
  }

  public static void EnsureDisjoint(string first, string second, string errorCode)
  {
    if (IsWithinOrEqual(first, second) || IsWithinOrEqual(second, first))
    {
      throw new LabConfigurationException(errorCode);
    }
  }

  public static bool IsWithinOrEqual(string candidate, string root)
  {
    var relative = Path.GetRelativePath(root, candidate);
    if (string.Equals(relative, ".", PathComparison))
    {
      return true;
    }

    if (Path.IsPathRooted(relative) || string.Equals(relative, "..", PathComparison))
    {
      return false;
    }

    return !relative.StartsWith($"..{Path.DirectorySeparatorChar}", PathComparison) &&
        !relative.StartsWith($"..{Path.AltDirectorySeparatorChar}", PathComparison);
  }

  public static void EnsureNoReparsePoints(string fullPath, bool requireFinalExists, string errorCode)
  {
    var normalized = Path.GetFullPath(fullPath);
    var root = Path.GetPathRoot(normalized);
    if (string.IsNullOrEmpty(root))
    {
      throw new LabConfigurationException(errorCode);
    }

    var relative = normalized[root.Length..];
    var current = root;
    foreach (var segment in relative.Split(
                 [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                 StringSplitOptions.RemoveEmptyEntries))
    {
      current = Path.Combine(current, segment);
      if (!File.Exists(current) && !Directory.Exists(current))
      {
        continue;
      }

      FileAttributes attributes;
      try
      {
        attributes = File.GetAttributes(current);
      }
      catch
      {
        throw new LabConfigurationException(errorCode);
      }

      if ((attributes & FileAttributes.ReparsePoint) != 0)
      {
        throw new LabConfigurationException(errorCode);
      }
    }

    if (requireFinalExists && !File.Exists(normalized) && !Directory.Exists(normalized))
    {
      throw new LabConfigurationException(errorCode);
    }
  }
}
