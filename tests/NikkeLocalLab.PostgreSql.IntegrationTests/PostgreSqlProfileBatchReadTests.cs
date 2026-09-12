using System.Data;
using System.Reflection;
using System.Text.Json;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalAccountProfileTests
{
  [Fact]
  public async Task ProfileBatchReadsPreserveSharedBuildMembershipAcrossRosterAndSquadChanges()
  {
    await using var source = CreateDataSource();
    await ResetOverloadReadDatabaseAsync(source);
    var catalogs = await PublishSyntheticCatalogsAsync(source, 6);
    var support = await ReadSupportSelectionsAsync(source, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var now = new DateTimeOffset(2026, 9, 11, 0, 0, 0, TimeSpan.Zero);
    var initial = CreateOverloadReadProfile(catalogs, support, 1);
    var createCommand = new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now);
    var created = await store.CreateAsync(createCommand);
    // Identical content in another account must still have independent logical slot identities.
    var other = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var noSquad = WithProfileBatchMembership(initial, initial.Builds.Reverse(), null);
    var noSquadCommand = new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, noSquad, now.AddSeconds(1));
    var withoutSquad = await store.SaveAsync(noSquadCommand);
    Assert.NotEqual(created.ProfileTemplateRevisionUid, withoutSquad.ProfileTemplateRevisionUid);
    Assert.Null(withoutSquad.SquadRevisionUid);
    Assert.Equal(created.AccountCombatStateRevisionUid, withoutSquad.AccountCombatStateRevisionUid);
    foreach (var build in created.Builds)
    {
      AssertProfileBatchBuildReceipt(build, Assert.Single(withoutSquad.Builds,
          candidate => candidate.CharacterUid == build.CharacterUid));
    }

    var changedUid = initial.Builds.First(build => build.Equipment.Any(
        equipment => equipment.OverloadLines.Count > 0)).CharacterUid;
    var removedUid = initial.Builds[4].CharacterUid;
    Assert.NotEqual(changedUid, removedUid);
    var replacement = CreateOverloadReadProfile(catalogs, support, 2).Builds.Single(
        build => build.CharacterUid == changedUid);
    var reduced = WithProfileBatchMembership(initial, initial.Builds.Reverse()
        .Where(build => build.CharacterUid != removedUid)
        .Select(build => build.CharacterUid == changedUid ? replacement : build), null);
    var reducedCommand = new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, withoutSquad.ProfileTemplateRevisionUid, reduced, now.AddSeconds(2));
    var reducedReceipt = await store.SaveAsync(reducedCommand);
    Assert.Equal(5, reducedReceipt.Builds.Count);
    Assert.DoesNotContain(reducedReceipt.Builds, build => build.CharacterUid == removedUid);
    var previousChanged = created.Builds.Single(build => build.CharacterUid == changedUid);
    var changedReceipt = Assert.Single(reducedReceipt.Builds, build => build.CharacterUid == changedUid);
    Assert.Equal(previousChanged.CharacterBuildUid, changedReceipt.CharacterBuildUid);
    Assert.NotEqual(previousChanged.CharacterBuildRevisionUid, changedReceipt.CharacterBuildRevisionUid);
    Assert.NotEqual(previousChanged.ContentSha256, changedReceipt.ContentSha256);
    Assert.Equal(previousChanged.CharacterBuildRevisionUid, changedReceipt.Lineage.PreviousRevisionUid);
    Assert.Equal(previousChanged.Lineage.RevisionNumber + 1, changedReceipt.Lineage.RevisionNumber);
    Assert.Equal(previousChanged.EquipmentSlots.ToArray(), changedReceipt.EquipmentSlots.ToArray());
    foreach (var build in reducedReceipt.Builds.Where(build => build.CharacterUid != changedUid))
    {
      AssertProfileBatchBuildReceipt(created.Builds.Single(original => original.CharacterUid == build.CharacterUid), build);
    }

    var readded = WithProfileBatchMembership(initial,
        reduced.Builds.Append(initial.Builds.Single(build => build.CharacterUid == removedUid)).Reverse(),
        initial.SquadCharacterUids!.Reverse());
    var restored = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, reducedReceipt.ProfileTemplateRevisionUid, readded, now.AddSeconds(3)));
    Assert.Equal(6, restored.Builds.Count);
    Assert.NotNull(restored.SquadRevisionUid);
    Assert.NotEqual(created.SquadRevisionUid, restored.SquadRevisionUid);
    foreach (var build in restored.Builds)
    {
      var expectedBuild = build.CharacterUid == changedUid ? changedReceipt : created.Builds.Single(
          original => original.CharacterUid == build.CharacterUid);
      AssertProfileBatchBuildReceipt(expectedBuild, build);
    }

    // Old operations must return their original graph, not the account's current
    // membership, even when a Save command's expected revision is now stale.
    AssertProfileBatchReplayReceipt(created, await store.CreateAsync(createCommand));
    AssertProfileBatchReplayReceipt(withoutSquad, await store.SaveAsync(noSquadCommand));
    AssertProfileBatchReplayReceipt(reducedReceipt, await store.SaveAsync(reducedCommand));
    AssertProfileBatchReplayReceipt(created, await store.GetByOperationAsync(createCommand.OperationUid));
    AssertProfileBatchReplayReceipt(withoutSquad, await store.GetByOperationAsync(noSquadCommand.OperationUid));
    AssertProfileBatchReplayReceipt(reducedReceipt, await store.GetByOperationAsync(reducedCommand.OperationUid));

    // Multiple memberships now reference each unchanged build revision. Each selected
    // profile must still yield exactly its own roster and four slots per build.
    AssertProfileBatchRead(initial, created,
        await ReadOverloadRevisionAsync(store, created.AccountUid, created.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(noSquad, withoutSquad,
        await ReadOverloadRevisionAsync(store, created.AccountUid, withoutSquad.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(reduced, reducedReceipt,
        await ReadOverloadRevisionAsync(store, created.AccountUid, reducedReceipt.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(readded, restored, await store.GetCurrentAsync(created.AccountUid));
    AssertProfileBatchRead(initial, other, await store.GetCurrentAsync(other.AccountUid));
    Assert.Empty(created.Builds.SelectMany(build => build.EquipmentSlots).Select(slot => slot.EquipmentSlotUid)
        .Intersect(other.Builds.SelectMany(build => build.EquipmentSlots).Select(slot => slot.EquipmentSlotUid)));

    // Roster input order is normalized, unlike squad position. Reversing only the
    // roster cannot create another profile or multiply its shared-build membership.
    var reorderedOnly = WithProfileBatchMembership(readded, readded.Builds.Reverse(), readded.SquadCharacterUids);
    Assert.Equal(readded.CanonicalSha256, reorderedOnly.CanonicalSha256);
    var unchanged = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, restored.ProfileTemplateRevisionUid, reorderedOnly, now.AddSeconds(4)));
    Assert.Equal(restored.ProfileTemplateRevisionUid, unchanged.ProfileTemplateRevisionUid);
    AssertProfileBatchRead(readded, restored, await store.GetCurrentAsync(created.AccountUid));
  }

  [Fact]
  public async Task ProfileBatchReadsKeepPinnedMembershipWhileConcurrentSaveChangesRosterAndBuilds()
  {
    await using var source = CreateDataSource();
    await ResetOverloadReadDatabaseAsync(source);
    var catalogs = await PublishSyntheticCatalogsAsync(source, 6);
    var support = await ReadSupportSelectionsAsync(source, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var now = new DateTimeOffset(2026, 9, 11, 0, 0, 0, TimeSpan.Zero);
    var initial = CreateOverloadReadProfile(catalogs, support, 1);
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var pinnedWrite = WithProfileBatchMembership(initial, initial.Builds.Reverse(), null);
    var pinnedReceipt = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, pinnedWrite, now.AddSeconds(1)));
    var otherWrite = CreateOverloadReadProfile(catalogs, support, 3);
    var other = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), otherWrite, now));

    await using var connection = await source.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead);
    // Establish the snapshot without holding a row lock or racing a timer.
    await using (var pin = new NpgsqlCommand(
        "SELECT local_account_uid FROM lab_profile.local_account WHERE local_account_uid = @uid;",
        connection, transaction))
    {
      pin.Parameters.AddWithValue("uid", created.AccountUid.Value);
      Assert.Equal(created.AccountUid.Value, Assert.IsType<Guid>(await pin.ExecuteScalarAsync()));
    }

    var replacement = otherWrite.Builds.First(build => build.Equipment.Any(
        equipment => equipment.OverloadLines.Count > 0));
    var changed = WithProfileBatchMembership(initial, initial.Builds.Reverse()
        .Where(build => build.CharacterUid != initial.Builds[4].CharacterUid)
        .Select(build => build.CharacterUid == replacement.CharacterUid ? replacement : build),
        initial.Builds.Where(build => build.CharacterUid != initial.Builds[4].CharacterUid)
            .Select(build => build.CharacterUid).Reverse());
    // Save uses a different connection and commits while the reader's transaction remains open.
    var saved = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, pinnedReceipt.ProfileTemplateRevisionUid, changed, now.AddSeconds(2)));
    Assert.NotEqual(pinnedReceipt.ProfileTemplateRevisionUid, saved.ProfileTemplateRevisionUid);
    Assert.Equal(5, saved.Builds.Count);
    Assert.NotNull(saved.SquadRevisionUid);
    foreach (var build in saved.Builds.Where(build => build.CharacterUid != replacement.CharacterUid))
    {
      AssertProfileBatchBuildReceipt(pinnedReceipt.Builds.Single(old => old.CharacterUid == build.CharacterUid), build);
    }

    var readMethod = typeof(PostgreSqlLocalAccountProfileStore).GetMethod(
        "GetCurrentAsync", BindingFlags.NonPublic | BindingFlags.Static, null,
        [typeof(NpgsqlConnection), typeof(NpgsqlTransaction), typeof(EntityUid), typeof(CancellationToken)], null);
    Assert.NotNull(readMethod);
    var pinned = await (Task<LocalCurrentAccountProfile?>)readMethod.Invoke(
        null, [connection, transaction, created.AccountUid, CancellationToken.None])!;
    AssertProfileBatchRead(pinnedWrite, pinnedReceipt, pinned);
    AssertProfileBatchRead(changed, saved, await store.GetCurrentAsync(created.AccountUid));
    await transaction.CommitAsync();

    AssertProfileBatchRead(initial, created,
        await ReadOverloadRevisionAsync(store, created.AccountUid, created.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(pinnedWrite, pinnedReceipt,
        await ReadOverloadRevisionAsync(store, created.AccountUid, pinnedReceipt.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(changed, saved,
        await ReadOverloadRevisionAsync(store, created.AccountUid, saved.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(otherWrite, other, await store.GetCurrentAsync(other.AccountUid));
    Assert.Null(await ReadOverloadRevisionAsync(store, created.AccountUid, other.ProfileTemplateRevisionUid));
    Assert.Null(await ReadOverloadRevisionAsync(store, other.AccountUid, saved.ProfileTemplateRevisionUid));
    Assert.Null(await ReadOverloadRevisionAsync(store, created.AccountUid, EntityUid.New()));

    await using var freshSource = CreateDataSource();
    var freshStore = new PostgreSqlLocalAccountProfileStore(freshSource, new RandomEntityUidGenerator());
    AssertProfileBatchRead(changed, saved, await freshStore.GetCurrentAsync(created.AccountUid));
    AssertProfileBatchRead(pinnedWrite, pinnedReceipt,
        await ReadOverloadRevisionAsync(freshStore, created.AccountUid, pinnedReceipt.ProfileTemplateRevisionUid));
    AssertProfileBatchRead(otherWrite, other, await freshStore.GetCurrentAsync(other.AccountUid));
  }

  [Fact]
  public async Task ProfileBatchReadsReturnEmptyRosterWithoutLeakingHistoricalBuilds()
  {
    await using var source = CreateDataSource();
    await ResetOverloadReadDatabaseAsync(source);
    var catalogs = await PublishSyntheticCatalogsAsync(source, 5);
    var support = await ReadSupportSelectionsAsync(source, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var now = new DateTimeOffset(2026, 9, 11, 0, 0, 0, TimeSpan.Zero);
    var initial = CreateOverloadReadProfile(catalogs, support, 1);
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var empty = WithProfileBatchMembership(initial, [], null);
    var saved = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, empty, now.AddSeconds(1)));
    Assert.Empty(saved.Builds);
    Assert.Null(saved.SquadRevisionUid);
    Assert.False(saved.IsCombatReady);
    AssertProfileBatchRead(empty, saved, await store.GetCurrentAsync(created.AccountUid));
    AssertProfileBatchRead(initial, created,
        await ReadOverloadRevisionAsync(store, created.AccountUid, created.ProfileTemplateRevisionUid));

    var restored = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, saved.ProfileTemplateRevisionUid, initial, now.AddSeconds(2)));
    Assert.NotEqual(created.ProfileTemplateRevisionUid, restored.ProfileTemplateRevisionUid);
    foreach (var build in restored.Builds)
    {
      AssertProfileBatchBuildReceipt(created.Builds.Single(original => original.CharacterUid == build.CharacterUid), build);
    }

    AssertProfileBatchRead(initial, restored, await store.GetCurrentAsync(created.AccountUid));
    AssertProfileBatchRead(empty, saved,
        await ReadOverloadRevisionAsync(store, created.AccountUid, saved.ProfileTemplateRevisionUid));
  }

  private static LocalAccountProfileWrite WithProfileBatchMembership(
      LocalAccountProfileWrite source,
      IEnumerable<LocalCharacterBuildWrite> builds,
      IEnumerable<EntityUid>? squad) => new(
          source.CharacterCatalog, source.CombatSupportCatalog, source.AccountState,
          builds, squad, source.SquadOrigin, source.ProfileTemplateOrigin);

  private static void AssertProfileBatchRead(
      LocalAccountProfileWrite expectedWrite,
      LocalAccountProfileReceipt expectedReceipt,
      LocalCurrentAccountProfile? result)
  {
    AssertOverloadRead(expectedWrite, result);
    var actual = Assert.IsType<LocalCurrentAccountProfile>(result);
    // Compare the complete hydrated write, not merely the hashes supplied by a read receipt.
    Assert.Equal(JsonSerializer.Serialize(expectedWrite), JsonSerializer.Serialize(actual.Profile));
    var receipt = actual.Revision;
    Assert.Null(receipt.OperationUid);
    Assert.False(receipt.IsIdempotentReplay);
    Assert.Equal(expectedReceipt.IssueCodes.ToArray(), receipt.IssueCodes.ToArray());
    Assert.Equal(expectedWrite.Builds.Select(build => build.CharacterUid).ToArray(),
        receipt.Builds.Select(build => build.CharacterUid).ToArray());
    Assert.Equal(expectedReceipt.Builds.Count, receipt.Builds.Count);
    Assert.Equal(receipt.Builds.Count * 4,
        receipt.Builds.SelectMany(build => build.EquipmentSlots).Select(slot => slot.EquipmentSlotUid).Distinct().Count());
    foreach (var (expected, hydrated) in expectedReceipt.Builds.Zip(receipt.Builds))
    {
      AssertProfileBatchBuildReceipt(expected, hydrated);
    }

    // Reads omit operation metadata. Collections are compared above by value;
    // record equality covers every remaining identity, lineage, hash and readiness field.
    Assert.Equal(expectedReceipt with
    {
      OperationUid = null,
      IsIdempotentReplay = false,
      Builds = receipt.Builds,
      IssueCodes = receipt.IssueCodes
    }, receipt);
  }

  private static void AssertProfileBatchReplayReceipt(
      LocalAccountProfileReceipt original, LocalAccountProfileReceipt? result)
  {
    var replay = Assert.IsType<LocalAccountProfileReceipt>(result);
    Assert.NotNull(original.OperationUid);
    Assert.False(original.IsIdempotentReplay);
    Assert.True(replay.IsIdempotentReplay);
    Assert.Equal(original.IssueCodes.ToArray(), replay.IssueCodes.ToArray());
    Assert.Equal(original.Builds.Count, replay.Builds.Count);
    Assert.Equal(replay.Builds.Count * 4,
        replay.Builds.SelectMany(build => build.EquipmentSlots).Select(slot => slot.EquipmentSlotUid).Distinct().Count());
    foreach (var (expected, actual) in original.Builds.Zip(replay.Builds))
    {
      AssertProfileBatchBuildReceipt(expected, actual);
    }

    // Only the replay flag changes: retain the original operation, revision,
    // timestamps, lineage, readiness and hashes, with value-compared collections.
    Assert.Equal(original with
    {
      IsIdempotentReplay = true,
      Builds = replay.Builds,
      IssueCodes = replay.IssueCodes
    }, replay);
  }

  private static void AssertProfileBatchBuildReceipt(
      LocalCharacterBuildReceipt expected, LocalCharacterBuildReceipt actual)
  {
    Assert.Equal(4, actual.EquipmentSlots.Count);
    Assert.Equal(Enum.GetValues<LocalEquipmentSlot>().OrderBy(slot => slot).ToArray(),
        actual.EquipmentSlots.Select(slot => slot.Slot).OrderBy(slot => slot).ToArray());
    Assert.All(actual.EquipmentSlots, slot => Assert.NotEqual(Guid.Empty, slot.EquipmentSlotUid.Value));
    Assert.Equal(expected.EquipmentSlots.ToArray(), actual.EquipmentSlots.ToArray());
    Assert.Equal(expected.IssueCodes.ToArray(), actual.IssueCodes.ToArray());
    Assert.Equal(expected with { EquipmentSlots = actual.EquipmentSlots, IssueCodes = actual.IssueCodes }, actual);
  }
}
