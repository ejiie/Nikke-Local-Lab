using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class Squad
{
  public Squad(EntityUid squadUid, LocalAccount account)
  {
    ArgumentNullException.ThrowIfNull(account);
    SquadUid = ProfileGuard.RequireUid(squadUid, nameof(squadUid));
    LocalAccountUid = account.LocalAccountUid;
  }

  public EntityUid SquadUid { get; }

  public EntityUid LocalAccountUid { get; }
}

public sealed class SquadMemberReference
{
  internal SquadMemberReference(int slotIndex, CharacterBuildRevisionReference buildRevision)
  {
    if (slotIndex is < 1 or > 5)
    {
      throw new ArgumentOutOfRangeException(nameof(slotIndex));
    }

    SlotIndex = slotIndex;
    BuildRevision = buildRevision ?? throw new ArgumentNullException(nameof(buildRevision));
  }

  public int SlotIndex { get; }

  public CharacterBuildRevisionReference BuildRevision { get; }
}

public sealed class SquadRevisionContent
{
  internal SquadRevisionContent(
      ProfileDatasetBinding datasetBinding,
      IReadOnlyList<SquadMemberReference> members)
  {
    DatasetBinding = datasetBinding;
    Members = members;
  }

  public ProfileDatasetBinding DatasetBinding { get; }

  public IReadOnlyList<SquadMemberReference> Members { get; }
}

public sealed class SquadValidation
{
  internal SquadValidation(
      ProfileValidationResult selection,
      ProfileValidationResult combatSemantics)
  {
    Selection = selection ?? throw new ArgumentNullException(nameof(selection));
    CombatSemantics = combatSemantics ?? throw new ArgumentNullException(nameof(combatSemantics));
  }

  public ProfileValidationResult Selection { get; }

  public ProfileValidationResult CombatSemantics { get; }
}

public sealed class SquadRevision
{
  private SquadRevision(
      EntityUid squadRevisionUid,
      EntityUid squadUid,
      EntityUid localAccountUid,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      SquadRevisionContent content,
      SquadValidation validation)
  {
    SquadRevisionUid = squadRevisionUid;
    SquadUid = squadUid;
    LocalAccountUid = localAccountUid;
    RevisionNumber = revisionNumber;
    Provenance = provenance;
    Content = content;
    Validation = validation;
    ContentSha256 = ProfileCanonicalizer.ComputeContentHash(content);
  }

  public EntityUid SquadRevisionUid { get; }

  public EntityUid SquadUid { get; }

  public EntityUid LocalAccountUid { get; }

  public long RevisionNumber { get; }

  public ProfileRevisionProvenance Provenance { get; }

  public SquadRevisionContent Content { get; }

  public SquadValidation Validation { get; }

  public ProfileReadiness Readiness => Validation.Selection.Status;

  public ProfileReadiness CombatSemanticsReadiness => Validation.CombatSemantics.Status;

  public Sha256Digest ContentSha256 { get; }

  public static SquadRevision Create(
      EntityUid squadRevisionUid,
      Squad squad,
      long revisionNumber,
      ProfileRevisionProvenance provenance,
      ProfileCatalogEvidence catalogEvidence,
      IEnumerable<CharacterBuildRevision> orderedBuildRevisions)
  {
    ArgumentNullException.ThrowIfNull(squad);
    ArgumentNullException.ThrowIfNull(catalogEvidence);
    ArgumentNullException.ThrowIfNull(orderedBuildRevisions);
    ProfileGuard.RequireRevision(revisionNumber, provenance);
    var revisions = orderedBuildRevisions.ToArray();
    if (revisions.Any(static revision => revision is null) || revisions.Length != 5)
    {
      throw new ArgumentException("A squad revision must contain exactly five ordered build revisions.", nameof(orderedBuildRevisions));
    }

    if (revisions.GroupBy(static revision => revision.CharacterUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("A squad cannot contain the same character more than once.", nameof(orderedBuildRevisions));
    }

    if (revisions.GroupBy(static revision => revision.CharacterBuildRevisionUid)
        .Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("A squad must reference five distinct build revisions.", nameof(orderedBuildRevisions));
    }

    var members = revisions.Select((revision, index) =>
        new SquadMemberReference(index + 1, revision.ToReference())).ToArray();
    var datasetBinding = catalogEvidence.DatasetBinding;
    var content = new SquadRevisionContent(datasetBinding, Array.AsReadOnly(members));
    var selectionIssues = new List<ProfileValidationIssue>();
    foreach (var revision in revisions)
    {
      var field = $"squad_slot_{Array.IndexOf(revisions, revision) + 1}";
      if (revision.LocalAccountUid != squad.LocalAccountUid)
      {
        selectionIssues.Add(ProfileGuard.Invalid(field, "local_account_mismatch"));
      }

      if (!revision.Content.DatasetBinding.Equals(datasetBinding))
      {
        selectionIssues.Add(ProfileGuard.Invalid(field, "catalog_binding_mismatch"));
      }

      if (revision.Readiness == ProfileReadiness.Invalid)
      {
        selectionIssues.Add(ProfileGuard.Invalid(field, "build_revision_invalid"));
      }
      else if (revision.Readiness == ProfileReadiness.Unresolved)
      {
        selectionIssues.Add(ProfileGuard.Unresolved(field, "build_revision_unresolved"));
      }
    }

    var combatSemanticsIssues = new List<ProfileValidationIssue>(selectionIssues);
    foreach (var revision in revisions)
    {
      var field = $"squad_slot_{Array.IndexOf(revisions, revision) + 1}_combat_semantics";
      if (revision.CombatSemanticsReadiness == ProfileReadiness.Invalid)
      {
        combatSemanticsIssues.Add(ProfileGuard.Invalid(field, "build_combat_semantics_invalid"));
      }
      else if (revision.CombatSemanticsReadiness == ProfileReadiness.Unresolved)
      {
        combatSemanticsIssues.Add(ProfileGuard.Unresolved(field, "build_combat_semantics_unresolved"));
      }
    }

    return new SquadRevision(
        ProfileGuard.RequireUid(squadRevisionUid, nameof(squadRevisionUid)),
        squad.SquadUid,
        squad.LocalAccountUid,
        revisionNumber,
        provenance,
        content,
        new SquadValidation(
            new ProfileValidationResult(selectionIssues),
            new ProfileValidationResult(combatSemanticsIssues)));
  }

  public SquadRevisionReference ToReference() =>
      SquadRevisionReference.Restore(
          SquadUid,
          SquadRevisionUid,
          LocalAccountUid,
          Content.DatasetBinding,
          Content.Members.Select(static member => member.BuildRevision),
          ContentSha256,
          Readiness,
          CombatSemanticsReadiness);
}

public sealed class SquadRevisionReference
{
  private SquadRevisionReference(
      EntityUid squadUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      ProfileDatasetBinding datasetBinding,
      IReadOnlyList<CharacterBuildRevisionReference> members,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness combatSemanticsReadiness)
  {
    SquadUid = squadUid;
    RevisionUid = revisionUid;
    LocalAccountUid = localAccountUid;
    DatasetBinding = datasetBinding;
    Members = Array.AsReadOnly(members.ToArray());
    ContentSha256 = contentSha256;
    Readiness = readiness;
    CombatSemanticsReadiness = combatSemanticsReadiness;
  }

  public EntityUid SquadUid { get; }

  public EntityUid RevisionUid { get; }

  public EntityUid LocalAccountUid { get; }

  public ProfileDatasetBinding DatasetBinding { get; }

  public IReadOnlyList<CharacterBuildRevisionReference> Members { get; }

  public Sha256Digest ContentSha256 { get; }

  public ProfileReadiness Readiness { get; }

  public ProfileReadiness CombatSemanticsReadiness { get; }

  internal static SquadRevisionReference Restore(
      EntityUid squadUid,
      EntityUid revisionUid,
      EntityUid localAccountUid,
      ProfileDatasetBinding datasetBinding,
      IEnumerable<CharacterBuildRevisionReference> orderedMembers,
      Sha256Digest contentSha256,
      ProfileReadiness readiness,
      ProfileReadiness combatSemanticsReadiness)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(orderedMembers);
    var members = orderedMembers.ToArray();
    if (members.Any(static member => member is null) || members.Length != 5)
    {
      throw new ArgumentException(
          "A restored squad reference must contain exactly five ordered build references.",
          nameof(orderedMembers));
    }

    if (members.Any(member =>
            member.LocalAccountUid != localAccountUid ||
            !member.DatasetBinding.Equals(datasetBinding)) ||
        members.GroupBy(static member => member.CharacterUid).Any(static group => group.Count() != 1) ||
        members.GroupBy(static member => member.CharacterBuildUid).Any(static group => group.Count() != 1) ||
        members.GroupBy(static member => member.RevisionUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "A restored squad reference must retain one account, one binding, and five distinct characters/build revisions.",
          nameof(orderedMembers));
    }

    return new SquadRevisionReference(
        ProfileGuard.RequireUid(squadUid, nameof(squadUid)),
        ProfileGuard.RequireUid(revisionUid, nameof(revisionUid)),
        ProfileGuard.RequireUid(localAccountUid, nameof(localAccountUid)),
        datasetBinding,
        Array.AsReadOnly(members),
        ProfileGuard.RequireDigest(contentSha256, nameof(contentSha256)),
        ProfileGuard.RequireEnum(readiness, nameof(readiness)),
        ProfileGuard.RequireEnum(combatSemanticsReadiness, nameof(combatSemanticsReadiness)));
  }
}
