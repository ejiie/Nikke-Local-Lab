namespace NikkeLocalLab.Profile.UnitTests;

public sealed class CharacterBuildTests
{
  [Fact]
  public void Research_write_preserves_sparse_ol_lines_and_arbitrary_exact_decimals()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var lines = new[]
    {
      new CharacterOverloadLineInput(
          3,
          catalog.ChargeSpeedOption,
          new CombatSupportExactValue(-999, 4)),
      new CharacterOverloadLineInput(
          1,
          catalog.AttackOption,
          new CombatSupportExactValue(123_456, 6))
    };
    var revision = ProfileTestData.ExplicitBuild(20, 21, 10, catalog, headLines: lines);
    var head = revision.Content.Equipment.Single(item => item.Slot == CombatSupportEquipmentSlot.Head);

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(new[] { 1, 3 }, head.OverloadLines.Select(static line => line.LineIndex));
    Assert.Equal(new CombatSupportExactValue(123_456, 6), head.OverloadLines[0].ApplicationValue);
    Assert.Contains("line-index=3", ProfileCanonicalizer.ToCanonicalText(revision.Content), StringComparison.Ordinal);
  }

  [Fact]
  public void T9_and_detached_equipment_cannot_carry_ol_lines_even_in_research_mode()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion();
    var build = new CharacterBuild(ProfileTestData.Uid(20), account, character.CharacterUid);
    var line = new CharacterOverloadLineInput(
        1,
        catalog.AttackOption,
        new CombatSupportExactValue(1, 2));
    var equipment = catalog.EquipmentT10.Select((definition, index) =>
        index == 0
            ? CharacterEquipmentInput.EquippedWith(
                ProfileTestData.Uid(2_000 + index),
                catalog.EquipmentT9[index],
                ProfileFact<int>.Ready(5),
                ProfileFact<bool>.Ready(true),
                new[] { line })
            : CharacterEquipmentInput.EquippedWith(
                ProfileTestData.Uid(2_000 + index),
                definition,
                ProfileFact<int>.Ready(5),
                ProfileFact<bool>.Ready(true)));
    var revision = CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(21),
        build,
        1,
        ProfileTestData.Provenance(),
        ProfileTestData.Evidence(new[] { character }, catalog.All),
        character,
        ProfileValidationMode.Research,
        ReadyInvestment(),
        ReadySkills(),
        equipment,
        CharacterCubeInput.Detached(),
        CharacterCollectibleInput.Detached());

    Assert.Equal(ProfileReadiness.Invalid, revision.Readiness);
    Assert.Contains(revision.Validation.Selection.Issues, issue => issue.ReasonCode == "overload_not_applicable");
    Assert.Empty(CharacterEquipmentInput.Detached(
        ProfileTestData.Uid(9_000),
        CombatSupportEquipmentSlot.Head).OverloadLines);
  }

  [Fact]
  public void Detached_and_unresolved_equipment_and_cube_are_distinct_canonical_states()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var detachedEquipment = CharacterEquipmentInput.Detached(
        ProfileTestData.Uid(1),
        CombatSupportEquipmentSlot.Head);
    var unresolvedEquipment = CharacterEquipmentInput.Unresolved(
        ProfileTestData.Uid(1),
        CombatSupportEquipmentSlot.Head,
        "equipment_definition_not_retained");
    var detachedCube = CharacterCubeInput.Detached();
    var unresolvedCube = CharacterCubeInput.Unresolved("detached_vs_missing_ambiguous");
    var detachedRevision = BuildWithStates(catalog, 21, detachedEquipment, detachedCube);
    var unresolvedEquipmentRevision = BuildWithStates(catalog, 22, unresolvedEquipment, detachedCube);
    var unresolvedCubeRevision = BuildWithStates(catalog, 23, detachedEquipment, unresolvedCube);

    Assert.Equal(ProfileAttachmentKind.Detached, detachedEquipment.AttachmentKind);
    Assert.Equal(ProfileAttachmentKind.Unresolved, unresolvedEquipment.AttachmentKind);
    Assert.Equal(ProfileFactStatus.Unresolved, unresolvedEquipment.EnhancementLevel.Status);
    Assert.Equal(ProfileAttachmentKind.Detached, detachedCube.AttachmentKind);
    Assert.Equal(ProfileAttachmentKind.Unresolved, unresolvedCube.AttachmentKind);
    Assert.Equal("detached_vs_missing_ambiguous", unresolvedCube.ReasonCode);
    Assert.Equal(ProfileReadiness.Ready, detachedRevision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, unresolvedEquipmentRevision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, unresolvedCubeRevision.Readiness);
    Assert.NotEqual(detachedRevision.ContentSha256, unresolvedEquipmentRevision.ContentSha256);
    Assert.NotEqual(detachedRevision.ContentSha256, unresolvedCubeRevision.ContentSha256);
    Assert.Contains(
        "equipment.0.attachment=unresolved",
        ProfileCanonicalizer.ToCanonicalText(unresolvedEquipmentRevision.Content),
        StringComparison.Ordinal);
    Assert.Contains(
        "cube.attachment=unresolved",
        ProfileCanonicalizer.ToCanonicalText(unresolvedCubeRevision.Content),
        StringComparison.Ordinal);
  }

  [Fact]
  public void Game_legal_mode_checks_signed_discrete_values_but_does_not_invent_duplicate_policy()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var legalDuplicate = new[]
    {
      new CharacterOverloadLineInput(1, catalog.AttackOption, new CombatSupportExactValue(410, 4)),
      new CharacterOverloadLineInput(3, catalog.AttackOption, new CombatSupportExactValue(420, 4))
    };
    var legalSigned = new[]
    {
      new CharacterOverloadLineInput(1, catalog.ChargeSpeedOption, new CombatSupportExactValue(-410, 4))
    };
    var illegalMagnitude = new[]
    {
      new CharacterOverloadLineInput(1, catalog.ChargeSpeedOption, new CombatSupportExactValue(410, 4))
    };

    var duplicateRevision = ProfileTestData.ExplicitBuild(
        20,
        21,
        10,
        catalog,
        headLines: legalDuplicate,
        validationMode: ProfileValidationMode.GameLegal);
    var signedRevision = ProfileTestData.ExplicitBuild(
        22,
        23,
        10,
        catalog,
        headLines: legalSigned,
        validationMode: ProfileValidationMode.GameLegal);
    var invalidRevision = ProfileTestData.ExplicitBuild(
        24,
        25,
        10,
        catalog,
        headLines: illegalMagnitude,
        validationMode: ProfileValidationMode.GameLegal);

    Assert.Equal(ProfileReadiness.Ready, duplicateRevision.Readiness);
    Assert.Equal(ProfileReadiness.Ready, signedRevision.Readiness);
    Assert.Equal(ProfileReadiness.Invalid, invalidRevision.Readiness);
    Assert.Contains(
        invalidRevision.Validation.Selection.Issues,
        issue => issue.ReasonCode == "value_not_in_discrete_legal_set");
  }

  [Fact]
  public void Research_mode_does_not_apply_a_game_legal_duplicate_rule()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var option = ProfileTestData.OverloadOption(
        CombatSupportOverloadOptionType.Attack,
        9_100,
        9_101,
        duplicatePolicy: CombatSupportFact<CombatSupportOverloadDuplicatePolicy>.Ready(
            CombatSupportOverloadDuplicatePolicy.ForbidSameTypeOnOneEquipment));
    var lines = new[]
    {
      new CharacterOverloadLineInput(1, option, new CombatSupportExactValue(410, 4)),
      new CharacterOverloadLineInput(2, option, new CombatSupportExactValue(420, 4))
    };
    var research = ProfileTestData.ExplicitBuild(20, 21, 10, catalog, headLines: lines);
    var gameLegal = ProfileTestData.ExplicitBuild(
        22,
        23,
        10,
        catalog,
        headLines: lines,
        validationMode: ProfileValidationMode.GameLegal);

    Assert.Equal(ProfileReadiness.Ready, research.Readiness);
    Assert.Equal(ProfileReadiness.Invalid, gameLegal.Readiness);
    Assert.Contains(
        gameLegal.Validation.Selection.Issues,
        issue => issue.ReasonCode == "duplicate_option_type_forbidden");
  }

  [Fact]
  public void Attached_cube_is_profile_ready_but_exposes_unresolved_skill_effect_semantics()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var revision = ProfileTestData.ExplicitBuild(
        20,
        21,
        10,
        catalog,
        cube: CharacterCubeInput.Attached(catalog.Cube, ProfileFact<int>.Ready(15)));

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, revision.CombatSemanticsReadiness);
    Assert.Contains(
        revision.Validation.CombatSemantics.Issues,
        issue => issue.ReasonCode == "skill_definition_catalog_not_imported");
  }

  [Fact]
  public void Cube_not_applicable_role_is_universal_even_when_character_role_is_unresolved()
  {
    var revision = BuildWithCubeApplicability(
        NormalizedFact<CombatRole>.Unresolved("character_combat_role_not_retained"),
        CombatSupportFact<CombatSupportCombatRole>.NotApplicable());

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.DoesNotContain(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "cube_definition");
  }

  [Fact]
  public void Unresolved_cube_role_applicability_propagates_to_selection_readiness()
  {
    var revision = BuildWithCubeApplicability(
        NormalizedFact<CombatRole>.Ready(CombatRole.Attacker),
        CombatSupportFact<CombatSupportCombatRole>.Unresolved("cube_role_not_retained"));

    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "cube_definition" &&
            issue.ReasonCode == "cube_role_not_retained");
  }

  [Fact]
  public void Ready_cube_role_with_unresolved_character_role_propagates_to_selection_readiness()
  {
    var revision = BuildWithCubeApplicability(
        NormalizedFact<CombatRole>.Unresolved("character_role_not_retained"),
        CombatSupportFact<CombatSupportCombatRole>.Ready(CombatSupportCombatRole.Attacker));

    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "cube_definition" &&
            issue.ReasonCode == "character_role_not_retained");
  }

  [Fact]
  public void Ready_cube_and_character_role_mismatch_is_invalid()
  {
    var revision = BuildWithCubeApplicability(
        NormalizedFact<CombatRole>.Ready(CombatRole.Attacker),
        CombatSupportFact<CombatSupportCombatRole>.Ready(CombatSupportCombatRole.Defender));

    Assert.Equal(ProfileReadiness.Invalid, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "cube_definition" &&
            issue.ReasonCode == "combat_role_mismatch");
  }

  [Theory]
  [InlineData(true)]
  [InlineData(false)]
  public void Generic_equipment_manufacturer_accepts_authoritative_build_match(bool manufacturerMatch)
  {
    var revision = BuildWithManufacturer(
        NormalizedFact<Manufacturer>.Unresolved("character_manufacturer_not_retained"),
        CombatSupportFact<CombatSupportManufacturer>.NotApplicable(),
        ProfileFact<bool>.Ready(manufacturerMatch));

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.DoesNotContain(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "equipment_head_manufacturer_match");
  }

  [Theory]
  [InlineData(Manufacturer.Elysion, CombatSupportManufacturer.Elysion, true)]
  [InlineData(Manufacturer.Elysion, CombatSupportManufacturer.Missilis, false)]
  public void Specific_equipment_manufacturer_accepts_matching_derived_fact(
      Manufacturer characterManufacturer,
      CombatSupportManufacturer equipmentManufacturer,
      bool manufacturerMatch)
  {
    var revision = BuildWithManufacturer(
        NormalizedFact<Manufacturer>.Ready(characterManufacturer),
        CombatSupportFact<CombatSupportManufacturer>.Ready(equipmentManufacturer),
        ProfileFact<bool>.Ready(manufacturerMatch));

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
  }

  [Fact]
  public void Specific_equipment_manufacturer_rejects_build_fact_that_disagrees_with_catalogs()
  {
    var revision = BuildWithManufacturer(
        NormalizedFact<Manufacturer>.Ready(Manufacturer.Elysion),
        CombatSupportFact<CombatSupportManufacturer>.Ready(CombatSupportManufacturer.Elysion),
        ProfileFact<bool>.Ready(false));

    Assert.Equal(ProfileReadiness.Invalid, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "equipment_head_manufacturer_match" &&
            issue.ReasonCode == "manufacturer_match_mismatch");
  }

  [Fact]
  public void Unresolved_equipment_manufacturer_propagates_source_reason_to_selection()
  {
    var revision = BuildWithManufacturer(
        NormalizedFact<Manufacturer>.Ready(Manufacturer.Elysion),
        CombatSupportFact<CombatSupportManufacturer>.Unresolved("equipment_manufacturer_not_retained"),
        ProfileFact<bool>.Ready(true));

    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "equipment_head_manufacturer_match" &&
            issue.ReasonCode == "equipment_manufacturer_not_retained");
  }

  [Fact]
  public void Unresolved_character_manufacturer_propagates_source_reason_to_selection()
  {
    var revision = BuildWithManufacturer(
        NormalizedFact<Manufacturer>.Unresolved("character_manufacturer_not_retained"),
        CombatSupportFact<CombatSupportManufacturer>.Ready(CombatSupportManufacturer.Elysion),
        ProfileFact<bool>.Ready(true));

    Assert.Equal(ProfileReadiness.Unresolved, revision.Readiness);
    Assert.Contains(
        revision.Validation.Selection.Issues,
        issue => issue.FieldCode == "equipment_head_manufacturer_match" &&
            issue.ReasonCode == "character_manufacturer_not_retained");
  }

  [Fact]
  public void Content_hash_excludes_revision_identity_but_preserves_exact_decimal_scale()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var first = ProfileTestData.ExplicitBuild(
        20,
        21,
        10,
        catalog,
        headLines: new[]
        {
          new CharacterOverloadLineInput(1, catalog.AttackOption, new CombatSupportExactValue(10, 2))
        });
    var second = ProfileTestData.ExplicitBuild(
        20,
        22,
        10,
        catalog,
        headLines: new[]
        {
          new CharacterOverloadLineInput(1, catalog.AttackOption, new CombatSupportExactValue(10, 2))
        });
    var scaled = ProfileTestData.ExplicitBuild(
        20,
        23,
        10,
        catalog,
        headLines: new[]
        {
          new CharacterOverloadLineInput(1, catalog.AttackOption, new CombatSupportExactValue(100, 3))
        });

    Assert.Equal(first.ContentSha256, second.ContentSha256);
    Assert.NotEqual(first.ContentSha256, scaled.ContentSha256);
    Assert.DoesNotContain(
        first.CharacterBuildRevisionUid.ToString(),
        ProfileCanonicalizer.ToCanonicalText(first.Content),
        StringComparison.Ordinal);
  }

  [Fact]
  public void Catalog_evidence_rejects_cloned_character_and_support_version_uids()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var character = ProfileTestData.CharacterVersion();
    var evidence = ProfileTestData.Evidence(new[] { character }, catalog.All);
    var clonedCharacter = CharacterDefinitionVersion.Create(
        ProfileTestData.Uid(9_001),
        new CharacterDefinition(character.CharacterUid),
        character.DatasetSnapshotUid,
        character.Content);

    Assert.Throws<ArgumentException>(() => ProfileTestData.ExplicitBuild(
        20,
        21,
        10,
        catalog,
        characterDefinitionVersion: clonedCharacter,
        catalogEvidence: evidence));

    var clonedOption = CombatSupportDefinitionVersion.Create(
        ProfileTestData.Uid(9_002),
        new CombatSupportDefinition(catalog.AttackOption.DefinitionUid),
        catalog.AttackOption.DatasetSnapshotUid,
        catalog.AttackOption.Content);
    var lines = new[]
    {
      new CharacterOverloadLineInput(1, clonedOption, new CombatSupportExactValue(410, 4))
    };
    Assert.Throws<ArgumentException>(() => ProfileTestData.ExplicitBuild(
        22,
        23,
        10,
        catalog,
        headLines: lines,
        characterDefinitionVersion: character,
        catalogEvidence: evidence));
  }

  [Fact]
  public void Unresolved_character_element_only_blocks_standalone_combat_semantics()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion(
        element: NormalizedFact<NikkeElement>.Unresolved("character_element_not_retained"));
    var evidence = ProfileTestData.Evidence(new[] { character }, catalog.All);
    var equipment = Enum.GetValues<CombatSupportEquipmentSlot>().Select((slot, index) =>
        CharacterEquipmentInput.Detached(ProfileTestData.Uid(9_100 + index), slot));
    var revision = CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(9_110),
        new CharacterBuild(ProfileTestData.Uid(9_111), account, character.CharacterUid),
        1,
        ProfileTestData.Provenance(),
        evidence,
        character,
        ProfileValidationMode.Research,
        ReadyInvestment(),
        ReadySkills(),
        equipment,
        CharacterCubeInput.Detached(),
        CharacterCollectibleInput.Detached());

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, revision.CombatSemanticsReadiness);
    var issue = Assert.Single(
        revision.Validation.CombatSemantics.Issues,
        issue => issue.FieldCode == "character_profile_element_combat_semantics");
    Assert.Equal("character_element_not_retained", issue.ReasonCode);
  }

  private static CharacterInvestmentState ReadyInvestment() =>
      new(
          200,
          ProfileFact<int>.Ready(3),
          ProfileFact<int>.Ready(7),
          ProfileFact<int>.Ready(40));

  private static CharacterSkillState ReadySkills() =>
      new(
          ProfileFact<int>.Ready(10),
          ProfileFact<int>.Ready(10),
          ProfileFact<int>.Ready(10));

  private static CharacterBuildRevision BuildWithStates(
      SyntheticSupportCatalog catalog,
      int revisionUid,
      CharacterEquipmentInput head,
      CharacterCubeInput cube)
  {
    var account = ProfileTestData.Account();
    var character = ProfileTestData.CharacterVersion();
    var build = new CharacterBuild(ProfileTestData.Uid(20), account, character.CharacterUid);
    var equipment = catalog.EquipmentT10.Select((definition, index) => index == 0
        ? head
        : CharacterEquipmentInput.EquippedWith(
            ProfileTestData.Uid(index + 1),
            definition,
            ProfileFact<int>.Ready(5),
            ProfileFact<bool>.Ready(true)));
    return CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(revisionUid),
        build,
        1,
        ProfileTestData.Provenance(),
        ProfileTestData.Evidence(new[] { character }, catalog.All),
        character,
        ProfileValidationMode.Research,
        ReadyInvestment(),
        ReadySkills(),
        equipment,
        cube,
        CharacterCollectibleInput.Detached());
  }

  private static CharacterBuildRevision BuildWithCubeApplicability(
      NormalizedFact<CombatRole> characterRole,
      CombatSupportFact<CombatSupportCombatRole> cubeRole)
  {
    var catalog = ProfileTestData.SupportCatalog();
    var character = ProfileTestData.CharacterVersion(combatRole: characterRole);
    var cube = ProfileTestData.Cube(
        uid: 9_200,
        versionUid: 9_201,
        applicableCombatRole: cubeRole);
    var support = catalog.All
        .Where(definition => definition.DefinitionUid != catalog.Cube.DefinitionUid)
        .Append(cube)
        .ToArray();
    var account = ProfileTestData.Account();
    var build = new CharacterBuild(ProfileTestData.Uid(9_202), account, character.CharacterUid);
    var equipment = Enum.GetValues<CombatSupportEquipmentSlot>().Select((slot, index) =>
        CharacterEquipmentInput.Detached(ProfileTestData.Uid(9_210 + index), slot));
    return CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(9_220),
        build,
        1,
        ProfileTestData.Provenance(),
        ProfileTestData.Evidence(new[] { character }, support),
        character,
        ProfileValidationMode.Research,
        ReadyInvestment(),
        ReadySkills(),
        equipment,
        CharacterCubeInput.Attached(cube, ProfileFact<int>.Ready(15)),
        CharacterCollectibleInput.Detached());
  }

  private static CharacterBuildRevision BuildWithManufacturer(
      NormalizedFact<Manufacturer> characterManufacturer,
      CombatSupportFact<CombatSupportManufacturer> equipmentManufacturer,
      ProfileFact<bool> manufacturerMatch)
  {
    var catalog = ProfileTestData.SupportCatalog();
    var character = ProfileTestData.CharacterVersion(manufacturer: characterManufacturer);
    var head = ProfileTestData.Equipment(
        CombatSupportEquipmentSlot.Head,
        10,
        9_300,
        9_301,
        manufacturer: equipmentManufacturer);
    var support = catalog.All.Append(head).ToArray();
    var account = ProfileTestData.Account();
    var build = new CharacterBuild(ProfileTestData.Uid(9_302), account, character.CharacterUid);
    var equipment = Enum.GetValues<CombatSupportEquipmentSlot>().Select((slot, index) =>
        slot == CombatSupportEquipmentSlot.Head
            ? CharacterEquipmentInput.EquippedWith(
                ProfileTestData.Uid(9_310 + index),
                head,
                ProfileFact<int>.Ready(5),
                manufacturerMatch)
            : CharacterEquipmentInput.Detached(ProfileTestData.Uid(9_310 + index), slot));
    return CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(9_320),
        build,
        1,
        ProfileTestData.Provenance(),
        ProfileTestData.Evidence(new[] { character }, support),
        character,
        ProfileValidationMode.Research,
        ReadyInvestment(),
        ReadySkills(),
        equipment,
        CharacterCubeInput.Detached(),
        CharacterCollectibleInput.Detached());
  }
}
