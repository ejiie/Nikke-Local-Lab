using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public static class PostgreSqlDataSourceFactory
{
  public static NpgsqlDataSource Create(string connectionString)
  {
    var validated = PostgreSqlConnectionPolicy.Validate(connectionString);
    var builder = new NpgsqlDataSourceBuilder(validated);
    return builder.Build();
  }
}
