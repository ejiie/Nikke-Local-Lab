using NikkeLocalLab.BattleLog;
using NikkeLocalLab.Persistence.PostgreSql;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class BattleLogProjectileTests
{
  [Fact]
  public void CompositionDoesNotUseCorrectionFromAnotherLog()
  {
    var result = DamageCompositionAnalyzer.Analyze([1, 2, 3], [new(1, 123, 100)],
        new("ready", new string('a', 64), ProjectileAnalysis.CurrentVersion, [new(1, 10, 90)]),
        new("synthetic", new string('b', 64), [], [], []), new string('c', 64));
    Assert.Equal("projectile_analysis_required", result.Status);
    Assert.Empty(result.Characters);
  }
  [Fact]
  public void MissingCorruptOversizedLogsNeverBecomeZeroDamage()
  {
    BattleLogCharacter[] characters = [new(1, 123, 100)];
    foreach (var bytes in new[] { Array.Empty<byte>(), new byte[] { 128 }, new byte[BattleLogProjectileDecoder.MaximumRawBytes + 1] })
    {
      var result = BattleLogProjectileDecoder.Analyze(bytes, characters, 0);
      Assert.NotEqual("ready", result.Status); Assert.Empty(result.Characters);
    }
  }

  [Fact]
  public void AggregateUsesExactIntegersAndDoesNotFillMissingCharacterAnalysis()
  {
    var row = new RaidRecord();
    row.Characters.Add(new(1, 1, Guid.NewGuid(), "9007199254740993", "1", "9007199254740992"));
    row.Characters.Add(new(2, 2, Guid.NewGuid(), "9007199254740993", "0", "9007199254740993"));
    Assert.Equal("18014398509481985", row.ProjectileExcludedDamage);
    row.Characters.Add(new(3, 3, Guid.NewGuid(), "12", null, null));
    Assert.Null(row.ProjectileExcludedDamage);
  }
}
