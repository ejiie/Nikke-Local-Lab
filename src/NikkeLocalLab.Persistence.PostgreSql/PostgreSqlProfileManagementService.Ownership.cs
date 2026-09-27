using App = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using Npgsql;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlProfileManagementService
{
  private async Task<LocalProfileCatalogBindingWrite> ResolveOwnershipCatalogAsync(
      LocalProfileCatalogBindingWrite previous, IReadOnlyList<App.ProfileEditOperation> operations,
      IReadOnlySet<EntityUid> owned, CancellationToken token)
  {
    var selection = operations.SingleOrDefault(item => item.FieldCode == "character_catalog");
    if (selection is null) return previous;
    selection.Validate();
    if (selection is not { SubjectUid: null, ValueKind: "reference", ReferenceUid: { } uid } ||
        !operations.Any(item => item.FieldCode == "character_owned"))
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_catalog_edit_invalid");
    var source = _workspaceDataSource ?? throw Failure(App.ProfileManagementFailureKind.Unavailable,
        "profile_catalog_resolver_unavailable");
    await using var connection = await source.OpenConnectionAsync(token).ConfigureAwait(false);
    await using var command = new NpgsqlCommand("""
        SELECT dataset.dataset_snapshot_uid, catalog.catalog_manifest_sha256,
          (SELECT count(*) FROM lab_catalog.character_catalog_snapshot_member member
           JOIN lab_catalog.character_entity entity USING (character_entity_id)
           WHERE member.character_catalog_snapshot_id = catalog.character_catalog_snapshot_id
             AND entity.character_uid = ANY(@owned))
        FROM lab_catalog.character_catalog_snapshot catalog
        JOIN lab_import.dataset_snapshot dataset USING (dataset_snapshot_id)
        WHERE catalog.character_catalog_snapshot_uid = @uid;
        """, connection);
    command.Parameters.AddWithValue("uid", uid.Value);
    command.Parameters.AddWithValue("owned", owned.Select(item => item.Value).ToArray());
    await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
    if (!await reader.ReadAsync(token).ConfigureAwait(false) || reader.GetInt64(2) != owned.Count)
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_catalog_members_missing");
    return new(uid, new EntityUid(reader.GetGuid(0)), Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(1)));
  }

  // An explicit user edit: base investment, detached gear, pinned catalog applicability.
  // Existing builds never pass through this initializer.
  private async Task<IReadOnlyList<LocalCharacterBuildWrite>> CreateOwnedCharacterBuildsAsync(
      LocalProfileCatalogBindingWrite binding, IReadOnlyList<App.ProfileEditOperation> operations,
      IReadOnlySet<EntityUid> owned, CancellationToken cancellationToken)
  {
    var requested = new HashSet<EntityUid>();
    foreach (var operation in operations.Where(item => item.FieldCode == "character_owned"))
    {
      operation.Validate();
      if (operation is not { SubjectUid: { } uid, ValueKind: "boolean", BooleanValue: true })
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_ownership_edit_invalid");
      if (!owned.Contains(uid)) requested.Add(uid);
    }
    if (requested.Count == 0) return [];
    var dataSource = _workspaceDataSource ??
        throw Failure(App.ProfileManagementFailureKind.Unavailable, "profile_catalog_resolver_unavailable");
    await using var connection = await dataSource.OpenConnectionAsync(cancellationToken).ConfigureAwait(false);
    await using var command = new NpgsqlCommand("""
        SELECT entity.character_uid, CASE WHEN version.rarity_status = 'ready' THEN version.rarity_code END, cap.capability_code,
               cap.resolution_status, cap.maximum_level, cap.unresolved_reason_code
        FROM lab_catalog.character_catalog_snapshot AS catalog
        JOIN lab_import.dataset_snapshot AS dataset ON dataset.dataset_snapshot_id = catalog.dataset_snapshot_id
        JOIN lab_catalog.character_catalog_snapshot_member AS member
          ON member.character_catalog_snapshot_id = catalog.character_catalog_snapshot_id
        JOIN lab_catalog.character_entity AS entity ON entity.character_entity_id = member.character_entity_id
        JOIN lab_catalog.character_definition_version AS version
          ON version.character_definition_version_id = member.character_definition_version_id
        LEFT JOIN lab_catalog.character_definition_capability AS cap
          ON cap.character_definition_version_id = version.character_definition_version_id
        WHERE catalog.character_catalog_snapshot_uid = @catalog
          AND dataset.dataset_snapshot_uid = @dataset AND catalog.catalog_manifest_sha256 = @manifest
          AND entity.character_uid = ANY(@characters);
        """, connection);
    command.Parameters.AddWithValue("catalog", binding.CatalogSnapshotUid.Value);
    command.Parameters.AddWithValue("dataset", binding.DatasetSnapshotUid.Value);
    command.Parameters.AddWithValue("manifest", binding.CatalogManifestSha256.ToByteArray());
    command.Parameters.AddWithValue("characters", requested.Select(uid => uid.Value).ToArray());
    var characters = new Dictionary<EntityUid, (string? Rarity, Dictionary<string, OwnershipCapability> Caps)>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
    {
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        var uid = new EntityUid(reader.GetGuid(0));
        if (!characters.TryGetValue(uid, out var row))
        {
          row = (reader.IsDBNull(1) ? null : reader.GetString(1), new(StringComparer.Ordinal));
          characters.Add(uid, row);
        }
        if (!reader.IsDBNull(2)) row.Caps.Add(reader.GetString(2), new(reader.GetString(3),
            reader.IsDBNull(4) ? null : reader.GetInt32(4), reader.IsDBNull(5) ? null : reader.GetString(5)));
      }
    }
    if (characters.Count != requested.Count)
      throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_edit_subject_not_found");
    return requested.OrderBy(uid => uid.Value).Select(uid =>
    {
      var row = characters[uid];
      LocalProfileFact<int> Initial(string code, int value, bool allowNotApplicable = false)
      {
        if (!row.Caps.TryGetValue(code, out var cap))
          return LocalProfileFact<int>.Unresolved(new("character_capability_missing"));
        if (allowNotApplicable && (cap.Status == "not_applicable" || code == "bond_level" && row.Rarity == "r"))
          return LocalProfileFact<int>.NotApplicable();
        if (cap.Status == "unresolved")
          return LocalProfileFact<int>.Unresolved(new(cap.Reason ?? "character_capability_unresolved"));
        if (cap.Status != "ready" || cap.Maximum is null || cap.Maximum < value)
          throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_ownership_defaults_invalid");
        return LocalProfileFact<int>.Ready(value);
      }
      if (Initial("character_level", 1).Status != LocalProfileFactStatus.Ready)
        throw Failure(App.ProfileManagementFailureKind.Unprocessable, "profile_ownership_level_unresolved");
      return new LocalCharacterBuildWrite(uid, 1, Initial("limit_break", 0), Initial("core_level", 0, true),
          Initial("bond_level", 1, true), Initial("skill_1", 1), Initial("skill_2", 1), Initial("burst", 1),
          Enum.GetValues<LocalEquipmentSlot>().Select(slot => new LocalEquipmentWrite(slot, LocalEquipmentState.Unequipped,
              manufacturerMatched: LocalProfileFact<bool>.NotApplicable())),
          new LocalCubeSelectionWrite(LocalOptionalSelectionState.Unequipped),
          new LocalCollectionSelectionWrite(LocalCollectionSelectionKind.Detached),
          LocalProfileValidationMode.GameLegal);
    }).ToArray();
  }

  private sealed record OwnershipCapability(string Status, int? Maximum, string? Reason);
}
