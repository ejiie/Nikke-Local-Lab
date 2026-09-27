using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalAccountProfileTests
{
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task CharacterOwnershipAddsBaseBuildWithoutOverwritingOwnedBuildsAndReplays(bool synchronizeCatalog)
  {
    await using var dataSource = CreateDataSource();
    await ResetProfileTestDatabaseAsync(dataSource);
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, synchronizeCatalog ? 5 : 6);
    var support = await ReadSupportSelectionsAsync(dataSource, catalogs.Support.CatalogSnapshotUid);
    var seed = CreateProfile(catalogs, support, 200, null, false);
    var owned = seed.Builds.Take(5).ToArray();
    var initial = new LocalAccountProfileWrite(seed.CharacterCatalog, seed.CombatSupportCatalog,
        seed.AccountState, owned, owned.Select(build => build.CharacterUid), seed.SquadOrigin, seed.ProfileTemplateOrigin);
    var store = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var created = await store.CreateAsync(new(EntityUid.New(), initial, new(2026, 9, 16, 0, 0, 0, TimeSpan.Zero)));
    if (synchronizeCatalog)
    {
      catalogs = await PublishSyntheticCatalogsAsync(dataSource, 6, characterSnapshotTag: "new-character-update");
      seed = CreateProfile(catalogs, support, 200, null, false);
    }
    var service = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    var operations = seed.Builds.Select(build => new App.ProfileEditOperation(
        "character_owned", build.CharacterUid, "boolean", BooleanValue: true)).ToList();
    if (synchronizeCatalog) operations.Add(new("character_catalog", null, "reference",
        ReferenceUid: seed.CharacterCatalog.CatalogSnapshotUid));
    var preview = await service.PreviewProfileEditsAsync(new(EntityUid.New(), created.AccountUid,
        created.ProfileTemplateRevisionUid, operations));
    Assert.Equal(5, (await store.GetCurrentAsync(created.AccountUid))!.Profile.Builds.Count);
    var save = new App.SaveProfileCommand(EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
        preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256);
    var saved = await service.SaveProfileAsync(save);
    var reopened = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    Assert.True((await reopened.SaveProfileAsync(save)).IsIdempotentReplay);
    var after = (await store.GetCurrentAsync(created.AccountUid))!;
    Assert.Equal(6, after.Profile.Builds.Count);
    Assert.Equal(seed.CharacterCatalog, after.Profile.CharacterCatalog);
    foreach (var before in owned)
    {
      var preserved = after.Profile.Builds.Single(build => build.CharacterUid == before.CharacterUid);
      Assert.Equal(before.CharacterLevel, preserved.CharacterLevel);
      Assert.Equal(before.CoreLevel, preserved.CoreLevel);
      Assert.Equal(before.Skill1Level, preserved.Skill1Level);
      Assert.Equal(System.Text.Json.JsonSerializer.Serialize(before), System.Text.Json.JsonSerializer.Serialize(preserved));
    }
    Assert.Equal(initial.SquadCharacterUids, after.Profile.SquadCharacterUids);
    var added = Assert.Single(after.Profile.Builds, build => owned.All(old => old.CharacterUid != build.CharacterUid));
    Assert.Equal(1, added.CharacterLevel);
    Assert.Equal(0, added.LimitBreak.Value);
    Assert.Equal(0, added.CoreLevel.Value);
    Assert.Equal(1, added.BondLevel.Value);
    Assert.Equal(1, added.Skill1Level.Value);
    Assert.Equal(1, added.Skill2Level.Value);
    Assert.Equal(1, added.BurstLevel.Value);
    Assert.All(added.Equipment, item => Assert.Equal(LocalEquipmentState.Unequipped, item.State));
    Assert.Equal(LocalOptionalSelectionState.Unequipped, added.Cube.State);
    Assert.Equal(LocalCollectionSelectionKind.Detached, added.Collection.Kind);
    var repeat = await reopened.PreviewProfileEditsAsync(new(EntityUid.New(), created.AccountUid,
        saved.ProfileRevision.RevisionUid, operations));
    Assert.Empty(repeat.Changes);
    var noOp = await reopened.SaveProfileAsync(new(EntityUid.New(), created.AccountUid,
        saved.ProfileRevision.RevisionUid, repeat.CandidateDraftUid, repeat.CandidateSha256, repeat.DiffSha256));
    Assert.Equal(saved.ProfileRevision, noOp.ProfileRevision);
    var copy = await reopened.SaveAsProfileAsync(new(EntityUid.New(), created.AccountUid,
        saved.ProfileRevision.RevisionUid, repeat.CandidateDraftUid, repeat.CandidateSha256, repeat.DiffSha256));
    Assert.Equal(6, (await store.GetCurrentAsync(copy.AccountUid))!.Profile.Builds.Count);
    foreach (var operation in new[] {
        new App.ProfileEditOperation("character_owned", EntityUid.New(), "boolean", BooleanValue: true),
        new App.ProfileEditOperation("character_owned", added.CharacterUid, "boolean", BooleanValue: false) })
      await Assert.ThrowsAsync<App.ProfileManagementException>(() => reopened.PreviewProfileEditsAsync(new(
          EntityUid.New(), created.AccountUid, saved.ProfileRevision.RevisionUid, [operation])));
  }
}
