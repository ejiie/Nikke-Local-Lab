using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;

namespace NikkeLocalLab.BattleLog;

// Private, sealed static snapshot. Source IDs never leave the analyzer.
public sealed record DamageCatalog(string ClientBuild, string SourceSha256, DamageCharacterSpec[] Characters,
    DamageShotSpec[] Shots, DamageSkillSpec[] Skills, DamageEnhancement[]? Enhancements = null);
public sealed record DamageCharacterSpec(long Id, long BaseShot, DamageOrigin[] Origins);
public sealed record DamageOrigin(string Kind, long Id, string[] Slots, string EffectKind = "");
public sealed record DamageEnhancement(long Id, int PelletThreshold);
public sealed record DamageShotSpec(long Id, string FireType);
public sealed record DamageSkillSpec(long Id, long ReplacementShot, string WeaponKind = "replacement");
public sealed record DamageComponent(string Key, string Category, string Origin, string Component,
    string Damage, int Hits, int PenetratingHits, string EffectKind = "", IReadOnlyList<DamageSlice>? Breakdown = null);
public sealed record DamageSlice(string Kind, int[] PelletThresholds, string Damage, int Hits, int PenetratingHits, string PenetratingDamage);
public sealed record CharacterComposition(int Ordinal, string Status, string Damage, string UnclassifiedDamage,
    IReadOnlyList<DamageComponent> Components);
public sealed record DamageComposition(string Status, string Version, string LogSha256, string CatalogSha256,
    IReadOnlyList<CharacterComposition> Characters)
{
  public const string CurrentVersion = "damage-composition/v3";
}

public static class DamageCompositionAnalyzer
{
  private sealed record FormulaClass(long Kind, long Source, string Origin, bool ObservedWeapon, long Collision, long Explosion, string Enhancement);
  private sealed record PendingFormula(BattleLogProjectileDecoder.Entry Event, string Origin, bool ObservedWeapon, int Count);
  public static DamageComposition Analyze(byte[] raw, IReadOnlyList<BattleLogCharacter> characters,
      ProjectileAnalysis projectile, DamageCatalog catalog, string catalogHash)
  {
    var hash = Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
    DamageComposition Fail(string status) => new(status, DamageComposition.CurrentVersion, hash, catalogHash, []);
    if (raw.Length == 0 || raw.Length > BattleLogProjectileDecoder.MaximumRawBytes) return Fail("invalid_log");
    if (projectile.Status != "ready" || projectile.LogSha256 != hash) return Fail("projectile_analysis_required");
    try { return AnalyzeEvents(BattleLogProjectileDecoder.Decode(raw, true), characters, projectile, catalog, hash, catalogHash); }
    catch (NotSupportedException) { return Fail("unsupported_schema"); }
    catch (Exception ex) when (ex is InvalidDataException or EndOfStreamException or OverflowException or
        ArgumentException or KeyNotFoundException or IndexOutOfRangeException or InvalidOperationException)
    { return Fail("invalid_log"); }

  }

  internal static DamageComposition AnalyzeEvents(IReadOnlyList<BattleLogProjectileDecoder.Entry> events,
      IReadOnlyList<BattleLogCharacter> characters, ProjectileAnalysis projectile, DamageCatalog catalog, string hash, string catalogHash)
  {
    DamageComposition Fail(string status) => new(status, DamageComposition.CurrentVersion, hash, catalogHash, []);
    Dictionary<string, long>[] Table(string name) => events.Where(e => e.Name == name).Select(e => e.Values).ToArray();
    var entities = Table("Entity"); var hurts = Table("HurtShape"); var contexts = Table("HitContextShape"); var formulas = Table("DamageFormulaShape");
    Dictionary<string, long> At(Dictionary<string, long>[] table, long i) => i >= 0 && i < table.Length ? table[(int)i] : throw new InvalidDataException();
    var byEntity = new Dictionary<long, BattleLogCharacter>();
    foreach (var c in characters)
    {
      var matches = Enumerable.Range(0, entities.Length).Where(i => entities[i]["kind"] == 1 && entities[i]["staticId"] == c.StaticId).ToArray();
      if (matches.Length != 1) return Fail("identity_unresolved");
      byEntity.Add(matches[0], c);
    }
    var specs = catalog.Characters.ToDictionary(c => c.Id);
    var shots = catalog.Shots.ToDictionary(s => s.Id);
    var skills = catalog.Skills.ToDictionary(s => s.Id);
    var enhancementSpecs = (catalog.Enhancements ?? []).ToDictionary(f => f.Id);
    var functionRefs = Table("Function");
    var activeEnhancements = new Dictionary<(long Owner, long Function), long>();
    var owners = new Dictionary<long, long>();
    foreach (var e in events.Where(e => e.Name == "ProjectileSpawn"))
    {
      var v = e.Values;
      if (owners.TryGetValue(v["projectile"], out var old) && old != v["owner"]) return Fail("identity_ambiguous");
      owners[v["projectile"]] = v["owner"];
    }
    long Root(long entity)
    {
      var visited = new HashSet<long>();
      while (owners.TryGetValue(entity, out var owner)) { if (!visited.Add(entity)) throw new InvalidDataException(); entity = owner; }
      _ = At(entities, entity); return entity;
    }
    var enemyProjectiles = owners.Keys.Where(p => At(entities, Root(p))["kind"] == 2).ToHashSet();
    string Origin(long caster, string kind, long id)
    {
      if (!byEntity.TryGetValue(caster, out var c) || !specs.TryGetValue(c.StaticId, out var spec)) return "unresolved";
      var slots = spec.Origins.Where(o => o.Kind == kind && o.Id == id).SelectMany(o => o.Slots).Distinct().ToArray();
      return slots.Length == 1 ? slots[0] : "unresolved";
    }
    string Enhancement(long caster, Dictionary<string, long> context)
    {
      if (context["sourceKind"] != 0 || !byEntity.TryGetValue(caster, out var c) ||
          !specs.TryGetValue(c.StaticId, out var spec) || context["sourceId"] != spec.BaseShot) return "not_applicable";
      var own = spec.Origins.Where(o => o.Kind == "function" && enhancementSpecs.ContainsKey(o.Id)).Select(o => o.Id).ToHashSet();
      if (own.Count == 0) return "normal";
      var thresholds = activeEnhancements.Where(p => p.Key.Owner == caster && p.Value == caster)
          .Select(p => At(functionRefs, p.Key.Function)["functionId"]).Where(own.Contains)
          .Select(id => enhancementSpecs[id].PelletThreshold).Distinct().Order().ToArray();
      if (thresholds.Length == 0) return context.GetValueOrDefault("hasPenetration") == 1 ? "unresolved" : "normal";
      return context.GetValueOrDefault("hasPenetration") == 1 ? string.Join(",", thresholds) : "unresolved";
    }
    var uses = new Dictionary<long, List<BattleLogProjectileDecoder.Entry>>();
    var automatic = new Dictionary<(long Caster, long Shot), HashSet<string>>();
    var weapons = new Dictionary<long, (long Shot, string Origin)>();
    var spawned = new Dictionary<long, (long Shot, string Origin, bool ObservedWeapon)>();
    var pending = new Dictionary<(long Caster, long Target, long Part, long Damage), Dictionary<FormulaClass, PendingFormula>>();
    var groups = characters.ToDictionary(c => c.Ordinal, _ => new Dictionary<(string Category, string Origin, string Component, long Source), (long Damage, int Hits, int Penetrating)>());
    var slices = characters.ToDictionary(c => c.Ordinal, _ => new Dictionary<((string Category, string Origin, string Component, long Source) Group, string State), (long Damage, int Hits, int Penetrating, long PenetratingDamage)>());
    var sums = characters.ToDictionary(c => c.Ordinal, _ => 0L);
    var unknown = characters.ToDictionary(c => c.Ordinal, _ => 0L);
    foreach (var e in events)
    {
      var v = e.Values;
      if (e.Name is "AddedFunction" or "AddedIterationFunction")
      {
        if (enhancementSpecs.ContainsKey(At(functionRefs, v["func"])["functionId"]))
        {
          var key = (v["owner"], v["func"]);
          if (v["stack"] > 0) activeEnhancements[key] = v["caster"]; else activeEnhancements.Remove(key);
        }
      }
      if (e.Name is "RemovedFunction" or "DispelledFunction") activeEnhancements.Remove((v["owner"], v["func"]));
      if (e.Name == "UseCharacterSkill")
      {
        var list = uses.GetValueOrDefault(v["caster"]);
        if (list is null) uses[v["caster"]] = list = [];
        list.RemoveAll(x => e.Time - x.Time > 500);
        list.Add(e);
        if (skills.TryGetValue(v["characterSkillId"], out var autoSkill) && autoSkill.WeaponKind == "automatic")
        {
          var key = (v["caster"], autoSkill.ReplacementShot);
          if (!automatic.TryGetValue(key, out var origins)) automatic[key] = origins = [];
          origins.Add(Origin(v["caster"], "skill", autoSkill.Id));
        }
      }
      if (e.Name == "ChangeWeapon" && v["fromShotId"] != v["toShotId"])
      {
        var candidates = (uses.GetValueOrDefault(v["char"]) ?? []).Where(x => e.Time >= x.Time && e.Time - x.Time <= 500 &&
            skills.TryGetValue(x.Values["characterSkillId"], out var skill) && skill.ReplacementShot == v["toShotId"]).ToArray();
        weapons[v["char"]] = (v["toShotId"], candidates.Length == 1 ? Origin(v["char"], "skill", candidates[0].Values["characterSkillId"]) : "unresolved");
      }
      if (e.Name == "ProjectileSpawn")
      {
        var owner = Root(v["owner"]);
        var weapon = weapons.GetValueOrDefault(owner);
        spawned[v["projectile"]] = (v["shotId"], weapon.Shot == v["shotId"] ? weapon.Origin ?? "unresolved" : "unresolved", weapon.Shot == v["shotId"]);
      }
      if (e.Name == "DamageFormula")
      {
        var context = At(contexts, v["context"]);
        var key = (v["caster"], v["target"], context["partsType"], v["damage"]);
        if (!pending.TryGetValue(key, out var list)) pending[key] = list = [];
        var weapon = weapons.GetValueOrDefault(v["caster"]);
        var formulaOrigin = weapon.Shot == context["sourceId"] ? weapon.Origin ?? "unresolved" : "unresolved";
        var observedWeapon = weapon.Shot == context["sourceId"];
        if (spawned.TryGetValue(v["rawCaster"], out var spawn) && spawn.Shot == context["sourceId"])
        { formulaOrigin = spawn.Origin; observedWeapon = spawn.ObservedWeapon; }
        var shape = At(formulas, v["shape"]);
        var signature = new FormulaClass(context["sourceKind"], context["sourceId"], formulaOrigin, observedWeapon,
            context["sourceKind"] == 0 ? shape["stickyProjectileCollisionDamageRateBits"] : 0,
            context["sourceKind"] == 0 ? shape["projectileExplosionDamageRateBits"] : 0,
            Enhancement(v["caster"], context));
        // Equivalent calculations need a multiplicity, not an unbounded scan on each hit.
        list[signature] = list.TryGetValue(signature, out var previous)
            ? previous with { Count = checked(previous.Count + 1) } : new(e, formulaOrigin, observedWeapon, 1);
      }
      if (e.Name != "CommonHurtEvent") continue;
      var hurt = At(hurts, v["shape"]);
      if (v["damage"] < 0) throw new InvalidDataException();
      var caster = Root(hurt["caster"]);
      if (!byEntity.TryGetValue(caster, out var character)) continue;
      // Restrict to monster targets, exclude enemy projectiles, then reconcile per character.
      if (enemyProjectiles.Contains(hurt["target"]) || At(entities, hurt["target"])["kind"] != 2) continue;
      var ordinal = character.Ordinal; var damage = v["damage"];
      sums[ordinal] = checked(sums[ordinal] + damage);
      var pairKey = (hurt["caster"], hurt["target"], hurt["subId"], damage);
      // Skill damage may apply many ticks after its calculation. Retain unconsumed
      // formulas for this battle. Multiple candidates are usable for composition only
      // when every candidate has the same attribution; do not claim an exact hit link.
      if (!pending.TryGetValue(pairKey, out var matches) || matches.Count == 0)
      { unknown[ordinal] = checked(unknown[ordinal] + damage); continue; }
      if (matches.Count != 1)
      {
        var classes = matches.Keys.Select(k => k with { Enhancement = "unresolved" }).Distinct().Take(2).ToArray();
        if (classes.Length != 1) { unknown[ordinal] = checked(unknown[ordinal] + damage); continue; }
        // Preserve known source totals when only enhancement state is ambiguous.
        // Merge the remaining multiplicity into unresolved so a later hit cannot
        // gain false precision from an arbitrary candidate being consumed first.
        var representative = matches.First().Value with { Count = matches.Values.Sum(p => p.Count) };
        matches.Clear(); matches[classes[0]] = representative;
      }
      var candidate = matches.Single(); var pair = candidate.Value;
      if (pair.Count == 1) pending.Remove(pairKey);
      else matches[candidate.Key] = pair with { Count = pair.Count - 1 };
      var cv = At(contexts, pair.Event.Values["context"]); var source = cv["sourceId"];
      string category, origin, component = "unspecified";
      if (cv["sourceKind"] == 0 && specs.TryGetValue(character.StaticId, out var spec) && shots.ContainsKey(source))
      {
        category = source == spec.BaseShot ? "basic" : "replacement";
        origin = category == "basic" ? "basic" : pair.Origin;
        var observedWeapon = pair.ObservedWeapon;
        if (category == "replacement" && spawned.TryGetValue(v["rawCaster"], out var attackSpawn) && attackSpawn.Shot == source)
        { origin = attackSpawn.Origin; observedWeapon = attackSpawn.ObservedWeapon; }
        if (category == "replacement" && !observedWeapon)
        {
          if (automatic.TryGetValue((caster, source), out var autoOrigins) && autoOrigins.Count == 1)
          { category = "automatic"; origin = autoOrigins.Single(); }
          else { unknown[ordinal] = checked(unknown[ordinal] + damage); continue; }
        }
        var shape = At(formulas, pair.Event.Values["shape"]);
        var collision = Float(shape["stickyProjectileCollisionDamageRateBits"]);
        var explosion = Float(shape["projectileExplosionDamageRateBits"]);
        if (shots[source].FireType == "StickyProjectileDirect" && float.IsFinite(collision) && float.IsFinite(explosion))
        {
          if (collision != 1 && explosion == 1) component = "collision";
          else if (collision == 1 && explosion != 1) component = "explosion";
        }
      }
      else if (cv["sourceKind"] is 1 or 2)
      { category = cv["sourceKind"] == 1 ? "skill" : "effect"; origin = Origin(caster, category == "skill" ? "skill" : "function", source); }
      else { unknown[ordinal] = checked(unknown[ordinal] + damage); continue; }
      var groupKey = (category, origin, component, source);
      var group = groups[ordinal].GetValueOrDefault(groupKey);
      groups[ordinal][groupKey] = (checked(group.Damage + damage), group.Hits + 1, group.Penetrating + (hurt["isPenetration"] == 1 ? 1 : 0));
      if (category == "basic")
      {
        var sliceKey = (groupKey, candidate.Key.Enhancement);
        var slice = slices[ordinal].GetValueOrDefault(sliceKey); var penetrating = hurt["isPenetration"] == 1;
        slices[ordinal][sliceKey] = (checked(slice.Damage + damage), slice.Hits + 1,
            slice.Penetrating + (penetrating ? 1 : 0), checked(slice.PenetratingDamage + (penetrating ? damage : 0)));
      }
    }
    var output = new List<CharacterComposition>();
    foreach (var c in characters)
    {
      var total = projectile.Characters.Single(x => x.Ordinal == c.Ordinal).ExcludedDamage;
      if (sums[c.Ordinal] > total)
      {
        output.Add(new(c.Ordinal, "total_mismatch", Num(total), Num(total), [])); continue;
      }
      var remaining = checked(total - sums[c.Ordinal] + unknown[c.Ordinal]);
      var components = groups[c.Ordinal].Select((g, i) =>
      {
        var kind = g.Key.Category == "skill" ? "skill" : g.Key.Category == "effect" ? "function" : "";
        var effect = specs.TryGetValue(c.StaticId, out var spec)
            ? spec.Origins.Where(o => o.Kind == kind && o.Id == g.Key.Source).Select(o => o.EffectKind).Distinct().ToArray() : [];
        var breakdown = slices[c.Ordinal].Where(s => s.Key.Group == g.Key).Select(s =>
        {
          var state = s.Key.State; var enhanced = state.Length > 0 && char.IsDigit(state[0]);
          return new DamageSlice(enhanced ? "enhanced" : state,
              enhanced ? state.Split(',').Select(int.Parse).ToArray() : [], Num(s.Value.Damage), s.Value.Hits,
              s.Value.Penetrating, Num(s.Value.PenetratingDamage));
        }).ToArray();
        return new DamageComponent("component-" + (i + 1), g.Key.Category, g.Key.Origin, g.Key.Component,
            Num(g.Value.Damage), g.Value.Hits, g.Value.Penetrating, effect.Length == 1 ? effect[0] : "", breakdown);
      }).ToArray();
      if (components.Aggregate(0L, (sum, r) => checked(sum + long.Parse(r.Damage, CultureInfo.InvariantCulture))) + remaining != total)
        throw new InvalidDataException();
      output.Add(new(c.Ordinal, remaining == 0 ? "ready" : "partial", Num(total), Num(remaining), components));
    }
    return new(output.All(c => c.Status == "ready") ? "ready" : "partial", DamageComposition.CurrentVersion, hash, catalogHash, output);
  }
  private static float Float(long value) => BitConverter.Int32BitsToSingle(unchecked((int)value));
  private static string Num(long value) => value.ToString(CultureInfo.InvariantCulture);
}
