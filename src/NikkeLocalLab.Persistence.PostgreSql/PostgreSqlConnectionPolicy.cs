using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlPolicyException : Exception
{
  public PostgreSqlPolicyException(string code)
      : base(code)
  {
    Code = code;
  }

  public string Code { get; }
}

public static class PostgreSqlConnectionPolicy
{
  private static readonly HashSet<string> AllowedHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "localhost",
        "127.0.0.1",
        "::1"
    };

  public static string ResolveFromEnvironment(
      string environmentVariableName,
      Func<string, string?>? environmentReader = null)
  {
    if (string.IsNullOrWhiteSpace(environmentVariableName))
    {
      throw new PostgreSqlPolicyException("database_environment_name_missing");
    }

    environmentReader ??= Environment.GetEnvironmentVariable;
    var value = environmentReader(environmentVariableName);
    if (string.IsNullOrWhiteSpace(value))
    {
      throw new PostgreSqlPolicyException("database_connection_missing");
    }

    return Validate(value);
  }

  public static string Validate(string connectionString)
  {
    NpgsqlConnectionStringBuilder builder;
    try
    {
      builder = new NpgsqlConnectionStringBuilder(connectionString);
    }
    catch
    {
      throw new PostgreSqlPolicyException("database_connection_invalid");
    }

    if (string.IsNullOrWhiteSpace(builder.Host) ||
        builder.Host.Contains(',', StringComparison.Ordinal) ||
        !AllowedHosts.Contains(builder.Host) ||
        builder.IncludeErrorDetail)
    {
      throw new PostgreSqlPolicyException("database_connection_not_loopback_safe");
    }

    return builder.ConnectionString;
  }
}
