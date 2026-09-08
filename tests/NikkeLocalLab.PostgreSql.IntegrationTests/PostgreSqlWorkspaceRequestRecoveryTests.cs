using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  [Fact]
  public async Task WorkspaceRequestRecoveryMigrationPreservesLegacyClaimWithoutInventingPayload()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(17, await ApplyWorkspaceTestMigrationsAsync(dataSource, 17));
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, false);
    await InsertLegacyWorkspaceClaimAsync(dataSource, original);
    var before = await WorkspaceRevisionCountsAsync(dataSource);
    Assert.Equal(1, await ApplyWorkspaceTestMigrationsAsync(dataSource, 18));
    Assert.Equal(0, await ApplyWorkspaceTestMigrationsAsync(dataSource, 18));
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(dataSource));
    Assert.Equal(0L, await WorkspaceRequestCountAsync(dataSource));
    var pending = Assert.Single(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid));
    Assert.Equal("original_request_required", pending.RecoveryCode);
    Assert.Equal(original.OperationUid, pending.OperationUid);
    await Service(dataSource).SaveAccountWorkspaceAsync(original);
    Assert.Equal(0L, await WorkspaceRequestCountAsync(dataSource));
    Assert.Equal("completed", await WorkspaceSaveStatusAsync(dataSource, original.OperationUid));
  }

  [Theory]
  [InlineData(false, "profile")]
  [InlineData(false, "resolution")]
  [InlineData(false, "lobby")]
  [InlineData(false, "wallet")]
  [InlineData(false, "label")]
  [InlineData(false, "completion")]
  [InlineData(true, "profile")]
  [InlineData(true, "initialize")]
  [InlineData(true, "provenance")]
  [InlineData(true, "completion")]
  public async Task WorkspaceRequestRecoveryUsesDurableRequestAtEveryBoundary(bool saveAs, string stage)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var (table, condition) = WorkspaceStageTrigger(stage);
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(original)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }
    // A new pool/service has only the operation summary, not the original UI body.
    await using var freshPool = CreateDataSource();
    var before = await WorkspaceRevisionCountsAsync(freshPool);
    var pending = Assert.Single(await Service(freshPool).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid));
    Assert.Equal("pending", pending.StatusCode);
    Assert.Equal("exact_request_available", pending.RecoveryCode);
    Assert.Null(pending.CompletedReceipt);
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(freshPool));
    var resume = new App.ResumeWorkspaceSaveCommand(pending.SourceAccountUid, pending.OperationUid, pending.RequestSha256);
    var receipt = await Service(freshPool).ResumeWorkspaceSaveAsync(resume);
    Assert.Equal(saveAs ? 2 : 1, (await Service(freshPool).ListAccountsAsync()).Count);
    Assert.Equal(original.AccountLabel, receipt.AccountLabel);
    var bootstrap = (await Service(freshPool).GetCurrentBootstrapAsync(receipt.AccountUid))!;
    Assert.Equal(original.DisplayName, bootstrap.Lobby.DisplayName);
    Assert.Equal(original.Balances.OrderBy(item => item.CurrencyCode), bootstrap.Wallet.Balances.OrderBy(item => item.CurrencyCode));
    var counts = await WorkspaceRevisionCountsAsync(freshPool);
    var replay = await Service(freshPool).ResumeWorkspaceSaveAsync(resume);
    Assert.Equal(receipt with { IsIdempotentReplay = true }, replay);
    var completed = Assert.Single(await Service(freshPool).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid));
    Assert.Equal("completed", completed.StatusCode);
    Assert.Equal(replay, completed.CompletedReceipt);
    Assert.Equal(counts, await WorkspaceRevisionCountsAsync(freshPool));
    Assert.Equal(1L, await WorkspaceRequestCountAsync(freshPool));
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task WorkspaceRequestRecoveryClaimAndPayloadAreAtomic(bool saveAs)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var before = await WorkspaceRevisionCountsAsync(dataSource);
    await InstallWorkspaceStageFaultAsync(dataSource, "lab_profile.account_workspace_save_request", "TRUE");
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(original)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, "lab_profile.account_workspace_save_request"); }
    Assert.Null(await WorkspaceSaveStatusAsync(dataSource, original.OperationUid));
    Assert.Equal(0L, await WorkspaceRequestCountAsync(dataSource));
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(dataSource));
    await Service(dataSource).SaveAccountWorkspaceAsync(original);
    Assert.Equal(1L, await WorkspaceRequestCountAsync(dataSource));
  }

  [Fact]
  public async Task WorkspaceRequestRecoveryLegacyNeedsOriginalAndNeverBackfillsByGuess()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, false);
    await InsertLegacyWorkspaceClaimAsync(dataSource, original);
    var before = await WorkspaceRevisionCountsAsync(dataSource);
    var pending = Assert.Single(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid));
    Assert.Equal("original_request_required", pending.RecoveryCode);
    var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).ResumeWorkspaceSaveAsync(
        new(original.SourceAccountUid, original.OperationUid, original.RequestSha256)));
    Assert.Equal("account_workspace_save_original_request_required", failure.Code);
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(dataSource));
    Assert.Equal("pending", await WorkspaceSaveStatusAsync(dataSource, original.OperationUid));
    // A separately retained, exact original request can still use the old API.
    var saved = await Service(dataSource).SaveAccountWorkspaceAsync(original);
    Assert.Equal(0L, await WorkspaceRequestCountAsync(dataSource));
    Assert.Equal(saved with { IsIdempotentReplay = true }, await Service(dataSource).ResumeWorkspaceSaveAsync(
        new(original.SourceAccountUid, original.OperationUid, original.RequestSha256)));
  }

  [Fact]
  public async Task WorkspaceRequestRecoveryScopesCopiesAndRejectsWrongSourceOrHash()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, true);
    var sibling = await Service(dataSource).SaveAccountWorkspaceAsync(original);
    var pendingRequest = original with { OperationUid = EntityUid.New(), AccountLabel = "second copy" };
    var (table, condition) = WorkspaceStageTrigger("initialize");
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(pendingRequest)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }
    var target = (await Service(dataSource).ListAccountsAsync()).Single(item => item.AccountLabel == "second copy");
    var sourceRows = await Service(dataSource).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid);
    var pending = Assert.Single(sourceRows, item => item.StatusCode == "pending");
    Assert.Equal(pending, Assert.Single(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(target.AccountUid)));
    Assert.DoesNotContain(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(sibling.AccountUid), item => item.StatusCode == "pending");
    Assert.Empty(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(EntityUid.New()));
    var before = await WorkspaceRevisionCountsAsync(dataSource);
    var wrongSource = await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).ResumeWorkspaceSaveAsync(
        new(target.AccountUid, pending.OperationUid, pending.RequestSha256)));
    Assert.Equal("account_workspace_save_not_found", wrongSource.Code);
    var wrongHash = await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).ResumeWorkspaceSaveAsync(
        new(original.SourceAccountUid, pending.OperationUid, Sha256Digest.ComputeUtf8("wrong"))));
    Assert.Equal("account_workspace_save_operation_reuse_mismatch", wrongHash.Code);
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(dataSource));
    await Service(dataSource).ResumeWorkspaceSaveAsync(new(original.SourceAccountUid, pending.OperationUid, pending.RequestSha256));
  }

  [Fact]
  public async Task WorkspaceRequestRecoveryImmutablePayloadAndTamperFailClosed()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var original = await CreateWorkspaceSaveFixtureAsync(dataSource, false);
    var (table, condition) = WorkspaceStageTrigger("wallet");
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(original)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }
    foreach (var sql in new[] {
      "DELETE FROM lab_profile.account_workspace_save_request;",
      "UPDATE lab_profile.account_workspace_save_request SET contract_id = contract_id;",
      "DELETE FROM lab_profile.account_workspace_save_operation;" })
    {
      await using var mutation = dataSource.CreateCommand(sql);
      await Assert.ThrowsAsync<PostgresException>(() => mutation.ExecuteNonQueryAsync());
    }
    // Deliberately corrupt a synthetic fixture as a privileged DB owner, not an API write.
    await using (var corrupt = dataSource.CreateCommand("""
        ALTER TABLE lab_profile.account_workspace_save_request DISABLE TRIGGER trg_workspace_save_request_immutable;
        UPDATE lab_profile.account_workspace_save_request SET request_payload = @payload, payload_sha256 = sha256(@payload);
        ALTER TABLE lab_profile.account_workspace_save_request ENABLE TRIGGER trg_workspace_save_request_immutable;
        """))
    {
      corrupt.Parameters.AddWithValue("payload", App.WorkspaceSaveRequestCodec.Encode(original with { CommanderLevel = 999 }));
      await corrupt.ExecuteNonQueryAsync();
    }
    var before = await WorkspaceRevisionCountsAsync(dataSource);
    Assert.Equal("request_invalid", Assert.Single(await Service(dataSource).GetWorkspaceSaveRecoveryAsync(original.SourceAccountUid)).RecoveryCode);
    await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).ResumeWorkspaceSaveAsync(
        new(original.SourceAccountUid, original.OperationUid, original.RequestSha256)));
    await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(original));
    Assert.Equal(before, await WorkspaceRevisionCountsAsync(dataSource));
  }

  private static async Task<long> WorkspaceRequestCountAsync(NpgsqlDataSource dataSource)
  {
    await using var query = dataSource.CreateCommand("SELECT count(*) FROM lab_profile.account_workspace_save_request;");
    return (long)(await query.ExecuteScalarAsync())!;
  }

  private static async Task InsertLegacyWorkspaceClaimAsync(NpgsqlDataSource dataSource, App.SaveAccountWorkspaceCommand original)
  {
    await using var query = dataSource.CreateCommand("""
        INSERT INTO lab_profile.account_workspace_save_operation
          (operation_uid, operation_kind, request_sha256, source_account_uid, operation_status, created_at_utc)
        VALUES (@operation, @kind, @hash, @account, 'pending', @created);
        """);
    query.Parameters.AddWithValue("operation", original.OperationUid.Value);
    query.Parameters.AddWithValue("kind", original.SaveAs ? "save_as" : "save");
    query.Parameters.AddWithValue("hash", original.RequestSha256.ToByteArray());
    query.Parameters.AddWithValue("account", original.SourceAccountUid.Value);
    query.Parameters.AddWithValue("created", TestInstant);
    await query.ExecuteNonQueryAsync();
  }
}
