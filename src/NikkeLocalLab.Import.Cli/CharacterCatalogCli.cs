using System.Security.Cryptography;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Import.CharacterCatalog;
using NikkeLocalLab.Import.Sources;
using NikkeLocalLab.Persistence.PostgreSql;
using NikkeLocalLab.Provenance;

internal static class CharacterCatalogCli
{
  private const string DefaultGameConfigRelativePath =
      "NIKKE/game/nikke_Data/StreamingAssets/sd.bin";
  private static readonly ExtractorDescriptor Extractor = new(
      "staticdata_character_catalog",
      "v1",
      Sha256Digest.ComputeUtf8("nll/staticdata-character-catalog-extractor-contract/v1"));

  public static async Task<int> InspectAsync(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    var input = RequireInput(configuration, repositoryRoot, options);
    try
    {
      var result = await ReadStableAsync(input).ConfigureAwait(false);
      Console.WriteLine("character_catalog_valid");
      Console.WriteLine("source_artifact_count=2");
      Console.WriteLine("source_provenance=unverified_compound");
      Console.WriteLine($"character_count={result.Extraction.Characters.Count}");
      Console.WriteLine(
          $"source_resolved_character_count={result.Extraction.SourceResolvedCharacterCount}");
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
      var manifest = CanonicalDatasetManifest.Create(
      [
          new DatasetArtifactInput("game_config", result.GameConfigObservation),
        new DatasetArtifactInput("staticdata_catalog", result.StaticDataObservation)
      ]);
      var requestSha256 = ImportRequestFingerprint.Create(
          manifest.CanonicalSha256,
          Extractor.FingerprintSha256,
          SemanticOptionsFingerprint.Empty);
      var uidGenerator = new RandomEntityUidGenerator();
      var diagnostics = result.Extraction.Diagnostics.Select(item => new SafeDiagnostic(
          ImportDiagnosticSeverity.Warning,
          "catalog",
          item.Code,
          item.OccurrenceCount)).ToArray();
      var attempt = new CompletedImportAttempt(
          uidGenerator.NewUid(),
          uidGenerator.NewUid(),
          manifest.Artifacts
              .Select(item => new ArtifactRegistration(uidGenerator.NewUid(), item))
              .ToArray(),
          manifest,
          Extractor,
          SemanticOptionsFingerprint.Empty,
          requestSha256,
          result.Extraction.CanonicalCandidateSha256,
          diagnostics,
          startedAt,
          DateTimeOffset.UtcNow);
      var publication = new CharacterCatalogPublication(
          CharacterCatalogIdentityBinding.FromSecret(input.Secret),
          result.Extraction.Characters.Select(ToPublicationDefinition).ToArray());

      var connectionString = PostgreSqlConnectionPolicy.ResolveFromEnvironment(
          configuration.DatabaseConnectionStringEnvironmentVariable);
      await using var dataSource = PostgreSqlDataSourceFactory.Create(connectionString);
      await new PostgreSqlMigrationRunner().MigrateAsync(dataSource).ConfigureAwait(false);
      var store = new PostgreSqlCharacterCatalogImportStore(dataSource, uidGenerator);
      var receipt = await store.RecordCompletedAndPublishAsync(attempt, publication).ConfigureAwait(false);
      Console.WriteLine("character_catalog_imported");
      Console.WriteLine($"status={receipt.Import.Status.ToString().ToLowerInvariant()}");
      Console.WriteLine($"character_catalog_snapshot_uid={receipt.CharacterCatalogSnapshotUid}");
      Console.WriteLine($"catalog_manifest_sha256={receipt.CatalogManifestSha256}");
      Console.WriteLine($"character_count={receipt.Members.Count}");
      return 0;
    }
    finally
    {
      CryptographicOperations.ZeroMemory(input.Secret);
    }
  }

  private static async Task<CompoundReadResult> ReadStableAsync(CharacterCatalogInput input)
  {
    var staticBefore = await input.StaticDataSource.ObserveAsync().ConfigureAwait(false);
    var configBefore = await input.GameConfigSource.ObserveAsync().ConfigureAwait(false);
    var runtimeCaps = await input.GameConfigSource.ReadAsync(
        (stream, _) => Task.FromResult(new SdBinCharacterConfigReader().Read(stream)))
        .ConfigureAwait(false);
    var extraction = await input.StaticDataSource.ReadAsync(
        (stream, _) => Task.FromResult(
            new StaticDataCharacterCatalogReader().Read(stream, input.Secret, runtimeCaps)))
        .ConfigureAwait(false);
    var staticAfter = await input.StaticDataSource.ObserveAsync().ConfigureAwait(false);
    var configAfter = await input.GameConfigSource.ObserveAsync().ConfigureAwait(false);
    if (staticBefore != staticAfter || configBefore != configAfter)
    {
      throw new CharacterCatalogSourceException("source_changed_during_import");
    }

    return new CompoundReadResult(extraction, staticBefore, configBefore);
  }

  private static CharacterCatalogDefinition ToPublicationDefinition(
      ImportedCharacterDefinitionCandidate candidate)
  {
    var content = CharacterDefinitionContentFactory.Create(candidate);
    return new CharacterCatalogDefinition(
        candidate.AliasFingerprint,
        CharacterDefinitionCanonicalizer.ComputeContentHash(content),
        new CharacterCatalogTextFact(
            CharacterCatalogFactStatus.Unresolved,
            unresolvedReasonCode: "locale_not_imported"),
        MapCode(candidate.Rarity, value => value switch
        {
          "r" => CharacterRarityCode.R,
          "sr" => CharacterRarityCode.Sr,
          "ssr" => CharacterRarityCode.Ssr,
          _ => throw new CharacterCatalogIntegrityException("rarity_mapping_invalid")
        }),
        MapCode(candidate.CharacterClass, value => value switch
        {
          "attacker" => CharacterCombatClassCode.Attacker,
          "defender" => CharacterCombatClassCode.Defender,
          "supporter" => CharacterCombatClassCode.Supporter,
          _ => throw new CharacterCatalogIntegrityException("combat_class_mapping_invalid")
        }),
        MapCode(candidate.Weapon, value => value switch
        {
          "ar" => CharacterWeaponCode.AssaultRifle,
          "mg" => CharacterWeaponCode.MachineGun,
          "rl" => CharacterWeaponCode.RocketLauncher,
          "sg" => CharacterWeaponCode.Shotgun,
          "sr" => CharacterWeaponCode.SniperRifle,
          "smg" => CharacterWeaponCode.SubmachineGun,
          _ => throw new CharacterCatalogIntegrityException("weapon_mapping_invalid")
        }),
        MapCode(candidate.Element, value => value switch
        {
          "electric" => CharacterElementCode.Electric,
          "fire" => CharacterElementCode.Fire,
          "iron" => CharacterElementCode.Iron,
          "water" => CharacterElementCode.Water,
          "wind" => CharacterElementCode.Wind,
          _ => throw new CharacterCatalogIntegrityException("element_mapping_invalid")
        }),
        MapCode(candidate.Manufacturer, value => value switch
        {
          "abnormal" => CharacterManufacturerCode.Abnormal,
          "elysion" => CharacterManufacturerCode.Elysion,
          "missilis" => CharacterManufacturerCode.Missilis,
          "pilgrim" => CharacterManufacturerCode.Pilgrim,
          "tetra" => CharacterManufacturerCode.Tetra,
          _ => throw new CharacterCatalogIntegrityException("manufacturer_mapping_invalid")
        }),
        CreateCapabilities(candidate),
        CreateEquipment(candidate));
  }

  private static CharacterCatalogValueFact<T> MapCode<T>(
      ImportedCodeFact fact,
      Func<string, T> mapper)
      where T : struct => fact.Status switch
      {
        ImportedFactStatus.Ready => new CharacterCatalogValueFact<T>(
            CharacterCatalogFactStatus.Ready,
            mapper(fact.Value!)),
        ImportedFactStatus.Unresolved => new CharacterCatalogValueFact<T>(
            CharacterCatalogFactStatus.Unresolved,
            unresolvedReasonCode: fact.ReasonCode),
        _ => throw new CharacterCatalogIntegrityException("profile_fact_invalid")
      };

  private static IReadOnlyList<CharacterCatalogCapability> CreateCapabilities(
      ImportedCharacterDefinitionCandidate candidate) =>
  [
      MapLevel(CharacterCapabilityCode.CharacterLevel, candidate.MaximumCharacterLevel),
    MapLevel(CharacterCapabilityCode.LimitBreak, candidate.MaximumLimitBreak),
    MapLevel(CharacterCapabilityCode.CoreLevel, candidate.MaximumCore),
    MapLevel(CharacterCapabilityCode.BondLevel, candidate.MaximumBond),
    MapLevel(CharacterCapabilityCode.Cube, candidate.MaximumCubeLevel),
    MapLevel(CharacterCapabilityCode.Skill1, candidate.MaximumSkill1),
    MapLevel(CharacterCapabilityCode.Skill2, candidate.MaximumSkill2),
    MapLevel(CharacterCapabilityCode.Burst, candidate.MaximumBurstSkill),
    MapLevel(CharacterCapabilityCode.CollectionItem, candidate.MaximumCollectionLevel),
    MapLevel(CharacterCapabilityCode.FavoriteItem, candidate.MaximumFavoriteItemLevel)
  ];

  private static IReadOnlyList<CharacterCatalogEquipmentCapability> CreateEquipment(
      ImportedCharacterDefinitionCandidate candidate) =>
      Enum.GetValues<CharacterEquipmentSlot>()
          .Select(slot => new CharacterCatalogEquipmentCapability(
              slot,
              new CharacterCatalogValueFact<EntityUid>(
                  CharacterCatalogFactStatus.Unresolved,
                  unresolvedReasonCode: "equipment_definition_unselected"),
              MapValue(candidate.MaximumEquipmentTier),
              MapValue(candidate.MaximumEquipmentEnhancement),
              new CharacterCatalogValueFact<bool>(
                  CharacterCatalogFactStatus.Unresolved,
                  unresolvedReasonCode: "manufacturer_match_unselected")))
          .ToArray();

  private static CharacterCatalogCapability MapLevel(
      CharacterCapabilityCode code,
      ImportedIntegerFact fact) => fact.Status switch
      {
        ImportedFactStatus.Ready => new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.Ready,
            maximumLevel: fact.Value),
        ImportedFactStatus.Unresolved => new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.Unresolved,
            unresolvedReasonCode: fact.ReasonCode),
        ImportedFactStatus.NotApplicable => new CharacterCatalogCapability(
            code,
            CharacterCatalogFactStatus.NotApplicable),
        _ => throw new CharacterCatalogIntegrityException("capability_fact_invalid")
      };

  private static CharacterCatalogValueFact<int> MapValue(ImportedIntegerFact fact) =>
      fact.Status switch
      {
        ImportedFactStatus.Ready => new CharacterCatalogValueFact<int>(
            CharacterCatalogFactStatus.Ready,
            fact.Value),
        ImportedFactStatus.Unresolved => new CharacterCatalogValueFact<int>(
            CharacterCatalogFactStatus.Unresolved,
            unresolvedReasonCode: fact.ReasonCode),
        ImportedFactStatus.NotApplicable => new CharacterCatalogValueFact<int>(
            CharacterCatalogFactStatus.NotApplicable),
        _ => throw new CharacterCatalogIntegrityException("capability_fact_invalid")
      };

  private static CharacterCatalogInput RequireInput(
      ResolvedLabConfiguration configuration,
      string repositoryRoot,
      IReadOnlyDictionary<string, string> options)
  {
    if (!options.TryGetValue("static-root", out var staticRoot) ||
        !options.TryGetValue("static-file", out var staticFile))
    {
      throw new LabConfigurationException("character_catalog_source_option_missing");
    }

    var gameConfigFile = options.TryGetValue("game-config-file", out var configuredGameFile)
        ? configuredGameFile
        : DefaultGameConfigRelativePath;
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
      var staticSource = new ReadOnlySourceRoot(
          staticRoot,
          repositoryRoot,
          configuration.RuntimeRoot)
          .Bind(SourceRelativePath.Parse(staticFile), "staticdata_archive");
      var gameConfigSource = new ReadOnlySourceRoot(
          configuration.GameRoot,
          repositoryRoot,
          configuration.RuntimeRoot)
          .Bind(SourceRelativePath.Parse(gameConfigFile), "game_config_archive");
      return new CharacterCatalogInput(staticSource, gameConfigSource, secret);
    }
    catch
    {
      CryptographicOperations.ZeroMemory(secret);
      throw;
    }
  }

  private sealed record CharacterCatalogInput(
      IImportArtifactSource StaticDataSource,
      IImportArtifactSource GameConfigSource,
      byte[] Secret);

  private sealed record CompoundReadResult(
      CharacterCatalogExtraction Extraction,
      SourceArtifactObservation StaticDataObservation,
      SourceArtifactObservation GameConfigObservation);
}
