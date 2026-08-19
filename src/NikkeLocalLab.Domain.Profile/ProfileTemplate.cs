using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class ProfileTemplate
{
  public ProfileTemplate(EntityUid profileTemplateUid, LocalAccount account)
  {
    ArgumentNullException.ThrowIfNull(account);
    ProfileTemplateUid = ProfileGuard.RequireUid(profileTemplateUid, nameof(profileTemplateUid));
    LocalAccountUid = account.LocalAccountUid;
  }

  public EntityUid ProfileTemplateUid { get; }

  public EntityUid LocalAccountUid { get; }
}

public sealed class ProfileTemplateRevisionContent
{
  internal ProfileTemplateRevisionContent(
      ProfileDatasetBinding datasetBinding,
      AccountCombatStateRevisionReference accountCombatStateRevision,
      IReadOnlyList<CharacterBuildRevisionReference> buildRevisions,
      SquadRevisionReference? activeSquadRevision)
  {
    DatasetBinding = datasetBinding;
    AccountCombatStateRevision = accountCombatStateRevision;
    BuildRevisions = buildRevisions;
    ActiveSquadRevision = activeSquadRevision;
  }

  public ProfileDatasetBinding DatasetBinding { get; }

  public AccountCombatStateRevisionReference AccountCombatStateRevision { get; }

  public IReadOnlyList<CharacterBuildRevisionReference> BuildRevisions { get; }

  public SquadRevisionReference? ActiveSquadRevision { get; }
}

public sealed class ProfileTemplateValidation
{
  internal ProfileTemplateValidation(
      ProfileValidationResult draft,
      ProfileValidationResult combat,
      ProfileValidationResult combatSemantics)
  {
    Draft = draft;
    Combat = combat;
    CombatSemantics = combatSemantics;
  }

  /// <summary>Validity of the account/build membership. An empty build set and no active squad are allowed.</summary>
  public ProfileValidationResult Draft { get; }

  /// <summary>Readiness for battle; a ready active squad and account combat state are required.</summary>
  public ProfileValidationResult Combat { get; }

  /// <summary>Readiness for standalone normalized calculation without original-client skill lookup.</summary>
  public ProfileValidationResult CombatSemantics { get; }
}

public sealed class ProfileTemplateRevision
{
  private ProfileTemplateRevision(
      EntityUid profileTemplateRevisionUid,
      EntityUid profileTemplateUid,
      EntityUid localAccountUid,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileTemplateRevisionContent content,
      ProfileTemplateValidation validation)
  {
    ProfileTemplateRevisionUid = profileTemplateRevisionUid;
    ProfileTemplateUid = profileTemplateUid;
    LocalAccountUid = localAccountUid;
    RevisionNumber = revisionNumber;
    Provenance = provenance;
    Content = content;
    Validation = validation;
    ContentSha256 = ProfileCanonicalizer.ComputeContentHash(content);
  }

  public EntityUid ProfileTemplateRevisionUid { get; }

  public EntityUid ProfileTemplateUid { get; }

  public EntityUid LocalAccountUid { get; }

  public long RevisionNumber { get; }

  public ProfileRevisionProvenance Provenance { get; }

  public ProfileTemplateRevisionContent Content { get; }

  public ProfileTemplateValidation Validation { get; }

  public ProfileReadiness Readiness => Validation.Draft.Status;

  public ProfileReadiness CombatReadiness => Validation.Combat.Status;

  public ProfileReadiness CombatSemanticsReadiness => Validation.CombatSemantics.Status;

  public Sha256Digest ContentSha256 { get; }

  public static ProfileTemplateRevision Create(
      EntityUid profileTemplateRevisionUid,
      ProfileTemplate template,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      AccountCombatStateRevision accountCombatStateRevision,
      IEnumerable<CharacterBuildRevision> buildRevisions,
      SquadRevision? activeSquadRevision)
  {
    ArgumentNullException.ThrowIfNull(template);
    ArgumentNullException.ThrowIfNull(catalogEvidence);
    ArgumentNullException.ThrowIfNull(accountCombatStateRevision);
    ArgumentNullException.ThrowIfNull(buildRevisions);
    ProfileGuard.RequireRevision(revisionNumber, provenance);
    var datasetBinding = catalogEvidence.DatasetBinding;
    var builds = buildRevisions.ToArray();
    if (builds.Any(static build => build is null) ||
        builds.GroupBy(static build => build.CharacterBuildUid).Any(static group => group.Count() != 1) ||
        builds.GroupBy(static build => build.CharacterBuildRevisionUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("A template must contain unique build and exact revision identities.", nameof(buildRevisions));
    }

    var references = builds.Select(static build => build.ToReference())
        .OrderBy(static reference => reference.CharacterBuildUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var content = new ProfileTemplateRevisionContent(
        datasetBinding,
        accountCombatStateRevision.ToReference(),
        Array.AsReadOnly(references),
        activeSquadRevision?.ToReference());
    var draftIssues = ValidateDraft(template, content);
    var combatIssues = new List<ProfileValidationIssue>(draftIssues);
    ValidateCombat(content, combatIssues);
    var combatSemanticsIssues = new List<ProfileValidationIssue>(combatIssues);
    ValidateCombatSemantics(content, combatSemanticsIssues);

    return new ProfileTemplateRevision(
        ProfileGuard.RequireUid(profileTemplateRevisionUid, nameof(profileTemplateRevisionUid)),
        template.ProfileTemplateUid,
        template.LocalAccountUid,
        revisionNumber,
        provenance,
        content,
        new ProfileTemplateValidation(
            new ProfileValidationResult(draftIssues),
            new ProfileValidationResult(combatIssues),
            new ProfileValidationResult(combatSemanticsIssues)));
  }

  private static List<ProfileValidationIssue> ValidateDraft(
      ProfileTemplate template,
      ProfileTemplateRevisionContent content)
  {
    var issues = new List<ProfileValidationIssue>();
    var account = content.AccountCombatStateRevision;
    if (account.LocalAccountUid != template.LocalAccountUid)
    {
      issues.Add(ProfileGuard.Invalid("account_combat_state", "local_account_mismatch"));
    }

    if (!account.DatasetBinding.Equals(content.DatasetBinding))
    {
      issues.Add(ProfileGuard.Invalid("account_combat_state", "catalog_binding_mismatch"));
    }

    foreach (var build in content.BuildRevisions)
    {
      if (build.LocalAccountUid != template.LocalAccountUid)
      {
        issues.Add(ProfileGuard.Invalid("build_membership", "local_account_mismatch"));
      }

      if (!build.DatasetBinding.Equals(content.DatasetBinding))
      {
        issues.Add(ProfileGuard.Invalid("build_membership", "catalog_binding_mismatch"));
      }
    }

    if (content.ActiveSquadRevision is { } squad)
    {
      if (squad.LocalAccountUid != template.LocalAccountUid)
      {
        issues.Add(ProfileGuard.Invalid("active_squad", "local_account_mismatch"));
      }

      if (!squad.DatasetBinding.Equals(content.DatasetBinding))
      {
        issues.Add(ProfileGuard.Invalid("active_squad", "catalog_binding_mismatch"));
      }

      foreach (var member in squad.Members)
      {
        if (!content.BuildRevisions.Any(build =>
                build.CharacterBuildUid == member.CharacterBuildUid &&
                build.RevisionUid == member.RevisionUid &&
                build.ContentSha256 == member.ContentSha256))
        {
          issues.Add(ProfileGuard.Invalid("active_squad", "squad_build_not_in_template"));
        }
      }
    }

    return issues;
  }

  private static void ValidateCombat(
      ProfileTemplateRevisionContent content,
      ICollection<ProfileValidationIssue> issues)
  {
    if (content.AccountCombatStateRevision.Readiness == ProfileReadiness.Invalid)
    {
      issues.Add(ProfileGuard.Invalid("account_combat_state", "account_combat_state_invalid"));
    }
    else if (content.AccountCombatStateRevision.Readiness == ProfileReadiness.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved("account_combat_state", "account_combat_state_unresolved"));
    }

    if (content.ActiveSquadRevision is null)
    {
      issues.Add(ProfileGuard.Unresolved("active_squad", "active_squad_required_for_combat"));
      return;
    }

    if (content.ActiveSquadRevision.Readiness == ProfileReadiness.Invalid)
    {
      issues.Add(ProfileGuard.Invalid("active_squad", "squad_revision_invalid"));
    }
    else if (content.ActiveSquadRevision.Readiness == ProfileReadiness.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved("active_squad", "squad_revision_unresolved"));
    }
  }

  private static void ValidateCombatSemantics(
      ProfileTemplateRevisionContent content,
      ICollection<ProfileValidationIssue> issues)
  {
    if (content.ActiveSquadRevision is null)
    {
      return;
    }

    if (content.ActiveSquadRevision.CombatSemanticsReadiness == ProfileReadiness.Invalid)
    {
      issues.Add(ProfileGuard.Invalid("active_squad", "squad_combat_semantics_invalid"));
    }
    else if (content.ActiveSquadRevision.CombatSemanticsReadiness == ProfileReadiness.Unresolved)
    {
      issues.Add(ProfileGuard.Unresolved("active_squad", "squad_combat_semantics_unresolved"));
    }
  }
}
