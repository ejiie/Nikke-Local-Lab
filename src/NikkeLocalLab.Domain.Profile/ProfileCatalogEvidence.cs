using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Domain.CombatSupport;

namespace NikkeLocalLab.Domain.Profile;

/// <summary>
/// Opaque exact catalog-membership evidence used by in-memory creation paths. Only the trusted
/// catalog repository friend assembly can issue it after checking snapshot UID, definition-version
/// UID, entity UID, dataset, kind, content hash, and manifest association. V1 manifests do not
/// authenticate version UIDs by themselves, so general consumers intentionally have no factory.
/// </summary>
public sealed class ProfileCatalogEvidence
{
  private ProfileCatalogEvidence(
      ProfileDatasetBinding datasetBinding,
      CharacterCatalogManifest characterManifest,
      CombatSupportCatalogManifest combatSupportManifest,
      IReadOnlyList<CharacterDefinitionVersion> characterVersions,
      IReadOnlyList<CombatSupportDefinitionVersion> combatSupportVersions)
  {
    DatasetBinding = datasetBinding;
    CharacterManifest = characterManifest;
    CombatSupportManifest = combatSupportManifest;
    CharacterVersions = characterVersions;
    CombatSupportVersions = combatSupportVersions;
  }

  public ProfileDatasetBinding DatasetBinding { get; }

  public CharacterCatalogManifest CharacterManifest { get; }

  public CombatSupportCatalogManifest CombatSupportManifest { get; }

  private IReadOnlyList<CharacterDefinitionVersion> CharacterVersions { get; }

  private IReadOnlyList<CombatSupportDefinitionVersion> CombatSupportVersions { get; }

  internal static ProfileCatalogEvidence RestoreTrustedCatalogSnapshot(
      ProfileDatasetBinding datasetBinding,
      CharacterCatalogManifest characterManifest,
      IEnumerable<CharacterDefinitionVersion> characterVersions,
      CombatSupportCatalogManifest combatSupportManifest,
      IEnumerable<CombatSupportDefinitionVersion> combatSupportVersions)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    ArgumentNullException.ThrowIfNull(characterManifest);
    ArgumentNullException.ThrowIfNull(characterVersions);
    ArgumentNullException.ThrowIfNull(combatSupportManifest);
    ArgumentNullException.ThrowIfNull(combatSupportVersions);
    if (characterManifest.DatasetSnapshotUid != datasetBinding.CharacterCatalog.DatasetSnapshotUid ||
        characterManifest.Sha256 != datasetBinding.CharacterCatalog.CatalogManifestSha256)
    {
      throw new ArgumentException(
          "The pinned character catalog binding does not match its exact manifest.",
          nameof(characterManifest));
    }

    if (combatSupportManifest.DatasetSnapshotUid !=
            datasetBinding.CombatSupportCatalog.DatasetSnapshotUid ||
        combatSupportManifest.Sha256 != datasetBinding.CombatSupportCatalog.CatalogManifestSha256)
    {
      throw new ArgumentException(
          "The pinned combat-support catalog binding does not match its exact manifest.",
          nameof(combatSupportManifest));
    }

    var characters = characterVersions.ToArray();
    if (characters.Any(static version => version is null) ||
        characters.Length != characterManifest.Entries.Count ||
        characters.GroupBy(static version => version.DefinitionVersionUid)
            .Any(static group => group.Count() != 1) ||
        characters.GroupBy(static version => version.CharacterUid)
            .Any(static group => group.Count() != 1) ||
        characters.Any(version =>
            version.DatasetSnapshotUid != characterManifest.DatasetSnapshotUid ||
            !characterManifest.Entries.Any(entry =>
                entry.CharacterUid == version.CharacterUid &&
                entry.ContentSha256 == version.ContentSha256)))
    {
      throw new ArgumentException(
          "Character version evidence must cover the exact manifest membership once.",
          nameof(characterVersions));
    }

    var support = combatSupportVersions.ToArray();
    if (support.Any(static version => version is null) ||
        support.Length != combatSupportManifest.Entries.Count ||
        support.GroupBy(static version => version.DefinitionVersionUid)
            .Any(static group => group.Count() != 1) ||
        support.GroupBy(static version => version.DefinitionUid)
            .Any(static group => group.Count() != 1) ||
        support.Any(version =>
            version.DatasetSnapshotUid != combatSupportManifest.DatasetSnapshotUid ||
            !combatSupportManifest.Entries.Any(entry =>
                entry.Kind == version.Content.Kind &&
                entry.DefinitionUid == version.DefinitionUid &&
                entry.ContentSha256 == version.ContentSha256)))
    {
      throw new ArgumentException(
          "Combat-support version evidence must cover the exact manifest membership once.",
          nameof(combatSupportVersions));
    }

    return new ProfileCatalogEvidence(
        datasetBinding,
        characterManifest,
        combatSupportManifest,
        Array.AsReadOnly(characters),
        Array.AsReadOnly(support));
  }

  internal void RequireBinding(ProfileDatasetBinding datasetBinding, string parameterName)
  {
    ArgumentNullException.ThrowIfNull(datasetBinding);
    if (!DatasetBinding.Equals(datasetBinding))
    {
      throw new ArgumentException("The profile graph must use the evidenced catalog binding.", parameterName);
    }
  }

  internal void RequireCharacter(
      CharacterDefinitionVersion version,
      string parameterName)
  {
    ArgumentNullException.ThrowIfNull(version);
    if (!CharacterVersions.Any(candidate =>
            candidate.DefinitionVersionUid == version.DefinitionVersionUid &&
            candidate.CharacterUid == version.CharacterUid &&
            candidate.DatasetSnapshotUid == version.DatasetSnapshotUid &&
            candidate.ContentSha256 == version.ContentSha256))
    {
      throw new ArgumentException(
          "The character definition is not an exact member of the evidenced manifest.",
          parameterName);
    }
  }

  internal void RequireCombatSupport(
      CombatSupportDefinitionVersion version,
      string parameterName)
  {
    ArgumentNullException.ThrowIfNull(version);
    if (!CombatSupportVersions.Any(candidate =>
            candidate.DefinitionVersionUid == version.DefinitionVersionUid &&
            candidate.DefinitionUid == version.DefinitionUid &&
            candidate.DatasetSnapshotUid == version.DatasetSnapshotUid &&
            candidate.Content.Kind == version.Content.Kind &&
            candidate.ContentSha256 == version.ContentSha256))
    {
      throw new ArgumentException(
          "The combat-support definition is not an exact member of the evidenced manifest.",
          parameterName);
    }
  }

  internal void RequireCombatSupport(
      IEnumerable<CombatSupportDefinitionVersion> versions,
      string parameterName)
  {
    ArgumentNullException.ThrowIfNull(versions);
    foreach (var version in versions)
    {
      RequireCombatSupport(version, parameterName);
    }
  }
}
