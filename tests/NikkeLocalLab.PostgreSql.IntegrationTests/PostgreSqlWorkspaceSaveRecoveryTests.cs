using System.Text;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task WorkspaceSaveRecoveryRejectsNewStaleRequestWithoutLeavingClaim(bool saveAs)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var command = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource)
        .SaveAccountWorkspaceAsync(command with { ExpectedWalletRevisionUid = EntityUid.New() }));
    Assert.Equal("local_game_wallet_revision_conflict", failure.Code);
    Assert.Null(await WorkspaceSaveStatusAsync(dataSource, command.OperationUid));
    Assert.NotNull(await Service(dataSource).GetRuntimeProjectionSnapshotAsync(command.SourceAccountUid));
    var saved = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    Assert.Equal(command.AccountLabel, saved.AccountLabel);
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task WorkspaceSaveRecoveryValidatesClaimWithoutCommittedProfile(bool saveAs)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var command = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    command = command with { ExpectedLobbyRevisionUid = EntityUid.New() };
    // A process stopped after claiming, before validating or committing a child.
    await using (var claim = dataSource.CreateCommand("""
        INSERT INTO lab_profile.account_workspace_save_operation
          (operation_uid, operation_kind, request_sha256, source_account_uid, operation_status, created_at_utc)
        VALUES (@operation, @kind, @hash, @account, 'pending', @created);
        """))
    {
      claim.Parameters.AddWithValue("operation", command.OperationUid.Value);
      claim.Parameters.AddWithValue("kind", saveAs ? "save_as" : "save");
      claim.Parameters.AddWithValue("hash", command.RequestSha256.ToByteArray());
      claim.Parameters.AddWithValue("account", command.SourceAccountUid.Value);
      claim.Parameters.AddWithValue("created", TestInstant);
      await claim.ExecuteNonQueryAsync();
    }
    var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(
        () => Service(dataSource).SaveAccountWorkspaceAsync(command));
    Assert.Equal("local_game_lobby_revision_conflict", failure.Code);
    var source = (await Service(dataSource).GetAccountWorkspaceAsync(command.SourceAccountUid))!;
    Assert.Equal(command.ExpectedProfileRevisionUid, source.BaseRevisions.ProfileRevisionUid);
    Assert.Single(await Service(dataSource).ListAccountsAsync());
    Assert.Equal("pending", await WorkspaceSaveStatusAsync(dataSource, command.OperationUid));
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
  public async Task WorkspaceSaveRecoveryResumesEveryDurableBoundary(bool saveAs, string nextStage)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var command = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var sourceBefore = (await Service(dataSource).GetAccountWorkspaceAsync(command.SourceAccountUid))!;
    var (table, condition) = WorkspaceStageTrigger(nextStage);
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try
    {
      await Assert.ThrowsAsync<App.ProfileManagementException>(
          () => Service(dataSource).SaveAccountWorkspaceAsync(command));
      Assert.Equal("pending", await WorkspaceSaveStatusAsync(dataSource, command.OperationUid));
    }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }

    // New service, existing database: no in-memory recovery state is available.
    var saved = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    Assert.Equal("completed", await WorkspaceSaveStatusAsync(dataSource, command.OperationUid));
    var history = (await Service(dataSource).GetAccountRevisionHistoryAsync(saved.AccountUid))!;
    Assert.Equal(saveAs ? 1 : 2, history.Revisions.Count);
    var beforeReplay = await WorkspaceRevisionCountsAsync(dataSource);
    var replay = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    Assert.Equal(saved with { IsIdempotentReplay = true }, replay);
    Assert.Equal(beforeReplay, await WorkspaceRevisionCountsAsync(dataSource));
    var snapshot = (await Service(dataSource).GetRuntimeProjectionSnapshotAsync(saved.AccountUid))!;
    Assert.Equal(saved.ProfileRevision.RevisionUid, snapshot.Candidate.BaseRevisions.ProfileRevisionUid);
    Assert.Equal(saved.LobbyRevision, snapshot.Lobby!.Revision);
    Assert.Equal(command.DisplayName, snapshot.Lobby.DisplayName);
    Assert.Equal(command.AccountLabel, snapshot.Candidate.AccountLabel);
    var bootstrap = (await Service(dataSource).GetCurrentBootstrapAsync(saved.AccountUid))!;
    Assert.Equal(saved.WalletRevision, bootstrap.Wallet.Revision);
    Assert.Equal(saveAs ? 2 : 1, (await Service(dataSource).ListAccountsAsync()).Count);
    if (saveAs)
    {
      var sourceAfter = (await Service(dataSource).GetAccountWorkspaceAsync(command.SourceAccountUid))!;
      Assert.Equal(sourceBefore.BaseRevisions, sourceAfter.BaseRevisions);
      Assert.Equal(sourceBefore.AccountLabel, sourceAfter.AccountLabel);
    }
    var mismatch = await Assert.ThrowsAsync<App.ProfileManagementException>(
        () => Service(dataSource).SaveAccountWorkspaceAsync(command with { CommanderLevel = 999 }));
    Assert.Equal("account_workspace_save_operation_reuse_mismatch", mismatch.Code);
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task WorkspaceSaveRecoveryRejectsCompetingOperationUntilPendingSaveResumes(bool saveAs)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var command = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var (table, condition) = WorkspaceStageTrigger("completion");
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => Service(dataSource).SaveAccountWorkspaceAsync(command)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }
    var target = (await Service(dataSource).ListAccountsAsync()).Single(item => item.AccountLabel == command.AccountLabel);
    var competing = await CreateNextWorkspaceSaveAsync(dataSource, command, target.AccountUid);
    var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(
        () => Service(dataSource).SaveAccountWorkspaceAsync(competing));
    Assert.Equal("account_workspace_save_pending", failure.Code);
    Assert.Null(await WorkspaceSaveStatusAsync(dataSource, competing.OperationUid));
    await Service(dataSource).SaveAccountWorkspaceAsync(command);
    var next = await Service(dataSource).SaveAccountWorkspaceAsync(competing);
    Assert.Equal(competing.AccountLabel, next.AccountLabel);
  }

  [Theory]
  [InlineData(false, false)]
  [InlineData(false, true)]
  [InlineData(true, false)]
  [InlineData(true, true)]
  public async Task WorkspaceSaveRecoverySerializesAcrossServicesAndReleasesLease(bool saveAs, bool cancelWriter)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var command = await CreateWorkspaceSaveFixtureAsync(dataSource, saveAs);
    var independent = (await CreateWorkspaceSaveFixtureAsync(dataSource, false)) with { AccountLabel = "independent" };
    await using var barrier = await dataSource.OpenConnectionAsync();
    await using (var setup = new NpgsqlCommand($$"""
        SELECT pg_advisory_lock(730071);
        CREATE FUNCTION public.synthetic_workspace_live_pause() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.operation_uid = '{{command.OperationUid}}'::uuid AND NEW.operation_status = 'completed' THEN
            PERFORM pg_advisory_xact_lock(730071);
          END IF;
          RETURN NEW;
        END; $$;
        CREATE TRIGGER synthetic_workspace_live_pause BEFORE UPDATE ON lab_profile.account_workspace_save_operation
        FOR EACH ROW EXECUTE FUNCTION public.synthetic_workspace_live_pause();
        """, barrier))
      await setup.ExecuteNonQueryAsync();
    using var writerCancellation = new CancellationTokenSource();
    var writer = Service(dataSource).SaveAccountWorkspaceAsync(command, writerCancellation.Token);
    try
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
      while (true)
      {
        await using var waiting = dataSource.CreateCommand(
            "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 730071 AND NOT granted);");
        if (Equals(true, await waiting.ExecuteScalarAsync(deadline.Token))) break;
        if (writer.IsCompleted) await writer;
        await Task.Delay(10, deadline.Token);
      }
      // Separate pools as well as services: no process-local semaphore can satisfy this contract.
      await using var otherDataSource = CreateDataSource();
      using var requestDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
      var duplicate = await Assert.ThrowsAsync<App.ProfileManagementException>(
          () => Service(otherDataSource).SaveAccountWorkspaceAsync(command, requestDeadline.Token));
      Assert.Equal(App.ProfileManagementFailureKind.Conflict, duplicate.Kind);
      Assert.Equal("account_workspace_save_in_progress", duplicate.Code);
      var target = (await Service(otherDataSource).ListAccountsAsync()).Single(item => item.AccountLabel == command.AccountLabel);
      var competing = await CreateNextWorkspaceSaveAsync(otherDataSource, command, target.AccountUid);
      var conflict = await Assert.ThrowsAsync<App.ProfileManagementException>(
          () => Service(otherDataSource).SaveAccountWorkspaceAsync(competing, requestDeadline.Token));
      Assert.Equal(saveAs ? "account_workspace_save_pending" : "account_workspace_save_in_progress", conflict.Code);
      Assert.Null(await WorkspaceSaveStatusAsync(dataSource, competing.OperationUid));
      var unrelated = await Service(otherDataSource).SaveAccountWorkspaceAsync(independent, requestDeadline.Token);
      Assert.Equal("independent", unrelated.AccountLabel);
      if (cancelWriter)
      {
        writerCancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => writer);
        Assert.Equal("pending", await WorkspaceSaveStatusAsync(dataSource, command.OperationUid));
      }
    }
    finally
    {
      await using var release = new NpgsqlCommand("SELECT pg_advisory_unlock(730071);", barrier);
      await release.ExecuteNonQueryAsync();
      try { await writer; }
      catch (OperationCanceledException) when (writerCancellation.IsCancellationRequested) { }
      finally
      {
        await using var cleanup = dataSource.CreateCommand("""
            DROP TRIGGER synthetic_workspace_live_pause ON lab_profile.account_workspace_save_operation;
            DROP FUNCTION public.synthetic_workspace_live_pause();
            """);
        await cleanup.ExecuteNonQueryAsync();
      }
    }
    var recovered = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    var replay = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    Assert.Equal(recovered with { IsIdempotentReplay = true }, replay);
    await using var locks = dataSource.CreateCommand("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory';");
    Assert.Equal(0L, await locks.ExecuteScalarAsync());
  }

  [Fact]
  public async Task WorkspaceSaveRecoveryPinsObservationBeforeInterruptedCopyAndLaterSourceFetch()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var imported = await ImportStrictDraftAsync(dataSource, catalogs, CharacterLevelAuthorityPolicy.DetailObservationV1, TestInstant);
    var service = Service(dataSource);
    var created = await CreateAccountFromImportAsync(service, imported, DetailLevelAuthority);
    var draftJson = Encoding.UTF8.GetString(SanitizedProfileDraftJsonCodec.Encode(imported.Draft));
    async Task<EntityUid> FetchAsync(int minute)
    {
      var snapshot = FetchedAccountSnapshotMaterializer.Materialize(new FetchedAccountSnapshotMaterializationCommand(
          EntityUid.New(), TestInstant.AddMinutes(minute), imported.Draft,
          new CredentialBearingProfileCoverage(2, 2, 1, 8, 2, 2, 1, 9),
          new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
          new FetchedProgressionObservation(Sha256Digest.ComputeUtf8("synthetic-main-quest"), 611, 611, 17),
          Array.Empty<ProfileImportDiagnostic>()));
      var registered = await service.RegisterFetchedAccountSnapshotAsync(new App.RegisterFetchedAccountSnapshotCommand(
          created.AccountUid, created.ProfileRevision.RevisionUid,
          Encoding.UTF8.GetString(FetchedAccountSnapshotJsonCodec.Encode(snapshot)), draftJson));
      Assert.True(registered.IsCurrentWorkspaceSnapshot);
      return snapshot.SnapshotUid;
    }
    var originalObservation = await FetchAsync(5);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var state = await service.InitializeLocalStateAsync(new App.InitializeLocalStateCommand(
        EntityUid.New(), created.AccountUid, created.ProfileRevision.RevisionUid, manifest.ManifestUid, manifest.ContentSha256,
        "copy lobby", 100, null, null, null, null, [new("credit", 1), new("jewel", 2)]));
    var workspace = (await service.GetAccountWorkspaceAsync(created.AccountUid))!;
    var preview = await service.PreviewProfileEditsAsync(new App.ProfileEditPreviewCommand(
        EntityUid.New(), created.AccountUid, created.ProfileRevision.RevisionUid, []));
    var command = new App.SaveAccountWorkspaceCommand(EntityUid.New(), true, created.AccountUid,
        workspace.BaseRevisions.RevisionSetSha256, created.ProfileRevision.RevisionUid,
        state.Lobby.Revision.RevisionUid, state.Wallet.Revision.RevisionUid,
        preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256, workspace.AccountLabel,
        "pinned copy", state.Lobby.DisplayName, state.Lobby.CommanderLevel, null, null, null, null, state.Wallet.Balances);
    // Interrupt after pinning provenance but before a copy profile exists.
    var (table, condition) = WorkspaceStageTrigger("profile");
    await InstallWorkspaceStageFaultAsync(dataSource, table, condition);
    try { await Assert.ThrowsAsync<App.ProfileManagementException>(() => service.SaveAccountWorkspaceAsync(command)); }
    finally { await RemoveWorkspaceStageFaultAsync(dataSource, table); }
    var laterObservation = await FetchAsync(6);
    Assert.NotEqual(originalObservation, laterObservation);
    var saved = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    Assert.Equal(originalObservation, saved.ObservationSourceSnapshotUid);
    Assert.Equal(saved with { IsIdempotentReplay = true }, await Service(dataSource).SaveAccountWorkspaceAsync(command));
    var child = (await service.GetLatestFetchedAccountSnapshotAsync(saved.AccountUid))!;
    Assert.Equal(originalObservation, child.SnapshotUid);
    Assert.Equal(created.AccountUid, child.TargetAccountUid);
    Assert.Null((await service.GetAccountWorkspaceAsync(saved.AccountUid))!.FetchedSnapshotUid);
    Assert.Equal(laterObservation, (await service.GetAccountWorkspaceAsync(created.AccountUid))!.FetchedSnapshotUid);
  }

  private static async Task<App.SaveAccountWorkspaceCommand> CreateWorkspaceSaveFixtureAsync(NpgsqlDataSource dataSource, bool saveAs)
  {
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var created = await new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator())
        .CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), CreateSyntheticProfileWithOwnedCube(catalogs), TestInstant));
    var service = Service(dataSource);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var state = await service.InitializeLocalStateAsync(new App.InitializeLocalStateCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, manifest.ManifestUid, manifest.ContentSha256,
        "save before", 100, null, null, catalogs.CharacterUids[0], null, [new("credit", 100), new("jewel", 200)]));
    var workspace = (await service.GetAccountWorkspaceAsync(created.AccountUid))!;
    var preview = await service.PreviewProfileEditsAsync(new App.ProfileEditPreviewCommand(EntityUid.New(), created.AccountUid,
        created.ProfileTemplateRevisionUid, [new("character_level", catalogs.CharacterUids[0], "integer", IntegerValue: 201)]));
    return new App.SaveAccountWorkspaceCommand(EntityUid.New(), saveAs, created.AccountUid,
        workspace.BaseRevisions.RevisionSetSha256, created.ProfileTemplateRevisionUid,
        state.Lobby.Revision.RevisionUid, state.Wallet.Revision.RevisionUid,
        preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256,
        workspace.AccountLabel, "save after", "save after", 101, null, null, catalogs.CharacterUids[0], null,
        [new("credit", 300), new("jewel", 400)]);
  }

  private static async Task<App.SaveAccountWorkspaceCommand> CreateNextWorkspaceSaveAsync(
      NpgsqlDataSource dataSource, App.SaveAccountWorkspaceCommand previous, EntityUid accountUid)
  {
    var service = Service(dataSource);
    var workspace = (await service.GetAccountWorkspaceAsync(accountUid))!;
    var state = (await service.GetCurrentBootstrapAsync(accountUid))!;
    var preview = await service.PreviewProfileEditsAsync(new App.ProfileEditPreviewCommand(
        EntityUid.New(), accountUid, workspace.BaseRevisions.ProfileRevisionUid, []));
    return previous with
    {
      OperationUid = EntityUid.New(),
      SaveAs = false,
      SourceAccountUid = accountUid,
      ExpectedWorkspaceRevisionSetSha256 = workspace.BaseRevisions.RevisionSetSha256,
      ExpectedProfileRevisionUid = workspace.BaseRevisions.ProfileRevisionUid,
      ExpectedLobbyRevisionUid = state.Lobby.Revision.RevisionUid,
      ExpectedWalletRevisionUid = state.Wallet.Revision.RevisionUid,
      CandidateDraftUid = preview.CandidateDraftUid,
      CandidateSha256 = preview.CandidateSha256,
      ExpectedDiffSha256 = preview.DiffSha256,
      ExpectedAccountLabel = workspace.AccountLabel,
      AccountLabel = "next save",
      CommanderLevel = 102
    };
  }

  private static (string Table, string Condition) WorkspaceStageTrigger(string stage) => stage switch
  {
    "profile" => ("lab_profile.profile_write_operation", "TRUE"),
    "resolution" => ("lab_profile.account_workspace_save_operation", "NEW.resolved_lobby_revision_uid IS NOT NULL"),
    "lobby" => ("lab_local_game.client_state_write_operation", "NEW.operation_kind = 'save_lobby'"),
    "wallet" => ("lab_local_game.client_state_write_operation", "NEW.operation_kind = 'save_wallet'"),
    "label" => ("lab_profile.account_workspace", "NEW.account_label = 'save after'"),
    "initialize" => ("lab_local_game.account_client_state", "TRUE"),
    "provenance" => ("lab_profile.account_observation_provenance_binding", "TRUE"),
    "completion" => ("lab_profile.account_workspace_save_operation", "NEW.operation_status = 'completed'"),
    _ => throw new ArgumentOutOfRangeException(nameof(stage))
  };

  private static async Task InstallWorkspaceStageFaultAsync(NpgsqlDataSource dataSource, string table, string condition)
  {
    // Identifiers/conditions come only from the fixed synthetic stage list above.
    await using var setup = dataSource.CreateCommand($$"""
        CREATE FUNCTION public.synthetic_workspace_stage_fault() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF {{condition}} THEN RAISE EXCEPTION 'synthetic_workspace_stage_interrupted'; END IF;
          RETURN NEW;
        END; $$;
        CREATE TRIGGER synthetic_workspace_stage_fault BEFORE INSERT OR UPDATE ON {{table}}
        FOR EACH ROW EXECUTE FUNCTION public.synthetic_workspace_stage_fault();
        """);
    await setup.ExecuteNonQueryAsync();
  }

  private static async Task RemoveWorkspaceStageFaultAsync(NpgsqlDataSource dataSource, string table)
  {
    await using var cleanup = dataSource.CreateCommand($"DROP TRIGGER synthetic_workspace_stage_fault ON {table}; DROP FUNCTION public.synthetic_workspace_stage_fault();");
    await cleanup.ExecuteNonQueryAsync();
  }

  private static async Task<string?> WorkspaceSaveStatusAsync(NpgsqlDataSource dataSource, EntityUid operationUid)
  {
    await using var query = dataSource.CreateCommand("SELECT operation_status FROM lab_profile.account_workspace_save_operation WHERE operation_uid = @operation;");
    query.Parameters.AddWithValue("operation", operationUid.Value);
    return await query.ExecuteScalarAsync() as string;
  }

  private static async Task<string> WorkspaceRevisionCountsAsync(NpgsqlDataSource dataSource)
  {
    await using var query = dataSource.CreateCommand("""
        SELECT concat_ws(':',
          (SELECT count(*) FROM lab_profile.profile_template_revision),
          (SELECT count(*) FROM lab_local_game.lobby_presentation_revision),
          (SELECT count(*) FROM lab_local_game.wallet_revision),
          (SELECT count(*) FROM lab_profile.profile_write_operation),
          (SELECT count(*) FROM lab_local_game.client_state_write_operation),
          (SELECT count(*) FROM lab_profile.account_observation_provenance_binding));
        """);
    return (string)(await query.ExecuteScalarAsync())!;
  }
}
