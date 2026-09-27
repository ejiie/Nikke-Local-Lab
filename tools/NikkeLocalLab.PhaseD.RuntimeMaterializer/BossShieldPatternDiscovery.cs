using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using EpinelPS.Data;

// Static provenance, not a claim about client damage evaluation or rendering.
internal static class BossShieldPatternDiscovery
{
  internal static JsonElement Describe(MonsterRecord monster,
      IReadOnlyList<MonsterPartsRecord> parts,
      IReadOnlyDictionary<int, MonsterSkillRecord> skills,
      IReadOnlyDictionary<int, StateEffectRecord> states,
      IReadOnlyDictionary<int, FunctionRecord> functions,
      IReadOnlyList<QuickTimeEventRecord> qtes,
      IReadOnlyDictionary<int, ElementRecord> elements)
  {
    var paths = new List<object>();
    var interrupts = new List<object>();
    var selected = new HashSet<int>();
    var missing = new HashSet<string>(StringComparer.Ordinal);
    void Visit(string owner, string entry, IEnumerable<int> roots, int passiveId = 0)
    {
      if (passiveId != 0)
      {
        if (!states.TryGetValue(passiveId, out var state))
        {
          missing.Add("state:" + Key(passiveId));
          paths.Add(new { ownerCode = owner, entryCode = entry,
            referenceStatusCode = "unresolved", shieldFunctionKeys = Array.Empty<string>() });
          return;
        }
        roots = (state.UseFunctionIdList ?? []).Concat(state.HurtFunctionIdList ?? [])
            .Concat((state.Functions ?? []).Select(row => row.Function));
      }
      var visited = new HashSet<int>();
      var queue = new Queue<int>(roots.Where(id => id != 0));
      var found = new List<string>();
      var unresolved = false;
      while (queue.TryDequeue(out var id))
      {
        if (!visited.Add(id)) continue;
        if (!functions.TryGetValue(id, out var function))
        {
          missing.Add("function:" + Key(id)); unresolved = true; continue;
        }
        if ((int)function.FunctionType == 110)
        {
          selected.Add(id); found.Add(Key(id));
        }
        foreach (var next in function.ConnectedFunction ?? []) if (next != 0) queue.Enqueue(next);
      }
      paths.Add(new { ownerCode = owner, entryCode = entry,
        referenceStatusCode = unresolved ? "unresolved" : "resolved",
        shieldFunctionKeys = found.Order(StringComparer.Ordinal).ToArray() });
    }
    if (monster.PassiveSkillId != 0) Visit("monster", "passive", [], monster.PassiveSkillId);
    foreach (var (part, index) in parts.OrderBy(row => row.Id).Select((row, i) => (row, i)))
      if (part.PassiveSkillId != 0)
        Visit((part.IsMainPart ? "main_part_" : "part_") + (index + 1), "passive", [], part.PassiveSkillId);
    foreach (var (slot, index) in (monster.SkillData ?? []).Select((row, i) => (row, i)))
    {
      var owner = "skill_" + (index + 1);
      // Zero skill IDs may still carry function inputs; never silently drop them.
      if ((slot.UseFunctionIdSkill ?? []).Any(id => id != 0)) Visit(owner, "use", slot.UseFunctionIdSkill!);
      if ((slot.HurtFunctionIdSkill ?? []).Any(id => id != 0)) Visit(owner, "hurt", slot.HurtFunctionIdSkill!);
      if (slot.SkillId == 0) continue;
      if (!skills.TryGetValue(slot.SkillId, out var skill))
      {
        missing.Add("skill:" + Key(slot.SkillId)); continue;
      }
      var names = (skill.BreakObject ?? []).Where(name => !string.IsNullOrWhiteSpace(name)).ToArray();
      if (names.Length == 0 && !skill.CancelType.ToString().StartsWith("BreakCol", StringComparison.Ordinal)) continue;
      interrupts.Add(new { ownerCode = owner, cancelTypeCode = skill.CancelType.ToString(),
        breakObjectCount = names.Length, breakObjectNameKeys = names.Select(name => Key(name!)).Order(StringComparer.Ordinal),
        colliderOwnerStatusCode = "unresolved", bodyConditionInheritanceStatusCode = "unresolved",
        shieldPatternBindingStatusCode = "unresolved" });
    }
    var conditionRows = selected.Order().Select(id =>
    {
      var row = functions[id];
      var prefabs = new[] { row.FxPrefab01, row.FxPrefab02, row.FxPrefab03, row.FxPrefabFull,
        row.FxPrefab01Arena, row.FxPrefab02Arena, row.FxPrefab03Arena };
      return new { functionKey = Key(id), groupKey = row.GroupId == 0 ? null : Key(row.GroupId),
        conditionCode = "immune_other_element", standardCode = row.FunctionStandard.ToString(),
        targetCode = row.FunctionTarget.ToString(), fxSlotCount = prefabs.Count(value => !string.IsNullOrWhiteSpace(value)),
        fxPrefabSetKey = Key(string.Join("\n", prefabs.Select(value => value ?? ""))),
        fxAttachmentKey = BossContentDiscovery.FxAttachmentSha256(row),
        conditionConsumptionStatusCode = "unresolved", sharedConsumerStatusCode = "unresolved" };
    }).ToArray();
    var qteRows = qtes.Where(row => (row.MonsterId ?? []).Contains(monster.Id)).OrderBy(row => row.Id).Select((row, i) =>
    {
      var element = row.ElementId == 0 ? null : elements.GetValueOrDefault(row.ElementId);
      var weak = element is null ? null : elements.GetValueOrDefault(element.WeakElementId);
      var elementCode = SupportedElementCode(element);
      var weaknessCode = SupportedElementCode(weak);
      if (row.ElementId != 0 && (elementCode is null || weaknessCode is null)) missing.Add("qte_element:" + Key(row.ElementId));
      return new { ownerCode = "qte_" + (i + 1), recordKey = Key(row.Id),
        elementReferenceStatusCode = row.ElementId == 0 ? "not_applicable" : elementCode is null || weaknessCode is null ? "unresolved" : "resolved",
        elementCode, weaknessCode,
        matchesMonsterElement = (monster.ElementId ?? []).Contains(row.ElementId),
        prefabKey = string.IsNullOrWhiteSpace(row.QtePrefab) ? null : Key(row.QtePrefab),
        groupKeys = (row.GroupId ?? []).Select(id => Key(id)).Order(StringComparer.Ordinal),
        monsterReferenceCount = (row.MonsterId ?? []).Distinct().Count(),
        conditionConsumptionStatusCode = row.ElementId == 0 ? "not_applicable" : "unresolved",
        displayConsumptionStatusCode = row.ElementId == 0 ? "not_applicable" : "unresolved" };
    }).ToArray();
    return JsonSerializer.SerializeToElement(new {
      contractId = "nll/boss-shield-pattern-discovery/v1",
      entryPoints = paths,
      partTargets = parts.OrderBy(row => row.Id).Select((part, i) => new {
        ownerCode = (part.IsMainPart ? "main_part_" : "part_") + (i + 1),
        partsTypeCode = part.PartsType.ToString(), isMainPart = part.IsMainPart,
        damageable = part.IsPartsDamageAble }),
      conditions = conditionRows, normalInterrupts = interrupts, quickTimeEvents = qteRows,
      missingReferenceCount = missing.Count,
      staticReferenceStatusCode = missing.Count == 0 ? "resolved" : "unresolved",
      conditionConsumptionStatusCode = conditionRows.Length == 0 && interrupts.Count == 0 && qteRows.Length == 0 && missing.Count == 0
          ? "not_applicable" : "unresolved",
      rawSourceIdentifiersPersisted = false
    });
  }

  private static string Key(object value) => Convert.ToHexStringLower(SHA256.HashData(
      Encoding.UTF8.GetBytes(Convert.ToString(value, CultureInfo.InvariantCulture)!)));

  private static string? SupportedElementCode(ElementRecord? row) => row?.Element is
      AttackType.Fire or AttackType.Water or AttackType.Wind or AttackType.Electronic or AttackType.Iron
          ? BossContentDiscovery.ElementCode(row!.Element) : null;
}
