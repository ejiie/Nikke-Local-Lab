using System.Text.Json;
using System.Text.Json.Nodes;
using NikkeLocalLab.Import.CharacterCatalog;
using NikkeLocalLab.Persistence.PostgreSql;
using Npgsql;

internal static partial class CharacterCatalogCli
{
  // Publication is immutable. Only a fully prepared presentation is selected by
  // the caller; a failed attempt never changes account bindings or UI selection.
  private static async Task WriteSynchronizedPresentationAsync(IReadOnlyDictionary<string, string> options,
      CharacterCatalogExtraction extraction, CharacterCatalogImportReceipt receipt, NpgsqlDataSource dataSource)
  {
    var output = options["presentation-output"];
    if (File.Exists(output)) throw new CharacterCatalogSourceException("presentation_output_exists");
    var previous = JsonNode.Parse(await File.ReadAllTextAsync(options["presentation-input"]))!.AsObject();
    if (previous["contractId"]?.GetValue<string>() != "nll/control-center-presentation/v1")
      throw new CharacterCatalogSourceException("presentation_contract_invalid");
    var metadata = JsonNode.Parse(await File.ReadAllTextAsync(options["character-metadata"]))!.AsArray()
        .ToDictionary(row => row!["aliasFingerprint"]!.GetValue<string>(), row => row!);
    var names = receipt.Members.ToDictionary(member => member.CharacterUid.Value,
        member => metadata[extraction.Characters[member.Ordinal].AliasFingerprint.Hex]);
    var rows = new JsonArray();
    await using var connection = await dataSource.OpenConnectionAsync();
    await using var command = new NpgsqlCommand("""
        SELECT entity.character_uid, version.rarity_code, version.combat_class_code,
               version.weapon_code, version.element_code, version.manufacturer_code
        FROM lab_catalog.character_catalog_snapshot catalog
        JOIN lab_catalog.character_catalog_snapshot_member member USING (character_catalog_snapshot_id)
        JOIN lab_catalog.character_entity entity USING (character_entity_id)
        JOIN lab_catalog.character_definition_version version USING (character_definition_version_id)
        WHERE catalog.character_catalog_snapshot_uid = @uid ORDER BY member.ordinal;
        """, connection);
    command.Parameters.AddWithValue("uid", receipt.CharacterCatalogSnapshotUid.Value);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      var uid = reader.GetGuid(0);
      var name = names[uid];
      var displayName = name["displayName"]?.GetValue<string>();
      if (string.IsNullOrWhiteSpace(displayName)) throw new CharacterCatalogSourceException("character_locale_missing");
      rows.Add(new JsonObject
      {
        ["characterUid"] = uid.ToString(),
        ["displayName"] = displayName,
        ["rarityCode"] = Text(1),
        ["combatClassCode"] = Text(2),
        ["weaponCode"] = Text(3),
        ["elementCode"] = Text(4),
        ["manufacturerCode"] = Text(5),
        ["burstStep"] = name["burstStep"]!.GetValue<int>(),
        ["portraitPath"] = $"/editor/assets/characters/{uid}.png"
      });
    }
    string? Text(int index) => reader.IsDBNull(index) ? null : reader.GetString(index);
    var nextUids = rows.Select(row => row!["characterUid"]!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
    if (rows.Count != receipt.Members.Count || previous["characters"]!.AsArray()
        .Any(row => !nextUids.Contains(row!["characterUid"]!.GetValue<string>())))
      throw new CharacterCatalogSourceException("character_catalog_would_remove_members");
    previous["characters"] = rows;
    previous["characterCatalogUid"] = receipt.CharacterCatalogSnapshotUid.ToString();
    await File.WriteAllTextAsync(output, previous.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
  }
}
