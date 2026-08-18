using System.Text.RegularExpressions;

namespace NikkeLocalLab.Provenance;

public static partial class ControlledCode
{
  public static string Require(string? value, string parameterName)
  {
    if (value is null || !CodePattern().IsMatch(value))
    {
      throw new ArgumentException(
          "A controlled code must start with a lowercase letter and contain only lowercase ASCII letters, digits, dot, underscore, or hyphen.",
          parameterName);
    }

    return value;
  }

  [GeneratedRegex("^[a-z][a-z0-9._-]{0,63}$", RegexOptions.CultureInvariant)]
  private static partial Regex CodePattern();
}
