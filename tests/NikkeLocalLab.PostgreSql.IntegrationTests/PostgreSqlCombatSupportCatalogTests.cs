using System.Text.Json;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;
using Npgsql;
using CombatSupportDomain = NikkeLocalLab.Domain.CombatSupport;

namespace NikkeLocalLab.PostgreSql.IntegrationTests;

public sealed class PostgreSqlCombatSupportCatalogTests
{
  private const string ResetToken = "allow-phase1a-disposable-schema-reset";
  private const string RawCanary = "SYNTHETIC-RAW-SUPPORT-ID-MUST-NOT-LEAK";
  private const string PathCanary = "C:\\SYNTHETIC-PRIVATE-SOURCE\\combat-support.mpk";
  private static readonly byte[] IdentitySecret =
      Enumerable.Range(1, 32).Select(static value => (byte)value).ToArray();
  private static readonly byte[] OtherIdentitySecret =
      Enumerable.Range(65, 32).Select(static value => (byte)value).ToArray();

  [Fact]
  public async Task CatalogPublicationIsAtomicDomainCanonicalSealedAndSourceFree()
  {
    await using var dataSource = CreateDataSource();
    await ResetSchemasAsync(dataSource);
    var migrationReceipts = await Task.WhenAll(
        Enumerable.Range(0, 4)
            .Select(_ => new PostgreSqlMigrationRunner().MigrateAsync(dataSource)));
    Assert.Equal(7, migrationReceipts.Sum());
    Assert.Equal(0, await new PostgreSqlMigrationRunner().MigrateAsync(dataSource));

    var characterAlias = Alias("character", "favorite-owner");
    await SeedCharacterAliasAsync(dataSource, characterAlias);
    var binding = CombatSupportCatalogIdentityBinding.FromSecret(IdentitySecret);
    var publication = CreatePublication(binding, characterAlias);
    var store = new PostgreSqlCombatSupportCatalogImportStore(
        dataSource,
        new RandomEntityUidGenerator());

    var receipts = await Task.WhenAll(
        Enumerable.Range(0, 4).Select(index => store.RecordCompletedAndPublishAsync(
            CreateAttempt(publication, $"run-{index}"),
            publication)));
    Assert.Equal(1, receipts.Count(static item => item.Import.Status == ImportReceiptStatus.Succeeded));
    Assert.Equal(3, receipts.Count(static item => item.Import.Status == ImportReceiptStatus.Reused));
    Assert.Single(receipts.Select(static item => item.CombatSupportCatalogSnapshotUid).Distinct());
    Assert.Single(receipts.Select(static item => item.CatalogManifestSha256).Distinct());
    Assert.All(receipts, item => Assert.Equal(receipts[0].Members, item.Members));

    var first = receipts[0];
    var expectedManifest = CombatSupportDomain.CombatSupportCatalogManifest.Create(
        first.Import.DatasetSnapshotUid!.Value,
        first.Members.Select(static member =>
            new CombatSupportDomain.CombatSupportCatalogManifestEntry(
                ToDomainKind(member.Kind),
                member.DefinitionUid,
                member.DefinitionContentSha256,
                member.IsProfileSelectable,
                member.HasCompleteCombatSemantics)));
    Assert.Equal(expectedManifest.Sha256, first.CatalogManifestSha256);

    var overloadMembers = first.Members
        .Where(static item => item.Kind == CombatSupportDefinitionKind.OverloadOption)
        .ToArray();
    Assert.Equal(9, overloadMembers.Length);
    Assert.All(overloadMembers, static member =>
    {
      Assert.True(member.IsSourceReady);
      Assert.True(member.IsProfileSelectable);
      Assert.True(member.IsGameLegalReady);
      Assert.False(member.HasCompleteCombatSemantics);
      Assert.False(member.IsDuplicatePolicyReady);
    });
    Assert.All(
        first.Members.Where(static item => item.Kind is
            CombatSupportDefinitionKind.Cube or
            CombatSupportDefinitionKind.Collection or
            CombatSupportDefinitionKind.Favorite),
        static member =>
        {
          Assert.True(member.IsSourceReady);
          Assert.True(member.IsProfileSelectable);
          Assert.False(member.IsGameLegalReady);
          Assert.False(member.HasCompleteCombatSemantics);
        });

    await using var connection = await dataSource.OpenConnectionAsync();
    Assert.Equal(24L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.equipment_definition_detail;"));
    Assert.Equal(5_220L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.console_legal_level;"));
    Assert.Equal(135L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.overload_legal_value;"));
    Assert.Equal(135L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private.overload_legal_value_source_alias;"));
    Assert.Equal(30L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.overload_legal_value WHERE source_raw_value < 0;"));
    Assert.Equal(4L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.catalog_import_projection;"));

    var semanticV2 = CreatePublication(
        binding,
        characterAlias,
        overloadMagnitudeOffset: 1_000,
        consoleMaximumLevel: 680);
    var semanticV2Receipt = await store.RecordCompletedAndPublishAsync(
        CreateAttempt(semanticV2, "semantic-v2", sourceVersion: "semantic-v2"),
        semanticV2);
    Assert.Equal(ImportReceiptStatus.Succeeded, semanticV2Receipt.Import.Status);
    Assert.NotEqual(first.CombatSupportCatalogSnapshotUid, semanticV2Receipt.CombatSupportCatalogSnapshotUid);
    Assert.Equal(
        first.Members.Select(static member => member.DefinitionUid).OrderBy(static uid => uid.Value).ToArray(),
        semanticV2Receipt.Members.Select(static member => member.DefinitionUid)
            .OrderBy(static uid => uid.Value).ToArray());
    var firstMembersByUid = first.Members.ToDictionary(static member => member.DefinitionUid);
    Assert.All(
        semanticV2Receipt.Members.Where(static member =>
            member.Kind == CombatSupportDefinitionKind.OverloadOption),
        member =>
        {
          Assert.NotEqual(firstMembersByUid[member.DefinitionUid].DefinitionVersionUid, member.DefinitionVersionUid);
          Assert.NotEqual(firstMembersByUid[member.DefinitionUid].DefinitionContentSha256, member.DefinitionContentSha256);
        });
    Assert.Equal(270L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_private.overload_legal_value_source_alias;"));
    Assert.Equal(135L, await ScalarAsync(
        connection,
        """
        SELECT count(*)
        FROM (
            SELECT alias_fingerprint
            FROM lab_private.overload_legal_value_source_alias
            GROUP BY alias_fingerprint
            HAVING count(*) = 2
        ) AS versioned_alias;
        """));
    Assert.Equal(11_340L, await ScalarAsync(
        connection,
        "SELECT count(*) FROM lab_combat_support.console_legal_level;"));

    var runCount = await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;");
    var wrongRole = await Assert.ThrowsAsync<CombatSupportCatalogIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(publication, "wrong-role", roleCode: "catalog"),
            publication));
    Assert.Equal("support_staticdata_artifact_invalid", wrongRole.Code);
    Assert.Equal(runCount, await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var wrongKeyPublication = CreatePublication(
        CombatSupportCatalogIdentityBinding.FromSecret(OtherIdentitySecret),
        characterAlias,
        OtherIdentitySecret);
    var wrongKey = await Assert.ThrowsAsync<CombatSupportCatalogIntegrityException>(() =>
        store.RecordCompletedAndPublishAsync(
            CreateAttempt(wrongKeyPublication, "wrong-key", sourceVersion: "wrong-key"),
            wrongKeyPublication));
    Assert.Equal("support_identity_key_mismatch", wrongKey.Code);
    Assert.Equal(runCount, await ScalarAsync(connection, "SELECT count(*) FROM lab_import.import_run;"));

    var immutableStatements = new[]
    {
      "UPDATE lab_combat_support.definition_entity SET definition_uid = definition_uid;",
      "UPDATE lab_combat_support.definition_version SET source_readiness_status = source_readiness_status;",
      "UPDATE lab_combat_support.definition_level_coordinate SET level = level;",
      "UPDATE lab_combat_support.overload_legal_value SET source_raw_value = source_raw_value;",
      "UPDATE lab_private.overload_legal_value_source_alias SET roll_level = roll_level;",
      "UPDATE lab_combat_support.catalog_snapshot_member SET ordinal = ordinal;"
    };
    foreach (var statement in immutableStatements)
    {
      var immutable = await Assert.ThrowsAsync<PostgresException>(async () =>
      {
        await using var command = new NpgsqlCommand(statement, connection);
        await command.ExecuteNonQueryAsync();
      });
      Assert.Equal("P0001", immutable.SqlState);
      Assert.Contains("immutable_combat_support_row", immutable.MessageText, StringComparison.Ordinal);
    }

    var sealedInsert = await Assert.ThrowsAsync<PostgresException>(async () =>
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_combat_support.definition_stat_contribution
              (definition_version_id, ordinal, unlock_level,
               stat_status, stat_code, unit_status, unit_code,
               exact_unscaled_value, exact_decimal_scale)
          SELECT definition_version_id, 999999, 0,
                 'ready', 'attack', 'ready', 'absolute', 1, 0
          FROM lab_combat_support.definition_version
          LIMIT 1;
          """,
          connection);
      await command.ExecuteNonQueryAsync();
    });
    Assert.Equal("P0001", sealedInsert.SqlState);
    Assert.Contains("immutable_combat_support_row", sealedInsert.MessageText, StringComparison.Ordinal);

    await AssertLeakSafeSchemaAsync(connection);
    var publicJson = JsonSerializer.Serialize(receipts);
    Assert.DoesNotContain(RawCanary, publicJson, StringComparison.Ordinal);
    Assert.DoesNotContain(PathCanary, publicJson, StringComparison.OrdinalIgnoreCase);
    foreach (var alias in AllAliases(publication))
    {
      Assert.DoesNotContain(alias.Hex, publicJson, StringComparison.OrdinalIgnoreCase);
    }
  }

  [Fact]
  public void PublicationRejectsLowerTierAndDuplicateEquipmentCoordinate()
  {
    var lowerTier = Assert.Throws<CombatSupportCatalogIntegrityException>(() =>
        CreateEquipment(
            CombatSupportCombatClass.Attacker,
            CombatSupportEquipmentSlot.Head,
            8,
            Alias("equipment", "lower-tier")));
    Assert.Equal("support_equipment_scope_unsupported", lowerTier.Code);

    var characterAlias = Alias("character", "grid-owner");
    var binding = CombatSupportCatalogIdentityBinding.FromSecret(IdentitySecret);
    var valid = CreatePublication(binding, characterAlias);
    var definitions = valid.Definitions.ToList();
    var firstEquipment = definitions.First(static item =>
        item.Kind == CombatSupportDefinitionKind.Equipment);
    var lastEquipmentIndex = definitions.FindLastIndex(static item =>
        item.Kind == CombatSupportDefinitionKind.Equipment);
    definitions[lastEquipmentIndex] = new CombatSupportDefinitionPublication(
        Alias("equipment", "duplicate-coordinate-with-distinct-alias"),
        UnresolvedName(),
        firstEquipment.Payload,
        firstEquipment.Contributions);
    var duplicate = Assert.Throws<CombatSupportCatalogIntegrityException>(() =>
        new CombatSupportCatalogPublication(binding, definitions));
    Assert.Equal("support_equipment_subset_invalid", duplicate.Code);

  }

  [Fact]
  public void PublicationStatContractMatchesAllDomainStatKinds()
  {
    var persistenceKinds = Enum.GetValues<CombatSupportStat>();
    var domainKinds = Enum.GetValues<CombatSupportDomain.CombatSupportStat>();
    Assert.Equal(
        domainKinds.Select(static value => value.ToString()),
        persistenceKinds.Select(static value => value.ToString()));
    Assert.All(persistenceKinds, stat =>
    {
      var contribution = Contribution(0, 0, stat, 1);
      Assert.Equal(stat, contribution.Stat.Value);
      Assert.Equal(CombatSupportFactStatus.Ready, contribution.Stat.Status);
      Assert.Equal(CombatSupportFactStatus.Ready, contribution.Unit.Status);
    });
  }

  private static CombatSupportCatalogPublication CreatePublication(
      CombatSupportCatalogIdentityBinding binding,
      SourceAliasFingerprint characterAlias,
      byte[]? secret = null,
      int overloadMagnitudeOffset = 0,
      int consoleMaximumLevel = 580)
  {
    var key = secret ?? IdentitySecret;
    var definitions = new List<CombatSupportDefinitionPublication>();
    foreach (var combatClass in Enum.GetValues<CombatSupportCombatClass>())
      foreach (var slot in Enum.GetValues<CombatSupportEquipmentSlot>())
        foreach (var tier in new[] { 9, 10 })
        {
          definitions.Add(CreateEquipment(
              combatClass,
              slot,
              tier,
              Alias(key, "equipment", $"{combatClass}-{slot}-{tier}")));
        }

    definitions.Add(CreateCube(Alias(key, "cube", "cube-0")));
    definitions.Add(CreateCollection(Alias(key, "collection", "collection-0")));
    definitions.Add(CreateFavorite(Alias(key, "favorite", "favorite-0"), characterAlias));
    foreach (var coordinate in Enum.GetValues<CombatSupportConsoleCoordinate>())
    {
      definitions.Add(CreateConsole(
          coordinate,
          Alias(key, "console", coordinate.ToString()),
          consoleMaximumLevel));
    }

    foreach (var optionType in Enum.GetValues<CombatSupportOverloadOptionType>())
    {
      definitions.Add(CreateOverload(
          optionType,
          Alias(key, "overload", optionType.ToString()),
          key,
          overloadMagnitudeOffset));
    }

    return new CombatSupportCatalogPublication(binding, definitions);
  }

  private static CombatSupportDefinitionPublication CreateEquipment(
      CombatSupportCombatClass combatClass,
      CombatSupportEquipmentSlot slot,
      int tier,
      SourceAliasFingerprint alias)
  {
    var slots = tier == 9
        ? new[] { Exact(0, 0), Exact(0, 0), Exact(0, 0) }
        : new[] { Exact(1, 0), Exact(5, 1), Exact(3, 1) };
    var payload = new CombatSupportEquipmentDefinitionPublication(
        slot,
        Ready(combatClass),
        NotApplicable<CombatSupportManufacturer>(),
        Ready(tier),
        Ready(0),
        Ready(5),
        Ready(tier == 10),
        slots.Select((value, ordinal) =>
            new CombatSupportEquipmentOptionSlotPublication(ordinal, value)));
    return Definition(
        alias,
        payload,
        ReadyContributions(
        [
          Contribution(0, 0, CombatSupportStat.Attack, 100),
          Contribution(1, 0, CombatSupportStat.Defence, 50)
        ]));
  }

  private static CombatSupportDefinitionPublication CreateCube(SourceAliasFingerprint alias)
  {
    var levels = Enumerable.Range(1, 15)
        .Select(level => new CombatSupportLevelCoordinatePublication(
            level,
            NotApplicable<int>(),
            Ready(level),
            NotApplicable<int>()))
        .ToArray();
    var contributions = Enumerable.Range(1, 15)
        .Select((level, ordinal) => Contribution(
            ordinal,
            level,
            CombatSupportStat.Attack,
            level))
        .ToArray();
    var skills = Enumerable.Range(1, 15)
        .SelectMany(level => Enumerable.Range(0, 3)
            .Select(slot => new { Level = level, Slot = slot }))
        .Select((item, ordinal) => new CombatSupportSkillCoordinatePublication(
            ordinal,
            item.Level,
            item.Slot,
            Math.Min(item.Level, 10)))
        .ToArray();
    return Definition(
        alias,
        new CombatSupportCubeDefinitionPublication(
            Ready(CombatSupportRarity.Ssr),
            NotApplicable<CombatSupportCombatClass>(),
            Ready(15),
            levels,
            Unresolved<bool>("skill_semantics_unresolved")),
        ReadyContributions(contributions, skills));
  }

  private static CombatSupportDefinitionPublication CreateCollection(SourceAliasFingerprint alias)
  {
    var levels = Enumerable.Range(0, 16)
        .Select(level => new CombatSupportLevelCoordinatePublication(
            level,
            Ready(level / 5),
            NotApplicable<int>(),
            NotApplicable<int>()))
        .ToArray();
    return Definition(
        alias,
        new CombatSupportCollectionDefinitionPublication(
            Ready(CombatSupportWeaponClass.AssaultRifle),
            Ready(CombatSupportRarity.R),
            Ready(15),
            levels,
            Unresolved<bool>("skill_semantics_unresolved")),
        ReadyContributions(
            levels.Select((level, ordinal) => Contribution(
                ordinal,
                level.Level,
                CombatSupportStat.Hp,
                level.Level)),
            CreateCollectionSkills(levels)));
  }

  private static CombatSupportDefinitionPublication CreateFavorite(
      SourceAliasFingerprint alias,
      SourceAliasFingerprint characterAlias)
  {
    var levels = Enumerable.Range(0, 3)
        .Select(level => new CombatSupportLevelCoordinatePublication(
            level,
            Ready(level),
            NotApplicable<int>(),
            NotApplicable<int>()))
        .ToArray();
    return Definition(
        alias,
        new CombatSupportFavoriteDefinitionPublication(
            Ready(2),
            Ready(characterAlias),
            Ready(CombatSupportRarity.Ssr),
            levels,
            Unresolved<bool>("skill_semantics_unresolved")),
        ReadyContributions(
            levels.Select((level, ordinal) => Contribution(
                ordinal,
                level.Level,
                CombatSupportStat.Attack,
                level.Level)),
            CreateCollectionSkills(levels)));
  }

  private static IEnumerable<CombatSupportSkillCoordinatePublication> CreateCollectionSkills(
      IReadOnlyList<CombatSupportLevelCoordinatePublication> levels) => levels
      .SelectMany(level => Enumerable.Range(0, 2)
          .Select(slot => new { level.Level, Slot = slot }))
      .Select((item, ordinal) => new CombatSupportSkillCoordinatePublication(
          ordinal,
          item.Level,
          item.Slot,
          Math.Min(item.Level, 10)));

  private static CombatSupportDefinitionPublication CreateConsole(
      CombatSupportConsoleCoordinate coordinate,
      SourceAliasFingerprint alias,
      int maximumLevel)
  {
    var coefficients = coordinate switch
    {
      CombatSupportConsoleCoordinate.Common => new[] { 0L, 0L, 450L },
      CombatSupportConsoleCoordinate.Attacker or
      CombatSupportConsoleCoordinate.Defender or
      CombatSupportConsoleCoordinate.Supporter => new[] { 0L, 5L, 750L },
      _ => new[] { 25L, 5L, 0L }
    };
    return Definition(
        alias,
        new CombatSupportConsoleDefinitionPublication(
            coordinate,
            Ready(maximumLevel),
            Enumerable.Range(1, maximumLevel).Select((level, ordinal) =>
                new CombatSupportConsoleLevelPublication(ordinal, level, 0))),
        ReadyContributions(
        [
          Contribution(0, 0, CombatSupportStat.Attack, coefficients[0]),
          Contribution(1, 0, CombatSupportStat.Defence, coefficients[1]),
          Contribution(2, 0, CombatSupportStat.Hp, coefficients[2])
        ]));
  }

  private static CombatSupportDefinitionPublication CreateOverload(
      CombatSupportOverloadOptionType optionType,
      SourceAliasFingerprint alias,
      byte[] secret,
      int magnitudeOffset)
  {
    var negative = optionType is CombatSupportOverloadOptionType.ChargeSpeed or
        CombatSupportOverloadOptionType.HitRate;
    var bands = Enumerable.Range(0, 3).Select(band =>
    {
      var probability = band switch
      {
        0 => Exact(6000, 4),
        1 => Exact(3500, 4),
        _ => Exact(500, 4)
      };
      var values = Enumerable.Range((band * 5) + 1, 5).Select(rollLevel =>
      {
        var magnitude = 100 + rollLevel + magnitudeOffset;
        return new CombatSupportOverloadLegalValuePublication(
            Alias(secret, "overload-value", $"{optionType}-{rollLevel}"),
            rollLevel,
            negative ? -magnitude : magnitude,
            magnitude,
            Exact(magnitude, 4));
      });
      return new CombatSupportOverloadLegalBandPublication(band, probability, values);
    });
    return Definition(
        alias,
        new CombatSupportOverloadOptionDefinitionPublication(
            Ready(optionType),
            Ready(CombatSupportValueUnit.Ratio),
            optionType is
                CombatSupportOverloadOptionType.Attack or
                CombatSupportOverloadOptionType.Defence or
                CombatSupportOverloadOptionType.CriticalDamage or
                CombatSupportOverloadOptionType.ElementalDamage
                ? Exact(10, 2)
                : Exact(12, 2),
            bands,
            Unresolved<CombatSupportOverloadDuplicatePolicy>("duplicate_policy_unresolved")),
        new CombatSupportContributionSetPublication(CombatSupportFactStatus.NotApplicable));
  }

  private static CombatSupportDefinitionPublication Definition(
      SourceAliasFingerprint alias,
      ICombatSupportDefinitionPayload payload,
      CombatSupportContributionSetPublication contributions) => new(
      alias,
      UnresolvedName(),
      payload,
      contributions);

  private static CombatSupportTextFact UnresolvedName() => new(
      CombatSupportFactStatus.Unresolved,
      unresolvedReasonCode: "locale_not_imported");

  private static CombatSupportContributionSetPublication ReadyContributions(
      IEnumerable<CombatSupportStatContributionPublication> contributions,
      IEnumerable<CombatSupportSkillCoordinatePublication>? skills = null) => new(
      CombatSupportFactStatus.Ready,
      contributions,
      skills);

  private static CombatSupportStatContributionPublication Contribution(
      int ordinal,
      int unlockLevel,
      CombatSupportStat stat,
      long value) => new(
      ordinal,
      unlockLevel,
      Ready(stat),
      Ready(CombatSupportValueUnit.Absolute),
      Exact(value, 0));

  private static CombatSupportValueFact<T> Ready<T>(T value)
      where T : struct => new(CombatSupportFactStatus.Ready, value);

  private static CombatSupportValueFact<T> Unresolved<T>(string reason)
      where T : struct => new(
      CombatSupportFactStatus.Unresolved,
      unresolvedReasonCode: reason);

  private static CombatSupportValueFact<T> NotApplicable<T>()
      where T : struct => new(CombatSupportFactStatus.NotApplicable);

  private static CombatSupportExactValue Exact(long value, int scale) => new(value, scale);

  private static SourceAliasFingerprint Alias(string category, string value) =>
      Alias(IdentitySecret, category, value);

  private static SourceAliasFingerprint Alias(byte[] secret, string category, string value) =>
      SourceAliasFingerprintEncoder.Encode(
          secret,
          "synthetic.combat-support",
          category,
          $"{RawCanary}|{PathCanary}|{value}");

  private static IEnumerable<SourceAliasFingerprint> AllAliases(
      CombatSupportCatalogPublication publication) =>
      publication.Definitions.Select(static item => item.SourceAliasFingerprint)
          .Concat(publication.Definitions.SelectMany(static definition =>
              definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload
                  ? overload.LegalBands.SelectMany(static band => band.OrderedValues)
                      .Select(static value => value.SourceAliasFingerprint)
                  : []));

  private static CompletedImportAttempt CreateAttempt(
      CombatSupportCatalogPublication publication,
      string runLabel,
      string roleCode = "combat_support_staticdata",
      string sourceVersion = "v1")
  {
    var observation = new SourceArtifactObservation(
        "staticdata_archive",
        Sha256Digest.ComputeUtf8($"synthetic-combat-support-staticdata/{sourceVersion}"),
        1_024);
    var manifest = CanonicalDatasetManifest.Create(
    [
      new DatasetArtifactInput(roleCode, observation)
    ]);
    var extractor = new ExtractorDescriptor(
        "combat_support_catalog",
        "v1",
        Sha256Digest.ComputeUtf8("nll/combat-support-catalog-output/v1"));
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
        publication.CanonicalSha256,
        [],
        now,
        now.AddMilliseconds(runLabel.Length + 1));
  }

  private static async Task SeedCharacterAliasAsync(
      NpgsqlDataSource dataSource,
      SourceAliasFingerprint alias)
  {
    var binding = CombatSupportCatalogIdentityBinding.FromSecret(IdentitySecret);
    var fingerprint = alias.ToByteArray();
    var keyCheck = binding.KeyCheckSha256.ToByteArray();
    try
    {
      await using var connection = await dataSource.OpenConnectionAsync();
      await using var transaction = await connection.BeginTransactionAsync();
      var createdAt = DateTimeOffset.UtcNow;
      await using (var bindingCommand = new NpgsqlCommand(
                       """
                       INSERT INTO lab_meta.character_identity_key_binding
                           (binding_id, encoder_version, key_check_sha256, created_at_utc)
                       VALUES (1, $1, $2, $3);
                       """,
                       connection,
                       transaction))
      {
        bindingCommand.Parameters.AddWithValue(binding.EncoderVersion);
        bindingCommand.Parameters.AddWithValue(keyCheck);
        bindingCommand.Parameters.AddWithValue(createdAt);
        await bindingCommand.ExecuteNonQueryAsync();
      }

      await using (var aliasCommand = new NpgsqlCommand(
                       """
                       WITH entity AS (
                           INSERT INTO lab_catalog.character_entity(character_uid, created_at_utc)
                           VALUES ($1, $2)
                           RETURNING character_entity_id
                       )
                       INSERT INTO lab_private.character_source_alias
                           (alias_fingerprint, character_entity_id, created_at_utc)
                       SELECT $3, character_entity_id, $2 FROM entity;
                       """,
                       connection,
                       transaction))
      {
        aliasCommand.Parameters.AddWithValue(EntityUid.New().Value);
        aliasCommand.Parameters.AddWithValue(createdAt);
        aliasCommand.Parameters.AddWithValue(fingerprint);
        await aliasCommand.ExecuteNonQueryAsync();
      }

      await transaction.CommitAsync();
    }
    finally
    {
      System.Security.Cryptography.CryptographicOperations.ZeroMemory(fingerprint);
      System.Security.Cryptography.CryptographicOperations.ZeroMemory(keyCheck);
    }
  }

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

  private static async Task<long> ScalarAsync(NpgsqlConnection connection, string sql)
  {
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(await command.ExecuteScalarAsync(), System.Globalization.CultureInfo.InvariantCulture);
  }

  private static async Task AssertLeakSafeSchemaAsync(NpgsqlConnection connection)
  {
    var forbiddenColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
      "source_path",
      "source_file",
      "file_path",
      "raw_id",
      "raw_source_identifier",
      "source_identifier",
      "json"
    };
    await using var command = new NpgsqlCommand(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'lab_combat_support';
        """,
        connection);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      var column = reader.GetString(0);
      var dataType = reader.GetString(1);
      Assert.DoesNotContain(column, forbiddenColumns);
      Assert.DoesNotContain("json", dataType, StringComparison.OrdinalIgnoreCase);
    }
  }

  private static CombatSupportDomain.CombatSupportDefinitionKind ToDomainKind(
      CombatSupportDefinitionKind kind) => kind switch
      {
        CombatSupportDefinitionKind.Equipment => CombatSupportDomain.CombatSupportDefinitionKind.Equipment,
        CombatSupportDefinitionKind.Cube => CombatSupportDomain.CombatSupportDefinitionKind.HarmonyCube,
        CombatSupportDefinitionKind.Collection => CombatSupportDomain.CombatSupportDefinitionKind.GenericCollection,
        CombatSupportDefinitionKind.Favorite => CombatSupportDomain.CombatSupportDefinitionKind.Favorite,
        CombatSupportDefinitionKind.Console => CombatSupportDomain.CombatSupportDefinitionKind.Console,
        CombatSupportDefinitionKind.OverloadOption => CombatSupportDomain.CombatSupportDefinitionKind.OverloadOption,
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
      };
}
