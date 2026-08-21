using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

internal static class PostgreSqlTestDatabaseGuard
{
  private const string DefaultDatabase = "nikke_local_lab_test";
  private const string ExpectedDatabaseEnvironmentVariable =
      "NIKKE_LAB_TEST_EXPECTED_DATABASE";

  internal static void RequireDisposableDatabase(NpgsqlConnectionStringBuilder builder)
  {
    ArgumentNullException.ThrowIfNull(builder);
    var expected = Environment.GetEnvironmentVariable(ExpectedDatabaseEnvironmentVariable) ??
        DefaultDatabase;
    if (expected.Length is < 1 or > 63 ||
        !expected.StartsWith("nikke_local_lab_", StringComparison.Ordinal) ||
        expected.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character == '_')))
    {
      throw new InvalidOperationException("The disposable PostgreSQL database name is invalid.");
    }

    Assert.Equal(expected, builder.Database);
  }
}
