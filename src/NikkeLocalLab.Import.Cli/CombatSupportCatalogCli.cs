using System.Security.Cryptography;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.CombatSupportCatalog;
using NikkeLocalLab.Import.Sources;
using NikkeLocalLab.Provenance;
using Domain = NikkeLocalLab.Domain.CombatSupport;
using Persistence = NikkeLocalLab.Persistence.PostgreSql;

internal static class CombatSupportCatalogCli
{
  private static readonly ExtractorDescriptor Extractor = new(
      "combat_support_catalog",
      "v1",
      Sha256Digest.ComputeUtf8("nll/combat-support-catalog-extractor-contract/v1"));

  public static async Task<int> InspectAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    var input = RequireInput(configuration, repositoryRoot, options);
    try
    {
      var result = await ReadStableAsync(input).ConfigureAwait(false);
      Console.WriteLine("combat_support_catalog_valid");
      Console.WriteLine("source_artifact_count=1");
      Console.WriteLine($"definition_count={result.Extraction.Definitions.Count}");
      foreach (var kind in Enum.GetValues<Domain.CombatSupportDefinitionKind>())
      {
        Console.WriteLine(
            $"definition_kind={Domain.CombatSupportCanonicalCodes.DefinitionKind(kind)}:" +
            result.Extraction.Count(kind));
      }

      Console.WriteLine($"candidate_sha256={result.Extraction.CanonicalCandidateSha256}");
      foreach (var diagnostic in result.Extraction.Diagnostics)
      {
        Console.WriteLine($"diagnostic={diagnostic.Code}:{diagnostic.OccurrenceCount}");
      }

      return 0;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(input.Secret);
    }
  }

  public static async Task<int> ImportAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    RuntimeRootInitializer.Initialize(configuration, repositoryRoot);
    var input = RequireInput(configuration, repositoryRoot, options);
    try
    {
      var startedAt = DateTimeOffset.UtcNow;
      var result = await ReadStableAsync(input).ConfigureAwait(false);
      var datasetManifest = CanonicalDatasetManifest.Create(
      [
          new DatasetArtifactInput("combat_support_staticdata", result.SourceObservation)
      ]);
      var publication = ToPublication(result.Extraction, input.Secret);
      var requestSha256 = ImportRequestFingerprint.Create(
          datasetManifest.CanonicalSha256,
          Extractor.FingerprintSha256,
          SemanticOptionsFingerprint.Empty);
      var uidGenerator = new RandomEntityUidGenerator();
      var attempt = new CompletedImportAttempt(
          uidGenerator.NewUid(),
          uidGenerator.NewUid(),
          datasetManifest.Artifacts
              .Select(item => new ArtifactRegistration(uidGenerator.NewUid(), item))
              .ToArray(),
          datasetManifest,
          Extractor,
          SemanticOptionsFingerprint.Empty,
          requestSha256,
          publication.CanonicalSha256,
          result.Extraction.Diagnostics.Select(ToSafeDiagnostic).ToArray(),
          startedAt,
          DateTimeOffset.UtcNow);

      var connectionString = Persistence.PostgreSqlConnectionPolicy.ResolveFromEnvironment(
          configuration.DatabaseConnectionStringEnvironmentVariable);
      await using var dataSource = Persistence.PostgreSqlDataSourceFactory.Create(connectionString);
      await new Persistence.PostgreSqlMigrationRunner().MigrateAsync(dataSource).ConfigureAwait(false);
      var store = new Persistence.PostgreSqlCombatSupportCatalogImportStore(dataSource, uidGenerator);
      var receipt = await store.RecordCompletedAndPublishAsync(attempt, publication).ConfigureAwait(false);
      Console.WriteLine("combat_support_catalog_imported");
      Console.WriteLine($"status={receipt.Import.Status.ToString().ToLowerInvariant()}");
      Console.WriteLine($"combat_support_catalog_snapshot_uid={receipt.CombatSupportCatalogSnapshotUid}");
      Console.WriteLine($"catalog_manifest_sha256={receipt.CatalogManifestSha256}");
      Console.WriteLine($"definition_count={receipt.Members.Count}");
      return 0;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(input.Secret);
    }
  }

  internal static Persistence.CombatSupportCatalogPublication ToPublication(
      CombatSupportCatalogExtraction extraction,
      ReadOnlySpan<byte> identitySecret)
  {
    ArgumentNullException.ThrowIfNull(extraction);
    return new Persistence.CombatSupportCatalogPublication(
        Persistence.CombatSupportCatalogIdentityBinding.FromSecret(identitySecret),
        extraction.Definitions.Select(ToPublicationDefinition).ToArray());
  }

  internal static SafeDiagnostic ToSafeDiagnostic(CombatSupportCatalogDiagnostic diagnostic) => new(
      ImportDiagnosticSeverity.Warning,
      "combat_support_catalog",
      diagnostic.Code,
      diagnostic.OccurrenceCount);

  private static Persistence.CombatSupportDefinitionPublication ToPublicationDefinition(
      ImportedCombatSupportDefinitionCandidate candidate)
  {
    Persistence.ICombatSupportDefinitionPayload payload = candidate.Payload switch
    {
      ImportedEquipmentDefinitionPayload equipment => ToEquipment(equipment),
      ImportedHarmonyCubeDefinitionPayload cube => ToCube(cube),
      ImportedGenericCollectionDefinitionPayload collection => ToCollection(collection),
      ImportedFavoriteDefinitionPayload favorite => ToFavorite(favorite),
      ImportedConsoleDefinitionPayload console => ToConsole(console),
      ImportedOverloadOptionDefinitionPayload overload => ToOverload(overload),
      _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_payload_invalid")
    };
    return new Persistence.CombatSupportDefinitionPublication(
        candidate.AliasFingerprint,
        new Persistence.CombatSupportTextFact(
            Persistence.CombatSupportFactStatus.Unresolved,
            unresolvedReasonCode: "locale_not_imported"),
        payload,
        ToContributionSet(candidate.Payload));
  }

  private static Persistence.CombatSupportEquipmentDefinitionPublication ToEquipment(
      ImportedEquipmentDefinitionPayload equipment) => new(
      MapEquipmentSlot(equipment.Slot),
      MapFact(equipment.CombatRole, MapCombatRole),
      MapFact(equipment.Manufacturer, MapManufacturer),
      MapFact(equipment.Tier, static value => value),
      MapFact(equipment.EnhancementGrade, static value => value),
      MapFact(equipment.MaximumEnhancementLevel, static value => value),
      MapFact(equipment.OverloadEligible, static value => value),
      equipment.OptionSlots.Select(static slot =>
          new Persistence.CombatSupportEquipmentOptionSlotPublication(
              slot.Ordinal,
              ToPersistenceExact(slot.ActivationProbability))));

  private static Persistence.CombatSupportCubeDefinitionPublication ToCube(
      ImportedHarmonyCubeDefinitionPayload cube) => new(
      MapFact(cube.Rarity, MapRarity),
      MapFact(cube.ApplicableCombatRole, MapCombatRole),
      MapFact(cube.MaximumLevel, static value => value),
      cube.Levels.Select(ToLevel),
      MapFact(cube.SkillSemantics, static value => value));

  private static Persistence.CombatSupportCollectionDefinitionPublication ToCollection(
      ImportedGenericCollectionDefinitionPayload collection) => new(
      MapFact(collection.ApplicableWeaponClass, MapWeaponClass),
      MapFact(collection.Rarity, MapRarity),
      MapFact(collection.MaximumLevel, static value => value),
      collection.Levels.Select(ToLevel),
      MapFact(collection.SkillSemantics, static value => value));

  private static Persistence.CombatSupportFavoriteDefinitionPublication ToFavorite(
      ImportedFavoriteDefinitionPayload favorite) => new(
      MapFact(favorite.MaximumLevel, static value => value),
      MapFact(favorite.ApplicableCharacterAlias, static value => value),
      MapFact(favorite.Rarity, MapRarity),
      favorite.Levels.Select(ToLevel),
      MapFact(favorite.SkillSemantics, static value => value));

  private static Persistence.CombatSupportConsoleDefinitionPublication ToConsole(
      ImportedConsoleDefinitionPayload console) => new(
      MapConsoleCoordinate(console.Coordinate),
      MapFact(console.MaximumLevel, static value => value),
      console.Levels.Select((level, ordinal) =>
          new Persistence.CombatSupportConsoleLevelPublication(
              ordinal,
              level.Level,
              level.MinimumSynchroLevel.RequireValue())));

  private static Persistence.CombatSupportOverloadOptionDefinitionPublication ToOverload(
      ImportedOverloadOptionDefinitionPayload overload)
  {
    var aliases = overload.LegalValueAliases.ToDictionary(static item => item.RollLevel);
    return new Persistence.CombatSupportOverloadOptionDefinitionPublication(
        MapFact(overload.OptionType, MapOverloadOptionType),
        MapFact(overload.Unit, MapValueUnit),
        ToPersistenceExact(overload.KindSelectionProbability),
        overload.LegalBands.Select(band => new Persistence.CombatSupportOverloadLegalBandPublication(
            band.Ordinal,
            ToPersistenceExact(band.Probability),
            band.OrderedValues.Select(value =>
            {
              if (!aliases.TryGetValue(value.RollLevel, out var alias))
              {
                throw new Persistence.CombatSupportCatalogIntegrityException(
                    "support_overload_value_alias_set_invalid");
              }

              return new Persistence.CombatSupportOverloadLegalValuePublication(
                  alias.SourceValueAlias,
                  value.RollLevel,
                  value.SourceRawValue,
                  value.MagnitudeBasisPoints,
                  ToPersistenceExact(value.EngineFraction));
            }))),
        MapFact(overload.DuplicatePolicy, MapDuplicatePolicy));
  }

  private static Persistence.CombatSupportContributionSetPublication ToContributionSet(
      IImportedCombatSupportDefinitionPayload payload)
  {
    if (payload is ImportedOverloadOptionDefinitionPayload)
    {
      return new Persistence.CombatSupportContributionSetPublication(
          Persistence.CombatSupportFactStatus.NotApplicable);
    }

    var contributions = new List<Persistence.CombatSupportStatContributionPublication>();
    var skills = new List<Persistence.CombatSupportSkillCoordinatePublication>();
    switch (payload)
    {
      case ImportedEquipmentDefinitionPayload equipment:
        AddContributions(contributions, equipment.BaseStats, unlockLevel: 0);
        break;
      case ImportedHarmonyCubeDefinitionPayload cube:
        AddLevelChildren(contributions, skills, cube.Levels);
        break;
      case ImportedGenericCollectionDefinitionPayload collection:
        AddLevelChildren(contributions, skills, collection.Levels);
        break;
      case ImportedFavoriteDefinitionPayload favorite:
        AddLevelChildren(contributions, skills, favorite.Levels);
        break;
      case ImportedConsoleDefinitionPayload console:
        AddContributions(contributions, console.PerLevelContributions, unlockLevel: 0);
        break;
      default:
        throw new Persistence.CombatSupportCatalogIntegrityException("support_payload_invalid");
    }

    return new Persistence.CombatSupportContributionSetPublication(
        Persistence.CombatSupportFactStatus.Ready,
        contributions,
        skills);
  }

  private static void AddLevelChildren(
      ICollection<Persistence.CombatSupportStatContributionPublication> contributions,
      ICollection<Persistence.CombatSupportSkillCoordinatePublication> skills,
      IEnumerable<Domain.CombatSupportLevelCoordinate> levels)
  {
    foreach (var level in levels)
    {
      AddContributions(contributions, level.Contributions, level.Level);
      for (var skillSlotOrdinal = 0; skillSlotOrdinal < level.SkillLevels.Count; skillSlotOrdinal++)
      {
        skills.Add(new Persistence.CombatSupportSkillCoordinatePublication(
            skills.Count,
            level.Level,
            skillSlotOrdinal,
            level.SkillLevels[skillSlotOrdinal]));
      }
    }
  }

  private static void AddContributions(
      ICollection<Persistence.CombatSupportStatContributionPublication> target,
      IEnumerable<Domain.CombatSupportStatContribution> contributions,
      int unlockLevel)
  {
    foreach (var contribution in contributions.OrderBy(static item => item.Ordinal))
    {
      target.Add(new Persistence.CombatSupportStatContributionPublication(
          target.Count,
          unlockLevel,
          MapFact(contribution.Stat, MapStat),
          MapFact(contribution.Unit, MapValueUnit),
          ToPersistenceExact(contribution.Value)));
    }
  }

  private static Persistence.CombatSupportLevelCoordinatePublication ToLevel(
      Domain.CombatSupportLevelCoordinate level) => new(
      level.Level,
      MapFact(level.Grade, static value => value),
      MapFact(level.Capacity, static value => value),
      MapFact(level.MinimumSynchroLevel, static value => value));

  private static Persistence.CombatSupportValueFact<TOutput> MapFact<TInput, TOutput>(
      Domain.CombatSupportFact<TInput> fact,
      Func<TInput, TOutput> mapper)
      where TInput : struct
      where TOutput : struct => fact.Status switch
      {
        Domain.CombatSupportFactStatus.Ready =>
            new Persistence.CombatSupportValueFact<TOutput>(
                Persistence.CombatSupportFactStatus.Ready,
                mapper(fact.RequireValue())),
        Domain.CombatSupportFactStatus.Unresolved =>
            new Persistence.CombatSupportValueFact<TOutput>(
                Persistence.CombatSupportFactStatus.Unresolved,
                unresolvedReasonCode: fact.ReasonCode),
        Domain.CombatSupportFactStatus.NotApplicable =>
            new Persistence.CombatSupportValueFact<TOutput>(
                Persistence.CombatSupportFactStatus.NotApplicable),
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_fact_status_invalid")
      };

  private static Persistence.CombatSupportExactValue ToPersistenceExact(
      Domain.CombatSupportExactValue value) => new(value.UnscaledValue, value.DecimalScale);

  private static Persistence.CombatSupportEquipmentSlot MapEquipmentSlot(
      Domain.CombatSupportEquipmentSlot value) => value switch
      {
        Domain.CombatSupportEquipmentSlot.Head => Persistence.CombatSupportEquipmentSlot.Head,
        Domain.CombatSupportEquipmentSlot.Torso => Persistence.CombatSupportEquipmentSlot.Torso,
        Domain.CombatSupportEquipmentSlot.Arms => Persistence.CombatSupportEquipmentSlot.Arms,
        Domain.CombatSupportEquipmentSlot.Legs => Persistence.CombatSupportEquipmentSlot.Legs,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_equipment_slot_invalid")
      };

  private static Persistence.CombatSupportCombatClass MapCombatRole(
      Domain.CombatSupportCombatRole value) => value switch
      {
        Domain.CombatSupportCombatRole.Attacker => Persistence.CombatSupportCombatClass.Attacker,
        Domain.CombatSupportCombatRole.Defender => Persistence.CombatSupportCombatClass.Defender,
        Domain.CombatSupportCombatRole.Supporter => Persistence.CombatSupportCombatClass.Supporter,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_combat_class_invalid")
      };

  private static Persistence.CombatSupportManufacturer MapManufacturer(
      Domain.CombatSupportManufacturer value) => value switch
      {
        Domain.CombatSupportManufacturer.Abnormal => Persistence.CombatSupportManufacturer.Abnormal,
        Domain.CombatSupportManufacturer.Elysion => Persistence.CombatSupportManufacturer.Elysion,
        Domain.CombatSupportManufacturer.Missilis => Persistence.CombatSupportManufacturer.Missilis,
        Domain.CombatSupportManufacturer.Pilgrim => Persistence.CombatSupportManufacturer.Pilgrim,
        Domain.CombatSupportManufacturer.Tetra => Persistence.CombatSupportManufacturer.Tetra,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_manufacturer_invalid")
      };

  private static Persistence.CombatSupportRarity MapRarity(Domain.CombatSupportRarity value) =>
      value switch
      {
        Domain.CombatSupportRarity.R => Persistence.CombatSupportRarity.R,
        Domain.CombatSupportRarity.Sr => Persistence.CombatSupportRarity.Sr,
        Domain.CombatSupportRarity.Ssr => Persistence.CombatSupportRarity.Ssr,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_rarity_invalid")
      };

  private static Persistence.CombatSupportWeaponClass MapWeaponClass(
      Domain.CombatSupportWeaponClass value) => value switch
      {
        Domain.CombatSupportWeaponClass.AssaultRifle => Persistence.CombatSupportWeaponClass.AssaultRifle,
        Domain.CombatSupportWeaponClass.MachineGun => Persistence.CombatSupportWeaponClass.MachineGun,
        Domain.CombatSupportWeaponClass.RocketLauncher => Persistence.CombatSupportWeaponClass.RocketLauncher,
        Domain.CombatSupportWeaponClass.Shotgun => Persistence.CombatSupportWeaponClass.Shotgun,
        Domain.CombatSupportWeaponClass.SniperRifle => Persistence.CombatSupportWeaponClass.SniperRifle,
        Domain.CombatSupportWeaponClass.SubmachineGun => Persistence.CombatSupportWeaponClass.SubmachineGun,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_weapon_class_invalid")
      };

  private static Persistence.CombatSupportConsoleCoordinate MapConsoleCoordinate(
      Domain.CombatSupportConsoleCoordinate value) => value switch
      {
        Domain.CombatSupportConsoleCoordinate.Common => Persistence.CombatSupportConsoleCoordinate.Common,
        Domain.CombatSupportConsoleCoordinate.Attacker => Persistence.CombatSupportConsoleCoordinate.Attacker,
        Domain.CombatSupportConsoleCoordinate.Defender => Persistence.CombatSupportConsoleCoordinate.Defender,
        Domain.CombatSupportConsoleCoordinate.Supporter => Persistence.CombatSupportConsoleCoordinate.Supporter,
        Domain.CombatSupportConsoleCoordinate.Elysion => Persistence.CombatSupportConsoleCoordinate.Elysion,
        Domain.CombatSupportConsoleCoordinate.Missilis => Persistence.CombatSupportConsoleCoordinate.Missilis,
        Domain.CombatSupportConsoleCoordinate.Tetra => Persistence.CombatSupportConsoleCoordinate.Tetra,
        Domain.CombatSupportConsoleCoordinate.Pilgrim => Persistence.CombatSupportConsoleCoordinate.Pilgrim,
        Domain.CombatSupportConsoleCoordinate.Abnormal => Persistence.CombatSupportConsoleCoordinate.Abnormal,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_console_coordinate_invalid")
      };

  private static Persistence.CombatSupportStat MapStat(Domain.CombatSupportStat value) => value switch
  {
    Domain.CombatSupportStat.Attack => Persistence.CombatSupportStat.Attack,
    Domain.CombatSupportStat.Defence => Persistence.CombatSupportStat.Defence,
    Domain.CombatSupportStat.Hp => Persistence.CombatSupportStat.Hp,
    Domain.CombatSupportStat.EnergyResistance => Persistence.CombatSupportStat.EnergyResistance,
    Domain.CombatSupportStat.MetalResistance => Persistence.CombatSupportStat.MetalResistance,
    Domain.CombatSupportStat.BioResistance => Persistence.CombatSupportStat.BioResistance,
    _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_stat_invalid")
  };

  private static Persistence.CombatSupportValueUnit MapValueUnit(
      Domain.CombatSupportValueUnit value) => value switch
      {
        Domain.CombatSupportValueUnit.Absolute => Persistence.CombatSupportValueUnit.Absolute,
        Domain.CombatSupportValueUnit.Ratio => Persistence.CombatSupportValueUnit.Ratio,
        Domain.CombatSupportValueUnit.Percent => Persistence.CombatSupportValueUnit.Percent,
        Domain.CombatSupportValueUnit.Count => Persistence.CombatSupportValueUnit.Count,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_value_unit_invalid")
      };

  private static Persistence.CombatSupportOverloadOptionType MapOverloadOptionType(
      Domain.CombatSupportOverloadOptionType value) => value switch
      {
        Domain.CombatSupportOverloadOptionType.Attack => Persistence.CombatSupportOverloadOptionType.Attack,
        Domain.CombatSupportOverloadOptionType.Defence => Persistence.CombatSupportOverloadOptionType.Defence,
        Domain.CombatSupportOverloadOptionType.MaximumAmmunition =>
            Persistence.CombatSupportOverloadOptionType.MaximumAmmunition,
        Domain.CombatSupportOverloadOptionType.CriticalRate =>
            Persistence.CombatSupportOverloadOptionType.CriticalRate,
        Domain.CombatSupportOverloadOptionType.CriticalDamage =>
            Persistence.CombatSupportOverloadOptionType.CriticalDamage,
        Domain.CombatSupportOverloadOptionType.ChargeDamage =>
            Persistence.CombatSupportOverloadOptionType.ChargeDamage,
        Domain.CombatSupportOverloadOptionType.ChargeSpeed =>
            Persistence.CombatSupportOverloadOptionType.ChargeSpeed,
        Domain.CombatSupportOverloadOptionType.ElementalDamage =>
            Persistence.CombatSupportOverloadOptionType.ElementalDamage,
        Domain.CombatSupportOverloadOptionType.HitRate => Persistence.CombatSupportOverloadOptionType.HitRate,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException("support_overload_option_type_invalid")
      };

  private static Persistence.CombatSupportOverloadDuplicatePolicy MapDuplicatePolicy(
      Domain.CombatSupportOverloadDuplicatePolicy value) => value switch
      {
        Domain.CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment =>
            Persistence.CombatSupportOverloadDuplicatePolicy.AllowSameTypeOnOneEquipment,
        Domain.CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment =>
            Persistence.CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment,
        _ => throw new Persistence.CombatSupportCatalogIntegrityException(
            "support_overload_duplicate_policy_invalid")
      };

  private static async Task<CombatSupportCatalogReadResult> ReadStableAsync(
      CombatSupportCatalogInput input)
  {
    var before = await input.Source.ObserveAsync().ConfigureAwait(false);
    var extraction = await input.Source.ReadAsync(
        (stream, _) => Task.FromResult(
            new StaticDataCombatSupportCatalogReader().Read(stream, input.Secret)))
        .ConfigureAwait(false);
    var after = await input.Source.ObserveAsync().ConfigureAwait(false);
    if (before != after || extraction.SourceArchiveSha256 != before.ContentSha256)
    {
      throw new CombatSupportCatalogSourceException("source_changed_during_import");
    }

    return new CombatSupportCatalogReadResult(extraction, before);
  }

  private static CombatSupportCatalogInput RequireInput(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    if (!options.TryGetValue("static-root", out var staticRoot) ||
        !options.TryGetValue("static-file", out var staticFile))
    {
      throw new LabConfigurationException("combat_support_catalog_source_option_missing");
    }

    var secretText = Environment.GetEnvironmentVariable(configuration.IdentitySecretEnvironmentVariable);
    if (string.IsNullOrWhiteSpace(secretText))
    {
      throw new LabConfigurationException("identity_secret_missing");
    }

    byte[] secret;
    try
    {
      secret = Convert.FromBase64String(secretText);
    }
    catch (FormatException)
    {
      throw new LabConfigurationException("identity_secret_invalid");
    }

    if (secret.Length < 32)
    {
      CryptographicOperations.ZeroMemory(secret);
      throw new LabConfigurationException("identity_secret_invalid");
    }

    try
    {
      var source = new ReadOnlySourceRoot(
          staticRoot,
          repositoryRoot,
          configuration.RuntimeRoot)
          .Bind(SourceRelativePath.Parse(staticFile), "staticdata_archive");
      return new CombatSupportCatalogInput(source, secret);
    }
    catch
    {
      CryptographicOperations.ZeroMemory(secret);
      throw;
    }
  }

  private sealed record CombatSupportCatalogInput(
      IImportArtifactSource Source,
      byte[] Secret);

  private sealed record CombatSupportCatalogReadResult(
      CombatSupportCatalogExtraction Extraction,
      SourceArtifactObservation SourceObservation);
}
