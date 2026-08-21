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

public sealed class PostgreSqlLocalGameStateTests
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
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

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
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

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
    Assert.True(Value(head, "manufacturer_matched").BooleanValue);
    Assert.Equal("present", Value(head, "overload.1.state").ControlledValue);
    Assert.Equal(catalogs.OptionRawValue1, Value(head, "overload.1.value").UnscaledValue);
    Assert.Equal(4, Value(head, "overload.1.value").DecimalScale);
    Assert.Equal("absent", Value(head, "overload.2.state").ControlledValue);
    Assert.Equal("present", Value(head, "overload.3.state").ControlledValue);
    Assert.Equal(catalogs.OptionRawValue3, Value(head, "overload.3.value").UnscaledValue);
    Assert.Equal(4, Value(head, "overload.3.value").DecimalScale);
  }

  [Fact]
  public async Task ImportAuthorityScopesEditorSaveAsAndCasRemainExplicit()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
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
        emptyPreview.DiffSha256);
    var savedAs = await service.SaveAsProfileAsync(saveAsCommand);
    var savedAsReplay = await service.SaveAsProfileAsync(saveAsCommand);
    Assert.NotEqual(afterAccountOnly.AccountUid, savedAs.AccountUid);
    Assert.True(savedAsReplay.IsIdempotentReplay);
    Assert.Equal(savedAs.AccountUid, savedAsReplay.AccountUid);

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
  public async Task ReviewedOverridesAndExactRebasePreserveTypedLineage()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
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
              "user_reviewed_override"),
          new App.ImportReviewedOverrideRequest(
              App.ImportReviewedOverrideKind.EquipmentManufacturerMatched,
              catalogs.CharacterUids[0],
              App.ImportEquipmentSlot.Head,
              null,
              true,
              "original_client_verified_override")
        ]);
    var reviewPreview = await service.PreviewReviewImportDraftAsync(reviewRequest);
    Assert.Equal(2, reviewPreview.Changes.Count);
    var reviewed = await service.ReviewImportDraftAsync(
        reviewRequest with { ExpectedDiffSha256 = reviewPreview.DiffSha256 });
    var reviewedReplay = await service.ReviewImportDraftAsync(
        reviewRequest with { ExpectedDiffSha256 = reviewPreview.DiffSha256 });
    Assert.Equal(reviewed.DraftUid, reviewedReplay.DraftUid);
    Assert.Equal("reviewed_override", reviewed.DerivationKind);
    Assert.Equal(unresolved.Receipt.DraftUid, reviewed.PreviousDraftUid);
    Assert.Equal(2, reviewed.ReviewedOverrides.Count);
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
    Assert.True(Value(
        reviewedCurrent,
        "equipment.head.manufacturer_matched",
        catalogs.CharacterUids[0]).BooleanValue);

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
    Assert.Equal(2, rebased.ReviewedOverrides.Count);

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
  public async Task TypedSquadInventoryLobbyRevalidationAndApplicationRecoveryAreDurable()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
    var catalogs = await PublishCatalogFixtureAsync(dataSource, 5);
    var profileStore = new PostgreSqlLocalAccountProfileStore(
        dataSource,
        new RandomEntityUidGenerator());
    var sourceCreate = await profileStore.CreateAsync(
        new CreateLocalAccountProfileCommand(
            EntityUid.New(),
            CreateSyntheticProfile(catalogs),
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
            CreateSyntheticProfile(catalogs, 203),
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
    var applySource = Assert.IsType<LocalCurrentAccountProfile>(
        await profileStore.GetCurrentAsync(sourceCreate.AccountUid));
    var interruptedApply = await profileStore.SaveAsync(
        new SaveLocalAccountProfileCommand(
            applyWriteOperation,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            MaterializeImportProfile(
                applySource,
                applyDraft.Draft,
                NoLevelAuthority,
                ["account_state_only"]),
            applyDiff.CreatedAtUtc));
    var recoveredApply = await service.ApplyImportAsync(
        new App.ApplyImportCommand(
            applyWriteOperation,
            applyDraft.Receipt.DraftUid,
            applyDraft.Receipt.CanonicalPayloadSha256,
            sourceCreate.AccountUid,
            activeRevision.RevisionUid,
            applyPreview.DiffSha256,
            NoLevelAuthority,
            ["account_state_only"]));
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
            legacyDiff.CreatedAtUtc));
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
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));
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
    Assert.Equal(7, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

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
      int equipmentManufacturerCode = 1,
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
      int characterCount)
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
        false);
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
        SELECT legal.source_raw_value
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

  private static LocalAccountProfileWrite MaterializeImportProfile(
      LocalCurrentAccountProfile current,
      SanitizedProfileDraft draft,
      string authority,
      IReadOnlyList<string> scopes)
  {
    var method = typeof(PostgreSqlProfileManagementService).GetMethod(
        "MaterializeImportProfile",
        BindingFlags.NonPublic | BindingFlags.Static)!;
    return (LocalAccountProfileWrite)method.Invoke(
        null,
        [
          current,
          draft,
          authority,
          scopes,
          LocalProfileRevisionOrigin.OfflineSanitizedImport
        ])!;
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
                    ProfileImportFact<ProfileImportManufacturer>.Ready(
                        ProfileImportManufacturer.Elysion),
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
