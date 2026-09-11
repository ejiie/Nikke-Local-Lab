using System.Collections;
using System.Reflection;
using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  [Fact]
  public async Task ReadinessCachePinsImmutableRevisionAndNeverCachesMutableSummary()
  {
    await using var source = CreateDataSource();
    await ResetAndMigrateAsync(source);
    var catalogs = await PublishCatalogFixtureAsync(source, 5);
    var profile = CreateSyntheticProfileWithOwnedCube(catalogs, null);
    var unresolved = new LocalAccountProfileWrite(profile.CharacterCatalog, profile.CombatSupportCatalog,
        new LocalAccountCombatStateWrite(LocalProfileFact<int>.Unresolved(new("fixture_cache_unresolved")),
            profile.AccountState.Consoles, profile.AccountState.ValidationMode, profile.AccountState.Origin, profile.AccountState.Cubes),
        profile.Builds, profile.SquadCharacterUids, profile.SquadOrigin, profile.ProfileTemplateOrigin);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var first = await store.CreateAsync(new(EntityUid.New(), unresolved, TestInstant, "cache-a"));
    var other = await store.CreateAsync(new(EntityUid.New(), profile, TestInstant, "cache-b"));
    var service = Service(source);
    var initial = await service.ListAccountsAsync();
    Assert.Contains("fixture_cache_unresolved", initial.Single(row => row.AccountUid == first.AccountUid).ValidationReasonCodes);
    Assert.DoesNotContain("fixture_cache_unresolved", initial.Single(row => row.AccountUid == other.AccountUid).ValidationReasonCodes);
    Assert.Equal(2, Cache(service).Count);
    for (var iteration = 0; iteration < 3; iteration++)
      Assert.Equal(initial, await service.ListAccountsAsync());
    var renamed = await service.RenameAccountAsync(new(other.AccountUid, "cache-b", "cache-0"));
    Assert.Equal("cache-0", (await service.ListAccountsAsync())[0].AccountLabel);
    Assert.Equal(other.AccountUid, renamed.AccountUid);

    var oldSummary = initial.Single(row => row.AccountUid == first.AccountUid);
    var saved = await store.SaveAsync(new(EntityUid.New(), first.AccountUid, first.ProfileTemplateRevisionUid,
        CreateSyntheticProfileWithOwnedCube(catalogs, 222), TestInstant.AddSeconds(1)));
    var concurrent = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => service.ListAccountsAsync()));
    Assert.All(concurrent, rows => Assert.Equal(saved.ProfileTemplateRevisionUid,
        rows.Single(row => row.AccountUid == first.AccountUid).ProfileRevision.RevisionUid));
    Assert.All(concurrent, rows => Assert.DoesNotContain("fixture_cache_unresolved",
        rows.Single(row => row.AccountUid == first.AccountUid).ValidationReasonCodes));
    Assert.Equal(3, Cache(service).Count);
    // A previously read summary remains pinned even if Save commits before hydration.
    Assert.Equal(oldSummary, await HydrateSummaryAsync(service, oldSummary));
    var fresh = Service(source);
    Assert.Empty(Cache(fresh));
    Assert.Equal(System.Text.Json.JsonSerializer.Serialize(await fresh.ListAccountsAsync()),
        System.Text.Json.JsonSerializer.Serialize(await service.ListAccountsAsync()));
    var badHash = oldSummary with { ProfileRevision = oldSummary.ProfileRevision with { ContentSha256 = Sha256Digest.ComputeUtf8("not-the-revision") } };
    await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() => HydrateSummaryAsync(service, badHash));
    var wrongOwner = oldSummary with { AccountUid = other.AccountUid };
    await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() => HydrateSummaryAsync(service, wrongOwner));
    Assert.Equal(3, Cache(service).Count);
    using var canceled = new CancellationTokenSource();
    canceled.Cancel();
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.ListAccountsAsync(canceled.Token));
    Assert.Equal(3, Cache(service).Count);
  }

  [Fact]
  public async Task ReadinessCacheEvictsOldRevisionAndRemainsBounded()
  {
    await using var source = CreateDataSource();
    await ResetAndMigrateAsync(source);
    var catalogs = await PublishCatalogFixtureAsync(source, 5);
    var profile = CreateSyntheticProfileWithOwnedCube(catalogs, null);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var saved = await store.CreateAsync(new(EntityUid.New(), profile, TestInstant));
    var service = Service(source);
    var first = Assert.Single(await service.ListAccountsAsync());
    for (var revision = 1; revision <= 256; revision++)
    {
      saved = await store.SaveAsync(new(EntityUid.New(), saved.AccountUid, saved.ProfileTemplateRevisionUid,
          CreateSyntheticProfileWithOwnedCube(catalogs, 200 + revision % 2), TestInstant.AddSeconds(revision)));
      Assert.Equal(saved.ProfileTemplateRevisionUid, Assert.Single(await service.ListAccountsAsync()).ProfileRevision.RevisionUid);
    }
    Assert.Equal(256, Cache(service).Count);
    Assert.False(Cache(service).Contains((first.AccountUid, first.ProfileRevision)));
    Assert.Equal(System.Text.Json.JsonSerializer.Serialize(first),
        System.Text.Json.JsonSerializer.Serialize(await HydrateSummaryAsync(service, first)));
    Assert.Equal(256, Cache(service).Count);
  }

  private static IDictionary Cache(PostgreSqlProfileManagementService service) => (IDictionary)
      typeof(PostgreSqlProfileManagementService).GetField("_readiness", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(service)!;

  private static Task<App.AccountSummaryProjection> HydrateSummaryAsync(PostgreSqlProfileManagementService service, App.AccountSummaryProjection summary) =>
      (Task<App.AccountSummaryProjection>)typeof(PostgreSqlProfileManagementService)
          .GetMethod("WithRuntimeMaterializationReadinessAsync", BindingFlags.NonPublic | BindingFlags.Instance)!
          .Invoke(service, [summary, CancellationToken.None])!;
}
