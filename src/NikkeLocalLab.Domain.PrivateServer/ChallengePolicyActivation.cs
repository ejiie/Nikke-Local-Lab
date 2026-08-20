using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public sealed class ChallengeOperationalPolicyActivationRevision
{
  private ChallengeOperationalPolicyActivationRevision(
      EntityUid activationUid,
      EntityUid activationRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid policyUid,
      Sha256Digest policyContentSha256,
      RaidDayKey effectiveRaidDayKey,
      DateTimeOffset materializedAtUtc)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    ActivationUid = PrivateServerGuard.RequireUid(activationUid, nameof(activationUid));
    ActivationRevisionUid = PrivateServerGuard.RequireUid(
        activationRevisionUid,
        nameof(activationRevisionUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    PolicyUid = PrivateServerGuard.RequireUid(policyUid, nameof(policyUid));
    PolicyContentSha256 = PrivateServerGuard.RequireDigest(
        policyContentSha256,
        nameof(policyContentSha256));
    EffectiveRaidDayKey = effectiveRaidDayKey;
    MaterializedAtUtc = PrivateServerGuard.NormalizeUtc(
        materializedAtUtc,
        nameof(materializedAtUtc));
    ContentSha256 = PrivateServerHash.Compute("nll/challenge-policy-activation/v1", hash =>
    {
      PrivateServerHash.Append(hash, PolicyUid);
      PrivateServerHash.Append(hash, PolicyContentSha256);
      PrivateServerHash.Append(hash, EffectiveRaidDayKey.Value);
    });
  }

  public EntityUid ActivationUid { get; }

  public EntityUid ActivationRevisionUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public EntityUid PolicyUid { get; }

  public Sha256Digest PolicyContentSha256 { get; }

  public RaidDayKey EffectiveRaidDayKey { get; }

  public DateTimeOffset MaterializedAtUtc { get; }

  public Sha256Digest ContentSha256 { get; }

  public static ChallengeOperationalPolicyActivationRevision CreateInitial(
      EntityUid activationUid,
      EntityUid activationRevisionUid,
      ChallengeOperationalPolicy policy,
      RaidDayKey effectiveRaidDayKey,
      DateTimeOffset materializedAtUtc,
      RaidDayKey observedRaidDayKey,
      int currentDayConsumedEntries,
      int currentActiveRunCount)
  {
    ArgumentNullException.ThrowIfNull(policy);
    RequireCanCreateInitial(
        effectiveRaidDayKey,
        observedRaidDayKey,
        currentDayConsumedEntries,
        currentActiveRunCount);
    return new ChallengeOperationalPolicyActivationRevision(
        activationUid,
        activationRevisionUid,
        1,
        null,
        policy.PolicyUid,
        policy.ContentSha256,
        effectiveRaidDayKey,
        materializedAtUtc);
  }

  public static ChallengeOperationalPolicyActivationRevision Restore(
      EntityUid activationUid,
      EntityUid activationRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid policyUid,
      Sha256Digest policyContentSha256,
      RaidDayKey effectiveRaidDayKey,
      DateTimeOffset materializedAtUtc) =>
      new(
          activationUid,
          activationRevisionUid,
          revisionNumber,
          predecessorRevisionUid,
          policyUid,
          policyContentSha256,
          effectiveRaidDayKey,
          materializedAtUtc);

  public ChallengeOperationalPolicyActivationRevision Activate(
      EntityUid nextRevisionUid,
      ChallengeOperationalPolicy policy,
      RaidDayKey effectiveRaidDayKey,
      DateTimeOffset materializedAtUtc,
      RaidDayKey observedRaidDayKey)
  {
    ArgumentNullException.ThrowIfNull(policy);
    if (effectiveRaidDayKey.CompareTo(observedRaidDayKey) <= 0 ||
        effectiveRaidDayKey.CompareTo(EffectiveRaidDayKey) < 0)
    {
      throw new PrivateServerIntegrityException("challenge_policy_activation_requires_future_day");
    }
    if (policy.PolicyUid == PolicyUid && policy.ContentSha256 == PolicyContentSha256 &&
        effectiveRaidDayKey == EffectiveRaidDayKey)
    {
      return this;
    }

    return new ChallengeOperationalPolicyActivationRevision(
        ActivationUid,
        nextRevisionUid,
        RevisionNumber + 1,
        ActivationRevisionUid,
        policy.PolicyUid,
        policy.ContentSha256,
        effectiveRaidDayKey,
        materializedAtUtc);
  }

  private static void RequireCanCreateInitial(
      RaidDayKey effectiveRaidDayKey,
      RaidDayKey observedRaidDayKey,
      int currentDayConsumedEntries,
      int currentActiveRunCount)
  {
    if (currentDayConsumedEntries != 0 || currentActiveRunCount != 0 ||
        effectiveRaidDayKey != observedRaidDayKey)
    {
      throw new PrivateServerIntegrityException("challenge_policy_activation_invalid");
    }

  }
}
