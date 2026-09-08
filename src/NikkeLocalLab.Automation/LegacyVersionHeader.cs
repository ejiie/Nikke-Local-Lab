using System.Collections.ObjectModel;
using System.Text.RegularExpressions;

namespace NikkeLocalLab.Automation;

public static partial class LegacyVersionHeader
{
  public static IReadOnlyDictionary<string, string> Parse(string text)
  {
    var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd('\n').Split('\n');
    if (lines.Length != 8 || !RootVersionPattern().IsMatch(lines[0]))
    {
      throw new PipelineManifestException("resource_version_header_invalid");
    }

    var entries = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var line in lines.Skip(1))
    {
      var match = EntryPattern().Match(line);
      if (!match.Success || !entries.TryAdd(match.Groups[1].Value, match.Groups[2].Value))
      {
        throw new PipelineManifestException("resource_version_header_invalid");
      }
    }

    if (!new[] { "core", "dp", "fd", "saus", "en", "ko", "ja" }.All(entries.ContainsKey))
    {
      throw new PipelineManifestException("resource_version_header_invalid");
    }

    return new ReadOnlyDictionary<string, string>(entries);
  }

  [GeneratedRegex("^[a-z0-9]+$", RegexOptions.CultureInvariant)]
  private static partial Regex RootVersionPattern();

  [GeneratedRegex("^(core|dp|fd|saus|en|ko|ja):([a-z0-9.]+),[0-9]+$", RegexOptions.CultureInvariant)]
  private static partial Regex EntryPattern();
}
