namespace NikkeLocalLab.Character.UnitTests;

internal static class CharacterTestData
{
  public static CharacterDefinitionContent ReadyContent(
      NormalizedFact<int>? maximumCharacterLevel = null,
      NormalizedFact<int>? maximumCoreLevel = null,
      NormalizedFact<int>? maximumCubeLevel = null,
      NormalizedFact<int>? maximumCollectionLevel = null,
      NormalizedFact<int>? maximumFavoriteLevel = null,
      SkillMaximums? skillMaximums = null,
      IEnumerable<EquipmentSlotCapability>? equipment = null,
      CharacterProfile? profile = null)
  {
    return new CharacterDefinitionContent(
        profile ?? ReadyProfile(),
        new CharacterCapabilities(
            maximumCharacterLevel ?? NormalizedFact<int>.Ready(400),
            NormalizedFact<int>.Ready(3),
            maximumCoreLevel ?? NormalizedFact<int>.Ready(7),
            NormalizedFact<int>.Ready(30),
            equipment ?? ReadyEquipment(),
            skillMaximums ?? ReadySkills(),
            maximumCubeLevel ?? NormalizedFact<int>.Ready(15),
            maximumCollectionLevel ?? NormalizedFact<int>.Ready(15),
            maximumFavoriteLevel ?? NormalizedFact<int>.NotApplicable()));
  }

  public static CharacterProfile ReadyProfile() => new(
      NormalizedFact<CharacterRarity>.Ready(CharacterRarity.SSR),
      NormalizedFact<CombatRole>.Ready(CombatRole.Attacker),
      NormalizedFact<WeaponClass>.Ready(WeaponClass.RocketLauncher),
      NormalizedFact<NikkeElement>.Ready(NikkeElement.Electric),
      NormalizedFact<Manufacturer>.Ready(Manufacturer.Missilis));

  public static SkillMaximums ReadySkills() => new(
      NormalizedFact<int>.Ready(10),
      NormalizedFact<int>.Ready(10),
      NormalizedFact<int>.Ready(10));

  public static IReadOnlyList<EquipmentSlotCapability> ReadyEquipment(
      Func<EquipmentSlot, NormalizedFact<EntityUid>>? uidFactory = null,
      Func<EquipmentSlot, NormalizedFact<int>>? tierFactory = null,
      Func<EquipmentSlot, NormalizedFact<int>>? enhancementFactory = null,
      Func<EquipmentSlot, NormalizedFact<bool>>? manufacturerMatchFactory = null)
  {
    uidFactory ??= slot => NormalizedFact<EntityUid>.Ready(Uid(100 + (int)slot));
    tierFactory ??= _ => NormalizedFact<int>.Ready(10);
    enhancementFactory ??= _ => NormalizedFact<int>.Ready(5);
    manufacturerMatchFactory ??= _ => NormalizedFact<bool>.Ready(true);

    return Enum.GetValues<EquipmentSlot>()
        .Select(slot => new EquipmentSlotCapability(
            slot,
            uidFactory(slot),
            tierFactory(slot),
            enhancementFactory(slot),
            manufacturerMatchFactory(slot)))
        .ToArray();
  }

  public static CharacterDefinitionVersion Version(
      CharacterDefinitionContent? content = null,
      int characterUid = 1,
      int versionUid = 2,
      int datasetUid = 3) =>
      CharacterDefinitionVersion.Create(
          Uid(versionUid),
          new CharacterDefinition(Uid(characterUid)),
          Uid(datasetUid),
          content ?? ReadyContent());

  public static EntityUid Uid(int suffix) => new(Guid.Parse($"00000000-0000-4000-8000-{suffix:D12}"));
}
