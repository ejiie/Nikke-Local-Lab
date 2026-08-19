using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;
using CharacterDomain = NikkeLocalLab.Domain.Character;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlCharacterCatalogTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private const string RawCanary = "SYNTHETIC-RAW-CHARACTER-ID-MUST-NOT-LEAK";
  private const string PathCanary = "C:\\SYNTHETIC-PRIVATE-SOURCE\\catalog.mpk";
  private static readonly byte[] IdentitySecretA =
      Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();
  private static readonly byte[] IdentitySecretB =
      Enumerable.Range(33, 32).Select(value => (byte)value).ToArray();

  [Fact]
  public async Task CharacterCatalogPublicationIsAtomicVersionedPrivateAndKeyBound()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);

    var concurrentResults = await Task.WhenAll(
        Enumerable.Range(0, 4)
            .Select(_ => new PostgreSqlMigrationRunner().MigrateAsync(dataSource)));
    Assert.Equal(5, concurrentResults.Sum());
    Assert.Equal(0, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var uidGenerator = new RandomEntityUidGenerator();
    var store = new PostgreSqlCharacterCatalogImportStore(dataSource, uidGenerator);
    var bindingA = CharacterCatalogIdentityBinding.FromSecret(IdentitySecretA);
    var aliasA = SourceAliasFingerprintEncoder.Encode(
        IdentitySecretA,
        "synthetic.character",
        "character",
        $"{RawCanary}|{PathCanary}");
    var definitionV1 = CreateDefinition(
        aliasA,
        "synthetic-definition-v1",
        CharacterCombatClassCode.Attacker);

    var first = await store.RecordCompletedAndPublishAsync(
        CreateAttempt("synthetic-source-v1", "synthetic-output-v1"),
        new CharacterCatalogPublication(bindingA, [definitionV1]));
    var repeated = await store.RecordCompletedAndPublishAsync(
        CreateAttempt("synthetic-source-v1", "synthetic-output-v1"),
        new CharacterCatalogPublication(bindingA, [definitionV1]));

    Assert.Equal(ImportReceiptStatus.Succeeded, first.Import.Status);
    Assert.Equal(ImportReceiptStatus.Reused, repeated.Import.Status);
    Assert.Equal(first.CharacterCatalogSnapshotUid, repeated.CharacterCatalogSnapshotUid);
    Assert.Equal(first.CatalogManifestSha256, repeated.CatalogManifestSha256);
    Assert.Equal(first.Members, repeated.Members);
    Assert.Equal(first.Import.DatasetSnapshotUid, repeated.Import.DatasetSnapshotUid);
    var expectedManifest = CharacterDomain.CharacterCatalogManifest.Create(
        first.Import.DatasetSnapshotUid!.Value,
        [new CharacterDomain.CharacterCatalogManifestEntry(
            first.Members[0].CharacterUid,
            definitionV1.DefinitionContentSha256)]);
    Assert.Equal(expectedManifest.Sha256, first.CatalogManifestSha256);

    var renamedDefinition = definitionV1 with
    {
      DisplayName = new CharacterCatalogTextFact(
          CharacterCatalogFactStatus.Ready,
          "Renamed Synthetic Unit")
    };
    var renamed = await store.RecordCompletedAndPublishAsync(
        CreateAttempt("synthetic-source-name-change", "synthetic-output-name-change"),
        new CharacterCatalogPublication(bindingA, [renamedDefinition]));
    Assert.Equal(first.Members[0].CharacterUid, renamed.Members[0].CharacterUid);
    Assert.NotEqual(
        first.Members[0].CharacterDefinitionVersionUid,
        renamed.Members[0].CharacterDefinitionVersionUid);
    Assert.Equal(first.CatalogManifestSha256, renamed.CatalogManifestSha256);

    var definitionV2 = CreateDefinition(
        aliasA,
        "synthetic-definition-v2",
        CharacterCombatClassCode.Supporter,
        unresolvedCollection: true);
    var changed = await store.RecordCompletedAndPublishAsync(
        CreateAttempt("synthetic-source-v2", "synthetic-output-v2"),
        new CharacterCatalogPublication(bindingA, [definitionV2]));

    Assert.Equal(first.Members[0].CharacterUid, changed.Members[0].CharacterUid);
    Assert.NotEqual(
        first.Members[0].CharacterDefinitionVersionUid,
        changed.Members[0].CharacterDefinitionVersionUid);
    Assert.NotEqual(first.CharacterCatalogSnapshotUid, changed.CharacterCatalogSnapshotUid);

    var aliasB = SourceAliasFingerprintEncoder.Encode(
        IdentitySecretA,
        "synthetic.character",
        "character",
        "SYNTHETIC-SECOND-RAW-ID-MUST-NOT-LEAK");
    var sameNameDifferentAlias = CreateDefinition(
        aliasB,
        "synthetic-definition-v1",
        CharacterCombatClassCode.Attacker);
    var secondEntity = await store.RecordCompletedAndPublishAsync(
        CreateAttempt("synthetic-source-v3", "synthetic-output-v3"),
        new CharacterCatalogPublication(bindingA, [sameNameDifferentAlias]));
    Assert.NotEqual(first.Members[0].CharacterUid, secondEntity.Members[0].CharacterUid);

    await using var connection = await dataSource.OpenConnectionAsync();
    Assert.Equal(
        first.CatalogManifestSha256,
        await ReadCatalogManifestForSnapshotAsync(connection, first.CharacterCatalogSnapshotUid.Value));
    Assert.Equal(5L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run;"));
    Assert.Equal(2L, await ScalarInt64Async(connection, "SELECT count(*) FROM lab_catalog.character_entity;"));
    Assert.Equal(2L, await ScalarInt64Async(
        connection,
        """
        SELECT count(*) FROM lab_private.character_source_alias
        WHERE octet_length(alias_fingerprint) = 32;
        """));
    Assert.Equal(1L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_meta.character_identity_key_binding WHERE binding_id = 1;"));
    Assert.Equal(4L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_catalog.character_definition_version;"));
    Assert.Equal(40L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_catalog.character_definition_capability;"));
    Assert.Equal(16L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_catalog.character_definition_equipment_capability;"));
    Assert.Equal(4L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_catalog.character_catalog_snapshot;"));
    Assert.Equal(
        first.Members[0].CharacterDefinitionVersionUid.Value,
        await ReadVersionForSnapshotAsync(connection, first.CharacterCatalogSnapshotUid.Value));

    var runCountBeforeRejectedWrites = await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_import.import_run;");
    var keyMismatch = await Assert.ThrowsAsync<CharacterCatalogIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt("synthetic-source-key-mismatch", "synthetic-output-key-mismatch"),
            new CharacterCatalogPublication(
                CharacterCatalogIdentityBinding.FromSecret(IdentitySecretB),
                [definitionV1])));
    Assert.Equal("identity_key_mismatch", keyMismatch.Code);
    Assert.Equal(
        runCountBeforeRejectedWrites,
        await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var wrongContentHash = definitionV2 with
    {
      CombatClass = new CharacterCatalogValueFact<CharacterCombatClassCode>(
          CharacterCatalogFactStatus.Ready,
          CharacterCombatClassCode.Defender)
    };
    var contentHashMismatch = await Assert.ThrowsAsync<CharacterCatalogIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt("synthetic-source-collision", "synthetic-output-collision"),
            new CharacterCatalogPublication(bindingA, [wrongContentHash])));
    Assert.Equal("definition_content_hash_mismatch", contentHashMismatch.Code);
    Assert.Equal(
        runCountBeforeRejectedWrites,
        await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run;"));
    Assert.Equal(4L, await ScalarInt64Async(
        connection,
        "SELECT count(*) FROM lab_import.source_artifact;"));

    var errorAttempt = CreateAttempt(
        "synthetic-source-error",
        "synthetic-output-error",
        new SafeDiagnostic(
            ImportDiagnosticSeverity.Error,
            "extract",
            "synthetic_parse_failed"));
    var errorDiagnostic = await Assert.ThrowsAsync<CharacterCatalogIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            errorAttempt,
            new CharacterCatalogPublication(bindingA, [definitionV1])));
    Assert.Equal("catalog_error_diagnostic", errorDiagnostic.Code);
    Assert.Equal(
        runCountBeforeRejectedWrites,
        await ScalarInt64Async(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var immutableStatements = new[]
    {
      "UPDATE lab_meta.character_identity_key_binding SET encoder_version = encoder_version;",
      "UPDATE lab_catalog.character_entity SET character_uid = character_uid;",
      "UPDATE lab_private.character_source_alias SET character_entity_id = character_entity_id;",
      "UPDATE lab_catalog.character_definition_version SET readiness_status = readiness_status;",
      "UPDATE lab_catalog.character_definition_capability SET maximum_level = maximum_level;",
      "UPDATE lab_catalog.character_definition_equipment_capability SET maximum_tier = maximum_tier;",
      "UPDATE lab_catalog.character_catalog_snapshot SET output_manifest_sha256 = output_manifest_sha256;",
      "UPDATE lab_catalog.character_catalog_snapshot_member SET ordinal = ordinal;"
    };
    foreach (var statement in immutableStatements)
    {
      var immutable = await Assert.ThrowsAsync<PostgresException>(async () =>
      {
        await using var command = new NpgsqlCommand(statement, connection);
        await command.ExecuteNonQueryAsync();
      });
      Assert.Equal("P0001", immutable.SqlState);
      Assert.Contains("immutable_catalog_row", immutable.MessageText, StringComparison.Ordinal);
    }

    await AssertLeakSafeSchemaAsync(connection);
    var storedText = await ReadStoredCatalogTextAsync(connection);
    var publicJson = JsonSerializer.Serialize(new { first, repeated, renamed, changed, secondEntity });
    foreach (var projection in new[] { storedText, publicJson })
    {
      Assert.DoesNotContain(RawCanary, projection, StringComparison.Ordinal);
      Assert.DoesNotContain("SYNTHETIC-SECOND-RAW-ID-MUST-NOT-LEAK", projection, StringComparison.Ordinal);
      Assert.DoesNotContain(PathCanary, projection, StringComparison.OrdinalIgnoreCase);
      Assert.DoesNotContain(aliasA.Hex, projection, StringComparison.OrdinalIgnoreCase);
    }
  }

  private static CharacterCatalogDefinition CreateDefinition(
      SourceAliasFingerprint fingerprint,
      string _,
      CharacterCombatClassCode combatClass,
      bool unresolvedCollection = false)
  {
    var capabilities = new List<CharacterCatalogCapability>();
    foreach (var code in Enum.GetValues<CharacterCapabilityCode>())
    {
      if (code == CharacterCapabilityCode.FavoriteItem)
      {
        capabilities.Add(new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.NotApplicable));
      }
      else if (code == CharacterCapabilityCode.CollectionItem && unresolvedCollection)
      {
        capabilities.Add(new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.Unresolved,
            unresolvedReasonCode: "reference_missing"));
      }
      else
      {
        var maximum = code switch
        {
          CharacterCapabilityCode.CharacterLevel => 400,
          CharacterCapabilityCode.LimitBreak => 3,
          CharacterCapabilityCode.CoreLevel => 7,
          CharacterCapabilityCode.BondLevel => 40,
          CharacterCapabilityCode.Cube => 15,
          CharacterCapabilityCode.Skill1 => 10,
          CharacterCapabilityCode.Skill2 => 10,
          CharacterCapabilityCode.Burst => 10,
          CharacterCapabilityCode.CollectionItem => 15,
          _ => throw new InvalidOperationException("The synthetic capability is not mapped.")
        };
        capabilities.Add(new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.Ready,
            maximumLevel: maximum));
      }
    }

    var equipment = Enum.GetValues<CharacterEquipmentSlot>()
        .Select(slot => new CharacterCatalogEquipmentCapability(
            slot,
            new CharacterCatalogValueFact<EntityUid>(
                CharacterCatalogFactStatus.Ready,
                SyntheticEquipmentUid(slot)),
            new CharacterCatalogValueFact<int>(CharacterCatalogFactStatus.Ready, 10),
            new CharacterCatalogValueFact<int>(CharacterCatalogFactStatus.Ready, 5),
            new CharacterCatalogValueFact<bool>(CharacterCatalogFactStatus.Ready, true)))
        .ToArray();

    return new CharacterCatalogDefinition(
        fingerprint,
        ComputeSyntheticContentHash(combatClass, unresolvedCollection),
        new CharacterCatalogTextFact(CharacterCatalogFactStatus.Ready, "Synthetic Unit"),
        new CharacterCatalogValueFact<CharacterRarityCode>(
            CharacterCatalogFactStatus.Ready,
            CharacterRarityCode.Ssr),
        new CharacterCatalogValueFact<CharacterCombatClassCode>(
            CharacterCatalogFactStatus.Ready,
            combatClass),
        new CharacterCatalogValueFact<CharacterWeaponCode>(
            CharacterCatalogFactStatus.Ready,
            CharacterWeaponCode.AssaultRifle),
        new CharacterCatalogValueFact<CharacterElementCode>(
            CharacterCatalogFactStatus.Ready,
            CharacterElementCode.Electric),
        new CharacterCatalogValueFact<CharacterManufacturerCode>(
            CharacterCatalogFactStatus.Ready,
            CharacterManufacturerCode.Elysion),
        capabilities,
        equipment);
  }

  private static Sha256Digest ComputeSyntheticContentHash(
      CharacterCombatClassCode combatClass,
      bool unresolvedCollection)
  {
    var equipment = Enum.GetValues<CharacterDomain.EquipmentSlot>()
        .Select(slot => new CharacterDomain.EquipmentSlotCapability(
            slot,
            CharacterDomain.NormalizedFact<EntityUid>.Ready(SyntheticEquipmentUid(slot)),
            CharacterDomain.NormalizedFact<int>.Ready(10),
            CharacterDomain.NormalizedFact<int>.Ready(5),
            CharacterDomain.NormalizedFact<bool>.Ready(true)))
        .ToArray();
    var content = new CharacterDomain.CharacterDefinitionContent(
        new CharacterDomain.CharacterProfile(
            CharacterDomain.NormalizedFact<CharacterDomain.CharacterRarity>.Ready(
                CharacterDomain.CharacterRarity.SSR),
            CharacterDomain.NormalizedFact<CharacterDomain.CombatRole>.Ready(combatClass switch
            {
              CharacterCombatClassCode.Attacker => CharacterDomain.CombatRole.Attacker,
              CharacterCombatClassCode.Defender => CharacterDomain.CombatRole.Defender,
              CharacterCombatClassCode.Supporter => CharacterDomain.CombatRole.Supporter,
              _ => throw new InvalidOperationException("The synthetic class is not mapped.")
            }),
            CharacterDomain.NormalizedFact<CharacterDomain.WeaponClass>.Ready(
                CharacterDomain.WeaponClass.AssaultRifle),
            CharacterDomain.NormalizedFact<CharacterDomain.NikkeElement>.Ready(
                CharacterDomain.NikkeElement.Electric),
            CharacterDomain.NormalizedFact<CharacterDomain.Manufacturer>.Ready(
                CharacterDomain.Manufacturer.Elysion)),
        new CharacterDomain.CharacterCapabilities(
            CharacterDomain.NormalizedFact<int>.Ready(400),
            CharacterDomain.NormalizedFact<int>.Ready(3),
            CharacterDomain.NormalizedFact<int>.Ready(7),
            CharacterDomain.NormalizedFact<int>.Ready(40),
            equipment,
            new CharacterDomain.SkillMaximums(
                CharacterDomain.NormalizedFact<int>.Ready(10),
                CharacterDomain.NormalizedFact<int>.Ready(10),
                CharacterDomain.NormalizedFact<int>.Ready(10)),
            CharacterDomain.NormalizedFact<int>.Ready(15),
            unresolvedCollection
                ? CharacterDomain.NormalizedFact<int>.Unresolved("reference_missing")
                : CharacterDomain.NormalizedFact<int>.Ready(15),
            CharacterDomain.NormalizedFact<int>.NotApplicable()));
    return CharacterDomain.CharacterDefinitionCanonicalizer.ComputeContentHash(content);
  }

  private static EntityUid SyntheticEquipmentUid(CharacterEquipmentSlot slot) => slot switch
  {
    CharacterEquipmentSlot.Head => new EntityUid(Guid.Parse("10000000-0000-4000-8000-000000000001")),
    CharacterEquipmentSlot.Torso => new EntityUid(Guid.Parse("10000000-0000-4000-8000-000000000002")),
    CharacterEquipmentSlot.Arms => new EntityUid(Guid.Parse("10000000-0000-4000-8000-000000000003")),
    CharacterEquipmentSlot.Legs => new EntityUid(Guid.Parse("10000000-0000-4000-8000-000000000004")),
    _ => throw new InvalidOperationException("The synthetic equipment slot is not mapped.")
  };

  private static EntityUid SyntheticEquipmentUid(CharacterDomain.EquipmentSlot slot) => slot switch
  {
    CharacterDomain.EquipmentSlot.Head => SyntheticEquipmentUid(CharacterEquipmentSlot.Head),
    CharacterDomain.EquipmentSlot.Torso => SyntheticEquipmentUid(CharacterEquipmentSlot.Torso),
    CharacterDomain.EquipmentSlot.Arms => SyntheticEquipmentUid(CharacterEquipmentSlot.Arms),
    CharacterDomain.EquipmentSlot.Legs => SyntheticEquipmentUid(CharacterEquipmentSlot.Legs),
    _ => throw new InvalidOperationException("The synthetic equipment slot is not mapped.")
  };

  private static CompletedImportAttempt CreateAttempt(
      string sourceContent,
      string outputContent,
      params SafeDiagnostic[] diagnostics)
  {
    var observation = new SourceArtifactObservation(
        "synthetic_catalog",
        Sha256Digest.ComputeUtf8(sourceContent),
        sourceContent.Length);
    var manifest = CanonicalDatasetManifest.Create(
    [
      new DatasetArtifactInput("catalog", observation)
    ]);
    var extractor = new ExtractorDescriptor(
        "synthetic_character_catalog",
        "v1",
        Sha256Digest.ComputeUtf8("nll/synthetic-character-catalog-contract/v1"));
    var request = ImportRequestFingerprint.Create(
        manifest.CanonicalSha256,
        extractor.FingerprintSha256,
        SemanticOptionsFingerprint.Empty);
    var now = DateTimeOffset.UtcNow;
    return new CompletedImportAttempt(
        EntityUid.New(),
        EntityUid.New(),
        [new ArtifactRegistration(EntityUid.New(), manifest.Artifacts[0])],
        manifest,
        extractor,
        SemanticOptionsFingerprint.Empty,
        request,
        Sha256Digest.ComputeUtf8(outputContent),
        diagnostics,
        now,
        now.AddMilliseconds(1));
  }

  private static NpgsqlDataSource CreateDataSource()
  {
    var connectionString = Environment.GetEnvironmentVariable("NIKKE_LAB_TEST_DB")
        ?? throw new InvalidOperationException(
            "NIKKE_LAB_TEST_DB is required for PostgreSQL integration tests.");
    var validated = PostgreSqlConnectionPolicy.Validate(connectionString);
    var builder = new NpgsqlConnectionStringBuilder(validated);
    Assert.Equal("nikke_local_lab_test", builder.Database);
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

  private static async Task AssertLeakSafeSchemaAsync(NpgsqlConnection connection)
  {
    var forbiddenColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
      "source_path",
      "file_name",
      "raw_id",
      "raw_source_identifier",
      "source_identifier",
      "payload",
      "json",
      "message",
      "details",
      "exception_message",
      "stack_trace"
    };
    await using (var command = new NpgsqlCommand(
                     """
                     SELECT column_name, data_type
                     FROM information_schema.columns
                     WHERE table_schema IN ('lab_catalog', 'lab_private');
                     """,
                     connection))
    await using (var reader = await command.ExecuteReaderAsync())
    {
      while (await reader.ReadAsync())
      {
        Assert.DoesNotContain(reader.GetString(0), forbiddenColumns);
        Assert.DoesNotContain(reader.GetString(1), new[] { "json", "jsonb" });
      }
    }

    await using var privilege = new NpgsqlCommand(
        """
        SELECT count(*)
        FROM information_schema.role_table_grants
        WHERE grantee = 'PUBLIC'
          AND table_schema = 'lab_private'
          AND table_name = 'character_source_alias';
        """,
        connection);
    Assert.Equal(
        0L,
        Convert.ToInt64(
            await privilege.ExecuteScalarAsync(),
            System.Globalization.CultureInfo.InvariantCulture));
  }

  private static async Task<Guid> ReadVersionForSnapshotAsync(
      NpgsqlConnection connection,
      Guid snapshotUid)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT version.character_definition_version_uid
        FROM lab_catalog.character_catalog_snapshot AS snapshot
        JOIN lab_catalog.character_catalog_snapshot_member AS member
          ON member.character_catalog_snapshot_id = snapshot.character_catalog_snapshot_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id = member.character_definition_version_id
        WHERE snapshot.character_catalog_snapshot_uid = $1;
        """,
        connection);
    command.Parameters.AddWithValue(snapshotUid);
    return (Guid)(await command.ExecuteScalarAsync()
        ?? throw new InvalidOperationException("The synthetic snapshot member was not found."));
  }

  private static async Task<Sha256Digest> ReadCatalogManifestForSnapshotAsync(
      NpgsqlConnection connection,
      Guid snapshotUid)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT catalog_manifest_sha256
        FROM lab_catalog.character_catalog_snapshot
        WHERE character_catalog_snapshot_uid = $1;
        """,
        connection);
    command.Parameters.AddWithValue(snapshotUid);
    return Sha256Digest.FromBytes((byte[])(await command.ExecuteScalarAsync()
        ?? throw new InvalidOperationException("The synthetic catalog manifest was not found.")));
  }

  private static async Task<string> ReadStoredCatalogTextAsync(NpgsqlConnection connection)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT string_agg(value, E'\n')
        FROM (
            SELECT display_name AS value FROM lab_catalog.character_definition_version
            UNION ALL SELECT rarity_code FROM lab_catalog.character_definition_version
            UNION ALL SELECT combat_class_code FROM lab_catalog.character_definition_version
            UNION ALL SELECT weapon_code FROM lab_catalog.character_definition_version
            UNION ALL SELECT element_code FROM lab_catalog.character_definition_version
            UNION ALL SELECT manufacturer_code FROM lab_catalog.character_definition_version
            UNION ALL SELECT capability_code FROM lab_catalog.character_definition_capability
            UNION ALL SELECT resolution_status FROM lab_catalog.character_definition_capability
            UNION ALL SELECT equipment_slot
              FROM lab_catalog.character_definition_equipment_capability
            UNION ALL SELECT equipment_definition_status
              FROM lab_catalog.character_definition_equipment_capability
            UNION ALL SELECT manufacturer_match_status
              FROM lab_catalog.character_definition_equipment_capability
        ) AS stored_text;
        """,
        connection);
    return (string?)await command.ExecuteScalarAsync() ?? string.Empty;
  }

  private static async Task<long> ScalarInt64Async(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    var value = await command.ExecuteScalarAsync();
    return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture);
  }
}
