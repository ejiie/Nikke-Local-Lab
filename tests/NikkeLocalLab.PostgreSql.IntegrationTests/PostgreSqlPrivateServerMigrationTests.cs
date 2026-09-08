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

  [Fact]
  public void V0013DefinesImmutableProfileBoundClassicSoloRaidRuntimeState()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 13);
    var sql = NormalizeWhitespace(migration.Sql);

    Assert.Equal("phase_d_classic_solo_raid_runtime_state", migration.Name);
    Assert.Contains(
        "CREATE TABLE lab_private_server.classic_solo_raid_runtime_state (",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "CREATE TABLE lab_private_server.classic_solo_raid_runtime_state_revision (",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "CREATE TABLE lab_private_server.classic_solo_raid_runtime_state_operation (",
        sql,
        StringComparison.Ordinal);

    Assert.Contains(
        "FOREIGN KEY (raid_snapshot_id, season_number) REFERENCES " +
        "lab_raid.raid_snapshot(raid_snapshot_id, season_number) ON DELETE RESTRICT",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "UNIQUE ( local_account_id, raid_snapshot_id, season_number, " +
        "client_build_code, client_executable_sha256 )",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("source_profile_revision_set_sha256 BYTEA NOT NULL", sql,
        StringComparison.Ordinal);
    Assert.Contains("state_schema_version SMALLINT NOT NULL CHECK (state_schema_version = 1)",
        sql, StringComparison.Ordinal);
    Assert.Contains("protected_payload BYTEA NOT NULL", sql, StringComparison.Ordinal);
    Assert.Contains("completed_best_total_damage BIGINT", sql, StringComparison.Ordinal);
    Assert.Contains(
        "CREATE INDEX ix_classic_solo_raid_runtime_state_revision_content ON " +
        "lab_private_server.classic_solo_raid_runtime_state_revision( " +
        "classic_solo_raid_runtime_state_id, state_content_sha256 )",
        sql,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "UNIQUE (classic_solo_raid_runtime_state_id, state_content_sha256)",
        sql,
        StringComparison.Ordinal);

    Assert.Contains(
        "previous_classic_solo_raid_runtime_state_revision_id BIGINT",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "revision_number = 1 AND previous_classic_solo_raid_runtime_state_revision_id IS NULL",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "revision_number > 1 AND previous_classic_solo_raid_runtime_state_revision_id IS NOT NULL",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("DEFERRABLE INITIALLY DEFERRED", sql, StringComparison.Ordinal);
    Assert.Contains("expected_head_revision_uid UUID", sql, StringComparison.Ordinal);
    Assert.Contains(
        "operation_status IN ('pending', 'applied', 'quarantined')",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("source_launch_context_uid UUID PRIMARY KEY", sql,
        StringComparison.Ordinal);

    Assert.Contains("guard_classic_solo_raid_runtime_state_operation", sql,
        StringComparison.Ordinal);
    Assert.Contains("guard_aggregate_pointer_update", sql, StringComparison.Ordinal);
    Assert.Contains("reject_immutable_mutation", sql, StringComparison.Ordinal);
    Assert.Contains(
        "completed_best_total_damage IS NOT NULL AND completed_best_team_count = 5",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("state_present OR NOT has_open_run", sql, StringComparison.Ordinal);
  }

  [Fact]
  public void V0014FreezesSaveAsObservationProvenanceWithoutCopyingSnapshotOwnership()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 14);
    var sql = NormalizeWhitespace(migration.Sql);

    Assert.Equal("save_as_observation_provenance", migration.Name);
    Assert.Contains("observation_provenance_resolved BOOLEAN NOT NULL DEFAULT FALSE", sql,
        StringComparison.Ordinal);
    Assert.Contains("resolved_observation_snapshot_uid UUID", sql, StringComparison.Ordinal);
    Assert.Contains(
        "CREATE TABLE lab_profile.account_observation_provenance_binding (",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("save_as_source_account_uid UUID NOT NULL", sql, StringComparison.Ordinal);
    Assert.Contains("source_snapshot_uid UUID", sql, StringComparison.Ordinal);
    Assert.Contains("binding_kind IN ('save_as/v1', 'legacy_parent_fallback/v1')", sql,
        StringComparison.Ordinal);
    Assert.Contains("save_operation_uid UUID UNIQUE", sql, StringComparison.Ordinal);
    Assert.Contains("trg_account_observation_provenance_binding_immutable", sql,
        StringComparison.Ordinal);
    Assert.DoesNotContain(
        "UPDATE lab_profile.fetched_account_snapshot",
        sql,
        StringComparison.Ordinal);
  }

  [Fact]
  public void V0015AcceptsOperatorClosedPartialClassicSoloRaidCompletions()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 15);
    var sql = NormalizeWhitespace(migration.Sql);

    Assert.Equal("partial_classic_solo_raid_completion", migration.Name);
    Assert.Contains(
        "completed_best_total_damage IS NOT NULL AND " +
        "completed_best_team_count BETWEEN 1 AND 5",
        sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "ck_classic_solo_raid_runtime_state_revision_completed_best_shape",
        sql,
        StringComparison.Ordinal);
  }

  [Fact]
  public void V0016RestoresFiveTeamOnlyCompletionForNewRevisions()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 16);
    var sql = NormalizeWhitespace(migration.Sql);

    Assert.Equal("discard_abandoned_classic_solo_raid_trials", migration.Name);
    Assert.Contains(
        "completed_best_total_damage IS NOT NULL AND completed_best_team_count = 5",
        sql,
        StringComparison.Ordinal);
    Assert.Contains("NOT VALID", sql, StringComparison.Ordinal);
    Assert.Contains(
        "phase_d_permissive_completed_best_shape_constraint_cardinality_invalid",
        sql,
        StringComparison.Ordinal);
  }

  private static string NormalizeWhitespace(string value) =>
      string.Join(' ', value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
