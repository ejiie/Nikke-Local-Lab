namespace NikkeLocalLab.Raid.UnitTests;

public sealed class ChallengeBossSupportPolicyTests
{
  [Theory]
  [InlineData(14)]
  [InlineData(39)]
  public void Explicitly_excluded_seasons_are_never_admitted(int season)
  {
    var decision = ChallengeBossSupportPolicy.Evaluate(
        season,
        RaidElement.Electric,
        RaidElement.Iron,
        authoritativeChallengeChainResolved: true);

    Assert.Equal(ChallengeAdmissionOutcome.ExcludedByPolicy, decision.Outcome);
    Assert.Equal("excluded_season", decision.ReasonCode);
    Assert.Null(decision.Rule);
  }

  [Theory]
  [InlineData(RaidElement.Fire, RaidElement.Water)]
  [InlineData(RaidElement.Wind, RaidElement.Fire)]
  [InlineData(RaidElement.Electric, RaidElement.Iron)]
  public void Season_40_is_an_explicit_include_independent_of_element_facts(
      RaidElement element,
      RaidElement weakness)
  {
    var decision = ChallengeBossSupportPolicy.Evaluate(
        40,
        element,
        weakness,
        authoritativeChallengeChainResolved: true);

    Assert.True(decision.IsSupported);
    Assert.Equal(ChallengeAdmissionRule.Season40Explicit, decision.Rule);
    Assert.Equal(ChallengeBossSupportPolicy.PolicyId, decision.PolicyId);
  }

  [Fact]
  public void Electric_weak_to_iron_rule_is_policy_driven_not_a_second_season_allowlist()
  {
    var decision = ChallengeBossSupportPolicy.Evaluate(
        41,
        RaidElement.Electric,
        RaidElement.Iron,
        authoritativeChallengeChainResolved: true);

    Assert.True(decision.IsSupported);
    Assert.Equal(ChallengeAdmissionRule.ElectricWeakToIron, decision.Rule);
  }

  [Fact]
  public void Incomplete_authoritative_chain_and_wrong_element_pair_are_not_publishable()
  {
    var unresolved = ChallengeBossSupportPolicy.Evaluate(
        40,
        RaidElement.Wind,
        RaidElement.Fire,
        authoritativeChallengeChainResolved: false);
    var unsupported = ChallengeBossSupportPolicy.Evaluate(
        13,
        RaidElement.Wind,
        RaidElement.Fire,
        authoritativeChallengeChainResolved: true);

    Assert.Equal(ChallengeAdmissionOutcome.Unresolved, unresolved.Outcome);
    Assert.Equal("authoritative_challenge_chain_unresolved", unresolved.ReasonCode);
    Assert.Equal(ChallengeAdmissionOutcome.Unsupported, unsupported.Outcome);
    Assert.Equal("element_weakness_not_supported", unsupported.ReasonCode);
  }
}
