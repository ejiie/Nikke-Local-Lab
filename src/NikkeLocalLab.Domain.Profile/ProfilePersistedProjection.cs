using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

/// <summary>
/// Rehydrates canonical profile content from source-free persisted values. These factories validate
/// graph shape and identity bindings; catalog-dependent game rules remain the persistence caller's
/// responsibility before publication.
/// </summary>
internal static class ProfilePersistedProjection
{
  public static ConsoleProgressState ConsoleProgress(
      CombatSupportConsoleCoordinate coordinate,
      CombatSupportDefinitionReference definition,
      ProfileFact<int> level,
      ProfileFact<long> experience)
  {
    RequireDefinitionKind(definition, CombatSupportDefinitionKind.Console, nameof(definition));
    return new ConsoleProgressState(
        ProfileGuard.RequireEnum(coordinate, nameof(coordinate)),
        definition,
        ProfileGuard.RequireFact(level, nameof(level)),
        ProfileGuard.RequireFact(experience, nameof(experience)));
  }

  public static AccountCombatStateRevisionContent AccountCombatState(
      ProfileDatasetBinding datasetBinding,
      ProfileValidationMode validationMode,
      ProfileFact<int> synchroLevel,
      IEnumerable<ConsoleProgressState> consoles,
      IEnumerable<OwnedCubeProgressState>? cubes = null)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(consoles);
    var values = consoles.ToArray();
    var coordinates = Enum.GetValues<CombatSupportConsoleCoordinate>();
    if (values.Any(static value => value is null) ||
        values.Length != coordinates.Length ||
        values.GroupBy(static value => value.Coordinate).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Persisted account combat state must contain each console coordinate exactly once.",
          nameof(consoles));
    }

    foreach (var value in values)
    {
      RequireDefinitionKind(value.Definition, CombatSupportDefinitionKind.Console, nameof(consoles));
      RequireSupportDataset(value.Definition, datasetBinding, nameof(consoles));
    }

    var normalized = coordinates.Select(coordinate =>
        values.Single(value => value.Coordinate == coordinate)).ToArray();
    var owned = (cubes ?? []).OrderBy(static cube => cube.Definition.DefinitionUid.ToString(), StringComparer.Ordinal).ToArray();
    if (owned.Any(static cube => cube.Level is < 1 or > 15) ||
        owned.Select(static cube => cube.Definition.DefinitionUid).Distinct().Count() != owned.Length)
    {
      throw new ArgumentException("Persisted cube inventory is invalid.", nameof(cubes));
    }

    foreach (var cube in owned)
    {
      RequireDefinitionKind(cube.Definition, CombatSupportDefinitionKind.HarmonyCube, nameof(cubes));
      RequireSupportDataset(cube.Definition, datasetBinding, nameof(cubes));
    }

    return new AccountCombatStateRevisionContent(
        datasetBinding,
        ProfileGuard.RequireEnum(validationMode, nameof(validationMode)),
        ProfileGuard.RequireFact(synchroLevel, nameof(synchroLevel)),
        Array.AsReadOnly(normalized),
        Array.AsReadOnly(owned));
  }

  public static CharacterOverloadLine OverloadLine(
      int lineIndex,
      CombatSupportDefinitionReference optionDefinition,
      ProfileFact<CombatSupportOverloadOptionType> optionType,
      ProfileFact<CombatSupportValueUnit> unit,
      CombatSupportExactValue applicationValue)
  {
    if (lineIndex is < 1 or > 3)
    {
      throw new ArgumentOutOfRangeException(nameof(lineIndex));
    }

    RequireDefinitionKind(
        optionDefinition,
        CombatSupportDefinitionKind.OverloadOption,
        nameof(optionDefinition));
    return new CharacterOverloadLine(
        lineIndex,
        optionDefinition,
        ProfileGuard.RequireFact(optionType, nameof(optionType)),
        ProfileGuard.RequireFact(unit, nameof(unit)),
        applicationValue);
  }

  public static CharacterEquipmentState AttachedEquipment(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      CombatSupportDefinitionReference definition,
      ProfileFact<int> tier,
      ProfileFact<int> enhancementLevel,
      ProfileFact<bool> manufacturerMatch,
      IEnumerable<CharacterOverloadLine>? overloadLines = null)
  {
    RequireDefinitionKind(definition, CombatSupportDefinitionKind.Equipment, nameof(definition));
    var lines = NormalizeOverloadLines(overloadLines);
    return new CharacterEquipmentState(
        ProfileGuard.RequireUid(equipmentSlotUid, nameof(equipmentSlotUid)),
        ProfileGuard.RequireEnum(slot, nameof(slot)),
        ProfileAttachmentKind.Attached,
        definition,
        ProfileGuard.RequireFact(tier, nameof(tier)),
        ProfileGuard.RequireFact(enhancementLevel, nameof(enhancementLevel)),
        ProfileGuard.RequireFact(manufacturerMatch, nameof(manufacturerMatch)),
        lines,
        null);
  }

  public static CharacterEquipmentState DetachedEquipment(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot) =>
      new(
          ProfileGuard.RequireUid(equipmentSlotUid, nameof(equipmentSlotUid)),
          ProfileGuard.RequireEnum(slot, nameof(slot)),
          ProfileAttachmentKind.Detached,
          null,
          ProfileFact<int>.NotApplicable(),
          ProfileFact<int>.NotApplicable(),
          ProfileFact<bool>.NotApplicable(),
          Array.Empty<CharacterOverloadLine>(),
          null);

  public static CharacterEquipmentState UnresolvedEquipment(
      EntityUid equipmentSlotUid,
      CombatSupportEquipmentSlot slot,
      string reasonCode)
  {
    var reason = ControlledCode.Require(reasonCode, nameof(reasonCode));
    return new CharacterEquipmentState(
        ProfileGuard.RequireUid(equipmentSlotUid, nameof(equipmentSlotUid)),
        ProfileGuard.RequireEnum(slot, nameof(slot)),
        ProfileAttachmentKind.Unresolved,
        null,
        ProfileFact<int>.Unresolved(reason),
        ProfileFact<int>.Unresolved(reason),
        ProfileFact<bool>.Unresolved(reason),
        Array.Empty<CharacterOverloadLine>(),
        reason);
  }

  public static CharacterCubeState AttachedCube(
      CombatSupportDefinitionReference definition,
      ProfileFact<int> level)
  {
    RequireDefinitionKind(definition, CombatSupportDefinitionKind.HarmonyCube, nameof(definition));
    return new CharacterCubeState(
        ProfileAttachmentKind.Attached,
        definition,
        ProfileGuard.RequireFact(level, nameof(level)),
        null);
  }

  public static CharacterCubeState DetachedCube() =>
      new(
          ProfileAttachmentKind.Detached,
          null,
          ProfileFact<int>.NotApplicable(),
          null);

  public static CharacterCubeState UnresolvedCube(string reasonCode)
  {
    var reason = ControlledCode.Require(reasonCode, nameof(reasonCode));
    return new CharacterCubeState(
        ProfileAttachmentKind.Unresolved,
        null,
        ProfileFact<int>.Unresolved(reason),
        reason);
  }

  public static CharacterCollectibleState SelectedCollectible(
      CharacterCollectibleSelectionKind selectionKind,
      CombatSupportDefinitionReference definition,
      ProfileFact<int> level)
  {
    var expectedKind = selectionKind switch
    {
      CharacterCollectibleSelectionKind.GenericCollection => CombatSupportDefinitionKind.GenericCollection,
      CharacterCollectibleSelectionKind.Favorite => CombatSupportDefinitionKind.Favorite,
      _ => throw new ArgumentException(
          "A selected collectible must be either generic collection or favorite.",
          nameof(selectionKind))
    };
    RequireDefinitionKind(definition, expectedKind, nameof(definition));
    return new CharacterCollectibleState(
        selectionKind,
        definition,
        ProfileGuard.RequireFact(level, nameof(level)),
        null);
  }

  public static CharacterCollectibleState DetachedCollectible() =>
      new(
          CharacterCollectibleSelectionKind.Detached,
          null,
          ProfileFact<int>.NotApplicable(),
          null);

  public static CharacterCollectibleState NotApplicableCollectible() =>
      new(
          CharacterCollectibleSelectionKind.NotApplicable,
          null,
          ProfileFact<int>.NotApplicable(),
          null);

  public static CharacterCollectibleState UnresolvedCollectible(string reasonCode)
  {
    var reason = ControlledCode.Require(reasonCode, nameof(reasonCode));
    return new CharacterCollectibleState(
        CharacterCollectibleSelectionKind.Unresolved,
        null,
        ProfileFact<int>.Unresolved(reason),
        reason);
  }

  public static CharacterBuildRevisionContent CharacterBuild(
      ProfileDatasetBinding datasetBinding,
      CharacterBuildMaterializationPolicy materializationPolicy,
      ProfileValidationMode validationMode,
      CharacterDefinitionReference characterDefinition,
      CharacterInvestmentState investment,
      CharacterSkillState skills,
      IEnumerable<CharacterEquipmentState> equipment,
      CharacterCubeState cube,
      CharacterCollectibleState collectible)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(characterDefinition);
    ArgumentNullException.ThrowIfNull(investment);
    ArgumentNullException.ThrowIfNull(skills);
    ArgumentNullException.ThrowIfNull(equipment);
    ArgumentNullException.ThrowIfNull(cube);
    ArgumentNullException.ThrowIfNull(collectible);
    if (characterDefinition.DatasetSnapshotUid != datasetBinding.CharacterCatalog.DatasetSnapshotUid)
    {
      throw new ArgumentException(
          "The character definition must belong to the pinned character dataset.",
          nameof(characterDefinition));
    }

    var values = equipment.ToArray();
    var slots = Enum.GetValues<CombatSupportEquipmentSlot>();
    if (values.Any(static value => value is null) ||
        values.Length != slots.Length ||
        values.GroupBy(static value => value.Slot).Any(static group => group.Count() != 1) ||
        values.GroupBy(static value => value.EquipmentSlotUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Persisted build content must contain four uniquely identified equipment coordinates.",
          nameof(equipment));
    }

    foreach (var value in values)
    {
      ValidateEquipmentState(value, datasetBinding, nameof(equipment));
    }

    ValidateCubeState(cube, datasetBinding, nameof(cube));
    ValidateCollectibleState(collectible, datasetBinding, nameof(collectible));
    var normalized = slots.Select(slot => values.Single(value => value.Slot == slot)).ToArray();
    return new CharacterBuildRevisionContent(
        datasetBinding,
        ProfileGuard.RequireEnum(materializationPolicy, nameof(materializationPolicy)),
        ProfileGuard.RequireEnum(validationMode, nameof(validationMode)),
        characterDefinition,
        investment,
        skills,
        Array.AsReadOnly(normalized),
        cube,
        collectible);
  }

  public static SquadRevisionContent Squad(
      ProfileDatasetBinding datasetBinding,
      IEnumerable<CharacterBuildRevisionReference> orderedBuildRevisions)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(orderedBuildRevisions);
    var values = NormalizeSquadBuildReferences(
        datasetBinding,
        orderedBuildRevisions,
        nameof(orderedBuildRevisions));
    var members = values.Select((reference, index) =>
        new SquadMemberReference(index + 1, reference)).ToArray();
    return new SquadRevisionContent(datasetBinding, Array.AsReadOnly(members));
  }

  public static SquadValidation ValidateSquadReadiness(SquadRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var selectionIssues = new List<ProfileValidationIssue>();
    foreach (var member in content.Members)
    {
      var field = $"squad_slot_{member.SlotIndex}";
      if (member.BuildRevision.Readiness == ProfileReadiness.Invalid)
      {
        selectionIssues.Add(ProfileGuard.Invalid(field, "build_revision_invalid"));
      }
      else if (member.BuildRevision.Readiness == ProfileReadiness.Unresolved)
      {
        selectionIssues.Add(ProfileGuard.Unresolved(field, "build_revision_unresolved"));
      }
    }

    var combatSemanticsIssues = new List<ProfileValidationIssue>(selectionIssues);
    foreach (var member in content.Members)
    {
      var field = $"squad_slot_{member.SlotIndex}_combat_semantics";
      if (member.BuildRevision.CombatSemanticsReadiness == ProfileReadiness.Invalid)
      {
        combatSemanticsIssues.Add(ProfileGuard.Invalid(field, "build_combat_semantics_invalid"));
      }
      else if (member.BuildRevision.CombatSemanticsReadiness == ProfileReadiness.Unresolved)
      {
        combatSemanticsIssues.Add(ProfileGuard.Unresolved(field, "build_combat_semantics_unresolved"));
      }
    }

    return new SquadValidation(
        new ProfileValidationResult(selectionIssues),
        new ProfileValidationResult(combatSemanticsIssues));
  }

  public static ProfileTemplateRevisionContent ProfileTemplate(
      ProfileDatasetBinding datasetBinding,
      AccountCombatStateRevisionReference accountCombatStateRevision,
      IEnumerable<CharacterBuildRevisionReference> buildRevisions,
      SquadRevisionReference? activeSquadRevision)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(accountCombatStateRevision);
    ArgumentNullException.ThrowIfNull(buildRevisions);
    if (!accountCombatStateRevision.DatasetBinding.Equals(datasetBinding))
    {
      throw new ArgumentException(
          "The account combat state must belong to the pinned combat-support catalog.",
          nameof(accountCombatStateRevision));
    }

    var builds = buildRevisions.ToArray();
    if (builds.Any(static build => build is null) ||
        builds.GroupBy(static build => build.CharacterBuildUid).Any(static group => group.Count() != 1) ||
        builds.GroupBy(static build => build.RevisionUid).Any(static group => group.Count() != 1) ||
        builds.Any(build =>
            build.LocalAccountUid != accountCombatStateRevision.LocalAccountUid ||
            !build.DatasetBinding.Equals(datasetBinding)))
    {
      throw new ArgumentException(
          "Persisted template membership must retain unique exact revisions for one account and binding.",
          nameof(buildRevisions));
    }

    var normalized = builds
        .OrderBy(static build => build.CharacterBuildUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    if (activeSquadRevision is { } squad)
    {
      if (squad.LocalAccountUid != accountCombatStateRevision.LocalAccountUid ||
          !squad.DatasetBinding.Equals(datasetBinding))
      {
        throw new ArgumentException(
            "The active squad must belong to the template account and binding.",
            nameof(activeSquadRevision));
      }

      foreach (var member in squad.Members)
      {
        if (!normalized.Any(build =>
                build.CharacterBuildUid == member.CharacterBuildUid &&
                build.RevisionUid == member.RevisionUid &&
                build.ContentSha256 == member.ContentSha256))
        {
          throw new ArgumentException(
              "Every active squad member must be an exact template build member.",
              nameof(activeSquadRevision));
        }
      }
    }

    return new ProfileTemplateRevisionContent(
        datasetBinding,
        accountCombatStateRevision,
        Array.AsReadOnly(normalized),
        activeSquadRevision);
  }

  public static ProfileTemplateValidation ValidateProfileTemplateReadiness(
      ProfileTemplateRevisionContent content)
  {
    ArgumentNullException.ThrowIfNull(content);
    var draftIssues = Array.Empty<ProfileValidationIssue>();
    var combatIssues = new List<ProfileValidationIssue>();
    if (content.AccountCombatStateRevision.Readiness == ProfileReadiness.Invalid)
    {
      combatIssues.Add(ProfileGuard.Invalid("account_combat_state", "account_combat_state_invalid"));
    }
    else if (content.AccountCombatStateRevision.Readiness == ProfileReadiness.Unresolved)
    {
      combatIssues.Add(ProfileGuard.Unresolved("account_combat_state", "account_combat_state_unresolved"));
    }

    if (content.ActiveSquadRevision is null)
    {
      combatIssues.Add(ProfileGuard.Unresolved("active_squad", "active_squad_required_for_combat"));
    }
    else if (content.ActiveSquadRevision.Readiness == ProfileReadiness.Invalid)
    {
      combatIssues.Add(ProfileGuard.Invalid("active_squad", "squad_revision_invalid"));
    }
    else if (content.ActiveSquadRevision.Readiness == ProfileReadiness.Unresolved)
    {
      combatIssues.Add(ProfileGuard.Unresolved("active_squad", "squad_revision_unresolved"));
    }

    var combatSemanticsIssues = new List<ProfileValidationIssue>(combatIssues);
    if (content.ActiveSquadRevision?.CombatSemanticsReadiness == ProfileReadiness.Invalid)
    {
      combatSemanticsIssues.Add(ProfileGuard.Invalid(
          "active_squad",
          "squad_combat_semantics_invalid"));
    }
    else if (content.ActiveSquadRevision?.CombatSemanticsReadiness == ProfileReadiness.Unresolved)
    {
      combatSemanticsIssues.Add(ProfileGuard.Unresolved(
          "active_squad",
          "squad_combat_semantics_unresolved"));
    }

    return new ProfileTemplateValidation(
        new ProfileValidationResult(draftIssues),
        new ProfileValidationResult(combatIssues),
        new ProfileValidationResult(combatSemanticsIssues));
  }

  private static IReadOnlyList<CharacterOverloadLine> NormalizeOverloadLines(
      IEnumerable<CharacterOverloadLine>? overloadLines)
  {
    var values = (overloadLines ?? Array.Empty<CharacterOverloadLine>()).ToArray();
    if (values.Any(static value => value is null) ||
        values.Any(static value => value.LineIndex is < 1 or > 3) ||
        values.GroupBy(static value => value.LineIndex).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Persisted OL lines must be a unique sparse subset of fixed indexes 1..3.",
          nameof(overloadLines));
    }

    return Array.AsReadOnly(values.OrderBy(static value => value.LineIndex).ToArray());
  }

  private static IReadOnlyList<CharacterBuildRevisionReference> NormalizeSquadBuildReferences(
      ProfileDatasetBinding datasetBinding,
      IEnumerable<CharacterBuildRevisionReference> orderedBuildRevisions,
      string parameterName)
  {
    var values = orderedBuildRevisions.ToArray();
    if (values.Any(static value => value is null) || values.Length != 5 ||
        values.GroupBy(static value => value.CharacterUid).Any(static group => group.Count() != 1) ||
        values.GroupBy(static value => value.CharacterBuildUid).Any(static group => group.Count() != 1) ||
        values.GroupBy(static value => value.RevisionUid).Any(static group => group.Count() != 1) ||
        values.Select(static value => value.LocalAccountUid).Distinct().Count() != 1 ||
        values.Any(value => !value.DatasetBinding.Equals(datasetBinding)))
    {
      throw new ArgumentException(
          "Persisted squad content must retain five distinct characters/build revisions for one account and binding.",
          parameterName);
    }

    return Array.AsReadOnly(values);
  }

  private static void ValidateEquipmentState(
      CharacterEquipmentState state,
      ProfileDatasetBinding datasetBinding,
      string parameterName)
  {
    switch (state.AttachmentKind)
    {
      case ProfileAttachmentKind.Attached:
        RequireDefinitionKind(state.Definition, CombatSupportDefinitionKind.Equipment, parameterName);
        RequireSupportDataset(state.Definition!, datasetBinding, parameterName);
        foreach (var line in state.OverloadLines)
        {
          RequireDefinitionKind(
              line.OptionDefinition,
              CombatSupportDefinitionKind.OverloadOption,
              parameterName);
          RequireSupportDataset(line.OptionDefinition, datasetBinding, parameterName);
        }

        break;
      case ProfileAttachmentKind.Detached:
        if (state.Definition is not null || state.ReasonCode is not null || state.OverloadLines.Count != 0 ||
            state.Tier.Status != ProfileFactStatus.NotApplicable ||
            state.EnhancementLevel.Status != ProfileFactStatus.NotApplicable ||
            state.ManufacturerMatch.Status != ProfileFactStatus.NotApplicable)
        {
          throw new ArgumentException("A detached equipment projection contains attached state.", parameterName);
        }

        break;
      case ProfileAttachmentKind.Unresolved:
        if (state.Definition is not null || state.OverloadLines.Count != 0 || state.ReasonCode is null ||
            state.Tier.Status != ProfileFactStatus.Unresolved ||
            state.EnhancementLevel.Status != ProfileFactStatus.Unresolved ||
            state.ManufacturerMatch.Status != ProfileFactStatus.Unresolved)
        {
          throw new ArgumentException("An unresolved equipment projection has an incoherent shape.", parameterName);
        }

        break;
      default:
        throw new ArgumentOutOfRangeException(parameterName);
    }
  }

  private static void ValidateCubeState(
      CharacterCubeState state,
      ProfileDatasetBinding datasetBinding,
      string parameterName)
  {
    switch (state.AttachmentKind)
    {
      case ProfileAttachmentKind.Attached:
        RequireDefinitionKind(state.Definition, CombatSupportDefinitionKind.HarmonyCube, parameterName);
        RequireSupportDataset(state.Definition!, datasetBinding, parameterName);
        break;
      case ProfileAttachmentKind.Detached:
        if (state.Definition is not null || state.ReasonCode is not null ||
            state.Level.Status != ProfileFactStatus.NotApplicable)
        {
          throw new ArgumentException("A detached cube projection contains attached state.", parameterName);
        }

        break;
      case ProfileAttachmentKind.Unresolved:
        if (state.Definition is not null || state.ReasonCode is null ||
            state.Level.Status != ProfileFactStatus.Unresolved)
        {
          throw new ArgumentException("An unresolved cube projection has an incoherent shape.", parameterName);
        }

        break;
      default:
        throw new ArgumentOutOfRangeException(parameterName);
    }
  }

  private static void ValidateCollectibleState(
      CharacterCollectibleState state,
      ProfileDatasetBinding datasetBinding,
      string parameterName)
  {
    switch (state.Kind)
    {
      case CharacterCollectibleSelectionKind.GenericCollection:
        RequireDefinitionKind(state.Definition, CombatSupportDefinitionKind.GenericCollection, parameterName);
        RequireSupportDataset(state.Definition!, datasetBinding, parameterName);
        break;
      case CharacterCollectibleSelectionKind.Favorite:
        RequireDefinitionKind(state.Definition, CombatSupportDefinitionKind.Favorite, parameterName);
        RequireSupportDataset(state.Definition!, datasetBinding, parameterName);
        break;
      case CharacterCollectibleSelectionKind.Detached:
      case CharacterCollectibleSelectionKind.NotApplicable:
        if (state.Definition is not null || state.ReasonCode is not null ||
            state.Level.Status != ProfileFactStatus.NotApplicable)
        {
          throw new ArgumentException("An empty collectible projection contains selected state.", parameterName);
        }

        break;
      case CharacterCollectibleSelectionKind.Unresolved:
        if (state.Definition is not null || state.ReasonCode is null ||
            state.Level.Status != ProfileFactStatus.Unresolved)
        {
          throw new ArgumentException("An unresolved collectible projection has an incoherent shape.", parameterName);
        }

        break;
      default:
        throw new ArgumentOutOfRangeException(parameterName);
    }
  }

  private static void RequireDefinitionKind(
      CombatSupportDefinitionReference? definition,
      CombatSupportDefinitionKind expected,
      string parameterName)
  {
    if (definition is null || definition.Kind != expected)
    {
      throw new ArgumentException($"The persisted definition reference must be {expected}.", parameterName);
    }
  }

  private static void RequireSupportDataset(
      CombatSupportDefinitionReference definition,
      ProfileDatasetBinding datasetBinding,
      string parameterName)
  {
    if (definition.DatasetSnapshotUid != datasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
    {
      throw new ArgumentException(
          "The combat-support definition must belong to the pinned support dataset.",
          parameterName);
    }
  }
}
