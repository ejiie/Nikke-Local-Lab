using EpinelPS.Data;
using System.Text.Json;

internal static class BossShieldPatternChecks
{
  internal static void Run()
  {
    var count = 0;
    void Check(bool value) { if (!value) throw new InvalidOperationException("phase_d_shield_pattern_check_failed"); count++; }
    var monster = new MonsterRecord { Id = 101, ElementId = [7], SkillData = [
      new SkillData { SkillId = 0, UseFunctionIdSkill = [11] },
      new SkillData { SkillId = 31, HurtFunctionIdSkill = [12] }] };
    var parts = new[] { new MonsterPartsRecord { Id = 21, IsMainPart = true, IsPartsDamageAble = true,
      PartsType = PartsType.Body, PassiveSkillId = 41 } };
    var states = new Dictionary<int, StateEffectRecord> { [41] = new() { Id = 41, UseFunctionIdList = [11] } };
    var functions = new Dictionary<int, FunctionRecord> {
      [11] = new() { Id = 11, FunctionType = (FunctionType)110, GroupId = 81, FxPrefab01 = "synthetic-shield", ConnectedFunction = [12] },
      [12] = new() { Id = 12, FunctionType = (FunctionType)110, GroupId = 81, ConnectedFunction = [11] } };
    var skills = new Dictionary<int, MonsterSkillRecord> { [31] = new() { Id = 31,
      BreakObject = ["synthetic-interrupt"], CancelType = (CancelType)1 } };
    var elements = new Dictionary<int, ElementRecord> {
      [7] = new() { Id = 7, Element = AttackType.Water, WeakElementId = 8 },
      [8] = new() { Id = 8, Element = AttackType.Electronic, WeakElementId = 7 } };
    var qtes = new[] { new QuickTimeEventRecord { Id = 51, MonsterId = [101, 102],
      ElementId = 7, QtePrefab = "synthetic-qte", GroupId = [61] } };
    var options = new JsonSerializerOptions { IncludeFields = true };
    var before = JsonSerializer.Serialize(new { monster, parts, states, functions, skills, elements, qtes }, options);
    JsonElement Describe() => BossShieldPatternDiscovery.Describe(monster, parts, skills, states, functions, qtes, elements);
    var result = Describe();
    Check(result.GetProperty("conditions").GetArrayLength() == 2); // Cycle terminates, shared origins deduplicate.
    Check(result.GetProperty("entryPoints").GetArrayLength() == 3); // Includes functions on a zero skill ID.
    Check(result.GetProperty("conditions").EnumerateArray().Any(row => row.GetProperty("fxSlotCount").GetInt32() == 0));
    Check(result.GetProperty("normalInterrupts")[0].GetProperty("bodyConditionInheritanceStatusCode").GetString() == "unresolved");
    Check(result.GetProperty("quickTimeEvents")[0].GetProperty("elementCode").GetString() == "water" &&
        result.GetProperty("quickTimeEvents")[0].GetProperty("weaknessCode").GetString() == "electric");
    Check(!result.GetRawText().Contains("synthetic-interrupt") && !result.GetRawText().Contains("synthetic-shield"));
    Check(before == JsonSerializer.Serialize(new { monster, parts, states, functions, skills, elements, qtes }, options));
    functions.Remove(12);
    Check(Describe().GetProperty("missingReferenceCount").GetInt32() == 1);
    states.Clear();
    Check(Describe().GetProperty("staticReferenceStatusCode").GetString() == "unresolved");
    elements.Remove(7);
    Check(Describe().GetProperty("quickTimeEvents")[0].GetProperty("elementReferenceStatusCode").GetString() == "unresolved");
    elements[7] = new() { Id = 7, Element = (AttackType)999, WeakElementId = 8 };
    Check(Describe().GetProperty("quickTimeEvents")[0].GetProperty("elementReferenceStatusCode").GetString() == "unresolved");
    qtes[0].ElementId = 0;
    elements[0] = new() { Id = 0, Element = (AttackType)999 };
    Check(Describe().GetProperty("quickTimeEvents")[0].GetProperty("elementReferenceStatusCode").GetString() == "not_applicable");
    var empty = BossShieldPatternDiscovery.Describe(new MonsterRecord(), [], skills, states, functions, [], elements);
    Check(empty.GetProperty("conditionConsumptionStatusCode").GetString() == "not_applicable");
    Console.WriteLine(JsonSerializer.Serialize(new { contractId = "nll/boss-shield-pattern-check/v1",
      passed = count, failed = 0, syntheticOnly = true, originalClientExecuted = false }));
  }
}
