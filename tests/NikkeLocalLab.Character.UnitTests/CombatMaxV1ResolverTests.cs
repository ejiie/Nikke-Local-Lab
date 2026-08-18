namespace NikkeLocalLab.Character.UnitTests;

public sealed class CombatMaxV1ResolverTests
{
  private readonly CombatMaxV1Resolver _resolver = new();

  [Fact]
  public void Ready_definition_materializes_combat_max_v1_without_guessing_a_cube_or_overload()
  {
    var content = CharacterTestData.ReadyContent(
        maximumCoreLevel: NormalizedFact<int>.NotApplicable(),
        maximumCubeLevel: NormalizedFact<int>.Unresolved("cube_catalog_incomplete"),
        equipment: CharacterTestData.ReadyEquipment(
            manufacturerMatchFactory: slot => slot == EquipmentSlot.Legs
                ? NormalizedFact<bool>.NotApplicable()
                : NormalizedFact<bool>.Ready(true)));
    var version = CharacterTestData.Version(content);

    var resolution = _resolver.Resolve(version, explicitCharacterLevel: 200);

    Assert.Equal(CombatBuildReadiness.Ready, resolution.Status);
    Assert.Empty(resolution.Issues);
    Assert.Equal(CombatMaxV1Resolver.PolicyId, resolution.Seed.PolicyId);
    Assert.Equal(version.DatasetSnapshotUid, resolution.Seed.DatasetSnapshotUid);
    Assert.Equal(version.CharacterUid, resolution.Seed.CharacterUid);
    Assert.Equal(version.DefinitionVersionUid, resolution.Seed.DefinitionVersionUid);
    Assert.Equal(version.ContentSha256, resolution.Seed.DefinitionContentSha256);
    Assert.Equal(200, resolution.Seed.CharacterLevel);
    Assert.Equal(3, resolution.Seed.LimitBreak.RequireValue());
    Assert.Equal(FactStatus.NotApplicable, resolution.Seed.CoreLevel.Status);
    Assert.Equal(30, resolution.Seed.BondLevel.RequireValue());

    Assert.Equal(Enum.GetValues<EquipmentSlot>(), resolution.Seed.Equipment.Select(static item => item.Slot));
    Assert.All(resolution.Seed.Equipment, equipment =>
    {
      Assert.Equal(FactStatus.Ready, equipment.EquipmentDefinitionUid.Status);
      Assert.Equal(10, equipment.Tier.RequireValue());
      Assert.Equal(5, equipment.EnhancementLevel.RequireValue());
    });

    Assert.False(resolution.Seed.Cube.Equipped);
    Assert.Null(resolution.Seed.Cube.CubeUid);
    Assert.Null(resolution.Seed.Cube.Level);
    Assert.Equal(10, resolution.Seed.Skills.Skill1.RequireValue());
    Assert.Equal(10, resolution.Seed.Skills.Skill2.RequireValue());
    Assert.Equal(10, resolution.Seed.Skills.Burst.RequireValue());
    Assert.Empty(resolution.Seed.OverloadLines);
    Assert.Equal(15, resolution.Seed.CollectionLevel.RequireValue());
    Assert.Equal(FactStatus.NotApplicable, resolution.Seed.FavoriteLevel.Status);
  }

  [Fact]
  public void Missing_authority_produces_a_partial_seed_and_preserves_reason_codes()
  {
    var profile = new CharacterProfile(
        NormalizedFact<CharacterRarity>.Ready(CharacterRarity.SSR),
        NormalizedFact<CombatRole>.Ready(CombatRole.Supporter),
        NormalizedFact<WeaponClass>.Unresolved("weapon_mapping_missing"),
        NormalizedFact<NikkeElement>.Ready(NikkeElement.Water),
        NormalizedFact<Manufacturer>.Ready(Manufacturer.Tetra));
    var equipment = CharacterTestData.ReadyEquipment(
        uidFactory: slot => slot == EquipmentSlot.Head
            ? NormalizedFact<EntityUid>.Unresolved("equipment_selection_missing")
            : NormalizedFact<EntityUid>.Ready(CharacterTestData.Uid(100 + (int)slot)));
    var skills = new SkillMaximums(
        NormalizedFact<int>.Unresolved("skill_maximum_missing"),
        NormalizedFact<int>.Ready(10),
        NormalizedFact<int>.Ready(10));
    var version = CharacterTestData.Version(CharacterTestData.ReadyContent(
        profile: profile,
        equipment: equipment,
        skillMaximums: skills,
        maximumFavoriteLevel: NormalizedFact<int>.Unresolved("favorite_relation_missing")));

    var resolution = _resolver.Resolve(version, 200);

    Assert.Equal(CombatBuildReadiness.Unresolved, resolution.Status);
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "weapon_class" && issue.ReasonCode == "weapon_mapping_missing");
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "equipment_head_definition" &&
                 issue.ReasonCode == "equipment_selection_missing");
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "skill_1" && issue.ReasonCode == "skill_maximum_missing");
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "favorite_level" && issue.ReasonCode == "favorite_relation_missing");
    Assert.Equal(
        "equipment_selection_missing",
        resolution.Seed.Equipment.Single(item => item.Slot == EquipmentSlot.Head)
            .EquipmentDefinitionUid.ReasonCode);
    Assert.Equal("skill_maximum_missing", resolution.Seed.Skills.Skill1.ReasonCode);
    Assert.Equal(FactStatus.Unresolved, resolution.Seed.FavoriteLevel.Status);
  }

  [Fact]
  public void Unsupported_fixed_defaults_fail_closed_instead_of_fabricating_values()
  {
    var equipment = CharacterTestData.ReadyEquipment(
        tierFactory: slot => NormalizedFact<int>.Ready(slot == EquipmentSlot.Head ? 9 : 10));
    var skills = new SkillMaximums(
        NormalizedFact<int>.Ready(9),
        NormalizedFact<int>.Ready(10),
        NormalizedFact<int>.Ready(10));
    var version = CharacterTestData.Version(CharacterTestData.ReadyContent(
        maximumCharacterLevel: NormalizedFact<int>.Ready(100),
        equipment: equipment,
        skillMaximums: skills));

    var resolution = _resolver.Resolve(version, 200);

    Assert.Equal(CombatBuildReadiness.Invalid, resolution.Status);
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "character_level" && issue.ReasonCode == "above_snapshot_maximum");
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "equipment_head_tier" && issue.ReasonCode == "tier_ten_unsupported");
    Assert.Contains(
        resolution.Issues,
        issue => issue.FieldCode == "skill_1" && issue.ReasonCode == "level_ten_unsupported");
    Assert.Equal(
        FactStatus.Unresolved,
        resolution.Seed.Equipment.Single(item => item.Slot == EquipmentSlot.Head).Tier.Status);
    Assert.Equal(FactStatus.Unresolved, resolution.Seed.Skills.Skill1.Status);
  }

  [Fact]
  public void Explicit_level_is_mandatory_and_positive()
  {
    var version = CharacterTestData.Version();

    Assert.Throws<ArgumentOutOfRangeException>(() => _resolver.Resolve(version, 0));
    Assert.Throws<ArgumentOutOfRangeException>(() => _resolver.Resolve(version, -1));
  }
}
