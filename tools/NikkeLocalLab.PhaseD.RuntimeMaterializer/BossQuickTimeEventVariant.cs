using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using EpinelPS.Data;
using MemoryPack;

// Build-local data only. Never return original row/monster identifiers in receipts.
internal static class BossQuickTimeEventVariant
{
  internal static QuickTimeEventRecord[] Select(
      QuickTimeEventRecord[] rows, long targetMonsterId) => rows
      .Where(row => (row.MonsterId ?? []).Any(id => id == targetMonsterId))
      .OrderBy(row => row.Id).ToArray();

  internal static string HashRecords(IEnumerable<QuickTimeEventRecord> rows)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    foreach (var row in rows.OrderBy(row => row.Id))
    {
      var bytes = MemoryPackSerializer.Serialize(row);
      try { hash.AppendData(bytes); }
      finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    return Convert.ToHexStringLower(hash.GetHashAndReset());
  }

  internal static string HashImmutable(IEnumerable<QuickTimeEventRecord> rows) =>
      HashStrings(rows.OrderBy(row => row.Id).Select(row => string.Join('\t',
          row.Id.ToString(CultureInfo.InvariantCulture), string.Join(',', row.MonsterId ?? []),
          row.QtePrefab ?? string.Empty, string.Join(',', row.GroupId ?? []),
          row.RandomPreset ? "true" : "false", row.TimeLimit.ToString(CultureInfo.InvariantCulture),
          row.FirstColAnimTime.ToString(CultureInfo.InvariantCulture))));

  internal static string HashElements(IEnumerable<QuickTimeEventRecord> rows) =>
      HashStrings(rows.Select(row => row.ElementId.ToString(CultureInfo.InvariantCulture))
          .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal));

  private static string HashStrings(IEnumerable<string> values) =>
      Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join("\n", values))));

  internal static void ValidateSource(QuickTimeEventRecord[] rows, long targetMonsterId,
      BossRuntimeVariantQuickTimeEventAffinity? contract, int sourceElementId, bool variantRequired)
  {
    Require(rows.Select(row => row.Id).Distinct().Count() == rows.Length, "index_invalid");
    var selected = Select(rows, targetMonsterId);
    if (contract is null)
    {
      // Older profiles must not silently leave an elemental QTE unchanged.
      Require(!variantRequired || !selected.Any(row => row.ElementId != 0), "contract_required");
      return;
    }
    Require(contract.ModeCode == "target_monster_linked_element_only" &&
        selected.Length > 0 && selected.Length == contract.RecordCount &&
        selected.SelectMany(row => row.MonsterId ?? []).Distinct().Count() == contract.MonsterReferenceCount &&
        HashRecords(selected) == contract.RecordSetSha256 &&
        HashImmutable(selected) == contract.ImmutablePayloadSetSha256 &&
        HashElements(selected) == contract.SourceElementSetSha256 &&
        selected.All(row => row.ElementId == sourceElementId), "source_mismatch");
  }

  internal static int Apply(QuickTimeEventRecord[] rows, long targetMonsterId,
      BossRuntimeVariantQuickTimeEventAffinity? contract, int sourceElementId, int targetElementId)
  {
    ValidateSource(rows, targetMonsterId, contract, sourceElementId, sourceElementId != targetElementId);
    if (contract is null || sourceElementId == targetElementId) return 0;
    Require(targetElementId > 0, "target_invalid");
    var selected = Select(rows, targetMonsterId);
    foreach (var row in selected) row.ElementId = targetElementId;
    Require(HashImmutable(selected) == contract.ImmutablePayloadSetSha256, "immutable_payload_changed");
    return selected.Length;
  }

  internal static void VerifyBoundary(QuickTimeEventRecord[] before, QuickTimeEventRecord[] after,
      long targetMonsterId, int targetElementId, int expectedModifiedCount)
  {
    Require(before.Length == after.Length && before.Select(row => row.Id).SequenceEqual(after.Select(row => row.Id)),
        "table_boundary_invalid");
    var selectedIds = Select(before, targetMonsterId).Select(row => row.Id).ToHashSet();
    var modified = 0;
    for (var i = 0; i < before.Length; i++)
    {
      var source = before[i];
      var result = after[i];
      if (source.ElementId != result.ElementId)
      {
        Require(selectedIds.Contains(source.Id) && result.ElementId == targetElementId, "foreign_row_changed");
        modified++;
      }
      // Check every serialized field, not only fields listed in the older discovery digest.
      var resultElement = result.ElementId;
      try
      {
        result.ElementId = source.ElementId;
        Require(HashRecords([source]) == HashRecords([result]), "immutable_payload_changed");
      }
      finally { result.ElementId = resultElement; }
    }
    Require(modified == expectedModifiedCount, "modified_count_invalid");
  }

  private static void Require(bool value, string code)
  {
    if (!value) throw new InvalidOperationException("phase_d_qte_" + code);
  }
}
