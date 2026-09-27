using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using App = NikkeLocalLab.Application.ProfileManagement;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalAccountProfileTests
{
  [Fact]
  public async Task DirectoryCreatesDefaultAccountAndMovesImportedMembershipWithoutChangingOtherAccounts()
  {
    await using var source = CreateDataSource();
    await ResetProfileTestDatabaseAsync(source);
    _ = await PublishSyntheticCatalogsAsync(source, 5);
    var profiles = new PostgreSqlProfileManagementService(source, new RandomEntityUidGenerator());
    await profiles.EnsureBuiltInFeatureManifestAsync();
    var directory = new AccountDirectoryStore(source, profiles);
    var request = new CreateDirectoryAccountCommand(EntityUid.New(),
        new(2026, 9, 18, 0, 0, 0, TimeSpan.Zero), "새 지휘관", "합성 계정");
    var first = await directory.CreateAsync(request, default);
    Assert.Equal(first, await directory.CreateAsync(request, default));
    await Assert.ThrowsAsync<App.ProfileManagementException>(() => directory.CreateAsync(request with { DisplayName = "다른 이름" }, default));
    var second = await directory.CreateAsync(request with { OperationUid = EntityUid.New(), AccountLabel = "두 번째 계정" }, default);
    var lobby = await profiles.GetLobbyPresentationAsync(first);
    Assert.Equal("새 지휘관", lobby!.DisplayName);
    Assert.Equal(1, lobby.CommanderLevel);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var original = (await store.GetCurrentAsync(first))!;
    Assert.Empty(original.Profile.Builds);
    Assert.Equal(1, original.Profile.AccountState.SynchroLevel.Value);
    Assert.All(original.Profile.AccountState.Consoles, row => Assert.Equal(0, row.Level.Value));
    var nll = Assert.Single(await directory.ListAsync(default));
    Assert.Equal("NLL", nll.Name); Assert.Equal(3, nll.Level); Assert.Equal(2, nll.Members.Count);
    var imported = new ImportedDirectoryPresentation("member", "합성 유니온", 7, new string('a', 64),
        $"/admin-api/v1/account-art/{first}-portrait-{new string('b', 64)}.png", $"/admin-api/v1/account-art/{first}-emblem-{new string('c', 64)}.png");
    await directory.ApplyImportedAsync(first, imported, default);
    await directory.ApplyImportedAsync(first, imported, default);
    var groups = await directory.ListAsync(default);
    Assert.Equal(2, groups.Count);
    Assert.Equal(second, Assert.Single(groups.Single(g => g.Name == "NLL").Members).AccountUid);
    var moved = groups.Single(g => g.Name == "합성 유니온");
    Assert.Equal(7, moved.Level); Assert.True(Assert.Single(moved.Members).Imported);
    Assert.Equal(first, moved.Members[0].AccountUid);
    Assert.Equal(original.Profile.CanonicalSha256, (await store.GetCurrentAsync(first))!.Profile.CanonicalSha256);
    await directory.ApplyImportedAsync(first, imported with { Status = "none", Name = null, Level = null, Fingerprint = null }, default);
    Assert.Equal(first, Assert.Single((await directory.ListAsync(default)).Single(g => g.Name == "소속 없음").Members).AccountUid);
    await Assert.ThrowsAsync<App.ProfileManagementException>(() => directory.ApplyImportedAsync(second,
        imported with { Level = 0 }, default));
    await Assert.ThrowsAsync<Npgsql.PostgresException>(() => directory.ApplyImportedAsync(second,
        imported with { PortraitPath = "https://example.invalid/account.png" }, default));
    Assert.Equal("NLL", (await directory.ListAsync(default)).Single(g => g.Members.Any(m => m.AccountUid == second)).Name);
  }
}
