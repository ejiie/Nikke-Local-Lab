namespace NikkeLocalLab.Import.Sources;

public readonly record struct SourceRelativePath
{
  private SourceRelativePath(string value)
  {
    Value = value;
  }

  public string Value { get; }

  public static SourceRelativePath Parse(string? value)
  {
    if (string.IsNullOrWhiteSpace(value) ||
        Path.IsPathRooted(value) ||
        Path.IsPathFullyQualified(value) ||
        value.Contains(':'))
    {
      throw new SourceBoundaryException("source_relative_path_invalid");
    }

    var segments = value.Split(
        ['/', '\\'],
        StringSplitOptions.RemoveEmptyEntries);
    if (segments.Length == 0 || segments.Any(segment => segment is "." or ".."))
    {
      throw new SourceBoundaryException("source_relative_path_invalid");
    }

    return new SourceRelativePath(Path.Combine(segments));
  }
}

public sealed class SourceBoundaryException : Exception
{
  public SourceBoundaryException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}
