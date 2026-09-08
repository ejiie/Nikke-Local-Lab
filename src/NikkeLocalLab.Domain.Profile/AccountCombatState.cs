using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class AccountCombatState
{
  public AccountCombatState(EntityUid accountCombatStateUid, LocalAccount account)
  {
    ArgumentNullException.ThrowIfNull(account);
    AccountCombatStateUid = ProfileGuard.RequireUid(accountCombatStateUid, nameof(accountCombatStateUid));
    LocalAccountUid = account.LocalAccountUid;
  }

  public EntityUid AccountCombatStateUid { get; }

  public EntityUid LocalAccountUid { get; }
}

public sealed class ConsoleProgressInput
{
  public ConsoleProgressInput(
      CombatSupportDefinitionVersion definitionVersion,
      ProfileFact<int> level,
      ProfileFact<long> experience)
  {
    ArgumentNullException.ThrowIfNull(definitionVersion);
    if (definitionVersion.Content is not ConsoleDefinitionContent console)
    {
      throw new ArgumentException("A console progress input must reference a console definition.", nameof(definitionVersion));
    }

    DefinitionVersion = definitionVersion;
    Coordinate = console.Coordinate;
    Level = ProfileGuard.RequireFact(level, nameof(level));
    Experience = ProfileGuard.RequireFact(experience, nameof(experience));
  }

  public CombatSupportDefinitionVersion DefinitionVersion { get; }

  public CombatSupportConsoleCoordinate Coordinate { get; }

  public ProfileFact<int> Level { get; }

  public ProfileFact<long> Experience { get; }
}

public sealed class ConsoleProgressState
{
  internal ConsoleProgressState(
      CombatSupportConsoleCoordinate coordinate,
      CombatSupportDefinitionReference definition,
      ProfileFact<int> level,
      ProfileFact<long> experience)
  {
    Coordinate = ProfileGuard.RequireEnum(coordinate, nameof(coordinate));
    Definition = definition ?? throw new ArgumentNullException(nameof(definition));
    Level = ProfileGuard.RequireFact(level, nameof(level));
    Experience = ProfileGuard.RequireFact(experience, nameof(experience));
  }

  public CombatSupportConsoleCoordinate Coordinate { get; }

  public CombatSupportDefinitionReference Definition { get; }

  public ProfileFact<int> Level { get; }

  /// <summary>
  /// Exact progress when retained, or an explicit unresolved fact when only combat-effective level is known.
  /// </summary>
  public ProfileFact<long> Experience { get; }
}

public sealed record OwnedCubeProgressState(CombatSupportDefinitionReference Definition, int Level);

public sealed class AccountCombatStateRevisionContent
{
  internal AccountCombatStateRevisionContent(
      ProfileDatasetBinding datasetBinding,
      ProfileValidationMode validationMode,
      ProfileFact<int> synchroLevel,
      IReadOnlyList<ConsoleProgressState> consoles,
      IReadOnlyList<OwnedCubeProgressState>? cubes = null)
  {
    DatasetBinding = datasetBinding ?? throw new ArgumentNullException(nameof(datasetBinding));
    ValidationMode = ProfileGuard.RequireEnum(validationMode, nameof(validationMode));
    SynchroLevel = ProfileGuard.RequireFact(synchroLevel, nameof(synchroLevel));
    Consoles = consoles ?? throw new ArgumentNullException(nameof(consoles));
    Cubes = cubes ?? Array.Empty<OwnedCubeProgressState>();
  }

  public ProfileDatasetBinding DatasetBinding { get; }

  public ProfileValidationMode ValidationMode { get; }

  public ProfileFact<int> SynchroLevel { get; }

  public IReadOnlyList<ConsoleProgressState> Consoles { get; }

  public IReadOnlyList<OwnedCubeProgressState> Cubes { get; }
}

public sealed class AccountCombatStateValidation
{
  internal AccountCombatStateValidation(
      ProfileValidationResult combat,
      ProfileValidationResult fullFidelity)
  {
    Combat = combat;
    FullFidelity = fullFidelity;
  }

  /// <summary>Readiness for combat calculation; console EXP is intentionally excluded.</summary>
  public ProfileValidationResult Combat { get; }

  /// <summary>Readiness for lossless account-progress restoration, including console EXP.</summary>
  public ProfileValidationResult FullFidelity { get; }
}

public sealed class AccountCombatStateRevision
{
  private AccountCombatStateRevision(
      EntityUid accountCombatStateRevisionUid,
      EntityUid accountCombatStateUid,
      EntityUid localAccountUid,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      AccountCombatStateRevisionContent content,
      AccountCombatStateValidation validation)
  {
    AccountCombatStateRevisionUid = accountCombatStateRevisionUid;
    AccountCombatStateUid = accountCombatStateUid;
    LocalAccountUid = localAccountUid;
    RevisionNumber = revisionNumber;
    Provenance = provenance;
    Content = content;
    Validation = validation;
    ContentSha256 = ProfileCanonicalizer.ComputeContentHash(content);
  }

  public EntityUid AccountCombatStateRevisionUid { get; }

  public EntityUid AccountCombatStateUid { get; }

  public EntityUid LocalAccountUid { get; }

  public long RevisionNumber { get; }

  public ProfileRevisionProvenance Provenance { get; }

  public AccountCombatStateRevisionContent Content { get; }

  public AccountCombatStateValidation Validation { get; }

  public ProfileReadiness Readiness => Validation.Combat.Status;

  public ProfileReadiness FullFidelityReadiness => Validation.FullFidelity.Status;

  public Sha256Digest ContentSha256 { get; }

  public static AccountCombatStateRevision Create(
      EntityUid accountCombatStateRevisionUid,
      AccountCombatState state,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      ProfileValidationMode validationMode,
      ProfileFact<int> synchroLevel,
      IEnumerable<ConsoleProgressInput> consoles)
  {
    ArgumentNullException.ThrowIfNull(state);
    ArgumentNullException.ThrowIfNull(catalogEvidence);
    ArgumentNullException.ThrowIfNull(consoles);
    ProfileGuard.RequireRevision(revisionNumber, provenance);

    var normalizedInputs = NormalizeInputs(consoles);
    catalogEvidence.RequireCombatSupport(
        normalizedInputs.Select(static input => input.DefinitionVersion),
        nameof(consoles));
    var states = normalizedInputs
        .Select(input => new ConsoleProgressState(
            input.Coordinate,
            CombatSupportDefinitionReference.From(input.DefinitionVersion),
            input.Level,
            input.Experience))
        .ToArray();
    var content = new AccountCombatStateRevisionContent(
        catalogEvidence.DatasetBinding,
        validationMode,
        synchroLevel,
        Array.AsReadOnly(states));
    var validation = ValidateContent(content, normalizedInputs.Select(static item => item.DefinitionVersion));

    return new AccountCombatStateRevision(
        ProfileGuard.RequireUid(accountCombatStateRevisionUid, nameof(accountCombatStateRevisionUid)),
        state.AccountCombatStateUid,
        state.LocalAccountUid,
        revisionNumber,
        provenance,
        content,
        validation);
  }

  public AccountCombatStateValidation Validate(
      IEnumerable<CombatSupportDefinitionVersion> consoleDefinitions) =>
      ValidateContent(Content, consoleDefinitions);

  public AccountCombatStateRevisionReference ToReference() =>
      AccountCombatStateRevisionReference.Restore(
          AccountCombatStateUid,
          AccountCombatStateRevisionUid,
          LocalAccountUid,
          Content.DatasetBinding,
          ContentSha256,
          Readiness,
          FullFidelityReadiness);

  private static IReadOnlyList<ConsoleProgressInput> NormalizeInputs(IEnumerable<ConsoleProgressInput> consoles)
  {
    var items = consoles.ToArray();
    var expected = Enum.GetValues<CombatSupportConsoleCoordinate>();
    if (items.Any(static item => item is null) ||
        items.Length != expected.Length ||
        items.GroupBy(static item => item.Coordinate).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("Account combat state must contain each of the nine console coordinates exactly once.", nameof(consoles));
    }

    return Array.AsReadOnly(expected.Select(coordinate => items.Single(item => item.Coordinate == coordinate)).ToArray());
  }

  private static AccountCombatStateValidation ValidateContent(
      AccountCombatStateRevisionContent content,
      IEnumerable<CombatSupportDefinitionVersion> definitions)
  {
    ArgumentNullException.ThrowIfNull(definitions);
    var definitionList = definitions.ToArray();
    if (definitionList.Any(static item => item is null) ||
        definitionList.GroupBy(static item => item.DefinitionVersionUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("Console definition evidence must contain unique version UIDs.", nameof(definitions));
    }

    var combatIssues = new List<ProfileValidationIssue>();
    var fidelityIssues = new List<ProfileValidationIssue>();
    ProfileGuard.AddRequiredFactIssue(content.SynchroLevel, "synchro_level", combatIssues);
    if (content.SynchroLevel.Value is { } synchro && synchro <= 0)
    {
      combatIssues.Add(ProfileGuard.Invalid("synchro_level", "level_must_be_positive"));
    }

    foreach (var state in content.Consoles)
    {
      var coordinateCode = ProfileCanonicalCodes.ConsoleCoordinate(state.Coordinate);
      var fieldPrefix = $"console_{coordinateCode.Replace("-", "_", StringComparison.Ordinal)}";
      var definition = definitionList.SingleOrDefault(item => state.Definition.Matches(item));
      if (definition?.Content is not ConsoleDefinitionContent console || console.Coordinate != state.Coordinate)
      {
        combatIssues.Add(ProfileGuard.Invalid($"{fieldPrefix}_definition", "definition_reference_mismatch"));
      }
      else
      {
        if (definition.DatasetSnapshotUid != content.DatasetBinding.CombatSupportCatalog.DatasetSnapshotUid)
        {
          combatIssues.Add(ProfileGuard.Invalid($"{fieldPrefix}_definition", "dataset_binding_mismatch"));
        }

        ValidateConsoleLevel(
            state,
            console,
            content.ValidationMode,
            content.SynchroLevel,
            fieldPrefix,
            combatIssues);
        if (!console.HasCompleteCombatSemantics)
        {
          combatIssues.Add(ProfileGuard.Unresolved(
              $"{fieldPrefix}_combat_semantics",
              "console_combat_semantics_unresolved"));
        }
      }

      if (state.Experience.Status == ProfileFactStatus.Unresolved)
      {
        fidelityIssues.Add(ProfileGuard.Unresolved(
            $"{fieldPrefix}_experience",
            state.Experience.ReasonCode ?? "console_progress_not_retained"));
      }
      else if (state.Experience.Status == ProfileFactStatus.NotApplicable)
      {
        fidelityIssues.Add(ProfileGuard.Invalid($"{fieldPrefix}_experience", "progress_is_applicable"));
      }
      else if (state.Experience.RequireValue() < 0)
      {
        fidelityIssues.Add(ProfileGuard.Invalid($"{fieldPrefix}_experience", "experience_cannot_be_negative"));
      }
    }

    fidelityIssues.InsertRange(0, combatIssues);
    return new AccountCombatStateValidation(
        new ProfileValidationResult(combatIssues),
        new ProfileValidationResult(fidelityIssues));
  }

  private static void ValidateConsoleLevel(
      ConsoleProgressState state,
      ConsoleDefinitionContent definition,
      ProfileValidationMode validationMode,
      ProfileFact<int> synchroLevel,
      string fieldPrefix,
      ICollection<ProfileValidationIssue> issues)
  {
    ProfileGuard.AddRequiredFactIssue(state.Level, $"{fieldPrefix}_level", issues);
    if (state.Level.Status != ProfileFactStatus.Ready)
    {
      return;
    }

    var level = state.Level.RequireValue();
    if (level < 0)
    {
      issues.Add(ProfileGuard.Invalid($"{fieldPrefix}_level", "level_cannot_be_negative"));
      return;
    }

    if (definition.MaximumLevel.Status != CombatSupportFactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved($"{fieldPrefix}_level", "console_maximum_unresolved"));
    }
    else if (level > definition.MaximumLevel.RequireValue())
    {
      issues.Add(ProfileGuard.Invalid($"{fieldPrefix}_level", "above_catalog_maximum"));
    }

    if (validationMode != ProfileValidationMode.GameLegal || level == 0 ||
        definition.MaximumLevel.Status != CombatSupportFactStatus.Ready ||
        level > definition.MaximumLevel.RequireValue())
    {
      return;
    }

    var coordinate = definition.Levels.SingleOrDefault(item => item.Level == level);
    if (coordinate is null)
    {
      issues.Add(ProfileGuard.Invalid($"{fieldPrefix}_level", "level_coordinate_missing"));
      return;
    }

    if (coordinate.MinimumSynchroLevel.Status != CombatSupportFactStatus.Ready)
    {
      issues.Add(ProfileGuard.Unresolved($"{fieldPrefix}_level", "minimum_synchro_unresolved"));
    }
    else if (synchroLevel.Status == ProfileFactStatus.Ready &&
             synchroLevel.RequireValue() < coordinate.MinimumSynchroLevel.RequireValue())
    {
      issues.Add(ProfileGuard.Invalid($"{fieldPrefix}_level", "synchro_below_console_requirement"));
    }
  }
}

public sealed class AccountCombatStateRevisionReference
{
  private AccountCombatStateRevisionReference(
      EntityUid accountCombatStateUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      ProfileDatasetBinding datasetBinding,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness fullFidelityReadiness)
  {
    AccountCombatStateUid = accountCombatStateUid;
    RevisionUid = revisionUid;
    LocalAccountUid = localAccountUid;
    DatasetBinding = datasetBinding;
    ContentSha256 = contentSha256;
    Readiness = readiness;
    FullFidelityReadiness = fullFidelityReadiness;
  }

  public EntityUid AccountCombatStateUid { get; }

  public EntityUid RevisionUid { get; }

  public EntityUid LocalAccountUid { get; }

  public ProfileDatasetBinding DatasetBinding { get; }

  public ProfileCatalogBinding CombatSupportCatalog => DatasetBinding.CombatSupportCatalog;

  public Sha256Digest ContentSha256 { get; }

  public ProfileReadiness Readiness { get; }

  public ProfileReadiness FullFidelityReadiness { get; }

  internal static AccountCombatStateRevisionReference Restore(
      EntityUid accountCombatStateUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      ProfileDatasetBinding datasetBinding,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness fullFidelityReadiness) =>
      new(
          ProfileGuard.RequireUid(accountCombatStateUid, nameof(accountCombatStateUid)),
          ProfileGuard.RequireUid(revisionUid, nameof(revisionUid)),
          ProfileGuard.RequireUid(localAccountUid, nameof(localAccountUid)),
          datasetBinding ?? throw new ArgumentNullException(nameof(datasetBinding)),
          ProfileGuard.RequireDigest(contentSha256, nameof(contentSha256)),
          ProfileGuard.RequireEnum(readiness, nameof(readiness)),
          ProfileGuard.RequireEnum(fullFidelityReadiness, nameof(fullFidelityReadiness)));
}
