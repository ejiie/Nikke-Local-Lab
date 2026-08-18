using System.Globalization;
using System.Text;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.RaidCatalog;

public static class ChallengeRaidCandidateCanonicalizer
{
  public const string ContractId = "nll/challenge-raid-candidate/v2";

  public static Sha256Digest ComputeHash(
      IEnumerable<NormalizedChallengeRaidCandidate> candidates)
  {
    ArgumentNullException.ThrowIfNull(candidates);
    return Sha256Digest.ComputeUtf8(ToCanonicalText(candidates));
  }

  public static string ToCanonicalText(
      IEnumerable<NormalizedChallengeRaidCandidate> candidates)
  {
    ArgumentNullException.ThrowIfNull(candidates);
    var ordered = candidates
        .Select(static candidate => candidate ??
            throw new ArgumentException("A candidate collection cannot contain null entries.", nameof(candidates)))
        .OrderBy(static candidate => candidate.SeasonNumber)
        .ToArray();
    if (ordered.GroupBy(static candidate => candidate.SeasonNumber)
        .Any(static group => group.Count() != 1))
    {
      throw new ArgumentException("A candidate collection cannot contain duplicate seasons.", nameof(candidates));
    }

    var builder = new StringBuilder(ContractId)
        .Append('\n')
        .Append("count=")
        .Append(ordered.Length.ToString(CultureInfo.InvariantCulture));
    foreach (var candidate in ordered)
    {
      builder.Append('\n').Append("season=")
          .Append(candidate.SeasonNumber.ToString(CultureInfo.InvariantCulture));
      Append(builder, "admission", candidate.AdmissionRuleCode);
      Append(builder, "readiness", candidate.Readiness switch
      {
        ChallengeCandidateReadiness.Ready => "ready",
        ChallengeCandidateReadiness.Incomplete => "incomplete",
        _ => throw new ArgumentOutOfRangeException(nameof(candidates))
      });
      Append(builder, "affinity.element", candidate.Affinity?.Element ?? "unresolved");
      Append(builder, "affinity.weakness", candidate.Affinity?.Weakness ?? "unresolved");
      Append(
          builder,
          "behavior-variant-count",
          candidate.SpotBehaviorVariantCount.ToString(CultureInfo.InvariantCulture));
      Append(
          builder,
          "monster-skill-relation-count",
          candidate.MonsterSkillRelationCount?.ToString(CultureInfo.InvariantCulture) ?? "unresolved");
      Append(builder, "part-topology-closed", Boolean(candidate.HasClosedPartTopology));

      var parts = candidate.Parts
          .OrderBy(static part => part.Ordinal)
          .ToArray();
      Append(builder, "part-count", parts.Length.ToString(CultureInfo.InvariantCulture));
      for (var index = 0; index < parts.Length; index++)
      {
        Append(
            builder,
            $"part.{index.ToString(CultureInfo.InvariantCulture)}",
            PartTuple(parts[index]));
      }

      var evidence = candidate.Evidence;
      Append(builder, "evidence.static-data", evidence.StaticDataArchiveSha256.ToString());
      Append(builder, "evidence.tier", ChallengeEvidenceCodes.TierCode(evidence.Tier));
      Append(
          builder,
          "evidence.runtime-relation",
          ChallengeEvidenceCodes.RuntimeRelationCode(evidence.RuntimeRelation));
      Append(builder, "evidence.behavior", ArtifactTuple(evidence.Behavior));

      var timelines = evidence.Timelines
          .OrderBy(static timeline => timeline.Sha256.Hex, StringComparer.Ordinal)
          .ToArray();
      Append(builder, "evidence.timeline-count", timelines.Length.ToString(CultureInfo.InvariantCulture));
      for (var index = 0; index < timelines.Length; index++)
      {
        Append(
            builder,
            $"evidence.timeline.{index.ToString(CultureInfo.InvariantCulture)}",
            TimelineTuple(timelines[index]));
      }

      var bundles = evidence.AssetBundles
          .OrderBy(static bundle => bundle.Sha256.Hex, StringComparer.Ordinal)
          .ToArray();
      Append(builder, "evidence.bundle-count", bundles.Length.ToString(CultureInfo.InvariantCulture));
      for (var index = 0; index < bundles.Length; index++)
      {
        Append(
            builder,
            $"evidence.bundle.{index.ToString(CultureInfo.InvariantCulture)}",
            BundleTuple(bundles[index]));
      }

      Append(
          builder,
          "evidence.asset-bundle-set",
          evidence.AssetBundleSetSha256?.ToString() ?? "unresolved");
      Append(builder, "evidence.runtime", RuntimeTuple(evidence.Runtime));

      foreach (var claim in evidence.Timing.ClockBases
                   .OrderBy(static claim => ChallengeEvidenceCodes.ClockBasisCode(claim.Basis), StringComparer.Ordinal))
      {
        Append(
            builder,
            $"evidence.timing.clock.{ChallengeEvidenceCodes.ClockBasisCode(claim.Basis)}",
            ClaimTuple(claim.Resolution, claim.EvidenceObjectSha256, claim.ReasonCode));
      }

      Append(
          builder,
          "evidence.timing.scheduler",
          string.Join(
              ':',
              ClaimTuple(
                  evidence.Timing.Scheduler.Resolution,
                  evidence.Timing.Scheduler.EvidenceObjectSha256,
                  evidence.Timing.Scheduler.ReasonCode),
              string.Join(
                  ',',
                  evidence.Timing.Scheduler.RelatedClockBases
                      .Select(ChallengeEvidenceCodes.ClockBasisCode)
                      .OrderBy(static value => value, StringComparer.Ordinal))));

      var warnings = evidence.WarningCodes.OrderBy(static value => value, StringComparer.Ordinal).ToArray();
      Append(builder, "evidence.warning-count", warnings.Length.ToString(CultureInfo.InvariantCulture));
      for (var index = 0; index < warnings.Length; index++)
      {
        Append(builder, $"evidence.warning.{index.ToString(CultureInfo.InvariantCulture)}", warnings[index]);
      }
    }

    return builder.ToString();
  }

  private static string PartTuple(NormalizedRaidPart part) => string.Join(
      ':',
      part.Ordinal.ToString(CultureInfo.InvariantCulture),
      part.TypeCode,
      part.DamageHpRatio.ToString(CultureInfo.InvariantCulture),
      part.HpRatio.ToString(CultureInfo.InvariantCulture),
      part.DefenceRatio.ToString(CultureInfo.InvariantCulture),
      part.EnergyResistRatio.ToString(CultureInfo.InvariantCulture),
      part.MetalResistRatio.ToString(CultureInfo.InvariantCulture),
      part.BioResistRatio.ToString(CultureInfo.InvariantCulture),
      part.AttackRatio.ToString(CultureInfo.InvariantCulture),
      Boolean(part.IsMainPart),
      Boolean(part.IsDamageable),
      Boolean(part.IsHpVisible),
      part.LinkedPartOrdinal?.ToString(CultureInfo.InvariantCulture) ?? "none");

  private static string ArtifactTuple(ChallengeArtifactEvidence? artifact) => artifact is null
      ? "unresolved"
      : $"{artifact.Sha256}:{artifact.ByteLength.ToString(CultureInfo.InvariantCulture)}";

  private static string TimelineTuple(ChallengeTimelineEvidence timeline) => string.Join(
      ':',
      timeline.Sha256,
      timeline.ByteLength.ToString(CultureInfo.InvariantCulture),
      string.Join(
          ',',
          timeline.ClockBases.Select(ChallengeEvidenceCodes.ClockBasisCode)
              .OrderBy(static value => value, StringComparer.Ordinal)));

  private static string BundleTuple(ChallengeAssetBundleEvidence bundle) => string.Join(
      ':',
      bundle.Sha256,
      bundle.ByteLength.ToString(CultureInfo.InvariantCulture),
      string.Join(
          ',',
          bundle.Roles.Select(ChallengeEvidenceCodes.BundleRoleCode)
              .OrderBy(static value => value, StringComparer.Ordinal)));

  private static string RuntimeTuple(ChallengeRuntimeArtifactEvidence? runtime) => runtime is null
      ? "unresolved"
      : string.Join(
          ':',
          runtime.Sha256,
          runtime.ByteLength.ToString(CultureInfo.InvariantCulture),
          runtime.LocalBuildLabel);

  private static string ClaimTuple(
      TimingEvidenceResolution resolution,
      IReadOnlyList<Sha256Digest> evidence,
      string? reasonCode) => string.Join(
      ':',
      ChallengeEvidenceCodes.TimingResolutionCode(resolution),
      evidence.Count == 0
          ? "none"
          : string.Join(',', evidence.Select(static digest => digest.ToString())
              .OrderBy(static value => value, StringComparer.Ordinal)),
      reasonCode ?? "none");

  private static string Boolean(bool value) => value ? "true" : "false";

  private static void Append(StringBuilder builder, string key, string value) =>
      builder.Append('\n').Append(key).Append('=').Append(value);
}
