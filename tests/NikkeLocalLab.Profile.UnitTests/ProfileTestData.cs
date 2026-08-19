namespace NikkeLocalLab.Profile.UnitTests;

internal static class ProfileTestData
{
  public static readonly DateTimeOffset Timestamp =
      new(2026, 8, 19, 0, 0, 0, TimeSpan.Zero);

  public static EntityUid Uid(int value) => new(new Guid(value, 0, 0, new byte[8]));

  public static ProfileDatasetBinding Binding(
      int characterDataset = 100,
      int supportDataset = 200) =>
      new(
          new ProfileCatalogBinding(
              Uid(characterDataset + 1_000),
              Uid(characterDataset),
              Sha256Digest.ComputeUtf8($"character-{characterDataset}")),
          new ProfileCatalogBinding(
              Uid(supportDataset + 1_000),
              Uid(supportDataset),
              Sha256Digest.ComputeUtf8($"support-{supportDataset}")));

  public static ProfileCatalogEvidence Evidence(
      IEnumerable<CharacterDefinitionVersion> characterVersions,
      IEnumerable<CombatSupportDefinitionVersion> combatSupportVersions,
      int characterCatalogSnapshotUid = 1_100,
      int supportCatalogSnapshotUid = 1_200)
  {
    var characters = characterVersions.ToArray();
    var support = combatSupportVersions.ToArray();
    var characterManifest = CharacterCatalogManifest.Create(characters);
    var supportManifest = CombatSupportCatalogManifest.Create(support);
    var binding = new ProfileDatasetBinding(
        new ProfileCatalogBinding(
            Uid(characterCatalogSnapshotUid),
            characterManifest.DatasetSnapshotUid,
            characterManifest.Sha256),
        new ProfileCatalogBinding(
            Uid(supportCatalogSnapshotUid),
            supportManifest.DatasetSnapshotUid,
            supportManifest.Sha256));
    return ProfileCatalogEvidence.RestoreTrustedCatalogSnapshot(
        binding,
        characterManifest,
        characters,
        supportManifest,
        support);
  }

  public static ProfileRevisionProvenance Provenance(
      ProfileRevisionOrigin origin = ProfileRevisionOrigin.UserEdit,
      EntityUid? previous = null) =>
      new(origin, Timestamp, previous);

  public static LocalAccount Account(int uid = 1) => new(Uid(uid), Timestamp);

  public static CharacterDefinitionVersion CharacterVersion(
      int characterUid = 10,
      int versionUid = 11,
      int datasetUid = 100,
      bool hasFavorite = false,
      NormalizedFact<CombatRole>? combatRole = null,
      NormalizedFact<CharacterRarity>? rarity = null,
      NormalizedFact<WeaponClass>? weaponClass = null,
      NormalizedFact<NikkeElement>? element = null,
      NormalizedFact<Manufacturer>? manufacturer = null)
  {
    var equipment = Enum.GetValues<EquipmentSlot>().Select(slot =>
        new EquipmentSlotCapability(
            slot,
            NormalizedFact<EntityUid>.Unresolved("phase1b_equipment_reference_unresolved"),
            NormalizedFact<int>.Ready(10),
            NormalizedFact<int>.Ready(5),
            NormalizedFact<bool>.Unresolved("manufacturer_match_requires_profile_input")));
    var content = new CharacterDefinitionContent(
        new CharacterProfile(
            rarity ?? NormalizedFact<CharacterRarity>.Ready(CharacterRarity.SSR),
            combatRole ?? NormalizedFact<CombatRole>.Ready(CombatRole.Attacker),
            weaponClass ?? NormalizedFact<WeaponClass>.Ready(WeaponClass.AssaultRifle),
            element ?? NormalizedFact<NikkeElement>.Ready(NikkeElement.Fire),
            manufacturer ?? NormalizedFact<Manufacturer>.Ready(Manufacturer.Elysion)),
        new CharacterCapabilities(
            NormalizedFact<int>.Ready(400),
            NormalizedFact<int>.Ready(3),
            NormalizedFact<int>.Ready(7),
            NormalizedFact<int>.Ready(40),
            equipment,
            new SkillMaximums(
                NormalizedFact<int>.Ready(10),
                NormalizedFact<int>.Ready(10),
                NormalizedFact<int>.Ready(10)),
            NormalizedFact<int>.Ready(15),
            NormalizedFact<int>.Ready(15),
            hasFavorite
                ? NormalizedFact<int>.Ready(2)
                : NormalizedFact<int>.NotApplicable()));
    return CharacterDefinitionVersion.Create(
        Uid(versionUid),
        new CharacterDefinition(Uid(characterUid)),
        Uid(datasetUid),
        content);
  }

  public static CombatSupportDefinitionVersion Equipment(
      CombatSupportEquipmentSlot slot,
      int tier,
      int uid,
      int versionUid,
      CombatSupportCombatRole role = CombatSupportCombatRole.Attacker,
      int datasetUid = 200,
      CombatSupportFact<CombatSupportManufacturer>? manufacturer = null)
  {
    var stats = new[]
    {
      new CombatSupportStatContribution(
          0,
          CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.Attack),
          CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute),
          new CombatSupportExactValue(100, 0)),
      new CombatSupportStatContribution(
          1,
          CombatSupportFact<CombatSupportStat>.Ready(CombatSupportStat.Hp),
          CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute),
          new CombatSupportExactValue(1_000, 0))
    };
    var optionSlots = tier == 10
        ? new[]
        {
          new CombatSupportEquipmentOptionSlot(0, new CombatSupportExactValue(10_000, 4)),
          new CombatSupportEquipmentOptionSlot(1, new CombatSupportExactValue(5_000, 4)),
          new CombatSupportEquipmentOptionSlot(2, new CombatSupportExactValue(3_000, 4))
        }
        : new[]
        {
          new CombatSupportEquipmentOptionSlot(0, new CombatSupportExactValue(0, 4)),
          new CombatSupportEquipmentOptionSlot(1, new CombatSupportExactValue(0, 4)),
          new CombatSupportEquipmentOptionSlot(2, new CombatSupportExactValue(0, 4))
        };
    var content = new EquipmentDefinitionContent(
        slot,
        CombatSupportFact<CombatSupportCombatRole>.Ready(role),
        manufacturer ?? CombatSupportFact<CombatSupportManufacturer>.NotApplicable(),
        CombatSupportFact<int>.Ready(tier),
        CombatSupportFact<int>.Ready(0),
        CombatSupportFact<int>.Ready(5),
        CombatSupportFact<bool>.Ready(tier == 10),
        stats,
        optionSlots);
    return SupportVersion(uid, versionUid, datasetUid, content);
  }

  public static CombatSupportDefinitionVersion Console(
      CombatSupportConsoleCoordinate coordinate,
      int uid,
      int versionUid,
      int datasetUid = 200)
  {
    var levels = Enumerable.Range(1, 3).Select(level =>
        new CombatSupportLevelCoordinate(
            level,
            CombatSupportFact<int>.NotApplicable(),
            CombatSupportFact<int>.NotApplicable(),
            Array.Empty<int>(),
            Array.Empty<CombatSupportStatContribution>(),
            CombatSupportFact<int>.Ready(level * 10)));
    var contributions = new[]
    {
      Contribution(0, CombatSupportStat.Attack, coordinate is >= CombatSupportConsoleCoordinate.Elysion ? 25 : 0),
      Contribution(1, CombatSupportStat.Defence, coordinate == CombatSupportConsoleCoordinate.Common ? 0 : 5),
      Contribution(2, CombatSupportStat.Hp, coordinate == CombatSupportConsoleCoordinate.Common ? 450 : 750)
    };
    return SupportVersion(
        uid,
        versionUid,
        datasetUid,
        new ConsoleDefinitionContent(
            coordinate,
            CombatSupportFact<int>.Ready(3),
            levels,
            contributions));
  }

  public static CombatSupportDefinitionVersion OverloadOption(
      CombatSupportOverloadOptionType type,
      int uid,
      int versionUid,
      int datasetUid = 200,
      CombatSupportFact<CombatSupportOverloadDuplicatePolicy>? duplicatePolicy = null)
  {
    var negative = type is CombatSupportOverloadOptionType.ChargeSpeed or
        CombatSupportOverloadOptionType.HitRate;
    var bands = Enumerable.Range(0, 3).Select(band =>
    {
      var values = Enumerable.Range((band * 5) + 1, 5).Select(level =>
      {
        var magnitude = 400 + (level * 10);
        return new CombatSupportOverloadLegalValue(
            level,
            negative ? -magnitude : magnitude,
            magnitude,
            new CombatSupportExactValue(magnitude, 4));
      });
      return new CombatSupportOverloadLegalBand(
          band,
          band switch
          {
            0 => new CombatSupportExactValue(6_000, 4),
            1 => new CombatSupportExactValue(3_500, 4),
            _ => new CombatSupportExactValue(500, 4)
          },
          values);
    });
    var weight = type is CombatSupportOverloadOptionType.Attack or
        CombatSupportOverloadOptionType.Defence or
        CombatSupportOverloadOptionType.CriticalDamage or
        CombatSupportOverloadOptionType.ElementalDamage
        ? new CombatSupportExactValue(10, 2)
        : new CombatSupportExactValue(12, 2);
    return SupportVersion(
        uid,
        versionUid,
        datasetUid,
        new OverloadOptionDefinitionContent(
            CombatSupportFact<CombatSupportOverloadOptionType>.Ready(type),
            CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Ratio),
            weight,
            bands,
            duplicatePolicy ?? CombatSupportFact<CombatSupportOverloadDuplicatePolicy>.Unresolved(
                "same_equipment_duplicate_policy_unresolved")));
  }

  public static CombatSupportDefinitionVersion Cube(
      int uid = 400,
      int versionUid = 401,
      int datasetUid = 200,
      CombatSupportFact<CombatSupportCombatRole>? applicableCombatRole = null)
  {
    var levels = Enumerable.Range(1, 15).Select(level =>
        new CombatSupportLevelCoordinate(
            level,
            CombatSupportFact<int>.NotApplicable(),
            CombatSupportFact<int>.Ready(level),
            new[] { level, level, level },
            Array.Empty<CombatSupportStatContribution>()));
    return SupportVersion(
        uid,
        versionUid,
        datasetUid,
        new HarmonyCubeDefinitionContent(
            CombatSupportFact<CombatSupportRarity>.Ready(CombatSupportRarity.Ssr),
            applicableCombatRole ?? CombatSupportFact<CombatSupportCombatRole>.NotApplicable(),
            CombatSupportFact<int>.Ready(15),
            levels,
            CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported")));
  }

  public static CombatSupportDefinitionVersion Collection(
      CombatSupportRarity rarity,
      int uid,
      int versionUid,
      int datasetUid = 200)
  {
    var levels = Enumerable.Range(0, 16).Select(level => CollectionLevel(level));
    return SupportVersion(
        uid,
        versionUid,
        datasetUid,
        new GenericCollectionDefinitionContent(
            CombatSupportFact<CombatSupportWeaponClass>.Ready(CombatSupportWeaponClass.AssaultRifle),
            CombatSupportFact<CombatSupportRarity>.Ready(rarity),
            CombatSupportFact<int>.Ready(15),
            levels,
            CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported")));
  }

  public static CombatSupportDefinitionVersion Favorite(
      EntityUid characterUid,
      int uid = 500,
      int versionUid = 501,
      int datasetUid = 200)
  {
    var levels = Enumerable.Range(0, 3).Select(level => CollectionLevel(level));
    return SupportVersion(
        uid,
        versionUid,
        datasetUid,
        new FavoriteDefinitionContent(
            CombatSupportFact<EntityUid>.Ready(characterUid),
            CombatSupportFact<CombatSupportRarity>.Ready(CombatSupportRarity.Ssr),
            CombatSupportFact<int>.Ready(2),
            levels,
            CombatSupportFact<bool>.Unresolved("skill_definition_catalog_not_imported")));
  }

  public static SyntheticSupportCatalog SupportCatalog(bool includeFavorite = false, EntityUid? characterUid = null)
  {
    var equipment10 = Enum.GetValues<CombatSupportEquipmentSlot>()
        .Select((slot, index) => Equipment(slot, 10, 300 + index, 310 + index))
        .ToArray();
    var equipment9 = Enum.GetValues<CombatSupportEquipmentSlot>()
        .Select((slot, index) => Equipment(slot, 9, 320 + index, 330 + index))
        .ToArray();
    var consoles = Enum.GetValues<CombatSupportConsoleCoordinate>()
        .Select((coordinate, index) => Console(coordinate, 600 + index, 620 + index))
        .ToArray();
    var attack = OverloadOption(CombatSupportOverloadOptionType.Attack, 700, 701);
    var chargeSpeed = OverloadOption(CombatSupportOverloadOptionType.ChargeSpeed, 702, 703);
    var cube = Cube();
    var collectionR = Collection(CombatSupportRarity.R, 800, 801);
    var collectionSr = Collection(CombatSupportRarity.Sr, 802, 803);
    var favorite = Favorite(
        includeFavorite
            ? characterUid ?? throw new ArgumentNullException(nameof(characterUid))
            : Uid(9_999));
    return new SyntheticSupportCatalog(
        equipment10,
        equipment9,
        consoles,
        attack,
        chargeSpeed,
        cube,
        collectionR,
        collectionSr,
        favorite);
  }

  public static CharacterBuildRevision ExplicitBuild(
      int buildUid,
      int revisionUid,
      int characterUid,
      SyntheticSupportCatalog catalog,
      LocalAccount? account = null,
      IEnumerable<CharacterOverloadLineInput>? headLines = null,
      CharacterCubeInput? cube = null,
      CharacterCollectibleInput? collectible = null,
      ProfileValidationMode validationMode = ProfileValidationMode.Research,
      int characterVersionUid = 11,
      CharacterDefinitionVersion? characterDefinitionVersion = null,
      ProfileCatalogEvidence? catalogEvidence = null)
  {
    var localAccount = account ?? Account();
    var character = characterDefinitionVersion ?? CharacterVersion(characterUid, characterVersionUid);
    var build = new CharacterBuild(Uid(buildUid), localAccount, character.CharacterUid);
    var equipment = catalog.EquipmentT10.Select((definition, index) =>
        CharacterEquipmentInput.EquippedWith(
            Uid(2_000 + buildUid + index),
            definition,
            ProfileFact<int>.Ready(5),
            ProfileFact<bool>.Ready(true),
            index == 0 ? headLines : null));
    var selectedSupport = catalog.All
        .Concat((headLines ?? Array.Empty<CharacterOverloadLineInput>())
            .Select(static line => line.OptionDefinitionVersion))
        .GroupBy(static version => version.DefinitionVersionUid)
        .Select(static group => group.First())
        .ToArray();
    var evidence = catalogEvidence ?? Evidence(new[] { character }, selectedSupport);
    return CharacterBuildRevision.CreateExplicit(
        Uid(revisionUid),
        build,
        1,
        Provenance(),
        evidence,
        character,
        validationMode,
        new CharacterInvestmentState(
            200,
            ProfileFact<int>.Ready(3),
            ProfileFact<int>.Ready(7),
            ProfileFact<int>.Ready(40)),
        new CharacterSkillState(
            ProfileFact<int>.Ready(10),
            ProfileFact<int>.Ready(10),
            ProfileFact<int>.Ready(10)),
        equipment,
        cube ?? CharacterCubeInput.Detached(),
        collectible ?? CharacterCollectibleInput.Detached());
  }

  public static AccountCombatStateRevision AccountState(
      LocalAccount account,
      SyntheticSupportCatalog catalog,
      ProfileValidationMode mode = ProfileValidationMode.Research,
      ProfileFact<long>? experience = null,
      int synchroLevel = 50,
      int consoleLevel = 1,
      ProfileCatalogEvidence? catalogEvidence = null)
  {
    var state = new AccountCombatState(Uid(50), account);
    var inputs = catalog.Consoles.Select(definition =>
        new ConsoleProgressInput(
            definition,
            ProfileFact<int>.Ready(consoleLevel),
            experience ?? ProfileFact<long>.Ready(0)));
    var evidence = catalogEvidence ?? Evidence(new[] { CharacterVersion() }, catalog.All);
    return AccountCombatStateRevision.Create(
        Uid(51),
        state,
        1,
        Provenance(),
        evidence,
        mode,
        ProfileFact<int>.Ready(synchroLevel),
        inputs);
  }

  private static CombatSupportDefinitionVersion SupportVersion(
      int uid,
      int versionUid,
      int datasetUid,
      ICombatSupportDefinitionContent content) =>
      CombatSupportDefinitionVersion.Create(
          Uid(versionUid),
          new CombatSupportDefinition(Uid(uid)),
          Uid(datasetUid),
          content);

  private static CombatSupportStatContribution Contribution(
      int ordinal,
      CombatSupportStat stat,
      int value) =>
      new(
          ordinal,
          CombatSupportFact<CombatSupportStat>.Ready(stat),
          CombatSupportFact<CombatSupportValueUnit>.Ready(CombatSupportValueUnit.Absolute),
          new CombatSupportExactValue(value, 0));

  private static CombatSupportLevelCoordinate CollectionLevel(int level) =>
      new(
          level,
          CombatSupportFact<int>.Ready(level),
          CombatSupportFact<int>.NotApplicable(),
          new[] { level, level },
          Array.Empty<CombatSupportStatContribution>());
}

internal sealed record SyntheticSupportCatalog(
    IReadOnlyList<CombatSupportDefinitionVersion> EquipmentT10,
    IReadOnlyList<CombatSupportDefinitionVersion> EquipmentT9,
    IReadOnlyList<CombatSupportDefinitionVersion> Consoles,
    CombatSupportDefinitionVersion AttackOption,
    CombatSupportDefinitionVersion ChargeSpeedOption,
    CombatSupportDefinitionVersion Cube,
    CombatSupportDefinitionVersion CollectionR,
    CombatSupportDefinitionVersion CollectionSr,
    CombatSupportDefinitionVersion? Favorite)
{
  public IReadOnlyList<CombatSupportDefinitionVersion> All =>
      EquipmentT10.Concat(EquipmentT9).Concat(Consoles)
          .Concat(new[] { AttackOption, ChargeSpeedOption, Cube, CollectionR, CollectionSr })
          .Concat(Favorite is null ? Array.Empty<CombatSupportDefinitionVersion>() : new[] { Favorite })
          .ToArray();
}
