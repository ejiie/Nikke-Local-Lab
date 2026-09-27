using System.Reflection;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalAccountProfileTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";

  private static async Task ResetProfileTestDatabaseAsync(NpgsqlDataSource dataSource)
  {
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
  }

  [Fact]
  public async Task AccountCubeInventoryPersistsCopiesAndPreservesImmutableHistory()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 5);
    var support = await ReadSupportSelectionsAsync(dataSource, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var initial = CreateProfile(catalogs, support, 200, null, false);
    var now = DateTimeOffset.UtcNow;
    now = now.AddTicks(-(now.Ticks % 10));
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(EntityUid.New(), initial, now));
    var service = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    var account = created.AccountUid;
    var revision = created.ProfileTemplateRevisionUid;

    async Task<NikkeLocalLab.Application.ProfileManagement.ProfileWriteReceipt> Save(
        params NikkeLocalLab.Application.ProfileManagement.ProfileEditOperation[] operations)
    {
      var diff = await service.PreviewProfileEditsAsync(new(
          EntityUid.New(), account, revision, operations));
      var command = new NikkeLocalLab.Application.ProfileManagement.SaveProfileCommand(
          EntityUid.New(), account, revision, diff.CandidateDraftUid, diff.CandidateSha256, diff.DiffSha256);
      var receipt = await service.SaveProfileAsync(command);
      var replay = await service.SaveProfileAsync(command);
      Assert.True(replay.IsIdempotentReplay);
      revision = receipt.ProfileRevision.RevisionUid;
      return receipt;
    }

    // Preview must disclose the first legacy completion without changing the old head.
    var legacyPreview = await service.PreviewProfileEditsAsync(new(EntityUid.New(), account, revision, []));
    var completion = Assert.Single(legacyPreview.Changes);
    Assert.Equal("account_cube_level", completion.FieldCode);
    Assert.Equal(support.CubeUid, completion.SubjectUid);
    Assert.Null(completion.Before);
    Assert.Equal(15, completion.After!.IntegerValue);
    var beforeCompletion = (await store.GetCurrentAsync(account))!;
    Assert.Equal(created.ProfileTemplateRevisionUid, beforeCompletion.Revision.ProfileTemplateRevisionUid);
    Assert.Empty(beforeCompletion.Profile.AccountState.Cubes);

    var completed = await Save(); // Explicit legacy completion is not a no-op.
    Assert.NotEqual(created.ProfileTemplateRevisionUid, completed.ProfileRevision.RevisionUid);
    var owned = (await store.GetCurrentAsync(account))!.Profile.AccountState.Cubes;
    Assert.Equal(15, Assert.Single(owned).Level);
    Assert.Empty(initial.AccountState.Cubes);
    var noOpPreview = await service.PreviewProfileEditsAsync(new(EntityUid.New(), account, revision, []));
    Assert.Empty(noOpPreview.Changes);
    var unchanged = await Save();
    Assert.Equal(completed.ProfileRevision, unchanged.ProfileRevision);
    var subjects = catalogs.Character.CharacterUids.Take(2).ToArray();
    await Save(subjects.SelectMany(uid => new[]
    {
      new NikkeLocalLab.Application.ProfileManagement.ProfileEditOperation("cube.state", uid, "controlled", ControlledValue: "equipped"),
      new NikkeLocalLab.Application.ProfileManagement.ProfileEditOperation("cube.definition", uid, "reference", ReferenceUid: support.CubeUid),
      new NikkeLocalLab.Application.ProfileManagement.ProfileEditOperation("cube.level", uid, "integer", IntegerValue: 15)
    }).ToArray());
    await Save([new("account_cube_level", support.CubeUid, "integer", IntegerValue: 1)]);
    var after = (await store.GetCurrentAsync(account))!;
    Assert.Equal(1, Assert.Single(after.Profile.AccountState.Cubes).Level);
    Assert.All(after.Profile.Builds.Where(build => subjects.Contains(build.CharacterUid)),
        build => Assert.Equal(1, build.Cube.Level!.Value));
    Assert.Equal(initial.AccountState.Consoles, after.Profile.AccountState.Consoles);

    // Save As preserves the inventory and equipped levels, but owns an independent revision chain.
    var copyDiff = await service.PreviewProfileEditsAsync(new(EntityUid.New(), account, revision, []));
    var copy = await service.SaveAsProfileAsync(new(EntityUid.New(), account, revision,
        copyDiff.CandidateDraftUid, copyDiff.CandidateSha256, copyDiff.DiffSha256));
    Assert.Equal(1, Assert.Single((await store.GetCurrentAsync(copy.AccountUid))!.Profile.AccountState.Cubes).Level);
    await Save([new("account_cube_level", support.CubeUid, "integer", IntegerValue: 15)]);
    Assert.Equal(1, Assert.Single((await store.GetCurrentAsync(copy.AccountUid))!.Profile.AccountState.Cubes).Level);
    var newService = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    var projection = await newService.GetCurrentProfileAsync(account);
    Assert.Equal(15, Assert.Single(projection!.Values, value => value.FieldCode == "account_cube_level").IntegerValue);
    await Assert.ThrowsAnyAsync<Exception>(() => service.PreviewProfileEditsAsync(new(
        EntityUid.New(), account, revision, [new("account_cube_level", support.CubeUid, "integer", IntegerValue: 16)])));
    await Assert.ThrowsAnyAsync<Exception>(() => service.PreviewProfileEditsAsync(new(
        EntityUid.New(), account, revision, [new("account_cube_level", EntityUid.New(), "integer", IntegerValue: 15)])));
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var mutate = new NpgsqlCommand("UPDATE lab_profile.account_cube_state SET level = 1;", connection);
    var immutable = await Assert.ThrowsAsync<PostgresException>(() => mutate.ExecuteNonQueryAsync());
    Assert.Equal("immutable_profile_row", immutable.MessageText);
    await using var oldState = new NpgsqlCommand("""
        SELECT cube_count FROM lab_profile.account_state_revision WHERE account_state_revision_uid = @uid;
        """, connection);
    oldState.Parameters.AddWithValue("uid", created.AccountCombatStateRevisionUid.Value);
    Assert.Equal(0, await oldState.ExecuteScalarAsync());
  }

  [Theory]
  [InlineData(1)]
  [InlineData(15)]
  public async Task OwnedCubeLevelSurvivesNoOpSaveAndNewService(int level)
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 5);
    var support = await ReadSupportSelectionsAsync(dataSource, catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var seed = CreateProfile(catalogs, support, 200, null, false);
    var profile = new LocalAccountProfileWrite(
        seed.CharacterCatalog, seed.CombatSupportCatalog,
        new LocalAccountCombatStateWrite(seed.AccountState.SynchroLevel, seed.AccountState.Consoles,
            seed.AccountState.ValidationMode, seed.AccountState.Origin,
            [new LocalOwnedCubeWrite(support.CubeUid, level)]),
        seed.Builds, seed.SquadCharacterUids, seed.SquadOrigin, seed.ProfileTemplateOrigin);
    var instant = new DateTimeOffset(2026, 9, 6, 0, 0, 0, TimeSpan.Zero);
    var created = await store.CreateAsync(new(EntityUid.New(), profile, instant));
    var service = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    var previewCommand = new NikkeLocalLab.Application.ProfileManagement.ProfileEditPreviewCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid, []);
    var preview = await service.PreviewProfileEditsAsync(previewCommand);
    var previewReplay = await service.PreviewProfileEditsAsync(previewCommand);
    Assert.Empty(preview.Changes);
    Assert.Empty(previewReplay.Changes);
    Assert.Equal(preview.DiffSha256, previewReplay.DiffSha256);
    var saveCommand = new NikkeLocalLab.Application.ProfileManagement.SaveProfileCommand(
        EntityUid.New(), created.AccountUid, created.ProfileTemplateRevisionUid,
        preview.CandidateDraftUid, preview.CandidateSha256, preview.DiffSha256);
    var saved = await service.SaveProfileAsync(saveCommand);
    var reopened = new PostgreSqlProfileManagementService(dataSource, new RandomEntityUidGenerator());
    var replay = await reopened.SaveProfileAsync(saveCommand);
    Assert.True(replay.IsIdempotentReplay);
    Assert.Equal(created.ProfileTemplateRevisionUid, saved.ProfileRevision.RevisionUid);
    Assert.Equal(saved.ProfileRevision, replay.ProfileRevision);
    var current = (await store.GetCurrentAsync(created.AccountUid))!;
    Assert.Equal(created.ProfileContentSha256, current.Revision.ProfileContentSha256);
    Assert.Equal(level, Assert.Single(current.Profile.AccountState.Cubes).Level);
    var again = await reopened.PreviewProfileEditsAsync(new(EntityUid.New(), created.AccountUid,
        current.Revision.ProfileTemplateRevisionUid, []));
    Assert.Empty(again.Changes);
  }

  [Fact]
  public void ContractsPreserveSparseOverloadDraftAndControlledLossCodes()
  {
    var option = EntityUid.New();
    var manufacturerNotApplicable = new LocalEquipmentWrite(
        LocalEquipmentSlot.Head,
        LocalEquipmentState.Equipped,
        EntityUid.New(),
        5,
        LocalProfileFact<bool>.NotApplicable());
    Assert.Equal(
        LocalProfileFactStatus.NotApplicable,
        manufacturerNotApplicable.ManufacturerMatched?.Status);

    var sparse = new LocalEquipmentWrite(
        LocalEquipmentSlot.Head,
        LocalEquipmentState.Equipped,
        EntityUid.New(),
        5,
        LocalProfileFact<bool>.Ready(false),
        [
          new LocalOverloadLineWrite(
              1,
              option,
              LocalProfileValueUnit.Ratio,
              new LocalProfileExactValue(117, 4)),
          new LocalOverloadLineWrite(
              3,
              option,
              LocalProfileValueUnit.Ratio,
              new LocalProfileExactValue(131, 4))
        ]);
    Assert.Equal([1, 3], sparse.OverloadLines.Select(static line => line.LineIndex));

    var duplicate = Assert.Throws<LocalAccountProfileIntegrityException>(() =>
        new LocalEquipmentWrite(
            LocalEquipmentSlot.Head,
            LocalEquipmentState.Equipped,
            EntityUid.New(),
            5,
            LocalProfileFact<bool>.Ready(false),
            [
              new LocalOverloadLineWrite(
                  1,
                  option,
                  LocalProfileValueUnit.Ratio,
                  new LocalProfileExactValue(1, 4)),
              new LocalOverloadLineWrite(
                  1,
                  option,
                  LocalProfileValueUnit.Ratio,
                  new LocalProfileExactValue(2, 4))
            ]));
    Assert.Equal("profile_overload_line_set_invalid", duplicate.Code);
    Assert.Equal(
        "profile_overload_line_invalid",
        Assert.Throws<LocalAccountProfileIntegrityException>(() =>
            new LocalOverloadLineWrite(
                0,
                option,
                LocalProfileValueUnit.Ratio,
                new LocalProfileExactValue(1, 4))).Code);
    Assert.Equal(
        "profile_overload_line_invalid",
        Assert.Throws<LocalAccountProfileIntegrityException>(() =>
            new LocalOverloadLineWrite(
                4,
                option,
                LocalProfileValueUnit.Ratio,
                new LocalProfileExactValue(1, 4))).Code);

    var lossCode = new LocalProfileReasonCode("console_progress_not_retained");
    var profile = new LocalAccountProfileWrite(
        Binding(),
        Binding(),
        new LocalAccountCombatStateWrite(
            LocalProfileFact<int>.Unresolved(
                new LocalProfileReasonCode("roster_detail_level_ambiguous")),
            Enum.GetValues<LocalConsoleCoordinate>().Select(coordinate =>
                new LocalConsoleStateWrite(
                    coordinate,
                    EntityUid.New(),
                    LocalProfileFact<int>.Ready(0),
                    LocalProfileFact<long>.Unresolved(lossCode))),
            LocalProfileValidationMode.Research),
        [],
        squadCharacterUids: null);
    Assert.Empty(profile.Builds);
    Assert.Null(profile.SquadCharacterUids);
    Assert.Equal(
        "console_progress_not_retained",
        profile.AccountState.Consoles[0].ObservedExperience.ReasonCode?.Code);

    var zeroBond = Assert.Throws<LocalAccountProfileIntegrityException>(() =>
        new LocalCharacterBuildWrite(
            EntityUid.New(),
            1,
            LocalProfileFact<int>.Ready(0),
            LocalProfileFact<int>.Ready(0),
            LocalProfileFact<int>.Ready(0),
            1,
            1,
            1,
            Enum.GetValues<LocalEquipmentSlot>().Select(slot =>
                new LocalEquipmentWrite(
                    slot,
                    LocalEquipmentState.Unequipped,
                    manufacturerMatched: LocalProfileFact<bool>.NotApplicable())),
            new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped),
            new LocalCollectionSelectionWrite(LocalCollectionSelectionKind.Detached),
            LocalProfileValidationMode.Research));
    Assert.Equal("profile_build_scalar_invalid", zeroBond.Code);

    var notApplicable = new LocalCollectionSelectionWrite(
        LocalCollectionSelectionKind.NotApplicable);
    Assert.Equal(LocalCollectionSelectionKind.NotApplicable, notApplicable.Kind);

    var microsecondUtc = new DateTimeOffset(638_900_000_000_000_000, TimeSpan.Zero);
    var timestamp = Assert.Throws<LocalAccountProfileIntegrityException>(() =>
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            profile,
            microsecondUtc.AddTicks(1)));
    Assert.Equal("profile_timestamp_invalid", timestamp.Code);
  }

  [Fact]
  public void MigrationContainsOnlyControlledSourceFreeProfileStorage()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 5);
    Assert.Contains("CREATE SCHEMA lab_profile", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("line_index BETWEEN 1 AND 3", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("previous_profile_template_revision_id", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("combat_semantics_readiness_status", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("revision_origin", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("materialized_at_utc", migration.Sql, StringComparison.Ordinal);
    Assert.Contains(
        "(materialization_policy = 'combat_max_v1') =",
        migration.Sql,
        StringComparison.Ordinal);
    Assert.Contains(
        "current_build_revision_id IS DISTINCT FROM member.build_revision_id",
        migration.Sql,
        StringComparison.Ordinal);
    Assert.Equal(
        4,
        migration.Sql.Split(
            "IF current_revision_number IS NULL",
            StringSplitOptions.None).Length - 1);
    Assert.Contains("cube_definition_kind IS NOT NULL", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("collection_definition_kind IS NOT NULL", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("definition_kind IS NOT NULL", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("manufacturer_matched_status IS NOT NULL", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("enhancement_level_status", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("cube_level_status", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("collection_level_status", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("JSONB", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("official_token", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("cookie", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("open_id", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("source_alias", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("source_path", migration.Sql, StringComparison.OrdinalIgnoreCase);
  }

  [Fact]
  public async Task MigrationSealsRevisionsAndSessionHasOnlySyntheticLifecycleState()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    await using var connection = await dataSource.OpenConnectionAsync();
    var forbidden = await ReadForbiddenProfileColumnsAsync(connection);
    Assert.Empty(forbidden);
    // The same names on an unrelated table are NOT provenance metadata.
    await using (var inject = new NpgsqlCommand("""
        ALTER TABLE lab_profile.local_account ADD COLUMN source_account_uid uuid;
        ALTER TABLE lab_profile.local_account ADD COLUMN source_artifact_sha256 bytea;
        ALTER TABLE lab_profile.local_account ADD COLUMN request_payload bytea;
        ALTER TABLE lab_profile.local_account ADD COLUMN payload_sha256 bytea;
        ALTER TABLE lab_profile.account_workspace_save_request ADD COLUMN official_token text;
        """, connection))
      await inject.ExecuteNonQueryAsync();
    Assert.Equal(new[] { "official_token", "payload_sha256", "request_payload", "source_account_uid", "source_artifact_sha256" },
        await ReadForbiddenProfileColumnsAsync(connection));
    await using (var remove = new NpgsqlCommand("""
        ALTER TABLE lab_profile.local_account DROP COLUMN source_account_uid;
        ALTER TABLE lab_profile.local_account DROP COLUMN source_artifact_sha256;
        ALTER TABLE lab_profile.local_account DROP COLUMN request_payload;
        ALTER TABLE lab_profile.local_account DROP COLUMN payload_sha256;
        ALTER TABLE lab_profile.account_workspace_save_request DROP COLUMN official_token;
        """, connection))
      await remove.ExecuteNonQueryAsync();
    Assert.Equal(
        5L,
        await ScalarInt64Async(
            connection,
            """
            SELECT count(*)
            FROM information_schema.columns
            WHERE table_schema = 'lab_profile'
              AND table_name = 'local_session'
              AND column_name IN (
                  'local_session_uid', 'local_account_id',
                  'issued_at_utc', 'expires_at_utc', 'revoked_at_utc'
              );
            """));
    Assert.True(await ScalarInt64Async(
        connection,
        """
        SELECT count(*)
        FROM pg_trigger
        WHERE NOT tgisinternal
          AND tgname IN (
              'trg_account_state_revision_immutable',
              'trg_build_revision_immutable',
              'trg_squad_revision_immutable',
              'trg_template_revision_immutable'
          );
        """) >= 4L);
  }

  [Fact]
  public async Task GameLegalOverloadAcceptsEquivalentApplicationMagnitudesAndKeepsRawSemanticsSeparate()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 5);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));

    var magnitude = new LocalProfileExactValue(Math.Abs(support.SignedRawValue), 4);
    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        CreateGameLegalProfile(catalogs, support, magnitude),
        now));
    Assert.True(created.IsCombatReady);
    Assert.True(created.IsGameLegalReady);
    Assert.False(created.HasCompleteCombatSemantics);

    var equivalent = new LocalProfileExactValue(
        checked(Math.Abs(support.SignedRawValue) * 10),
        5);
    var saved = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        created.AccountUid,
        created.ProfileTemplateRevisionUid,
        CreateGameLegalProfile(catalogs, support, equivalent),
        now.AddSeconds(1)));
    Assert.True(saved.IsGameLegalReady);

    var signedRaw = new LocalProfileExactValue(support.SignedRawValue, 4);
    var invalid = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        store.CreateAsync(new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateGameLegalProfile(catalogs, support, signedRaw),
            now.AddSeconds(2))));
    Assert.Equal("profile_overload_value_not_legal", invalid.Code);
  }

  [Fact]
  public async Task SelectedCubeWithUnresolvedCatalogApplicabilityPersistsAsUnreadyDraft()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(
        dataSource,
        5,
        unresolvedCubeApplicability: true);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));
    var profile = CreateGameLegalProfile(
        catalogs,
        support,
        new LocalProfileExactValue(Math.Abs(support.SignedRawValue), 4));

    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        profile,
        now));

    Assert.False(created.IsCombatReady);
    Assert.False(created.IsGameLegalReady);
    var hydrated = Assert.IsType<LocalCurrentAccountProfile>(
        await store.GetCurrentAsync(created.AccountUid));
    Assert.All(hydrated.Profile.Builds, build =>
    {
      Assert.Equal(LocalOptionalSelectionState.Equipped, build.Cube.State);
      Assert.Equal(support.CubeUid, build.Cube.DefinitionUid);
      Assert.Equal(LocalProfileFactStatus.Ready, build.Cube.Level?.Status);
      Assert.Equal(15, build.Cube.Level?.Value);
    });
  }

  [Fact]
  public async Task SelectedDefinitionsWithUnresolvedLevelsRoundTripAsUnreadyDraft()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 5);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));
    var source = CreateGameLegalProfile(
        catalogs,
        support,
        new LocalProfileExactValue(Math.Abs(support.SignedRawValue), 4));
    var reason = new LocalProfileReasonCode("selected_level_not_retained");
    var characterUid = catalogs.Character.CharacterUids[0];
    var builds = source.Builds.Select(build => build.CharacterUid != characterUid
        ? build
        : new LocalCharacterBuildWrite(
            build.CharacterUid,
            build.CharacterLevel,
            build.LimitBreak,
            build.CoreLevel,
            build.BondLevel,
            build.Skill1Level,
            build.Skill2Level,
            build.BurstLevel,
            build.Equipment.Select(equipment => equipment.State != LocalEquipmentState.Equipped
                ? equipment
                : new LocalEquipmentWrite(
                    equipment.Slot,
                    equipment.State,
                    equipment.EquipmentDefinitionUid,
                    LocalProfileFact<int>.Unresolved(reason),
                    equipment.ManufacturerMatched,
                    equipment.OverloadLines)),
            new LocalCubeSelectionWrite(
                build.Cube.State,
                build.Cube.DefinitionUid,
                LocalProfileFact<int>.Unresolved(reason)),
            new LocalCollectionSelectionWrite(
                build.Collection.Kind,
                build.Collection.DefinitionUid,
                LocalProfileFact<int>.Unresolved(reason)),
            build.ValidationMode,
            build.MaterializationPolicy,
            build.Origin)).ToArray();
    var draft = new LocalAccountProfileWrite(
        source.CharacterCatalog,
        source.CombatSupportCatalog,
        source.AccountState,
        builds,
        source.SquadCharacterUids,
        source.SquadOrigin,
        source.ProfileTemplateOrigin);

    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        draft,
        now));

    Assert.False(created.IsCombatReady);
    Assert.False(created.IsGameLegalReady);
    var hydrated = Assert.IsType<LocalCurrentAccountProfile>(
        await store.GetCurrentAsync(created.AccountUid));
    var first = hydrated.Profile.Builds.Single(build => build.CharacterUid == characterUid);
    var head = first.Equipment.Single(equipment =>
        equipment.State == LocalEquipmentState.Equipped);
    Assert.NotNull(head.EquipmentDefinitionUid);
    Assert.Equal(LocalProfileFactStatus.Unresolved, head.EnhancementLevel?.Status);
    Assert.Equal(reason, head.EnhancementLevel?.ReasonCode);
    Assert.NotNull(first.Cube.DefinitionUid);
    Assert.Equal(LocalProfileFactStatus.Unresolved, first.Cube.Level?.Status);
    Assert.Equal(reason, first.Cube.Level?.ReasonCode);
    Assert.NotNull(first.Collection.DefinitionUid);
    Assert.Equal(LocalProfileFactStatus.Unresolved, first.Collection.Level?.Status);
    Assert.Equal(reason, first.Collection.Level?.ReasonCode);
    Assert.Equal(draft.CanonicalSha256, hydrated.Profile.CanonicalSha256);
    var firstReceipt = created.Builds.Single(build => build.CharacterUid == characterUid);
    await AssertNullSelectedDefinitionDiscriminatorsRejectedAsync(
        dataSource,
        firstReceipt.CharacterBuildRevisionUid);
  }

  [Fact]
  public async Task CombatMaxPolicyRequiresExactResolverMaterialization()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 5);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));

    var aboveMaximum = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        store.CreateAsync(new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateCombatMaxProfile(catalogs, support, characterLevel: 401),
            now)));
    Assert.Equal("profile_character_level_exceeds_cap", aboveMaximum.Code);

    var nonPolicySkill = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        store.CreateAsync(new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateCombatMaxProfile(catalogs, support, characterLevel: 399, skillLevel: 9),
            now.AddSeconds(1))));
    Assert.Equal("profile_combat_max_policy_invalid", nonPolicySkill.Code);

    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        CreateCombatMaxProfile(catalogs, support, characterLevel: 399),
        now.AddSeconds(2)));
    Assert.True(created.IsCombatReady);
    Assert.True(created.IsGameLegalReady);
    Assert.All(created.Builds, build =>
    {
      Assert.Equal(LocalProfileRevisionOrigin.CombatMaxV1, build.Lineage.Origin);
      Assert.Equal(4, build.EquipmentSlots.Count);
    });
  }

  [Fact]
  public async Task CombatMaxUnresolvedDraftRoundTripsCharacterRoleAndSkillEvidence()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(
        dataSource,
        5,
        unresolvedFirstSkill: true,
        unresolvedFirstCombatRole: true);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));
    var profile = CreateUnresolvedCombatMaxProfile(catalogs, support);

    var created = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        profile,
        now));

    Assert.False(created.IsCombatReady);
    Assert.False(created.HasCompleteCombatSemantics);
    var hydrated = Assert.IsType<LocalCurrentAccountProfile>(
        await store.GetCurrentAsync(created.AccountUid));
    var first = hydrated.Profile.Builds.Single(build =>
        build.CharacterUid == catalogs.Character.CharacterUids[0]);
    Assert.Equal(LocalProfileFactStatus.Unresolved, first.Skill1Level.Status);
    Assert.Equal(
        "fixture_skill_maximum_unresolved",
        first.Skill1Level.ReasonCode?.Code);
    Assert.All(first.Equipment, equipment =>
    {
      Assert.Equal(LocalEquipmentState.Unresolved, equipment.State);
      Assert.Equal("character_combat_role_unresolved", equipment.UnresolvedReasonCode?.Code);
    });
    Assert.All(
        hydrated.Profile.Builds.Where(build => build.CharacterUid != first.CharacterUid),
        build => Assert.All(
            build.Equipment,
            equipment => Assert.Equal(LocalEquipmentState.Equipped, equipment.State)));
    Assert.Equal(profile.CanonicalSha256, hydrated.Profile.CanonicalSha256);
  }

  [Fact]
  public async Task ProfileStoreRoundTrips192BuildsSparseOverloadLineageCasAndSessions()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishSyntheticCatalogsAsync(dataSource, 192);
    var support = await ReadSupportSelectionsAsync(
        dataSource,
        catalogs.Support.CatalogSnapshotUid);
    var store = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var nowValue = DateTimeOffset.UtcNow;
    var now = nowValue.AddTicks(-(nowValue.Ticks % 10));

    var initial = CreateProfile(
        catalogs,
        support,
        synchroLevel: 200,
        changedCharacterLevel: null,
        swapSquadLead: false);
    var create = await store.CreateAsync(new CreateLocalAccountProfileCommand(
        EntityUid.New(),
        initial,
        now));
    Assert.Equal(
        "profile_timestamp_invalid",
        (await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
            store.IssueLocalSessionAsync(
                create.AccountUid,
                now.AddTicks(1),
                now.AddMinutes(5)))).Code);
    Assert.Equal(192, create.Builds.Count);
    Assert.True(create.IsCombatReady);
    Assert.True(create.HasCompleteCombatSemantics);
    Assert.True(create.IsAccountCombatReady);
    Assert.False(create.IsFullFidelity);
    Assert.Equal(1, create.AccountStateLineage.RevisionNumber);
    Assert.Equal(1, create.ProfileTemplateLineage.RevisionNumber);
    Assert.Equal(192 * 4, create.Builds.SelectMany(static build => build.EquipmentSlots)
        .Select(static slot => slot.EquipmentSlotUid).Distinct().Count());

    var hydrated = await store.GetCurrentAsync(create.AccountUid);
    Assert.NotNull(hydrated);
    Assert.Equal(192, hydrated.Profile.Builds.Count);
    var sparse = hydrated.Profile.Builds
        .Single(build => build.CharacterUid == catalogs.Character.CharacterUids[0])
        .Equipment
        .Single(static equipment => equipment.Slot == LocalEquipmentSlot.Head)
        .OverloadLines;
    Assert.Equal([1, 3], sparse.Select(static line => line.LineIndex));
    Assert.Equal(initial.CanonicalSha256, hydrated.Profile.CanonicalSha256);

    var changed = CreateProfile(
        catalogs,
        support,
        synchroLevel: 201,
        changedCharacterLevel: 201,
        swapSquadLead: true);
    var saveCommand = new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        create.AccountUid,
        create.ProfileTemplateRevisionUid,
        changed,
        now.AddSeconds(1));
    var saved = await store.SaveAsync(saveCommand);
    Assert.Equal(2, saved.AccountStateLineage.RevisionNumber);
    Assert.Equal(create.AccountCombatStateRevisionUid,
        saved.AccountStateLineage.PreviousRevisionUid);
    Assert.Equal(2, saved.SquadLineage?.RevisionNumber);
    Assert.Equal(create.SquadRevisionUid, saved.SquadLineage?.PreviousRevisionUid);
    Assert.Equal(2, saved.ProfileTemplateLineage.RevisionNumber);
    Assert.Equal(create.ProfileTemplateRevisionUid,
        saved.ProfileTemplateLineage.PreviousRevisionUid);
    var changedBuild = saved.Builds.Single(build =>
        build.CharacterUid == catalogs.Character.CharacterUids[0]);
    Assert.Equal(2, changedBuild.Lineage.RevisionNumber);
    Assert.Equal(
        create.Builds.Single(build => build.CharacterUid == changedBuild.CharacterUid)
            .CharacterBuildRevisionUid,
        changedBuild.Lineage.PreviousRevisionUid);
    Assert.All(
        saved.Builds.Where(build => build.CharacterUid != changedBuild.CharacterUid),
        static build => Assert.Equal(1, build.Lineage.RevisionNumber));

    var replay = await store.SaveAsync(saveCommand);
    Assert.True(replay.IsIdempotentReplay);
    Assert.Equal(saved.ProfileTemplateRevisionUid, replay.ProfileTemplateRevisionUid);
    var mismatch = Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        store.SaveAsync(new SaveLocalAccountProfileCommand(
            saveCommand.OperationUid,
            create.AccountUid,
            saved.ProfileTemplateRevisionUid,
            changed,
            now.AddSeconds(2))));
    Assert.Equal("profile_operation_reuse_mismatch", (await mismatch).Code);

    var originOnlyCollision = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        store.SaveAsync(new SaveLocalAccountProfileCommand(
            saveCommand.OperationUid,
            create.AccountUid,
            create.ProfileTemplateRevisionUid,
            WithOrigins(changed, LocalProfileRevisionOrigin.OfflineSanitizedImport),
            saveCommand.CreatedAtUtc)));
    Assert.Equal("profile_operation_reuse_mismatch", originOnlyCollision.Code);

    var sameContentImportIntent = WithOrigins(
        changed,
        LocalProfileRevisionOrigin.OfflineSanitizedImport);
    Assert.NotEqual(changed.CanonicalSha256, sameContentImportIntent.CanonicalSha256);
    var reused = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        create.AccountUid,
        saved.ProfileTemplateRevisionUid,
        sameContentImportIntent,
        now.AddSeconds(3)));
    Assert.Equal(saved.ProfileTemplateRevisionUid, reused.ProfileTemplateRevisionUid);
    Assert.Equal(saved.AccountCombatStateRevisionUid, reused.AccountCombatStateRevisionUid);
    Assert.Equal(LocalProfileRevisionOrigin.UserEdit, reused.ProfileTemplateLineage.Origin);
    Assert.Equal(
        saved.ProfileTemplateLineage.MaterializedAtUtc,
        reused.ProfileTemplateLineage.MaterializedAtUtc);
    Assert.Equal(LocalProfileRevisionOrigin.UserEdit, reused.AccountStateLineage.Origin);
    Assert.All(reused.Builds,
        static build => Assert.Equal(LocalProfileRevisionOrigin.UserEdit, build.Lineage.Origin));

    var revertedProfile = WithOrigins(initial, LocalProfileRevisionOrigin.Rebase);
    var reverted = await store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        create.AccountUid,
        reused.ProfileTemplateRevisionUid,
        revertedProfile,
        now.AddSeconds(4)));
    Assert.NotEqual(create.ProfileTemplateRevisionUid, reverted.ProfileTemplateRevisionUid);
    Assert.Equal(3, reverted.ProfileTemplateLineage.RevisionNumber);
    Assert.Equal(saved.ProfileTemplateRevisionUid,
        reverted.ProfileTemplateLineage.PreviousRevisionUid);
    Assert.Equal(LocalProfileRevisionOrigin.Rebase, reverted.ProfileTemplateLineage.Origin);
    Assert.Equal(3, reverted.AccountStateLineage.RevisionNumber);
    Assert.Equal(saved.AccountCombatStateRevisionUid,
        reverted.AccountStateLineage.PreviousRevisionUid);
    Assert.Equal(LocalProfileRevisionOrigin.Rebase, reverted.AccountStateLineage.Origin);
    var revertedBuild = reverted.Builds.Single(build =>
        build.CharacterUid == catalogs.Character.CharacterUids[0]);
    Assert.Equal(3, revertedBuild.Lineage.RevisionNumber);
    Assert.Equal(changedBuild.CharacterBuildRevisionUid,
        revertedBuild.Lineage.PreviousRevisionUid);
    Assert.Equal(LocalProfileRevisionOrigin.Rebase, revertedBuild.Lineage.Origin);

    var revertedHydrated = await store.GetCurrentAsync(create.AccountUid);
    Assert.NotNull(revertedHydrated);
    Assert.Equal(LocalProfileRevisionOrigin.Rebase,
        revertedHydrated.Profile.ProfileTemplateOrigin);
    Assert.Equal(LocalProfileRevisionOrigin.Rebase,
        revertedHydrated.Profile.AccountState.Origin);

    var contenderA = store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        create.AccountUid,
        reverted.ProfileTemplateRevisionUid,
        CreateProfile(catalogs, support, 202, 202, true),
        now.AddSeconds(5)));
    var contenderB = store.SaveAsync(new SaveLocalAccountProfileCommand(
        EntityUid.New(),
        create.AccountUid,
        reverted.ProfileTemplateRevisionUid,
        CreateProfile(catalogs, support, 203, 203, true),
        now.AddSeconds(6)));
    var outcomes = await Task.WhenAll(CaptureAsync(contenderA), CaptureAsync(contenderB));
    Assert.Single(outcomes, static outcome => outcome.Receipt is not null);
    Assert.Single(outcomes, static outcome =>
        outcome.Error?.Code == "profile_revision_conflict");
    var winner = Assert.Single(outcomes, static outcome => outcome.Receipt is not null).Receipt!;

    var issued = await store.IssueLocalSessionAsync(
        create.AccountUid,
        now,
        now.AddMinutes(5));
    Assert.Equal(LocalSessionStatus.Active, issued.Status);
    var revoked = await store.RevokeLocalSessionAsync(
        issued.SessionUid,
        now.AddMinutes(1));
    Assert.Equal(LocalSessionStatus.Revoked, revoked.Status);
    Assert.Equal(
        revoked,
        await store.RevokeLocalSessionAsync(issued.SessionUid, now.AddMinutes(2)));

    await AssertCurrentBuildPointerCannotBeClearedAsync(dataSource, winner);
    await AssertPointerFirstAccountStateLineageRejectedAsync(dataSource, winner);
    await AssertRevisionChildrenAreSealedAsync(dataSource, create);
  }

  private static async Task<CatalogFixture> PublishSyntheticCatalogsAsync(
      NpgsqlDataSource dataSource,
      int characterCount,
      bool unresolvedFirstSkill = false,
      bool unresolvedFirstCombatRole = false,
      bool unresolvedCubeApplicability = false,
      string characterSnapshotTag = "profile-character")
  {
    var characterTestType = typeof(PostgreSqlCharacterCatalogTests);
    var characterSecret = (byte[])characterTestType
        .GetField("IdentitySecretA", BindingFlags.NonPublic | BindingFlags.Static)!
        .GetValue(null)!;
    var createDefinition = characterTestType.GetMethod(
        "CreateDefinition",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var definitions = new List<CharacterCatalogDefinition>(characterCount);
    SourceAliasFingerprint? favoriteCharacterAlias = null;
    for (var index = 0; index < characterCount; index++)
    {
      var alias = SourceAliasFingerprintEncoder.Encode(
          characterSecret,
          "synthetic.profile-character",
          "character",
          index.ToString(System.Globalization.CultureInfo.InvariantCulture));
      favoriteCharacterAlias ??= alias;
      var definition = (CharacterCatalogDefinition)createDefinition.Invoke(
          null,
          [alias, $"profile-{index}", CharacterCombatClassCode.Attacker, false])!;
      if ((unresolvedFirstSkill || unresolvedFirstCombatRole) && index == 0)
      {
        var capabilities = definition.Capabilities.Select(capability =>
            capability.Code == CharacterCapabilityCode.Skill1
                ? new CharacterCatalogCapability(
                    CharacterCapabilityCode.Skill1,
                    CharacterCatalogFactStatus.Unresolved,
                    unresolvedReasonCode: "fixture_skill_maximum_unresolved")
                : capability).ToArray();
        var provisional = definition with
        {
          Capabilities = capabilities,
          CombatClass = unresolvedFirstCombatRole
              ? new CharacterCatalogValueFact<CharacterCombatClassCode>(
                  CharacterCatalogFactStatus.Unresolved,
                  unresolvedReasonCode: "fixture_combat_role_unresolved")
              : definition.CombatClass
        };
        var toDomainContent = typeof(PostgreSqlCharacterCatalogImportStore).GetMethod(
            "ToDomainContent",
            BindingFlags.NonPublic | BindingFlags.Static)!;
        var domainContent = (NikkeLocalLab.Domain.Character.CharacterDefinitionContent)
            toDomainContent.Invoke(null, [provisional])!;
        definition = provisional with
        {
          DefinitionContentSha256 =
              NikkeLocalLab.Domain.Character.CharacterDefinitionCanonicalizer
                  .ComputeContentHash(domainContent)
        };
      }

      definitions.Add(definition);
    }

    var characterPublication = new CharacterCatalogPublication(
        CharacterCatalogIdentityBinding.FromSecret(characterSecret),
        definitions);
    var createCharacterAttempt = characterTestType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var characterAttempt = (CompletedImportAttempt)createCharacterAttempt.Invoke(
        null,
        [characterSnapshotTag + "-source", characterSnapshotTag + "-output", Array.Empty<SafeDiagnostic>()])!;
    var characterReceipt = await new PostgreSqlCharacterCatalogImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            characterAttempt,
            characterPublication);

    var supportTestType = typeof(PostgreSqlCombatSupportCatalogTests);
    var supportSecret = (byte[])supportTestType
        .GetField("IdentitySecret", BindingFlags.NonPublic | BindingFlags.Static)!
        .GetValue(null)!;
    var supportBinding = CombatSupportCatalogIdentityBinding.FromSecret(supportSecret);
    var createSupportPublication = supportTestType.GetMethod(
        "CreatePublication",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var supportPublication = (CombatSupportCatalogPublication)createSupportPublication.Invoke(
        null,
        [supportBinding, favoriteCharacterAlias!.Value, null, 0, 580])!;
    if (unresolvedCubeApplicability)
    {
      var supportDefinitions = supportPublication.Definitions.Select(definition =>
      {
        if (unresolvedCubeApplicability &&
            definition.Payload is CombatSupportCubeDefinitionPublication cube)
        {
          return new CombatSupportDefinitionPublication(
              definition.SourceAliasFingerprint,
              definition.DisplayName,
              new CombatSupportCubeDefinitionPublication(
                  cube.Rarity,
                  new CombatSupportValueFact<CombatSupportCombatClass>(
                      CombatSupportFactStatus.Unresolved,
                      unresolvedReasonCode: "fixture_cube_applicability_unresolved"),
                  cube.MaximumLevel,
                  cube.Levels,
                  cube.SkillSemantics),
              definition.Contributions);
        }

        return definition;
      }).ToArray();
      supportPublication = new CombatSupportCatalogPublication(
          supportBinding,
          supportDefinitions);
    }
    var createSupportAttempt = supportTestType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var supportAttempt = (CompletedImportAttempt)createSupportAttempt.Invoke(
        null,
        [
          supportPublication,
          "profile-support-source",
          "combat_support_staticdata",
          "profile-v1"
        ])!;
    var supportReceipt = await new PostgreSqlCombatSupportCatalogImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            supportAttempt,
            supportPublication);

    return new CatalogFixture(
        new CharacterFixture(
            new LocalProfileCatalogBindingWrite(
                characterReceipt.CharacterCatalogSnapshotUid,
                characterReceipt.Import.DatasetSnapshotUid!.Value,
                characterReceipt.CatalogManifestSha256),
            characterReceipt.Members.Select(static member => member.CharacterUid).ToArray()),
        new SupportFixture(
            new LocalProfileCatalogBindingWrite(
                supportReceipt.CombatSupportCatalogSnapshotUid,
                supportReceipt.Import.DatasetSnapshotUid!.Value,
                supportReceipt.CatalogManifestSha256),
            supportReceipt.CombatSupportCatalogSnapshotUid));
  }

  private static async Task<SupportSelections> ReadSupportSelectionsAsync(
      NpgsqlDataSource dataSource,
      EntityUid catalogUid)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    var consoles = new Dictionary<LocalConsoleCoordinate, EntityUid>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT detail.coordinate_code, entity.definition_uid
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.console_definition_detail AS detail
          ON detail.definition_version_id = member.definition_version_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid;
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      while (await reader.ReadAsync())
      {
        consoles.Add(ParseConsole(reader.GetString(0)), new EntityUid(reader.GetGuid(1)));
      }
    }

    var equipment = new Dictionary<LocalEquipmentSlot, EntityUid>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT detail.equipment_slot, entity.definition_uid
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.equipment_definition_detail AS detail
          ON detail.definition_version_id = member.definition_version_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND detail.combat_class_code = 'attacker'
          AND detail.tier_value = 10;
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      while (await reader.ReadAsync())
      {
        equipment.Add(ParseEquipmentSlot(reader.GetString(0)), new EntityUid(reader.GetGuid(1)));
      }
    }

    EntityUid optionUid;
    LocalProfileValueUnit optionUnit;
    await using (var command = new NpgsqlCommand(
        """
        SELECT entity.definition_uid, detail.unit_code
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.overload_option_definition_detail AS detail
          ON detail.definition_version_id = member.definition_version_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND detail.option_type_code = 'attack';
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      optionUid = new EntityUid(reader.GetGuid(0));
      optionUnit = reader.GetString(1) switch
      {
        "absolute" => LocalProfileValueUnit.Absolute,
        "ratio" => LocalProfileValueUnit.Ratio,
        "percent" => LocalProfileValueUnit.Percent,
        "count" => LocalProfileValueUnit.Count,
        _ => throw new InvalidOperationException("Synthetic OL unit is invalid.")
      };
    }

    EntityUid cubeUid;
    EntityUid collectionUid;
    await using (var command = new NpgsqlCommand(
        """
        SELECT member.definition_kind, entity.definition_uid
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND member.definition_kind IN ('cube', 'collection')
        ORDER BY member.definition_kind;
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      var selected = new Dictionary<string, EntityUid>(StringComparer.Ordinal);
      while (await reader.ReadAsync())
      {
        selected.Add(reader.GetString(0), new EntityUid(reader.GetGuid(1)));
      }

      cubeUid = selected["cube"];
      collectionUid = selected["collection"];
    }

    EntityUid signedOptionUid;
    LocalProfileValueUnit signedOptionUnit;
    long signedRawValue;
    await using (var command = new NpgsqlCommand(
        """
        SELECT entity.definition_uid, detail.unit_code, legal.source_raw_value
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.overload_option_definition_detail AS detail
          ON detail.definition_version_id = member.definition_version_id
        JOIN lab_combat_support.overload_legal_value AS legal
          ON legal.definition_version_id = member.definition_version_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND detail.option_type_code = 'charge_speed'
        ORDER BY legal.roll_level
        LIMIT 1;
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      Assert.True(await reader.ReadAsync());
      signedOptionUid = new EntityUid(reader.GetGuid(0));
      signedOptionUnit = ParseValueUnit(reader.GetString(1));
      signedRawValue = reader.GetInt64(2);
      Assert.True(signedRawValue < 0);
    }

    Assert.Equal(9, consoles.Count);
    Assert.Equal(4, equipment.Count);
    return new SupportSelections(
        consoles,
        equipment,
        optionUid,
        optionUnit,
        cubeUid,
        collectionUid,
        signedOptionUid,
        signedOptionUnit,
        signedRawValue);
  }

  private static LocalAccountProfileWrite CreateProfile(
      CatalogFixture catalogs,
      SupportSelections support,
      int synchroLevel,
      int? changedCharacterLevel,
      bool swapSquadLead)
  {
    var builds = catalogs.Character.CharacterUids.Select((uid, index) =>
        CreateBuild(
            uid,
            index == 0 ? changedCharacterLevel ?? 200 : 200,
            index == 0,
            support)).ToArray();
    var squad = catalogs.Character.CharacterUids.Take(5).ToArray();
    if (swapSquadLead)
    {
      (squad[0], squad[1]) = (squad[1], squad[0]);
    }

    var consoles = Enum.GetValues<LocalConsoleCoordinate>().Select(coordinate =>
        new LocalConsoleStateWrite(
            coordinate,
            support.Consoles[coordinate],
            LocalProfileFact<int>.Ready(0),
            LocalProfileFact<long>.Unresolved(
                new LocalProfileReasonCode("console_progress_not_retained"))));
    return new LocalAccountProfileWrite(
        catalogs.Character.Binding,
        catalogs.Support.Binding,
        new LocalAccountCombatStateWrite(
            LocalProfileFact<int>.Ready(synchroLevel),
            consoles,
            LocalProfileValidationMode.Research),
        builds,
        squad);
  }

  private static LocalCharacterBuildWrite CreateBuild(
      EntityUid characterUid,
      int characterLevel,
      bool withSparseOverload,
      SupportSelections support)
  {
    var equipment = Enum.GetValues<LocalEquipmentSlot>().Select(slot =>
    {
      if (withSparseOverload && slot == LocalEquipmentSlot.Head)
      {
        return new LocalEquipmentWrite(
            slot,
            LocalEquipmentState.Equipped,
            support.Equipment[LocalEquipmentSlot.Head],
            5,
            LocalProfileFact<bool>.Ready(true),
            [
              new LocalOverloadLineWrite(
                  1,
                  support.OptionUid,
                  support.OptionUnit,
                  new LocalProfileExactValue(123456789, 9)),
              new LocalOverloadLineWrite(
                  3,
                  support.OptionUid,
                  support.OptionUnit,
                  new LocalProfileExactValue(-987654321, 9))
            ]);
      }

      return new LocalEquipmentWrite(
          slot,
          LocalEquipmentState.Unequipped,
          manufacturerMatched: LocalProfileFact<bool>.NotApplicable());
    });
    return new LocalCharacterBuildWrite(
        characterUid,
        characterLevel,
        LocalProfileFact<int>.Ready(3),
        LocalProfileFact<int>.Ready(7),
        LocalProfileFact<int>.Ready(40),
        10,
        10,
        10,
        equipment,
        new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped),
        new LocalCollectionSelectionWrite(LocalCollectionSelectionKind.Detached),
        LocalProfileValidationMode.Research);
  }

  private static LocalAccountProfileWrite CreateGameLegalProfile(
      CatalogFixture catalogs,
      SupportSelections support,
      LocalProfileExactValue overloadValue)
  {
    var builds = catalogs.Character.CharacterUids.Select((characterUid, index) =>
    {
      var equipment = Enum.GetValues<LocalEquipmentSlot>().Select(slot =>
          index == 0 && slot == LocalEquipmentSlot.Head
              ? new LocalEquipmentWrite(
                  slot,
                  LocalEquipmentState.Equipped,
                  support.Equipment[slot],
                  5,
                  LocalProfileFact<bool>.Ready(false),
                  [
                    new LocalOverloadLineWrite(
                        1,
                        support.SignedOptionUid,
                        support.SignedOptionUnit,
                        overloadValue)
                  ])
              : new LocalEquipmentWrite(
                  slot,
                  LocalEquipmentState.Unequipped,
                  manufacturerMatched: LocalProfileFact<bool>.NotApplicable()));
      return new LocalCharacterBuildWrite(
          characterUid,
          200,
          LocalProfileFact<int>.Ready(3),
          LocalProfileFact<int>.Ready(7),
          LocalProfileFact<int>.Ready(40),
          10,
          10,
          10,
          equipment,
          new LocalCubeSelectionWrite(
              LocalOptionalSelectionState.Equipped,
              support.CubeUid,
              15),
          new LocalCollectionSelectionWrite(
              LocalCollectionSelectionKind.GenericCollection,
              support.CollectionUid,
              15),
          LocalProfileValidationMode.GameLegal);
    }).ToArray();
    var consoles = Enum.GetValues<LocalConsoleCoordinate>().Select(coordinate =>
        new LocalConsoleStateWrite(
            coordinate,
            support.Consoles[coordinate],
            LocalProfileFact<int>.Ready(0),
            LocalProfileFact<long>.Ready(0)));
    return new LocalAccountProfileWrite(
        catalogs.Character.Binding,
        catalogs.Support.Binding,
        new LocalAccountCombatStateWrite(
            LocalProfileFact<int>.Ready(200),
            consoles,
            LocalProfileValidationMode.GameLegal),
        builds,
        catalogs.Character.CharacterUids.Take(5));
  }

  private static LocalAccountProfileWrite CreateCombatMaxProfile(
      CatalogFixture catalogs,
      SupportSelections support,
      int characterLevel,
      int skillLevel = 10)
  {
    var builds = catalogs.Character.CharacterUids.Select(characterUid =>
        new LocalCharacterBuildWrite(
            characterUid,
            characterLevel,
            LocalProfileFact<int>.Ready(3),
            LocalProfileFact<int>.Ready(7),
            LocalProfileFact<int>.Ready(40),
            skillLevel,
            skillLevel,
            skillLevel,
            Enum.GetValues<LocalEquipmentSlot>().Select(slot =>
                new LocalEquipmentWrite(
                    slot,
                    LocalEquipmentState.Equipped,
                    support.Equipment[slot],
                    5,
                    LocalProfileFact<bool>.Ready(false))),
            new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped),
            new LocalCollectionSelectionWrite(
                LocalCollectionSelectionKind.GenericCollection,
                support.CollectionUid,
                15),
            LocalProfileValidationMode.GameLegal,
            LocalProfileMaterializationPolicy.CombatMaxV1,
            LocalProfileRevisionOrigin.CombatMaxV1)).ToArray();
    var consoles = Enum.GetValues<LocalConsoleCoordinate>().Select(coordinate =>
        new LocalConsoleStateWrite(
            coordinate,
            support.Consoles[coordinate],
            LocalProfileFact<int>.Ready(0),
            LocalProfileFact<long>.Ready(0)));
    return new LocalAccountProfileWrite(
        catalogs.Character.Binding,
        catalogs.Support.Binding,
        new LocalAccountCombatStateWrite(
            LocalProfileFact<int>.Ready(400),
            consoles,
            LocalProfileValidationMode.GameLegal,
            LocalProfileRevisionOrigin.CombatMaxV1),
        builds,
        catalogs.Character.CharacterUids.Take(5),
        LocalProfileRevisionOrigin.CombatMaxV1,
        LocalProfileRevisionOrigin.CombatMaxV1);
  }

  private static LocalAccountProfileWrite CreateUnresolvedCombatMaxProfile(
      CatalogFixture catalogs,
      SupportSelections support)
  {
    var resolved = CreateCombatMaxProfile(catalogs, support, characterLevel: 399);
    var unresolvedCharacterUid = catalogs.Character.CharacterUids[0];
    var builds = resolved.Builds.Select(build => new LocalCharacterBuildWrite(
        build.CharacterUid,
        build.CharacterLevel,
        build.LimitBreak,
        build.CoreLevel,
        build.BondLevel,
        build.CharacterUid == unresolvedCharacterUid
            ? LocalProfileFact<int>.Unresolved(
                new LocalProfileReasonCode("fixture_skill_maximum_unresolved"))
            : build.Skill1Level,
        build.Skill2Level,
        build.BurstLevel,
        build.Equipment.Select(equipment =>
            build.CharacterUid == unresolvedCharacterUid
                ? new LocalEquipmentWrite(
                    equipment.Slot,
                    LocalEquipmentState.Unresolved,
                    unresolvedReasonCode: new LocalProfileReasonCode(
                        "character_combat_role_unresolved"))
                : equipment),
        build.Cube,
        build.Collection,
        build.ValidationMode,
        build.MaterializationPolicy,
        build.Origin)).ToArray();
    return new LocalAccountProfileWrite(
        resolved.CharacterCatalog,
        resolved.CombatSupportCatalog,
        resolved.AccountState,
        builds,
        resolved.SquadCharacterUids,
        resolved.SquadOrigin,
        resolved.ProfileTemplateOrigin);
  }

  private static LocalAccountProfileWrite WithOrigins(
      LocalAccountProfileWrite profile,
      LocalProfileRevisionOrigin origin)
  {
    var accountState = new LocalAccountCombatStateWrite(
        profile.AccountState.SynchroLevel,
        profile.AccountState.Consoles,
        profile.AccountState.ValidationMode,
        origin);
    var builds = profile.Builds.Select(build => new LocalCharacterBuildWrite(
        build.CharacterUid,
        build.CharacterLevel,
        build.LimitBreak,
        build.CoreLevel,
        build.BondLevel,
        build.Skill1Level,
        build.Skill2Level,
        build.BurstLevel,
        build.Equipment,
        build.Cube,
        build.Collection,
        build.ValidationMode,
        build.MaterializationPolicy,
        origin));
    return new LocalAccountProfileWrite(
        profile.CharacterCatalog,
        profile.CombatSupportCatalog,
        accountState,
        builds,
        profile.SquadCharacterUids,
        origin,
        origin);
  }

  private static async Task<(LocalAccountProfileReceipt? Receipt,
      LocalAccountProfileIntegrityException? Error)> CaptureAsync(
          Task<LocalAccountProfileReceipt> task)
  {
    try
    {
      return (await task, null);
    }
    catch (LocalAccountProfileIntegrityException exception)
    {
      return (null, exception);
    }
  }

  private static async Task AssertRevisionChildrenAreSealedAsync(
      NpgsqlDataSource dataSource,
      LocalAccountProfileReceipt receipt)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    await using (var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.account_state_revision
        SET synchro_level = synchro_level
        WHERE account_state_revision_uid = @uid;
        """,
        connection))
    {
      update.Parameters.AddWithValue("uid", receipt.AccountCombatStateRevisionUid.Value);
      var exception = await Assert.ThrowsAsync<PostgresException>(() =>
          update.ExecuteNonQueryAsync());
      Assert.Equal("immutable_profile_row", exception.MessageText);
    }

    await using var append = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_console_state (
            account_state_revision_id,
            support_catalog_snapshot_id,
            coordinate_code,
            definition_entity_id,
            definition_version_id,
            definition_kind,
            level_status,
            level,
            observed_experience_status
        )
        SELECT
            account_state_revision_id,
            support_catalog_snapshot_id,
            coordinate_code,
            definition_entity_id,
            definition_version_id,
            definition_kind,
            level_status,
            level,
            'not_applicable'
        FROM lab_profile.account_console_state
        WHERE account_state_revision_id = (
            SELECT account_state_revision_id
            FROM lab_profile.account_state_revision
            WHERE account_state_revision_uid = @uid
        )
        LIMIT 1;
        """,
        connection);
    append.Parameters.AddWithValue("uid", receipt.AccountCombatStateRevisionUid.Value);
    var appendException = await Assert.ThrowsAsync<PostgresException>(() =>
        append.ExecuteNonQueryAsync());
    Assert.Equal("immutable_profile_row", appendException.MessageText);
  }

  private static async Task AssertCurrentBuildPointerCannotBeClearedAsync(
      NpgsqlDataSource dataSource,
      LocalAccountProfileReceipt receipt)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    await using var update = new NpgsqlCommand(
        """
        UPDATE lab_profile.character_build AS build
        SET current_build_revision_id = NULL
        WHERE build.character_build_id = (
            SELECT member.character_build_id
            FROM lab_profile.local_account AS account
            JOIN lab_profile.profile_template_revision_build AS member
              ON member.profile_template_revision_id =
                 account.current_profile_template_revision_id
            WHERE account.local_account_uid = @account_uid
            ORDER BY member.ordinal
            LIMIT 1
        );
        """,
        connection,
        transaction);
    update.Parameters.AddWithValue("account_uid", receipt.AccountUid.Value);
    var exception = await Assert.ThrowsAsync<PostgresException>(() =>
        update.ExecuteNonQueryAsync());
    Assert.Equal("immutable_profile_row", exception.MessageText);
  }

  private static async Task AssertPointerFirstAccountStateLineageRejectedAsync(
      NpgsqlDataSource dataSource,
      LocalAccountProfileReceipt source)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    long futureRevisionId;
    await using (var reserve = new NpgsqlCommand(
        """
        SELECT nextval(pg_get_serial_sequence(
            'lab_profile.account_state_revision',
            'account_state_revision_id'));
        """,
        connection,
        transaction))
    {
      futureRevisionId = Convert.ToInt64(
          await reserve.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    long accountId;
    await using (var insertAccount = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.local_account (
            local_account_uid,
            account_combat_state_uid,
            canonical_sha256,
            current_account_state_revision_id,
            created_at_utc
        ) VALUES (@account_uid, @state_uid, @hash, @future_revision_id, @created_at)
        RETURNING local_account_id;
        """,
        connection,
        transaction))
    {
      insertAccount.Parameters.AddWithValue("account_uid", EntityUid.New().Value);
      insertAccount.Parameters.AddWithValue("state_uid", EntityUid.New().Value);
      insertAccount.Parameters.AddWithValue("hash", new byte[32]);
      insertAccount.Parameters.AddWithValue("future_revision_id", futureRevisionId);
      insertAccount.Parameters.AddWithValue("created_at", source.AccountCreatedAtUtc);
      accountId = Convert.ToInt64(
          await insertAccount.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    await using var insertRevision = new NpgsqlCommand(
        """
        INSERT INTO lab_profile.account_state_revision (
            account_state_revision_id,
            account_state_revision_uid,
            local_account_id,
            revision_number,
            previous_account_state_revision_id,
            character_catalog_snapshot_id,
            character_dataset_snapshot_id,
            character_catalog_manifest_sha256,
            support_catalog_snapshot_id,
            support_dataset_snapshot_id,
            support_catalog_manifest_sha256,
            synchro_level_status,
            synchro_level,
            synchro_level_unresolved_reason_code,
            validation_mode,
            combat_readiness_status,
            combat_readiness_issue_code,
            full_fidelity_status,
            full_fidelity_issue_code,
            game_legal_readiness_status,
            game_legal_issue_code,
            console_count,
            content_sha256,
            revision_origin,
            materialized_at_utc
        ) OVERRIDING SYSTEM VALUE
        SELECT
            @future_revision_id,
            @revision_uid,
            @account_id,
            2,
            @future_revision_id,
            source.character_catalog_snapshot_id,
            source.character_dataset_snapshot_id,
            source.character_catalog_manifest_sha256,
            source.support_catalog_snapshot_id,
            source.support_dataset_snapshot_id,
            source.support_catalog_manifest_sha256,
            source.synchro_level_status,
            source.synchro_level,
            source.synchro_level_unresolved_reason_code,
            source.validation_mode,
            source.combat_readiness_status,
            source.combat_readiness_issue_code,
            source.full_fidelity_status,
            source.full_fidelity_issue_code,
            source.game_legal_readiness_status,
            source.game_legal_issue_code,
            source.console_count,
            source.content_sha256,
            source.revision_origin,
            source.materialized_at_utc
        FROM lab_profile.account_state_revision AS source
        WHERE source.account_state_revision_uid = @source_revision_uid;
        """,
        connection,
        transaction);
    insertRevision.Parameters.AddWithValue("future_revision_id", futureRevisionId);
    insertRevision.Parameters.AddWithValue("revision_uid", EntityUid.New().Value);
    insertRevision.Parameters.AddWithValue("account_id", accountId);
    insertRevision.Parameters.AddWithValue(
        "source_revision_uid",
        source.AccountCombatStateRevisionUid.Value);
    var exception = await Assert.ThrowsAsync<PostgresException>(() =>
        insertRevision.ExecuteNonQueryAsync());
    Assert.Equal("profile_revision_lineage_invalid", exception.MessageText);
  }

  private static async Task AssertNullSelectedDefinitionDiscriminatorsRejectedAsync(
      NpgsqlDataSource dataSource,
      EntityUid sourceBuildRevisionUid)
  {
    foreach (var discriminator in new[]
             {
               "cube_definition_kind",
               "collection_definition_kind"
             })
    {
      await using var connection = await dataSource.OpenConnectionAsync();
      await using var transaction = await connection.BeginTransactionAsync();
      var sql = $"""
          CREATE TEMP TABLE pending_profile_build_revision (
              LIKE lab_profile.character_build_revision
          ) ON COMMIT DROP;
          INSERT INTO pending_profile_build_revision
          SELECT *
          FROM lab_profile.character_build_revision
          WHERE build_revision_uid = @source_revision_uid;
          UPDATE pending_profile_build_revision
          SET previous_build_revision_id = build_revision_id,
              build_revision_id = nextval(pg_get_serial_sequence(
                  'lab_profile.character_build_revision',
                  'build_revision_id')),
              build_revision_uid = @new_revision_uid,
              revision_number = revision_number + 1,
              {discriminator} = NULL;
          INSERT INTO lab_profile.character_build_revision
          OVERRIDING SYSTEM VALUE
          SELECT * FROM pending_profile_build_revision;
          """;
      await using var insert = new NpgsqlCommand(sql, connection, transaction);
      insert.Parameters.AddWithValue("source_revision_uid", sourceBuildRevisionUid.Value);
      insert.Parameters.AddWithValue("new_revision_uid", EntityUid.New().Value);
      var exception = await Assert.ThrowsAsync<PostgresException>(() =>
          insert.ExecuteNonQueryAsync());
      Assert.Equal(PostgresErrorCodes.CheckViolation, exception.SqlState);
    }

    await AssertNullEquipmentDefinitionDiscriminatorRejectedAsync(
        dataSource,
        sourceBuildRevisionUid);
  }

  private static async Task AssertNullEquipmentDefinitionDiscriminatorRejectedAsync(
      NpgsqlDataSource dataSource,
      EntityUid sourceBuildRevisionUid)
  {
    await AssertNullEquipmentShapeFieldRejectedAsync(
        dataSource,
        sourceBuildRevisionUid,
        "equipped",
        clearDefinitionKind: true);
    await AssertNullEquipmentShapeFieldRejectedAsync(
        dataSource,
        sourceBuildRevisionUid,
        "unequipped",
        clearDefinitionKind: false);
  }

  private static async Task AssertNullEquipmentShapeFieldRejectedAsync(
      NpgsqlDataSource dataSource,
      EntityUid sourceBuildRevisionUid,
      string equipmentState,
      bool clearDefinitionKind)
  {
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    long newRevisionId;
    await using (var clone = new NpgsqlCommand(
        """
        CREATE TEMP TABLE pending_profile_build_revision (
            LIKE lab_profile.character_build_revision
        ) ON COMMIT DROP;
        INSERT INTO pending_profile_build_revision
        SELECT *
        FROM lab_profile.character_build_revision
        WHERE build_revision_uid = @source_revision_uid;
        UPDATE pending_profile_build_revision
        SET previous_build_revision_id = build_revision_id,
            build_revision_id = nextval(pg_get_serial_sequence(
                'lab_profile.character_build_revision',
                'build_revision_id')),
            build_revision_uid = @new_revision_uid,
            revision_number = revision_number + 1;
        INSERT INTO lab_profile.character_build_revision
        OVERRIDING SYSTEM VALUE
        SELECT * FROM pending_profile_build_revision
        RETURNING build_revision_id;
        """,
        connection,
        transaction))
    {
      clone.Parameters.AddWithValue("source_revision_uid", sourceBuildRevisionUid.Value);
      clone.Parameters.AddWithValue("new_revision_uid", EntityUid.New().Value);
      newRevisionId = Convert.ToInt64(
          await clone.ExecuteScalarAsync(),
          System.Globalization.CultureInfo.InvariantCulture);
    }

    var definitionKind = clearDefinitionKind ? "NULL" : "source.definition_kind";
    var manufacturerStatus = clearDefinitionKind
        ? "source.manufacturer_matched_status"
        : "NULL";
    var sql = $"""
        INSERT INTO lab_profile.build_equipment_state (
            build_revision_id,
            character_build_id,
            equipment_slot_id,
            slot_code,
            support_catalog_snapshot_id,
            equipment_state,
            definition_entity_id,
            definition_version_id,
            definition_kind,
            enhancement_level_status,
            enhancement_level,
            enhancement_level_unresolved_reason_code,
            manufacturer_matched_status,
            manufacturer_matched,
            manufacturer_matched_unresolved_reason_code,
            equipment_unresolved_reason_code,
            overload_line_count
        )
        SELECT
            @new_revision_id,
            source.character_build_id,
            source.equipment_slot_id,
            source.slot_code,
            source.support_catalog_snapshot_id,
            source.equipment_state,
            source.definition_entity_id,
            source.definition_version_id,
            {definitionKind},
            source.enhancement_level_status,
            source.enhancement_level,
            source.enhancement_level_unresolved_reason_code,
            {manufacturerStatus},
            source.manufacturer_matched,
            source.manufacturer_matched_unresolved_reason_code,
            source.equipment_unresolved_reason_code,
            source.overload_line_count
        FROM lab_profile.build_equipment_state AS source
        JOIN lab_profile.character_build_revision AS revision
          ON revision.build_revision_id = source.build_revision_id
        WHERE revision.build_revision_uid = @source_revision_uid
          AND source.equipment_state = @equipment_state
        LIMIT 1;
        """;
    await using var insertEquipment = new NpgsqlCommand(
        sql,
        connection,
        transaction);
    insertEquipment.Parameters.AddWithValue("new_revision_id", newRevisionId);
    insertEquipment.Parameters.AddWithValue(
        "source_revision_uid",
        sourceBuildRevisionUid.Value);
    insertEquipment.Parameters.AddWithValue("equipment_state", equipmentState);
    var exception = await Assert.ThrowsAsync<PostgresException>(() =>
        insertEquipment.ExecuteNonQueryAsync());
    Assert.Equal(PostgresErrorCodes.CheckViolation, exception.SqlState);
  }

  private static LocalConsoleCoordinate ParseConsole(string value) => value switch
  {
    "common" => LocalConsoleCoordinate.Common,
    "attacker" => LocalConsoleCoordinate.Attacker,
    "defender" => LocalConsoleCoordinate.Defender,
    "supporter" => LocalConsoleCoordinate.Supporter,
    "elysion" => LocalConsoleCoordinate.Elysion,
    "missilis" => LocalConsoleCoordinate.Missilis,
    "tetra" => LocalConsoleCoordinate.Tetra,
    "pilgrim" => LocalConsoleCoordinate.Pilgrim,
    "abnormal" => LocalConsoleCoordinate.Abnormal,
    _ => throw new InvalidOperationException("Synthetic console coordinate is invalid.")
  };

  private static LocalEquipmentSlot ParseEquipmentSlot(string value) => value switch
  {
    "head" => LocalEquipmentSlot.Head,
    "torso" => LocalEquipmentSlot.Torso,
    "arms" => LocalEquipmentSlot.Arms,
    "legs" => LocalEquipmentSlot.Legs,
    _ => throw new InvalidOperationException("Synthetic equipment slot is invalid.")
  };

  private static LocalProfileValueUnit ParseValueUnit(string value) => value switch
  {
    "absolute" => LocalProfileValueUnit.Absolute,
    "ratio" => LocalProfileValueUnit.Ratio,
    "percent" => LocalProfileValueUnit.Percent,
    "count" => LocalProfileValueUnit.Count,
    _ => throw new InvalidOperationException("Synthetic value unit is invalid.")
  };

  private static LocalProfileCatalogBindingWrite Binding() => new(
      EntityUid.New(),
      EntityUid.New(),
      Sha256Digest.ComputeUtf8(Guid.NewGuid().ToString("D")));

  private static NpgsqlDataSource CreateDataSource()
  {
    var connectionString = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB")
        ?? throw new InvalidOperationException(
            "NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(connectionString);
    var builder = new NpgsqlConnectionStringBuilder(validated);
    PostgreSqlTestDatabaseGuard.RequireDisposableDatabase(builder);
    return PostgreSqlDataSourceFactory.Create(validated);
  }

  private static async Task ResetOverloadReadDatabaseAsync(NpgsqlDataSource dataSource)
  {
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
  }

  private static async Task ResetSchemasAsync(NpgsqlDataSource dataSource)
  {
    if (!string.Equals(
            Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_RESET_TOKEN"),
            ResetToken,
            StringComparison.Ordinal))
    {
      throw new InvalidOperationException("The disposable PostgreSQL reset token is required.");
    }

    await using var command = dataSource.CreateCommand(
        """
        DROP SCHEMA IF EXISTS lab_private_server CASCADE;
        DROP SCHEMA IF EXISTS lab_local_game CASCADE;
        DROP SCHEMA IF EXISTS lab_profile CASCADE;
        DROP SCHEMA IF EXISTS lab_combat_support CASCADE;
        DROP SCHEMA IF EXISTS lab_raid CASCADE;
        DROP SCHEMA IF EXISTS lab_private CASCADE;
        DROP SCHEMA IF EXISTS lab_catalog CASCADE;
        DROP SCHEMA IF EXISTS lab_import CASCADE;
        DROP SCHEMA IF EXISTS lab_meta CASCADE;
        """);
    await command.ExecuteNonQueryAsync();
  }

  private static async Task<IReadOnlyList<string>> ReadForbiddenProfileColumnsAsync(
      NpgsqlConnection connection)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'lab_profile'
          AND (
              data_type IN ('json', 'jsonb')
              OR column_name ~ '(source|raw|path|alias|token|cookie|open.?id|payload|free.?text)'
          )
          -- V0009/V0011/V0014 metadata uses local UUIDs or digest/length,
          -- not original account IDs, paths, credentials or source payloads.
          -- V0018's immutable bounded canonical command is checked by the codec,
          -- FK/checksum guards and recovery tests, not an opaque source dump.
          AND (table_name, column_name, data_type) NOT IN (
              -- V0026 paths are CHECK-constrained local account-art URLs with opaque local IDs/hashes.
              ('account_directory_presentation', 'portrait_path', 'text'),
              ('account_directory_presentation', 'frame_path', 'text'),
              ('fetched_account_snapshot', 'source_artifact_byte_length', 'integer'),
              ('fetched_account_snapshot', 'source_artifact_sha256', 'bytea'),
              ('account_workspace_save_operation', 'source_account_uid', 'uuid'),
              ('account_workspace_save_request', 'source_account_uid', 'uuid'),
              ('account_workspace_save_request', 'request_payload', 'bytea'),
              ('account_workspace_save_request', 'payload_sha256', 'bytea'),
              ('account_observation_provenance_binding', 'save_as_source_account_uid', 'uuid'),
              ('account_observation_provenance_binding', 'source_snapshot_uid', 'uuid')
          )
        ORDER BY column_name;
        """,
        connection);
    var result = new List<string>();
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      result.Add(reader.GetString(0));
    }

    return result;
  }

  private static async Task<long> ScalarInt64Async(
      NpgsqlConnection connection,
      string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(await command.ExecuteScalarAsync(),
        System.Globalization.CultureInfo.InvariantCulture);
  }

  private sealed record CatalogFixture(
      CharacterFixture Character,
      SupportFixture Support);

  private sealed record CharacterFixture(
      LocalProfileCatalogBindingWrite Binding,
      IReadOnlyList<EntityUid> CharacterUids);

  private sealed record SupportFixture(
      LocalProfileCatalogBindingWrite Binding,
      EntityUid CatalogSnapshotUid);

  private sealed record SupportSelections(
      IReadOnlyDictionary<LocalConsoleCoordinate, EntityUid> Consoles,
      IReadOnlyDictionary<LocalEquipmentSlot, EntityUid> Equipment,
      EntityUid OptionUid,
      LocalProfileValueUnit OptionUnit,
      EntityUid CubeUid,
      EntityUid CollectionUid,
      EntityUid SignedOptionUid,
      LocalProfileValueUnit SignedOptionUnit,
      long SignedRawValue);
}
