namespace NikkeLocalLab.Profile.UnitTests;

public sealed class SquadAndTemplateTests
{
  [Fact]
  public void Squad_pins_five_ordered_exact_build_revisions_and_rejects_duplicate_characters()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var fixture = Builds(account, catalog);
    var builds = fixture.Builds;
    var squad = new Squad(ProfileTestData.Uid(900), account);
    var revision = SquadRevision.Create(
        ProfileTestData.Uid(901),
        squad,
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        builds);

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Ready, revision.CombatSemanticsReadiness);
    Assert.Equal(Enumerable.Range(1, 5), revision.Content.Members.Select(static member => member.SlotIndex));
    Assert.Equal(
        builds.Select(static build => build.CharacterBuildRevisionUid),
        revision.Content.Members.Select(static member => member.BuildRevision.RevisionUid));
    Assert.Throws<ArgumentException>(() => SquadRevision.Create(
        ProfileTestData.Uid(902),
        squad,
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        new[] { builds[0], builds[0], builds[2], builds[3], builds[4] }));
  }

  [Fact]
  public void Template_allows_a_draft_without_squad_but_requires_active_squad_for_combat()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var character = ProfileTestData.CharacterVersion();
    var evidence = ProfileTestData.Evidence(new[] { character }, catalog.All);
    var accountState = ProfileTestData.AccountState(account, catalog, catalogEvidence: evidence);
    var template = new ProfileTemplate(ProfileTestData.Uid(950), account);
    var revision = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(951),
        template,
        1,
        ProfileTestData.Provenance(),
        evidence,
        accountState,
        Array.Empty<CharacterBuildRevision>(),
        null);

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, revision.CombatReadiness);
    Assert.Equal(ProfileReadiness.Unresolved, revision.CombatSemanticsReadiness);
    Assert.Contains(
        revision.Validation.Combat.Issues,
        issue => issue.ReasonCode == "active_squad_required_for_combat");
  }

  [Fact]
  public void Combat_ready_template_contains_every_exact_active_squad_member()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var fixture = Builds(account, catalog);
    var builds = fixture.Builds;
    var squad = SquadRevision.Create(
        ProfileTestData.Uid(900),
        new Squad(ProfileTestData.Uid(899), account),
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        builds);
    var revision = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(951),
        new ProfileTemplate(ProfileTestData.Uid(950), account),
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        ProfileTestData.AccountState(account, catalog, catalogEvidence: fixture.Evidence),
        builds.Reverse(),
        squad);

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Ready, revision.CombatReadiness);
    Assert.Equal(ProfileReadiness.Ready, revision.CombatSemanticsReadiness);
    Assert.Equal(
        revision.Content.BuildRevisions.OrderBy(static item => item.CharacterBuildUid.ToString()),
        revision.Content.BuildRevisions);

    var missingMember = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(952),
        new ProfileTemplate(ProfileTestData.Uid(950), account),
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        ProfileTestData.AccountState(account, catalog, catalogEvidence: fixture.Evidence),
        builds.Take(4),
        squad);
    Assert.Equal(ProfileReadiness.Invalid, missingMember.Readiness);
    Assert.Contains(
        missingMember.Validation.Draft.Issues,
        issue => issue.ReasonCode == "squad_build_not_in_template");
  }

  [Fact]
  public void Original_client_combat_readiness_is_separate_from_standalone_skill_semantics()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var fixture = Builds(account, catalog, attachCube: true);
    var squad = SquadRevision.Create(
        ProfileTestData.Uid(920),
        new Squad(ProfileTestData.Uid(919), account),
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        fixture.Builds);
    var profile = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(922),
        new ProfileTemplate(ProfileTestData.Uid(921), account),
        1,
        ProfileTestData.Provenance(),
        fixture.Evidence,
        ProfileTestData.AccountState(account, catalog, catalogEvidence: fixture.Evidence),
        fixture.Builds,
        squad);

    Assert.Equal(ProfileReadiness.Ready, squad.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, squad.CombatSemanticsReadiness);
    Assert.Equal(ProfileReadiness.Ready, profile.CombatReadiness);
    Assert.Equal(ProfileReadiness.Unresolved, profile.CombatSemanticsReadiness);
    Assert.Contains(
        "combat-semantics-readiness=unresolved",
        ProfileCanonicalizer.ToCanonicalText(profile.Content),
        StringComparison.Ordinal);
  }

  [Fact]
  public void Character_profile_semantics_gap_propagates_without_blocking_original_client_combat()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var characters = Enumerable.Range(0, 5).Select(index => ProfileTestData.CharacterVersion(
        6_000 + index,
        6_100 + index,
        element: index == 0
            ? NormalizedFact<NikkeElement>.Unresolved("character_element_not_retained")
            : null)).ToArray();
    var evidence = ProfileTestData.Evidence(characters, catalog.All);
    var builds = characters.Select((character, index) => CharacterBuildRevision.CreateExplicit(
        ProfileTestData.Uid(6_200 + index),
        new CharacterBuild(ProfileTestData.Uid(6_300 + index), account, character.CharacterUid),
        1,
        ProfileTestData.Provenance(),
        evidence,
        character,
        ProfileValidationMode.Research,
        new CharacterInvestmentState(
            200,
            ProfileFact<int>.Ready(3),
            ProfileFact<int>.Ready(7),
            ProfileFact<int>.Ready(40)),
        new CharacterSkillState(
            ProfileFact<int>.Ready(10),
            ProfileFact<int>.Ready(10),
            ProfileFact<int>.Ready(10)),
        Enum.GetValues<CombatSupportEquipmentSlot>().Select((slot, slotIndex) =>
            CharacterEquipmentInput.Detached(
                ProfileTestData.Uid(7_000 + (index * 10) + slotIndex),
                slot)),
        CharacterCubeInput.Detached(),
        CharacterCollectibleInput.Detached())).ToArray();
    var squad = SquadRevision.Create(
        ProfileTestData.Uid(7_100),
        new Squad(ProfileTestData.Uid(7_101), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        builds);
    var profile = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(7_102),
        new ProfileTemplate(ProfileTestData.Uid(7_103), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        ProfileTestData.AccountState(account, catalog, catalogEvidence: evidence),
        builds,
        squad);

    Assert.All(builds, build => Assert.Equal(ProfileReadiness.Ready, build.Readiness));
    Assert.Equal(ProfileReadiness.Unresolved, builds[0].CombatSemanticsReadiness);
    Assert.Equal(ProfileReadiness.Ready, squad.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, squad.CombatSemanticsReadiness);
    Assert.Contains(
        squad.Validation.CombatSemantics.Issues,
        issue => issue.ReasonCode == "build_combat_semantics_unresolved");
    Assert.Equal(ProfileReadiness.Ready, profile.CombatReadiness);
    Assert.Equal(ProfileReadiness.Unresolved, profile.CombatSemanticsReadiness);
    Assert.Contains(
        profile.Validation.CombatSemantics.Issues,
        issue => issue.ReasonCode == "squad_combat_semantics_unresolved");
  }

  [Fact]
  public void Revision_one_and_later_revision_predecessor_contract_is_strict()
  {
    Assert.Throws<ArgumentException>(() => new ProfileRevisionProvenance(
        ProfileRevisionOrigin.UserEdit,
        ProfileTestData.Timestamp.ToOffset(TimeSpan.FromHours(9)),
        null));

    var catalog = ProfileTestData.SupportCatalog();
    var account = ProfileTestData.Account();
    var state = new AccountCombatState(ProfileTestData.Uid(50), account);
    var evidence = ProfileTestData.Evidence(
        new[] { ProfileTestData.CharacterVersion() },
        catalog.All);
    var inputs = catalog.Consoles.Select(definition =>
        new ConsoleProgressInput(definition, ProfileFact<int>.Ready(1), ProfileFact<long>.Ready(0)));
    Assert.Throws<ArgumentException>(() => AccountCombatStateRevision.Create(
        ProfileTestData.Uid(51),
        state,
        2,
        ProfileTestData.Provenance(),
        evidence,
        ProfileValidationMode.Research,
        ProfileFact<int>.Ready(50),
        inputs));
  }

  [Fact]
  public void Template_accepts_a_192_build_draft_without_treating_192_as_a_roster_cap()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var characters = Enumerable.Range(0, 193).Select(index => ProfileTestData.CharacterVersion(
        10_000 + index,
        20_000 + index)).ToArray();
    var evidence = ProfileTestData.Evidence(characters, catalog.All);
    var builds = characters.Select((character, index) => ProfileTestData.ExplicitBuild(
        30_000 + index,
        40_000 + index,
        10_000 + index,
        catalog,
        account,
        characterVersionUid: 20_000 + index,
        characterDefinitionVersion: character,
        catalogEvidence: evidence)).ToArray();
    var accountState = ProfileTestData.AccountState(account, catalog, catalogEvidence: evidence);
    var template = new ProfileTemplate(ProfileTestData.Uid(50_000), account);
    var draft192 = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(50_001),
        template,
        1,
        ProfileTestData.Provenance(),
        evidence,
        accountState,
        builds.Take(192),
        null);
    var squad = SquadRevision.Create(
        ProfileTestData.Uid(50_002),
        new Squad(ProfileTestData.Uid(50_003), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        builds.Take(5));
    var expanded193 = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(50_004),
        template,
        1,
        ProfileTestData.Provenance(),
        evidence,
        accountState,
        builds,
        squad);

    Assert.Equal(192, draft192.Content.BuildRevisions.Count);
    Assert.Equal(ProfileReadiness.Ready, draft192.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, draft192.CombatReadiness);
    Assert.Equal(193, expanded193.Content.BuildRevisions.Count);
    Assert.Equal(ProfileReadiness.Ready, expanded193.CombatReadiness);
    Assert.Equal(5, expanded193.Content.ActiveSquadRevision?.Members.Count);
  }

  private static BuildFixture Builds(
      LocalAccount account,
      SyntheticSupportCatalog catalog,
      bool attachCube = false)
  {
    var characters = Enumerable.Range(0, 5).Select(index =>
        ProfileTestData.CharacterVersion(300 + index, 400 + index)).ToArray();
    var evidence = ProfileTestData.Evidence(characters, catalog.All);
    var builds = characters.Select((character, index) => ProfileTestData.ExplicitBuild(
        100 + index,
        200 + index,
        300 + index,
        catalog,
        account,
        cube: attachCube
            ? CharacterCubeInput.Attached(catalog.Cube, ProfileFact<int>.Ready(15))
            : null,
        characterVersionUid: 400 + index,
        characterDefinitionVersion: character,
        catalogEvidence: evidence)).ToArray();
    return new BuildFixture(builds, evidence);
  }

  private sealed record BuildFixture(
      CharacterBuildRevision[] Builds,
      ProfileCatalogEvidence Evidence);
}
