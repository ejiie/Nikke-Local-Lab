using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  [Theory]
  [InlineData(false, false)]
  [InlineData(true, false)]
  [InlineData(false, true)]
  [InlineData(true, true)]
  public async Task RuntimeExportRejectsUnfinishedWorkspaceSave(bool saveAs, bool interruptCompletion)
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var created = await profileStore.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(), CreateSyntheticProfileWithOwnedCube(catalogs), TestInstant));
    var service = Service(dataSource);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initialized = await service.InitializeLocalStateAsync(new App.InitializeLocalStateCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
        manifest.ManifestUid, manifest.ContentSha256, "snapshot before", 100,
        null, null, catalogs.CharacterUids[0], null, [new("credit", 100), new("jewel", 200)]));
    var workspace = Assert.IsType<App.AccountWorkspaceProjection>(await service.GetAccountWorkspaceAsync(created.AccountUid));
    var before = Assert.IsType<App.RuntimeProjectionCandidate>(await service.ExportRuntimeProjectionCandidateAsync(created.AccountUid));
    var sibling = await profileStore.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(), CreateSyntheticProfileWithOwnedCube(catalogs, 203), TestInstant,
        "independent sibling", created.AccountUid));
    var siblingBefore = Assert.IsType<App.RuntimeProjectionCandidate>(await service.ExportRuntimeProjectionCandidateAsync(sibling.AccountUid));
    var preview = await service.PreviewProfileEditsAsync(new App.ProfileEditPreviewCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
        [new App.ProfileEditOperation("character_level", catalogs.CharacterUids[0], "integer", IntegerValue: 201)]));
    var command = new App.SaveAccountWorkspaceCommand(EntityUid.New(), saveAs, created.AccountUid,
        workspace.BaseRevisions.RevisionSetSha256, created.ProfileTemplateRevisionUid,
        initialized.Lobby.Revision.RevisionUid, initialized.Wallet.Revision.RevisionUid,
        preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256,
        workspace.AccountLabel, "snapshot after", "snapshot after", 101,
        null, null, catalogs.CharacterUids[0], null, [new("credit", 300), new("jewel", 400)]);

    // Pause the real orchestration after all child commits but before its completion seal.
    await using var barrier = await dataSource.OpenConnectionAsync();
    await using (var setup = new NpgsqlCommand($$"""
        SELECT pg_advisory_lock(730031);
        CREATE FUNCTION public.synthetic_pause_workspace_completion() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.operation_status = 'completed' THEN
            PERFORM pg_advisory_xact_lock(730031);
            {{(interruptCompletion ? "RAISE EXCEPTION 'synthetic_workspace_completion_interrupted';" : "")}}
          END IF;
          RETURN NEW;
        END; $$;
        CREATE TRIGGER synthetic_pause_workspace_completion
        BEFORE UPDATE ON lab_profile.account_workspace_save_operation
        FOR EACH ROW EXECUTE FUNCTION public.synthetic_pause_workspace_completion();
        """, barrier))
    {
      await setup.ExecuteNonQueryAsync();
    }
    var save = service.SaveAccountWorkspaceAsync(command);
    EntityUid targetUid = created.AccountUid;
    App.SaveAccountWorkspaceReceipt saved;
    try
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
      while (true)
      {
        await using var waiting = dataSource.CreateCommand(
            "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=730031 AND NOT granted);");
        if (Equals(true, await waiting.ExecuteScalarAsync(deadline.Token))) break;
        if (save.IsCompleted) await save; // Surface a failed writer instead of timing out on the barrier.
        await Task.Delay(10, deadline.Token);
      }
      if (saveAs)
      {
        targetUid = (await service.ListAccountsAsync()).Single(item => item.AccountLabel == "snapshot after").AccountUid;
        var source = Assert.IsType<App.RuntimeProjectionCandidate>(await service.ExportRuntimeProjectionCandidateAsync(created.AccountUid));
        Assert.Equal(before.CandidateSha256, source.CandidateSha256);
      }
      // Editing/repair reads remain available while launch/export is not admissible.
      Assert.NotNull(await service.GetAccountWorkspaceAsync(targetUid));
      var siblingDuring = Assert.IsType<App.RuntimeProjectionCandidate>(await service.ExportRuntimeProjectionCandidateAsync(sibling.AccountUid));
      Assert.Equal(siblingBefore.CandidateSha256, siblingDuring.CandidateSha256);
      var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(
          () => Service(dataSource).ExportRuntimeProjectionCandidateAsync(targetUid));
      Assert.Equal(App.ProfileManagementFailureKind.Conflict, failure.Kind);
      Assert.Equal("account_workspace_save_pending", failure.Code);
      var launchFailure = await Assert.ThrowsAsync<App.ProfileManagementException>(
          () => Service(dataSource).GetRuntimeProjectionSnapshotAsync(targetUid));
      Assert.Equal("account_workspace_save_pending", launchFailure.Code);
    }
    finally
    {
      await using var release = new NpgsqlCommand("SELECT pg_advisory_unlock(730031);", barrier);
      await release.ExecuteNonQueryAsync();
      try
      {
        if (interruptCompletion)
        {
          await Assert.ThrowsAsync<App.ProfileManagementException>(() => save);
          var pending = await Assert.ThrowsAsync<App.ProfileManagementException>(
              () => Service(dataSource).GetRuntimeProjectionSnapshotAsync(targetUid));
          Assert.Equal("account_workspace_save_pending", pending.Code);
        }
        else { await save; }
      }
      finally
      {
        await using var cleanup = dataSource.CreateCommand("""
            DROP TRIGGER synthetic_pause_workspace_completion ON lab_profile.account_workspace_save_operation;
            DROP FUNCTION public.synthetic_pause_workspace_completion();
            """);
        await cleanup.ExecuteNonQueryAsync();
      }
    }
    saved = await Service(dataSource).SaveAccountWorkspaceAsync(command);
    var candidate = Assert.IsType<App.RuntimeProjectionCandidate>(await Service(dataSource).ExportRuntimeProjectionCandidateAsync(targetUid));
    Assert.Equal(saved.ProfileRevision.RevisionUid, candidate.BaseRevisions.ProfileRevisionUid);
    Assert.Equal("snapshot after", candidate.AccountLabel);
    Assert.Equal(201, candidate.Values.Single(item => item.FieldCode == "character_level" && item.SubjectUid == catalogs.CharacterUids[0]).IntegerValue);
    Assert.Equal(saved with { IsIdempotentReplay = true }, await Service(dataSource).SaveAccountWorkspaceAsync(command));
    var launch = Assert.IsType<App.RuntimeProjectionSnapshot>(await Service(dataSource).GetRuntimeProjectionSnapshotAsync(targetUid));
    Assert.Equal(candidate.CandidateSha256, launch.Candidate.CandidateSha256);
    Assert.Equal(saved.LobbyRevision, launch.Lobby!.Revision);
    Assert.Equal("snapshot after", launch.Lobby.DisplayName);
    var current = Assert.IsType<App.AccountBootstrapProjection>(await service.GetCurrentBootstrapAsync(targetUid));
    var noChange = await service.PreviewProfileEditsAsync(new App.ProfileEditPreviewCommand(
        EntityUid.New(), targetUid, saved.ProfileRevision.RevisionUid, []));
    Assert.Empty(noChange.Changes);
    var noOp = await service.SaveAccountWorkspaceAsync(command with
    {
      OperationUid = EntityUid.New(),
      SaveAs = false,
      SourceAccountUid = targetUid,
      ExpectedWorkspaceRevisionSetSha256 = candidate.BaseRevisions.RevisionSetSha256,
      ExpectedProfileRevisionUid = saved.ProfileRevision.RevisionUid,
      ExpectedLobbyRevisionUid = saved.LobbyRevision.RevisionUid,
      ExpectedWalletRevisionUid = current.Wallet.Revision.RevisionUid,
      ExpectedAccountLabel = candidate.AccountLabel,
      CandidateDraftUid = noChange.CandidateDraftUid,
      CandidateSha256 = noChange.CandidateSha256,
      ExpectedDiffSha256 = noChange.DiffSha256
    });
    Assert.Equal(saved.ProfileRevision, noOp.ProfileRevision);
    Assert.Equal(saved.LobbyRevision, noOp.LobbyRevision);
    Assert.Equal(candidate.CandidateSha256, (await service.GetRuntimeProjectionSnapshotAsync(targetUid))!.Candidate.CandidateSha256);
  }

  [Fact]
  public async Task RuntimeSnapshotDoesNotInitializeMissingLocalState()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var created = await profileStore.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(), CreateSyntheticProfile(catalogs), TestInstant));
    var service = Service(dataSource);
    Assert.Null(await service.GetRuntimeProjectionSnapshotAsync(EntityUid.New()));
    Assert.Null(await service.ExportRuntimeProjectionCandidateAsync(EntityUid.New()));
    var snapshot = Assert.IsType<App.RuntimeProjectionSnapshot>(await service.GetRuntimeProjectionSnapshotAsync(created.AccountUid));
    Assert.Null(snapshot.Lobby);
    Assert.Equal(created.ProfileTemplateRevisionUid, snapshot.Candidate.BaseRevisions.ProfileRevisionUid);
    Assert.DoesNotContain(snapshot.Candidate.Values, item => item.FieldCode == "account_cube_level");
    await using var count = dataSource.CreateCommand("SELECT count(*) FROM lab_local_game.account_client_state;");
    Assert.Equal(0L, await count.ExecuteScalarAsync());
  }

  [Fact]
  public async Task RuntimeSnapshotDoesNotRefreshComponentsAfterConcurrentHeadAdvance()
  {
    await using var dataSource = CreateDataSource();
    await ResetAndMigrateAsync(dataSource);
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var created = await profileStore.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(), CreateSyntheticProfileWithOwnedCube(catalogs), TestInstant));
    var service = Service(dataSource);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initialized = await service.InitializeLocalStateAsync(new App.InitializeLocalStateCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
        manifest.ManifestUid, manifest.ContentSha256, "pinned lobby", 100,
        null, null, catalogs.CharacterUids[0], null, [new("credit", 100), new("jewel", 200)]));
    var before = Assert.IsType<App.RuntimeProjectionSnapshot>(await service.GetRuntimeProjectionSnapshotAsync(created.AccountUid));

    // Block the pending-operation SELECT after the workspace SELECT has fixed its
    // MVCC snapshot. Independent profile/lobby writers do not use this ledger.
    await using var barrier = await dataSource.OpenConnectionAsync();
    await using var transaction = await barrier.BeginTransactionAsync();
    await using (var hold = new NpgsqlCommand("LOCK TABLE lab_profile.account_workspace_save_operation IN ACCESS EXCLUSIVE MODE;", barrier, transaction))
      await hold.ExecuteNonQueryAsync();
    var reading = Service(dataSource).GetRuntimeProjectionSnapshotAsync(created.AccountUid);
    try
    {
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
      while (true)
      {
        await using var waiting = dataSource.CreateCommand("""
            SELECT EXISTS (SELECT 1 FROM pg_locks
              WHERE relation = 'lab_profile.account_workspace_save_operation'::regclass AND NOT granted);
            """);
        if (Equals(true, await waiting.ExecuteScalarAsync(deadline.Token))) break;
        if (reading.IsCompleted) { await reading; Assert.Fail("reader did not reach snapshot barrier"); }
        await Task.Delay(10, deadline.Token);
      }
      var advanced = await profileStore.SaveAsync(new SaveLocalAccountProfileCommand(
          EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
          CreateSyntheticProfileWithOwnedCube(catalogs, 202), TestInstant.AddSeconds(1)));
      var revalidated = Assert.IsType<App.LobbyPresentationProjection>(await service.GetLobbyPresentationAsync(created.AccountUid));
      await service.SaveLobbyPresentationAsync(new App.SaveLobbyPresentationCommand(
          EntityUid.New(), created.AccountUid, revalidated.Revision.RevisionUid,
          "new lobby", 200, null, null, catalogs.CharacterUids[0], null));
      await service.RenameAccountAsync(new App.RenameAccountCommand(created.AccountUid, before.Candidate.AccountLabel, "new label"));
      Assert.NotEqual(created.ProfileTemplateRevisionUid, advanced.ProfileTemplateRevisionUid);
    }
    finally { await transaction.RollbackAsync(); }

    var pinned = Assert.IsType<App.RuntimeProjectionSnapshot>(await reading);
    Assert.Equal(before.Candidate.CandidateSha256, pinned.Candidate.CandidateSha256);
    Assert.Equal(initialized.Lobby.Revision, pinned.Lobby!.Revision);
    Assert.Equal("pinned lobby", pinned.Lobby.DisplayName);
    var after = Assert.IsType<App.RuntimeProjectionSnapshot>(await Service(dataSource).GetRuntimeProjectionSnapshotAsync(created.AccountUid));
    Assert.NotEqual(pinned.Candidate.BaseRevisions.ProfileRevisionUid, after.Candidate.BaseRevisions.ProfileRevisionUid);
    Assert.Equal("new label", after.Candidate.AccountLabel);
    Assert.Equal("new lobby", after.Lobby!.DisplayName);
    Assert.Equal(202, after.Candidate.Values.Single(item => item.FieldCode == "character_level" && item.SubjectUid == catalogs.CharacterUids[0]).IntegerValue);
    var workspace = Assert.IsType<App.AccountWorkspaceProjection>(await service.GetAccountWorkspaceAsync(created.AccountUid));
    Assert.Equal(after.Candidate.BaseRevisions, workspace.BaseRevisions);
    Assert.Equal(after.Candidate.ValidationStatusCode, workspace.ValidationStatusCode);
  }
}
