using Npgsql;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed record LocalUnionSelection(string Name, int Level, int SeasonNumber, bool NormalCleared,
    string CatalogSha256, string PublicationRoot, string ReceiptSha256);

public static class LocalUnionStore
{
  public static async Task SelectAsync(NpgsqlDataSource source, int season, string catalogSha256,
      string publicationRoot, string receiptSha256, CancellationToken token = default)
  {
    if (season is < 1 or > 999 || !Path.IsPathFullyQualified(publicationRoot) ||
        Convert.FromHexString(catalogSha256).Length != 32 || Convert.FromHexString(receiptSha256).Length != 32)
      throw new ArgumentException("local_union_selection_invalid");
    await using var connection = await source.OpenConnectionAsync(token).ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(token).ConfigureAwait(false);
    await using var command = new NpgsqlCommand("""
        SELECT local_union_id FROM lab_private_server.local_union ORDER BY local_union_id FOR UPDATE;
        INSERT INTO lab_private_server.local_union_raid_season
          (local_union_id,season_number,normal_cleared,catalog_sha256,publication_root,receipt_sha256,selected_at_utc)
        SELECT local_union_id,@season,TRUE,@catalog,@root,@receipt,now() FROM lab_private_server.local_union
        ON CONFLICT (local_union_id,season_number) DO UPDATE SET
          catalog_sha256=EXCLUDED.catalog_sha256, publication_root=EXCLUDED.publication_root,
          receipt_sha256=EXCLUDED.receipt_sha256, selected_at_utc=EXCLUDED.selected_at_utc;
        UPDATE lab_private_server.local_union SET selected_season_number=@season;
        """, connection, transaction);
    command.Parameters.AddWithValue("season", season);
    command.Parameters.AddWithValue("catalog", Convert.FromHexString(catalogSha256));
    command.Parameters.AddWithValue("root", publicationRoot);
    command.Parameters.AddWithValue("receipt", Convert.FromHexString(receiptSha256));
    await command.ExecuteNonQueryAsync(token).ConfigureAwait(false);
    await transaction.CommitAsync(token).ConfigureAwait(false);
  }

  public static async Task<LocalUnionSelection?> ReadAsync(NpgsqlDataSource source, Guid accountUid, CancellationToken token = default)
  {
    await using var command = source.CreateCommand("""
        SELECT u.display_name,u.union_level,s.season_number,s.normal_cleared,
               s.catalog_sha256,s.publication_root,s.receipt_sha256
          FROM lab_private_server.local_union_member m
          JOIN lab_profile.local_account a USING (local_account_id)
          JOIN lab_private_server.local_union u USING (local_union_id)
          LEFT JOIN lab_private_server.local_union_raid_season s
            ON s.local_union_id=u.local_union_id AND s.season_number=u.selected_season_number
         WHERE a.local_account_uid=@account;
        """);
    command.Parameters.AddWithValue("account", accountUid);
    await using var reader = await command.ExecuteReaderAsync(token).ConfigureAwait(false);
    if (!await reader.ReadAsync(token).ConfigureAwait(false)) return null;
    if (reader.IsDBNull(2)) return new(reader.GetString(0), reader.GetInt32(1), 0, false, "", "", "");
    return new(reader.GetString(0), reader.GetInt32(1), reader.GetInt32(2), reader.GetBoolean(3),
        Convert.ToHexString(reader.GetFieldValue<byte[]>(4)).ToLowerInvariant(), reader.GetString(5),
        Convert.ToHexString(reader.GetFieldValue<byte[]>(6)).ToLowerInvariant());
  }
}
