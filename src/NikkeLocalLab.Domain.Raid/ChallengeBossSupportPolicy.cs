namespace NikkeLocalLab.Domain.Raid;

public enum RaidElement
{
  Fire,
  Water,
  Wind,
  Electric,
  Iron,
}

public enum ChallengeAdmissionRule
{
  ElectricWeakToIron,
  Season40Explicit,
}

public enum ChallengeAdmissionOutcome
{
  Supported,
  ExcludedByPolicy,
  Unsupported,
  Unresolved,
}

public sealed class ChallengeAdmissionDecision
{
  internal ChallengeAdmissionDecision(
      int seasonNumber,
      RaidElement bossElement,
      RaidElement weaknessCode,
      ChallengeAdmissionOutcome outcome,
      ChallengeAdmissionRule? rule,
      string? reasonCode)
  {
    SeasonNumber = seasonNumber;
    BossElement = bossElement;
    WeaknessCode = weaknessCode;
    Outcome = outcome;
    Rule = rule;
    ReasonCode = reasonCode;
  }

  public string PolicyId => ChallengeBossSupportPolicy.PolicyId;

  public int SeasonNumber { get; }

  public RaidElement BossElement { get; }

  public RaidElement WeaknessCode { get; }

  public ChallengeAdmissionOutcome Outcome { get; }

  public ChallengeAdmissionRule? Rule { get; }

  public string? ReasonCode { get; }

  public bool IsSupported => Outcome == ChallengeAdmissionOutcome.Supported;
}

public static class ChallengeBossSupportPolicy
{
  public const string PolicyId = "challenge-boss-support/v1";

  private static readonly HashSet<int> ExcludedSeasons = [14, 39];

  public static ChallengeAdmissionDecision Evaluate(
      int seasonNumber,
      RaidElement bossElement,
      RaidElement weaknessCode,
      bool authoritativeChallengeChainResolved)
  {
    if (seasonNumber < 1)
    {
      throw new ArgumentOutOfRangeException(nameof(seasonNumber), "A season number must be positive.");
    }

    if (ExcludedSeasons.Contains(seasonNumber))
    {
      return new ChallengeAdmissionDecision(
          seasonNumber,
          bossElement,
          weaknessCode,
          ChallengeAdmissionOutcome.ExcludedByPolicy,
          null,
          "excluded_season");
    }

    if (!authoritativeChallengeChainResolved)
    {
      return new ChallengeAdmissionDecision(
          seasonNumber,
          bossElement,
          weaknessCode,
          ChallengeAdmissionOutcome.Unresolved,
          null,
          "authoritative_challenge_chain_unresolved");
    }

    if (seasonNumber == 40)
    {
      return new ChallengeAdmissionDecision(
          seasonNumber,
          bossElement,
          weaknessCode,
          ChallengeAdmissionOutcome.Supported,
          ChallengeAdmissionRule.Season40Explicit,
          null);
    }

    if (bossElement == RaidElement.Electric && weaknessCode == RaidElement.Iron)
    {
      return new ChallengeAdmissionDecision(
          seasonNumber,
          bossElement,
          weaknessCode,
          ChallengeAdmissionOutcome.Supported,
          ChallengeAdmissionRule.ElectricWeakToIron,
          null);
    }

    return new ChallengeAdmissionDecision(
        seasonNumber,
        bossElement,
        weaknessCode,
        ChallengeAdmissionOutcome.Unsupported,
        null,
        "element_weakness_not_supported");
  }
}
