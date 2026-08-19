using NikkeLocalLab.Domain.Character;
using NikkeLocalLab.Domain.CombatSupport;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Profile;

public sealed class CharacterDefinitionReference
{
  private CharacterDefinitionReference(
      EntityUid characterUid,
      EntityUid definitionVersionUid,
      EntityUid datasetSnapshotUid,
      Sha256Digest contentSha256)
  {
    CharacterUid = characterUid;
    DefinitionVersionUid = definitionVersionUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    ContentSha256 = contentSha256;
  }

  public EntityUid CharacterUid { get; }

  public EntityUid DefinitionVersionUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public Sha256Digest ContentSha256 { get; }

  public static CharacterDefinitionReference From(CharacterDefinitionVersion version)
  {
    ArgumentNullException.ThrowIfNull(version);
    return Restore(
        version.CharacterUid,
        version.DefinitionVersionUid,
        version.DatasetSnapshotUid,
        version.ContentSha256);
  }

  internal static CharacterDefinitionReference Restore(
      EntityUid characterUid,
      EntityUid definitionVersionUid,
      EntityUid datasetSnapshotUid,
      Sha256Digest contentSha256) =>
      new(
          ProfileGuard.RequireUid(characterUid, nameof(characterUid)),
          ProfileGuard.RequireUid(definitionVersionUid, nameof(definitionVersionUid)),
          ProfileGuard.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid)),
          ProfileGuard.RequireDigest(contentSha256, nameof(contentSha256)));

  internal bool Matches(CharacterDefinitionVersion version) =>
      version.CharacterUid == CharacterUid &&
      version.DefinitionVersionUid == DefinitionVersionUid &&
      version.DatasetSnapshotUid == DatasetSnapshotUid &&
      version.ContentSha256 == ContentSha256;
}

public sealed class CombatSupportDefinitionReference
{
  private CombatSupportDefinitionReference(
      EntityUid definitionUid,
      EntityUid definitionVersionUid,
      EntityUid datasetSnapshotUid,
      CombatSupportDefinitionKind kind,
      Sha256Digest contentSha256)
  {
    DefinitionUid = definitionUid;
    DefinitionVersionUid = definitionVersionUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    Kind = kind;
    ContentSha256 = contentSha256;
  }

  public EntityUid DefinitionUid { get; }

  public EntityUid DefinitionVersionUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public CombatSupportDefinitionKind Kind { get; }

  public Sha256Digest ContentSha256 { get; }

  public static CombatSupportDefinitionReference From(CombatSupportDefinitionVersion version)
  {
    ArgumentNullException.ThrowIfNull(version);
    return Restore(
        version.DefinitionUid,
        version.DefinitionVersionUid,
        version.DatasetSnapshotUid,
        version.Content.Kind,
        version.ContentSha256);
  }

  internal static CombatSupportDefinitionReference Restore(
      EntityUid definitionUid,
      EntityUid definitionVersionUid,
      EntityUid datasetSnapshotUid,
      CombatSupportDefinitionKind kind,
      Sha256Digest contentSha256) =>
      new(
          ProfileGuard.RequireUid(definitionUid, nameof(definitionUid)),
          ProfileGuard.RequireUid(definitionVersionUid, nameof(definitionVersionUid)),
          ProfileGuard.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid)),
          ProfileGuard.RequireEnum(kind, nameof(kind)),
          ProfileGuard.RequireDigest(contentSha256, nameof(contentSha256)));

  internal bool Matches(CombatSupportDefinitionVersion version) =>
      version.DefinitionUid == DefinitionUid &&
      version.DefinitionVersionUid == DefinitionVersionUid &&
      version.DatasetSnapshotUid == DatasetSnapshotUid &&
      version.Content.Kind == Kind &&
      version.ContentSha256 == ContentSha256;
}
