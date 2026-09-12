using System.Data;
using System.Reflection;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalAccountProfileTests
{
  [Fact]
  public async Task OverloadReadsPreserveExactEquipmentAcrossAccountsRevisionsAndConcurrentSave()
  {
    await using var source = CreateDataSource();
    await ResetOverloadReadDatabaseAsync(source);
    var catalogs = await PublishSyntheticCatalogsAsync(source, 5);
    var support = await ReadSupportSelectionsAsync(source, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var now = new DateTimeOffset(2026, 9, 11, 0, 0, 0, TimeSpan.Zero);
    var initial = CreateOverloadReadProfile(catalogs, support, 1);
    var otherWrite = CreateOverloadReadProfile(catalogs, support, 2);
    var changed = CreateOverloadReadProfile(catalogs, support, 3);
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var other = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), otherWrite, now));
    AssertOverloadRead(initial, await store.GetCurrentAsync(created.AccountUid));
    AssertOverloadRead(otherWrite, await store.GetCurrentAsync(other.AccountUid));
    Assert.NotEqual(initial.CanonicalSha256, changed.CanonicalSha256);
    Assert.NotEqual(initial.CanonicalSha256, otherWrite.CanonicalSha256);

    await using var connection = await source.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead);
    // Pin the snapshot before the writer commits, without locking its account row.
    await using (var pin = new NpgsqlCommand(
        "SELECT local_account_uid FROM lab_profile.local_account WHERE local_account_uid = @uid;",
        connection, transaction))
    {
      pin.Parameters.AddWithValue("uid", created.AccountUid.Value);
      Assert.Equal(created.AccountUid.Value, Assert.IsType<Guid>(await pin.ExecuteScalarAsync()));
    }

    var saved = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, changed, now.AddSeconds(1)));
    Assert.NotEqual(created.ProfileTemplateRevisionUid, saved.ProfileTemplateRevisionUid);
    var snapshotRead = typeof(PostgreSqlLocalAccountProfileStore).GetMethod(
        "GetCurrentAsync", BindingFlags.NonPublic | BindingFlags.Static, null,
        [typeof(NpgsqlConnection), typeof(NpgsqlTransaction), typeof(EntityUid), typeof(CancellationToken)], null)!;
    var snapshot = await (Task<LocalCurrentAccountProfile?>)snapshotRead.Invoke(
        null, [connection, transaction, created.AccountUid, CancellationToken.None])!;
    AssertOverloadRead(initial, snapshot);
    Assert.Equal(created.ProfileTemplateRevisionUid, snapshot!.Revision.ProfileTemplateRevisionUid);
    await transaction.CommitAsync();

    AssertOverloadRead(changed, await store.GetCurrentAsync(created.AccountUid));
    AssertOverloadRead(initial, await ReadOverloadRevisionAsync(store, created.AccountUid, created.ProfileTemplateRevisionUid));
    AssertOverloadRead(changed, await ReadOverloadRevisionAsync(store, created.AccountUid, saved.ProfileTemplateRevisionUid));
    AssertOverloadRead(otherWrite, await store.GetCurrentAsync(other.AccountUid));
    Assert.Null(await ReadOverloadRevisionAsync(store, created.AccountUid, EntityUid.New()));
    Assert.Null(await ReadOverloadRevisionAsync(store, created.AccountUid, other.ProfileTemplateRevisionUid));
    Assert.Null(await ReadOverloadRevisionAsync(store, other.AccountUid, saved.ProfileTemplateRevisionUid));

    await using var freshSource = CreateDataSource();
    var freshStore = new PostgreSqlLocalAccountProfileStore(freshSource, new RandomEntityUidGenerator());
    AssertOverloadRead(changed, await freshStore.GetCurrentAsync(created.AccountUid));
    AssertOverloadRead(otherWrite, await freshStore.GetCurrentAsync(other.AccountUid));
    AssertOverloadRead(initial, await ReadOverloadRevisionAsync(
        freshStore, created.AccountUid, created.ProfileTemplateRevisionUid));
    AssertOverloadRead(changed, await freshStore.GetCurrentAsync(created.AccountUid));
  }

  [Fact]
  public async Task MissingOverloadOptionRejectsWriteWithoutChangingCurrentProfile()
  {
    await using var source = CreateDataSource();
    await ResetOverloadReadDatabaseAsync(source);
    var catalogs = await PublishSyntheticCatalogsAsync(source, 5);
    var support = await ReadSupportSelectionsAsync(source, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var now = new DateTimeOffset(2026, 9, 11, 0, 0, 0, TimeSpan.Zero);
    var initial = CreateOverloadReadProfile(catalogs, support, 1);
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var invalid = CreateOverloadReadProfile(catalogs, support, 2, EntityUid.New());
    var operationUid = EntityUid.New();
    var error = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() => store.SaveAsync(
        new SaveLocalAccountProfileCommand(operationUid, created.AccountUid,
            created.ProfileTemplateRevisionUid, invalid, now.AddSeconds(1))));
    Assert.Equal("profile_definition_not_in_catalog", error.Code);
    Assert.Null(await store.GetByOperationAsync(operationUid));
    var current = await store.GetCurrentAsync(created.AccountUid);
    AssertOverloadRead(initial, current);
    Assert.Equal(created.ProfileTemplateRevisionUid, current!.Revision.ProfileTemplateRevisionUid);
  }

  private static LocalAccountProfileWrite CreateOverloadReadProfile(
      CatalogFixture catalogs, SupportSelections support, int variant, EntityUid? missingOption = null)
  {
    var seed = CreateProfile(catalogs, support, 200, null, false);
    var builds = seed.Builds.Select((build, characterIndex) =>
    {
      var equipment = Enum.GetValues<LocalEquipmentSlot>().Select(slot =>
      {
        // Rotate 0/1/3/sparse lines and absent states across slots and characters.
        // The final character has no overload rows at all.
        var shape = characterIndex == 4 ? 4 : (characterIndex * 4 + (int)slot) % 6;
        if (shape == 4)
        {
          return new LocalEquipmentWrite(slot, LocalEquipmentState.Unequipped,
              manufacturerMatched: LocalProfileFact<bool>.NotApplicable());
        }

        if (shape == 5)
        {
          return new LocalEquipmentWrite(slot, LocalEquipmentState.Unresolved,
              unresolvedReasonCode: new LocalProfileReasonCode("fixture_equipment_unresolved"));
        }

        int[] indexes = shape switch { 0 => [], 1 => [1], 2 => [3, 1, 2], _ => [3, 1] };
        var lines = indexes.Select(index =>
        {
          var discriminator = variant * 1000L + characterIndex * 100 + (int)slot * 10 + index;
          var signedOption = index == 2;
          return new LocalOverloadLineWrite(index,
              missingOption ?? (signedOption ? support.SignedOptionUid : support.OptionUid),
              signedOption ? support.SignedOptionUnit : support.OptionUnit,
              new LocalProfileExactValue(
                  index == 1 ? long.MaxValue - discriminator : long.MinValue + discriminator,
                  index == 1 ? 0 : 9));
        });
        return new LocalEquipmentWrite(slot, LocalEquipmentState.Equipped, support.Equipment[slot],
            shape == 0
                ? LocalProfileFact<int>.Unresolved(new LocalProfileReasonCode("fixture_enhancement_unresolved"))
                : LocalProfileFact<int>.Ready((characterIndex + (int)slot) % 6),
            LocalProfileFact<bool>.NotApplicable(), lines);
      });
      return new LocalCharacterBuildWrite(build.CharacterUid, build.CharacterLevel,
          build.LimitBreak, build.CoreLevel, build.BondLevel, build.Skill1Level, build.Skill2Level,
          build.BurstLevel, equipment, build.Cube, build.Collection, build.ValidationMode,
          build.MaterializationPolicy, build.Origin);
    });
    return new LocalAccountProfileWrite(seed.CharacterCatalog, seed.CombatSupportCatalog,
        seed.AccountState, builds, seed.SquadCharacterUids, seed.SquadOrigin, seed.ProfileTemplateOrigin);
  }

  private static Task<LocalCurrentAccountProfile?> ReadOverloadRevisionAsync(
      PostgreSqlLocalAccountProfileStore store, EntityUid accountUid, EntityUid revisionUid)
  {
    var method = typeof(PostgreSqlLocalAccountProfileStore).GetMethod(
        "GetRevisionAsync", BindingFlags.NonPublic | BindingFlags.Instance)!;
    return (Task<LocalCurrentAccountProfile?>)method.Invoke(
        store, [accountUid, revisionUid, CancellationToken.None])!;
  }

  private static void AssertOverloadRead(LocalAccountProfileWrite expected, LocalCurrentAccountProfile? result)
  {
    var actual = Assert.IsType<LocalCurrentAccountProfile>(result).Profile;
    Assert.Equal(expected.CanonicalSha256, actual.CanonicalSha256);
    Assert.Equal(expected.Builds.Count, actual.Builds.Count);
    foreach (var (expectedBuild, actualBuild) in expected.Builds.Zip(actual.Builds))
    {
      Assert.Equal(expectedBuild.CharacterUid, actualBuild.CharacterUid);
      Assert.Equal(expectedBuild.Equipment.Count, actualBuild.Equipment.Count);
      foreach (var (equipment, hydrated) in expectedBuild.Equipment.Zip(actualBuild.Equipment))
      {
        Assert.Equal(equipment.Slot, hydrated.Slot);
        Assert.Equal(equipment.State, hydrated.State);
        Assert.Equal(equipment.EquipmentDefinitionUid, hydrated.EquipmentDefinitionUid);
        Assert.Equal(equipment.EnhancementLevel, hydrated.EnhancementLevel);
        Assert.Equal(equipment.ManufacturerMatched, hydrated.ManufacturerMatched);
        Assert.Equal(equipment.UnresolvedReasonCode, hydrated.UnresolvedReasonCode);
        Assert.Equal(equipment.OverloadLines.Count, hydrated.OverloadLines.Count);
        foreach (var (line, hydratedLine) in equipment.OverloadLines.Zip(hydrated.OverloadLines))
        {
          Assert.Equal(line.LineIndex, hydratedLine.LineIndex);
          Assert.Equal(line.OptionDefinitionUid, hydratedLine.OptionDefinitionUid);
          Assert.Equal(line.Unit, hydratedLine.Unit);
          Assert.Equal(line.ExactValue.UnscaledValue, hydratedLine.ExactValue.UnscaledValue);
          Assert.Equal(line.ExactValue.DecimalScale, hydratedLine.ExactValue.DecimalScale);
        }
      }
    }
  }
}
