using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using CharacterDomain = NikkeLocalLab.Domain.Character;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class PostgreSqlCharacterCatalogImportStore
{
  private const long AliasAdvisoryLockNamespace = 2_917_642_803_118_647_153;
  private static readonly CharacterCapabilityCode[] RequiredCapabilities =
      Enum.GetValues<CharacterCapabilityCode>();
  private static readonly CharacterEquipmentSlot[] RequiredEquipment =
      Enum.GetValues<CharacterEquipmentSlot>();
  private readonly PostgreSqlImportLedger _ledger;
  private readonly IEntityUidGenerator _uidGenerator;

  public PostgreSqlCharacterCatalogImportStore(
      NpgsqlDataSource dataSource,
      IEntityUidGenerator uidGenerator)
  {
    ArgumentNullException.ThrowIfNull(dataSource);
    _uidGenerator = uidGenerator ?? throw new ArgumentNullException(nameof(uidGenerator));
    _ledger = new PostgreSqlImportLedger(dataSource, uidGenerator);
  }

  public async Task<CharacterCatalogImportReceipt> RecordCompletedAndPublishAsync(
      CompletedImportAttempt attempt,
      CharacterCatalogPublication publication,
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
      throw new CharacterCatalogIntegrityException("catalog_publication_missing");
    }

    return new CharacterCatalogImportReceipt(
        importReceipt,
        published.SnapshotUid,
        published.CatalogManifestSha256,
        published.Members);
  }

  private static void ValidatePublication(
      CompletedImportAttempt attempt,
      CharacterCatalogPublication publication)
  {
    ArgumentNullException.ThrowIfNull(publication);
    ArgumentNullException.ThrowIfNull(publication.IdentityBinding);
    ArgumentNullException.ThrowIfNull(publication.Definitions);

    if (attempt.Diagnostics.Any(item => item.Severity == ImportDiagnosticSeverity.Error))
    {
      throw new CharacterCatalogIntegrityException("catalog_error_diagnostic");
    }

    if (publication.Definitions.Count == 0)
    {
      throw new CharacterCatalogIntegrityException("catalog_empty");
    }

    var aliases = new HashSet<SourceAliasFingerprint>();
    foreach (var definition in publication.Definitions)
    {
      if (definition is null ||
          definition.SourceAliasFingerprint == default ||
          definition.DefinitionContentSha256 == default ||
          definition.DisplayName is null ||
          definition.Rarity is null ||
          definition.CombatClass is null ||
          definition.Weapon is null ||
          definition.Element is null ||
          definition.Manufacturer is null ||
          definition.Capabilities is null ||
          definition.Equipment is null)
      {
        throw new CharacterCatalogIntegrityException("catalog_definition_invalid");
      }

      if (definition.DisplayName.Status == CharacterCatalogFactStatus.NotApplicable ||
          definition.Rarity.Status == CharacterCatalogFactStatus.NotApplicable ||
          definition.CombatClass.Status == CharacterCatalogFactStatus.NotApplicable ||
          definition.Weapon.Status == CharacterCatalogFactStatus.NotApplicable ||
          definition.Element.Status == CharacterCatalogFactStatus.NotApplicable ||
          definition.Manufacturer.Status == CharacterCatalogFactStatus.NotApplicable)
      {
        throw new CharacterCatalogIntegrityException("profile_fact_invalid");
      }

      if (!aliases.Add(definition.SourceAliasFingerprint))
      {
        throw new CharacterCatalogIntegrityException("catalog_alias_duplicate");
      }

      if (definition.DisplayName.Value is { } displayName &&
          !displayName.IsNormalized(NormalizationForm.FormC))
      {
        throw new CharacterCatalogIntegrityException("display_name_not_normalized");
      }

      var capabilityCodes = definition.Capabilities
          .Select(item => item?.Code ?? throw new CharacterCatalogIntegrityException("capability_fact_invalid"))
          .OrderBy(item => item)
          .ToArray();
      if (!capabilityCodes.SequenceEqual(RequiredCapabilities))
      {
        throw new CharacterCatalogIntegrityException("capability_set_incomplete");
      }

      var equipmentSlots = definition.Equipment
          .Select(item => item?.Slot ??
              throw new CharacterCatalogIntegrityException("equipment_capability_fact_invalid"))
          .OrderBy(item => item)
          .ToArray();
      if (!equipmentSlots.SequenceEqual(RequiredEquipment))
      {
        throw new CharacterCatalogIntegrityException("equipment_capability_set_incomplete");
      }

      if (CharacterDomain.CharacterDefinitionCanonicalizer.ComputeContentHash(
              ToDomainContent(definition)) != definition.DefinitionContentSha256)
      {
        throw new CharacterCatalogIntegrityException("definition_content_hash_mismatch");
      }
    }
  }

  private async Task<PublishedCatalog> PublishWithinTransactionAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      CharacterCatalogPublication publication,
      CancellationToken cancellationToken)
  {
    await EnsureIdentityBindingAsync(
        context.Connection,
        context.Transaction,
        publication.IdentityBinding,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await AcquireAliasLocksAsync(
        context.Connection,
        context.Transaction,
        publication.Definitions.Select(item => item.SourceAliasFingerprint),
        cancellationToken).ConfigureAwait(false);

    var storedMembers = new List<StoredCatalogMember>(publication.Definitions.Count);
    for (var ordinal = 0; ordinal < publication.Definitions.Count; ordinal++)
    {
      var definition = publication.Definitions[ordinal];
      var character = await ResolveCharacterAsync(
          context.Connection,
          context.Transaction,
          definition.SourceAliasFingerprint,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      var version = await RegisterDefinitionVersionAsync(
          context.Connection,
          context.Transaction,
          character.Id,
          definition,
          attempt.FinishedAtUtc,
          cancellationToken).ConfigureAwait(false);
      storedMembers.Add(new StoredCatalogMember(
          ordinal,
          character.Id,
          character.Uid,
          version.Id,
          version.Uid));
    }

    var manifest = CharacterDomain.CharacterCatalogManifest.Create(
        context.DatasetSnapshotUid,
        storedMembers.Select(member => new CharacterDomain.CharacterCatalogManifestEntry(
            member.CharacterUid,
            publication.Definitions[member.Ordinal].DefinitionContentSha256)));
    var snapshot = await RegisterCatalogSnapshotAsync(
        context,
        attempt,
        manifest.Sha256,
        attempt.FinishedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await RegisterSnapshotMembersAsync(
        context.Connection,
        context.Transaction,
        snapshot.Id,
        storedMembers,
        cancellationToken).ConfigureAwait(false);

    return new PublishedCatalog(
        snapshot.Uid,
        manifest.Sha256,
        storedMembers
            .OrderBy(item => item.Ordinal)
            .Select(item => new CharacterCatalogMemberReceipt(
                item.Ordinal,
                item.CharacterUid,
                item.VersionUid))
            .ToArray());
  }

  private static async Task EnsureIdentityBindingAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      CharacterCatalogIdentityBinding binding,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_meta.character_identity_key_binding
                         (binding_id, encoder_version, key_check_sha256, created_at_utc)
                     VALUES (1, $1, $2, $3)
                     ON CONFLICT (binding_id) DO NOTHING;
                     """,
                     connection,
                     transaction))
    {
      insert.Parameters.AddWithValue(binding.EncoderVersion);
      insert.Parameters.AddWithValue(binding.KeyCheckSha256.ToByteArray());
      insert.Parameters.AddWithValue(createdAt);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    string storedVersion;
    byte[] storedKeyCheck;
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT encoder_version, key_check_sha256
                     FROM lab_meta.character_identity_key_binding
                     WHERE binding_id = 1
                     FOR SHARE;
                     """,
                     connection,
                     transaction))
    await using (var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        throw new CharacterCatalogIntegrityException("identity_binding_missing");
      }

      storedVersion = reader.GetString(0);
      storedKeyCheck = (byte[])reader[1];
    }

    var expected = binding.KeyCheckSha256.ToByteArray();
    try
    {
      if (!string.Equals(storedVersion, binding.EncoderVersion, StringComparison.Ordinal) ||
          !CryptographicOperations.FixedTimeEquals(storedKeyCheck, expected))
      {
        throw new CharacterCatalogIntegrityException("identity_key_mismatch");
      }
    }
    finally
    {
      CryptographicOperations.ZeroMemory(storedKeyCheck);
      CryptographicOperations.ZeroMemory(expected);
    }
  }

  private static async Task AcquireAliasLocksAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      IEnumerable<SourceAliasFingerprint> fingerprints,
      CancellationToken cancellationToken)
  {
    foreach (var fingerprint in fingerprints
                 .Distinct()
                 .OrderBy(item => item.Hex, StringComparer.Ordinal))
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
          connection,
          transaction);
      command.Parameters.AddWithValue(lockKey);
      await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private async Task<StoredCharacter> ResolveCharacterAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      SourceAliasFingerprint fingerprint,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var fingerprintBytes = fingerprint.ToByteArray();
    try
    {
      await using (var read = new NpgsqlCommand(
                       """
                       SELECT entity.character_entity_id, entity.character_uid
                       FROM lab_private.character_source_alias AS alias
                       JOIN lab_catalog.character_entity AS entity
                           ON entity.character_entity_id = alias.character_entity_id
                       WHERE alias.alias_fingerprint = $1;
                       """,
                       connection,
                       transaction))
      {
        read.Parameters.AddWithValue(fingerprintBytes);
        await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          return new StoredCharacter(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
        }
      }

      long entityId;
      var entityUid = _uidGenerator.NewUid();
      await using (var insertEntity = new NpgsqlCommand(
                       """
                       INSERT INTO lab_catalog.character_entity (character_uid, created_at_utc)
                       VALUES ($1, $2)
                       RETURNING character_entity_id;
                       """,
                       connection,
                       transaction))
      {
        insertEntity.Parameters.AddWithValue(entityUid.Value);
        insertEntity.Parameters.AddWithValue(createdAt);
        var value = await insertEntity.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
        entityId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
      }

      await using (var insertAlias = new NpgsqlCommand(
                       """
                       INSERT INTO lab_private.character_source_alias
                           (alias_fingerprint, character_entity_id, created_at_utc)
                       VALUES ($1, $2, $3);
                       """,
                       connection,
                       transaction))
      {
        insertAlias.Parameters.AddWithValue(fingerprintBytes);
        insertAlias.Parameters.AddWithValue(entityId);
        insertAlias.Parameters.AddWithValue(createdAt);
        await insertAlias.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      return new StoredCharacter(entityId, entityUid);
    }
    finally
    {
      CryptographicOperations.ZeroMemory(fingerprintBytes);
    }
  }

  private async Task<StoredVersion> RegisterDefinitionVersionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long characterId,
      CharacterCatalogDefinition definition,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    var shapeSha256 = ComputeNormalizedShapeSha256(definition);
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT character_definition_version_id,
                            character_definition_version_uid,
                            definition_content_sha256
                     FROM lab_catalog.character_definition_version
                     WHERE character_entity_id = $1 AND normalized_shape_sha256 = $2;
                     """,
                     connection,
                     transaction))
    {
      read.Parameters.AddWithValue(characterId);
      read.Parameters.AddWithValue(shapeSha256.ToByteArray());
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var storedContentSha256 = (byte[])reader[2];
        if (!storedContentSha256.AsSpan().SequenceEqual(
                definition.DefinitionContentSha256.ToByteArray()))
        {
          throw new CharacterCatalogIntegrityException("definition_shape_digest_collision");
        }

        var existing = new StoredVersion(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
        await reader.DisposeAsync().ConfigureAwait(false);
        await EnsureCapabilityCountAsync(
            connection,
            transaction,
            existing.Id,
            cancellationToken).ConfigureAwait(false);
        return existing;
      }
    }

    var versionUid = _uidGenerator.NewUid();
    long versionId;
    await using (var insert = new NpgsqlCommand(
                     """
                     INSERT INTO lab_catalog.character_definition_version
                         (character_definition_version_uid, character_entity_id,
                          definition_content_sha256, normalized_shape_sha256,
                          display_name_status, display_name, display_name_unresolved_reason_code,
                          rarity_status, rarity_code, rarity_unresolved_reason_code,
                          combat_class_status, combat_class_code, combat_class_unresolved_reason_code,
                          weapon_status, weapon_code, weapon_unresolved_reason_code,
                          element_status, element_code, element_unresolved_reason_code,
                          manufacturer_status, manufacturer_code, manufacturer_unresolved_reason_code,
                          readiness_status, created_at_utc)
                     VALUES
                         ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
                          $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24)
                     RETURNING character_definition_version_id;
                     """,
                     connection,
                     transaction))
    {
      var readiness = ComputeReadiness(definition);
      insert.Parameters.AddWithValue(versionUid.Value);
      insert.Parameters.AddWithValue(characterId);
      insert.Parameters.AddWithValue(definition.DefinitionContentSha256.ToByteArray());
      insert.Parameters.AddWithValue(shapeSha256.ToByteArray());
      AddProfileFact(insert, definition.DisplayName, value => value);
      AddProfileFact(insert, definition.Rarity, ToDbCode);
      AddProfileFact(insert, definition.CombatClass, ToDbCode);
      AddProfileFact(insert, definition.Weapon, ToDbCode);
      AddProfileFact(insert, definition.Element, ToDbCode);
      AddProfileFact(insert, definition.Manufacturer, ToDbCode);
      insert.Parameters.AddWithValue(readiness);
      insert.Parameters.AddWithValue(createdAt);
      var value = await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
      versionId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }

    foreach (var capability in definition.Capabilities.OrderBy(item => item.Code))
    {
      await InsertCapabilityAsync(
          connection,
          transaction,
          versionId,
          capability,
          cancellationToken).ConfigureAwait(false);
    }

    foreach (var equipment in definition.Equipment.OrderBy(item => item.Slot))
    {
      await InsertEquipmentCapabilityAsync(
          connection,
          transaction,
          versionId,
          equipment,
          cancellationToken).ConfigureAwait(false);
    }

    return new StoredVersion(versionId, versionUid);
  }

  private static async Task EnsureCapabilityCountAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long versionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT
          (SELECT count(*) FROM lab_catalog.character_definition_capability
           WHERE character_definition_version_id = $1),
          (SELECT count(*) FROM lab_catalog.character_definition_equipment_capability
           WHERE character_definition_version_id = $1);
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue(versionId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
        reader.GetInt64(0) != RequiredCapabilities.Length ||
        reader.GetInt64(1) != RequiredEquipment.Length)
    {
      throw new CharacterCatalogIntegrityException("definition_capability_corrupt");
    }
  }

  private static async Task InsertCapabilityAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long versionId,
      CharacterCatalogCapability capability,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_catalog.character_definition_capability
            (character_definition_version_id, capability_code, resolution_status,
             unresolved_reason_code, maximum_level)
        VALUES ($1, $2, $3, $4, $5);
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(ToDbCode(capability.Code));
    command.Parameters.AddWithValue(ToDbCode(capability.Status));
    command.Parameters.AddWithValue((object?)capability.UnresolvedReasonCode ?? DBNull.Value);
    command.Parameters.AddWithValue((object?)capability.MaximumLevel ?? DBNull.Value);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task InsertEquipmentCapabilityAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long versionId,
      CharacterCatalogEquipmentCapability equipment,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_catalog.character_definition_equipment_capability
            (character_definition_version_id, equipment_slot,
             equipment_definition_status, equipment_definition_uid,
             equipment_definition_unresolved_reason_code,
             maximum_tier_status, maximum_tier, maximum_tier_unresolved_reason_code,
             maximum_tier_ten_enhancement_status, maximum_tier_ten_enhancement_level,
             maximum_tier_ten_enhancement_unresolved_reason_code,
             manufacturer_match_status, manufacturer_match,
             manufacturer_match_unresolved_reason_code)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14);
        """,
        connection,
        transaction);
    command.Parameters.AddWithValue(versionId);
    command.Parameters.AddWithValue(ToDbCode(equipment.Slot));
    AddFact(command, equipment.EquipmentDefinitionUid, value => value.Value);
    AddFact(command, equipment.MaximumTier, value => value);
    AddFact(command, equipment.MaximumTierTenEnhancementLevel, value => value);
    AddFact(command, equipment.ManufacturerMatch, value => value);
    await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private async Task<StoredCatalogSnapshot> RegisterCatalogSnapshotAsync(
      PostgreSqlCompletedImportContext context,
      CompletedImportAttempt attempt,
      Sha256Digest catalogManifestSha256,
      DateTimeOffset createdAt,
      CancellationToken cancellationToken)
  {
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT character_catalog_snapshot_id, character_catalog_snapshot_uid,
                            dataset_snapshot_id, output_manifest_sha256,
                            catalog_manifest_sha256
                     FROM lab_catalog.character_catalog_snapshot
                     WHERE request_sha256 = $1;
                     """,
                     context.Connection,
                     context.Transaction))
    {
      read.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        if (reader.GetInt64(2) != context.DatasetSnapshotId ||
            !((byte[])reader[3]).AsSpan().SequenceEqual(attempt.OutputManifestSha256.ToByteArray()) ||
            !((byte[])reader[4]).AsSpan().SequenceEqual(catalogManifestSha256.ToByteArray()))
        {
          throw new CharacterCatalogIntegrityException("catalog_snapshot_provenance_mismatch");
        }

        return new StoredCatalogSnapshot(reader.GetInt64(0), new EntityUid(reader.GetGuid(1)));
      }
    }

    if (context.IsReusedImport)
    {
      throw new CharacterCatalogIntegrityException("catalog_reused_import_missing_publication");
    }

    var snapshotUid = _uidGenerator.NewUid();
    await using var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_catalog.character_catalog_snapshot
            (character_catalog_snapshot_uid, dataset_snapshot_id, request_sha256,
             output_manifest_sha256, catalog_manifest_sha256,
             published_by_import_run_id, created_at_utc)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING character_catalog_snapshot_id;
        """,
        context.Connection,
        context.Transaction);
    insert.Parameters.AddWithValue(snapshotUid.Value);
    insert.Parameters.AddWithValue(context.DatasetSnapshotId);
    insert.Parameters.AddWithValue(attempt.RequestSha256.ToByteArray());
    insert.Parameters.AddWithValue(attempt.OutputManifestSha256.ToByteArray());
    insert.Parameters.AddWithValue(catalogManifestSha256.ToByteArray());
    insert.Parameters.AddWithValue(context.ImportRunId);
    insert.Parameters.AddWithValue(createdAt);
    var value = await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    return new StoredCatalogSnapshot(
        Convert.ToInt64(value, CultureInfo.InvariantCulture),
        snapshotUid);
  }

  private static async Task RegisterSnapshotMembersAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long snapshotId,
      IReadOnlyList<StoredCatalogMember> members,
      CancellationToken cancellationToken)
  {
    var existing = new List<(int Ordinal, long CharacterId, long VersionId)>();
    await using (var read = new NpgsqlCommand(
                     """
                     SELECT ordinal, character_entity_id, character_definition_version_id
                     FROM lab_catalog.character_catalog_snapshot_member
                     WHERE character_catalog_snapshot_id = $1
                     ORDER BY ordinal;
                     """,
                     connection,
                     transaction))
    {
      read.Parameters.AddWithValue(snapshotId);
      await using var reader = await read.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        existing.Add((reader.GetInt32(0), reader.GetInt64(1), reader.GetInt64(2)));
      }
    }

    var expected = members
        .OrderBy(item => item.Ordinal)
        .Select(item => (item.Ordinal, item.CharacterId, item.VersionId))
        .ToArray();
    if (existing.Count > 0)
    {
      if (!existing.SequenceEqual(expected))
      {
        throw new CharacterCatalogIntegrityException("catalog_snapshot_membership_mismatch");
      }

      return;
    }

    foreach (var member in members.OrderBy(item => item.Ordinal))
    {
      await using var insert = new NpgsqlCommand(
          """
          INSERT INTO lab_catalog.character_catalog_snapshot_member
              (character_catalog_snapshot_id, character_entity_id,
               character_definition_version_id, ordinal)
          VALUES ($1, $2, $3, $4);
          """,
          connection,
          transaction);
      insert.Parameters.AddWithValue(snapshotId);
      insert.Parameters.AddWithValue(member.CharacterId);
      insert.Parameters.AddWithValue(member.VersionId);
      insert.Parameters.AddWithValue(member.Ordinal);
      await insert.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static CharacterDomain.CharacterDefinitionContent ToDomainContent(
      CharacterCatalogDefinition definition)
  {
    var capabilities = definition.Capabilities.ToDictionary(item => item.Code);
    var equipment = definition.Equipment
        .Select(item => new CharacterDomain.EquipmentSlotCapability(
            ToDomainCode(item.Slot),
            ToDomainFact(item.EquipmentDefinitionUid, static value => value),
            ToDomainFact(item.MaximumTier, static value => value),
            ToDomainFact(item.MaximumTierTenEnhancementLevel, static value => value),
            ToDomainFact(item.ManufacturerMatch, static value => value)))
        .ToArray();
    return new CharacterDomain.CharacterDefinitionContent(
        new CharacterDomain.CharacterProfile(
            ToDomainFact(definition.Rarity, ToDomainCode),
            ToDomainFact(definition.CombatClass, ToDomainCode),
            ToDomainFact(definition.Weapon, ToDomainCode),
            ToDomainFact(definition.Element, ToDomainCode),
            ToDomainFact(definition.Manufacturer, ToDomainCode)),
        new CharacterDomain.CharacterCapabilities(
            ToDomainFact(capabilities[CharacterCapabilityCode.CharacterLevel]),
            ToDomainFact(capabilities[CharacterCapabilityCode.LimitBreak]),
            ToDomainFact(capabilities[CharacterCapabilityCode.CoreLevel]),
            ToDomainFact(capabilities[CharacterCapabilityCode.BondLevel]),
            equipment,
            new CharacterDomain.SkillMaximums(
                ToDomainFact(capabilities[CharacterCapabilityCode.Skill1]),
                ToDomainFact(capabilities[CharacterCapabilityCode.Skill2]),
                ToDomainFact(capabilities[CharacterCapabilityCode.Burst])),
            ToDomainFact(capabilities[CharacterCapabilityCode.Cube]),
            ToDomainFact(capabilities[CharacterCapabilityCode.CollectionItem]),
            ToDomainFact(capabilities[CharacterCapabilityCode.FavoriteItem])));
  }

  private static CharacterDomain.NormalizedFact<int> ToDomainFact(
      CharacterCatalogCapability fact) => fact.Status switch
      {
        CharacterCatalogFactStatus.Ready =>
            CharacterDomain.NormalizedFact<int>.Ready(fact.MaximumLevel!.Value),
        CharacterCatalogFactStatus.Unresolved =>
            CharacterDomain.NormalizedFact<int>.Unresolved(fact.UnresolvedReasonCode!),
        CharacterCatalogFactStatus.NotApplicable => CharacterDomain.NormalizedFact<int>.NotApplicable(),
        _ => throw new CharacterCatalogIntegrityException("capability_fact_invalid")
      };

  private static CharacterDomain.NormalizedFact<TTarget> ToDomainFact<TSource, TTarget>(
      CharacterCatalogValueFact<TSource> fact,
      Func<TSource, TTarget> mapper)
      where TSource : struct
      where TTarget : struct => fact.Status switch
      {
        CharacterCatalogFactStatus.Ready =>
            CharacterDomain.NormalizedFact<TTarget>.Ready(mapper(fact.Value!.Value)),
        CharacterCatalogFactStatus.Unresolved =>
            CharacterDomain.NormalizedFact<TTarget>.Unresolved(fact.UnresolvedReasonCode!),
        CharacterCatalogFactStatus.NotApplicable =>
            CharacterDomain.NormalizedFact<TTarget>.NotApplicable(),
        _ => throw new CharacterCatalogIntegrityException("fact_shape_invalid")
      };

  private static CharacterDomain.CharacterRarity ToDomainCode(CharacterRarityCode value) => value switch
  {
    CharacterRarityCode.R => CharacterDomain.CharacterRarity.R,
    CharacterRarityCode.Sr => CharacterDomain.CharacterRarity.SR,
    CharacterRarityCode.Ssr => CharacterDomain.CharacterRarity.SSR,
    _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
  };

  private static CharacterDomain.CombatRole ToDomainCode(CharacterCombatClassCode value) => value switch
  {
    CharacterCombatClassCode.Attacker => CharacterDomain.CombatRole.Attacker,
    CharacterCombatClassCode.Defender => CharacterDomain.CombatRole.Defender,
    CharacterCombatClassCode.Supporter => CharacterDomain.CombatRole.Supporter,
    _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
  };

  private static CharacterDomain.WeaponClass ToDomainCode(CharacterWeaponCode value) => value switch
  {
    CharacterWeaponCode.AssaultRifle => CharacterDomain.WeaponClass.AssaultRifle,
    CharacterWeaponCode.MachineGun => CharacterDomain.WeaponClass.MachineGun,
    CharacterWeaponCode.RocketLauncher => CharacterDomain.WeaponClass.RocketLauncher,
    CharacterWeaponCode.Shotgun => CharacterDomain.WeaponClass.Shotgun,
    CharacterWeaponCode.SniperRifle => CharacterDomain.WeaponClass.SniperRifle,
    CharacterWeaponCode.SubmachineGun => CharacterDomain.WeaponClass.SubmachineGun,
    _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
  };

  private static CharacterDomain.NikkeElement ToDomainCode(CharacterElementCode value) => value switch
  {
    CharacterElementCode.Electric => CharacterDomain.NikkeElement.Electric,
    CharacterElementCode.Fire => CharacterDomain.NikkeElement.Fire,
    CharacterElementCode.Iron => CharacterDomain.NikkeElement.Iron,
    CharacterElementCode.Water => CharacterDomain.NikkeElement.Water,
    CharacterElementCode.Wind => CharacterDomain.NikkeElement.Wind,
    _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
  };

  private static CharacterDomain.Manufacturer ToDomainCode(CharacterManufacturerCode value) => value switch
  {
    CharacterManufacturerCode.Abnormal => CharacterDomain.Manufacturer.Abnormal,
    CharacterManufacturerCode.Elysion => CharacterDomain.Manufacturer.Elysion,
    CharacterManufacturerCode.Missilis => CharacterDomain.Manufacturer.Missilis,
    CharacterManufacturerCode.Pilgrim => CharacterDomain.Manufacturer.Pilgrim,
    CharacterManufacturerCode.Tetra => CharacterDomain.Manufacturer.Tetra,
    _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
  };

  private static CharacterDomain.EquipmentSlot ToDomainCode(CharacterEquipmentSlot value) => value switch
  {
    CharacterEquipmentSlot.Head => CharacterDomain.EquipmentSlot.Head,
    CharacterEquipmentSlot.Torso => CharacterDomain.EquipmentSlot.Torso,
    CharacterEquipmentSlot.Arms => CharacterDomain.EquipmentSlot.Arms,
    CharacterEquipmentSlot.Legs => CharacterDomain.EquipmentSlot.Legs,
    _ => throw new CharacterCatalogIntegrityException("equipment_capability_fact_invalid")
  };

  private static void AddProfileFact(
      NpgsqlCommand command,
      CharacterCatalogTextFact fact,
      Func<string, string> valueMapper)
  {
    command.Parameters.AddWithValue(ToDbCode(fact.Status));
    command.Parameters.AddWithValue(
        fact.Value is null ? DBNull.Value : valueMapper(fact.Value));
    command.Parameters.AddWithValue((object?)fact.UnresolvedReasonCode ?? DBNull.Value);
  }

  private static void AddProfileFact<T>(
      NpgsqlCommand command,
      CharacterCatalogValueFact<T> fact,
      Func<T, string> valueMapper)
      where T : struct
  {
    command.Parameters.AddWithValue(ToDbCode(fact.Status));
    command.Parameters.AddWithValue(
        fact.Value is { } value ? valueMapper(value) : DBNull.Value);
    command.Parameters.AddWithValue((object?)fact.UnresolvedReasonCode ?? DBNull.Value);
  }

  private static void AddFact<T>(
      NpgsqlCommand command,
      CharacterCatalogValueFact<T> fact,
      Func<T, object> valueMapper)
      where T : struct
  {
    command.Parameters.AddWithValue(ToDbCode(fact.Status));
    command.Parameters.AddWithValue(
        fact.Value is { } value ? valueMapper(value) : DBNull.Value);
    command.Parameters.AddWithValue((object?)fact.UnresolvedReasonCode ?? DBNull.Value);
  }

  private static string ComputeReadiness(CharacterCatalogDefinition definition)
  {
    var profileReady = definition.Rarity.Status == CharacterCatalogFactStatus.Ready &&
        definition.CombatClass.Status == CharacterCatalogFactStatus.Ready &&
        definition.Weapon.Status == CharacterCatalogFactStatus.Ready &&
        definition.Element.Status == CharacterCatalogFactStatus.Ready &&
        definition.Manufacturer.Status == CharacterCatalogFactStatus.Ready;
    var capabilitiesReady = definition.Capabilities.All(
        item => item.Status != CharacterCatalogFactStatus.Unresolved);
    var equipmentReady = definition.Equipment.All(item =>
        item.EquipmentDefinitionUid.Status != CharacterCatalogFactStatus.Unresolved &&
        item.MaximumTier.Status != CharacterCatalogFactStatus.Unresolved &&
        item.MaximumTierTenEnhancementLevel.Status != CharacterCatalogFactStatus.Unresolved &&
        item.ManufacturerMatch.Status != CharacterCatalogFactStatus.Unresolved);
    return profileReady && capabilitiesReady && equipmentReady ? "ready" : "unresolved";
  }

  private static Sha256Digest ComputeNormalizedShapeSha256(CharacterCatalogDefinition definition)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    AppendCanonical(hash, "nll/character-definition-shape/v1");
    AppendCanonical(hash, ToDbCode(definition.DisplayName.Status));
    AppendCanonical(hash, definition.DisplayName.Value);
    AppendCanonical(hash, definition.DisplayName.UnresolvedReasonCode);
    AppendFact(hash, definition.Rarity, ToDbCode);
    AppendFact(hash, definition.CombatClass, ToDbCode);
    AppendFact(hash, definition.Weapon, ToDbCode);
    AppendFact(hash, definition.Element, ToDbCode);
    AppendFact(hash, definition.Manufacturer, ToDbCode);
    foreach (var capability in definition.Capabilities.OrderBy(item => item.Code))
    {
      AppendCanonical(hash, ToDbCode(capability.Code));
      AppendCanonical(hash, ToDbCode(capability.Status));
      AppendCanonical(hash, capability.MaximumLevel?.ToString(CultureInfo.InvariantCulture));
      AppendCanonical(hash, capability.UnresolvedReasonCode);
    }

    foreach (var equipment in definition.Equipment.OrderBy(item => item.Slot))
    {
      AppendCanonical(hash, ToDbCode(equipment.Slot));
      AppendFact(hash, equipment.EquipmentDefinitionUid, value => value.ToString());
      AppendFact(
          hash,
          equipment.MaximumTier,
          value => value.ToString(CultureInfo.InvariantCulture));
      AppendFact(
          hash,
          equipment.MaximumTierTenEnhancementLevel,
          value => value.ToString(CultureInfo.InvariantCulture));
      AppendFact(hash, equipment.ManufacturerMatch, value => value ? "true" : "false");
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static void AppendFact<T>(
      IncrementalHash hash,
      CharacterCatalogValueFact<T> fact,
      Func<T, string> valueMapper)
      where T : struct
  {
    AppendCanonical(hash, ToDbCode(fact.Status));
    AppendCanonical(hash, fact.Value is { } value ? valueMapper(value) : null);
    AppendCanonical(hash, fact.UnresolvedReasonCode);
  }

  private static void AppendCanonical(IncrementalHash hash, string? value)
  {
    if (value is null)
    {
      Span<byte> nullLength = stackalloc byte[sizeof(int)];
      BinaryPrimitives.WriteInt32BigEndian(nullLength, -1);
      hash.AppendData(nullLength);
      return;
    }

    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[sizeof(int)];
    BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  private static string ToDbCode(CharacterCatalogFactStatus value) => value switch
  {
    CharacterCatalogFactStatus.Ready => "ready",
    CharacterCatalogFactStatus.Unresolved => "unresolved",
    CharacterCatalogFactStatus.NotApplicable => "not_applicable",
    _ => throw new CharacterCatalogIntegrityException("fact_status_invalid")
  };

  private static string ToDbCode(CharacterRarityCode value) => value switch
  {
    CharacterRarityCode.R => "r",
    CharacterRarityCode.Sr => "sr",
    CharacterRarityCode.Ssr => "ssr",
    _ => throw new CharacterCatalogIntegrityException("rarity_code_invalid")
  };

  private static string ToDbCode(CharacterCombatClassCode value) => value switch
  {
    CharacterCombatClassCode.Attacker => "attacker",
    CharacterCombatClassCode.Defender => "defender",
    CharacterCombatClassCode.Supporter => "supporter",
    _ => throw new CharacterCatalogIntegrityException("combat_class_code_invalid")
  };

  private static string ToDbCode(CharacterWeaponCode value) => value switch
  {
    CharacterWeaponCode.AssaultRifle => "assault_rifle",
    CharacterWeaponCode.MachineGun => "machine_gun",
    CharacterWeaponCode.RocketLauncher => "rocket_launcher",
    CharacterWeaponCode.Shotgun => "shotgun",
    CharacterWeaponCode.SniperRifle => "sniper_rifle",
    CharacterWeaponCode.SubmachineGun => "submachine_gun",
    _ => throw new CharacterCatalogIntegrityException("weapon_code_invalid")
  };

  private static string ToDbCode(CharacterElementCode value) => value switch
  {
    CharacterElementCode.Electric => "electric",
    CharacterElementCode.Fire => "fire",
    CharacterElementCode.Iron => "iron",
    CharacterElementCode.Water => "water",
    CharacterElementCode.Wind => "wind",
    _ => throw new CharacterCatalogIntegrityException("element_code_invalid")
  };

  private static string ToDbCode(CharacterManufacturerCode value) => value switch
  {
    CharacterManufacturerCode.Abnormal => "abnormal",
    CharacterManufacturerCode.Elysion => "elysion",
    CharacterManufacturerCode.Missilis => "missilis",
    CharacterManufacturerCode.Pilgrim => "pilgrim",
    CharacterManufacturerCode.Tetra => "tetra",
    _ => throw new CharacterCatalogIntegrityException("manufacturer_code_invalid")
  };

  private static string ToDbCode(CharacterCapabilityCode value) => value switch
  {
    CharacterCapabilityCode.CharacterLevel => "character_level",
    CharacterCapabilityCode.LimitBreak => "limit_break",
    CharacterCapabilityCode.CoreLevel => "core_level",
    CharacterCapabilityCode.BondLevel => "bond_level",
    CharacterCapabilityCode.Cube => "cube",
    CharacterCapabilityCode.Skill1 => "skill_1",
    CharacterCapabilityCode.Skill2 => "skill_2",
    CharacterCapabilityCode.Burst => "burst",
    CharacterCapabilityCode.CollectionItem => "collection_item",
    CharacterCapabilityCode.FavoriteItem => "favorite_item",
    _ => throw new CharacterCatalogIntegrityException("capability_code_invalid")
  };

  private static string ToDbCode(CharacterEquipmentSlot value) => value switch
  {
    CharacterEquipmentSlot.Head => "head",
    CharacterEquipmentSlot.Torso => "torso",
    CharacterEquipmentSlot.Arms => "arms",
    CharacterEquipmentSlot.Legs => "legs",
    _ => throw new CharacterCatalogIntegrityException("equipment_slot_invalid")
  };

  private sealed record StoredCharacter(long Id, EntityUid Uid);

  private sealed record StoredVersion(long Id, EntityUid Uid);

  private sealed record StoredCatalogSnapshot(long Id, EntityUid Uid);

  private sealed record StoredCatalogMember(
      int Ordinal,
      long CharacterId,
      EntityUid CharacterUid,
      long VersionId,
      EntityUid VersionUid);

  private sealed record PublishedCatalog(
      EntityUid SnapshotUid,
      Sha256Digest CatalogManifestSha256,
      IReadOnlyList<CharacterCatalogMemberReceipt> Members);
}
