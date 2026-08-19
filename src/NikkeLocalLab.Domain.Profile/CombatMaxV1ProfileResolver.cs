using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Domain.Profile;

public sealed class CombatMaxEquipmentSlotRequest
{
  public CombatMaxEquipmentSlotRequest(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      ProfileFact<bool> manufacturerMatch)
  {
    EquipmentSlotUid = ProfileGuard.RequireUid(equipmentSlotUid, nameof(equipmentSlotUid));
    Slot = ProfileGuard.RequireEnum(slot, nameof(slot));
    ManufacturerMatch = ProfileGuard.RequireFact(manufacturerMatch, nameof(manufacturerMatch));
    if (ManufacturerMatch.Status == ProfileFactStatus.NotApplicable)
    {
      throw new ArgumentException("Manufacturer match is applicable to combat-max equipment.", nameof(manufacturerMatch));
    }
  }

  public EntityUid EquipmentSlotUid { get; }

  public CombatSupportEquipmentSlot Slot { get; }

  public ProfileFact<bool> ManufacturerMatch { get; }
}

public sealed class CombatMaxV1ProfileRequest
{
  public CombatMaxV1ProfileRequest(
      EntityUid characterBuildRevisionUid,
      CharacterBuild build,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      CharacterDefinitionVersion characterDefinitionVersion,
      int explicitCharacterLevel,
      ProfileValidationMode validationMode,
      IEnumerable<CombatMaxEquipmentSlotRequest> equipmentSlots,
      IEnumerable<CombatSupportDefinitionVersion> combatSupportDefinitions)
  {
    if (explicitCharacterLevel <= 0)
    {
      throw new ArgumentOutOfRangeException(nameof(explicitCharacterLevel));
    }

    CharacterBuildRevisionUid = ProfileGuard.RequireUid(
        characterBuildRevisionUid,
        nameof(characterBuildRevisionUid));
    Build = build ?? throw new ArgumentNullException(nameof(build));
    RevisionNumber = revisionNumber;
    Provenance = provenance ?? throw new ArgumentNullException(nameof(provenance));
    CatalogEvidence = catalogEvidence ?? throw new ArgumentNullException(nameof(catalogEvidence));
    CharacterDefinitionVersion = characterDefinitionVersion ??
        throw new ArgumentNullException(nameof(characterDefinitionVersion));
    ExplicitCharacterLevel = explicitCharacterLevel;
    ValidationMode = ProfileGuard.RequireEnum(validationMode, nameof(validationMode));
    ArgumentNullException.ThrowIfNull(equipmentSlots);
    ArgumentNullException.ThrowIfNull(combatSupportDefinitions);
    var slots = equipmentSlots.ToArray();
    var expected = Enum.GetValues<CombatSupportEquipmentSlot>();
    if (slots.Any(static slot => slot is null) ||
        slots.Length != expected.Length ||
        slots.GroupBy(static slot => slot.Slot).Any(static group => group.Count() != 1) ||
        slots.GroupBy(static slot => slot.EquipmentSlotUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("combat-max/v1 requires four unique local equipment-slot identities.", nameof(equipmentSlots));
    }

    EquipmentSlots = Array.AsReadOnly(
        expected.Select(slot => slots.Single(item => item.Slot == slot)).ToArray());
    var definitions = combatSupportDefinitions.ToArray();
    if (definitions.Any(static item => item is null))
    {
      throw new ArgumentException("Combat-support definitions cannot contain null entries.", nameof(combatSupportDefinitions));
    }

    CombatSupportDefinitions = Array.AsReadOnly(definitions);
    CatalogEvidence.RequireCharacter(CharacterDefinitionVersion, nameof(characterDefinitionVersion));
    CatalogEvidence.RequireCombatSupport(CombatSupportDefinitions, nameof(combatSupportDefinitions));
  }

  public EntityUid CharacterBuildRevisionUid { get; }

  public CharacterBuild Build { get; }

  public long RevisionNumber { get; }

  public ProfileRevisionProvenance Provenance { get; }

  public ProfileCatalogEvidence CatalogEvidence { get; }

  public ProfileDatasetBinding DatasetBinding => CatalogEvidence.DatasetBinding;

  public CharacterDefinitionVersion CharacterDefinitionVersion { get; }

  public int ExplicitCharacterLevel { get; }

  public ProfileValidationMode ValidationMode { get; }

  public IReadOnlyList<CombatMaxEquipmentSlotRequest> EquipmentSlots { get; }

  public IReadOnlyList<CombatSupportDefinitionVersion> CombatSupportDefinitions { get; }
}

/// <summary>
/// Materializes combat-max/v1 from pinned Character and Phase 1D catalogs. It never consults legacy
/// Phase 1B equipment references and never invents synchro, console, cube, or manufacturer state.
/// </summary>
public sealed class CombatMaxV1ProfileResolver
{
  public const string PolicyId = "combat-max/v1";
  public const int EquipmentTier = 10;
  public const int EquipmentEnhancementLevel = 5;
  public const int SkillLevel = 10;

  public CharacterBuildRevision Resolve(CombatMaxV1ProfileRequest request)
  {
    ArgumentNullException.ThrowIfNull(request);
    if (request.Provenance.Origin != ProfileRevisionOrigin.CombatMaxV1)
    {
      throw new ArgumentException("combat-max/v1 requires combat-max provenance.", nameof(request));
    }

    var capabilities = request.CharacterDefinitionVersion.Content.Capabilities;
    var investment = new CharacterInvestmentState(
        request.ExplicitCharacterLevel,
        FromCharacterFact(capabilities.MaximumLimitBreak),
        FromCharacterFact(capabilities.MaximumCoreLevel),
        FromCharacterFact(capabilities.MaximumBondLevel));
    var skills = new CharacterSkillState(
        ResolveFixedSkill(capabilities.SkillMaximums.Skill1),
        ResolveFixedSkill(capabilities.SkillMaximums.Skill2),
        ResolveFixedSkill(capabilities.SkillMaximums.Burst));
    var equipment = ResolveEquipment(request).ToArray();
    var collectible = ResolveCollectible(request);

    return CharacterBuildRevision.CreateCore(
        request.CharacterBuildRevisionUid,
        request.Build,
        request.RevisionNumber,
        request.Provenance,
        request.CatalogEvidence,
        request.CharacterDefinitionVersion,
        CharacterBuildMaterializationPolicy.CombatMaxV1,
        request.ValidationMode,
        investment,
        skills,
        equipment,
        CharacterCubeInput.Detached(),
        collectible);
  }

  private static IEnumerable<CharacterEquipmentInput> ResolveEquipment(CombatMaxV1ProfileRequest request)
  {
    var characterRole = MapRole(request.CharacterDefinitionVersion.Content.Profile.CombatRole);
    foreach (var slot in request.EquipmentSlots)
    {
      if (characterRole is null)
      {
        yield return CharacterEquipmentInput.Unresolved(
            slot.EquipmentSlotUid,
            slot.Slot,
            "character_combat_role_unresolved");
        continue;
      }

      var matches = request.CombatSupportDefinitions.Where(version =>
          version.DatasetSnapshotUid == request.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid &&
          version.Content is EquipmentDefinitionContent equipment &&
          equipment.IsProfileSelectable &&
          equipment.Slot == slot.Slot &&
          equipment.Tier.Status == CombatSupportFactStatus.Ready &&
          equipment.Tier.Value == EquipmentTier &&
          equipment.CombatRole.Status == CombatSupportFactStatus.Ready &&
          equipment.CombatRole.Value == characterRole &&
          equipment.MaximumEnhancementLevel.Status == CombatSupportFactStatus.Ready &&
          equipment.MaximumEnhancementLevel.Value >= EquipmentEnhancementLevel).ToArray();
      if (matches.Length != 1)
      {
        yield return CharacterEquipmentInput.Unresolved(
            slot.EquipmentSlotUid,
            slot.Slot,
            matches.Length == 0
                ? "combat_max_equipment_definition_missing"
                : "combat_max_equipment_definition_ambiguous");
        continue;
      }

      yield return CharacterEquipmentInput.EquippedWith(
          slot.EquipmentSlotUid,
          matches[0],
          ProfileFact<int>.Ready(EquipmentEnhancementLevel),
          slot.ManufacturerMatch);
    }
  }

  private static CharacterCollectibleInput ResolveCollectible(CombatMaxV1ProfileRequest request)
  {
    var capabilities = request.CharacterDefinitionVersion.Content.Capabilities;
    if (capabilities.MaximumFavoriteLevel.Status == FactStatus.Unresolved)
    {
      return CharacterCollectibleInput.Unresolved(
          capabilities.MaximumFavoriteLevel.ReasonCode ?? "favorite_applicability_unresolved");
    }

    if (capabilities.MaximumFavoriteLevel.Status == FactStatus.Ready)
    {
      var favorites = request.CombatSupportDefinitions.Where(version =>
          version.DatasetSnapshotUid == request.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid &&
          version.Content is FavoriteDefinitionContent favorite &&
          favorite.ApplicableCharacterUid.Status == CombatSupportFactStatus.Ready &&
          favorite.ApplicableCharacterUid.Value == request.CharacterDefinitionVersion.CharacterUid).ToArray();
      if (favorites.Length != 1 || favorites[0].Content is not FavoriteDefinitionContent selectedFavorite ||
          selectedFavorite.MaximumLevel.Status != CombatSupportFactStatus.Ready)
      {
        return CharacterCollectibleInput.Unresolved("favorite_selection_not_unique");
      }

      return CharacterCollectibleInput.Favorite(
          favorites[0],
          ProfileFact<int>.Ready(selectedFavorite.MaximumLevel.RequireValue()));
    }

    if (capabilities.MaximumCollectionLevel.Status == FactStatus.NotApplicable)
    {
      return CharacterCollectibleInput.NotApplicable();
    }

    if (capabilities.MaximumCollectionLevel.Status == FactStatus.Unresolved)
    {
      return CharacterCollectibleInput.Unresolved(
          capabilities.MaximumCollectionLevel.ReasonCode ?? "collection_applicability_unresolved");
    }

    var weapon = MapWeapon(request.CharacterDefinitionVersion.Content.Profile.WeaponClass);
    if (weapon is null)
    {
      return CharacterCollectibleInput.Unresolved("collection_weapon_unresolved");
    }

    var candidates = request.CombatSupportDefinitions.Where(version =>
        version.DatasetSnapshotUid == request.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid &&
        version.Content is GenericCollectionDefinitionContent collection &&
        collection.ApplicableWeaponClass.Status == CombatSupportFactStatus.Ready &&
        collection.ApplicableWeaponClass.Value == weapon &&
        collection.Rarity.Status == CombatSupportFactStatus.Ready).ToArray();
    if (candidates.Length == 0)
    {
      return CharacterCollectibleInput.Unresolved("collection_selection_missing");
    }

    var highestRarity = candidates.Max(static version =>
        ((GenericCollectionDefinitionContent)version.Content).Rarity.RequireValue());
    var highest = candidates.Where(version =>
        ((GenericCollectionDefinitionContent)version.Content).Rarity.RequireValue() == highestRarity).ToArray();
    if (highest.Length != 1 || highest[0].Content is not GenericCollectionDefinitionContent selected ||
        selected.MaximumLevel.Status != CombatSupportFactStatus.Ready)
    {
      return CharacterCollectibleInput.Unresolved("collection_selection_not_unique");
    }

    return CharacterCollectibleInput.GenericCollection(
        highest[0],
        ProfileFact<int>.Ready(selected.MaximumLevel.RequireValue()));
  }

  private static ProfileFact<int> ResolveFixedSkill(NormalizedFact<int> maximum) => maximum.Status switch
  {
    FactStatus.Ready when maximum.RequireValue() >= SkillLevel => ProfileFact<int>.Ready(SkillLevel),
    FactStatus.Ready => ProfileFact<int>.Unresolved("level_ten_unsupported"),
    FactStatus.Unresolved => ProfileFact<int>.Unresolved(maximum.ReasonCode ?? "skill_maximum_unresolved"),
    FactStatus.NotApplicable => ProfileFact<int>.Unresolved("skill_not_applicable"),
    _ => throw new ArgumentOutOfRangeException(nameof(maximum))
  };

  private static ProfileFact<int> FromCharacterFact(NormalizedFact<int> fact) => fact.Status switch
  {
    FactStatus.Ready => ProfileFact<int>.Ready(fact.RequireValue()),
    FactStatus.Unresolved => ProfileFact<int>.Unresolved(fact.ReasonCode ?? "character_fact_unresolved"),
    FactStatus.NotApplicable => ProfileFact<int>.NotApplicable(),
    _ => throw new ArgumentOutOfRangeException(nameof(fact))
  };

  private static CombatSupportCombatRole? MapRole(NormalizedFact<CombatRole> role) => role.Status switch
  {
    FactStatus.Ready => role.RequireValue() switch
    {
      CombatRole.Attacker => CombatSupportCombatRole.Attacker,
      CombatRole.Defender => CombatSupportCombatRole.Defender,
      CombatRole.Supporter => CombatSupportCombatRole.Supporter,
      _ => throw new ArgumentOutOfRangeException(nameof(role))
    },
    _ => null
  };

  private static CombatSupportWeaponClass? MapWeapon(NormalizedFact<WeaponClass> weapon) => weapon.Status switch
  {
    FactStatus.Ready => weapon.RequireValue() switch
    {
      WeaponClass.AssaultRifle => CombatSupportWeaponClass.AssaultRifle,
      WeaponClass.RocketLauncher => CombatSupportWeaponClass.RocketLauncher,
      WeaponClass.SniperRifle => CombatSupportWeaponClass.SniperRifle,
      WeaponClass.MachineGun => CombatSupportWeaponClass.MachineGun,
      WeaponClass.Shotgun => CombatSupportWeaponClass.Shotgun,
      WeaponClass.SubmachineGun => CombatSupportWeaponClass.SubmachineGun,
      _ => throw new ArgumentOutOfRangeException(nameof(weapon))
    },
    _ => null
  };
}
