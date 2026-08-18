using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Character;

public sealed class CharacterCatalogManifest
{
  public const string ContractId = "nll/character-catalog-output/v1";

  private CharacterCatalogManifest(
      EntityUid datasetSnapshotUid,
      IReadOnlyList<CharacterCatalogManifestEntry> entries,
      string canonicalText,
      Sha256Digest sha256)
  {
    DatasetSnapshotUid = datasetSnapshotUid;
    Entries = entries;
    CanonicalText = canonicalText;
    Sha256 = sha256;
  }

  public EntityUid DatasetSnapshotUid { get; }

  public IReadOnlyList<CharacterCatalogManifestEntry> Entries { get; }

  public int Count => Entries.Count;

  public string CanonicalText { get; }

  public Sha256Digest Sha256 { get; }

  public static CharacterCatalogManifest Create(IEnumerable<CharacterDefinitionVersion> versions)
  {
    ArgumentNullException.ThrowIfNull(versions);
    var items = versions.ToArray();
    if (items.Length == 0)
    {
      throw new ArgumentException("A character catalog manifest cannot be empty.", nameof(versions));
    }

    if (items.Any(static version => version is null))
    {
      throw new ArgumentException("A character catalog manifest cannot contain null versions.", nameof(versions));
    }

    var datasetSnapshotUid = items[0].DatasetSnapshotUid;
    if (items.Any(version => version.DatasetSnapshotUid != datasetSnapshotUid))
    {
      throw new ArgumentException("Every catalog version must belong to the same dataset snapshot.", nameof(versions));
    }

    return Create(
        datasetSnapshotUid,
        items.Select(static version =>
            new CharacterCatalogManifestEntry(version.CharacterUid, version.ContentSha256)));
  }

  public static CharacterCatalogManifest Create(
      EntityUid datasetSnapshotUid,
      IEnumerable<CharacterCatalogManifestEntry> entries)
  {
    CharacterDefinition.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid));
    ArgumentNullException.ThrowIfNull(entries);
    var normalizedEntries = entries.ToArray();
    if (normalizedEntries.Length == 0)
    {
      throw new ArgumentException("A character catalog manifest cannot be empty.", nameof(entries));
    }

    if (normalizedEntries.Any(static entry =>
            entry.CharacterUid.Value == Guid.Empty || entry.ContentSha256 == default) ||
        normalizedEntries.GroupBy(static entry => entry.CharacterUid)
            .Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "A catalog must contain one initialized content digest per character.",
          nameof(entries));
    }

    var orderedEntries = normalizedEntries
        .OrderBy(static entry => entry.CharacterUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    var lines = new List<string>(orderedEntries.Length + 2)
    {
      ContractId,
      $"count={orderedEntries.Length}",
    };
    lines.AddRange(orderedEntries.Select(static entry =>
        $"{entry.CharacterUid}\t{entry.ContentSha256}"));
    var canonicalText = string.Join('\n', lines);

    return new CharacterCatalogManifest(
        datasetSnapshotUid,
        Array.AsReadOnly(orderedEntries),
        canonicalText,
        Sha256Digest.ComputeUtf8(canonicalText));
  }
}

public readonly record struct CharacterCatalogManifestEntry(EntityUid CharacterUid, Sha256Digest ContentSha256);
