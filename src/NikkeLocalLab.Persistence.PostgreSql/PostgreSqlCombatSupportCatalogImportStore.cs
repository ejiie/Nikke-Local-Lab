using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;
using CombatSupportDomain = NikkeLocalLab.Domain.CombatSupport;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlCombatSupportCatalogImportStore
{
  private const long AliasAdvisoryLockNamespace = 7_104_891_529_337_028_619;
  private const string StaticDataArtifactKind = "staticdata_archive";
  private const string StaticDataRole = "combat_support_staticdata";
  private readonly PostgreSqlImportLedger _ledger;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlCombatSupportCatalogImportStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    ArgumentNullException.ThrowIfNull(dataSource);
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
    _ledger = new PostgreSqlImportLedger(dataSource, uidGenerator);
  }

  public async Task<CombatSupportCatalogImportReceipt> RecordCompletedAndPublishAsync(
      CompletedImportAttempt attempt,
      CombatSupportCatalogPublication publication,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(attempt);
    ValidatePublication(attempt, publication);

    PublishedCatalog? published = null;
    var importReceipt = await _ledger.RecordCompletedAtomicallyAsync(
        attempt,
        async (context, token) =>
        {
          published = await PublishWithinTransactionAsync(
              context,
              attempt,
              publication,
              token).ConfigureAwait(false);
        },
        cancellationToken).ConfigureAwait(false);
    if (published is null)
    {
      throw new CombatSupportCatalogIntegrityException("support_catalog_publication_missing");
    }

    return new CombatSupportCatalogImportReceipt(
        importReceipt,
        published.Uid,
        published.ManifestSha256,
        published.Members.Select(ToReceipt).ToArray());
  }

  private void ValidatePublication(
      CompletedImportAttempt attempt,
      CombatSupportCatalogPublication publication)
  {
    ArgumentNullException.ThrowIfNull(publication);
    if (attempt.Diagnostics.Any(static diagnostic =>
            diagnostic.Severity == ImportDiagnosticSeverity.Error))
    {
      throw new CombatSupportCatalogIntegrityException("support_catalog_error_diagnostic");
    }

    if (attempt.OutputManifestSha256 != publication.CanonicalSha256)
    {
      throw new CombatSupportCatalogIntegrityException("support_publication_hash_mismatch");
    }

    if (attempt.DatasetManifest.Artifacts.Count != 1 ||
        !string.Equals(
            attempt.DatasetManifest.Artifacts[0].RoleCode,
            StaticDataRole,
            StringComparison.Ordinal) ||
        !string.Equals(
            attempt.DatasetManifest.Artifacts[0].Artifact.ArtifactKind,
            StaticDataArtifactKind,
            StringComparison.Ordinal))
    {
      throw new CombatSupportCatalogIntegrityException("support_staticdata_artifact_invalid");
    }

    foreach (var definition in publication.Definitions)
    {
      if (CombatSupportPublicationCanonicalizer.ComputeDefinitionContentSha256(definition) !=
          definition.DefinitionContentSha256)
      {
        throw new CombatSupportCatalogIntegrityException("support_definition_hash_mismatch");
      }

    }
  }

  private async Task<PublishedCatalog> PublishWithinTransactionAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      CombatSupportCatalogPublication publication,
      CancellationToken cancellationToken)
  {
    await EnsureIdentityBindingAsync(
        context,
        publication.IdentityBinding,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await AcquireAliasLocksAsync(
        context,
        publication.Definitions.Select(static item => item.SourceAliasFingerprint)
            .Concat(publication.Definitions.SelectMany(static definition =>
                definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload
                    ? overload.LegalBands.SelectMany(static band => band.OrderedValues)
                        .Select(static value => value.SourceAliasFingerprint)
                    : [])),
        cancellationToken).ConfigureAwait(false);

    var members = new List<StoredMember>(publication.Definitions.Count);
    for (var ordinal = 0; ordinal < publication.Definitions.Count; ordinal++)
    {
      var definition = publication.Definitions[ordinal];
      var entity = await ResolveEntityAsync(
          context,
          definition,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var version = await ResolveVersionAsync(
          context,
          entity,
          definition,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      members.Add(new StoredMember(
          ordinal,
          entity.Id,
          entity.Uid,
          version.Id,
          version.Uid,
          definition.Kind,
          version.DomainContentSha256,
          version.IsSourceReady,
          version.IsProfileSelectable,
          version.IsGameLegalReady,
          version.HasCompleteCombatSemantics,
          version.IsDuplicatePolicyReady));
    }

    var manifest = CombatSupportDomain.CombatSupportCatalogManifest.Create(
        context.DatasetSnapshotUid,
        members.Select(static member => new CombatSupportDomain.CombatSupportCatalogManifestEntry(
            ToDomainKind(member.Kind),
            member.EntityUid,
            member.DomainContentSha256,
            member.IsProfileSelectable,
            member.HasCompleteCombatSemantics)));
    var manifestSha256 = manifest.Sha256;
    var catalog = await ResolveCatalogAsync(
        context,
        attempt,
        manifestSha256,
        members.Count,
        cancellationToken).ConfigureAwait(false);
    await ResolveCatalogMembersAsync(
        context,
        catalog.Id,
        members,
        cancellationToken).ConfigureAwait(false);
    await ResolveImportProjectionAsync(
        context,
        catalog.Id,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);

    return new PublishedCatalog(catalog.Id, catalog.Uid, manifestSha256, members);
  }

  private static async Task EnsureIdentityBindingAsync(
      PostgreSqlCompletedImportContext context,
      CombatSupportCatalogIdentityBinding binding,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_meta.combat_support_identity_key_binding
                         (binding_id, encoder_version, key_check_sha256, created_at_utc)
                     VALUES (1, $1, $2, $3)
                     ON CONFLICT (binding_id) DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(binding.EncoderVersion);
      insert.Parameters.AddWithValue(binding.KeyCheckSha256.ToByteArray());
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await VerifyBindingRowAsync(
        context,
        "combat_support_identity_key_binding",
        binding,
        required: true,
        cancellationToken).ConfigureAwait(false);
    await VerifyBindingRowAsync(
        context,
        "character_identity_key_binding",
        binding,
        required: false,
        cancellationToken).ConfigureAwait(false);
  }

  private static async Task VerifyBindingRowAsync(
      PostgreSqlCompletedImportContext context,
      string tableName,
      CombatSupportCatalogIdentityBinding binding,
      bool required,
      CancellationToken cancellationToken)
  {
    var sql = tableName switch
    {
      "combat_support_identity_key_binding" =>
          "SELECT encoder_version, key_check_sha256 FROM lab_meta.combat_support_identity_key_binding WHERE binding_id = 1 FOR SHARE;",
      "character_identity_key_binding" =>
          "SELECT encoder_version, key_check_sha256 FROM lab_meta.character_identity_key_binding WHERE binding_id = 1 FOR SHARE;",
      _ => throw new CombatSupportCatalogIntegrityException("support_identity_binding_invalid")
    };
    string? storedVersion = null;
    byte[]? storedDigest = null;
    await using (var command = new NpgsqlCommand(sql, context.Connection, context.Transaction))
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        storedVersion = reader.GetString(0);
        storedDigest = (byte[])reader[1];
      }
    }

    if (storedDigest is null)
    {
      if (required)
      {
        throw new CombatSupportCatalogIntegrityException("support_identity_binding_missing");
      }

      return;
    }

    var expected = binding.KeyCheckSha256.ToByteArray();
    try
    {
      if (!string.Equals(storedVersion, binding.EncoderVersion, StringComparison.Ordinal) ||
          !CryptographicOperations.FixedTimeEquals(storedDigest, expected))
      {
        throw new CombatSupportCatalogIntegrityException("support_identity_key_mismatch");
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(storedDigest);
      CryptographicOperations.ZeroMemory(expected);
    }
  }

  private static async Task AcquireAliasLocksAsync(
      PostgreSqlCompletedImportContext context,
      IEnumerable<SourceAliasFingerprint> fingerprints,
      CancellationToken cancellationToken)
  {
    foreach (var fingerprint in fingerprints
                 .Distinct()
                 .OrderBy(static item => item.Hex, StringComparer.Ordinal))
    {
      var bytes = fingerprint.ToByteArray();
      long lockKey;
      try
      {
        lockKey = BinaryPrimitives.ReadInt64BigEndian(bytes) ^ AliasAdvisoryLockNamespace;
      }
      finally
      {
        CryptographicOperations.ZeroMemory(bytes);
      }

      await using var command = new NpgsqlCommand(
          "SELECT pg_advisory_xact_lock($1);",
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(lockKey);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private async Task<StoredEntity> ResolveEntityAsync(
      PostgreSqlCompletedImportContext context,
      CombatSupportDefinitionPublication definition,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var fingerprint = definition.SourceAliasFingerprint.ToByteArray();
    try
    {
      await using (var read = new NpgsqlCommand(
                       """
                       SELECT entity.definition_entity_id, entity.definition_uid,
                              entity.definition_kind
                       FROM lab_private.combat_support_source_alias AS alias
                       JOIN lab_combat_support.definition_entity AS entity
                         ON entity.definition_entity_id = alias.definition_entity_id
                       WHERE alias.alias_fingerprint = $1;
                       """,
                       context.Connection,
                       context.Transaction))
      {
        read.Parameters.AddWithValue(fingerprint);
        await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          var kindCode = reader.GetString(2);
          if (!string.Equals(
                  kindCode,
                  CombatSupportPublicationCodes.DefinitionKind(definition.Kind),
                  StringComparison.Ordinal))
          {
            throw new CombatSupportCatalogIntegrityException("support_alias_kind_mismatch");
          }

          return new StoredEntity(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
        }
      }

      var uid = _uidGenerator.NewUid();
      long id;
      await using (var insertEntity = new NpgsqlCommand(
                       """
                       INSERT INTO lab_combat_support.definition_entity
                           (definition_uid, definition_kind, created_at_utc)
                       VALUES ($1, $2, $3)
                       RETURNING definition_entity_id;
                       """,
                       context.Connection,
                       context.Transaction))
      {
        insertEntity.Parameters.AddWithValue(uid.Value);
        insertEntity.Parameters.AddWithValue(
            CombatSupportPublicationCodes.DefinitionKind(definition.Kind));
        insertEntity.Parameters.AddWithValue(createdAt);
        id = Convert.ToInt64(
            await insertEntity.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
            CultureInfo.InvariantCulture);
      }

      await using (var insertAlias = new NpgsqlCommand(
                       """
                       INSERT INTO lab_private.combat_support_source_alias
                           (alias_fingerprint, definition_entity_id,
                            definition_kind, created_at_utc)
                       VALUES ($1, $2, $3, $4);
                       """,
                       context.Connection,
                       context.Transaction))
      {
        insertAlias.Parameters.AddWithValue(fingerprint);
        insertAlias.Parameters.AddWithValue(id);
        insertAlias.Parameters.AddWithValue(
            CombatSupportPublicationCodes.DefinitionKind(definition.Kind));
        insertAlias.Parameters.AddWithValue(createdAt);
        await insertAlias.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      return new StoredEntity(id, uid);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(fingerprint);
    }
  }

  private async Task<StoredVersion> ResolveVersionAsync(
      PostgreSqlCompletedImportContext context,
      StoredEntity entity,
      CombatSupportDefinitionPublication definition,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var applicableCharacterUid = await ResolveApplicableCharacterUidAsync(
        context,
        definition,
        cancellationToken).ConfigureAwait(false);
    var domain = CreateDomainProjection(definition, applicableCharacterUid);
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT definition_version_id, definition_version_uid,
                            definition_kind, domain_canonical_sha256,
                            source_readiness_status, profile_selectable_status,
                            game_legal_readiness_status,
                            complete_semantics_status, duplicate_policy_readiness_status,
                            stat_contribution_count, skill_coordinate_count,
                            level_coordinate_count, equipment_option_slot_count,
                            legal_level_count, overload_legal_band_count,
                            overload_legal_value_count
                     FROM lab_combat_support.definition_version
                     WHERE definition_entity_id = $1 AND definition_content_sha256 = $2;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      read.Parameters.AddWithValue(entity.Id);
      read.Parameters.AddWithValue(definition.DefinitionContentSha256.ToByteArray());
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var stored = new StoredVersion(
            reader.GetInt64(0),
            new EntityUid(reader.GetGuid(1)),
            domain.ContentSha256,
            domain.IsSourceReady,
            domain.IsProfileSelectable,
            domain.IsGameLegalReady,
            domain.HasCompleteCombatSemantics,
            domain.IsDuplicatePolicyReady);
        var domainMatches = ((byte[])reader[3]).AsSpan()
            .SequenceEqual(domain.ContentSha256.ToByteArray());
        if (!string.Equals(
                reader.GetString(2),
                CombatSupportPublicationCodes.DefinitionKind(definition.Kind),
                StringComparison.Ordinal) ||
            !domainMatches ||
            !string.Equals(reader.GetString(4), Readiness(domain.IsSourceReady), StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(5), Readiness(domain.IsProfileSelectable), StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(6), Readiness(domain.IsGameLegalReady), StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(7), Readiness(domain.HasCompleteCombatSemantics), StringComparison.Ordinal) ||
            !string.Equals(reader.GetString(8), Readiness(domain.IsDuplicatePolicyReady), StringComparison.Ordinal) ||
            reader.GetInt32(9) != definition.Contributions.Contributions.Count ||
            reader.GetInt32(10) != definition.Contributions.SkillCoordinates.Count ||
            reader.GetInt32(11) != LevelCoordinateCount(definition) ||
            reader.GetInt32(12) != EquipmentOptionCount(definition) ||
            reader.GetInt32(13) != LegalLevelCount(definition) ||
            reader.GetInt32(14) != OverloadBandCount(definition) ||
            reader.GetInt32(15) != OverloadValueCount(definition))
        {
          throw new CombatSupportCatalogIntegrityException("support_version_provenance_mismatch");
        }

        await reader.DisposeAsync().ConfigureAwait(false);
        await EnsureVersionChildrenAsync(
            context,
            stored.Id,
            definition,
            cancellationToken).ConfigureAwait(false);
        return stored;
      }
    }

    var uid = _uidGenerator.NewUid();
    long id;
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_combat_support.definition_version
                         (definition_version_uid, definition_entity_id, definition_kind,
                          definition_content_sha256, domain_canonical_sha256,
                          display_name_status, display_name,
                          display_name_unresolved_reason_code,
                          contribution_status, contribution_unresolved_reason_code,
                          stat_contribution_count, skill_coordinate_count,
                          level_coordinate_count, equipment_option_slot_count,
                          legal_level_count, overload_legal_band_count,
                          overload_legal_value_count,
                          source_readiness_status, profile_selectable_status,
                          game_legal_readiness_status,
                          complete_semantics_status, duplicate_policy_readiness_status,
                          created_at_utc)
                     VALUES
                         ($1, $2, $3, $4, $5, $6, $7, $8, $9,
                          $10, $11, $12, $13, $14, $15, $16, $17,
                          $18, $19, $20, $21, $22, $23)
                     RETURNING definition_version_id;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(uid.Value);
      insert.Parameters.AddWithValue(entity.Id);
      insert.Parameters.AddWithValue(CombatSupportPublicationCodes.DefinitionKind(definition.Kind));
      insert.Parameters.AddWithValue(definition.DefinitionContentSha256.ToByteArray());
      insert.Parameters.AddWithValue(domain.ContentSha256.ToByteArray());
      AddTextFact(insert, definition.DisplayName);
      insert.Parameters.AddWithValue(
          CombatSupportPublicationCodes.FactStatus(definition.Contributions.Status));
      insert.Parameters.AddWithValue(
          (object?)definition.Contributions.UnresolvedReasonCode ?? DBNull.Value);
      insert.Parameters.AddWithValue(definition.Contributions.Contributions.Count);
      insert.Parameters.AddWithValue(definition.Contributions.SkillCoordinates.Count);
      insert.Parameters.AddWithValue(LevelCoordinateCount(definition));
      insert.Parameters.AddWithValue(EquipmentOptionCount(definition));
      insert.Parameters.AddWithValue(LegalLevelCount(definition));
      insert.Parameters.AddWithValue(OverloadBandCount(definition));
      insert.Parameters.AddWithValue(OverloadValueCount(definition));
      insert.Parameters.AddWithValue(Readiness(domain.IsSourceReady));
      insert.Parameters.AddWithValue(Readiness(domain.IsProfileSelectable));
      insert.Parameters.AddWithValue(Readiness(domain.IsGameLegalReady));
      insert.Parameters.AddWithValue(Readiness(domain.HasCompleteCombatSemantics));
      insert.Parameters.AddWithValue(Readiness(domain.IsDuplicatePolicyReady));
      insert.Parameters.AddWithValue(createdAt);
      id = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    await InsertDefinitionDetailAsync(
        context,
        id,
        entity.Id,
        definition,
        applicableCharacterUid,
        cancellationToken).ConfigureAwait(false);
    await InsertBulkChildrenAsync(
        context,
        id,
        entity.Id,
        definition,
        createdAt,
        cancellationToken).ConfigureAwait(false);
    return new StoredVersion(
        id,
        uid,
        domain.ContentSha256,
        domain.IsSourceReady,
        domain.IsProfileSelectable,
        domain.IsGameLegalReady,
        domain.HasCompleteCombatSemantics,
        domain.IsDuplicatePolicyReady);
  }

  private static async Task<StoredCharacter?> ResolveApplicableCharacterUidAsync(
      PostgreSqlCompletedImportContext context,
      CombatSupportDefinitionPublication definition,
      CancellationToken cancellationToken)
  {
    if (definition.Payload is not CombatSupportFavoriteDefinitionPublication favorite ||
        favorite.ApplicableCharacterAlias.Status == CombatSupportFactStatus.Unresolved)
    {
      return null;
    }

    var fingerprint = favorite.ApplicableCharacterAlias.Value!.Value.ToByteArray();
    try
    {
      await using var command = new NpgsqlCommand(
          """
          SELECT entity.character_entity_id, entity.character_uid
          FROM lab_private.character_source_alias AS alias
          JOIN lab_catalog.character_entity AS entity
            ON entity.character_entity_id = alias.character_entity_id
          WHERE alias.alias_fingerprint = $1;
          """,
          context.Connection,
          context.Transaction);
      command.Parameters.AddWithValue(fingerprint);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new CombatSupportCatalogIntegrityException("support_favorite_character_alias_missing");
      }

      var stored = new StoredCharacter(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new CombatSupportCatalogIntegrityException("support_favorite_character_alias_missing");
      }

      return stored;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(fingerprint);
    }
  }

  private static DomainProjection CreateDomainProjection(
      CombatSupportDefinitionPublication definition,
      StoredCharacter? applicableCharacter)
  {
    try
    {
      var content = ToDomainContent(definition, applicableCharacter);
      var gameLegalReady = content is CombatSupportDomain.OverloadOptionDefinitionContent overload
          ? overload.IsGameLegalReady
          : content.HasCompleteCombatSemantics;
      var duplicatePolicyReady = content is not CombatSupportDomain.OverloadOptionDefinitionContent option ||
          option.IsDuplicatePolicyReady;
      return new DomainProjection(
          CombatSupportDomain.CombatSupportDefinitionCanonicalizer.ComputeContentHash(content),
          definition.IsSourceReady,
          content.IsProfileSelectable,
          gameLegalReady,
          content.HasCompleteCombatSemantics,
          duplicatePolicyReady);
    }
    catch (CombatSupportCatalogIntegrityException)
    {
      throw;
    }
    catch (Exception exception) when (exception is ArgumentException or InvalidOperationException)
    {
      throw new CombatSupportCatalogIntegrityException("support_domain_publication_invalid");
    }
  }

  private static CombatSupportDomain.ICombatSupportDefinitionContent ToDomainContent(
      CombatSupportDefinitionPublication definition,
      StoredCharacter? applicableCharacter) => definition.Payload switch
      {
        CombatSupportEquipmentDefinitionPublication equipment =>
            new CombatSupportDomain.EquipmentDefinitionContent(
                ToDomainSlot(equipment.Slot),
                ToDomainCombatRoleFact(equipment.CombatClass),
                ToDomainManufacturerFact(equipment.Manufacturer),
                ToDomainIntFact(equipment.Tier),
                ToDomainIntFact(equipment.EnhancementGrade),
                ToDomainIntFact(equipment.MaximumEnhancementLevel),
                ToDomainBoolFact(equipment.OverloadEligible),
                ToDomainContributions(definition.Contributions.Contributions, 0),
                equipment.OptionSlots.Select(static slot =>
                    new CombatSupportDomain.CombatSupportEquipmentOptionSlot(
                        slot.Ordinal,
                        ToDomainExact(slot.SuccessRatio)))),
        CombatSupportCubeDefinitionPublication cube =>
            new CombatSupportDomain.HarmonyCubeDefinitionContent(
                ToDomainRarityFact(cube.Rarity),
                ToDomainCombatRoleFact(cube.ApplicableCombatClass),
                ToDomainIntFact(cube.MaximumLevel),
                ToDomainLevels(cube.Levels, definition.Contributions),
                ToDomainBoolFact(cube.SkillSemantics)),
        CombatSupportCollectionDefinitionPublication collection =>
            new CombatSupportDomain.GenericCollectionDefinitionContent(
                ToDomainWeaponFact(collection.WeaponClass),
                ToDomainRarityFact(collection.Rarity),
                ToDomainIntFact(collection.MaximumLevel),
                ToDomainLevels(collection.Levels, definition.Contributions),
                ToDomainBoolFact(collection.SkillSemantics)),
        CombatSupportFavoriteDefinitionPublication favorite =>
            new CombatSupportDomain.FavoriteDefinitionContent(
                ToDomainCharacterFact(favorite.ApplicableCharacterAlias, applicableCharacter),
                ToDomainRarityFact(favorite.Rarity),
                ToDomainIntFact(favorite.MaximumLevel),
                ToDomainLevels(favorite.Levels, definition.Contributions),
                ToDomainBoolFact(favorite.SkillSemantics)),
        CombatSupportConsoleDefinitionPublication console =>
            new CombatSupportDomain.ConsoleDefinitionContent(
                ToDomainConsoleCoordinate(console.Coordinate),
                ToDomainIntFact(console.MaximumLevel),
                console.LegalLevels.Select(static level =>
                    new CombatSupportDomain.CombatSupportLevelCoordinate(
                        level.Level,
                        CombatSupportDomain.CombatSupportFact<int>.NotApplicable(),
                        CombatSupportDomain.CombatSupportFact<int>.NotApplicable(),
                        [],
                        [],
                        CombatSupportDomain.CombatSupportFact<int>.Ready(
                            level.MinimumSynchroLevel))),
                ToDomainContributions(definition.Contributions.Contributions, 0)),
        CombatSupportOverloadOptionDefinitionPublication overload =>
            new CombatSupportDomain.OverloadOptionDefinitionContent(
                ToDomainOverloadOptionFact(overload.OptionType),
                ToDomainUnitFact(overload.Unit),
                ToDomainExact(overload.KindSelectionProbability),
                overload.LegalBands.Select(static band =>
                    new CombatSupportDomain.CombatSupportOverloadLegalBand(
                        band.Ordinal,
                        ToDomainExact(band.Probability),
                        band.OrderedValues.Select(static value =>
                            new CombatSupportDomain.CombatSupportOverloadLegalValue(
                                value.RollLevel,
                                value.SourceRawValue,
                                value.MagnitudeBasisPoints,
                                ToDomainExact(value.EngineFraction))))),
                ToDomainDuplicatePolicyFact(overload.DuplicatePolicy)),
        _ => throw new CombatSupportCatalogIntegrityException("support_payload_invalid")
      };

  private static IReadOnlyList<CombatSupportDomain.CombatSupportLevelCoordinate> ToDomainLevels(
      IReadOnlyList<CombatSupportLevelCoordinatePublication> levels,
      CombatSupportContributionSetPublication contributionSet)
  {
    var levelCodes = levels.Select(static item => item.Level).ToHashSet();
    if (contributionSet.Contributions.Any(item => !levelCodes.Contains(item.UnlockLevel)) ||
        contributionSet.SkillCoordinates.Any(item => !levelCodes.Contains(item.UnlockLevel)))
    {
      throw new CombatSupportCatalogIntegrityException("support_level_child_orphan");
    }

    return levels.Select(level =>
    {
      var skills = contributionSet.SkillCoordinates
          .Where(item => item.UnlockLevel == level.Level)
          .OrderBy(static item => item.SkillSlotOrdinal)
          .ToArray();
      if (!skills.Select(static item => item.SkillSlotOrdinal)
          .SequenceEqual(Enumerable.Range(0, skills.Length)))
      {
        throw new CombatSupportCatalogIntegrityException("support_skill_slot_set_invalid");
      }

      return new CombatSupportDomain.CombatSupportLevelCoordinate(
          level.Level,
          ToDomainIntFact(level.Grade),
          ToDomainIntFact(level.Capacity),
          skills.Select(static item => item.SkillLevel),
          ToDomainContributions(contributionSet.Contributions, level.Level),
          ToDomainIntFact(level.MinimumSynchroLevel));
    }).ToArray();
  }

  private static IReadOnlyList<CombatSupportDomain.CombatSupportStatContribution>
      ToDomainContributions(
          IReadOnlyList<CombatSupportStatContributionPublication> contributions,
          int unlockLevel) => contributions
      .Where(item => item.UnlockLevel == unlockLevel)
      .OrderBy(static item => item.Ordinal)
      .Select((item, ordinal) => new CombatSupportDomain.CombatSupportStatContribution(
          ordinal,
          ToDomainStatFact(item.Stat),
          ToDomainUnitFact(item.Unit),
          ToDomainExact(item.ExactValue)))
      .ToArray();

  private static CombatSupportDomain.CombatSupportEquipmentSlot ToDomainSlot(
      CombatSupportEquipmentSlot value) => value switch
      {
        CombatSupportEquipmentSlot.Head => CombatSupportDomain.CombatSupportEquipmentSlot.Head,
        CombatSupportEquipmentSlot.Torso => CombatSupportDomain.CombatSupportEquipmentSlot.Torso,
        CombatSupportEquipmentSlot.Arms => CombatSupportDomain.CombatSupportEquipmentSlot.Arms,
        CombatSupportEquipmentSlot.Legs => CombatSupportDomain.CombatSupportEquipmentSlot.Legs,
        _ => throw new CombatSupportCatalogIntegrityException("support_equipment_slot_invalid")
      };

  private static CombatSupportDomain.CombatSupportConsoleCoordinate ToDomainConsoleCoordinate(
      CombatSupportConsoleCoordinate value) => value switch
      {
        CombatSupportConsoleCoordinate.Common => CombatSupportDomain.CombatSupportConsoleCoordinate.Common,
        CombatSupportConsoleCoordinate.Attacker => CombatSupportDomain.CombatSupportConsoleCoordinate.Attacker,
        CombatSupportConsoleCoordinate.Defender => CombatSupportDomain.CombatSupportConsoleCoordinate.Defender,
        CombatSupportConsoleCoordinate.Supporter => CombatSupportDomain.CombatSupportConsoleCoordinate.Supporter,
        CombatSupportConsoleCoordinate.Elysion => CombatSupportDomain.CombatSupportConsoleCoordinate.Elysion,
        CombatSupportConsoleCoordinate.Missilis => CombatSupportDomain.CombatSupportConsoleCoordinate.Missilis,
        CombatSupportConsoleCoordinate.Tetra => CombatSupportDomain.CombatSupportConsoleCoordinate.Tetra,
        CombatSupportConsoleCoordinate.Pilgrim => CombatSupportDomain.CombatSupportConsoleCoordinate.Pilgrim,
        CombatSupportConsoleCoordinate.Abnormal => CombatSupportDomain.CombatSupportConsoleCoordinate.Abnormal,
        _ => throw new CombatSupportCatalogIntegrityException("support_console_coordinate_invalid")
      };

  private static CombatSupportDomain.CombatSupportFact<int> ToDomainIntFact(
      CombatSupportValueFact<int> fact) => fact.Status switch
      {
        CombatSupportFactStatus.Ready =>
            CombatSupportDomain.CombatSupportFact<int>.Ready(fact.Value!.Value),
        CombatSupportFactStatus.Unresolved =>
            CombatSupportDomain.CombatSupportFact<int>.Unresolved(fact.UnresolvedReasonCode!),
        CombatSupportFactStatus.NotApplicable =>
            CombatSupportDomain.CombatSupportFact<int>.NotApplicable(),
        _ => throw new CombatSupportCatalogIntegrityException("support_fact_status_invalid")
      };

  private static CombatSupportDomain.CombatSupportFact<bool> ToDomainBoolFact(
      CombatSupportValueFact<bool> fact) => fact.Status switch
      {
        CombatSupportFactStatus.Ready =>
            CombatSupportDomain.CombatSupportFact<bool>.Ready(fact.Value!.Value),
        CombatSupportFactStatus.Unresolved =>
            CombatSupportDomain.CombatSupportFact<bool>.Unresolved(fact.UnresolvedReasonCode!),
        CombatSupportFactStatus.NotApplicable =>
            CombatSupportDomain.CombatSupportFact<bool>.NotApplicable(),
        _ => throw new CombatSupportCatalogIntegrityException("support_fact_status_invalid")
      };

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportCombatRole>
      ToDomainCombatRoleFact(CombatSupportValueFact<CombatSupportCombatClass> fact) =>
      fact.Status switch
      {
        CombatSupportFactStatus.Ready =>
            CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportCombatRole>.Ready(
                fact.Value!.Value switch
                {
                  CombatSupportCombatClass.Attacker => CombatSupportDomain.CombatSupportCombatRole.Attacker,
                  CombatSupportCombatClass.Defender => CombatSupportDomain.CombatSupportCombatRole.Defender,
                  CombatSupportCombatClass.Supporter => CombatSupportDomain.CombatSupportCombatRole.Supporter,
                  _ => throw new CombatSupportCatalogIntegrityException("support_combat_class_invalid")
                }),
        CombatSupportFactStatus.Unresolved =>
            CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportCombatRole>
                .Unresolved(fact.UnresolvedReasonCode!),
        CombatSupportFactStatus.NotApplicable =>
            CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportCombatRole>
                .NotApplicable(),
        _ => throw new CombatSupportCatalogIntegrityException("support_fact_status_invalid")
      };

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportManufacturer>
      ToDomainManufacturerFact(CombatSupportValueFact<CombatSupportManufacturer> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportManufacturer.Abnormal => CombatSupportDomain.CombatSupportManufacturer.Abnormal,
        CombatSupportManufacturer.Elysion => CombatSupportDomain.CombatSupportManufacturer.Elysion,
        CombatSupportManufacturer.Missilis => CombatSupportDomain.CombatSupportManufacturer.Missilis,
        CombatSupportManufacturer.Pilgrim => CombatSupportDomain.CombatSupportManufacturer.Pilgrim,
        CombatSupportManufacturer.Tetra => CombatSupportDomain.CombatSupportManufacturer.Tetra,
        _ => throw new CombatSupportCatalogIntegrityException("support_manufacturer_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportWeaponClass>
      ToDomainWeaponFact(CombatSupportValueFact<CombatSupportWeaponClass> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportWeaponClass.AssaultRifle => CombatSupportDomain.CombatSupportWeaponClass.AssaultRifle,
        CombatSupportWeaponClass.MachineGun => CombatSupportDomain.CombatSupportWeaponClass.MachineGun,
        CombatSupportWeaponClass.RocketLauncher => CombatSupportDomain.CombatSupportWeaponClass.RocketLauncher,
        CombatSupportWeaponClass.Shotgun => CombatSupportDomain.CombatSupportWeaponClass.Shotgun,
        CombatSupportWeaponClass.SniperRifle => CombatSupportDomain.CombatSupportWeaponClass.SniperRifle,
        CombatSupportWeaponClass.SubmachineGun => CombatSupportDomain.CombatSupportWeaponClass.SubmachineGun,
        _ => throw new CombatSupportCatalogIntegrityException("support_weapon_class_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportRarity>
      ToDomainRarityFact(CombatSupportValueFact<CombatSupportRarity> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportRarity.R => CombatSupportDomain.CombatSupportRarity.R,
        CombatSupportRarity.Sr => CombatSupportDomain.CombatSupportRarity.Sr,
        CombatSupportRarity.Ssr => CombatSupportDomain.CombatSupportRarity.Ssr,
        _ => throw new CombatSupportCatalogIntegrityException("support_rarity_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportStat>
      ToDomainStatFact(CombatSupportValueFact<CombatSupportStat> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportStat.Attack => CombatSupportDomain.CombatSupportStat.Attack,
        CombatSupportStat.Defence => CombatSupportDomain.CombatSupportStat.Defence,
        CombatSupportStat.Hp => CombatSupportDomain.CombatSupportStat.Hp,
        CombatSupportStat.EnergyResistance => CombatSupportDomain.CombatSupportStat.EnergyResistance,
        CombatSupportStat.MetalResistance => CombatSupportDomain.CombatSupportStat.MetalResistance,
        CombatSupportStat.BioResistance => CombatSupportDomain.CombatSupportStat.BioResistance,
        _ => throw new CombatSupportCatalogIntegrityException("support_stat_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportValueUnit>
      ToDomainUnitFact(CombatSupportValueFact<CombatSupportValueUnit> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportValueUnit.Absolute => CombatSupportDomain.CombatSupportValueUnit.Absolute,
        CombatSupportValueUnit.Ratio => CombatSupportDomain.CombatSupportValueUnit.Ratio,
        CombatSupportValueUnit.Percent => CombatSupportDomain.CombatSupportValueUnit.Percent,
        CombatSupportValueUnit.Count => CombatSupportDomain.CombatSupportValueUnit.Count,
        _ => throw new CombatSupportCatalogIntegrityException("support_value_unit_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportOverloadOptionType>
      ToDomainOverloadOptionFact(CombatSupportValueFact<CombatSupportOverloadOptionType> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportOverloadOptionType.Attack => CombatSupportDomain.CombatSupportOverloadOptionType.Attack,
        CombatSupportOverloadOptionType.Defence => CombatSupportDomain.CombatSupportOverloadOptionType.Defence,
        CombatSupportOverloadOptionType.MaximumAmmunition => CombatSupportDomain.CombatSupportOverloadOptionType.MaximumAmmunition,
        CombatSupportOverloadOptionType.CriticalRate => CombatSupportDomain.CombatSupportOverloadOptionType.CriticalRate,
        CombatSupportOverloadOptionType.CriticalDamage => CombatSupportDomain.CombatSupportOverloadOptionType.CriticalDamage,
        CombatSupportOverloadOptionType.ChargeDamage => CombatSupportDomain.CombatSupportOverloadOptionType.ChargeDamage,
        CombatSupportOverloadOptionType.ChargeSpeed => CombatSupportDomain.CombatSupportOverloadOptionType.ChargeSpeed,
        CombatSupportOverloadOptionType.ElementalDamage => CombatSupportDomain.CombatSupportOverloadOptionType.ElementalDamage,
        CombatSupportOverloadOptionType.HitRate => CombatSupportDomain.CombatSupportOverloadOptionType.HitRate,
        _ => throw new CombatSupportCatalogIntegrityException("support_overload_option_type_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<CombatSupportDomain.CombatSupportOverloadDuplicatePolicy>
      ToDomainDuplicatePolicyFact(
          CombatSupportValueFact<CombatSupportOverloadDuplicatePolicy> fact) =>
      MapEnumFact(fact, static value => value switch
      {
        CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment =>
            CombatSupportDomain.CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment,
        CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment =>
            CombatSupportDomain.CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment,
        _ => throw new CombatSupportCatalogIntegrityException("support_overload_duplicate_policy_invalid")
      });

  private static CombatSupportDomain.CombatSupportFact<EntityUid> ToDomainCharacterFact(
      CombatSupportValueFact<SourceAliasFingerprint> fact,
      StoredCharacter? storedCharacter) => fact.Status switch
      {
        CombatSupportFactStatus.Ready when storedCharacter is not null =>
            CombatSupportDomain.CombatSupportFact<EntityUid>.Ready(storedCharacter.Uid),
        CombatSupportFactStatus.Unresolved =>
            CombatSupportDomain.CombatSupportFact<EntityUid>.Unresolved(fact.UnresolvedReasonCode!),
        _ => throw new CombatSupportCatalogIntegrityException("support_favorite_character_invalid")
      };

  private static CombatSupportDomain.CombatSupportFact<TDomain> MapEnumFact<TSource, TDomain>(
      CombatSupportValueFact<TSource> fact,
      Func<TSource, TDomain> map)
      where TSource : struct
      where TDomain : struct => fact.Status switch
      {
        CombatSupportFactStatus.Ready =>
            CombatSupportDomain.CombatSupportFact<TDomain>.Ready(map(fact.Value!.Value)),
        CombatSupportFactStatus.Unresolved =>
            CombatSupportDomain.CombatSupportFact<TDomain>.Unresolved(fact.UnresolvedReasonCode!),
        CombatSupportFactStatus.NotApplicable =>
            CombatSupportDomain.CombatSupportFact<TDomain>.NotApplicable(),
        _ => throw new CombatSupportCatalogIntegrityException("support_fact_status_invalid")
      };

  private static CombatSupportDomain.CombatSupportExactValue ToDomainExact(
      CombatSupportExactValue value) => new(value.UnscaledValue, value.DecimalScale);

  private static int LevelCoordinateCount(CombatSupportDefinitionPublication definition) =>
      definition.Payload switch
      {
        CombatSupportCubeDefinitionPublication cube => cube.Levels.Count,
        CombatSupportCollectionDefinitionPublication collection => collection.Levels.Count,
        CombatSupportFavoriteDefinitionPublication favorite => favorite.Levels.Count,
        _ => 0
      };

  private static int EquipmentOptionCount(CombatSupportDefinitionPublication definition) =>
      definition.Payload is CombatSupportEquipmentDefinitionPublication equipment
          ? equipment.OptionSlots.Count
          : 0;

  private static int LegalLevelCount(CombatSupportDefinitionPublication definition) =>
      definition.Payload is CombatSupportConsoleDefinitionPublication console
          ? console.LegalLevels.Count
          : 0;

  private static int OverloadBandCount(CombatSupportDefinitionPublication definition) =>
      definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload
          ? overload.LegalBands.Count
          : 0;

  private static int OverloadValueCount(CombatSupportDefinitionPublication definition) =>
      definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload
          ? overload.LegalBands.Sum(static band => band.OrderedValues.Count)
          : 0;

  private static string Readiness(bool isReady) => isReady ? "ready" : "unresolved";

  private static CombatSupportDomain.CombatSupportDefinitionKind ToDomainKind(
      CombatSupportDefinitionKind kind) => kind switch
      {
        CombatSupportDefinitionKind.Equipment => CombatSupportDomain.CombatSupportDefinitionKind.Equipment,
        CombatSupportDefinitionKind.Cube => CombatSupportDomain.CombatSupportDefinitionKind.HarmonyCube,
        CombatSupportDefinitionKind.Collection => CombatSupportDomain.CombatSupportDefinitionKind.GenericCollection,
        CombatSupportDefinitionKind.Favorite => CombatSupportDomain.CombatSupportDefinitionKind.Favorite,
        CombatSupportDefinitionKind.Console => CombatSupportDomain.CombatSupportDefinitionKind.Console,
        CombatSupportDefinitionKind.OverloadOption => CombatSupportDomain.CombatSupportDefinitionKind.OverloadOption,
        _ => throw new CombatSupportCatalogIntegrityException("support_definition_kind_invalid")
      };

  private static CombatSupportCatalogMemberReceipt ToReceipt(StoredMember member) => new(
      member.Ordinal,
      member.Kind,
      member.EntityUid,
      member.VersionUid,
      member.DomainContentSha256,
      member.IsSourceReady,
      member.IsProfileSelectable,
      member.IsGameLegalReady,
      member.HasCompleteCombatSemantics,
      member.IsDuplicatePolicyReady);

  private static void AddTextFact(NpgsqlCommand command, CombatSupportTextFact fact)
  {
    command.Parameters.AddWithValue(CombatSupportPublicationCodes.FactStatus(fact.Status));
    command.Parameters.AddWithValue((object?)fact.Value ?? DBNull.Value);
    command.Parameters.AddWithValue((object?)fact.UnresolvedReasonCode ?? DBNull.Value);
  }

  private static void AddFact<T>(
      NpgsqlCommand command,
      CombatSupportValueFact<T> fact,
      Func<T, object> convert)
      where T : struct
  {
    command.Parameters.AddWithValue(CombatSupportPublicationCodes.FactStatus(fact.Status));
    command.Parameters.AddWithValue(
        fact.Value is { } value ? convert(value) : DBNull.Value);
    command.Parameters.AddWithValue((object?)fact.UnresolvedReasonCode ?? DBNull.Value);
  }

  private async Task<StoredCatalog> ResolveCatalogAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      Sha256Digest manifestSha256,
      int memberCount,
      CancellationToken cancellationToken)
  {
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT catalog_snapshot_id, catalog_snapshot_uid,
                            dataset_snapshot_id, output_manifest_sha256,
                            catalog_manifest_sha256, member_count
                     FROM lab_combat_support.catalog_snapshot
                     WHERE request_sha256 = $1;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      read.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var stored = new StoredCatalog(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
        if (reader.GetInt64(2) != context.DatasetSnapshotId ||
            !((byte[])reader[3]).AsSpan().SequenceEqual(attempt.OutputManifestSha256.ToByteArray()) ||
            !((byte[])reader[4]).AsSpan().SequenceEqual(manifestSha256.ToByteArray()) ||
            reader.GetInt32(5) != memberCount ||
            await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          throw new CombatSupportCatalogIntegrityException("support_catalog_provenance_mismatch");
        }

        return stored;
      }
    }

    if (context.IsReusedImport)
    {
      throw new CombatSupportCatalogIntegrityException("support_reused_import_missing_publication");
    }

    var uid = _uidGenerator.NewUid();
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.catalog_snapshot
            (catalog_snapshot_uid, dataset_snapshot_id, request_sha256,
             output_manifest_sha256, catalog_manifest_sha256,
             published_by_import_run_id, member_count, created_at_utc)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        RETURNING catalog_snapshot_id;
        """,
        context.Connection,
        context.Transaction);
    insert.Parameters.AddWithValue(uid.Value);
    insert.Parameters.AddWithValue(context.DatasetSnapshotId);
    insert.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
    insert.Parameters.AddWithValue(attempt.OutputManifestSha256.ToByteArray());
    insert.Parameters.AddWithValue(manifestSha256.ToByteArray());
    insert.Parameters.AddWithValue(context.ImportRunId);
    insert.Parameters.AddWithValue(memberCount);
    insert.Parameters.AddWithValue(attempt.FinishedAtUtc);
    var id = Convert.ToInt64(
        await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
    return new StoredCatalog(id, uid);
  }

  private static async Task ResolveCatalogMembersAsync(
      PostgreSqlCompletedImportContext context,
      long catalogId,
      IReadOnlyList<StoredMember> expectedMembers,
      CancellationToken cancellationToken)
  {
    var existing = await ReadCatalogMembersAsync(
        context,
        catalogId,
        cancellationToken).ConfigureAwait(false);
    if (existing.Count == 0)
    {
      await using (var importer = await context.Connection.BeginBinaryImportAsync(
                       """
                       COPY lab_combat_support.catalog_snapshot_member
                           (catalog_snapshot_id, definition_entity_id, definition_version_id,
                            definition_kind, ordinal)
                       FROM STDIN (FORMAT BINARY)
                       """,
                       cancellationToken).ConfigureAwait(false))
      {
        foreach (var member in expectedMembers.OrderBy(static item => item.Ordinal))
        {
          await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
          await importer.WriteAsync(catalogId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
          await importer.WriteAsync(member.EntityId, NpgsqlDbType.Bigint, cancellationToken)
              .ConfigureAwait(false);
          await importer.WriteAsync(member.VersionId, NpgsqlDbType.Bigint, cancellationToken)
              .ConfigureAwait(false);
          await importer.WriteAsync(
              CombatSupportPublicationCodes.DefinitionKind(member.Kind),
              NpgsqlDbType.Text,
              cancellationToken).ConfigureAwait(false);
          await importer.WriteAsync(member.Ordinal, NpgsqlDbType.Integer, cancellationToken)
              .ConfigureAwait(false);
        }

        await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
      }

      existing = await ReadCatalogMembersAsync(
          context,
          catalogId,
          cancellationToken).ConfigureAwait(false);
    }

    if (existing.Count != expectedMembers.Count)
    {
      throw new CombatSupportCatalogIntegrityException("support_catalog_membership_mismatch");
    }

    for (var index = 0; index < expectedMembers.Count; index++)
    {
      var expected = expectedMembers[index];
      var actual = existing[index];
      if (actual != expected)
      {
        throw new CombatSupportCatalogIntegrityException("support_catalog_membership_mismatch");
      }
    }

    var storedManifest = CombatSupportDomain.CombatSupportCatalogManifest.Create(
        context.DatasetSnapshotUid,
        existing.Select(static member => new CombatSupportDomain.CombatSupportCatalogManifestEntry(
            ToDomainKind(member.Kind),
            member.EntityUid,
            member.DomainContentSha256,
            member.IsProfileSelectable,
            member.HasCompleteCombatSemantics)));
    var expectedManifest = CombatSupportDomain.CombatSupportCatalogManifest.Create(
        context.DatasetSnapshotUid,
        expectedMembers.Select(static member => new CombatSupportDomain.CombatSupportCatalogManifestEntry(
            ToDomainKind(member.Kind),
            member.EntityUid,
            member.DomainContentSha256,
            member.IsProfileSelectable,
            member.HasCompleteCombatSemantics)));
    if (storedManifest.Sha256 != expectedManifest.Sha256)
    {
      throw new CombatSupportCatalogIntegrityException("support_catalog_manifest_mismatch");
    }
  }

  private static async Task<List<StoredMember>> ReadCatalogMembersAsync(
      PostgreSqlCompletedImportContext context,
      long catalogId,
      CancellationToken cancellationToken)
  {
    var result = new List<StoredMember>();
    await using var command = new NpgsqlCommand(
        """
        SELECT member.ordinal, entity.definition_entity_id, entity.definition_uid,
               version.definition_version_id, version.definition_version_uid,
               version.definition_kind, version.domain_canonical_sha256,
               version.source_readiness_status, version.profile_selectable_status,
               version.game_legal_readiness_status,
               version.complete_semantics_status,
               version.duplicate_policy_readiness_status
        FROM lab_combat_support.catalog_snapshot_member AS member
        JOIN lab_combat_support.definition_entity AS entity
          ON entity.definition_entity_id = member.definition_entity_id
        JOIN lab_combat_support.definition_version AS version
          ON version.definition_version_id = member.definition_version_id
        WHERE member.catalog_snapshot_id = $1
        ORDER BY member.ordinal;
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(catalogId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      result.Add(new StoredMember(
          reader.GetInt32(0),
          reader.GetInt64(1),
          new EntityUid(reader.GetGuid(2)),
          reader.GetInt64(3),
          new EntityUid(reader.GetGuid(4)),
          ParseKind(reader.GetString(5)),
          Sha256Digest.FromBytes((byte[])reader[6]),
          IsReady(reader.GetString(7)),
          IsReady(reader.GetString(8)),
          IsReady(reader.GetString(9)),
          IsReady(reader.GetString(10)),
          IsReady(reader.GetString(11))));
    }

    return result;
  }

  private static async Task ResolveImportProjectionAsync(
      PostgreSqlCompletedImportContext context,
      long catalogId,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_combat_support.catalog_import_projection
                         (import_run_id, catalog_snapshot_id, created_at_utc)
                     VALUES ($1, $2, $3)
                     ON CONFLICT (import_run_id) DO NOTHING;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      insert.Parameters.AddWithValue(context.ImportRunId);
      insert.Parameters.AddWithValue(catalogId);
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var read = new NpgsqlCommand(
        """
        SELECT catalog_snapshot_id
        FROM lab_combat_support.catalog_import_projection
        WHERE import_run_id = $1;
        """,
        context.Connection,
        context.Transaction);
    read.Parameters.AddWithValue(context.ImportRunId);
    var value = await read.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null || Convert.ToInt64(value, CultureInfo.InvariantCulture) != catalogId)
    {
      throw new CombatSupportCatalogIntegrityException("support_import_projection_mismatch");
    }
  }

  private static bool IsReady(string value) => value switch
  {
    "ready" => true,
    "unresolved" => false,
    _ => throw new CombatSupportCatalogIntegrityException("support_readiness_invalid")
  };

  private static CombatSupportDefinitionKind ParseKind(string value) => value switch
  {
    "equipment" => CombatSupportDefinitionKind.Equipment,
    "cube" => CombatSupportDefinitionKind.Cube,
    "collection" => CombatSupportDefinitionKind.Collection,
    "favorite" => CombatSupportDefinitionKind.Favorite,
    "console" => CombatSupportDefinitionKind.Console,
    "overload_option" => CombatSupportDefinitionKind.OverloadOption,
    _ => throw new CombatSupportCatalogIntegrityException("support_definition_kind_invalid")
  };

  private static async Task InsertDefinitionDetailAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportDefinitionPublication definition,
      StoredCharacter? applicableCharacter,
      CancellationToken cancellationToken)
  {
    await using var command = definition.Payload switch
    {
      CombatSupportEquipmentDefinitionPublication equipment =>
          CreateEquipmentDetailCommand(context, versionId, entityId, equipment),
      CombatSupportCubeDefinitionPublication cube =>
          CreateCubeDetailCommand(context, versionId, entityId, cube),
      CombatSupportCollectionDefinitionPublication collection =>
          CreateCollectionDetailCommand(context, versionId, entityId, collection),
      CombatSupportFavoriteDefinitionPublication favorite =>
          CreateFavoriteDetailCommand(
              context,
              versionId,
              entityId,
              favorite,
              applicableCharacter),
      CombatSupportConsoleDefinitionPublication console =>
          CreateConsoleDetailCommand(context, versionId, entityId, console),
      CombatSupportOverloadOptionDefinitionPublication overload =>
          CreateOverloadDetailCommand(context, versionId, entityId, overload),
      _ => throw new CombatSupportCatalogIntegrityException("support_payload_invalid")
    };
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw new CombatSupportCatalogIntegrityException("support_definition_detail_missing");
    }
  }

  private static NpgsqlCommand CreateEquipmentDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportEquipmentDefinitionPublication equipment)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.equipment_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             equipment_slot, combat_class_status, combat_class_code,
             combat_class_unresolved_reason_code, manufacturer_status,
             manufacturer_code, manufacturer_unresolved_reason_code,
             tier_status, tier_value, tier_unresolved_reason_code,
             enhancement_grade_status, enhancement_grade,
             enhancement_grade_unresolved_reason_code,
             enhancement_status, maximum_enhancement_level,
             enhancement_unresolved_reason_code, overload_eligible_status,
             overload_eligible, overload_eligible_unresolved_reason_code)
        VALUES ($1, $2, 'equipment', $3, $4, $5, $6, $7, $8, $9,
                $10, $11, $12, $13, $14, $15, $16, $17, $18,
                $19, $20, $21);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    command.Parameters.AddWithValue(CombatSupportPublicationCodes.EquipmentSlot(equipment.Slot));
    AddFact(command, equipment.CombatClass, static value =>
        CombatSupportPublicationCodes.CombatClass(value));
    AddFact(command, equipment.Manufacturer, static value =>
        CombatSupportPublicationCodes.Manufacturer(value));
    AddFact(command, equipment.Tier, static value => value);
    AddFact(command, equipment.EnhancementGrade, static value => value);
    AddFact(command, equipment.MaximumEnhancementLevel, static value => value);
    AddFact(command, equipment.OverloadEligible, static value => value);
    return command;
  }

  private static NpgsqlCommand CreateCubeDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportCubeDefinitionPublication cube)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.cube_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             rarity_status, rarity_code, rarity_unresolved_reason_code,
             applicable_combat_class_status, applicable_combat_class_code,
             applicable_combat_class_unresolved_reason_code,
             maximum_level_status, maximum_level, maximum_level_unresolved_reason_code,
             skill_semantics_status, skill_semantics,
             skill_semantics_unresolved_reason_code)
        VALUES ($1, $2, 'cube', $3, $4, $5, $6, $7, $8,
                $9, $10, $11, $12, $13, $14);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    AddFact(command, cube.Rarity, static value => CombatSupportPublicationCodes.Rarity(value));
    AddFact(command, cube.ApplicableCombatClass, static value =>
        CombatSupportPublicationCodes.CombatClass(value));
    AddFact(command, cube.MaximumLevel, static value => value);
    AddFact(command, cube.SkillSemantics, static value => value);
    return command;
  }

  private static NpgsqlCommand CreateCollectionDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportCollectionDefinitionPublication collection)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.collection_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             weapon_class_status, weapon_class_code,
             weapon_class_unresolved_reason_code, rarity_status, rarity_code,
             rarity_unresolved_reason_code, maximum_level_status,
             maximum_level, maximum_level_unresolved_reason_code,
             skill_semantics_status, skill_semantics,
             skill_semantics_unresolved_reason_code)
        VALUES ($1, $2, 'collection', $3, $4, $5, $6, $7, $8,
                $9, $10, $11, $12, $13, $14);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    AddFact(command, collection.WeaponClass, static value =>
        CombatSupportPublicationCodes.WeaponClass(value));
    AddFact(command, collection.Rarity, static value =>
        CombatSupportPublicationCodes.Rarity(value));
    AddFact(command, collection.MaximumLevel, static value => value);
    AddFact(command, collection.SkillSemantics, static value => value);
    return command;
  }

  private static NpgsqlCommand CreateFavoriteDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportFavoriteDefinitionPublication favorite,
      StoredCharacter? applicableCharacter)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.favorite_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             maximum_level_status, maximum_level,
             maximum_level_unresolved_reason_code, rarity_status, rarity_code,
             rarity_unresolved_reason_code, applicable_character_status,
             applicable_character_entity_id, applicable_character_unresolved_reason_code,
             skill_semantics_status, skill_semantics,
             skill_semantics_unresolved_reason_code)
        VALUES ($1, $2, 'favorite', $3, $4, $5, $6, $7, $8,
                $9, $10, $11, $12, $13, $14);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    AddFact(command, favorite.MaximumLevel, static value => value);
    AddFact(command, favorite.Rarity, static value => CombatSupportPublicationCodes.Rarity(value));
    command.Parameters.AddWithValue(
        CombatSupportPublicationCodes.FactStatus(favorite.ApplicableCharacterAlias.Status));
    command.Parameters.AddWithValue((object?)applicableCharacter?.Id ?? DBNull.Value);
    command.Parameters.AddWithValue(
        (object?)favorite.ApplicableCharacterAlias.UnresolvedReasonCode ?? DBNull.Value);
    AddFact(command, favorite.SkillSemantics, static value => value);
    return command;
  }

  private static NpgsqlCommand CreateConsoleDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportConsoleDefinitionPublication console)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.console_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             coordinate_code, maximum_level_status, maximum_level,
             maximum_level_unresolved_reason_code)
        VALUES ($1, $2, 'console', $3, $4, $5, $6);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    command.Parameters.AddWithValue(CombatSupportPublicationCodes.ConsoleCoordinate(console.Coordinate));
    AddFact(command, console.MaximumLevel, static value => value);
    return command;
  }

  private static NpgsqlCommand CreateOverloadDetailCommand(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportOverloadOptionDefinitionPublication overload)
  {
    var command = new NpgsqlCommand(
        """
        INSERT INTO lab_combat_support.overload_option_definition_detail
            (definition_version_id, definition_entity_id, definition_kind,
             option_type_status, option_type_code,
             option_type_unresolved_reason_code, unit_status, unit_code,
             unit_unresolved_reason_code, kind_probability_unscaled_value,
             kind_probability_decimal_scale, duplicate_policy_status,
             duplicate_policy_code, duplicate_policy_unresolved_reason_code)
        VALUES ($1, $2, 'overload_option', $3, $4, $5, $6, $7, $8,
                $9, $10, $11, $12, $13);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(entityId);
    AddFact(command, overload.OptionType, static value =>
        CombatSupportPublicationCodes.OverloadOptionType(value));
    AddFact(command, overload.Unit, static value =>
        CombatSupportPublicationCodes.ValueUnit(value));
    command.Parameters.AddWithValue(overload.KindSelectionProbability.UnscaledValue);
    command.Parameters.AddWithValue(overload.KindSelectionProbability.DecimalScale);
    AddFact(command, overload.DuplicatePolicy, static value =>
        CombatSupportPublicationCodes.OverloadDuplicatePolicy(value));
    return command;
  }

  private static async Task InsertBulkChildrenAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      CombatSupportDefinitionPublication definition,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await InsertContributionsAsync(
        context,
        versionId,
        definition.Contributions.Contributions,
        cancellationToken).ConfigureAwait(false);
    await InsertSkillCoordinatesAsync(
        context,
        versionId,
        definition.Contributions.SkillCoordinates,
        cancellationToken).ConfigureAwait(false);
    await InsertLevelCoordinatesAsync(
        context,
        versionId,
        GetLevelCoordinates(definition),
        cancellationToken).ConfigureAwait(false);

    if (definition.Payload is CombatSupportEquipmentDefinitionPublication equipment)
    {
      await InsertEquipmentOptionsAsync(
          context,
          versionId,
          equipment.OptionSlots,
          cancellationToken).ConfigureAwait(false);
    }

    if (definition.Payload is CombatSupportConsoleDefinitionPublication console)
    {
      await InsertConsoleLevelsAsync(
          context,
          versionId,
          console.LegalLevels,
          cancellationToken).ConfigureAwait(false);
    }

    if (definition.Payload is CombatSupportOverloadOptionDefinitionPublication overload)
    {
      await InsertOverloadLegalValuesAsync(
          context,
          versionId,
          entityId,
          overload.LegalBands,
          createdAt,
          cancellationToken).ConfigureAwait(false);
    }
  }

  private static IReadOnlyList<CombatSupportLevelCoordinatePublication> GetLevelCoordinates(
      CombatSupportDefinitionPublication definition) => definition.Payload switch
      {
        CombatSupportCubeDefinitionPublication cube => cube.Levels,
        CombatSupportCollectionDefinitionPublication collection => collection.Levels,
        CombatSupportFavoriteDefinitionPublication favorite => favorite.Levels,
        _ => []
      };

  private static async Task InsertContributionsAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      IReadOnlyList<CombatSupportStatContributionPublication> contributions,
      CancellationToken cancellationToken)
  {
    if (contributions.Count == 0)
    {
      return;
    }

    await using var importer = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_combat_support.definition_stat_contribution
            (definition_version_id, ordinal, unlock_level,
             stat_status, stat_code, stat_unresolved_reason_code,
             unit_status, unit_code, unit_unresolved_reason_code,
             exact_unscaled_value, exact_decimal_scale)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var contribution in contributions.OrderBy(static item => item.Ordinal))
    {
      await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(contribution.Ordinal, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(contribution.UnlockLevel, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await WriteFactAsync(
          importer,
          contribution.Stat,
          CombatSupportPublicationCodes.Stat,
          cancellationToken).ConfigureAwait(false);
      await WriteFactAsync(
          importer,
          contribution.Unit,
          CombatSupportPublicationCodes.ValueUnit,
          cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(
          contribution.ExactValue.UnscaledValue,
          NpgsqlDbType.Bigint,
          cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(
          (short)contribution.ExactValue.DecimalScale,
          NpgsqlDbType.Smallint,
          cancellationToken).ConfigureAwait(false);
    }

    await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertSkillCoordinatesAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      IReadOnlyList<CombatSupportSkillCoordinatePublication> coordinates,
      CancellationToken cancellationToken)
  {
    if (coordinates.Count == 0)
    {
      return;
    }

    await using var importer = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_combat_support.definition_skill_coordinate
            (definition_version_id, ordinal, unlock_level,
             skill_slot_ordinal, skill_level)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var coordinate in coordinates.OrderBy(static item => item.Ordinal))
    {
      await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(coordinate.Ordinal, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(coordinate.UnlockLevel, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(coordinate.SkillSlotOrdinal, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(coordinate.SkillLevel, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
    }

    await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertLevelCoordinatesAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      IReadOnlyList<CombatSupportLevelCoordinatePublication> levels,
      CancellationToken cancellationToken)
  {
    if (levels.Count == 0)
    {
      return;
    }

    await using var importer = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_combat_support.definition_level_coordinate
            (definition_version_id, level, grade_status, grade_value,
             grade_unresolved_reason_code, capacity_status, capacity_value,
             capacity_unresolved_reason_code, minimum_synchro_status,
             minimum_synchro_level, minimum_synchro_unresolved_reason_code)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var level in levels.OrderBy(static item => item.Level))
    {
      await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(level.Level, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await WriteFactAsync(importer, level.Grade, static value => value, cancellationToken)
          .ConfigureAwait(false);
      await WriteFactAsync(importer, level.Capacity, static value => value, cancellationToken)
          .ConfigureAwait(false);
      await WriteFactAsync(importer, level.MinimumSynchroLevel, static value => value, cancellationToken)
          .ConfigureAwait(false);
    }

    await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertEquipmentOptionsAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      IReadOnlyList<CombatSupportEquipmentOptionSlotPublication> slots,
      CancellationToken cancellationToken)
  {
    if (slots.Count == 0)
    {
      return;
    }

    await using var importer = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_combat_support.equipment_option_slot
            (definition_version_id, ordinal, success_ratio_unscaled_value,
             success_ratio_decimal_scale)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var slot in slots.OrderBy(static item => item.Ordinal))
    {
      await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(slot.Ordinal, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(slot.SuccessRatio.UnscaledValue, NpgsqlDbType.Bigint, cancellationToken)
          .ConfigureAwait(false);
      await importer.WriteAsync((short)slot.SuccessRatio.DecimalScale, NpgsqlDbType.Smallint, cancellationToken)
          .ConfigureAwait(false);
    }

    await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertConsoleLevelsAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      IReadOnlyList<CombatSupportConsoleLevelPublication> levels,
      CancellationToken cancellationToken)
  {
    if (levels.Count == 0)
    {
      return;
    }

    await using var importer = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_combat_support.console_legal_level
            (definition_version_id, ordinal, level, minimum_synchro_level)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var level in levels.OrderBy(static item => item.Ordinal))
    {
      await importer.StartRowAsync(cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(level.Ordinal, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(level.Level, NpgsqlDbType.Integer, cancellationToken).ConfigureAwait(false);
      await importer.WriteAsync(level.MinimumSynchroLevel, NpgsqlDbType.Integer, cancellationToken)
          .ConfigureAwait(false);
    }

    await importer.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertOverloadLegalValuesAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      long entityId,
      IReadOnlyList<CombatSupportOverloadLegalBandPublication> bands,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    if (bands.Count == 0)
    {
      return;
    }

    await using (var bandImporter = await context.Connection.BeginBinaryImportAsync(
                     """
                     COPY lab_combat_support.overload_legal_band
                         (definition_version_id, ordinal, probability_unscaled_value,
                          probability_decimal_scale)
                     FROM STDIN (FORMAT BINARY)
                     """,
                     cancellationToken).ConfigureAwait(false))
    {
      foreach (var band in bands.OrderBy(static item => item.Ordinal))
      {
        await bandImporter.StartRowAsync(cancellationToken).ConfigureAwait(false);
        await bandImporter.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken)
            .ConfigureAwait(false);
        await bandImporter.WriteAsync(band.Ordinal, NpgsqlDbType.Integer, cancellationToken)
            .ConfigureAwait(false);
        await bandImporter.WriteAsync(
            band.Probability.UnscaledValue,
            NpgsqlDbType.Bigint,
            cancellationToken).ConfigureAwait(false);
        await bandImporter.WriteAsync(
            (short)band.Probability.DecimalScale,
            NpgsqlDbType.Smallint,
            cancellationToken).ConfigureAwait(false);
      }

      await bandImporter.CompleteAsync(cancellationToken).ConfigureAwait(false);
    }

    await using (var valueImporter = await context.Connection.BeginBinaryImportAsync(
                     """
                     COPY lab_combat_support.overload_legal_value
                         (definition_version_id, band_ordinal, value_ordinal,
                          roll_level, source_raw_value, magnitude_basis_points,
                          engine_fraction_unscaled_value,
                          engine_fraction_decimal_scale)
                     FROM STDIN (FORMAT BINARY)
                     """,
                     cancellationToken).ConfigureAwait(false))
    {
      foreach (var band in bands.OrderBy(static item => item.Ordinal))
      {
        for (var valueOrdinal = 0; valueOrdinal < band.OrderedValues.Count; valueOrdinal++)
        {
          var value = band.OrderedValues[valueOrdinal];
          await valueImporter.StartRowAsync(cancellationToken).ConfigureAwait(false);
          await valueImporter.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken)
              .ConfigureAwait(false);
          await valueImporter.WriteAsync(band.Ordinal, NpgsqlDbType.Integer, cancellationToken)
              .ConfigureAwait(false);
          await valueImporter.WriteAsync(valueOrdinal, NpgsqlDbType.Integer, cancellationToken)
              .ConfigureAwait(false);
          await valueImporter.WriteAsync(value.RollLevel, NpgsqlDbType.Integer, cancellationToken)
              .ConfigureAwait(false);
          await valueImporter.WriteAsync(value.SourceRawValue, NpgsqlDbType.Bigint, cancellationToken)
              .ConfigureAwait(false);
          await valueImporter.WriteAsync(
              value.MagnitudeBasisPoints,
              NpgsqlDbType.Integer,
              cancellationToken).ConfigureAwait(false);
          await valueImporter.WriteAsync(
              value.EngineFraction.UnscaledValue,
              NpgsqlDbType.Bigint,
              cancellationToken).ConfigureAwait(false);
          await valueImporter.WriteAsync(
              (short)value.EngineFraction.DecimalScale,
              NpgsqlDbType.Smallint,
              cancellationToken).ConfigureAwait(false);
        }
      }

      await valueImporter.CompleteAsync(cancellationToken).ConfigureAwait(false);
    }

    await using var aliasImporter = await context.Connection.BeginBinaryImportAsync(
        """
        COPY lab_private.overload_legal_value_source_alias
            (alias_fingerprint, definition_entity_id, definition_version_id,
             roll_level, created_at_utc)
        FROM STDIN (FORMAT BINARY)
        """,
        cancellationToken).ConfigureAwait(false);
    foreach (var value in bands.SelectMany(static band => band.OrderedValues)
                 .OrderBy(static item => item.RollLevel))
    {
      var fingerprint = value.SourceAliasFingerprint.ToByteArray();
      try
      {
        await aliasImporter.StartRowAsync(cancellationToken).ConfigureAwait(false);
        await aliasImporter.WriteAsync(fingerprint, NpgsqlDbType.Bytea, cancellationToken)
            .ConfigureAwait(false);
        await aliasImporter.WriteAsync(entityId, NpgsqlDbType.Bigint, cancellationToken)
            .ConfigureAwait(false);
        await aliasImporter.WriteAsync(versionId, NpgsqlDbType.Bigint, cancellationToken)
            .ConfigureAwait(false);
        await aliasImporter.WriteAsync(value.RollLevel, NpgsqlDbType.Integer, cancellationToken)
            .ConfigureAwait(false);
        await aliasImporter.WriteAsync(createdAt, NpgsqlDbType.TimestampTz, cancellationToken)
            .ConfigureAwait(false);
      }
      finally
      {
        CryptographicOperations.ZeroMemory(fingerprint);
      }
    }

    await aliasImporter.CompleteAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async ValueTask WriteFactAsync<T>(
      NpgsqlBinaryImporter importer,
      CombatSupportValueFact<T> fact,
      Func<T, object> convert,
      CancellationToken cancellationToken)
      where T : struct
  {
    await importer.WriteAsync(
        CombatSupportPublicationCodes.FactStatus(fact.Status),
        NpgsqlDbType.Text,
        cancellationToken).ConfigureAwait(false);
    if (fact.Value is { } value)
    {
      await WriteObjectAsync(importer, convert(value), cancellationToken).ConfigureAwait(false);
    }
    else
    {
      await importer.WriteNullAsync(cancellationToken).ConfigureAwait(false);
    }

    if (fact.UnresolvedReasonCode is { } reason)
    {
      await importer.WriteAsync(reason, NpgsqlDbType.Text, cancellationToken).ConfigureAwait(false);
    }
    else
    {
      await importer.WriteNullAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static Task WriteObjectAsync(
      NpgsqlBinaryImporter importer,
      object value,
      CancellationToken cancellationToken) => value switch
      {
        int integer => importer.WriteAsync(integer, NpgsqlDbType.Integer, cancellationToken),
        bool boolean => importer.WriteAsync(boolean, NpgsqlDbType.Boolean, cancellationToken),
        string text => importer.WriteAsync(text, NpgsqlDbType.Text, cancellationToken),
        _ => throw new CombatSupportCatalogIntegrityException("support_fact_value_invalid")
      };

  private static async Task EnsureVersionChildrenAsync(
      PostgreSqlCompletedImportContext context,
      long versionId,
      CombatSupportDefinitionPublication definition,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
          (SELECT count(*) FROM lab_combat_support.definition_stat_contribution
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.definition_skill_coordinate
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.definition_level_coordinate
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.equipment_option_slot
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.console_legal_level
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.overload_legal_band
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_combat_support.overload_legal_value
           WHERE definition_version_id = $1),
          (SELECT count(*) FROM lab_private.overload_legal_value_source_alias
           WHERE definition_version_id = $1);
        """,
        context.Connection,
        context.Transaction);
    command.Parameters.AddWithValue(versionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
        reader.GetInt64(0) != definition.Contributions.Contributions.Count ||
        reader.GetInt64(1) != definition.Contributions.SkillCoordinates.Count ||
        reader.GetInt64(2) != LevelCoordinateCount(definition) ||
        reader.GetInt64(3) != EquipmentOptionCount(definition) ||
        reader.GetInt64(4) != LegalLevelCount(definition) ||
        reader.GetInt64(5) != OverloadBandCount(definition) ||
        reader.GetInt64(6) != OverloadValueCount(definition) ||
        reader.GetInt64(7) != OverloadValueCount(definition) ||
        await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw new CombatSupportCatalogIntegrityException("support_version_children_mismatch");
    }
  }

  private sealed record StoredEntity(long Id, EntityUid Uid);

  private sealed record StoredCharacter(long Id, EntityUid Uid);

  private sealed record StoredVersion(
      long Id,
      EntityUid Uid,
      Sha256Digest DomainContentSha256,
      bool IsSourceReady,
      bool IsProfileSelectable,
      bool IsGameLegalReady,
      bool HasCompleteCombatSemantics,
      bool IsDuplicatePolicyReady);

  private sealed record StoredMember(
      int Ordinal,
      long EntityId,
      EntityUid EntityUid,
      long VersionId,
      EntityUid VersionUid,
      CombatSupportDefinitionKind Kind,
      Sha256Digest DomainContentSha256,
      bool IsSourceReady,
      bool IsProfileSelectable,
      bool IsGameLegalReady,
      bool HasCompleteCombatSemantics,
      bool IsDuplicatePolicyReady);

  private sealed record StoredCatalog(long Id, EntityUid Uid);

  private sealed record PublishedCatalog(
      long Id,
      EntityUid Uid,
      Sha256Digest ManifestSha256,
      IReadOnlyList<StoredMember> Members);

  private sealed record DomainProjection(
      Sha256Digest ContentSha256,
      bool IsSourceReady,
      bool IsProfileSelectable,
      bool IsGameLegalReady,
      bool HasCompleteCombatSemantics,
      bool IsDuplicatePolicyReady);
}
