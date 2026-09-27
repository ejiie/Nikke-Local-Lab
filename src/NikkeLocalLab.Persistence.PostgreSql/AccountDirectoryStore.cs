using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using App = NikkeLocalLab.Application.ProfileManagement;
using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record CreateDirectoryAccountCommand(EntityUid OperationUid, DateTimeOffset CreatedAtUtc,
    string DisplayName, string AccountLabel);
public sealed record DirectoryMember(EntityUid AccountUid, string? PortraitPath, string? FramePath, bool Imported);
public sealed record DirectoryUnion(EntityUid UnionUid, int DisplayId, string Name, int Level,
    string? EmblemPath, IReadOnlyList<DirectoryMember> Members);
public sealed record ImportedDirectoryPresentation(string Status, string? Name, int? Level,
    string? Fingerprint, string PortraitPath, string? EmblemPath, string? FramePath = null);

public sealed class AccountDirectoryStore(NpgsqlDataSource source, App.IProfileManagementService profiles)
{
  public async Task ApplyImportedAsync(EntityUid account, ImportedDirectoryPresentation value, CancellationToken token)
  {
    if (value.Status is not ("member" or "none") ||
        value.Status == "member" && (string.IsNullOrWhiteSpace(value.Name) || value.Name.Length > 64 ||
          value.Level is null or < 1 or > 1000000 || value.Fingerprint?.Length != 64 ||
          value.Fingerprint.Any(c => !char.IsAsciiHexDigit(c))))
      throw new App.ProfileManagementException(App.ProfileManagementFailureKind.InvalidRequest, "union_metadata_invalid");
    await using var connection = await source.OpenConnectionAsync(token).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(token).ConfigureAwait(false);
    // A single directory write moves membership and portrait together; equal names never merge identities.
    await using var command = new NpgsqlCommand("""
        LOCK TABLE lab_private_server.local_union IN SHARE ROW EXCLUSIVE MODE;
        SELECT local_account_id FROM lab_profile.local_account WHERE local_account_uid=@account;
        """, connection, transaction);
    command.Parameters.AddWithValue("account", account.Value);
    var accountId = await command.ExecuteScalarAsync(token).ConfigureAwait(false) ??
        throw new App.ProfileManagementException(App.ProfileManagementFailureKind.NotFound, "account_not_found");
    short? unionId = null;
    if (value.Status == "member")
    {
      command.CommandText = """
          INSERT INTO lab_private_server.local_union(local_union_id,display_name,union_level,source_fingerprint,emblem_path,selected_season_number)
          SELECT COALESCE(max(local_union_id),0)+1,@name,@level,@fingerprint,@emblem,
            (SELECT selected_season_number FROM lab_private_server.local_union WHERE local_union_id=1)
          FROM lab_private_server.local_union
          ON CONFLICT(source_fingerprint) DO UPDATE SET display_name=EXCLUDED.display_name,
            union_level=EXCLUDED.union_level,emblem_path=EXCLUDED.emblem_path
          RETURNING local_union_id;
          """;
      command.Parameters.AddWithValue("name", value.Name!);
      command.Parameters.AddWithValue("level", value.Level!.Value);
      command.Parameters.AddWithValue("fingerprint", Convert.FromHexString(value.Fingerprint!));
      command.Parameters.AddWithValue("emblem", (object?)value.EmblemPath ?? DBNull.Value);
      unionId = (short)(await command.ExecuteScalarAsync(token).ConfigureAwait(false))!;
      command.Parameters.AddWithValue("union", unionId.Value);
      command.CommandText = """
          INSERT INTO lab_private_server.local_union_raid_season
            (local_union_id,season_number,normal_cleared,catalog_sha256,publication_root,receipt_sha256,selected_at_utc)
          SELECT @union,season_number,normal_cleared,catalog_sha256,publication_root,receipt_sha256,selected_at_utc
          FROM lab_private_server.local_union_raid_season WHERE local_union_id=1
          ON CONFLICT(local_union_id,season_number) DO NOTHING;
          """;
      await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    }
    command.Parameters.AddWithValue("id", accountId);
    command.CommandText = "DELETE FROM lab_private_server.local_union_member WHERE local_account_id=@id;";
    await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    if (unionId is not null)
    {
      command.CommandText = "INSERT INTO lab_private_server.local_union_member(local_account_id,local_union_id) VALUES(@id,@union);";
      await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    }
    command.Parameters.AddWithValue("portrait", value.PortraitPath);
    command.Parameters.AddWithValue("frame", (object?)value.FramePath ?? DBNull.Value);
    command.CommandText = """
        INSERT INTO lab_profile.account_directory_presentation(local_account_id,portrait_path,frame_path,imported_at_utc)
        VALUES(@id,@portrait,@frame,now()) ON CONFLICT(local_account_id) DO UPDATE
          SET portrait_path=EXCLUDED.portrait_path,
              frame_path=COALESCE(EXCLUDED.frame_path,lab_profile.account_directory_presentation.frame_path),
              imported_at_utc=EXCLUDED.imported_at_utc;
        """;
    await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    await transaction.CommitAsync(token).ConfigureAwait(false);
  }

  public async Task<EntityUid> CreateAsync(CreateDirectoryAccountCommand request, CancellationToken token)
  {
    var name = App.ProfileManagementText.NormalizeDisplayName(request.DisplayName);
    var label = App.ProfileManagementText.NormalizeAccountLabel(request.AccountLabel);
    // Reserve all form values, including nickname, before the profile store's resumable creation.
    var requestHash = System.Security.Cryptography.SHA256.HashData(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(
        new { request.CreatedAtUtc, DisplayName = name, AccountLabel = label }));
    await using (var reserve = source.CreateCommand("""
        INSERT INTO lab_profile.account_directory_creation VALUES(@operation,@hash) ON CONFLICT DO NOTHING;
        SELECT request_sha256 FROM lab_profile.account_directory_creation WHERE operation_uid=@operation;
        """))
    {
      reserve.Parameters.AddWithValue("operation", request.OperationUid.Value);
      reserve.Parameters.AddWithValue("hash", requestHash);
      if (await reserve.ExecuteScalarAsync(token).ConfigureAwait(false) is not byte[] stored || !stored.SequenceEqual(requestHash))
        throw new App.ProfileManagementException(App.ProfileManagementFailureKind.InvalidRequest, "account_creation_operation_reuse");
    }
    var character = await ReadCatalogAsync(true, token).ConfigureAwait(false);
    var support = await ReadCatalogAsync(false, token).ConfigureAwait(false);
    var consoles = new List<LocalConsoleStateWrite>();
    await using (var command = source.CreateCommand("""
        SELECT e.definition_uid,d.coordinate_code
        FROM lab_combat_support.catalog_snapshot c
        JOIN lab_combat_support.catalog_snapshot_member m USING(catalog_snapshot_id)
        JOIN lab_combat_support.definition_entity e USING(definition_entity_id)
        JOIN lab_combat_support.console_definition_detail d USING(definition_version_id)
        WHERE c.catalog_snapshot_uid=@uid ORDER BY d.coordinate_code;
        """))
    {
      command.Parameters.AddWithValue("uid", support.CatalogSnapshotUid.Value);
      await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
      while (await reader.ReadAsync(token).ConfigureAwait(false))
        consoles.Add(new(Enum.Parse<LocalConsoleCoordinate>(reader.GetString(1), true),
            new(reader.GetGuid(0)), LocalProfileFact<int>.Ready(0), LocalProfileFact<long>.Ready(0)));
    }
    var profile = new LocalAccountProfileWrite(character, support,
        new(LocalProfileFact<int>.Ready(1), consoles, LocalProfileValidationMode.GameLegal), []);
    var store = new PostgreSqlLocalAccountProfileStore(source, new RandomEntityUidGenerator());
    var created = await store.CreateAsync(new(request.OperationUid, profile,
        request.CreatedAtUtc, label), token).ConfigureAwait(false);
    if (await profiles.GetLobbyPresentationAsync(created.AccountUid, token).ConfigureAwait(false) is null)
    {
      var manifest = await profiles.GetFeatureManifestAsync(token).ConfigureAwait(false);
      await profiles.InitializeLocalStateAsync(new(request.OperationUid, created.AccountUid,
          created.ProfileTemplateRevisionUid, manifest.ManifestUid, manifest.ContentSha256, name, 1,
          null, null, null, null, [new("jewel", 0), new("credit", 0)]), token).ConfigureAwait(false);
    }
    return created.AccountUid;
  }

  private async Task<LocalProfileCatalogBindingWrite> ReadCatalogAsync(bool character, CancellationToken token)
  {
    var query = character ? """
        SELECT c.character_catalog_snapshot_uid,d.dataset_snapshot_uid,c.catalog_manifest_sha256
        FROM lab_catalog.character_catalog_snapshot c JOIN lab_import.dataset_snapshot d USING(dataset_snapshot_id)
        ORDER BY c.created_at_utc DESC,c.character_catalog_snapshot_id DESC LIMIT 1;
        """ : """
        SELECT c.catalog_snapshot_uid,d.dataset_snapshot_uid,c.catalog_manifest_sha256
        FROM lab_combat_support.catalog_snapshot c JOIN lab_import.dataset_snapshot d USING(dataset_snapshot_id)
        ORDER BY c.created_at_utc DESC,c.catalog_snapshot_id DESC LIMIT 1;
        """;
    await using var command = source.CreateCommand(query);
    await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
    if (!await reader.ReadAsync(token).ConfigureAwait(false))
      throw new App.ProfileManagementException(App.ProfileManagementFailureKind.Unavailable, "account_catalog_missing");
    return new(new(reader.GetGuid(0)), new(reader.GetGuid(1)), Sha256Digest.FromBytes(reader.GetFieldValue<byte[]>(2)));
  }

  public async Task<IReadOnlyList<DirectoryUnion>> ListAsync(CancellationToken token)
  {
    await using var command = source.CreateCommand("""
        SELECT COALESCE(u.union_uid,'00000000-0000-4000-8000-000000000001'::uuid),
               COALESCE(u.local_union_id,0)::smallint,COALESCE(u.display_name,'소속 없음'),COALESCE(u.union_level,0),u.emblem_path,
               a.local_account_uid,p.portrait_path,p.frame_path,p.imported_at_utc IS NOT NULL
        FROM lab_profile.local_account a
        LEFT JOIN lab_private_server.local_union_member m USING(local_account_id)
        LEFT JOIN lab_private_server.local_union u USING(local_union_id)
        LEFT JOIN lab_profile.account_directory_presentation p USING(local_account_id)
        ORDER BY u.local_union_id,a.created_at_utc,a.local_account_id;
        """);
    var groups = new Dictionary<EntityUid, DirectoryUnion>();
    await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
    while (await reader.ReadAsync(token).ConfigureAwait(false))
    {
      var uid = new EntityUid(reader.GetGuid(0));
      if (!groups.TryGetValue(uid, out var group))
      {
        group = new(uid, reader.GetInt16(1), reader.GetString(2), reader.GetInt32(3),
            reader.IsDBNull(4) ? null : reader.GetString(4), new List<DirectoryMember>());
        groups.Add(uid, group);
      }
      ((List<DirectoryMember>)group.Members).Add(new(new(reader.GetGuid(5)),
          reader.IsDBNull(6) ? null : reader.GetString(6), reader.IsDBNull(7) ? null : reader.GetString(7),
          reader.GetBoolean(8)));
    }
    return groups.Values.ToArray();
  }
}
