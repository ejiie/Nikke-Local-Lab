using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  [Fact]
  public async Task FullAccountImportAdvancesCatalogAndReplaysWithoutChangingOldRevision()
  {
    await using var source = CreateDataSource();
    await ResetSchemasAsync(source);
    await ApplyWorkspaceTestMigrationsAsync(source, MigrationBaseline.Count);
    var oldCatalog = await PublishCatalogFixtureAsync(source, 5);
    var oldDraft = await ImportStrictDraftAsync(source, oldCatalog,
        CharacterLevelAuthorityPolicy.RosterObservationV1, TestInstant);
    var service = DefaultTransformerService(source);
    var account = await CreateAccountFromImportAsync(service, oldDraft, RosterLevelAuthority);
    var oldProfile = (await service.GetCurrentProfileAsync(account.AccountUid))!;
    var currentCatalog = await PublishCatalogFixtureAsync(source, 6, "updated-character");
    Assert.NotEqual(oldCatalog.CharacterBinding, currentCatalog.CharacterBinding);
    var incoming = await ImportStrictDraftAsync(source, currentCatalog,
        CharacterLevelAuthorityPolicy.RosterObservationV1, TestInstant.AddMinutes(1));
    var previewCommand = new App.ImportDiffCommand(EntityUid.New(), incoming.Receipt.DraftUid,
        incoming.Receipt.CanonicalPayloadSha256, account.AccountUid, account.ProfileRevision.RevisionUid,
        RosterLevelAuthority, ["full_profile"]);
    var partial = await Assert.ThrowsAsync<App.ProfileManagementException>(() => service.PreviewImportDiffAsync(
        previewCommand with { OperationUid = EntityUid.New(), Scopes = ["builds_only"] }));
    Assert.Equal("sanitized_profile_catalog_rebase_required", partial.Code);
    var preview = await service.PreviewImportDiffAsync(previewCommand);
    var apply = new App.ApplyImportCommand(previewCommand.OperationUid, previewCommand.DraftUid,
        previewCommand.ExpectedDraftSha256, account.AccountUid, account.ProfileRevision.RevisionUid,
        preview.DiffSha256, RosterLevelAuthority, ["full_profile"]);
    var written = await service.ApplyImportAsync(apply);
    var replay = await service.ApplyImportAsync(apply);
    Assert.Equal(written.ProfileRevision, replay.ProfileRevision);
    Assert.Equal(account.AccountUid, written.AccountUid);
    var after = (await service.GetCurrentProfileAsync(account.AccountUid))!;
    Assert.Equal(currentCatalog.CharacterBinding.CatalogSnapshotUid, after.CharacterCatalog.CatalogSnapshotUid);
    Assert.NotEqual(oldProfile.ProfileRevision, after.ProfileRevision);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var method = typeof(PostgreSqlLocalAccountProfileStore).GetMethod("GetRevisionAsync",
        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!;
    var historical = Assert.IsType<LocalCurrentAccountProfile>(await InvokeTaskResultAsync(method, store,
        account.AccountUid, account.ProfileRevision.RevisionUid, CancellationToken.None));
    Assert.Equal(oldCatalog.CharacterBinding, historical.Profile.CharacterCatalog);
  }
}
