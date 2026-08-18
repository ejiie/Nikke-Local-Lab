using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Character;

public sealed class CharacterDefinition
{
  public CharacterDefinition(EntityUid characterUid)
  {
    CharacterUid = RequireUid(characterUid, nameof(characterUid));
  }

  public EntityUid CharacterUid { get; }

  internal static EntityUid RequireUid(EntityUid value, string parameterName)
  {
    if (value.Value == Guid.Empty)
    {
      throw new ArgumentException("A domain UID cannot be empty.", parameterName);
    }

    return value;
  }
}

public sealed class CharacterDefinitionContent
{
  public CharacterDefinitionContent(CharacterProfile profile, CharacterCapabilities capabilities)
  {
    Profile = profile ?? throw new ArgumentNullException(nameof(profile));
    Capabilities = capabilities ?? throw new ArgumentNullException(nameof(capabilities));
  }

  public CharacterProfile Profile { get; }

  public CharacterCapabilities Capabilities { get; }
}

public sealed class CharacterDefinitionVersion
{
  private CharacterDefinitionVersion(
      EntityUid definitionVersionUid,
      EntityUid characterUid,
      EntityUid datasetSnapshotUid,
      CharacterDefinitionContent content,
      Sha256Digest contentSha256)
  {
    DefinitionVersionUid = definitionVersionUid;
    CharacterUid = characterUid;
    DatasetSnapshotUid = datasetSnapshotUid;
    Content = content;
    ContentSha256 = contentSha256;
  }

  public EntityUid DefinitionVersionUid { get; }

  public EntityUid CharacterUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public CharacterDefinitionContent Content { get; }

  public Sha256Digest ContentSha256 { get; }

  public static CharacterDefinitionVersion Create(
      EntityUid definitionVersionUid,
      CharacterDefinition definition,
      EntityUid datasetSnapshotUid,
      CharacterDefinitionContent content)
  {
    ArgumentNullException.ThrowIfNull(definition);
    ArgumentNullException.ThrowIfNull(content);

    return new CharacterDefinitionVersion(
        CharacterDefinition.RequireUid(definitionVersionUid, nameof(definitionVersionUid)),
        definition.CharacterUid,
        CharacterDefinition.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid)),
        content,
        CharacterDefinitionCanonicalizer.ComputeContentHash(content));
  }
}
