namespace NikkeLocalLab.Character.UnitTests;

public sealed class NormalizedFactTests
{
  [Fact]
  public void States_keep_missing_and_inapplicable_distinct()
  {
    var ready = NormalizedFact<int>.Ready(0);
    var unresolved = NormalizedFact<int>.Unresolved("missing_authoritative_value");
    var notApplicable = NormalizedFact<int>.NotApplicable();

    Assert.Equal(FactStatus.Ready, ready.Status);
    Assert.Equal(0, ready.RequireValue());
    Assert.Equal(FactStatus.Unresolved, unresolved.Status);
    Assert.Equal("missing_authoritative_value", unresolved.ReasonCode);
    Assert.Null(unresolved.Value);
    Assert.Equal(FactStatus.NotApplicable, notApplicable.Status);
    Assert.Null(notApplicable.Value);
    Assert.Null(notApplicable.ReasonCode);
    Assert.Throws<InvalidOperationException>(() => notApplicable.RequireValue());
  }

  [Theory]
  [InlineData("")]
  [InlineData("Raw Value")]
  [InlineData("UPPERCASE")]
  [InlineData("contains/path")]
  public void Unresolved_reason_must_be_a_controlled_code(string reasonCode)
  {
    Assert.Throws<ArgumentException>(() => NormalizedFact<int>.Unresolved(reasonCode));
  }

  [Fact]
  public void Required_profile_fields_reject_not_applicable()
  {
    Assert.Throws<ArgumentException>(() => new CharacterProfile(
        NormalizedFact<CharacterRarity>.NotApplicable(),
        NormalizedFact<CombatRole>.Ready(CombatRole.Attacker),
        NormalizedFact<WeaponClass>.Ready(WeaponClass.Shotgun),
        NormalizedFact<NikkeElement>.Ready(NikkeElement.Fire),
        NormalizedFact<Manufacturer>.Ready(Manufacturer.Elysion)));
  }

  [Fact]
  public void Equipment_capabilities_require_all_four_unique_slots()
  {
    var threeSlots = CharacterTestData.ReadyEquipment().Take(3);
    Assert.Throws<ArgumentException>(() => new CharacterCapabilities(
        NormalizedFact<int>.Ready(400),
        NormalizedFact<int>.Ready(3),
        NormalizedFact<int>.Ready(7),
        NormalizedFact<int>.Ready(30),
        threeSlots,
        CharacterTestData.ReadySkills(),
        NormalizedFact<int>.Ready(15),
        NormalizedFact<int>.Ready(15),
        NormalizedFact<int>.NotApplicable()));
  }

  [Fact]
  public void Ready_maxima_reject_invalid_sentinel_values()
  {
    Assert.Throws<ArgumentOutOfRangeException>(() => CharacterTestData.ReadyContent(
        maximumCharacterLevel: NormalizedFact<int>.Ready(0)));
    Assert.Throws<ArgumentOutOfRangeException>(() => CharacterTestData.ReadyContent(
        maximumCollectionLevel: NormalizedFact<int>.Ready(-1)));
  }
}
