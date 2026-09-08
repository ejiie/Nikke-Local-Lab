using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlAccountWorkspaceMigrationTests
{
  [Fact]
  public void V0008DefinesAccountWorkspaceMetadataWithoutMutatingGameRevisions()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 8);

    Assert.Equal("account_workspace", migration.Name);
    Assert.Contains("CREATE TABLE lab_profile.account_workspace", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("account_label TEXT NOT NULL UNIQUE", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("save_as_parent_account_uid", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("fetched_snapshot_uid", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.profile_template_revision", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.account_state_revision", migration.Sql, StringComparison.Ordinal);
  }

  [Fact]
  public void V0009StoresSourceFreeFetchedSnapshotsAndAdvancesOnlyWorkspaceMetadata()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 9);

    Assert.Equal("fetched_account_snapshot", migration.Name);
    Assert.Contains("CREATE TABLE lab_profile.fetched_account_snapshot", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("sanitized_profile_draft_id", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("credentialOrSessionPersisted", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("rawSourcePersisted", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("trg_fetched_account_snapshot_immutable", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.profile_template_revision", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.account_state_revision", migration.Sql, StringComparison.Ordinal);
  }

  [Fact]
  public void V0010StoresBoundProgressionSidecarsWithoutGameRevisionMutation()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 10);

    Assert.Equal("fetched_progression_observation", migration.Name);
    Assert.Contains("CREATE TABLE lab_profile.fetched_progression_observation", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("nll/fetched-progression-observation/v2", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("officialUserIdentifierPersisted", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("rawSourcePathPersisted", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("rawSourceHashPersisted", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("trg_fetched_progression_observation_immutable", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.profile_template_revision", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("UPDATE lab_profile.account_state_revision", migration.Sql, StringComparison.Ordinal);
  }

  [Fact]
  public void V0011StoresResumableAggregateSaveReceipts()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 11);

    Assert.Equal("account_workspace_save", migration.Name);
    Assert.Contains(
        "CREATE TABLE lab_profile.account_workspace_save_operation",
        migration.Sql,
        StringComparison.Ordinal);
    Assert.Contains("operation_status IN ('pending', 'completed')", migration.Sql,
        StringComparison.Ordinal);
    Assert.Contains("resolved_lobby_revision_uid", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("result_revision_set_sha256", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("trg_account_workspace_save_operation_guard", migration.Sql,
        StringComparison.Ordinal);
    Assert.DoesNotContain("JSONB", migration.Sql, StringComparison.OrdinalIgnoreCase);
  }
}
