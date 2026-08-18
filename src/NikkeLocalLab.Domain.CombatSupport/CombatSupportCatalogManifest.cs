using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.CombatSupport;

public sealed class CombatSupportCatalogManifest
{
  public const string ContractId = "nll/combat-support-catalog-output/v1";

  private CombatSupportCatalogManifest(
      EntityUid datasetSnapshotUid,
      IReadOnlyList<CombatSupportCatalogManifestEntry> entries,
      string canonicalText,
      Sha256Digest sha256)
  {
    DatasetSnapshotUid = datasetSnapshotUid;
    Entries = entries;
    CanonicalText = canonicalText;
    Sha256 = sha256;
  }

  public EntityUid DatasetSnapshotUid { get; }

  public IReadOnlyList<CombatSupportCatalogManifestEntry> Entries { get; }

  public int Count => Entries.Count;

  public string CanonicalText { get; }

  public Sha256Digest Sha256 { get; }

  public static CombatSupportCatalogManifest Create(
      IEnumerable<CombatSupportDefinitionVersion> versions)
  {
    ArgumentNullException.ThrowIfNull(versions);
    var normalized = versions.ToArray();
    if (normalized.Length == 0 || normalized.Any(static item => item is null))
    {
      throw new ArgumentException("A combat-support catalog cannot be empty or contain null versions.", nameof(versions));
    }

    var datasetSnapshotUid = normalized[0].DatasetSnapshotUid;
    if (normalized.Any(item => item.DatasetSnapshotUid != datasetSnapshotUid))
    {
      throw new ArgumentException("Every definition version must belong to one dataset snapshot.", nameof(versions));
    }

    var entries = normalized.Select(static item => new CombatSupportCatalogManifestEntry(
        item.Content.Kind,
        item.DefinitionUid,
        item.ContentSha256,
        item.Content.IsProfileSelectable,
        item.Content.HasCompleteCombatSemantics));
    return Create(datasetSnapshotUid, entries);
  }

  public static CombatSupportCatalogManifest Create(
      EntityUid datasetSnapshotUid,
      IEnumerable<CombatSupportCatalogManifestEntry> entries)
  {
    CombatSupportDefinition.RequireUid(datasetSnapshotUid, nameof(datasetSnapshotUid));
    ArgumentNullException.ThrowIfNull(entries);
    var normalized = entries
        .OrderBy(static item => CombatSupportCanonicalCodes.DefinitionKind(item.Kind), StringComparer.Ordinal)
        .ThenBy(static item => item.DefinitionUid.ToString(), StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length == 0 ||
        normalized.Any(static item =>
            item.DefinitionUid.Value == Guid.Empty || item.ContentSha256 == default) ||
        normalized.GroupBy(static item => item.DefinitionUid).Any(static group => group.Count() != 1) ||
        Enum.GetValues<CombatSupportDefinitionKind>()
            .Any(kind => normalized.All(item => item.Kind != kind)))
    {
      throw new ArgumentException(
          "A combat-support catalog requires unique initialized entries for every definition kind.",
          nameof(entries));
    }

    var lines = new List<string>(normalized.Length + 2)
    {
      ContractId,
      $"count={normalized.Length}"
    };
    lines.AddRange(normalized.Select(static item =>
        $"{CombatSupportCanonicalCodes.DefinitionKind(item.Kind)}\t{item.DefinitionUid}\t{item.ContentSha256}\t{Ready(item.IsProfileSelectable)}\t{Ready(item.HasCompleteCombatSemantics)}"));
    var canonicalText = string.Join('\n', lines);
    return new CombatSupportCatalogManifest(
        datasetSnapshotUid,
        Array.AsReadOnly(normalized),
        canonicalText,
        Sha256Digest.ComputeUtf8(canonicalText));
  }

  private static string Ready(bool value) => value ? "ready" : "unresolved";
}

public readonly record struct CombatSupportCatalogManifestEntry(
    CombatSupportDefinitionKind Kind,
    EntityUid DefinitionUid,
    Sha256Digest ContentSha256,
    bool IsProfileSelectable,
    bool HasCompleteCombatSemantics);
