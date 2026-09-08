using ImportProfile = NikkeLocalLab.Import.Profile;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlProfileCatalogAliasResolverFactory
{
  private readonly NpgsqlDataSource _dataSource;

  public PostgreSqlProfileCatalogAliasResolverFactory(NpgsqlDataSource dataSource)
  {
    _dataSource = dataSource ?? throw new ArgumentNullException(nameof(dataSource));
  }

  public async Task<ImportProfile.IProfileCatalogAliasResolver> CreateCurrentAsync(
      CancellationToken cancellationToken = default)
  {
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(
        """
        SELECT
            character.character_catalog_snapshot_uid,
            character_dataset.dataset_snapshot_uid,
            character.catalog_manifest_sha256,
            support.catalog_snapshot_uid,
            support_dataset.dataset_snapshot_uid,
            support.catalog_manifest_sha256
        FROM LATERAL (
            SELECT * FROM lab_catalog.character_catalog_snapshot
            ORDER BY character_catalog_snapshot_id DESC LIMIT 1
        ) AS character
        JOIN lab_import.dataset_snapshot AS character_dataset
          ON character_dataset.dataset_snapshot_id = character.dataset_snapshot_id
        CROSS JOIN LATERAL (
            SELECT * FROM lab_combat_support.catalog_snapshot
            ORDER BY catalog_snapshot_id DESC LIMIT 1
        ) AS support
        JOIN lab_import.dataset_snapshot AS support_dataset
          ON support_dataset.dataset_snapshot_id = support.dataset_snapshot_id;
        """,
        connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new LocalGameStateIntegrityException("profile_catalog_current_pair_not_found");
    }

    var character = new ImportProfile.ProfileImportCatalogBinding(
        new EntityUid(reader.GetGuid(0)),
        new EntityUid(reader.GetGuid(1)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(2)));
    var support = new ImportProfile.ProfileImportCatalogBinding(
        new EntityUid(reader.GetGuid(3)),
        new EntityUid(reader.GetGuid(4)),
        Sha256Digest.FromBytes((byte[])reader.GetValue(5)));
    await reader.DisposeAsync().ConfigureAwait(false);
    return await CreateAsync(character, support, cancellationToken).ConfigureAwait(false);
  }

  public async Task<ImportProfile.IProfileCatalogAliasResolver> CreateAsync(
      ImportProfile.ProfileImportCatalogBinding characterCatalog,
      ImportProfile.ProfileImportCatalogBinding combatSupportCatalog,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(characterCatalog);
    ArgumentNullException.ThrowIfNull(combatSupportCatalog);
    var allCharacterAliases = await LoadAliasSetAsync(
        "SELECT alias_fingerprint FROM lab_private.character_source_alias;",
        cancellationToken).ConfigureAwait(false);
    var allSupportAliases = await LoadAliasSetAsync(
        "SELECT alias_fingerprint FROM lab_private.combat_support_source_alias;",
        cancellationToken).ConfigureAwait(false);
    var allOverloadAliases = await LoadAliasSetAsync(
        "SELECT DISTINCT alias_fingerprint FROM lab_private.overload_legal_value_source_alias;",
        cancellationToken).ConfigureAwait(false);
    var characters = await LoadCharactersAsync(characterCatalog, cancellationToken)
        .ConfigureAwait(false);
    var equipment = await LoadEquipmentAsync(combatSupportCatalog, cancellationToken)
        .ConfigureAwait(false);
    var cubes = await LoadCubesAsync(combatSupportCatalog, cancellationToken).ConfigureAwait(false);
    var collections = await LoadCollectionsAsync(combatSupportCatalog, cancellationToken)
        .ConfigureAwait(false);
    var favorites = await LoadFavoritesAsync(combatSupportCatalog, cancellationToken)
        .ConfigureAwait(false);
    var consoles = await LoadConsolesAsync(combatSupportCatalog, cancellationToken)
        .ConfigureAwait(false);
    var overload = await LoadOverloadAsync(combatSupportCatalog, cancellationToken)
        .ConfigureAwait(false);
    return new InMemoryResolver(
        characterCatalog,
        combatSupportCatalog,
        allCharacterAliases,
        allSupportAliases,
        allOverloadAliases,
        characters,
        equipment,
        cubes,
        collections,
        favorites,
        consoles,
        overload);
  }

  public async Task<IReadOnlySet<EntityUid>> LoadCoreLevelNotApplicableCharacterUidsAsync(
      ImportProfile.ProfileImportCatalogBinding characterCatalog,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(characterCatalog);
    const string sql = """
        SELECT entity.character_uid
        FROM lab_catalog.character_catalog_snapshot_member AS member
        JOIN lab_catalog.character_entity AS entity
          ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_capability AS capability
          ON capability.character_definition_version_id = member.character_definition_version_id
        JOIN lab_catalog.character_catalog_snapshot AS catalog
          ON catalog.character_catalog_snapshot_id = member.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE catalog.character_catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest
          AND capability.capability_code = 'core_level'
          AND capability.resolution_status = 'not_applicable';
        """;
    var result = new HashSet<EntityUid>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, characterCatalog);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new EntityUid(reader.GetGuid(0)));
    }

    return result;
  }

  public async Task<IReadOnlySet<EntityUid>> LoadBondLevelNotApplicableCharacterUidsAsync(
      ImportProfile.ProfileImportCatalogBinding characterCatalog,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(characterCatalog);
    const string sql = """
        SELECT entity.character_uid
        FROM lab_catalog.character_catalog_snapshot_member AS member
        JOIN lab_catalog.character_entity AS entity
          ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id = member.character_definition_version_id
        JOIN lab_catalog.character_catalog_snapshot AS catalog
          ON catalog.character_catalog_snapshot_id = member.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE catalog.character_catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest
          AND version.rarity_status = 'ready'
          AND version.rarity_code = 'r';
        """;
    var result = new HashSet<EntityUid>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, characterCatalog);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new EntityUid(reader.GetGuid(0)));
    }

    return result;
  }

  public async Task<IReadOnlySet<EntityUid>> LoadManufacturerNotApplicableEquipmentUidsAsync(
      ImportProfile.ProfileImportCatalogBinding combatSupportCatalog,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(combatSupportCatalog);
    const string sql = """
        SELECT entity.definition_uid
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
         AND entity.definition_kind = 'equipment'
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = member.definition_version_id
        JOIN lab_combat_support.equipment_definition_detail AS detail
          ON detail.definition_version_id = version.definition_version_id
        JOIN lab_combat_support.catalog_snapshot AS catalog
          ON catalog.catalog_snapshot_id = member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        WHERE catalog.catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest
          AND detail.tier_status = 'ready'
          AND detail.tier_value IN (9, 10)
          AND detail.manufacturer_status = 'not_applicable';
        """;
    var result = new HashSet<EntityUid>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, combatSupportCatalog);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new EntityUid(reader.GetGuid(0)));
    }

    return result;
  }

  public async Task ValidateRebaseAsync(
      ImportProfile.SanitizedProfileDraft source,
      ImportProfile.SanitizedProfileDraft target,
      IReadOnlyDictionary<EntityUid, EntityUid> explicitMappings,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(source);
    ArgumentNullException.ThrowIfNull(target);
    ArgumentNullException.ThrowIfNull(explicitMappings);
    var sourceResolver = await CreateSemanticValidationResolverAsync(
        source.CharacterCatalog,
        source.CombatSupportCatalog,
        cancellationToken).ConfigureAwait(false);
    var targetResolver = await CreateSemanticValidationResolverAsync(
        target.CharacterCatalog,
        target.CombatSupportCatalog,
        cancellationToken).ConfigureAwait(false);
    sourceResolver.ValidateRebaseTo(targetResolver, source, target, explicitMappings);
  }

  private async Task<InMemoryResolver> CreateSemanticValidationResolverAsync(
      ImportProfile.ProfileImportCatalogBinding characterCatalog,
      ImportProfile.ProfileImportCatalogBinding combatSupportCatalog,
      CancellationToken cancellationToken)
  {
    return new InMemoryResolver(
        characterCatalog,
        combatSupportCatalog,
        [],
        [],
        [],
        await LoadCharactersAsync(characterCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadEquipmentAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadCubesAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadCollectionsAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadFavoritesAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadConsolesAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false),
        await LoadOverloadAsync(combatSupportCatalog, cancellationToken, includeUnaliased: true)
            .ConfigureAwait(false));
  }

  private async Task<HashSet<SourceAliasFingerprint>> LoadAliasSetAsync(
      string sql,
      CancellationToken cancellationToken)
  {
    var result = new HashSet<SourceAliasFingerprint>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(SourceAliasFingerprint.FromBytes((byte[])reader.GetValue(0)));
    }

    return result;
  }

  private async Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCharacter>>>
      LoadCharactersAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken cancellationToken,
          bool includeUnaliased = false)
  {
    const string sql = """
        SELECT alias.alias_fingerprint, entity.character_uid, version.rarity_code,
               version.combat_class_code, version.manufacturer_code, version.weapon_code,
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'character_level'),
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'limit_break'),
               coalesce(max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'core_level'), 0),
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'bond_level'),
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'skill_1'),
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'skill_2'),
               max(cap.maximum_level) FILTER (WHERE cap.capability_code = 'burst')
        FROM lab_catalog.character_catalog_snapshot_member AS member
        JOIN lab_catalog.character_entity AS entity
          ON entity.character_entity_id = member.character_entity_id
        LEFT JOIN lab_private.character_source_alias AS alias
          ON alias.character_entity_id = entity.character_entity_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id = member.character_definition_version_id
        JOIN lab_catalog.character_catalog_snapshot AS catalog
          ON catalog.character_catalog_snapshot_id = member.character_catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset
          ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        JOIN lab_catalog.character_definition_capability AS cap
          ON cap.character_definition_version_id = version.character_definition_version_id
         AND (cap.resolution_status = 'ready'
              OR (cap.capability_code = 'core_level' AND cap.resolution_status = 'not_applicable'))
        WHERE catalog.character_catalog_snapshot_uid = @catalog_uid
          AND dataset.dataset_snapshot_uid = @dataset_uid
          AND catalog.catalog_manifest_sha256 = @manifest
          AND version.rarity_status = 'ready'
          AND version.combat_class_status = 'ready'
          AND version.manufacturer_status = 'ready'
          AND version.weapon_status = 'ready'
          AND (@include_unaliased OR alias.alias_fingerprint IS NOT NULL)
        GROUP BY alias.alias_fingerprint, entity.character_uid, version.rarity_code,
                 version.combat_class_code, version.manufacturer_code, version.weapon_code
        HAVING count(*) FILTER (WHERE cap.capability_code IN (
                   'character_level','limit_break','core_level','bond_level',
                   'skill_1','skill_2','burst')) = 7;
        """;
    var result = new Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCharacter>>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, binding);
    command.Parameters.AddWithValue("include_unaliased", NpgsqlDbType.Boolean, includeUnaliased);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      Add(result, ReadAliasOrValidationKey(reader, 0, 1, "character"),
          new ImportProfile.ResolvedProfileCharacter(
              new EntityUid(reader.GetGuid(1)),
              ParseRarity(reader.GetString(2)),
              ParseRole(reader.GetString(3)),
              ParseManufacturer(reader.GetString(4)),
              ParseWeapon(reader.GetString(5)),
              reader.GetInt32(6), reader.GetInt32(7), reader.GetInt32(8), reader.GetInt32(9),
              reader.GetInt32(10), reader.GetInt32(11), reader.GetInt32(12)));
    }

    return result;
  }

  private Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileEquipment>>>
      LoadEquipmentAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken token,
          bool includeUnaliased = false) =>
      LoadSupportAsync(
          binding,
          "equipment",
          """
          SELECT detail.equipment_slot, detail.combat_class_code,
                 detail.manufacturer_status, detail.manufacturer_code,
                 detail.manufacturer_unresolved_reason_code,
                 detail.tier_value, detail.maximum_enhancement_level,
                 detail.overload_eligible
          FROM lab_combat_support.equipment_definition_detail AS detail
          WHERE detail.definition_version_id = version.definition_version_id
            AND detail.combat_class_status='ready' AND detail.tier_status='ready'
            AND detail.enhancement_status='ready' AND detail.overload_eligible_status='ready'
          """,
          static (reader, uid) => new ImportProfile.ResolvedProfileEquipment(
              uid,
              ParseEquipmentSlot(reader.GetString(3)),
              ParseRole(reader.GetString(4)),
              ReadEquipmentManufacturer(reader, 5, 6, 7),
              reader.GetInt32(8), reader.GetInt32(9), reader.GetBoolean(10)),
          token,
          includeUnaliased);

  private static ImportProfile.ProfileImportFact<ImportProfile.ProfileImportManufacturer>
      ReadEquipmentManufacturer(
          NpgsqlDataReader reader,
          int statusOrdinal,
          int valueOrdinal,
          int reasonOrdinal) => reader.GetString(statusOrdinal) switch
          {
            "ready" when !reader.IsDBNull(valueOrdinal) =>
                ImportProfile.ProfileImportFact<ImportProfile.ProfileImportManufacturer>.Ready(
                    ParseManufacturer(reader.GetString(valueOrdinal))),
            "unresolved" when !reader.IsDBNull(reasonOrdinal) =>
                ImportProfile.ProfileImportFact<ImportProfile.ProfileImportManufacturer>.Unresolved(
                    reader.GetString(reasonOrdinal)),
            "not_applicable" =>
                ImportProfile.ProfileImportFact<ImportProfile.ProfileImportManufacturer>.NotApplicable(),
            _ => throw new LocalGameStateIntegrityException(
                "profile_catalog_manufacturer_shape_invalid")
          };

  private Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCube>>>
      LoadCubesAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken token,
          bool includeUnaliased = false) =>
      LoadSupportAsync(
          binding,
          "cube",
          """
          SELECT detail.maximum_level, detail.applicable_combat_class_status,
                 detail.applicable_combat_class_code
          FROM lab_combat_support.cube_definition_detail AS detail
          WHERE detail.definition_version_id = version.definition_version_id
            AND detail.maximum_level_status='ready'
            AND detail.applicable_combat_class_status IN ('ready','not_applicable')
          """,
          static (reader, uid) => new ImportProfile.ResolvedProfileCube(
              uid,
              reader.GetInt32(3),
              reader.GetString(4) == "ready" ? ParseRole(reader.GetString(5)) : null),
          token,
          includeUnaliased);

  private Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>>>
      LoadCollectionsAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken token,
          bool includeUnaliased = false) =>
      LoadSupportAsync(
          binding,
          "collection",
          """
          SELECT detail.maximum_level, detail.weapon_class_code
          FROM lab_combat_support.collection_definition_detail AS detail
          WHERE detail.definition_version_id = version.definition_version_id
            AND detail.maximum_level_status='ready' AND detail.weapon_class_status='ready'
          """,
          static (reader, uid) => new ImportProfile.ResolvedProfileCollection(
              uid, ImportProfile.ProfileImportCollectionKind.GenericCollection,
              reader.GetInt32(3), null, ParseWeapon(reader.GetString(4))),
          token,
          includeUnaliased);

  private Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>>>
      LoadFavoritesAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken token,
          bool includeUnaliased = false) =>
      LoadSupportAsync(
          binding,
          "favorite",
          """
          SELECT detail.maximum_level, character.character_uid
          FROM lab_combat_support.favorite_definition_detail AS detail
          JOIN lab_catalog.character_entity AS character
            ON character.character_entity_id = detail.applicable_character_entity_id
          WHERE detail.definition_version_id = version.definition_version_id
            AND detail.maximum_level_status='ready' AND detail.applicable_character_status='ready'
          """,
          static (reader, uid) => new ImportProfile.ResolvedProfileCollection(
              uid, ImportProfile.ProfileImportCollectionKind.Favorite,
              reader.GetInt32(3), new EntityUid(reader.GetGuid(4)), null),
          token,
          includeUnaliased);

  private async Task<Dictionary<SourceAliasFingerprint, List<ConsoleDefinition>>> LoadConsolesAsync(
      ImportProfile.ProfileImportCatalogBinding binding,
      CancellationToken cancellationToken,
      bool includeUnaliased = false)
  {
    const string sql = """
        SELECT alias.alias_fingerprint, entity.definition_uid, detail.coordinate_code,
               detail.maximum_level, legal.level, legal.minimum_synchro_level
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id=member.definition_entity_id AND entity.definition_kind='console'
        LEFT JOIN lab_private.combat_support_source_alias AS alias
          ON alias.definition_entity_id=entity.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id=member.definition_version_id
        JOIN lab_combat_support.console_definition_detail AS detail
          ON detail.definition_version_id=version.definition_version_id
        JOIN lab_combat_support.console_legal_level AS legal
          ON legal.definition_version_id=version.definition_version_id
        JOIN lab_combat_support.catalog_snapshot AS catalog
          ON catalog.catalog_snapshot_id=member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset ON dataset.dataset_snapshot_id=catalog.dataset_snapshot_id
        WHERE catalog.catalog_snapshot_uid=@catalog_uid AND dataset.dataset_snapshot_uid=@dataset_uid
          AND catalog.catalog_manifest_sha256=@manifest AND detail.maximum_level_status='ready'
          AND (@include_unaliased OR alias.alias_fingerprint IS NOT NULL);
        """;
    var rows = new Dictionary<SourceAliasFingerprint, List<ConsoleDefinition>>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, binding);
    command.Parameters.AddWithValue("include_unaliased", NpgsqlDbType.Boolean, includeUnaliased);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      var key = ReadAliasOrValidationKey(reader, 0, 1, "console");
      if (!rows.TryGetValue(key, out var definitions)) rows[key] = definitions = [];
      var uid = new EntityUid(reader.GetGuid(1));
      var existing = definitions.SingleOrDefault(item => item.DefinitionUid == uid);
      if (existing is null)
      {
        existing = new ConsoleDefinition(uid, ParseConsole(reader.GetString(2)), reader.GetInt32(3), []);
        definitions.Add(existing);
      }

      existing.MinimumSynchroByLevel[reader.GetInt32(4)] = reader.GetInt32(5);
    }

    return rows;
  }

  private async Task<Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileOverloadValue>>>
      LoadOverloadAsync(
          ImportProfile.ProfileImportCatalogBinding binding,
          CancellationToken cancellationToken,
          bool includeUnaliased = false)
  {
    const string sql = """
        SELECT alias.alias_fingerprint, entity.definition_uid, detail.unit_code,
               legal.source_raw_value, legal.engine_fraction_unscaled_value,
               legal.engine_fraction_decimal_scale
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id=member.definition_entity_id
         AND entity.definition_kind='overload_option'
        JOIN lab_combat_support.overload_option_definition_detail AS detail
          ON detail.definition_version_id=member.definition_version_id
        JOIN lab_combat_support.overload_legal_value AS legal
          ON legal.definition_version_id=member.definition_version_id
        LEFT JOIN lab_private.overload_legal_value_source_alias AS alias
          ON alias.definition_entity_id=member.definition_entity_id
         AND alias.definition_version_id=member.definition_version_id
         AND alias.roll_level=legal.roll_level
        JOIN lab_combat_support.catalog_snapshot AS catalog ON catalog.catalog_snapshot_id=member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset ON dataset.dataset_snapshot_id=catalog.dataset_snapshot_id
        WHERE catalog.catalog_snapshot_uid=@catalog_uid AND dataset.dataset_snapshot_uid=@dataset_uid
          AND catalog.catalog_manifest_sha256=@manifest AND detail.unit_status='ready'
          AND (@include_unaliased OR alias.alias_fingerprint IS NOT NULL);
        """;
    var result = new Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileOverloadValue>>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    AddBinding(command, binding);
    command.Parameters.AddWithValue("include_unaliased", NpgsqlDbType.Boolean, includeUnaliased);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      Add(result, ReadAliasOrValidationKey(reader, 0, 1, "overload_option"),
          new ImportProfile.ResolvedProfileOverloadValue(
              new EntityUid(reader.GetGuid(1)), ParseUnit(reader.GetString(2)), reader.GetInt64(3),
              new ImportProfile.ProfileImportExactValue(reader.GetInt64(4), reader.GetInt16(5))));
    }

    return result;
  }

  private async Task<Dictionary<SourceAliasFingerprint, List<T>>> LoadSupportAsync<T>(
      ImportProfile.ProfileImportCatalogBinding binding,
      string kind,
      string detailSql,
      Func<NpgsqlDataReader, EntityUid, T> project,
      CancellationToken cancellationToken,
      bool includeUnaliased = false)
      where T : class
  {
    var sql = $"""
        SELECT alias.alias_fingerprint, entity.definition_uid, version.definition_version_uid,
               detail.*
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id=member.definition_entity_id AND entity.definition_kind=@kind
        LEFT JOIN lab_private.combat_support_source_alias AS alias
          ON alias.definition_entity_id=entity.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id=member.definition_version_id
        JOIN lab_combat_support.catalog_snapshot AS catalog
          ON catalog.catalog_snapshot_id=member.catalog_snapshot_id
        JOIN lab_import.dataset_snapshot AS dataset ON dataset.dataset_snapshot_id=catalog.dataset_snapshot_id
        JOIN LATERAL ({detailSql}) AS detail ON TRUE
        WHERE catalog.catalog_snapshot_uid=@catalog_uid AND dataset.dataset_snapshot_uid=@dataset_uid
          AND catalog.catalog_manifest_sha256=@manifest
          AND (@include_unaliased OR alias.alias_fingerprint IS NOT NULL);
        """;
    var result = new Dictionary<SourceAliasFingerprint, List<T>>();
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand(sql, connection);
    command.Parameters.AddWithValue("kind", NpgsqlDbType.Text, kind);
    command.Parameters.AddWithValue("include_unaliased", NpgsqlDbType.Boolean, includeUnaliased);
    AddBinding(command, binding);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      Add(result, ReadAliasOrValidationKey(reader, 0, 1, kind),
          project(reader, new EntityUid(reader.GetGuid(1))));
    }

    return result;
  }

  private static void AddBinding(NpgsqlCommand command, ImportProfile.ProfileImportCatalogBinding binding)
  {
    command.Parameters.AddWithValue("catalog_uid", NpgsqlDbType.Uuid, binding.CatalogSnapshotUid.Value);
    command.Parameters.AddWithValue("dataset_uid", NpgsqlDbType.Uuid, binding.DatasetSnapshotUid.Value);
    command.Parameters.AddWithValue("manifest", NpgsqlDbType.Bytea, binding.ManifestSha256.ToByteArray());
  }

  private static SourceAliasFingerprint ReadAliasOrValidationKey(
      NpgsqlDataReader reader,
      int aliasOrdinal,
      int uidOrdinal,
      string kind)
  {
    if (!reader.IsDBNull(aliasOrdinal))
    {
      return SourceAliasFingerprint.FromBytes((byte[])reader.GetValue(aliasOrdinal));
    }

    var uid = reader.GetGuid(uidOrdinal).ToString("D");
    return SourceAliasFingerprint.FromBytes(
        Sha256Digest.ComputeUtf8($"nll/rebase-validation-member/v1\n{kind}\n{uid}").ToByteArray());
  }

  private static void Add<T>(Dictionary<SourceAliasFingerprint, List<T>> target, SourceAliasFingerprint key, T value)
  {
    if (!target.TryGetValue(key, out var values)) target[key] = values = [];
    values.Add(value);
  }

  private static ImportProfile.ProfileImportRarity ParseRarity(string value) => value switch
  {
    "r" => ImportProfile.ProfileImportRarity.R,
    "sr" => ImportProfile.ProfileImportRarity.Sr,
    "ssr" => ImportProfile.ProfileImportRarity.Ssr,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_rarity_invalid")
  };

  private static ImportProfile.ProfileImportCombatRole ParseRole(string value) => value switch
  {
    "attacker" => ImportProfile.ProfileImportCombatRole.Attacker,
    "defender" => ImportProfile.ProfileImportCombatRole.Defender,
    "supporter" => ImportProfile.ProfileImportCombatRole.Supporter,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_role_invalid")
  };

  private static ImportProfile.ProfileImportManufacturer ParseManufacturer(string value) => value switch
  {
    "elysion" => ImportProfile.ProfileImportManufacturer.Elysion,
    "missilis" => ImportProfile.ProfileImportManufacturer.Missilis,
    "tetra" => ImportProfile.ProfileImportManufacturer.Tetra,
    "pilgrim" => ImportProfile.ProfileImportManufacturer.Pilgrim,
    "abnormal" => ImportProfile.ProfileImportManufacturer.Abnormal,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_manufacturer_invalid")
  };

  private static ImportProfile.ProfileImportWeaponClass ParseWeapon(string value) => value switch
  {
    "assault_rifle" => ImportProfile.ProfileImportWeaponClass.AssaultRifle,
    "rocket_launcher" => ImportProfile.ProfileImportWeaponClass.RocketLauncher,
    "sniper_rifle" => ImportProfile.ProfileImportWeaponClass.SniperRifle,
    "machine_gun" => ImportProfile.ProfileImportWeaponClass.MachineGun,
    "shotgun" => ImportProfile.ProfileImportWeaponClass.Shotgun,
    "submachine_gun" => ImportProfile.ProfileImportWeaponClass.SubmachineGun,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_weapon_invalid")
  };

  private static ImportProfile.ProfileImportEquipmentSlot ParseEquipmentSlot(string value) => value switch
  {
    "head" => ImportProfile.ProfileImportEquipmentSlot.Head,
    "torso" => ImportProfile.ProfileImportEquipmentSlot.Torso,
    "arms" => ImportProfile.ProfileImportEquipmentSlot.Arms,
    "legs" => ImportProfile.ProfileImportEquipmentSlot.Legs,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_equipment_slot_invalid")
  };

  private static ImportProfile.ProfileImportConsoleCoordinate ParseConsole(string value) => value switch
  {
    "common" => ImportProfile.ProfileImportConsoleCoordinate.Common,
    "attacker" => ImportProfile.ProfileImportConsoleCoordinate.Attacker,
    "defender" => ImportProfile.ProfileImportConsoleCoordinate.Defender,
    "supporter" => ImportProfile.ProfileImportConsoleCoordinate.Supporter,
    "elysion" => ImportProfile.ProfileImportConsoleCoordinate.Elysion,
    "missilis" => ImportProfile.ProfileImportConsoleCoordinate.Missilis,
    "tetra" => ImportProfile.ProfileImportConsoleCoordinate.Tetra,
    "pilgrim" => ImportProfile.ProfileImportConsoleCoordinate.Pilgrim,
    "abnormal" => ImportProfile.ProfileImportConsoleCoordinate.Abnormal,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_console_invalid")
  };

  private static ImportProfile.ProfileImportValueUnit ParseUnit(string value) => value switch
  {
    "absolute" => ImportProfile.ProfileImportValueUnit.Absolute,
    "ratio" => ImportProfile.ProfileImportValueUnit.Ratio,
    "percent" => ImportProfile.ProfileImportValueUnit.Percent,
    "count" => ImportProfile.ProfileImportValueUnit.Count,
    _ => throw new LocalGameStateIntegrityException("profile_catalog_unit_invalid")
  };

  private sealed record ConsoleDefinition(
      EntityUid DefinitionUid,
      ImportProfile.ProfileImportConsoleCoordinate Coordinate,
      int MaximumLevel,
      Dictionary<int, int> MinimumSynchroByLevel);

  private sealed class InMemoryResolver : ImportProfile.IProfileCatalogAliasResolver
  {
    private readonly HashSet<SourceAliasFingerprint> _allCharacter;
    private readonly HashSet<SourceAliasFingerprint> _allSupport;
    private readonly HashSet<SourceAliasFingerprint> _allOverload;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCharacter>> _characters;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileEquipment>> _equipment;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCube>> _cubes;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>> _collections;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>> _favorites;
    private readonly Dictionary<SourceAliasFingerprint, List<ConsoleDefinition>> _consoles;
    private readonly Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileOverloadValue>> _overload;

    internal InMemoryResolver(
        ImportProfile.ProfileImportCatalogBinding characterCatalog,
        ImportProfile.ProfileImportCatalogBinding supportCatalog,
        HashSet<SourceAliasFingerprint> allCharacter,
        HashSet<SourceAliasFingerprint> allSupport,
        HashSet<SourceAliasFingerprint> allOverload,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCharacter>> characters,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileEquipment>> equipment,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCube>> cubes,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>> collections,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileCollection>> favorites,
        Dictionary<SourceAliasFingerprint, List<ConsoleDefinition>> consoles,
        Dictionary<SourceAliasFingerprint, List<ImportProfile.ResolvedProfileOverloadValue>> overload)
    {
      CharacterCatalog = characterCatalog;
      CombatSupportCatalog = supportCatalog;
      _allCharacter = allCharacter;
      _allSupport = allSupport;
      _allOverload = allOverload;
      _characters = characters;
      _equipment = equipment;
      _cubes = cubes;
      _collections = collections;
      _favorites = favorites;
      _consoles = consoles;
      _overload = overload;
    }

    public ImportProfile.ProfileImportCatalogBinding CharacterCatalog { get; }
    public ImportProfile.ProfileImportCatalogBinding CombatSupportCatalog { get; }

    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileCharacter> ResolveCharacter(SourceAliasFingerprint value) =>
        Resolve(value, _allCharacter, _characters);
    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileEquipment> ResolveEquipment(SourceAliasFingerprint value) =>
        Resolve(value, _allSupport, _equipment);
    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileCube> ResolveCube(SourceAliasFingerprint value) =>
        Resolve(value, _allSupport, _cubes);
    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileCollection> ResolveGenericCollection(SourceAliasFingerprint value) =>
        Resolve(value, _allSupport, _collections);
    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileCollection> ResolveFavorite(SourceAliasFingerprint value) =>
        Resolve(value, _allSupport, _favorites);
    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileOverloadValue> ResolveOverloadValue(SourceAliasFingerprint value) =>
        Resolve(value, _allOverload, _overload);

    public ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole> ResolveConsole(
        SourceAliasFingerprint value,
        int selectedLevel)
    {
      if (!_consoles.TryGetValue(value, out var values) || values.Count == 0)
      {
        return _allSupport.Contains(value)
            ? ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.CatalogMismatch()
            : ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.Missing();
      }

      if (values.Count != 1)
      {
        return ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.Ambiguous();
      }

      var definition = values[0];
      if (selectedLevel == 0)
      {
        return ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.Resolved(
            new ImportProfile.ResolvedProfileConsole(
                definition.DefinitionUid,
                definition.Coordinate,
                selectedLevel,
                definition.MaximumLevel,
                ImportProfile.ProfileImportFact<int>.Ready(0)));
      }

      if (!definition.MinimumSynchroByLevel.TryGetValue(selectedLevel, out var minimum))
      {
        return ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.CatalogMismatch();
      }

      return ImportProfile.ProfileAliasResolution<ImportProfile.ResolvedProfileConsole>.Resolved(
          new ImportProfile.ResolvedProfileConsole(
              definition.DefinitionUid,
              definition.Coordinate,
              selectedLevel,
              definition.MaximumLevel,
              ImportProfile.ProfileImportFact<int>.Ready(minimum)));
    }

    internal void ValidateRebaseTo(
        InMemoryResolver targetResolver,
        ImportProfile.SanitizedProfileDraft source,
        ImportProfile.SanitizedProfileDraft target,
        IReadOnlyDictionary<EntityUid, EntityUid> mappings)
    {
      var sourceCharacters = UniqueByUid(
          _characters.Values.SelectMany(static values => values),
          static value => value.CharacterUid);
      var targetCharacters = UniqueByUid(
          targetResolver._characters.Values.SelectMany(static values => values),
          static value => value.CharacterUid);
      var sourceEquipment = UniqueByUid(
          _equipment.Values.SelectMany(static values => values),
          static value => value.DefinitionUid);
      var targetEquipment = UniqueByUid(
          targetResolver._equipment.Values.SelectMany(static values => values),
          static value => value.DefinitionUid);
      var sourceCubes = UniqueByUid(
          _cubes.Values.SelectMany(static values => values),
          static value => value.DefinitionUid);
      var targetCubes = UniqueByUid(
          targetResolver._cubes.Values.SelectMany(static values => values),
          static value => value.DefinitionUid);
      var sourceCollections = UniqueByUid(
          _collections.Values.SelectMany(static values => values)
              .Concat(_favorites.Values.SelectMany(static values => values)),
          static value => value.DefinitionUid);
      var targetCollections = UniqueByUid(
          targetResolver._collections.Values.SelectMany(static values => values)
              .Concat(targetResolver._favorites.Values.SelectMany(static values => values)),
          static value => value.DefinitionUid);
      var sourceConsoles = UniqueConsoles(_consoles.Values.SelectMany(static values => values));
      var targetConsoles = UniqueConsoles(
          targetResolver._consoles.Values.SelectMany(static values => values));
      var sourceOverload = OverloadByUid(_overload.Values.SelectMany(static values => values));
      var targetOverload = OverloadByUid(
          targetResolver._overload.Values.SelectMany(static values => values));

      if (source.Builds.Count != target.Builds.Count ||
          source.AccountState.Consoles.Count != target.AccountState.Consoles.Count)
      {
        throw new LocalGameStateIntegrityException("profile_rebase_catalog_semantics_invalid");
      }

      for (var index = 0; index < source.AccountState.Consoles.Count; index++)
      {
        var sourceValue = source.AccountState.Consoles[index];
        var targetValue = target.AccountState.Consoles[index];
        RequireMapped(sourceValue.DefinitionUid, targetValue.DefinitionUid, mappings);
        var sourceDefinition = Require(sourceConsoles, sourceValue.DefinitionUid);
        var targetDefinition = Require(targetConsoles, targetValue.DefinitionUid);
        if (sourceDefinition.Coordinate != targetDefinition.Coordinate ||
            targetDefinition.Coordinate != targetValue.Coordinate ||
            targetValue.Level > targetDefinition.MaximumLevel ||
            !TryMinimumSynchro(targetDefinition, targetValue.Level, out var targetMinimum) ||
            target.AccountState.SynchroLevel < targetMinimum)
        {
          throw new LocalGameStateIntegrityException("profile_rebase_console_semantics_invalid");
        }
      }

      var targetBuilds = target.Builds.ToDictionary(static build => build.CharacterUid);
      foreach (var sourceBuild in source.Builds)
      {
        var expectedTargetCharacterUid = mappings.TryGetValue(
            sourceBuild.CharacterUid,
            out var mappedCharacterUid)
                ? mappedCharacterUid
                : sourceBuild.CharacterUid;
        if (!targetBuilds.TryGetValue(expectedTargetCharacterUid, out var targetBuild))
        {
          throw new LocalGameStateIntegrityException("profile_rebase_mapping_invalid");
        }

        RequireMapped(sourceBuild.CharacterUid, targetBuild.CharacterUid, mappings);
        var sourceCharacter = Require(sourceCharacters, sourceBuild.CharacterUid);
        var targetCharacter = Require(targetCharacters, targetBuild.CharacterUid);
        if (sourceCharacter.CombatRole != targetCharacter.CombatRole ||
            sourceCharacter.Manufacturer != targetCharacter.Manufacturer ||
            sourceCharacter.WeaponClass != targetCharacter.WeaponClass ||
            targetBuild.Level.RosterLevel > targetCharacter.MaximumCharacterLevel ||
            targetBuild.Level.DetailLevel > targetCharacter.MaximumCharacterLevel ||
            targetBuild.LimitBreak > targetCharacter.MaximumLimitBreak ||
            targetBuild.CoreLevel > targetCharacter.MaximumCoreLevel ||
            targetBuild.ResolvedBondLevel.Value is { } bond &&
                bond > targetCharacter.MaximumBondLevel ||
            targetBuild.Skill1Level > targetCharacter.MaximumSkill1Level ||
            targetBuild.Skill2Level > targetCharacter.MaximumSkill2Level ||
            targetBuild.BurstLevel > targetCharacter.MaximumBurstLevel)
        {
          throw new LocalGameStateIntegrityException("profile_rebase_character_semantics_invalid");
        }

        var targetSelections = targetBuild.Equipment.ToDictionary(static item => item.Slot);
        foreach (var sourceSelection in sourceBuild.Equipment)
        {
          if (!targetSelections.TryGetValue(sourceSelection.Slot, out var targetSelection))
          {
            throw new LocalGameStateIntegrityException("profile_rebase_equipment_semantics_invalid");
          }

          if (sourceSelection.State == ImportProfile.ProfileImportAttachmentState.Unequipped)
          {
            continue;
          }

          RequireMapped(
              sourceSelection.DefinitionUid!.Value,
              targetSelection.DefinitionUid!.Value,
              mappings);
          var sourceDefinition = Require(sourceEquipment, sourceSelection.DefinitionUid.Value);
          var targetDefinition = Require(targetEquipment, targetSelection.DefinitionUid.Value);
          if (sourceDefinition.Slot != targetDefinition.Slot ||
              sourceDefinition.CombatRole != targetDefinition.CombatRole ||
              sourceDefinition.Manufacturer != targetDefinition.Manufacturer ||
              sourceDefinition.Tier != targetDefinition.Tier ||
              sourceDefinition.OverloadEligible != targetDefinition.OverloadEligible ||
              targetDefinition.Slot != targetSelection.Slot ||
              targetDefinition.CombatRole != targetCharacter.CombatRole ||
              targetSelection.EnhancementLevel > targetDefinition.MaximumEnhancementLevel ||
              (targetSelection.OverloadLines.Count != 0 && !targetDefinition.OverloadEligible))
          {
            throw new LocalGameStateIntegrityException("profile_rebase_equipment_semantics_invalid");
          }

          var targetLines = targetSelection.OverloadLines.ToDictionary(static line => line.LineIndex);
          foreach (var sourceLine in sourceSelection.OverloadLines)
          {
            if (!targetLines.TryGetValue(sourceLine.LineIndex, out var targetLine))
            {
              throw new LocalGameStateIntegrityException("profile_rebase_overload_semantics_invalid");
            }

            RequireMapped(sourceLine.OptionDefinitionUid, targetLine.OptionDefinitionUid, mappings);
            if (!HasOverloadValue(sourceOverload, sourceLine) ||
                !HasOverloadValue(targetOverload, targetLine))
            {
              throw new LocalGameStateIntegrityException("profile_rebase_overload_semantics_invalid");
            }
          }
        }

        ValidateCube(sourceBuild.Cube, targetBuild.Cube, sourceCubes, targetCubes, mappings,
            targetCharacter.CombatRole);
        ValidateCollection(
            sourceBuild.Collection,
            targetBuild.Collection,
            sourceCollections,
            targetCollections,
            mappings,
            targetBuild.CharacterUid,
            targetCharacter.WeaponClass);
      }
    }

    private static void ValidateCube(
        ImportProfile.SanitizedCubeSelection source,
        ImportProfile.SanitizedCubeSelection target,
        IReadOnlyDictionary<EntityUid, ImportProfile.ResolvedProfileCube> sourceDefinitions,
        IReadOnlyDictionary<EntityUid, ImportProfile.ResolvedProfileCube> targetDefinitions,
        IReadOnlyDictionary<EntityUid, EntityUid> mappings,
        ImportProfile.ProfileImportCombatRole targetRole)
    {
      if (source.State == ImportProfile.ProfileImportAttachmentState.Unequipped)
      {
        return;
      }

      RequireMapped(source.DefinitionUid!.Value, target.DefinitionUid!.Value, mappings);
      var sourceDefinition = Require(sourceDefinitions, source.DefinitionUid.Value);
      var targetDefinition = Require(targetDefinitions, target.DefinitionUid.Value);
      if (sourceDefinition.ApplicableCombatRole != targetDefinition.ApplicableCombatRole ||
          target.Level > targetDefinition.MaximumLevel ||
          targetDefinition.ApplicableCombatRole is { } role && role != targetRole)
      {
        throw new LocalGameStateIntegrityException("profile_rebase_cube_semantics_invalid");
      }
    }

    private static void ValidateCollection(
        ImportProfile.SanitizedCollectionSelection source,
        ImportProfile.SanitizedCollectionSelection target,
        IReadOnlyDictionary<EntityUid, ImportProfile.ResolvedProfileCollection> sourceDefinitions,
        IReadOnlyDictionary<EntityUid, ImportProfile.ResolvedProfileCollection> targetDefinitions,
        IReadOnlyDictionary<EntityUid, EntityUid> mappings,
        EntityUid targetCharacterUid,
        ImportProfile.ProfileImportWeaponClass targetWeapon)
    {
      if (source.Kind == ImportProfile.ProfileImportCollectionKind.Detached)
      {
        return;
      }

      RequireMapped(source.DefinitionUid!.Value, target.DefinitionUid!.Value, mappings);
      var sourceDefinition = Require(sourceDefinitions, source.DefinitionUid.Value);
      var targetDefinition = Require(targetDefinitions, target.DefinitionUid.Value);
      if (sourceDefinition.Kind != targetDefinition.Kind ||
          targetDefinition.Kind != target.Kind ||
          target.Level > targetDefinition.MaximumLevel ||
          targetDefinition.ApplicableCharacterUid is { } character &&
              character != targetCharacterUid ||
          targetDefinition.ApplicableWeaponClass is { } weapon && weapon != targetWeapon)
      {
        throw new LocalGameStateIntegrityException("profile_rebase_collection_semantics_invalid");
      }
    }

    private static Dictionary<EntityUid, T> UniqueByUid<T>(
        IEnumerable<T> values,
        Func<T, EntityUid> uid)
        where T : class
    {
      var result = new Dictionary<EntityUid, T>();
      foreach (var value in values)
      {
        var key = uid(value);
        if (result.TryGetValue(key, out var existing) && existing != value)
        {
          throw new LocalGameStateIntegrityException("profile_catalog_uid_ambiguous");
        }

        result[key] = value;
      }

      return result;
    }

    private static Dictionary<EntityUid, ConsoleDefinition> UniqueConsoles(
        IEnumerable<ConsoleDefinition> values)
    {
      var result = new Dictionary<EntityUid, ConsoleDefinition>();
      foreach (var value in values)
      {
        if (result.TryGetValue(value.DefinitionUid, out var existing) &&
            (existing.Coordinate != value.Coordinate || existing.MaximumLevel != value.MaximumLevel ||
             !existing.MinimumSynchroByLevel.OrderBy(static item => item.Key)
                 .SequenceEqual(value.MinimumSynchroByLevel.OrderBy(static item => item.Key))))
        {
          throw new LocalGameStateIntegrityException("profile_catalog_uid_ambiguous");
        }

        result[value.DefinitionUid] = value;
      }

      return result;
    }

    private static Dictionary<EntityUid, IReadOnlyList<ImportProfile.ResolvedProfileOverloadValue>>
        OverloadByUid(IEnumerable<ImportProfile.ResolvedProfileOverloadValue> values) => values
            .GroupBy(static value => value.OptionDefinitionUid)
            .ToDictionary(
                static group => group.Key,
                static group => (IReadOnlyList<ImportProfile.ResolvedProfileOverloadValue>)group
                    .Distinct().ToArray());

    private static T Require<T>(IReadOnlyDictionary<EntityUid, T> values, EntityUid uid)
        where T : class => values.TryGetValue(uid, out var value)
            ? value
            : throw new LocalGameStateIntegrityException("profile_rebase_catalog_member_not_found");

    private static void RequireMapped(
        EntityUid source,
        EntityUid target,
        IReadOnlyDictionary<EntityUid, EntityUid> mappings)
    {
      var expected = mappings.TryGetValue(source, out var mapped) ? mapped : source;
      if (expected != target)
      {
        throw new LocalGameStateIntegrityException("profile_rebase_mapping_invalid");
      }
    }

    private static bool TryMinimumSynchro(
        ConsoleDefinition definition,
        int level,
        out int minimum)
    {
      if (level == 0)
      {
        minimum = 0;
        return true;
      }

      return definition.MinimumSynchroByLevel.TryGetValue(level, out minimum);
    }

    private static bool HasOverloadValue(
        IReadOnlyDictionary<EntityUid, IReadOnlyList<ImportProfile.ResolvedProfileOverloadValue>> values,
        ImportProfile.SanitizedOverloadLine line) =>
        values.TryGetValue(line.OptionDefinitionUid, out var legal) &&
        legal.Any(value => value.Unit == line.Unit && value.ApplicationValue == line.ExactValue);

    private static ImportProfile.ProfileAliasResolution<T> Resolve<T>(
        SourceAliasFingerprint value,
        HashSet<SourceAliasFingerprint> all,
        Dictionary<SourceAliasFingerprint, List<T>> selected)
        where T : class
    {
      if (!selected.TryGetValue(value, out var values) || values.Count == 0)
      {
        return all.Contains(value)
            ? ImportProfile.ProfileAliasResolution<T>.CatalogMismatch()
            : ImportProfile.ProfileAliasResolution<T>.Missing();
      }

      return values.Count == 1
          ? ImportProfile.ProfileAliasResolution<T>.Resolved(values[0])
          : ImportProfile.ProfileAliasResolution<T>.Ambiguous();
    }
  }
}
