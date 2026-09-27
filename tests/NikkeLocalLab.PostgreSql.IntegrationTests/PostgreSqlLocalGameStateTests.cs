using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using App = NikkeLocalLab.Application.ProfileManagement;
using DomainGameState = NikkeLocalLab.Domain.LocalGameState;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed partial class PostgreSqlLocalGameStateTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private const string NoLevelAuthority = "unresolved/no_apply";
  private const string RosterLevelAuthority = "roster_observation/v1";
  private const string DetailLevelAuthority = "detail_observation/v1";
  private static readonly byte[] IdentitySecret = Enumerable.Range(1, 32)
      .Select(static value => checked((byte)value))
      .ToArray();
  private static readonly Sha256Digest TransformerBinarySha256 =
      Sha256Digest.ComputeUtf8("synthetic-profile-transformer-binary-v1");
  private static readonly DateTimeOffset TestInstant =
      new(2026, 8, 20, 1, 0, 0, TimeSpan.Zero);

  [Fact]
  public void PersistenceContentUsesDomainCanonicalAuthority()
  {
    var characterUid = EntityUid.New();
    var iconUid = EntityUid.New();
    var persistenceLobby = new LocalLobbyPresentationWrite(
        " E\u0301ve ",
        LocalGameIntFact.Ready(833),
        LocalGameUidFact.Ready(characterUid),
        LocalGameUidFact.Ready(iconUid),
        LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
        LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
        LocalGameRevisionOrigin.OfflineSanitizedImport);
    var domainLobby = new DomainGameState.LobbyPresentationContent(
        " E\u0301ve ",
        DomainGameState.LocalGameFact<int>.Ready(833),
        DomainGameState.LocalGameFact<EntityUid>.Ready(characterUid),
        DomainGameState.LocalGameFact<EntityUid>.Ready(iconUid),
        DomainGameState.LocalGameFact<EntityUid>.Unresolved(
            "presentation_binding_unresolved"),
        DomainGameState.LocalGameFact<EntityUid>.Unresolved(
            "presentation_binding_unresolved"),
        DomainGameState.LocalGameRevisionOrigin.OfflineSanitizedImport);

    Assert.Equal("Éve", persistenceLobby.DisplayName);
    Assert.Equal(domainLobby.DisplayName, persistenceLobby.DisplayName);
    Assert.Equal(domainLobby.ContentSha256, persistenceLobby.ContentSha256);
    Assert.Equal(
        domainLobby.ContentSha256,
        LocalGameStateContractCanonicalizer.ComputeLobbySha256(persistenceLobby));

    var persistenceWallet = new LocalWalletWrite(
    [
      new LocalWalletBalance(LocalWalletCurrency.Credit, 10_037_000),
      new LocalWalletBalance(LocalWalletCurrency.Jewel, 1_771)
    ]);
    var domainWallet = new DomainGameState.WalletContent(
    [
      new DomainGameState.WalletBalance(DomainGameState.WalletCurrency.Credit, 10_037_000),
      new DomainGameState.WalletBalance(DomainGameState.WalletCurrency.Jewel, 1_771)
    ],
        DomainGameState.LocalGameRevisionOrigin.UserEdit);
    Assert.Equal(domainWallet.ContentSha256, persistenceWallet.ContentSha256);

    var longControlledRoute = "solo_raid." + new string('a', 70);
    var persistenceManifest = new LocalClientFeatureManifestWrite(
        "nll/client-feature-manifest/v1",
        [
          new LocalClientFeatureEntry(
              longControlledRoute,
              LocalClientFeatureCapability.Supported),
          new LocalClientFeatureEntry(
              "recruit",
              LocalClientFeatureCapability.VisibleNoOp)
        ]);
    var domainManifest = new DomainGameState.ClientFeatureManifestContent(
        "nll/client-feature-manifest/v1",
        [
          new DomainGameState.ClientFeatureEntry(
              longControlledRoute,
              DomainGameState.ClientFeatureCapability.Supported),
          new DomainGameState.ClientFeatureEntry(
              "recruit",
              DomainGameState.ClientFeatureCapability.VisibleNoOp)
        ]);
    Assert.Equal(domainManifest.ContentSha256, persistenceManifest.ContentSha256);

    Assert.Equal(
        "local_game_display_name_unicode_invalid",
        Assert.Throws<LocalGameStateIntegrityException>(() =>
            new LocalLobbyPresentationWrite(
                "bad\u200Bname",
                LocalGameIntFact.Ready(1),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"))).Code);
    Assert.Equal(
        "local_game_display_name_semantics_invalid",
        Assert.Throws<LocalGameStateIntegrityException>(() =>
            new LocalLobbyPresentationWrite(
                "https://example.invalid",
                LocalGameIntFact.Ready(1),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"),
                LocalGameUidFact.Unresolved("presentation_binding_unresolved"))).Code);
  }

  [Fact]
  public void SanitizedDraftRejectsRawSourceMetadataAndSeparatesPolicyHashes()
  {
    var catalog = Binding();
    var exception = Assert.Throws<LocalGameStateIntegrityException>(() =>
        new SanitizedProfileDraftWrite(
            SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
            previousDraftUid: null,
            Sha256Digest.ComputeUtf8("sanitizer-contract"),
            Sha256Digest.ComputeUtf8("transformer"),
            Sha256Digest.ComputeUtf8("semantic-options"),
            catalog,
            catalog,
            "{\"profile\":{\"sourcePath\":\"C:/private/account.json\"}}"));
    Assert.Equal("sanitized_profile_forbidden_field", exception.Code);

    var strictCodec = Assert.Throws<LocalGameStateIntegrityException>(() =>
        new SanitizedProfileDraftWrite(
            SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
            previousDraftUid: null,
            Sha256Digest.ComputeUtf8("sanitizer-contract"),
            Sha256Digest.ComputeUtf8("transformer"),
            Sha256Digest.ComputeUtf8("semantic-options"),
            catalog,
            catalog,
            "{\"observations\":[],\"resolvedLevel\":{\"status\":\"unresolved\",\"reasonCode\":\"level_authority_not_selected\"}}"));
    Assert.Equal("sanitized_draft_root_shape_invalid", strictCodec.Code);
    Assert.Equal(SanitizedProfileDraftWrite.SchemaCode, "nll/sanitized-profile-draft/v1");
    Assert.NotEqual(
        Sha256Digest.ComputeUtf8("sanitizer-contract"),
        Sha256Digest.ComputeUtf8("transformer"));
    Assert.NotEqual(
        Sha256Digest.ComputeUtf8("transformer"),
        Sha256Digest.ComputeUtf8("semantic-options"));
  }

  [Fact]
  public void MigrationDefinesAdditiveImmutableLineageAndSourceFreeStorage()
  {
    var migration = PostgreSqlMigrationRunner
        .LoadEmbeddedMigrations(typeof(PostgreSqlMigrationRunner).Assembly)
        .Single(item => item.Version == 6);

    Assert.Equal("local_game_state", migration.Name);
    Assert.Contains("CREATE SCHEMA lab_local_game", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("valid_lobby_display_name", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("char_length(value) BETWEEN 1 AND 32", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("value = normalize(value, NFC)", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("nll/sanitized-profile-draft/v1", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("^nll/client-feature-manifest/v", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("sanitizer_contract_sha256", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("transformer_sha256", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("semantic_options_sha256", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("guard_lobby_revision_lineage", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("guard_wallet_revision_lineage", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("local_game_revision_not_published", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("DEFERRABLE INITIALLY DEFERRED", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("IS DISTINCT FROM", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("FOR UPDATE", migration.Sql, StringComparison.Ordinal);
    Assert.Contains("reject_immutable_mutation", migration.Sql, StringComparison.Ordinal);
    Assert.DoesNotContain("source_path", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("raw_hash", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("mtime", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("envelope", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("token", migration.Sql, StringComparison.OrdinalIgnoreCase);
    Assert.DoesNotContain("CREATE TABLE lab_local_game.inventory", migration.Sql, StringComparison.Ordinal);
  }

  [Fact]
  public async Task FeatureManifestPublicationIsIdempotentAndSealed()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var store = new PostgreSqlLocalGameStateStore(dataSource, new RandomEntityUidGenerator());
    var manifest = new LocalClientFeatureManifestWrite(
        "nll/client-feature-manifest/v1",
        [
          new LocalClientFeatureEntry("solo_raid", LocalClientFeatureCapability.Supported),
          new LocalClientFeatureEntry("recruit", LocalClientFeatureCapability.VisibleNoOp)
        ]);
    var command = new PublishLocalClientFeatureManifestCommand(
        EntityUid.New(),
        manifest,
        new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero));

    var first = await store.PublishFeatureManifestAsync(command);
    var replay = await store.PublishFeatureManifestAsync(command);
    Assert.False(first.IsReused);
    Assert.True(replay.IsReused);
    Assert.Equal(first.ManifestUid, replay.ManifestUid);
    Assert.Equal(manifest.ContentSha256, first.ContentSha256);

    await using var connection = await dataSource.OpenConnectionAsync();
    await using var lateChild = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.client_feature_manifest_entry (
            client_feature_manifest_id, route_code, capability_code
        )
        SELECT client_feature_manifest_id, 'late_route', 'supported'
        FROM lab_local_game.client_feature_manifest
        WHERE client_feature_manifest_uid = @manifest_uid;
        """,
        connection);
    lateChild.Parameters.AddWithValue("manifest_uid", first.ManifestUid.Value);
    var sealedGraph = await Assert.ThrowsAsync<PostgresException>(() =>
        lateChild.ExecuteNonQueryAsync());
    Assert.Equal("immutable_local_game_row", sealedGraph.MessageText);
  }

  [Fact]
  public async Task StrictDraftCreatesCleanAccountAndBootstrapsTypedLocalState()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var imported = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant);
    var importStore = new PostgreSqlProfileImportStore(
        dataSource,
        new RandomEntityUidGenerator());
    var replay = await importStore.ImportDraftAsync(imported.Command);
    Assert.True(replay.IsIdempotentReplay);
    Assert.Equal(imported.Receipt.DraftUid, replay.DraftUid);

    var service = Service(dataSource);
    var projectedDraft = await service.GetImportDraftAsync(imported.Receipt.DraftUid);
    Assert.NotNull(projectedDraft);
    Assert.Equal("offline_sanitized_import", projectedDraft!.DerivationKind);
    Assert.Null(projectedDraft.PreviousDraftUid);
    Assert.Equal(2, projectedDraft.Observations.Count(
        static item => item.ObservationKind == RosterLevelAuthority));
    Assert.Equal(2, projectedDraft.Observations.Count(
        static item => item.ObservationKind == DetailLevelAuthority));

    await using (var connection = await dataSource.OpenConnectionAsync())
    await using (var command = new NpgsqlCommand(
        "SELECT canonical_payload_json FROM lab_local_game.sanitized_profile_draft WHERE sanitized_profile_draft_uid = @uid;",
        connection))
    {
      command.Parameters.AddWithValue("uid", imported.Receipt.DraftUid.Value);
      var stored = Assert.IsType<string>(await command.ExecuteScalarAsync());
      Assert.DoesNotContain("raw-account-sentinel", stored, StringComparison.Ordinal);
      Assert.DoesNotContain("secret-token-value", stored, StringComparison.Ordinal);
      Assert.DoesNotContain("official.invalid", stored, StringComparison.Ordinal);
    }

    var firstPreviewOperation = EntityUid.New();
    var firstPreview = await service.PreviewCreateFromImportAsync(
        new App.CreateImportDiffCommand(
            firstPreviewOperation,
            imported.Receipt.DraftUid,
            imported.Receipt.CanonicalPayloadSha256,
            DetailLevelAuthority,
            ["full_profile"]));
    Assert.NotEmpty(firstPreview.Changes);
    Assert.Empty(firstPreview.Issues);
    var firstDiff = Assert.IsType<ProfileDraftDiffDocument>(
        await importStore.GetDiffAsync(firstPreviewOperation));

    var createOperation = EntityUid.New();
    var createCommand = new App.CreateFromImportCommand(
        createOperation,
        imported.Receipt.DraftUid,
        imported.Receipt.CanonicalPayloadSha256,
        firstPreview.DiffSha256,
        DetailLevelAuthority,
        ["full_profile"]);
    var created = await WithPostgresDiagnosticsAsync(
        () => service.CreateFromImportAsync(createCommand));
    var secondPreview = await service.PreviewCreateFromImportAsync(
        new App.CreateImportDiffCommand(
            EntityUid.New(),
            imported.Receipt.DraftUid,
            imported.Receipt.CanonicalPayloadSha256,
            DetailLevelAuthority,
            ["full_profile"]));
    Assert.Equal(firstPreview.DiffSha256, secondPreview.DiffSha256);
    var createReplay = await service.CreateFromImportAsync(createCommand);
    Assert.False(created.IsIdempotentReplay);
    Assert.True(createReplay.IsIdempotentReplay);
    Assert.Equal(created.AccountUid, createReplay.AccountUid);
    Assert.Equal(created.ProfileRevision, createReplay.ProfileRevision);
    var completedCreate = Assert.IsType<ProfileDraftApplicationReceipt>(
        await importStore.TryRecoverApplicationAsync(
            createOperation,
            ProfileDraftApplicationKind.Create,
            firstDiff.DiffUid,
            createOperation));
    Assert.Equal(firstDiff.DiffUid, completedCreate.DiffUid);

    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var bootstrap = await service.InitializeLocalStateAsync(
        new App.InitializeLocalStateCommand(
            EntityUid.New(),
            created.AccountUid,
            created.ProfileRevision.RevisionUid,
            manifest.ManifestUid,
            manifest.ContentSha256,
            "Local Lab",
            833,
            null,
            null,
            catalogs.CharacterUids[0],
            null,
            [
              new App.WalletBalanceProjection("credit", 10_037_000),
              new App.WalletBalanceProjection("jewel", 1_771)
            ]));
    var readBack = await service.GetCurrentBootstrapAsync(created.AccountUid);
    Assert.NotNull(readBack);
    Assert.Equal(bootstrap.RevisionSetSha256, readBack!.RevisionSetSha256);
    Assert.Equal(2, readBack.Roster.Count);
    Assert.Null(readBack.Squad);
    Assert.Equal("equipped_combat_items_v1", readBack.Inventory.ProjectionKind);
    Assert.False(readBack.Inventory.IsCompleteInventory);
    Assert.True(readBack.Inventory.IsReadOnly);
    Assert.Equal(
        200,
        Value(readBack.Profile, "character_level", catalogs.CharacterUids[0]).IntegerValue);

    var head = readBack.Inventory.Items.Single(item =>
        item.ItemKind == "equipment" &&
        item.CharacterUid == catalogs.CharacterUids[0] &&
        item.SlotCode == "head");
    Assert.Equal("equipped", head.State);
    Assert.Equal("not_applicable", Value(head, "manufacturer_matched").Status);
    Assert.Equal("present", Value(head, "overload.1.state").ControlledValue);
    Assert.Equal(catalogs.OptionRawValue1, Value(head, "overload.1.value").UnscaledValue);
    Assert.Equal(4, Value(head, "overload.1.value").DecimalScale);
    Assert.Equal("absent", Value(head, "overload.2.state").ControlledValue);
    Assert.Equal("present", Value(head, "overload.3.state").ControlledValue);
    Assert.Equal(catalogs.OptionRawValue3, Value(head, "overload.3.value").UnscaledValue);
    Assert.Equal(4, Value(head, "overload.3.value").DecimalScale);

    var profileStore = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var current = Assert.IsType<LocalCurrentAccountProfile>(
        await profileStore.GetCurrentAsync(created.AccountUid));
    var legacyBuilds = current.Profile.Builds.Select(build =>
    {
      if (build.CharacterUid != catalogs.CharacterUids[0])
      {
        return build;
      }

      var equipment = build.Equipment.Select(item =>
          item.Slot == LocalEquipmentSlot.Head
              ? new LocalEquipmentWrite(
                  item.Slot,
                  item.State,
                  item.EquipmentDefinitionUid,
                  item.EnhancementLevel,
                  LocalProfileFact<bool>.Unresolved(
                      new LocalProfileReasonCode("manufacturer_observation_missing")),
                  item.OverloadLines,
                  item.UnresolvedReasonCode)
              : item);
      return new LocalCharacterBuildWrite(
          build.CharacterUid,
          build.CharacterLevel,
          build.LimitBreak,
          build.CoreLevel,
          build.BondLevel,
          build.Skill1Level,
          build.Skill2Level,
          build.BurstLevel,
          equipment,
          build.Cube,
          build.Collection,
          LocalProfileValidationMode.Research,
          build.MaterializationPolicy,
          build.Origin);
    });
    var legacy = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            new LocalAccountProfileWrite(
                current.Profile.CharacterCatalog,
                current.Profile.CombatSupportCatalog,
                current.Profile.AccountState,
                legacyBuilds,
                squadCharacterUids: null,
                current.Profile.SquadOrigin,
                current.Profile.ProfileTemplateOrigin),
            TestInstant.AddMinutes(1)));
    var applicabilityPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            legacy.AccountUid,
            legacy.ProfileTemplateRevisionUid,
            [
              new App.ProfileEditOperation(
                  "equipment.head.manufacturer_matched",
                  catalogs.CharacterUids[0],
                  "controlled",
                  ControlledValue: "not_applicable")
            ]));
    var applicabilityChange = Assert.Single(applicabilityPreview.Changes);
    Assert.Equal("unresolved", applicabilityChange.Before!.Status);
    Assert.Equal("not_applicable", applicabilityChange.After!.Status);
    var applicabilitySaved = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            legacy.AccountUid,
            legacy.ProfileTemplateRevisionUid,
            applicabilityPreview.CandidateDraftUid,
            applicabilityPreview.CandidateSha256,
            applicabilityPreview.DiffSha256));
    var applicabilityCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(legacy.AccountUid));
    Assert.Equal(applicabilitySaved.ProfileRevision, applicabilityCurrent.ProfileRevision);
    Assert.Equal(
        "not_applicable",
        Value(
            applicabilityCurrent,
            "equipment.head.manufacturer_matched",
            catalogs.CharacterUids[0]).Status);
    var legacyPercentPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            legacy.AccountUid,
            applicabilityCurrent.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "equipment.head.overload.1.unit",
                  catalogs.CharacterUids[0],
                  "controlled",
                  ControlledValue: "percent"),
              new App.ProfileEditOperation(
                  "equipment.head.overload.1.value",
                  catalogs.CharacterUids[0],
                  "exact_decimal",
                  UnscaledValue: catalogs.OptionRawValue3,
                  DecimalScale: 4)
            ]));
    Assert.DoesNotContain(
        legacyPercentPreview.Changes,
        static change => change.FieldCode.EndsWith(".unit", StringComparison.Ordinal));
    var legacyPercentSaved = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            legacy.AccountUid,
            applicabilityCurrent.ProfileRevision.RevisionUid,
            legacyPercentPreview.CandidateDraftUid,
            legacyPercentPreview.CandidateSha256,
            legacyPercentPreview.DiffSha256));
    var legacyPercentCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(legacy.AccountUid));
    Assert.Equal(legacyPercentSaved.ProfileRevision, legacyPercentCurrent.ProfileRevision);
    Assert.Equal(
        "ratio",
        Value(
            legacyPercentCurrent,
            "equipment.head.overload.1.unit",
            catalogs.CharacterUids[0]).ControlledValue);
    Assert.Equal(
        catalogs.OptionRawValue3,
        Value(
            legacyPercentCurrent,
            "equipment.head.overload.1.value",
            catalogs.CharacterUids[0]).UnscaledValue);
    var runtimeCandidate = Assert.IsType<App.RuntimeProjectionCandidate>(
        await service.ExportRuntimeProjectionCandidateAsync(legacy.AccountUid));
    Assert.Equal("ready", runtimeCandidate.ValidationStatusCode);
    Assert.Empty(runtimeCandidate.ValidationReasonCodes);
    Assert.DoesNotContain(
        runtimeCandidate.Values,
        static value => value.Status == "unresolved");
    var runtimeWorkspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(legacy.AccountUid));
    Assert.Equal("ready", runtimeWorkspace.ValidationStatusCode);
    Assert.Empty(runtimeWorkspace.ValidationReasonCodes);
    var runtimeSummary = Assert.Single(
        await service.ListAccountsAsync(),
        item => item.AccountUid == legacy.AccountUid);
    Assert.Equal("ready", runtimeSummary.ValidationStatusCode);
    Assert.Empty(runtimeSummary.ValidationReasonCodes);
    Assert.Null((await service.GetCurrentBootstrapAsync(legacy.AccountUid))?.Squad);
  }

  [Fact]
  public async Task ImportAuthorityScopesEditorSaveAsAndCasRemainExplicit()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var detailDraft = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant);
    var rosterDraft = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.RosterObservationV1,
        TestInstant.AddMinutes(1));
    var service = Service(dataSource);

    var detailAccount = await CreateAccountFromImportAsync(
        service,
        detailDraft,
        DetailLevelAuthority);
    var rosterAccount = await CreateAccountFromImportAsync(
        service,
        rosterDraft,
        RosterLevelAuthority);
    var detailCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(detailAccount.AccountUid));
    var rosterCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(rosterAccount.AccountUid));
    var detailSummary = Assert.Single(
        await service.ListAccountsAsync(),
        item => item.AccountUid == detailCurrent.AccountUid);
    var renamedDetail = await service.RenameAccountAsync(
        new App.RenameAccountCommand(
            detailCurrent.AccountUid,
            detailSummary.AccountLabel,
            "계정_1"));
    Assert.Equal("계정_1", renamedDetail.AccountLabel);
    Assert.Equal(200, Value(detailCurrent, "character_level", catalogs.CharacterUids[0]).IntegerValue);
    Assert.Equal(100, Value(rosterCurrent, "character_level", catalogs.CharacterUids[0]).IntegerValue);

    var accountOnlyPreview = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            EntityUid.New(),
            rosterDraft.Receipt.DraftUid,
            rosterDraft.Receipt.CanonicalPayloadSha256,
            detailCurrent.AccountUid,
            detailCurrent.ProfileRevision.RevisionUid,
            NoLevelAuthority,
            ["account_state_only"]));
    Assert.DoesNotContain(
        accountOnlyPreview.Issues,
        static item => item.Code == "level_authority_not_selected");
    var accountOnly = await service.ApplyImportAsync(
        new App.ApplyImportCommand(
            EntityUid.New(),
            rosterDraft.Receipt.DraftUid,
            rosterDraft.Receipt.CanonicalPayloadSha256,
            detailCurrent.AccountUid,
            detailCurrent.ProfileRevision.RevisionUid,
            accountOnlyPreview.DiffSha256,
            NoLevelAuthority,
            ["account_state_only"]));
    var afterAccountOnly = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(detailCurrent.AccountUid));
    Assert.Equal(accountOnly.ProfileRevision, afterAccountOnly.ProfileRevision);
    Assert.Equal(200, Value(afterAccountOnly, "character_level", catalogs.CharacterUids[0]).IntegerValue);

    var emptyPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            afterAccountOnly.AccountUid,
            afterAccountOnly.ProfileRevision.RevisionUid,
            []));
    Assert.Empty(emptyPreview.Changes);
    var emptySaveOperation = EntityUid.New();
    var emptySaveCommand = new App.SaveProfileCommand(
        emptySaveOperation,
        afterAccountOnly.AccountUid,
        afterAccountOnly.ProfileRevision.RevisionUid,
        emptyPreview.CandidateDraftUid,
        emptyPreview.CandidateSha256,
        emptyPreview.DiffSha256);
    var emptySaved = await service.SaveProfileAsync(emptySaveCommand);
    var emptySavedReplay = await service.SaveProfileAsync(emptySaveCommand);
    Assert.Equal(afterAccountOnly.ProfileRevision, emptySaved.ProfileRevision);
    Assert.True(emptySavedReplay.IsIdempotentReplay);
    Assert.Equal(emptySaved.ProfileRevision, emptySavedReplay.ProfileRevision);
    var saveAsOperation = EntityUid.New();
    var saveAsCommand = new App.SaveAsProfileCommand(
        saveAsOperation,
        afterAccountOnly.AccountUid,
        afterAccountOnly.ProfileRevision.RevisionUid,
        emptyPreview.CandidateDraftUid,
        emptyPreview.CandidateSha256,
        emptyPreview.DiffSha256,
        "계정_2");
    var savedAs = await service.SaveAsProfileAsync(saveAsCommand);
    var savedAsReplay = await service.SaveAsProfileAsync(saveAsCommand);
    Assert.NotEqual(afterAccountOnly.AccountUid, savedAs.AccountUid);
    Assert.True(savedAsReplay.IsIdempotentReplay);
    Assert.Equal(savedAs.AccountUid, savedAsReplay.AccountUid);
    var accountList = await service.ListAccountsAsync();
    var copiedSummary = Assert.Single(accountList, item => item.AccountUid == savedAs.AccountUid);
    Assert.Equal("계정_2", copiedSummary.AccountLabel);
    Assert.Equal(afterAccountOnly.AccountUid, copiedSummary.SaveAsParentAccountUid);

    var editPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            afterAccountOnly.AccountUid,
            afterAccountOnly.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 199)
            ]));
    var saveOperation = EntityUid.New();
    var saveCommand = new App.SaveProfileCommand(
        saveOperation,
        afterAccountOnly.AccountUid,
        afterAccountOnly.ProfileRevision.RevisionUid,
        editPreview.CandidateDraftUid,
        editPreview.CandidateSha256,
        editPreview.DiffSha256);
    var saved = await service.SaveProfileAsync(saveCommand);
    var savedReplay = await service.SaveProfileAsync(saveCommand);
    Assert.True(savedReplay.IsIdempotentReplay);
    Assert.Equal(saved.ProfileRevision, savedReplay.ProfileRevision);
    var copiedCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(savedAs.AccountUid));
    var copiedEditPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            copiedCurrent.AccountUid,
            copiedCurrent.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 198)
            ]));
    var copiedSaved = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            copiedCurrent.AccountUid,
            copiedCurrent.ProfileRevision.RevisionUid,
            copiedEditPreview.CandidateDraftUid,
            copiedEditPreview.CandidateSha256,
            copiedEditPreview.DiffSha256));
    var sourceAfterIndependentCopyEdit = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(afterAccountOnly.AccountUid));
    var copyAfterIndependentEdit = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(savedAs.AccountUid));
    Assert.Equal(saved.ProfileRevision, sourceAfterIndependentCopyEdit.ProfileRevision);
    Assert.Equal(copiedSaved.ProfileRevision, copyAfterIndependentEdit.ProfileRevision);
    Assert.Equal(
        199,
        Value(sourceAfterIndependentCopyEdit, "character_level", catalogs.CharacterUids[0]).IntegerValue);
    Assert.Equal(
        198,
        Value(copyAfterIndependentEdit, "character_level", catalogs.CharacterUids[0]).IntegerValue);
    var sourceHistory = Assert.IsType<App.AccountRevisionHistoryProjection>(
        await service.GetAccountRevisionHistoryAsync(afterAccountOnly.AccountUid));
    var copiedHistory = Assert.IsType<App.AccountRevisionHistoryProjection>(
        await service.GetAccountRevisionHistoryAsync(savedAs.AccountUid));
    Assert.Equal(2, sourceHistory.Revisions.Count);
    Assert.Equal(2, copiedHistory.Revisions.Count);
    Assert.NotEqual(
        sourceHistory.Revisions[0].ProfileRevision.RevisionUid,
        copiedHistory.Revisions[0].ProfileRevision.RevisionUid);
    var sourceRuntimeCandidate = Assert.IsType<App.RuntimeProjectionCandidate>(
        await service.ExportRuntimeProjectionCandidateAsync(afterAccountOnly.AccountUid));
    var copiedRuntimeCandidate = Assert.IsType<App.RuntimeProjectionCandidate>(
        await service.ExportRuntimeProjectionCandidateAsync(savedAs.AccountUid));
    Assert.Equal("계정_1", sourceRuntimeCandidate.AccountLabel);
    Assert.Equal("계정_2", copiedRuntimeCandidate.AccountLabel);
    Assert.NotEqual(sourceRuntimeCandidate.CandidateSha256, copiedRuntimeCandidate.CandidateSha256);
    var stale = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
        service.PreviewProfileEditsAsync(
            new App.ProfileEditPreviewCommand(
                EntityUid.New(),
                afterAccountOnly.AccountUid,
                afterAccountOnly.ProfileRevision.RevisionUid,
                [])));
    Assert.Equal("profile_revision_conflict", stale.Code);
  }

  [Fact]
  public async Task CompleteFetchedSnapshotBecomesCurrentAndReusesExistingSelectiveImportDiff()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var imported = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant);
    var service = Service(dataSource);
    var created = await CreateAccountFromImportAsync(service, imported, DetailLevelAuthority);
    var current = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(created.AccountUid));
    var edit = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            created.AccountUid,
            current.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 199)
            ]));
    var edited = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            created.AccountUid,
            current.ProfileRevision.RevisionUid,
            edit.CandidateDraftUid,
            edit.CandidateSha256,
            edit.DiffSha256));

    var snapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            EntityUid.New(),
            TestInstant.AddMinutes(5),
            imported.Draft,
            new CredentialBearingProfileCoverage(2, 2, 1, 8, 2, 2, 1, 9),
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(
                Sha256Digest.ComputeUtf8("synthetic-main-quest"),
                611,
                611,
                17),
            Array.Empty<ProfileImportDiagnostic>()));
    var snapshotJson = Encoding.UTF8.GetString(FetchedAccountSnapshotJsonCodec.Encode(snapshot));
    var draftJson = Encoding.UTF8.GetString(SanitizedProfileDraftJsonCodec.Encode(imported.Draft));
    var registerCommand = new App.RegisterFetchedAccountSnapshotCommand(
        created.AccountUid,
        edited.ProfileRevision.RevisionUid,
        snapshotJson,
        draftJson);

    var registered = await service.RegisterFetchedAccountSnapshotAsync(registerCommand);
    var replay = await service.RegisterFetchedAccountSnapshotAsync(registerCommand);
    Assert.True(registered.IsCurrentWorkspaceSnapshot);
    Assert.Equal(registered, replay);
    Assert.Equal("SyntheticLab", registered.DisplayName);
    Assert.Equal(893, registered.CommanderLevel);

    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initialized = await service.InitializeLocalStateAsync(
        new App.InitializeLocalStateCommand(
            EntityUid.New(),
            created.AccountUid,
            edited.ProfileRevision.RevisionUid,
            manifest.ManifestUid,
            manifest.ContentSha256,
            "Local Lobby Name",
            700,
            null,
            null,
            null,
            null,
            [
              new App.WalletBalanceProjection("credit", 0),
              new App.WalletBalanceProjection("jewel", 0)
            ]));
    var sourceWorkspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(created.AccountUid));
    var copyPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            created.AccountUid,
            edited.ProfileRevision.RevisionUid,
            []));
    var copyCommand = new App.SaveAccountWorkspaceCommand(
        EntityUid.New(),
        true,
        created.AccountUid,
        sourceWorkspace.BaseRevisions.RevisionSetSha256,
        edited.ProfileRevision.RevisionUid,
        initialized.Lobby.Revision.RevisionUid,
        initialized.Wallet.Revision.RevisionUid,
        copyPreview.CandidateDraftUid,
        copyPreview.CandidateSha256,
        copyPreview.DiffSha256,
        sourceWorkspace.AccountLabel,
        "관측 출처 복사본",
        initialized.Lobby.DisplayName,
        initialized.Lobby.CommanderLevel,
        initialized.Lobby.ProfileIconSelectionUid,
        initialized.Lobby.ProfileFrameSelectionUid,
        initialized.Lobby.LobbyCharacterSelectionUid,
        initialized.Lobby.LobbyBackgroundSelectionUid,
        initialized.Wallet.Balances);
    var copied = await service.SaveAccountWorkspaceAsync(copyCommand);
    var copiedReplay = await service.SaveAccountWorkspaceAsync(copyCommand);
    Assert.Equal(snapshot.SnapshotUid, copied.ObservationSourceSnapshotUid);
    Assert.Equal(copied with { IsIdempotentReplay = true }, copiedReplay);
    var copiedWorkspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(copied.AccountUid));
    Assert.Null(copiedWorkspace.FetchedSnapshotUid);
    var copiedObservation = Assert.IsType<App.FetchedAccountSnapshotProjection>(
        await service.GetLatestFetchedAccountSnapshotAsync(copied.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, copiedObservation.SnapshotUid);
    Assert.Equal(created.AccountUid, copiedObservation.TargetAccountUid);
    var copiedBootstrap = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(copied.AccountUid));
    var chainedPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            copied.AccountUid,
            copied.ProfileRevision.RevisionUid,
            []));
    var chained = await service.SaveAccountWorkspaceAsync(
        new App.SaveAccountWorkspaceCommand(
            EntityUid.New(),
            true,
            copied.AccountUid,
            copiedWorkspace.BaseRevisions.RevisionSetSha256,
            copied.ProfileRevision.RevisionUid,
            copied.LobbyRevision.RevisionUid,
            copied.WalletRevision.RevisionUid,
            chainedPreview.CandidateDraftUid,
            chainedPreview.CandidateSha256,
            chainedPreview.DiffSha256,
            copiedWorkspace.AccountLabel,
            "관측 출처 연속 복사본",
            copiedBootstrap.Lobby.DisplayName,
            copiedBootstrap.Lobby.CommanderLevel,
            copiedBootstrap.Lobby.ProfileIconSelectionUid,
            copiedBootstrap.Lobby.ProfileFrameSelectionUid,
            copiedBootstrap.Lobby.LobbyCharacterSelectionUid,
            copiedBootstrap.Lobby.LobbyBackgroundSelectionUid,
            copiedBootstrap.Wallet.Balances));
    Assert.Equal(snapshot.SnapshotUid, chained.ObservationSourceSnapshotUid);
    var chainedObservation = Assert.IsType<App.FetchedAccountSnapshotProjection>(
        await service.GetLatestFetchedAccountSnapshotAsync(chained.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, chainedObservation.SnapshotUid);
    Assert.Equal(created.AccountUid, chainedObservation.TargetAccountUid);
    var lobbyDiff = await service.PreviewFetchedLobbyDiffAsync(
        new App.PreviewFetchedLobbyDiffCommand(
            EntityUid.New(),
            snapshot.SnapshotUid,
            created.AccountUid,
            initialized.Lobby.Revision.RevisionUid,
            ["commander_level"]));
    var commanderChange = Assert.Single(lobbyDiff.Changes);
    Assert.Equal("commander_level", commanderChange.FieldCode);
    Assert.Equal(700, commanderChange.BeforeInteger);
    Assert.Equal(893, commanderChange.AfterInteger);
    var appliedLobby = await service.ApplyFetchedLobbyAsync(
        new App.ApplyFetchedLobbyCommand(
            EntityUid.New(),
            snapshot.SnapshotUid,
            created.AccountUid,
            initialized.Lobby.Revision.RevisionUid,
            lobbyDiff.DiffSha256,
            ["commander_level"]));
    Assert.Equal(893, appliedLobby.Lobby.CommanderLevel);
    Assert.Equal("Local Lobby Name", appliedLobby.Lobby.DisplayName);
    Assert.Null(appliedLobby.Lobby.ProfileIconSelectionUid);
    Assert.Null(appliedLobby.Lobby.ProfileFrameSelectionUid);
    Assert.Null(appliedLobby.Lobby.LobbyCharacterSelectionUid);
    Assert.Null(appliedLobby.Lobby.LobbyBackgroundSelectionUid);
    var zeroLobbyDiff = await service.PreviewFetchedLobbyDiffAsync(
        new App.PreviewFetchedLobbyDiffCommand(
            EntityUid.New(),
            snapshot.SnapshotUid,
            created.AccountUid,
            appliedLobby.Lobby.Revision.RevisionUid,
            ["commander_level"]));
    Assert.Empty(zeroLobbyDiff.Changes);
    var workspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(created.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, workspace.FetchedSnapshotUid);

    var draft = Assert.IsType<App.SourceFreeImportDraftProjection>(
        await service.GetImportDraftAsync(registered.SanitizedDraftUid));
    var diff = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            EntityUid.New(),
            draft.DraftUid,
            draft.DraftSha256,
            created.AccountUid,
            edited.ProfileRevision.RevisionUid,
            DetailLevelAuthority,
            ["full_profile"]));
    var characterLevel = Assert.Single(
        diff.Changes,
        item => item.FieldCode == "character_level" && item.SubjectUid == catalogs.CharacterUids[0]);
    Assert.Equal(199, characterLevel.Before?.IntegerValue);
    Assert.Equal(200, characterLevel.After?.IntegerValue);

    var incomplete = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            EntityUid.New(),
            TestInstant.AddMinutes(6),
            imported.Draft,
            new CredentialBearingProfileCoverage(2, 1, 1, 8, 2, 2, 1, 9),
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(null, null, null, null),
            Array.Empty<ProfileImportDiagnostic>()));
    var incompleteStored = await service.RegisterFetchedAccountSnapshotAsync(
        new App.RegisterFetchedAccountSnapshotCommand(
            created.AccountUid,
            edited.ProfileRevision.RevisionUid,
            Encoding.UTF8.GetString(FetchedAccountSnapshotJsonCodec.Encode(incomplete)),
            draftJson));
    Assert.Equal("incomplete", incompleteStored.CompletenessStatusCode);
    Assert.False(incompleteStored.IsCurrentWorkspaceSnapshot);
    copiedObservation = Assert.IsType<App.FetchedAccountSnapshotProjection>(
        await service.GetLatestFetchedAccountSnapshotAsync(copied.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, copiedObservation.SnapshotUid);
    Assert.NotEqual(incomplete.SnapshotUid, copiedObservation.SnapshotUid);
    chainedObservation = Assert.IsType<App.FetchedAccountSnapshotProjection>(
        await service.GetLatestFetchedAccountSnapshotAsync(chained.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, chainedObservation.SnapshotUid);
    workspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(created.AccountUid));
    Assert.Equal(snapshot.SnapshotUid, workspace.FetchedSnapshotUid);

    var progressionSnapshotUid = EntityUid.New();
    var progressionCapturedAt = TestInstant.AddMinutes(7);
    var progression = CreateProgressionObservation(
        progressionSnapshotUid,
        progressionCapturedAt);
    var progressionUtf8 = FetchedProgressionObservationV2JsonCodec.Encode(progression);
    var progressionSnapshot = FetchedAccountSnapshotMaterializer.Materialize(
        new FetchedAccountSnapshotMaterializationCommand(
            progressionSnapshotUid,
            progressionCapturedAt,
            imported.Draft,
            new CredentialBearingProfileCoverage(2, 2, 1, 8, 2, 2, 1, 9),
            new FetchedBasicAccountObservation("SyntheticLab", 893, "34-38", "20-31", "34-38"),
            new FetchedProgressionObservation(
                progression.MainQuestData.Summary.CanonicalEntriesSha256,
                progression.MainQuestData.CompletedCount,
                progression.CompletedScenarios.Summary.ItemCount,
                progression.ContentsOpenUnlocked.Summary.ItemCount,
                progressionSnapshotUid,
                Sha256Digest.Compute(progressionUtf8),
                progression.Completeness.StatusCode,
                progression.Completeness.ReasonCodes,
                progression.StageClearHistorys.Summary.ItemCount,
                progression.Triggers.Summary.ItemCount,
                progressionCapturedAt),
            Array.Empty<ProfileImportDiagnostic>()));
    var progressionSnapshotJson = Encoding.UTF8.GetString(
        FetchedAccountSnapshotJsonCodec.Encode(progressionSnapshot));
    var progressionJson = Encoding.UTF8.GetString(progressionUtf8);
    var progressionCommand = new App.RegisterFetchedAccountSnapshotCommand(
        created.AccountUid,
        edited.ProfileRevision.RevisionUid,
        progressionSnapshotJson,
        draftJson,
        progressionJson);
    var progressionStored = await service.RegisterFetchedAccountSnapshotAsync(progressionCommand);
    var progressionReplay = await service.RegisterFetchedAccountSnapshotAsync(progressionCommand);
    Assert.Equal(progressionStored, progressionReplay);
    Assert.False(progressionStored.IsCurrentWorkspaceSnapshot);
    var storedSidecar = Assert.IsType<App.FetchedProgressionObservationProjection>(
        progressionStored.Progression);
    Assert.Equal("incomplete", storedSidecar.CompletenessStatusCode);
    Assert.Equal(2, storedSidecar.AvailableComponentCount);
    Assert.Equal(2, storedSidecar.DerivedComponentCount);
    Assert.Equal(1, storedSidecar.UnavailableComponentCount);
    Assert.Equal(2, storedSidecar.MainQuestCompletedCount);
    Assert.Equal(2, storedSidecar.MainQuestRewardClaimedCount);
    Assert.Equal(3, storedSidecar.CompletedScenarioCount);
    Assert.Equal(1, storedSidecar.ContentsOpenUnlockedCount);
    Assert.Null(storedSidecar.StageClearHistoryCount);
    Assert.Equal(2, storedSidecar.TriggerCount);
    Assert.Equal(Sha256Digest.Compute(progressionUtf8), storedSidecar.CanonicalObservationSha256);
    var progressionRead = Assert.IsType<App.FetchedAccountSnapshotProjection>(
        await service.GetFetchedAccountSnapshotAsync(progressionSnapshotUid));
    Assert.Equal(progressionStored, progressionRead);

    var wrongBinding = progression with { SnapshotUid = EntityUid.New() };
    var bindingFailure = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
        service.RegisterFetchedAccountSnapshotAsync(
            progressionCommand with
            {
              CanonicalProgressionObservationJson = Encoding.UTF8.GetString(
                  FetchedProgressionObservationV2JsonCodec.Encode(wrongBinding))
            }));
    Assert.Equal("fetched_progression_observation_snapshot_parity_invalid", bindingFailure.Code);
  }

  [Fact]
  public async Task OperatorFetchedSnapshotDistinguishesLocalEditAndReturnsToSourceValue()
  {
    if (!string.Equals(
            Environment.GetEnvironmentVariable("NIKKE_LAB_OPERATOR_FETCH_ACCEPTANCE"),
            "1",
            StringComparison.Ordinal))
    {
      return;
    }

    var snapshotPath = Environment.GetEnvironmentVariable("NIKKE_LAB_OPERATOR_SNAPSHOT");
    var draftPath = Environment.GetEnvironmentVariable("NIKKE_LAB_OPERATOR_DRAFT");
    var progressionPath = Environment.GetEnvironmentVariable("NIKKE_LAB_OPERATOR_PROGRESSION");
    var receiptPath = Environment.GetEnvironmentVariable("NIKKE_LAB_OPERATOR_RECEIPT");
    if (string.IsNullOrWhiteSpace(snapshotPath) ||
        string.IsNullOrWhiteSpace(draftPath) ||
        string.IsNullOrWhiteSpace(receiptPath))
    {
      throw new InvalidOperationException("Operator acceptance paths are required.");
    }

    var snapshotUtf8 = await File.ReadAllBytesAsync(snapshotPath);
    var draftUtf8 = await File.ReadAllBytesAsync(draftPath);
    var snapshot = FetchedAccountSnapshotJsonCodec.Decode(snapshotUtf8);
    var draft = SanitizedProfileDraftJsonCodec.Decode(draftUtf8);
    string? canonicalProgressionJson = null;
    FetchedProgressionObservationV2? progression = null;
    if (!string.IsNullOrWhiteSpace(progressionPath))
    {
      var progressionUtf8 = await File.ReadAllBytesAsync(progressionPath);
      progression = FetchedProgressionObservationV2JsonCodec.Decode(progressionUtf8);
      Assert.Equal(snapshot.SnapshotUid, progression.SnapshotUid);
      Assert.Equal(snapshot.CapturedAtUtc, progression.CapturedAtUtc);
      canonicalProgressionJson = Encoding.UTF8.GetString(progressionUtf8);
    }
    Assert.Equal(snapshot.Source.ArtifactSha256, Sha256Digest.Compute(draftUtf8));
    Assert.False(snapshot.Source.CredentialOrSessionPersisted);
    Assert.False(snapshot.Source.RawSourcePersisted);

    await using var dataSource = CreateDataSource();
    Assert.Equal(0, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var importedAtUtc = snapshot.CapturedAtUtc;
    var importReceipt = await new PostgreSqlProfileImportStore(
        dataSource,
        new RandomEntityUidGenerator()).ImportDraftAsync(
        new ImportSanitizedProfileDraftCommand(
            EntityUid.New(),
            new SanitizedProfileDraftWrite(
                SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
                null,
                draft.Provenance.SourceSchemaSha256,
                draft.Provenance.TransformerBinarySha256,
                draft.Provenance.SemanticOptionsSha256,
                new LocalProfileCatalogBindingWrite(
                    draft.CharacterCatalog.CatalogSnapshotUid,
                    draft.CharacterCatalog.DatasetSnapshotUid,
                    draft.CharacterCatalog.ManifestSha256),
                new LocalProfileCatalogBindingWrite(
                    draft.CombatSupportCatalog.CatalogSnapshotUid,
                    draft.CombatSupportCatalog.DatasetSnapshotUid,
                    draft.CombatSupportCatalog.ManifestSha256),
                Encoding.UTF8.GetString(draftUtf8)),
            importedAtUtc));

    var service = new PostgreSqlProfileManagementService(
        dataSource,
        new RandomEntityUidGenerator(),
        new FixedTimeProvider(snapshot.CapturedAtUtc.AddMinutes(30)),
        draft.Provenance.TransformerBinarySha256);
    var createPreview = await service.PreviewCreateFromImportAsync(
        new App.CreateImportDiffCommand(
            EntityUid.New(),
            importReceipt.DraftUid,
            importReceipt.CanonicalPayloadSha256,
            DetailLevelAuthority,
            ["full_profile"]));
    var capabilityMismatches = await ReadCapabilityMismatchSummaryAsync(dataSource, draft);
    App.ProfileWriteReceipt created;
    try
    {
      created = await service.CreateFromImportAsync(
          new App.CreateFromImportCommand(
              EntityUid.New(),
              importReceipt.DraftUid,
              importReceipt.CanonicalPayloadSha256,
              createPreview.DiffSha256,
              DetailLevelAuthority,
              ["full_profile"]));
    }
    catch (App.ProfileManagementException exception)
    {
      throw new InvalidOperationException(
          $"{exception.Code}:capability_mismatch_summary=" +
          string.Join(',', capabilityMismatches),
          exception);
    }
    var sourceCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(created.AccountUid));
    var sourceSynchro = Assert.IsType<long>(
        Value(sourceCurrent, "synchro_level", null).IntegerValue);
    var localSynchro = checked(sourceSynchro + 1);
    var localEditPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            created.AccountUid,
            sourceCurrent.ProfileRevision.RevisionUid,
            [new App.ProfileEditOperation(
                "synchro_level",
                null,
                "integer",
                IntegerValue: localSynchro)]));
    var locallyEdited = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            created.AccountUid,
            sourceCurrent.ProfileRevision.RevisionUid,
            localEditPreview.CandidateDraftUid,
            localEditPreview.CandidateSha256,
            localEditPreview.DiffSha256));

    var sourceCommanderLevel = Assert.IsType<int>(snapshot.Account.CommanderLevel);
    var localCommanderLevel = checked(sourceCommanderLevel + 1);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initialized = await service.InitializeLocalStateAsync(
        new App.InitializeLocalStateCommand(
            EntityUid.New(),
            created.AccountUid,
            locallyEdited.ProfileRevision.RevisionUid,
            manifest.ManifestUid,
            manifest.ContentSha256,
            "Operator Local Lobby",
            localCommanderLevel,
            null,
            null,
            null,
            null,
            [
              new App.WalletBalanceProjection("credit", 0),
              new App.WalletBalanceProjection("jewel", 0)
            ]));
    Assert.Equal(localCommanderLevel, initialized.Lobby.CommanderLevel);

    var registered = await service.RegisterFetchedAccountSnapshotAsync(
        new App.RegisterFetchedAccountSnapshotCommand(
            created.AccountUid,
            locallyEdited.ProfileRevision.RevisionUid,
            Encoding.UTF8.GetString(snapshotUtf8),
            Encoding.UTF8.GetString(draftUtf8),
            canonicalProgressionJson));
    if (progression is not null)
    {
      var stored = Assert.IsType<App.FetchedProgressionObservationProjection>(
          registered.Progression);
      Assert.Equal(FetchedProgressionObservationV2Contract.ContractId, stored.ContractId);
      Assert.Equal(progression.Triggers.Summary.ItemCount, stored.TriggerCount);
    }
    var registeredDraft = Assert.IsType<App.SourceFreeImportDraftProjection>(
        await service.GetImportDraftAsync(registered.SanitizedDraftUid));
    var sourceDiff = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            EntityUid.New(),
            registeredDraft.DraftUid,
            registeredDraft.DraftSha256,
            created.AccountUid,
            locallyEdited.ProfileRevision.RevisionUid,
            NoLevelAuthority,
            ["account_state_only"]));
    var synchroDiff = Assert.Single(
        sourceDiff.Changes,
        item => item.FieldCode == "synchro_level" && item.SubjectUid is null);
    Assert.Equal(localSynchro, synchroDiff.Before?.IntegerValue);
    Assert.Equal(sourceSynchro, synchroDiff.After?.IntegerValue);

    var applied = await service.ApplyImportAsync(
        new App.ApplyImportCommand(
            EntityUid.New(),
            registeredDraft.DraftUid,
            registeredDraft.DraftSha256,
            created.AccountUid,
            locallyEdited.ProfileRevision.RevisionUid,
            sourceDiff.DiffSha256,
            NoLevelAuthority,
            ["account_state_only"]));
    var restored = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(created.AccountUid));
    Assert.Equal(sourceSynchro, Value(restored, "synchro_level", null).IntegerValue);

    var lobbyBeforeProjection = Assert.IsType<App.LobbyPresentationProjection>(
        await service.GetLobbyPresentationAsync(created.AccountUid));
    var lobbyDiff = await service.PreviewFetchedLobbyDiffAsync(
        new App.PreviewFetchedLobbyDiffCommand(
            EntityUid.New(),
            registered.SnapshotUid,
            created.AccountUid,
            lobbyBeforeProjection.Revision.RevisionUid,
            ["commander_level"]));
    var commanderDiff = Assert.Single(lobbyDiff.Changes);
    Assert.Equal("commander_level", commanderDiff.FieldCode);
    Assert.Equal(localCommanderLevel, commanderDiff.BeforeInteger);
    Assert.Equal(sourceCommanderLevel, commanderDiff.AfterInteger);
    var lobbyApplied = await service.ApplyFetchedLobbyAsync(
        new App.ApplyFetchedLobbyCommand(
            EntityUid.New(),
            registered.SnapshotUid,
            created.AccountUid,
            lobbyBeforeProjection.Revision.RevisionUid,
            lobbyDiff.DiffSha256,
            ["commander_level"]));
    Assert.Equal(sourceCommanderLevel, lobbyApplied.Lobby.CommanderLevel);
    Assert.Equal("Operator Local Lobby", lobbyApplied.Lobby.DisplayName);
    Assert.Null(lobbyApplied.Lobby.ProfileIconSelectionUid);
    Assert.Null(lobbyApplied.Lobby.ProfileFrameSelectionUid);
    Assert.Null(lobbyApplied.Lobby.LobbyCharacterSelectionUid);
    Assert.Null(lobbyApplied.Lobby.LobbyBackgroundSelectionUid);

    var secondSnapshot = snapshot with
    {
      SnapshotUid = EntityUid.New(),
      CapturedAtUtc = snapshot.CapturedAtUtc.AddMinutes(1)
    };
    var secondSnapshotUtf8 = FetchedAccountSnapshotJsonCodec.Encode(secondSnapshot);
    var secondRegistered = await service.RegisterFetchedAccountSnapshotAsync(
        new App.RegisterFetchedAccountSnapshotCommand(
            created.AccountUid,
            applied.ProfileRevision.RevisionUid,
            Encoding.UTF8.GetString(secondSnapshotUtf8),
            Encoding.UTF8.GetString(draftUtf8)));
    var zeroDiff = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            EntityUid.New(),
            secondRegistered.SanitizedDraftUid,
            registeredDraft.DraftSha256,
            created.AccountUid,
            applied.ProfileRevision.RevisionUid,
            NoLevelAuthority,
            ["account_state_only"]));
    Assert.Empty(zeroDiff.Changes);

    var receipt = new
    {
      schemaVersion = 1,
      contractId = "nll/phase-c-operator-fetch-acceptance/v1",
      completedAtUtc = DateTimeOffset.UtcNow.ToString("O"),
      accountUid = created.AccountUid.ToString(),
      snapshotUid = snapshot.SnapshotUid.ToString(),
      snapshotCompleteness = snapshot.Completeness.StatusCode,
      snapshotReasonCodes = snapshot.Completeness.ReasonCodes,
      rosterCount = snapshot.Completeness.RosterCount,
      detailCount = snapshot.Completeness.CharacterDetailCount,
      characterCount = snapshot.Characters.Count,
      progressionSidecarRegistered = progression is not null,
      progressionTriggerCount = progression?.Triggers.Summary.ItemCount,
      sourceSynchroLevel = sourceSynchro,
      localEditSynchroLevel = localSynchro,
      detectedDiffCount = sourceDiff.Changes.Count,
      selectedApplyRestoredSourceValue = true,
      sourceCommanderLevel,
      localCommanderLevel,
      commanderLobbyDiffCount = lobbyDiff.Changes.Count,
      commanderLobbySelectedApplyVerified = true,
      unselectedLobbyFieldsPreserved = true,
      sameCaptureSecondObservationDiffCount = zeroDiff.Changes.Count,
      freshExternalRefetchPerformed = false,
      rawSourcePersisted = false,
      officialUserIdentifierPersisted = false,
      credentialOrSessionPersisted = false,
      goldenModified = false,
      gameRuntimeModified = false,
      nextStepCode = "add_progression_observation_then_run_fresh_external_refetch"
    };
    await File.WriteAllTextAsync(
        receiptPath,
        JsonSerializer.Serialize(receipt, new JsonSerializerOptions { WriteIndented = true }),
        new UTF8Encoding(false));
  }

  [Fact]
  public async Task ReviewedOverridesAndExactRebasePreserveTypedLineage()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var unresolved = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant,
        bondLevel: 0,
        equipmentManufacturerCode: 0);
    Assert.True(unresolved.Draft.CanMaterializeLocalAccountProfile);
    Assert.False(unresolved.Draft.IsLocalAccountProfileWriteReady);
    var service = DefaultTransformerService(dataSource);
    var originalProjection = Assert.IsType<App.SourceFreeImportDraftProjection>(
        await service.GetImportDraftAsync(unresolved.Receipt.DraftUid));
    Assert.Contains(originalProjection.Values, static item =>
        item.FieldCode == "bond_level" && item.Status == "unresolved");
    Assert.Contains(originalProjection.Issues, static item =>
        item.Code == "bond_level_zero_semantics_unresolved");

    var reviewOperation = EntityUid.New();
    var reviewRequest = new App.ReviewImportDraftCommand(
        reviewOperation,
        unresolved.Receipt.DraftUid,
        unresolved.Receipt.CanonicalPayloadSha256,
        [
          new App.ImportReviewedOverrideRequest(
              App.ImportReviewedOverrideKind.BondLevel,
              catalogs.CharacterUids[0],
              null,
              1,
              null,
              "user_reviewed_override")
        ]);
    var reviewPreview = await service.PreviewReviewImportDraftAsync(reviewRequest);
    Assert.Single(reviewPreview.Changes);
    var reviewed = await service.ReviewImportDraftAsync(
        reviewRequest with { ExpectedDiffSha256 = reviewPreview.DiffSha256 });
    var reviewedReplay = await service.ReviewImportDraftAsync(
        reviewRequest with { ExpectedDiffSha256 = reviewPreview.DiffSha256 });
    Assert.Equal(reviewed.DraftUid, reviewedReplay.DraftUid);
    Assert.Equal("reviewed_override", reviewed.DerivationKind);
    Assert.Equal(unresolved.Receipt.DraftUid, reviewed.PreviousDraftUid);
    Assert.Single(reviewed.ReviewedOverrides);
    var reviewedStored = Assert.IsType<SanitizedProfileDraftDocument>(
        await new PostgreSqlProfileImportStore(
            dataSource,
            new RandomEntityUidGenerator()).GetDraftAsync(reviewed.DraftUid));
    Assert.Equal(
        Sha256Digest.Compute(File.ReadAllBytes(
            typeof(SanitizedProfileDraftJsonCodec).Assembly.Location)),
        reviewedStored.TransformerSha256);
    Assert.Equal(0, reviewed.Observations.Single(item =>
        item.ObservationKind == "bond_level_observation" &&
        item.CharacterUid == catalogs.CharacterUids[0]).ObservedValue);
    Assert.Equal(1, reviewed.Values.Single(item =>
        item.FieldCode == "bond_level" &&
        item.SubjectUid == catalogs.CharacterUids[0]).IntegerValue);

    var reviewedAccount = await CreateAccountFromImportAsync(
        service,
        reviewed.DraftUid,
        reviewed.DraftSha256,
        DetailLevelAuthority);
    var reviewedCurrent = Assert.IsType<App.CurrentProfileProjection>(
        await service.GetCurrentProfileAsync(reviewedAccount.AccountUid));
    Assert.Equal(
        1,
        Value(reviewedCurrent, "bond_level", catalogs.CharacterUids[0]).IntegerValue);
    Assert.Equal("not_applicable", Value(
        reviewedCurrent,
        "equipment.head.manufacturer_matched",
        catalogs.CharacterUids[0]).Status);

    var target = await PublishTargetCatalogAsync(dataSource, catalogs);
    var mappings = ReferencedMappings(unresolved.Draft, catalogs, target);
    var reversed = mappings.Reverse().ToDictionary(static item => item.Key, static item => item.Value);
    var targetCharacter = MapBinding(target.CharacterBinding);
    var targetSupport = MapBinding(target.SupportBinding);
    var rebaseOperation = EntityUid.New();
    var forwardCommand = new App.RebaseImportCommand(
        rebaseOperation,
        reviewed.DraftUid,
        reviewed.DraftSha256,
        targetCharacter,
        targetSupport,
        mappings);
    var forwardPreview = await service.PreviewRebaseAsync(forwardCommand);
    var reversePreview = await service.PreviewRebaseAsync(
        forwardCommand with { OperationUid = EntityUid.New(), ExplicitMappings = reversed });
    Assert.Equal(forwardPreview.DiffSha256, reversePreview.DiffSha256);

    var nonmember = mappings.ToDictionary(static item => item.Key, static item => item.Value);
    nonmember.Add(EntityUid.New(), EntityUid.New());
    var rejected = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
        service.PreviewRebaseAsync(
            forwardCommand with { OperationUid = EntityUid.New(), ExplicitMappings = nonmember }));
    Assert.Equal("import_rebase_mapping_source_not_found", rejected.Code);

    var nonmemberTarget = mappings.ToDictionary(static item => item.Key, static item => item.Value);
    nonmemberTarget[unresolved.Draft.Builds[0].CharacterUid] = EntityUid.New();
    var targetRejected = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
        service.PreviewRebaseAsync(
            forwardCommand with
            {
              OperationUid = EntityUid.New(),
              ExplicitMappings = nonmemberTarget
            }));
    Assert.Equal("profile_rebase_catalog_member_not_found", targetRejected.Code);

    var rebased = await service.RebaseImportAsync(
        forwardCommand with { ExpectedDiffSha256 = forwardPreview.DiffSha256 });
    Assert.Equal("rebase", rebased.DerivationKind);
    Assert.Equal(reviewed.DraftUid, rebased.PreviousDraftUid);
    Assert.Equal(targetSupport, rebased.CombatSupportCatalog);
    Assert.Single(rebased.ReviewedOverrides);

    var rebasedDocument = Assert.IsType<SanitizedProfileDraftDocument>(
        await new PostgreSqlProfileImportStore(
            dataSource,
            new RandomEntityUidGenerator()).GetDraftAsync(rebased.DraftUid));
    var decodedRebase = SanitizedProfileDraftJsonCodec.Decode(
        Encoding.UTF8.GetBytes(rebasedDocument.CanonicalPayloadJson));
    Assert.Equal(
        new[] { target.CharacterUids[1], target.CharacterUids[0] }
            .OrderBy(static uid => uid.ToString(), StringComparer.Ordinal),
        decodedRebase.Builds.Select(static build => build.CharacterUid));
  }

  [Fact]
  public async Task AggregateWorkspaceSaveSurvivesLobbyRevalidationAndReplaysExactly()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var created = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateSyntheticProfile(catalogs),
            TestInstant));
    var service = Service(dataSource);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initialized = await service.InitializeLocalStateAsync(
        new App.InitializeLocalStateCommand(
            EntityUid.New(),
            created.AccountUid,
            created.ProfileTemplateRevisionUid,
            manifest.ManifestUid,
            manifest.ContentSha256,
            "통합 저장 전",
            895,
            null,
            null,
            catalogs.CharacterUids[0],
            null,
            [new("credit", 100), new("jewel", 200)]));
    var workspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(created.AccountUid));
    var preview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            created.AccountUid,
            created.ProfileTemplateRevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 201)
            ]));
    var operationUid = EntityUid.New();
    var command = new App.SaveAccountWorkspaceCommand(
        operationUid,
        false,
        created.AccountUid,
        workspace.BaseRevisions.RevisionSetSha256,
        created.ProfileTemplateRevisionUid,
        initialized.Lobby.Revision.RevisionUid,
        initialized.Wallet.Revision.RevisionUid,
        preview.CandidateDraftUid,
        preview.CandidateSha256,
        preview.DiffSha256,
        workspace.AccountLabel,
        "통합 저장본",
        "통합 저장 후",
        896,
        null,
        null,
        catalogs.CharacterUids[0],
        null,
        [new("jewel", 2_000), new("credit", 1_000)]);

    var saved = await service.SaveAccountWorkspaceAsync(command);
    var replay = await service.SaveAccountWorkspaceAsync(command);
    var current = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(created.AccountUid));
    var currentWorkspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(created.AccountUid));

    Assert.False(saved.IsIdempotentReplay);
    Assert.True(replay.IsIdempotentReplay);
    Assert.Equal(saved with { IsIdempotentReplay = true }, replay);
    Assert.Equal(saved.ProfileRevision, current.Profile.ProfileRevision);
    Assert.Equal(saved.LobbyRevision, current.Lobby.Revision);
    Assert.Equal(saved.WalletRevision, current.Wallet.Revision);
    Assert.NotEqual(initialized.Lobby.Revision.RevisionUid, saved.LobbyRevision.RevisionUid);
    Assert.Equal("통합 저장 후", current.Lobby.DisplayName);
    Assert.Equal(896, current.Lobby.CommanderLevel);
    Assert.Equal("통합 저장본", currentWorkspace.AccountLabel);
    Assert.Equal(1_000, current.Wallet.Balances.Single(item => item.CurrencyCode == "credit").Balance);
    Assert.Equal(2_000, current.Wallet.Balances.Single(item => item.CurrencyCode == "jewel").Balance);

    var reuse = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
        service.SaveAccountWorkspaceAsync(command with { CommanderLevel = 897 }));
    Assert.Equal("account_workspace_save_operation_reuse_mismatch", reuse.Code);

    var copyPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            created.AccountUid,
            current.Profile.ProfileRevision.RevisionUid,
            []));
    var copyOperationUid = EntityUid.New();
    var copyCommand = new App.SaveAccountWorkspaceCommand(
        copyOperationUid,
        true,
        created.AccountUid,
        currentWorkspace.BaseRevisions.RevisionSetSha256,
        current.Profile.ProfileRevision.RevisionUid,
        current.Lobby.Revision.RevisionUid,
        current.Wallet.Revision.RevisionUid,
        copyPreview.CandidateDraftUid,
        copyPreview.CandidateSha256,
        copyPreview.DiffSha256,
        currentWorkspace.AccountLabel,
        "통합 저장본 복사본",
        current.Lobby.DisplayName,
        current.Lobby.CommanderLevel,
        current.Lobby.ProfileIconSelectionUid,
        current.Lobby.ProfileFrameSelectionUid,
        current.Lobby.LobbyCharacterSelectionUid,
        current.Lobby.LobbyBackgroundSelectionUid,
        current.Wallet.Balances);
    var copied = await service.SaveAccountWorkspaceAsync(copyCommand);
    var copiedReplay = await service.SaveAccountWorkspaceAsync(copyCommand);
    var copiedBootstrap = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(copied.AccountUid));
    var copiedWorkspace = Assert.IsType<App.AccountWorkspaceProjection>(
        await service.GetAccountWorkspaceAsync(copied.AccountUid));

    Assert.True(copied.SaveAs);
    Assert.NotEqual(created.AccountUid, copied.AccountUid);
    Assert.Equal(copied with { IsIdempotentReplay = true }, copiedReplay);
    Assert.Equal(copied.LobbyRevision, copiedBootstrap.Lobby.Revision);
    Assert.Equal(copied.WalletRevision, copiedBootstrap.Wallet.Revision);
    Assert.Equal("통합 저장본 복사본", copiedWorkspace.AccountLabel);
    Assert.Null(copied.ObservationSourceSnapshotUid);
    Assert.Null(await service.GetLatestFetchedAccountSnapshotAsync(copied.AccountUid));

    await using var count = dataSource.CreateCommand(
        "SELECT count(*) FROM lab_profile.account_workspace_save_operation;");
    Assert.Equal(2L, Convert.ToInt64(await count.ExecuteScalarAsync()));
    await using var binding = dataSource.CreateCommand(
        """
        SELECT count(*), count(source_snapshot_uid)
        FROM lab_profile.account_observation_provenance_binding;
        """);
    await using var bindingReader = await binding.ExecuteReaderAsync();
    Assert.True(await bindingReader.ReadAsync());
    Assert.Equal(1L, bindingReader.GetInt64(0));
    Assert.Equal(0L, bindingReader.GetInt64(1));
  }

  [Fact]
  public async Task ImportCreationMaterializesOwnedCubesBeforeFirstNoOpSave()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var imported = await ImportStrictDraftAsync(dataSource, catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1, TestInstant);
    var service = Service(dataSource);
    var created = await CreateAccountFromImportAsync(service, imported, DetailLevelAuthority);
    var store = new PostgreSqlLocalAccountProfileStore(dataSource, new RandomEntityUidGenerator());
    var current = (await store.GetCurrentAsync(created.AccountUid))!;
    Assert.Equal(15, Assert.Single(current.Profile.AccountState.Cubes).Level);
    var countBefore = await CountProfileRevisionsAsync(dataSource, created.AccountUid);
    var preview = await service.PreviewProfileEditsAsync(new(EntityUid.New(), created.AccountUid,
        created.ProfileRevision.RevisionUid, []));
    Assert.Empty(preview.Changes);
    var saved = await service.SaveProfileAsync(new(EntityUid.New(), created.AccountUid,
        created.ProfileRevision.RevisionUid, preview.CandidateDraftUid, preview.CandidateSha256,
        preview.DiffSha256));
    Assert.Equal(created.ProfileRevision, saved.ProfileRevision);
    Assert.Equal(countBefore, await CountProfileRevisionsAsync(dataSource, created.AccountUid));
  }

  [Fact]
  public async Task TypedSquadInventoryLobbyRevalidationAndApplicationRecoveryAreDurable()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var sourceCreate = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateSyntheticProfileWithOwnedCube(catalogs),
            TestInstant));
    var service = Service(dataSource);
    var manifest = await service.EnsureBuiltInFeatureManifestAsync();
    var initializeCommand = new App.InitializeLocalStateCommand(
        EntityUid.New(),
        sourceCreate.AccountUid,
        sourceCreate.ProfileTemplateRevisionUid,
        manifest.ManifestUid,
        manifest.ContentSha256,
        "Projection Lab",
        833,
        null,
        null,
        catalogs.CharacterUids[0],
        null,
        [
          new App.WalletBalanceProjection("credit", 10_037_000),
          new App.WalletBalanceProjection("jewel", 1_771)
        ]);
    var initialized = await service.InitializeLocalStateAsync(initializeCommand);
    Assert.Equal(5, initialized.Roster.Count);
    Assert.Equal(catalogs.CharacterUids.Take(5), initialized.Squad!.Members
        .OrderBy(static item => item.Position)
        .Select(static item => item.CharacterUid));
    var head = initialized.Inventory.Items.Single(item =>
        item.ItemKind == "equipment" &&
        item.CharacterUid == catalogs.CharacterUids[0] &&
        item.SlotCode == "head");
    Assert.True(Value(head, "manufacturer_matched").BooleanValue);
    Assert.Equal(123456789, Value(head, "overload.1.value").UnscaledValue);
    Assert.Equal(9, Value(head, "overload.1.value").DecimalScale);
    Assert.Equal("absent", Value(head, "overload.2.state").ControlledValue);
    Assert.Equal(-987654321, Value(head, "overload.3.value").UnscaledValue);
    Assert.Equal(9, Value(head, "overload.3.value").DecimalScale);

    var profileRevisionCountBeforeEmpty = await CountProfileRevisionsAsync(
        dataSource,
        sourceCreate.AccountUid);
    var lobbyRevisionCountBeforeEmpty = await CountLobbyRevisionsAsync(
        dataSource,
        sourceCreate.AccountUid);
    var emptyInitializedPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            sourceCreate.ProfileTemplateRevisionUid,
            []));
    Assert.Empty(emptyInitializedPreview.Changes);
    var emptyInitializedSave = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            sourceCreate.ProfileTemplateRevisionUid,
            emptyInitializedPreview.CandidateDraftUid,
            emptyInitializedPreview.CandidateSha256,
            emptyInitializedPreview.DiffSha256));
    var afterEmptyInitializedSave = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(sourceCreate.AccountUid));
    Assert.Equal(initialized.Profile.ProfileRevision, emptyInitializedSave.ProfileRevision);
    Assert.Equal(initialized.Profile.ProfileRevision, afterEmptyInitializedSave.Profile.ProfileRevision);
    Assert.Equal(initialized.Lobby.Revision, afterEmptyInitializedSave.Lobby.Revision);
    Assert.Equal(
        profileRevisionCountBeforeEmpty,
        await CountProfileRevisionsAsync(dataSource, sourceCreate.AccountUid));
    Assert.Equal(
        lobbyRevisionCountBeforeEmpty,
        await CountLobbyRevisionsAsync(dataSource, sourceCreate.AccountUid));

    var beforeRejectedPromotion = Assert.IsType<LocalCurrentAccountProfile>(
        await profileStore.GetCurrentAsync(sourceCreate.AccountUid));
    var lobbyBeforeRejectedPromotion = Assert.IsType<App.LobbyPresentationProjection>(
        await service.GetLobbyPresentationAsync(sourceCreate.AccountUid));
    var profileWithoutLobbyCharacter = new LocalAccountProfileWrite(
        beforeRejectedPromotion.Profile.CharacterCatalog,
        beforeRejectedPromotion.Profile.CombatSupportCatalog,
        beforeRejectedPromotion.Profile.AccountState,
        beforeRejectedPromotion.Profile.Builds.Where(
            build => build.CharacterUid != catalogs.CharacterUids[0]),
        squadCharacterUids: null,
        beforeRejectedPromotion.Profile.SquadOrigin,
        beforeRejectedPromotion.Profile.ProfileTemplateOrigin);
    var rejectedPromotion = await Assert.ThrowsAsync<LocalAccountProfileIntegrityException>(() =>
        profileStore.SaveAsync(
            new SaveLocalAccountProfileCommand(
                EntityUid.New(),
                sourceCreate.AccountUid,
                sourceCreate.ProfileTemplateRevisionUid,
                profileWithoutLobbyCharacter,
                TestInstant.AddMinutes(1))));
    Assert.Equal("local_game_lobby_character_not_in_profile", rejectedPromotion.Code);
    var afterRejectedPromotion = Assert.IsType<LocalCurrentAccountProfile>(
        await profileStore.GetCurrentAsync(sourceCreate.AccountUid));
    var lobbyAfterRejectedPromotion = Assert.IsType<App.LobbyPresentationProjection>(
        await service.GetLobbyPresentationAsync(sourceCreate.AccountUid));
    Assert.Equal(
        beforeRejectedPromotion.Revision.ProfileTemplateRevisionUid,
        afterRejectedPromotion.Revision.ProfileTemplateRevisionUid);
    Assert.Equal(
        beforeRejectedPromotion.Revision.ProfileContentSha256,
        afterRejectedPromotion.Revision.ProfileContentSha256);
    Assert.Equal(lobbyBeforeRejectedPromotion.Revision, lobbyAfterRejectedPromotion.Revision);
    Assert.Equal(
        profileRevisionCountBeforeEmpty,
        await CountProfileRevisionsAsync(dataSource, sourceCreate.AccountUid));
    Assert.Equal(
        lobbyRevisionCountBeforeEmpty,
        await CountLobbyRevisionsAsync(dataSource, sourceCreate.AccountUid));

    var editPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            sourceCreate.ProfileTemplateRevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 201)
            ]));
    var edited = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            sourceCreate.ProfileTemplateRevisionUid,
            editPreview.CandidateDraftUid,
            editPreview.CandidateSha256,
            editPreview.DiffSha256));
    var revalidated = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(sourceCreate.AccountUid));
    Assert.Equal(edited.ProfileRevision, revalidated.Profile.ProfileRevision);
    Assert.NotEqual(initialized.Lobby.Revision.RevisionUid, revalidated.Lobby.Revision.RevisionUid);
    Assert.Equal(
        initialized.Lobby.Revision.RevisionNumber + 1,
        revalidated.Lobby.Revision.RevisionNumber);
    Assert.Equal(initialized.Lobby.DisplayName, revalidated.Lobby.DisplayName);

    var initializeReplay = await service.InitializeLocalStateAsync(initializeCommand);
    Assert.Equal(edited.ProfileRevision, initializeReplay.Profile.ProfileRevision);
    Assert.Equal(revalidated.RevisionSetSha256, initializeReplay.RevisionSetSha256);

    var lobbyCommand = new App.SaveLobbyPresentationCommand(
        EntityUid.New(),
        sourceCreate.AccountUid,
        revalidated.Lobby.Revision.RevisionUid,
        "Projection Lab Edited",
        834,
        null,
        null,
        catalogs.CharacterUids[0],
        null);
    var lobbySaved = await WithPostgresDiagnosticsAsync(
        () => service.SaveLobbyPresentationAsync(lobbyCommand));
    var promotePreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            edited.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 202)
            ]));
    var promoted = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            edited.ProfileRevision.RevisionUid,
            promotePreview.CandidateDraftUid,
            promotePreview.CandidateSha256,
            promotePreview.DiffSha256));
    var lobbyReplay = await service.SaveLobbyPresentationAsync(lobbyCommand);
    Assert.Equal(lobbySaved, lobbyReplay);
    var promotedBootstrap = Assert.IsType<App.AccountBootstrapProjection>(
        await service.GetCurrentBootstrapAsync(sourceCreate.AccountUid));
    Assert.Equal(promoted.ProfileRevision, promotedBootstrap.Profile.ProfileRevision);
    Assert.Equal(lobbySaved.DisplayName, promotedBootstrap.Lobby.DisplayName);
    Assert.NotEqual(lobbySaved.Revision.RevisionUid, promotedBootstrap.Lobby.Revision.RevisionUid);

    var importStore = new PostgreSqlProfileImportStore(
        dataSource,
        new RandomEntityUidGenerator());
    var sameAccountPreviewOperation = EntityUid.New();
    var sameAccountPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            sameAccountPreviewOperation,
            sourceCreate.AccountUid,
            promoted.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 203)
            ]));
    var sameAccountDiff = Assert.IsType<ProfileDraftDiffDocument>(
        await importStore.GetDiffAsync(sameAccountPreviewOperation));
    var sameAccountWriteOperation = EntityUid.New();
    var sameAccountIntent = new LinkProfileDraftApplicationCommand(
        sameAccountWriteOperation,
        ProfileDraftApplicationKind.Apply,
        sameAccountDiff.DiffUid,
        sameAccountWriteOperation,
        sameAccountDiff.CreatedAtUtc);
    _ = await importStore.BeginApplicationAsync(sameAccountIntent);
    var sameAccountSecondPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            promoted.ProfileRevision.RevisionUid,
            [
              new App.ProfileEditOperation(
                  "character_level",
                  catalogs.CharacterUids[0],
                  "integer",
                  IntegerValue: 203)
            ]));
    Assert.Equal(
        sameAccountPreview.CandidateSha256,
        sameAccountSecondPreview.CandidateSha256);
    Assert.Equal(sameAccountPreview.Changes, sameAccountSecondPreview.Changes);
    Assert.NotEqual(
        sameAccountPreview.CandidateDraftUid,
        sameAccountSecondPreview.CandidateDraftUid);
    Assert.NotEqual(sameAccountPreview.DiffSha256, sameAccountSecondPreview.DiffSha256);
    var interruptedWrite = await profileStore.SaveAsync(
        new SaveLocalAccountProfileCommand(
            sameAccountWriteOperation,
            sourceCreate.AccountUid,
            promoted.ProfileRevision.RevisionUid,
            CreateSyntheticProfileWithOwnedCube(catalogs, 203),
            sameAccountDiff.CreatedAtUtc));
    var mismatchedRecovery = await Assert.ThrowsAsync<LocalGameStateIntegrityException>(() =>
        importStore.TryRecoverApplicationAsync(
            sameAccountWriteOperation,
            ProfileDraftApplicationKind.Apply,
            EntityUid.New(),
            sameAccountWriteOperation));
    Assert.Equal("profile_draft_application_intent_reuse_mismatch", mismatchedRecovery.Code);
    var recoveredSameAccount = await service.SaveProfileAsync(
        new App.SaveProfileCommand(
            sameAccountWriteOperation,
            sourceCreate.AccountUid,
            promoted.ProfileRevision.RevisionUid,
            sameAccountPreview.CandidateDraftUid,
            sameAccountPreview.CandidateSha256,
            sameAccountPreview.DiffSha256));
    Assert.Equal(interruptedWrite.AccountUid, recoveredSameAccount.AccountUid);
    Assert.Equal(
        interruptedWrite.ProfileTemplateRevisionUid,
        recoveredSameAccount.ProfileRevision.RevisionUid);
    Assert.True(recoveredSameAccount.IsIdempotentReplay);
    var activeRevision = recoveredSameAccount.ProfileRevision;
    var completedSameAccount = Assert.IsType<ProfileDraftApplicationReceipt>(
        await importStore.TryRecoverApplicationAsync(
            sameAccountWriteOperation,
            ProfileDraftApplicationKind.Apply,
            sameAccountDiff.DiffUid,
            sameAccountWriteOperation));
    Assert.Equal(sameAccountDiff.DiffUid, completedSameAccount.DiffUid);

    var applyDraft = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant.AddMinutes(5));
    var applyPreviewOperation = EntityUid.New();
    var applyPreview = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            applyPreviewOperation,
            applyDraft.Receipt.DraftUid,
            applyDraft.Receipt.CanonicalPayloadSha256,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            NoLevelAuthority,
            ["account_state_only"]));
    var applyDiff = Assert.IsType<ProfileDraftDiffDocument>(
        await importStore.GetDiffAsync(applyPreviewOperation));
    var applyWriteOperation = EntityUid.New();
    _ = await importStore.BeginApplicationAsync(
        new LinkProfileDraftApplicationCommand(
            applyWriteOperation,
            ProfileDraftApplicationKind.Apply,
            applyDiff.DiffUid,
            applyWriteOperation,
            applyDiff.CreatedAtUtc));
    var applySecondPreview = await service.PreviewImportDiffAsync(
        new App.ImportDiffCommand(
            EntityUid.New(),
            applyDraft.Receipt.DraftUid,
            applyDraft.Receipt.CanonicalPayloadSha256,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            NoLevelAuthority,
            ["account_state_only"]));
    Assert.Equal(applyPreview.DiffSha256, applySecondPreview.DiffSha256);
    var applyCommand = new App.ApplyImportCommand(
            applyWriteOperation,
            applyDraft.Receipt.DraftUid,
            applyDraft.Receipt.CanonicalPayloadSha256,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            applyPreview.DiffSha256,
            NoLevelAuthority,
            ["account_state_only"]);
    // Fail the real service after its profile transaction commits, before linking the
    // application receipt. Do not duplicate private materialization logic via reflection.
    await using (var injectionConnection = await dataSource.OpenConnectionAsync())
    {
      await using var inject = new NpgsqlCommand("""
          CREATE FUNCTION public.synthetic_reject_profile_link() RETURNS trigger
          LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic_profile_link_failure'; END $$;
          CREATE TRIGGER synthetic_reject_profile_link
          BEFORE INSERT ON lab_local_game.profile_draft_application
          FOR EACH ROW EXECUTE FUNCTION public.synthetic_reject_profile_link();
          """, injectionConnection);
      await inject.ExecuteNonQueryAsync();
      try
      {
        var failure = await Assert.ThrowsAsync<App.ProfileManagementException>(() =>
            service.ApplyImportAsync(applyCommand));
        Assert.Equal("sanitized_import_database_rejected", failure.Code);
        Assert.NotNull(await profileStore.GetByOperationAsync(applyWriteOperation));
        await using var unlinked = new NpgsqlCommand("""
            SELECT count(*) FROM lab_local_game.profile_draft_application WHERE application_uid = @uid;
            """, injectionConnection);
        unlinked.Parameters.AddWithValue("uid", applyWriteOperation.Value);
        Assert.Equal(0L, await unlinked.ExecuteScalarAsync());
      }
      finally
      {
        await using var remove = new NpgsqlCommand("""
            DROP TRIGGER synthetic_reject_profile_link ON lab_local_game.profile_draft_application;
            DROP FUNCTION public.synthetic_reject_profile_link();
            """, injectionConnection);
        await remove.ExecuteNonQueryAsync();
      }
    }

    var interruptedApply = (await profileStore.GetByOperationAsync(applyWriteOperation))!;
    var countBeforeRecovery = await CountProfileRevisionsAsync(dataSource, sourceCreate.AccountUid);
    var recoveredApply = await Service(dataSource).ApplyImportAsync(applyCommand);
    Assert.Equal(countBeforeRecovery, await CountProfileRevisionsAsync(dataSource, sourceCreate.AccountUid));
    Assert.Equal(interruptedApply.AccountUid, recoveredApply.AccountUid);
    Assert.Equal(
        interruptedApply.ProfileTemplateRevisionUid,
        recoveredApply.ProfileRevision.RevisionUid);
    Assert.True(recoveredApply.IsIdempotentReplay);
    var completedApply = Assert.IsType<ProfileDraftApplicationReceipt>(
        await importStore.TryRecoverApplicationAsync(
            applyWriteOperation,
            ProfileDraftApplicationKind.Apply,
            applyDiff.DiffUid,
            applyWriteOperation));
    Assert.Equal(applyDiff.DiffUid, completedApply.DiffUid);
    activeRevision = recoveredApply.ProfileRevision;

    var intentPreviewOperation = EntityUid.New();
    var intentPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            intentPreviewOperation,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            []));
    var intentDiff = Assert.IsType<ProfileDraftDiffDocument>(
        await importStore.GetDiffAsync(intentPreviewOperation));
    var intentOperation = EntityUid.New();
    var intent = new LinkProfileDraftApplicationCommand(
        intentOperation,
        ProfileDraftApplicationKind.SaveAs,
        intentDiff.DiffUid,
        intentOperation,
        intentDiff.CreatedAtUtc);
    var firstIntent = await importStore.BeginApplicationAsync(intent);
    var intentReplay = await importStore.BeginApplicationAsync(intent);
    Assert.False(firstIntent.IsIdempotentReplay);
    Assert.True(intentReplay.IsIdempotentReplay);
    Assert.Null(await importStore.TryRecoverApplicationAsync(
        intentOperation,
        ProfileDraftApplicationKind.SaveAs,
        intentDiff.DiffUid,
        intentOperation));
    var intentSecondPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            []));
    Assert.Equal(intentPreview.CandidateSha256, intentSecondPreview.CandidateSha256);
    Assert.Equal(intentPreview.Changes, intentSecondPreview.Changes);
    Assert.NotEqual(intentPreview.CandidateDraftUid, intentSecondPreview.CandidateDraftUid);
    Assert.NotEqual(intentPreview.DiffSha256, intentSecondPreview.DiffSha256);
    var completedIntent = await service.SaveAsProfileAsync(
        new App.SaveAsProfileCommand(
            intentOperation,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            intentPreview.CandidateDraftUid,
            intentPreview.CandidateSha256,
            intentPreview.DiffSha256));
    var recoveredIntent = Assert.IsType<ProfileDraftApplicationReceipt>(
        await importStore.TryRecoverApplicationAsync(
            intentOperation,
            ProfileDraftApplicationKind.SaveAs,
            intentDiff.DiffUid,
            intentOperation));
    Assert.Equal(completedIntent.AccountUid, recoveredIntent.ResultAccountUid);

    var legacyPreviewOperation = EntityUid.New();
    var legacyPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            legacyPreviewOperation,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            []));
    var legacyDiff = Assert.IsType<ProfileDraftDiffDocument>(
        await importStore.GetDiffAsync(legacyPreviewOperation));
    var legacyWriteOperation = EntityUid.New();
    var source = Assert.IsType<LocalCurrentAccountProfile>(
        await profileStore.GetCurrentAsync(sourceCreate.AccountUid));
    var writeBeforeLink = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            legacyWriteOperation,
            source.Profile,
            legacyDiff.CreatedAtUtc,
            saveAsParentAccountUid: sourceCreate.AccountUid));
    var legacySecondPreview = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            EntityUid.New(),
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            []));
    Assert.Equal(legacyPreview.CandidateSha256, legacySecondPreview.CandidateSha256);
    Assert.Equal(legacyPreview.Changes, legacySecondPreview.Changes);
    Assert.NotEqual(legacyPreview.CandidateDraftUid, legacySecondPreview.CandidateDraftUid);
    Assert.NotEqual(legacyPreview.DiffSha256, legacySecondPreview.DiffSha256);
    Assert.Null(await importStore.TryRecoverApplicationAsync(
        legacyWriteOperation,
        ProfileDraftApplicationKind.SaveAs,
        legacyDiff.DiffUid,
        legacyWriteOperation));
    var recoveredLegacy = await service.SaveAsProfileAsync(
        new App.SaveAsProfileCommand(
            legacyWriteOperation,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            legacyPreview.CandidateDraftUid,
            legacyPreview.CandidateSha256,
            legacyPreview.DiffSha256));
    Assert.Equal(writeBeforeLink.AccountUid, recoveredLegacy.AccountUid);
    Assert.True(recoveredLegacy.IsIdempotentReplay);
    Assert.NotNull(await importStore.TryRecoverApplicationAsync(
        legacyWriteOperation,
        ProfileDraftApplicationKind.SaveAs,
        legacyDiff.DiffUid,
        legacyWriteOperation));
  }

  [Fact]
  public async Task RawDraftAndEditorCandidateRemainExclusiveDatabaseSources()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var imported = await ImportStrictDraftAsync(
        dataSource,
        catalogs,
        CharacterLevelAuthorityPolicy.DetailObservationV1,
        TestInstant);
    var service = Service(dataSource);
    var account = await CreateAccountFromImportAsync(service, imported, DetailLevelAuthority);
    var editorOperation = EntityUid.New();
    _ = await service.PreviewProfileEditsAsync(
        new App.ProfileEditPreviewCommand(
            editorOperation,
            account.AccountUid,
            account.ProfileRevision.RevisionUid,
            []));

    await using var connection = await dataSource.OpenConnectionAsync();
    await using (var shape = new NpgsqlCommand(
        """
        SELECT count(*),
               count(*) FILTER (WHERE sanitized_profile_draft_id IS NOT NULL),
               count(*) FILTER (WHERE profile_edit_candidate_id IS NOT NULL),
               count(*) FILTER (
                   WHERE num_nonnulls(sanitized_profile_draft_id, profile_edit_candidate_id) <> 1)
        FROM lab_local_game.profile_draft_diff;
        """,
        connection))
    await using (var reader = await shape.ExecuteReaderAsync())
    {
      Assert.True(await reader.ReadAsync());
      Assert.Equal(2, reader.GetInt64(0));
      Assert.Equal(1, reader.GetInt64(1));
      Assert.Equal(1, reader.GetInt64(2));
      Assert.Equal(0, reader.GetInt64(3));
    }

    await using var invalid = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.profile_draft_diff (
            profile_draft_diff_uid, request_sha256,
            sanitized_profile_draft_id, profile_edit_candidate_id,
            local_account_id, base_profile_template_revision_id,
            diff_contract_version, canonical_diff_json, canonical_diff_sha256,
            change_count, has_conflicts, created_at_utc
        )
        SELECT @uid, @hash,
               draft.sanitized_profile_draft_id, candidate.profile_edit_candidate_id,
               candidate.local_account_id, candidate.base_profile_template_revision_id,
               'profile_edit_diff.v1', '{}', @hash, 0, false, @created_at
        FROM lab_local_game.sanitized_profile_draft AS draft
        CROSS JOIN lab_local_game.profile_edit_candidate AS candidate
        WHERE draft.sanitized_profile_draft_uid = @draft_uid
          AND candidate.operation_uid = @candidate_operation;
        """,
        connection);
    invalid.Parameters.AddWithValue("uid", EntityUid.New().Value);
    invalid.Parameters.AddWithValue("hash", Sha256Digest.ComputeUtf8("{}").ToByteArray());
    invalid.Parameters.AddWithValue("created_at", TestInstant.AddMinutes(10));
    invalid.Parameters.AddWithValue("draft_uid", imported.Receipt.DraftUid.Value);
    invalid.Parameters.AddWithValue("candidate_operation", editorOperation.Value);
    var xor = await Assert.ThrowsAsync<PostgresException>(() => invalid.ExecuteNonQueryAsync());
    Assert.Equal(PostgresErrorCodes.CheckViolation, xor.SqlState);
  }

  [Fact]
  public async Task OrphanWalletRevisionCannotCommitWithoutCurrentPromotion()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(MigrationBaseline.Count, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var created = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateSyntheticProfile(catalogs),
            TestInstant));

    await using var connection = await dataSource.OpenConnectionAsync();
    await using var transaction = await connection.BeginTransactionAsync();
    long accountId;
    await using (var account = new NpgsqlCommand(
        """
        SELECT local_account_id
        FROM lab_profile.local_account
        WHERE local_account_uid = @account_uid;
        """,
        connection,
        transaction))
    {
      account.Parameters.AddWithValue("account_uid", created.AccountUid.Value);
      accountId = Convert.ToInt64(await account.ExecuteScalarAsync());
    }

    long walletId;
    await using (var wallet = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.wallet_revision (
            wallet_revision_uid, local_account_id, revision_number,
            previous_wallet_revision_id, balance_count, content_sha256,
            revision_origin, materialized_at_utc
        ) VALUES (@uid, @account_id, 1, NULL, 2, @hash, 'system_default', @created_at)
        RETURNING wallet_revision_id;
        """,
        connection,
        transaction))
    {
      wallet.Parameters.AddWithValue("uid", Guid.NewGuid());
      wallet.Parameters.AddWithValue("account_id", accountId);
      wallet.Parameters.AddWithValue("hash", new byte[32]);
      wallet.Parameters.AddWithValue(
          "created_at",
          new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero));
      walletId = Convert.ToInt64(await wallet.ExecuteScalarAsync());
    }

    await using (var balances = new NpgsqlCommand(
        """
        INSERT INTO lab_local_game.wallet_balance (
            wallet_revision_id, currency_code, amount
        ) VALUES
            (@wallet_id, 'jewel', 0),
            (@wallet_id, 'credit', 0);
        """,
        connection,
        transaction))
    {
      balances.Parameters.AddWithValue("wallet_id", walletId);
      await balances.ExecuteNonQueryAsync();
    }

    var orphan = await Assert.ThrowsAsync<PostgresException>(async () =>
        await transaction.CommitAsync());
    Assert.Equal("local_game_revision_not_published", orphan.MessageText);
  }

  private static PostgreSqlProfileManagementService Service(NpgsqlDataSource dataSource) => new(
      dataSource,
      new RandomEntityUidGenerator(),
      new FixedTimeProvider(TestInstant.AddMinutes(30)),
      TransformerBinarySha256);

  private static PostgreSqlProfileManagementService DefaultTransformerService(
      NpgsqlDataSource dataSource) => new(
          dataSource,
          new RandomEntityUidGenerator(),
          new FixedTimeProvider(TestInstant.AddMinutes(30)));

  private static async Task<long> CountProfileRevisionsAsync(
      NpgsqlDataSource dataSource,
      EntityUid accountUid)
  {
    await using var command = dataSource.CreateCommand(
        """
        SELECT count(*)
        FROM lab_profile.profile_template_revision AS revision
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = revision.local_account_id
        WHERE account.local_account_uid = @account_uid;
        """);
    command.Parameters.AddWithValue("account_uid", accountUid.Value);
    return Convert.ToInt64(await command.ExecuteScalarAsync());
  }

  private static async Task<long> CountLobbyRevisionsAsync(
      NpgsqlDataSource dataSource,
      EntityUid accountUid)
  {
    await using var command = dataSource.CreateCommand(
        """
        SELECT count(*)
        FROM lab_local_game.lobby_presentation_revision AS revision
        JOIN lab_profile.local_account AS account
          ON account.local_account_id = revision.local_account_id
        WHERE account.local_account_uid = @account_uid;
        """);
    command.Parameters.AddWithValue("account_uid", accountUid.Value);
    return Convert.ToInt64(await command.ExecuteScalarAsync());
  }

  private static async Task<IReadOnlyList<string>> ReadCapabilityMismatchSummaryAsync(
      NpgsqlDataSource dataSource,
      SanitizedProfileDraft draft)
  {
    await using var command = dataSource.CreateCommand(
        """
        SELECT
            entity.character_uid,
            capability.capability_code,
            capability.resolution_status,
            capability.maximum_level
        FROM lab_catalog.character_catalog_snapshot AS snapshot
        JOIN lab_catalog.character_catalog_snapshot_member AS member
          ON member.character_catalog_snapshot_id = snapshot.character_catalog_snapshot_id
        JOIN lab_catalog.character_entity AS entity
          ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_capability AS capability
          ON capability.character_definition_version_id = member.character_definition_version_id
        WHERE snapshot.character_catalog_snapshot_uid = @snapshot_uid
          AND entity.character_uid = ANY(@character_uids);
        """);
    command.Parameters.AddWithValue("snapshot_uid", draft.CharacterCatalog.CatalogSnapshotUid.Value);
    command.Parameters.AddWithValue(
        "character_uids",
        draft.Builds.Select(static item => item.CharacterUid.Value).ToArray());
    var capabilities = new Dictionary<(Guid CharacterUid, string Code), (string Status, int? Maximum)>();
    await using (var reader = await command.ExecuteReaderAsync())
    {
      while (await reader.ReadAsync())
      {
        capabilities.Add(
            (reader.GetGuid(0), reader.GetString(1)),
            (reader.GetString(2), reader.IsDBNull(3) ? null : reader.GetInt32(3)));
      }
    }

    var mismatches = new Dictionary<string, int>(StringComparer.Ordinal);
    void Check(EntityUid characterUid, string code, int value)
    {
      if (!capabilities.TryGetValue((characterUid.Value, code), out var capability))
      {
        Increment($"{code}:missing");
      }
      else if (capability.Status != "ready" || capability.Maximum is null)
      {
        if (code == "core_level" && capability.Status == "not_applicable" && value == 0)
        {
          return;
        }

        Increment($"{code}:{capability.Status}");
      }
      else if (value > capability.Maximum.Value)
      {
        Increment($"{code}:exceeded");
      }
    }

    void Increment(string key) => mismatches[key] = mismatches.GetValueOrDefault(key) + 1;
    foreach (var build in draft.Builds)
    {
      Check(build.CharacterUid, "character_level", build.Level.DetailLevel);
      Check(build.CharacterUid, "limit_break", build.LimitBreak);
      Check(build.CharacterUid, "core_level", build.CoreLevel);
      if (build.ResolvedBondLevel.Status == ProfileImportFactStatus.Ready)
      {
        Check(build.CharacterUid, "bond_level", build.ResolvedBondLevel.Value!.Value);
      }
      Check(build.CharacterUid, "skill_1", build.Skill1Level);
      Check(build.CharacterUid, "skill_2", build.Skill2Level);
      Check(build.CharacterUid, "burst", build.BurstLevel);
    }
    return mismatches.OrderBy(static item => item.Key, StringComparer.Ordinal)
        .Select(static item => $"{item.Key}:{item.Value}")
        .ToArray();
  }

  private static App.ProfileValueProjection Value(
      App.CurrentProfileProjection profile,
      string fieldCode,
      EntityUid? subjectUid) => profile.Values.Single(item =>
          item.FieldCode == fieldCode && item.SubjectUid == subjectUid);

  private static App.ProfileValueProjection Value(
      App.InventoryItemProjection item,
      string fieldCode) => item.Values.Single(value => value.FieldCode == fieldCode);

  private static App.CatalogBindingProjection MapBinding(
      LocalProfileCatalogBindingWrite value) => new(
          value.CatalogSnapshotUid,
          value.DatasetSnapshotUid,
          value.CatalogManifestSha256);

  private static FetchedProgressionObservationV2 CreateProgressionObservation(
      EntityUid snapshotUid,
      DateTimeOffset capturedAtUtc)
  {
    const string privateSourceJson = """
        {
          "schemaVersion": 1,
          "contractId": "nll/phase3b2-user-progression-private-source/v1",
          "sourceSequencePersisted": false,
          "officialUserIdentifierPersisted": false,
          "credentialOrSessionFieldPersisted": false,
          "selectedTriggers": [
            { "typeCode": 2, "conditionId": 920001, "userValue": 1, "createdAt": 100 },
            { "typeCode": 22, "conditionId": 920002, "userValue": 1, "createdAt": 101 }
          ],
          "mainQuestData": [
            { "questId": 910001, "rewardClaimed": true },
            { "questId": 910002, "rewardClaimed": true }
          ]
        }
        """;
    const string candidateJson = """
        {
          "Users": [
            {
              "CompletedScenarios": [930001, 930002, 930003],
              "MainQuestData": { "910001": true, "910002": true },
              "ContentsOpenUnlocked": {
                "940001": { "ButtonAnimationPlayed": true, "PopupAnimationPlayed": true }
              },
              "StageClearHistorys": [],
              "Triggers": [
                { "Type": 2, "ConditionId": 920001 },
                { "Type": 22, "ConditionId": 920002 }
              ]
            }
          ]
        }
        """;
    using var privateSource = new MemoryStream(Encoding.UTF8.GetBytes(privateSourceJson));
    using var candidate = new MemoryStream(Encoding.UTF8.GetBytes(candidateJson));
    return LegacyProgressionObservationMaterializerV2.Materialize(
        new LegacyProgressionMaterializationCommandV2(
            snapshotUid,
            capturedAtUtc,
            privateSource,
            candidate,
            IdentitySecret));
  }

  private static async Task<App.ProfileWriteReceipt> CreateAccountFromImportAsync(
      PostgreSqlProfileManagementService service,
      ImportedDraftFixture draft,
      string authority) => await CreateAccountFromImportAsync(
          service,
          draft.Receipt.DraftUid,
          draft.Receipt.CanonicalPayloadSha256,
          authority);

  private static async Task<App.ProfileWriteReceipt> CreateAccountFromImportAsync(
      PostgreSqlProfileManagementService service,
      EntityUid draftUid,
      Sha256Digest draftSha256,
      string authority)
  {
    var preview = await service.PreviewCreateFromImportAsync(
        new App.CreateImportDiffCommand(
            EntityUid.New(),
            draftUid,
            draftSha256,
            authority,
            ["full_profile"]));
    Assert.Empty(preview.Issues);
    return await WithPostgresDiagnosticsAsync(() => service.CreateFromImportAsync(
        new App.CreateFromImportCommand(
            EntityUid.New(),
            draftUid,
            draftSha256,
            preview.DiffSha256,
            authority,
            ["full_profile"])));
  }

  private static async Task<T> WithPostgresDiagnosticsAsync<T>(Func<Task<T>> action)
  {
    string? databaseMessage = null;
    void Observe(object? _, FirstChanceExceptionEventArgs eventArgs)
    {
      if (eventArgs.Exception is NpgsqlException postgres)
      {
        databaseMessage = postgres is PostgresException server
            ? server.MessageText
            : postgres.Message;
      }
    }

    AppDomain.CurrentDomain.FirstChanceException += Observe;
    try
    {
      return await action();
    }
    catch (App.ProfileManagementException exception) when (databaseMessage is not null)
    {
      throw new InvalidOperationException(
          $"{exception.Code}:{databaseMessage}",
          exception);
    }
    finally
    {
      AppDomain.CurrentDomain.FirstChanceException -= Observe;
    }
  }

  private static async Task<ImportedDraftFixture> ImportStrictDraftAsync(
      NpgsqlDataSource dataSource,
      SyntheticCatalogFixture catalogs,
      CharacterLevelAuthorityPolicy authority,
      DateTimeOffset importedAtUtc,
      int bondLevel = 30,
      int equipmentManufacturerCode = 0,
      int synchroLevel = 200)
  {
    using var source = SyntheticCapture.Create(
        bondLevel,
        equipmentManufacturerCode,
        synchroLevel,
        catalogs.OptionRawValue1,
        catalogs.OptionRawValue3);
    var result = new CredentialBearingProfileSanitizer().Sanitize(
        source,
        IdentitySecret,
        new SyntheticResolver(catalogs),
        new OfflineProfileImportOptions(
            importedAtUtc,
            TransformerBinarySha256,
            authority));
    Assert.True(
        result.Succeeded,
        string.Join(',', result.Diagnostics.Select(static item => $"{item.Code}:{item.Count}")));
    var draft = Assert.IsType<SanitizedProfileDraft>(result.Draft);
    var canonical = Encoding.UTF8.GetString(SanitizedProfileDraftJsonCodec.Encode(draft));
    var command = new ImportSanitizedProfileDraftCommand(
        EntityUid.New(),
        new SanitizedProfileDraftWrite(
            SanitizedProfileDraftDerivationKind.OfflineSanitizedImport,
            null,
            draft.Provenance.SourceSchemaSha256,
            draft.Provenance.TransformerBinarySha256,
            draft.Provenance.SemanticOptionsSha256,
            catalogs.CharacterBinding,
            catalogs.SupportBinding,
            canonical),
        importedAtUtc);
    var receipt = await new PostgreSqlProfileImportStore(
        dataSource,
        new RandomEntityUidGenerator()).ImportDraftAsync(command);
    return new ImportedDraftFixture(draft, receipt, command);
  }

  private static async Task<SyntheticCatalogFixture> PublishCatalogFixtureAsync(
      NpgsqlDataSource dataSource,
      int characterCount,
      string characterSnapshotTag = "profile-character")
  {
    var method = typeof(PostgreSqlLocalAccountProfileTests).GetMethod(
        "PublishSyntheticCatalogsAsync",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var sourceFixture = await InvokeTaskResultAsync(
        method,
        null,
        dataSource,
        characterCount,
        false,
        false,
        false,
        characterSnapshotTag);
    var character = Property<object>(sourceFixture, "Character");
    var support = Property<object>(sourceFixture, "Support");
    var characterBinding = Property<LocalProfileCatalogBindingWrite>(character, "Binding");
    var supportBinding = Property<LocalProfileCatalogBindingWrite>(support, "Binding");
    var characterUids = Property<IReadOnlyList<EntityUid>>(character, "CharacterUids");
    var selections = await ReadSupportSelectionsAsync(
        dataSource,
        supportBinding.CatalogSnapshotUid);
    return new SyntheticCatalogFixture(
        characterBinding,
        supportBinding,
        characterUids,
        selections.Consoles,
        selections.Equipment,
        selections.OptionUid,
        selections.OptionUnit,
        selections.OptionRawValue1,
        selections.OptionRawValue3,
        selections.CubeUid,
        selections.CollectionUid,
        sourceFixture,
        selections.SourceFixture);
  }

  private static async Task<SupportSelectionFixture> ReadSupportSelectionsAsync(
      NpgsqlDataSource dataSource,
      EntityUid catalogUid)
  {
    var method = typeof(PostgreSqlLocalAccountProfileTests).GetMethod(
        "ReadSupportSelectionsAsync",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var source = await InvokeTaskResultAsync(method, null, dataSource, catalogUid);
    var optionUid = Property<EntityUid>(source, "OptionUid");
    var rawValues = new List<long>();
    await using (var connection = await dataSource.OpenConnectionAsync())
    await using (var command = new NpgsqlCommand(
        """
        SELECT legal.engine_fraction_unscaled_value
        FROM lab_combat_support.catalog_snapshot AS catalog
        JOIN lab_combat_support.catalog_snapshot_member AS member
          ON member.catalog_snapshot_id = catalog.catalog_snapshot_id
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.overload_legal_value AS legal
          ON legal.definition_version_id = member.definition_version_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND entity.definition_uid = @option_uid
        ORDER BY legal.roll_level
        LIMIT 2;
        """,
        connection))
    {
      command.Parameters.AddWithValue("catalog_uid", catalogUid.Value);
      command.Parameters.AddWithValue("option_uid", optionUid.Value);
      await using var reader = await command.ExecuteReaderAsync();
      while (await reader.ReadAsync())
      {
        rawValues.Add(reader.GetInt64(0));
      }
    }

    Assert.Equal(2, rawValues.Count);
    return new SupportSelectionFixture(
        Property<IReadOnlyDictionary<LocalConsoleCoordinate, EntityUid>>(source, "Consoles"),
        Property<IReadOnlyDictionary<LocalEquipmentSlot, EntityUid>>(source, "Equipment"),
        optionUid,
        Property<LocalProfileValueUnit>(source, "OptionUnit"),
        rawValues[0],
        rawValues[1],
        Property<EntityUid>(source, "CubeUid"),
        Property<EntityUid>(source, "CollectionUid"),
        source);
  }

  private static LocalAccountProfileWrite CreateSyntheticProfile(
      SyntheticCatalogFixture catalogs,
      int? firstCharacterLevel = null)
  {
    var method = typeof(PostgreSqlLocalAccountProfileTests).GetMethod(
        "CreateProfile",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    return (LocalAccountProfileWrite)method.Invoke(
        null,
        [
          catalogs.SourceCatalogFixture,
          catalogs.SourceSupportSelections,
          200,
          firstCharacterLevel,
          false
        ])!;
  }

  private static LocalAccountProfileWrite CreateSyntheticProfileWithOwnedCube(
      SyntheticCatalogFixture catalogs,
      int? firstCharacterLevel = null)
  {
    var profile = CreateSyntheticProfile(catalogs, firstCharacterLevel);
    // Low-level store fixtures may deliberately model a pre-cube-policy revision.
    // No-op editor/recovery tests instead start with an already materialized inventory.
    return new LocalAccountProfileWrite(
            profile.CharacterCatalog, profile.CombatSupportCatalog,
            new LocalAccountCombatStateWrite(
                profile.AccountState.SynchroLevel, profile.AccountState.Consoles,
                profile.AccountState.ValidationMode, profile.AccountState.Origin,
                [new LocalOwnedCubeWrite(catalogs.CubeUid, 15)]),
            profile.Builds, profile.SquadCharacterUids, profile.SquadOrigin,
            profile.ProfileTemplateOrigin);
  }

  private static async Task<TargetCatalogFixture> PublishTargetCatalogAsync(
      NpgsqlDataSource dataSource,
      SyntheticCatalogFixture source)
  {
    var characterTestType = typeof(PostgreSqlCharacterCatalogTests);
    var characterSecret = (byte[])characterTestType.GetField(
        "IdentitySecretA",
        BindingFlags.NonPublic | BindingFlags.Static)!.GetValue(null)!;
    var createDefinition = characterTestType.GetMethod(
        "CreateDefinition",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var aliases = Enumerable.Range(0, source.CharacterUids.Count)
        .Select(index => SourceAliasFingerprintEncoder.Encode(
            characterSecret,
            "synthetic.rebase-character",
            "character",
            index.ToString(System.Globalization.CultureInfo.InvariantCulture)))
        .ToArray();
    var definitions = aliases.Select((alias, index) =>
        (CharacterCatalogDefinition)createDefinition.Invoke(
            null,
            [alias, $"rebase-{index}", CharacterCombatClassCode.Attacker, false])!).ToArray();
    var characterPublication = new CharacterCatalogPublication(
        CharacterCatalogIdentityBinding.FromSecret(characterSecret),
        definitions);
    var createCharacterAttempt = characterTestType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var characterAttempt = (CompletedImportAttempt)createCharacterAttempt.Invoke(
        null,
        ["rebase-character-source", "rebase-character-output", Array.Empty<SafeDiagnostic>()])!;
    var characterReceipt = await new PostgreSqlCharacterCatalogImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            characterAttempt,
            characterPublication);

    var supportAliasSecret = Enumerable.Range(151, 32)
        .Select(static value => checked((byte)value))
        .ToArray();
    var supportTestType = typeof(PostgreSqlCombatSupportCatalogTests);
    var supportIdentitySecret = (byte[])supportTestType.GetField(
        "IdentitySecret",
        BindingFlags.NonPublic | BindingFlags.Static)!.GetValue(null)!;
    var createSupportPublication = supportTestType.GetMethod(
        "CreatePublication",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var supportBinding = CombatSupportCatalogIdentityBinding.FromSecret(supportIdentitySecret);
    var supportPublication = (CombatSupportCatalogPublication)createSupportPublication.Invoke(
        null,
        [supportBinding, aliases[0], supportAliasSecret, 0, 580])!;
    var createSupportAttempt = supportTestType.GetMethod(
        "CreateAttempt",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    var supportAttempt = (CompletedImportAttempt)createSupportAttempt.Invoke(
        null,
        [
          supportPublication,
          "rebase-support-source",
          "combat_support_staticdata",
          "rebase-v1"
        ])!;
    var supportReceipt = await new PostgreSqlCombatSupportCatalogImportStore(
        dataSource,
        new RandomEntityUidGenerator()).RecordCompletedAndPublishAsync(
            supportAttempt,
            supportPublication);
    var selections = await ReadSupportSelectionsAsync(
        dataSource,
        supportReceipt.CombatSupportCatalogSnapshotUid);
    return new TargetCatalogFixture(
        new LocalProfileCatalogBindingWrite(
            characterReceipt.CharacterCatalogSnapshotUid,
            characterReceipt.Import.DatasetSnapshotUid!.Value,
            characterReceipt.CatalogManifestSha256),
        characterReceipt.Members.Select(static member => member.CharacterUid).ToArray(),
        new LocalProfileCatalogBindingWrite(
            supportReceipt.CombatSupportCatalogSnapshotUid,
            supportReceipt.Import.DatasetSnapshotUid!.Value,
            supportReceipt.CatalogManifestSha256),
        selections.Consoles,
        selections.Equipment,
        selections.OptionUid,
        selections.CubeUid,
        selections.CollectionUid);
  }

  private static IReadOnlyDictionary<EntityUid, EntityUid> ReferencedMappings(
      SanitizedProfileDraft sourceDraft,
      SyntheticCatalogFixture source,
      TargetCatalogFixture target)
  {
    var mappings = new Dictionary<EntityUid, EntityUid>();
    var sourceBuilds = sourceDraft.Builds.ToArray();
    Assert.True(sourceBuilds.Length >= 2);
    mappings.Add(sourceBuilds[0].CharacterUid, target.CharacterUids[1]);
    mappings.Add(sourceBuilds[1].CharacterUid, target.CharacterUids[0]);
    foreach (var console in sourceDraft.AccountState.Consoles)
    {
      var coordinate = Enum.Parse<LocalConsoleCoordinate>(console.Coordinate.ToString());
      mappings.Add(console.DefinitionUid, target.Consoles[coordinate]);
    }

    mappings.Add(source.Equipment[LocalEquipmentSlot.Head], target.Equipment[LocalEquipmentSlot.Head]);
    mappings.Add(source.OptionUid, target.OptionUid);
    mappings.Add(source.CubeUid, target.CubeUid);
    mappings.Add(source.CollectionUid, target.CollectionUid);
    return mappings;
  }

  private static async Task<object> InvokeTaskResultAsync(
      MethodInfo method,
      object? instance,
      params object?[] arguments)
  {
    var task = (Task)method.Invoke(instance, arguments)!;
    await task;
    return task.GetType().GetProperty("Result")!.GetValue(task)!;
  }

  private static T Property<T>(object value, string name) =>
      (T)value.GetType().GetProperty(name)!.GetValue(value)!;

  private static class SyntheticCapture
  {
    internal const long CharacterA = 771_001_001;
    internal const long CharacterB = 771_001_002;
    internal const long EquipmentHead = 772_001_001;
    internal const long Cube = 773_001_001;
    internal const long Collection = 774_001_001;
    internal const long OverloadLine1 = 775_001_001;
    internal const long OverloadLine3 = 775_001_003;
    internal const long ConsoleBase = 776_001_000;

    internal static MemoryStream Create(
        int bondLevel,
        int equipmentManufacturerCode,
        int synchroLevel,
        long overloadValue1,
        long overloadValue3)
    {
      var details = new[]
      {
        Detail(
            CharacterA,
            200,
            1_000,
            withEquipment: true,
            equipmentManufacturerCode,
            bondLevel),
        Detail(
            CharacterB,
            101,
            2_000,
            withEquipment: false,
            equipmentManufacturerCode: 0,
            bondLevel: 30)
      };
      var root = new Dictionary<string, object?>
      {
        ["uid"] = "raw-account-sentinel",
        ["phase_1_initial_load"] = new object[]
        {
          Packet("roster", new
          {
            characters = new[]
            {
              Roster(CharacterA, 100, 1_000),
              Roster(CharacterB, 101, 2_000)
            }
          }),
          Packet("outpost", new
          {
            outpost_info = new
            {
              synchro_level = synchroLevel,
              synchro_nonempty_slot_count = 2,
              recycle_room_researches = Enumerable.Range(1, 9)
                  .Select(index => new
                  {
                    tid = ConsoleBase + index,
                    lv = index,
                    exp = index * 10L
                  }).ToArray()
            }
          }),
          Packet("login", new
          {
            open_id = "raw-open-id-sentinel",
            token = "secret-token-value"
          })
        },
        ["phase_2_after_click"] = new object[]
        {
          Packet("details", new
          {
            character_details = details,
            state_effects = new[]
            {
              StateEffect(OverloadLine1, overloadValue1),
              StateEffect(OverloadLine3, overloadValue3)
            }
          })
        }
      };
      return new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(root), writable: false);
    }

    private static object Packet(string endpoint, object data) => new
    {
      endpoint,
      url = "https://official.invalid/private",
      data
    };

    private static object Roster(long reference, int level, long combat) => new
    {
      name_code = reference,
      lv = level,
      grade = 3,
      core = 2,
      combat,
      costume_id = 991_000_001L
    };

    private static Dictionary<string, object> Detail(
        long reference,
        int level,
        long combat,
        bool withEquipment,
        int equipmentManufacturerCode,
        int bondLevel)
    {
      var result = new Dictionary<string, object>
      {
        ["name_code"] = reference,
        ["lv"] = level,
        ["grade"] = 3,
        ["core"] = 2,
        ["combat"] = combat,
        ["attractive_lv"] = bondLevel,
        ["skill1_lv"] = 10,
        ["skill2_lv"] = 10,
        ["ulti_skill_lv"] = 10,
        ["harmony_cube_tid"] = withEquipment ? Cube : 0L,
        ["harmony_cube_lv"] = withEquipment ? 15 : 0,
        ["favorite_item_tid"] = withEquipment ? Collection : 0L,
        ["favorite_item_lv"] = withEquipment ? 5 : 0
      };
      foreach (var prefix in new[] { "head", "torso", "arm", "leg" })
      {
        var equipped = withEquipment && prefix == "head";
        result[$"{prefix}_equip_tid"] = equipped ? EquipmentHead : 0L;
        result[$"{prefix}_equip_tier"] = equipped ? 10 : 0;
        result[$"{prefix}_equip_lv"] = equipped ? 5 : 0;
        result[$"{prefix}_equip_corporation_type"] =
            equipped ? equipmentManufacturerCode : 0;
        result[$"{prefix}_equip_option1_id"] = equipped ? OverloadLine1 : 0L;
        result[$"{prefix}_equip_option2_id"] = 0L;
        result[$"{prefix}_equip_option3_id"] = equipped ? OverloadLine3 : 0L;
      }

      return result;
    }

    private static object StateEffect(long reference, long rawValue) => new
    {
      id = reference.ToString(System.Globalization.CultureInfo.InvariantCulture),
      function_details = new[]
      {
        new
        {
          id = reference + 10,
          function_type = "synthetic",
          function_value = rawValue,
          function_value_type = "Percent"
        }
      }
    };
  }

  private sealed class SyntheticResolver : IProfileCatalogAliasResolver
  {
    private readonly SyntheticCatalogFixture _catalogs;

    internal SyntheticResolver(SyntheticCatalogFixture catalogs)
    {
      _catalogs = catalogs;
      CharacterCatalog = new ProfileImportCatalogBinding(
          catalogs.CharacterBinding.CatalogSnapshotUid,
          catalogs.CharacterBinding.DatasetSnapshotUid,
          catalogs.CharacterBinding.CatalogManifestSha256);
      CombatSupportCatalog = new ProfileImportCatalogBinding(
          catalogs.SupportBinding.CatalogSnapshotUid,
          catalogs.SupportBinding.DatasetSnapshotUid,
          catalogs.SupportBinding.CatalogManifestSha256);
    }

    public ProfileImportCatalogBinding CharacterCatalog { get; }

    public ProfileImportCatalogBinding CombatSupportCatalog { get; }

    public ProfileAliasResolution<ResolvedProfileCharacter> ResolveCharacter(
        SourceAliasFingerprint sourceAlias)
    {
      if (sourceAlias == Alias("character-resource", SyntheticCapture.CharacterA))
      {
        return Character(_catalogs.CharacterUids[0]);
      }

      return sourceAlias == Alias("character-resource", SyntheticCapture.CharacterB)
          ? Character(_catalogs.CharacterUids[1])
          : ProfileAliasResolution<ResolvedProfileCharacter>.Missing();
    }

    public ProfileAliasResolution<ResolvedProfileEquipment> ResolveEquipment(
        SourceAliasFingerprint sourceAlias) =>
        sourceAlias == Alias("combat-support-equipment", SyntheticCapture.EquipmentHead)
            ? ProfileAliasResolution<ResolvedProfileEquipment>.Resolved(
                new ResolvedProfileEquipment(
                    _catalogs.Equipment[LocalEquipmentSlot.Head],
                    ProfileImportEquipmentSlot.Head,
                    ProfileImportCombatRole.Attacker,
                    ProfileImportFact<ProfileImportManufacturer>.NotApplicable(),
                    10,
                    5,
                    true))
            : ProfileAliasResolution<ResolvedProfileEquipment>.Missing();

    public ProfileAliasResolution<ResolvedProfileCube> ResolveCube(
        SourceAliasFingerprint sourceAlias) =>
        sourceAlias == Alias("combat-support-harmony-cube", SyntheticCapture.Cube)
            ? ProfileAliasResolution<ResolvedProfileCube>.Resolved(
                new ResolvedProfileCube(
                    _catalogs.CubeUid,
                    15,
                    ProfileImportCombatRole.Attacker))
            : ProfileAliasResolution<ResolvedProfileCube>.Missing();

    public ProfileAliasResolution<ResolvedProfileCollection> ResolveGenericCollection(
        SourceAliasFingerprint sourceAlias) =>
        sourceAlias == Alias("combat-support-generic-collection", SyntheticCapture.Collection)
            ? ProfileAliasResolution<ResolvedProfileCollection>.Resolved(
                new ResolvedProfileCollection(
                    _catalogs.CollectionUid,
                    ProfileImportCollectionKind.GenericCollection,
                    15,
                    null,
                    ProfileImportWeaponClass.AssaultRifle))
            : ProfileAliasResolution<ResolvedProfileCollection>.Missing();

    public ProfileAliasResolution<ResolvedProfileCollection> ResolveFavorite(
        SourceAliasFingerprint sourceAlias) =>
        ProfileAliasResolution<ResolvedProfileCollection>.Missing();

    public ProfileAliasResolution<ResolvedProfileConsole> ResolveConsole(
        SourceAliasFingerprint sourceAlias,
        int selectedLevel)
    {
      foreach (var coordinate in Enum.GetValues<ProfileImportConsoleCoordinate>())
      {
        var raw = SyntheticCapture.ConsoleBase + (int)coordinate + 1;
        if (sourceAlias == Alias("combat-support-console", raw))
        {
          var local = Enum.Parse<LocalConsoleCoordinate>(coordinate.ToString());
          return ProfileAliasResolution<ResolvedProfileConsole>.Resolved(
              new ResolvedProfileConsole(
                  _catalogs.Consoles[local],
                  coordinate,
                  selectedLevel,
                  580,
                  ProfileImportFact<int>.Ready(100)));
        }
      }

      return ProfileAliasResolution<ResolvedProfileConsole>.Missing();
    }

    public ProfileAliasResolution<ResolvedProfileOverloadValue> ResolveOverloadValue(
        SourceAliasFingerprint sourceAlias)
    {
      if (sourceAlias == Alias(
              "combat-support-overload-legal-value",
              SyntheticCapture.OverloadLine1))
      {
        return Overload(_catalogs.OptionRawValue1);
      }

      return sourceAlias == Alias(
              "combat-support-overload-legal-value",
              SyntheticCapture.OverloadLine3)
          ? Overload(_catalogs.OptionRawValue3)
          : ProfileAliasResolution<ResolvedProfileOverloadValue>.Missing();
    }

    private static ProfileAliasResolution<ResolvedProfileCharacter> Character(EntityUid uid) =>
        ProfileAliasResolution<ResolvedProfileCharacter>.Resolved(
            new ResolvedProfileCharacter(
                uid,
                ProfileImportRarity.Ssr,
                ProfileImportCombatRole.Attacker,
                ProfileImportManufacturer.Elysion,
                ProfileImportWeaponClass.AssaultRifle,
                400,
                3,
                7,
                40,
                10,
                10,
                10));

    private ProfileAliasResolution<ResolvedProfileOverloadValue> Overload(long value) =>
        ProfileAliasResolution<ResolvedProfileOverloadValue>.Resolved(
            new ResolvedProfileOverloadValue(
                _catalogs.OptionUid,
                Enum.Parse<ProfileImportValueUnit>(_catalogs.OptionUnit.ToString()),
                value,
                new ProfileImportExactValue(value, 4)));

    private static SourceAliasFingerprint Alias(string kind, long sourceReference) =>
        SourceAliasFingerprintEncoder.Encode(
            IdentitySecret,
            "nikke-staticdata",
            kind,
            sourceReference.ToString(System.Globalization.CultureInfo.InvariantCulture));
  }

  private sealed class FixedTimeProvider(DateTimeOffset value) : TimeProvider
  {
    public override DateTimeOffset GetUtcNow() => value;
  }

  private sealed record ImportedDraftFixture(
      SanitizedProfileDraft Draft,
      SanitizedProfileDraftReceipt Receipt,
      ImportSanitizedProfileDraftCommand Command);

  private sealed record SyntheticCatalogFixture(
      LocalProfileCatalogBindingWrite CharacterBinding,
      LocalProfileCatalogBindingWrite SupportBinding,
      IReadOnlyList<EntityUid> CharacterUids,
      IReadOnlyDictionary<LocalConsoleCoordinate, EntityUid> Consoles,
      IReadOnlyDictionary<LocalEquipmentSlot, EntityUid> Equipment,
      EntityUid OptionUid,
      LocalProfileValueUnit OptionUnit,
      long OptionRawValue1,
      long OptionRawValue3,
      EntityUid CubeUid,
      EntityUid CollectionUid,
      object SourceCatalogFixture,
      object SourceSupportSelections);

  private sealed record SupportSelectionFixture(
      IReadOnlyDictionary<LocalConsoleCoordinate, EntityUid> Consoles,
      IReadOnlyDictionary<LocalEquipmentSlot, EntityUid> Equipment,
      EntityUid OptionUid,
      LocalProfileValueUnit OptionUnit,
      long OptionRawValue1,
      long OptionRawValue3,
      EntityUid CubeUid,
      EntityUid CollectionUid,
      object SourceFixture);

  private sealed record TargetCatalogFixture(
      LocalProfileCatalogBindingWrite CharacterBinding,
      IReadOnlyList<EntityUid> CharacterUids,
      LocalProfileCatalogBindingWrite SupportBinding,
      IReadOnlyDictionary<LocalConsoleCoordinate, EntityUid> Consoles,
      IReadOnlyDictionary<LocalEquipmentSlot, EntityUid> Equipment,
      EntityUid OptionUid,
      EntityUid CubeUid,
      EntityUid CollectionUid);

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

  private static async Task ResetAndMigrateAsync(NpgsqlDataSource dataSource)
  {
    await ResetSchemasAsync(dataSource);
    await new PostgreSqlMigrationRunner().MigrateAsync(dataSource);
  }

  private static Task<int> ApplyWorkspaceTestMigrationsAsync(NpgsqlDataSource dataSource, int count) =>
      new PostgreSqlMigrationRunner(PostgreSqlMigrationRunner.LoadEmbeddedMigrations(
          typeof(PostgreSqlMigrationRunner).Assembly).Take(count).ToArray()).MigrateAsync(dataSource);

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
}
