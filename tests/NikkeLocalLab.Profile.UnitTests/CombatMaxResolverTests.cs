namespace NikkeLocalLab.Profile.UnitTests;

public sealed class CombatMaxResolverTests
{
  [Fact]
  public void Resolver_joins_phase1d_T10_grid_and_materializes_policy_values_without_choosing_a_cube()
  {
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion();
    var catalog = ProfileTestData.SupportCatalog();
    var revision = Resolve(account, character, catalog, catalog.All);

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(CharacterBuildMaterializationPolicy.CombatMaxV1, revision.Content.MaterializationPolicy);
    Assert.All(revision.Content.Equipment, item =>
    {
      Assert.Equal(ProfileAttachmentKind.Attached, item.AttachmentKind);
      Assert.Equal(10, item.Tier.RequireValue());
      Assert.Equal(5, item.EnhancementLevel.RequireValue());
      Assert.Empty(item.OverloadLines);
    });
    Assert.Equal(ProfileAttachmentKind.Detached, revision.Content.Cube.AttachmentKind);
    Assert.Equal(10, revision.Content.Skills.Skill1.RequireValue());
    Assert.Equal(200, revision.Content.Investment.CharacterLevel);
    Assert.Equal(3, revision.Content.Investment.LimitBreak.RequireValue());
    Assert.Equal(CharacterCollectibleSelectionKind.GenericCollection, revision.Content.Collectible.Kind);
    Assert.Equal(catalog.CollectionSr.DefinitionUid, revision.Content.Collectible.Definition?.DefinitionUid);
    Assert.Equal(15, revision.Content.Collectible.Level.RequireValue());
  }

  [Fact]
  public void Resolver_prefers_the_unique_character_favorite_over_generic_collection()
  {
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion(hasFavorite: true);
    var catalog = ProfileTestData.SupportCatalog(true, character.CharacterUid);
    var revision = Resolve(account, character, catalog, catalog.All);

    Assert.Equal(CharacterCollectibleSelectionKind.Favorite, revision.Content.Collectible.Kind);
    Assert.Equal(catalog.Favorite?.DefinitionUid, revision.Content.Collectible.Definition?.DefinitionUid);
    Assert.Equal(2, revision.Content.Collectible.Level.RequireValue());
  }

  [Fact]
  public void Missing_T10_definition_is_explicitly_unresolved_and_never_collapsed_to_detached()
  {
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion();
    var catalog = ProfileTestData.SupportCatalog();
    var withoutHead = catalog.All.Where(definition =>
        definition.DefinitionUid != catalog.EquipmentT10[0].DefinitionUid).ToArray();
    var revision = Resolve(account, character, catalog, withoutHead);
    var head = revision.Content.Equipment.Single(item => item.Slot == CombatSupportEquipmentSlot.Head);

    Assert.Equal(ProfileAttachmentKind.Unresolved, head.AttachmentKind);
    Assert.Equal("combat_max_equipment_definition_missing", head.ReasonCode);
    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
  }

  [Fact]
  public void Manufacturer_match_is_not_invented_by_combat_max_policy()
  {
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion();
    var catalog = ProfileTestData.SupportCatalog();
    var request = Request(
        account,
        character,
        catalog,
        catalog.All,
        ProfileFact<bool>.Unresolved("manufacturer_match_requires_profile_input"));
    var revision = new CombatMaxV1ProfileResolver().Resolve(request);

    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
    Assert.All(revision.Content.Equipment, item =>
        Assert.Equal(ProfileFactStatus.Unresolved, item.ManufacturerMatch.Status));
  }

  private static CharacterBuildRevision Resolve(
      LocalAccount account,
      CharacterDefinitionVersion character,
      SyntheticSupportCatalog catalog,
      IEnumerable<CombatSupportDefinitionVersion> definitions) =>
      new CombatMaxV1ProfileResolver().Resolve(Request(
          account,
          character,
          catalog,
          definitions,
          ProfileFact<bool>.Ready(true)));

  private static CombatMaxV1ProfileRequest Request(
      LocalAccount account,
      CharacterDefinitionVersion character,
      SyntheticSupportCatalog catalog,
      IEnumerable<CombatSupportDefinitionVersion> definitions,
      ProfileFact<bool> manufacturerMatch)
  {
    var build = new CharacterBuild(ProfileTestData.Uid(20), account, character.CharacterUid);
    var slots = Enum.GetValues<CombatSupportEquipmentSlot>().Select((slot, index) =>
        new CombatMaxEquipmentSlotRequest(ProfileTestData.Uid(2_000 + index), slot, manufacturerMatch));
    return new CombatMaxV1ProfileRequest(
        ProfileTestData.Uid(21),
        build,
        1,
        ProfileTestData.Provenance(ProfileRevisionOrigin.CombatMaxV1),
        ProfileTestData.Evidence(new[] { character }, catalog.All),
        character,
        200,
        ProfileValidationMode.Research,
        slots,
        definitions);
  }
}
