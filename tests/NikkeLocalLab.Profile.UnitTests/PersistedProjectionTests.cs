namespace NikkeLocalLab.Profile.UnitTests;

public sealed class PersistedProjectionTests
{
  [Fact]
  public void Trusted_projection_rehydrates_account_build_squad_and_template_with_identical_hashes()
  {
    var fixture = CreateFixture();
    var accountContent = ProfilePersistedProjection.AccountCombatState(
        fixture.AccountState.Content.DatasetBinding,
        fixture.AccountState.Content.ValidationMode,
        fixture.AccountState.Content.SynchroLevel,
        fixture.AccountState.Content.Consoles.Select(console =>
            ProfilePersistedProjection.ConsoleProgress(
                console.Coordinate,
                Restore(console.Definition),
                console.Level,
                console.Experience)));
    Assert.Equal(fixture.AccountState.ContentSha256, ProfileCanonicalizer.ComputeContentHash(accountContent));

    var buildContents = fixture.Builds.Select(RestoreBuildContent).ToArray();
    Assert.Equal(
        fixture.Builds.Select(static build => build.ContentSha256),
        buildContents.Select(ProfileCanonicalizer.ComputeContentHash));
    Assert.Equal(
        new[] { 1, 3 },
        buildContents[0].Equipment[0].OverloadLines.Select(static line => line.LineIndex));

    var buildReferences = fixture.Builds.Select(static build => Restore(build.ToReference())).ToArray();
    var squadContent = ProfilePersistedProjection.Squad(
        fixture.Squad.Content.DatasetBinding,
        buildReferences);
    Assert.Equal(fixture.Squad.ContentSha256, ProfileCanonicalizer.ComputeContentHash(squadContent));
    var squadValidation = ProfilePersistedProjection.ValidateSquadReadiness(squadContent);
    Assert.Equal(fixture.Squad.Readiness, squadValidation.Selection.Status);
    Assert.Equal(
        fixture.Squad.CombatSemanticsReadiness,
        squadValidation.CombatSemantics.Status);

    var squadReference = SquadRevisionReference.Restore(
        fixture.Squad.SquadUid,
        fixture.Squad.SquadRevisionUid,
        fixture.Squad.LocalAccountUid,
        fixture.Squad.Content.DatasetBinding,
        buildReferences,
        fixture.Squad.ContentSha256,
        fixture.Squad.Readiness,
        fixture.Squad.CombatSemanticsReadiness);
    var templateContent = ProfilePersistedProjection.ProfileTemplate(
        fixture.Profile.Content.DatasetBinding,
        Restore(fixture.AccountState.ToReference()),
        buildReferences,
        squadReference);
    Assert.Equal(fixture.Profile.ContentSha256, ProfileCanonicalizer.ComputeContentHash(templateContent));
    var templateValidation = ProfilePersistedProjection.ValidateProfileTemplateReadiness(templateContent);
    Assert.Equal(fixture.Profile.Readiness, templateValidation.Draft.Status);
    Assert.Equal(fixture.Profile.CombatReadiness, templateValidation.Combat.Status);
    Assert.Equal(
        fixture.Profile.CombatSemanticsReadiness,
        templateValidation.CombatSemantics.Status);
  }

  [Fact]
  public void Reference_readiness_axes_are_canonical_and_hash_sensitive()
  {
    var fixture = CreateFixture();
    var binding = fixture.Profile.Content.DatasetBinding;
    var accountReady = Restore(fixture.AccountState.ToReference());
    var accountLossy = AccountCombatStateRevisionReference.Restore(
        accountReady.AccountCombatStateUid,
        accountReady.RevisionUid,
        accountReady.LocalAccountUid,
        accountReady.DatasetBinding,
        accountReady.ContentSha256,
        accountReady.Readiness,
        accountReady.FullFidelityReadiness == ProfileReadiness.Ready
            ? ProfileReadiness.Unresolved
            : ProfileReadiness.Ready);
    var accountReadyContent = ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountReady,
        Array.Empty<CharacterBuildRevisionReference>(),
        null);
    var accountLossyContent = ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountLossy,
        Array.Empty<CharacterBuildRevisionReference>(),
        null);
    Assert.NotEqual(
        ProfileCanonicalizer.ComputeContentHash(accountReadyContent),
        ProfileCanonicalizer.ComputeContentHash(accountLossyContent));

    var buildReferences = fixture.Builds.Select(static build => Restore(build.ToReference())).ToArray();
    var first = buildReferences[0];
    buildReferences[0] = CharacterBuildRevisionReference.Restore(
        first.CharacterBuildUid,
        first.RevisionUid,
        first.LocalAccountUid,
        first.CharacterUid,
        first.DatasetBinding,
        first.ContentSha256,
        first.Readiness,
        first.CombatSemanticsReadiness == ProfileReadiness.Ready
            ? ProfileReadiness.Unresolved
            : ProfileReadiness.Ready);
    var semanticsChangedSquad = ProfilePersistedProjection.Squad(binding, buildReferences);
    Assert.NotEqual(
        fixture.Squad.ContentSha256,
        ProfileCanonicalizer.ComputeContentHash(semanticsChangedSquad));

    var originalSquad = fixture.Squad.ToReference();
    var semanticsChangedSquadReference = SquadRevisionReference.Restore(
        originalSquad.SquadUid,
        originalSquad.RevisionUid,
        originalSquad.LocalAccountUid,
        originalSquad.DatasetBinding,
        originalSquad.Members,
        originalSquad.ContentSha256,
        originalSquad.Readiness,
        originalSquad.CombatSemanticsReadiness == ProfileReadiness.Ready
            ? ProfileReadiness.Unresolved
            : ProfileReadiness.Ready);
    var exactBuildReferences = fixture.Builds.Select(static build => Restore(build.ToReference())).ToArray();
    var originalProfile = ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountReady,
        exactBuildReferences,
        Restore(originalSquad));
    var semanticsChangedProfile = ProfilePersistedProjection.ProfileTemplate(
        binding,
        accountReady,
        exactBuildReferences,
        semanticsChangedSquadReference);
    Assert.NotEqual(
        ProfileCanonicalizer.ComputeContentHash(originalProfile),
        ProfileCanonicalizer.ComputeContentHash(semanticsChangedProfile));
  }

  [Fact]
  public void Trusted_projection_fails_closed_on_noncanonical_graph_shapes()
  {
    var fixture = CreateFixture();
    Assert.Throws<ArgumentException>(() => ProfilePersistedProjection.AccountCombatState(
        fixture.AccountState.Content.DatasetBinding,
        ProfileValidationMode.Research,
        ProfileFact<int>.Ready(1),
        fixture.AccountState.Content.Consoles.Take(8)));
    Assert.Throws<ArgumentException>(() => ProfilePersistedProjection.Squad(
        fixture.Profile.Content.DatasetBinding,
        fixture.Builds.Take(4).Select(static build => build.ToReference())));
    Assert.Throws<ArgumentException>(() => ProfilePersistedProjection.AttachedEquipment(
        ProfileTestData.Uid(9_900),
        CombatSupportEquipmentSlot.Head,
        Restore(fixture.Catalog.Cube),
        ProfileFact<int>.Ready(10),
        ProfileFact<int>.Ready(5),
        ProfileFact<bool>.Ready(true)));

    var accountReference = fixture.AccountState.ToReference();
    var mismatchedBinding = new ProfileDatasetBinding(
        new ProfileCatalogBinding(
            ProfileTestData.Uid(9_910),
            datasetSnapshotUid: fixture.Profile.Content.DatasetBinding.CharacterCatalog.DatasetSnapshotUid,
            catalogManifestSha256: Sha256Digest.ComputeUtf8("different-character-manifest")),
        fixture.Profile.Content.DatasetBinding.CombatSupportCatalog);
    var mismatchedAccountReference = AccountCombatStateRevisionReference.Restore(
        accountReference.AccountCombatStateUid,
        accountReference.RevisionUid,
        accountReference.LocalAccountUid,
        mismatchedBinding,
        accountReference.ContentSha256,
        accountReference.Readiness,
        accountReference.FullFidelityReadiness);
    Assert.Throws<ArgumentException>(() => ProfilePersistedProjection.ProfileTemplate(
        fixture.Profile.Content.DatasetBinding,
        mismatchedAccountReference,
        Array.Empty<CharacterBuildRevisionReference>(),
        null));
  }

  private static ProjectionFixture CreateFixture()
  {
    var account = ProfileTestData.Account();
    var catalog = ProfileTestData.SupportCatalog();
    var characters = Enumerable.Range(0, 5).Select(index =>
        ProfileTestData.CharacterVersion(3_000 + index, 3_100 + index)).ToArray();
    var evidence = ProfileTestData.Evidence(characters, catalog.All);
    var sparse = new[]
    {
      new CharacterOverloadLineInput(
          1,
          catalog.AttackOption,
          new CombatSupportExactValue(12_345, 6)),
      new CharacterOverloadLineInput(
          3,
          catalog.ChargeSpeedOption,
          new CombatSupportExactValue(-777, 4))
    };
    var builds = characters.Select((character, index) => ProfileTestData.ExplicitBuild(
        3_200 + index,
        3_300 + index,
        3_000 + index,
        catalog,
        account,
        headLines: index == 0 ? sparse : null,
        cube: index == 0
            ? CharacterCubeInput.Attached(catalog.Cube, ProfileFact<int>.Ready(15))
            : null,
        collectible: index == 0
            ? CharacterCollectibleInput.GenericCollection(
                catalog.CollectionSr,
                ProfileFact<int>.Ready(15))
            : null,
        characterDefinitionVersion: character,
        catalogEvidence: evidence)).ToArray();
    var accountState = ProfileTestData.AccountState(account, catalog, catalogEvidence: evidence);
    var squad = SquadRevision.Create(
        ProfileTestData.Uid(3_400),
        new Squad(ProfileTestData.Uid(3_401), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        builds);
    var profile = ProfileTemplateRevision.Create(
        ProfileTestData.Uid(3_402),
        new ProfileTemplate(ProfileTestData.Uid(3_403), account),
        1,
        ProfileTestData.Provenance(),
        evidence,
        accountState,
        builds,
        squad);
    return new ProjectionFixture(catalog, accountState, builds, squad, profile);
  }

  private static CharacterBuildRevisionContent RestoreBuildContent(CharacterBuildRevision build)
  {
    var content = build.Content;
    var equipment = content.Equipment.Select(item => item.AttachmentKind switch
    {
      ProfileAttachmentKind.Attached => ProfilePersistedProjection.AttachedEquipment(
          item.EquipmentSlotUid,
          item.Slot,
          Restore(item.Definition!),
          item.Tier,
          item.EnhancementLevel,
          item.ManufacturerMatch,
          item.OverloadLines.Select(line => ProfilePersistedProjection.OverloadLine(
              line.LineIndex,
              Restore(line.OptionDefinition),
              line.OptionType,
              line.Unit,
              line.ApplicationValue))),
      ProfileAttachmentKind.Detached => ProfilePersistedProjection.DetachedEquipment(
          item.EquipmentSlotUid,
          item.Slot),
      ProfileAttachmentKind.Unresolved => ProfilePersistedProjection.UnresolvedEquipment(
          item.EquipmentSlotUid,
          item.Slot,
          item.ReasonCode!),
      _ => throw new ArgumentOutOfRangeException()
    });
    var cube = content.Cube.AttachmentKind switch
    {
      ProfileAttachmentKind.Attached => ProfilePersistedProjection.AttachedCube(
          Restore(content.Cube.Definition!),
          content.Cube.Level),
      ProfileAttachmentKind.Detached => ProfilePersistedProjection.DetachedCube(),
      ProfileAttachmentKind.Unresolved => ProfilePersistedProjection.UnresolvedCube(content.Cube.ReasonCode!),
      _ => throw new ArgumentOutOfRangeException()
    };
    var collectible = content.Collectible.Kind switch
    {
      CharacterCollectibleSelectionKind.GenericCollection or CharacterCollectibleSelectionKind.Favorite =>
          ProfilePersistedProjection.SelectedCollectible(
              content.Collectible.Kind,
              Restore(content.Collectible.Definition!),
              content.Collectible.Level),
      CharacterCollectibleSelectionKind.Detached => ProfilePersistedProjection.DetachedCollectible(),
      CharacterCollectibleSelectionKind.NotApplicable =>
          ProfilePersistedProjection.NotApplicableCollectible(),
      CharacterCollectibleSelectionKind.Unresolved =>
          ProfilePersistedProjection.UnresolvedCollectible(content.Collectible.ReasonCode!),
      _ => throw new ArgumentOutOfRangeException()
    };
    return ProfilePersistedProjection.CharacterBuild(
        content.DatasetBinding,
        content.MaterializationPolicy,
        content.ValidationMode,
        CharacterDefinitionReference.Restore(
            content.CharacterDefinition.CharacterUid,
            content.CharacterDefinition.DefinitionVersionUid,
            content.CharacterDefinition.DatasetSnapshotUid,
            content.CharacterDefinition.ContentSha256),
        content.Investment,
        content.Skills,
        equipment,
        cube,
        collectible);
  }

  private static CombatSupportDefinitionReference Restore(
      CombatSupportDefinitionReference reference) =>
      CombatSupportDefinitionReference.Restore(
          reference.DefinitionUid,
          reference.DefinitionVersionUid,
          reference.DatasetSnapshotUid,
          reference.Kind,
          reference.ContentSha256);

  private static CombatSupportDefinitionReference Restore(
      CombatSupportDefinitionVersion version) =>
      CombatSupportDefinitionReference.Restore(
          version.DefinitionUid,
          version.DefinitionVersionUid,
          version.DatasetSnapshotUid,
          version.Content.Kind,
          version.ContentSha256);

  private static CharacterBuildRevisionReference Restore(CharacterBuildRevisionReference reference) =>
      CharacterBuildRevisionReference.Restore(
          reference.CharacterBuildUid,
          reference.RevisionUid,
          reference.LocalAccountUid,
          reference.CharacterUid,
          reference.DatasetBinding,
          reference.ContentSha256,
          reference.Readiness,
          reference.CombatSemanticsReadiness);

  private static AccountCombatStateRevisionReference Restore(
      AccountCombatStateRevisionReference reference) =>
      AccountCombatStateRevisionReference.Restore(
          reference.AccountCombatStateUid,
          reference.RevisionUid,
          reference.LocalAccountUid,
          reference.DatasetBinding,
          reference.ContentSha256,
          reference.Readiness,
          reference.FullFidelityReadiness);

  private static SquadRevisionReference Restore(SquadRevisionReference reference) =>
      SquadRevisionReference.Restore(
          reference.SquadUid,
          reference.RevisionUid,
          reference.LocalAccountUid,
          reference.DatasetBinding,
          reference.Members.Select(Restore),
          reference.ContentSha256,
          reference.Readiness,
          reference.CombatSemanticsReadiness);

  private sealed record ProjectionFixture(
      SyntheticSupportCatalog Catalog,
      AccountCombatStateRevision AccountState,
      CharacterBuildRevision[] Builds,
      SquadRevision Squad,
      ProfileTemplateRevision Profile);
}
