using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlPrivateServerMigrationTests
{
  [Fact]
  public void V0007DefinesTheImmutablePrivateServerBoundary()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 7);

    Assert.Equal("private_server_solo_raid", migration.Name);
    Assert.Contains("CREATE SCHEMA lab_private_server", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_operational_policy", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_policy_activation_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("raid_season_directory_member", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("local_client_context_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("selected_raid_season_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_daily_state_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("runtime_execution_profile_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("combat_control_profile_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_run_revision", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_team_damage_receipt", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("challenge_run_operation", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("uq_private_server_active_run_per_account", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("owning_session_inactive_recovery", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("lab_harness_observation/v1", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("canonical_damage", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("NUMERIC(78, 0)", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("Asia/Seoul", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("DEFERRABLE INITIALLY DEFERRED", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("reject_immutable_mutation", migration.Sql, StringComparison.Ordinal);
  }
}
