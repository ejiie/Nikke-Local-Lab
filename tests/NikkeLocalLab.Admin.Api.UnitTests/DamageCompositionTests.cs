using NikkeLocalLab.BattleLog;
using Entry = NikkeLocalLab.BattleLog.BattleLogProjectileDecoder.Entry;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class DamageCompositionTests
{
  private static Entry E(string name, int tick, params (string Key, long Value)[] values) =>
      new(name, values.ToDictionary(v => v.Key, v => v.Value), 0, tick, tick * 17L);
  private static List<Entry> Start(long sourceKind = 1) => [
      E("Entity", 0, ("kind", 1), ("staticId", 101)),
    E("Entity", 0, ("kind", 2), ("staticId", 102)),
    E("HurtShape", 0, ("caster", 0), ("target", 1), ("subId", 0), ("isPenetration", 0)),
    E("HitContextShape", 0, ("sourceKind", sourceKind), ("sourceId", 201), ("partsType", 0)),
    E("DamageFormulaShape", 0, ("stickyProjectileCollisionDamageRateBits", 1065353216), ("projectileExplosionDamageRateBits", 1065353216))
  ];
  private static Entry Formula(int tick, long context = 0) => E("DamageFormula", tick,
      ("caster", 0), ("target", 1), ("rawCaster", 0), ("context", context), ("shape", 0), ("damage", 100));
  private static Entry Hurt(int tick) => E("CommonHurtEvent", tick, ("shape", 0), ("rawCaster", 0), ("damage", 100));
  private static DamageCatalog Catalog() => new("synthetic", new string('a', 64),
      [new(101, 301, [new("skill", 201, ["burst"]), new("skill", 202, ["skill2"])])], [], []);
  private static CharacterComposition Analyze(List<Entry> events, int damage, DamageCatalog? catalog = null) =>
      DamageCompositionAnalyzer.AnalyzeEvents(events, [new(1, 101, damage)],
          new("ready", new string('b', 64), ProjectileAnalysis.CurrentVersion, [new(1, 0, damage)]),
          catalog ?? Catalog(), new string('b', 64), new string('c', 64)).Characters.Single();

  [Fact]
  public void DelayedSkillDamageRetainsItsOriginalSourceAcrossTicks()
  {
    var events = Start(); events.AddRange([Formula(1), Hurt(75)]);
    var result = Analyze(events, 100);
    Assert.Equal("0", result.UnclassifiedDamage);
    Assert.Equal("skill", Assert.Single(result.Components).Category);
    Assert.Equal("burst", result.Components[0].Origin);
  }
  [Fact]
  public void SequentialIdenticalDamageConsumesEachCalculationOnce()
  {
    var events = Start(); events.AddRange([Formula(1), Formula(1), Hurt(10), Hurt(20), Hurt(30)]);
    var result = Analyze(events, 300);
    Assert.Equal("200", Assert.Single(result.Components).Damage);
    Assert.Equal(2, result.Components[0].Hits);
    Assert.Equal("100", result.UnclassifiedDamage);
  }
  [Fact]
  public void EqualDamageFromDifferentSkillsRemainsUnclassified()
  {
    var events = Start(); events.Add(E("HitContextShape", 0, ("sourceKind", 1), ("sourceId", 202), ("partsType", 0)));
    events.AddRange([Formula(1), Formula(2, 1), Hurt(5)]);
    var result = Analyze(events, 100);
    Assert.Empty(result.Components); Assert.Equal("100", result.UnclassifiedDamage);
  }
  [Fact]
  public void AutomaticWeaponNeedsObservedSkillActivation()
  {
    var events = Start(0);
    var catalog = Catalog() with { Shots = [new(201, "Direct")], Skills = [new(201, 201, "automatic")] };
    events.AddRange([Formula(1), Hurt(1)]);
    Assert.Equal("100", Analyze(events, 100, catalog).UnclassifiedDamage);
    events.Insert(5, E("UseCharacterSkill", 0, ("caster", 0), ("characterSkillId", 201)));
    var result = Analyze(events, 100, catalog);
    Assert.Equal("automatic", Assert.Single(result.Components).Category);
    Assert.Equal("burst", result.Components[0].Origin);
  }
  [Fact]
  public void MatchingAmountDoesNotJoinAnotherBodyPart()
  {
    var events = Start(); events[3] = E("HitContextShape", 0, ("sourceKind", 1), ("sourceId", 201), ("partsType", 1));
    events.AddRange([Formula(1), Hurt(2)]);
    Assert.Equal("100", Analyze(events, 100).UnclassifiedDamage);
  }
  private static DamageCatalog EnhancedCatalog() => new("synthetic", new string('a', 64),
      [new(101, 201, [new("function", 401, ["skill1"]), new("function", 402, ["skill1"])])],
      [new(201, "Direct")], [], [new(401, 80), new(402, 160)]);
  private static List<Entry> EnhancedStart()
  {
    var events = Start(0);
    events.Add(E("HitContextShape", 0, ("sourceKind", 0), ("sourceId", 201), ("partsType", 0), ("hasPenetration", 1)));
    events.Add(E("Function", 0, ("functionId", 401))); events.Add(E("Function", 0, ("functionId", 402)));
    return events;
  }
  private static Entry AddEnhancement(int tick, int function) => E("AddedFunction", tick, ("owner", 0), ("caster", 0), ("func", function), ("stack", 1));

  [Fact]
  public void NormalAndTwoPelletEnhancementStatesKeepExactDamage()
  {
    var events = EnhancedStart(); events.AddRange([Formula(1),
      Hurt(1),
      AddEnhancement(2, 0),
      Formula(2, 1),
      Hurt(2),
      AddEnhancement(3, 1),
      Formula(3, 1),
      Hurt(3)]);
    var result = Analyze(events, 300, EnhancedCatalog()); var component = Assert.Single(result.Components);
    Assert.Equal("300", component.Damage); Assert.Equal(3, component.Breakdown!.Count);
    Assert.Equal("normal", component.Breakdown[0].Kind);
    Assert.Equal([80], component.Breakdown[1].PelletThresholds);
    Assert.Equal([80, 160], component.Breakdown[2].PelletThresholds);
    Assert.All(component.Breakdown, s => Assert.Equal("100", s.Damage));
  }
  [Fact]
  public void EnhancementRemovalDoesNotRewriteAlreadyCalculatedHit()
  {
    var events = EnhancedStart(); events.AddRange([AddEnhancement(1, 0),
      Formula(2, 1),
      E("RemovedFunction", 3, ("owner", 0), ("func", 0)),
      Hurt(4),
      Formula(5),
      Hurt(5)]);
    var parts = Assert.Single(Analyze(events, 200, EnhancedCatalog()).Components).Breakdown!;
    Assert.Equal("enhanced", parts[0].Kind); Assert.Equal("normal", parts[1].Kind);
  }
  [Fact]
  public void AmbiguousEnhancementPreservesKnownSourceWithoutInventingState()
  {
    var events = EnhancedStart(); events.AddRange([Formula(1), AddEnhancement(2, 0), Formula(2, 1), Hurt(3), Hurt(4)]);
    var result = Analyze(events, 200, EnhancedCatalog()); Assert.Equal("0", result.UnclassifiedDamage);
    var part = Assert.Single(Assert.Single(result.Components).Breakdown!);
    Assert.Equal("unresolved", part.Kind); Assert.Equal("200", part.Damage);
  }
}
