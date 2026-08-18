using System.Globalization;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

public static class RaidSnapshotCanonicalizer
{
  public const string ContractId = "nll/raid-snapshot/v2";

  public static string ToCanonicalText(RaidSnapshot snapshot)
  {
    ArgumentNullException.ThrowIfNull(snapshot);
    var lines = new List<string>(64)
    {
      ContractId,
      $"dataset-snapshot-uid={snapshot.DatasetSnapshotUid}",
      $"challenge-encounter-uid={snapshot.ChallengeEncounterUid}",
      $"boss-variant-uid={snapshot.BossVariantUid}",
      $"compatibility-map-uid={snapshot.CompatibilityMapUid}",
      $"season-number={snapshot.SeasonNumber.ToString(CultureInfo.InvariantCulture)}",
      $"mode={RaidSnapshot.Mode}",
      $"challenge.difficulty-type={RaidSnapshot.ChallengeDifficultyType.ToString(CultureInfo.InvariantCulture)}",
      $"challenge.wave-order={RaidSnapshot.ChallengeWaveOrder.ToString(CultureInfo.InvariantCulture)}",
      $"admission.policy-id={snapshot.Admission.PolicyId}",
      $"admission.rule={RaidCanonicalCodes.AdmissionRule(snapshot.Admission.Rule!.Value)}",
      $"admission.boss-element={RaidCanonicalCodes.Element(snapshot.Admission.BossElement)}",
      $"admission.weakness-code={RaidCanonicalCodes.Element(snapshot.Admission.WeaknessCode)}",
      "admission.status=supported",
      $"static-relations.part-count={snapshot.StaticRelations.Parts.Count.ToString(CultureInfo.InvariantCulture)}",
    };

    for (var index = 0; index < snapshot.StaticRelations.Parts.Count; index++)
    {
      lines.Add(
          $"static-relations.part.{index.ToString(CultureInfo.InvariantCulture)}=" +
          snapshot.StaticRelations.Parts[index].ToCanonicalTuple());
    }

    lines.Add(
        $"static-relations.skill-count={snapshot.StaticRelations.Skills.Count.ToString(CultureInfo.InvariantCulture)}");
    for (var index = 0; index < snapshot.StaticRelations.Skills.Count; index++)
    {
      lines.Add(
          $"static-relations.skill.{index.ToString(CultureInfo.InvariantCulture)}=" +
          snapshot.StaticRelations.Skills[index].ToCanonicalTuple());
    }

    lines.Add($"provenance.static-data={Artifact(snapshot.Provenance.StaticData)}");
    lines.Add(
        "provenance.asset-bundle-set-sha256=" +
        (snapshot.Provenance.AssetBundleSetSha256?.ToString() ?? "unresolved"));

    for (var index = 0; index < snapshot.Provenance.SelectedAssetBundles.Count; index++)
    {
      var bundle = snapshot.Provenance.SelectedAssetBundles[index];
      lines.Add(
          $"provenance.asset-bundle.{index.ToString(CultureInfo.InvariantCulture)}=" +
          $"{bundle.ArtifactUid}\t{bundle.Sha256}\t" +
          string.Join(',', bundle.Roles.Select(RaidCanonicalCodes.AssetBundleRole)));
    }

    lines.Add(snapshot.Provenance.Behavior is null
        ? "provenance.behavior=unresolved"
        : $"provenance.behavior={Artifact(snapshot.Provenance.Behavior)}");
    for (var index = 0; index < snapshot.Provenance.Timelines.Count; index++)
    {
      var timeline = snapshot.Provenance.Timelines[index];
      lines.Add(
          $"provenance.timeline.{index.ToString(CultureInfo.InvariantCulture)}=" +
          $"{Artifact(timeline.Artifact)}\t" +
          string.Join(',', timeline.ClockBases.Select(RaidCanonicalCodes.ClockBasis)));
    }

    lines.Add(snapshot.Provenance.ClientRuntime.IsResolved
        ? $"provenance.client-runtime={snapshot.Provenance.ClientRuntime.BuildUid}\t" +
          $"{snapshot.Provenance.ClientRuntime.LocalBuildLabel}\t{snapshot.Provenance.ClientRuntime.Sha256}"
        : "provenance.client-runtime=unresolved");

    foreach (var clock in snapshot.Provenance.Timing.ClockBases)
    {
      var prefix = $"provenance.timing.clock.{RaidCanonicalCodes.ClockBasis(clock.Basis)}";
      lines.Add($"{prefix}.resolution={RaidCanonicalCodes.TimingResolution(clock.Resolution)}");
      if (clock.Resolution == TimingEvidenceResolution.Unresolved)
      {
        lines.Add($"{prefix}.reason={clock.ReasonCode}");
      }
      else
      {
        AppendArtifacts(lines, $"{prefix}.evidence", clock.EvidenceArtifacts);
      }
    }

    var scheduler = snapshot.Provenance.Timing.Scheduler;
    lines.Add(
        $"provenance.timing.scheduler.resolution={RaidCanonicalCodes.TimingResolution(scheduler.Resolution)}");
    lines.Add(
        "provenance.timing.scheduler.clock-bases=" +
        string.Join(',', scheduler.RelatedClockBases.Select(RaidCanonicalCodes.ClockBasis)));
    if (scheduler.Resolution == TimingEvidenceResolution.Unresolved)
    {
      lines.Add($"provenance.timing.scheduler.reason={scheduler.ReasonCode}");
    }
    else
    {
      AppendArtifacts(lines, "provenance.timing.scheduler.evidence", scheduler.EvidenceArtifacts);
    }

    lines.Add($"compatibility.tier={RaidCanonicalCodes.CompatibilityTier(snapshot.Compatibility.Tier)}");
    lines.Add(
        $"compatibility.runtime-relation={RaidCanonicalCodes.RuntimeRelation(snapshot.Compatibility.RuntimeRelation)}");
    AppendCodes(lines, "compatibility.warning", snapshot.Compatibility.EvidenceWarningCodes);
    lines.Add("readiness.status=ready");
    AppendCodes(lines, "readiness.warning", snapshot.ReadinessWarningCodes);

    return string.Join('\n', lines);
  }

  public static Sha256Digest ComputeContentHash(RaidSnapshot snapshot) =>
      Sha256Digest.ComputeUtf8(ToCanonicalText(snapshot));

  private static string Artifact(RaidArtifactReference artifact) =>
      $"{artifact.ArtifactUid}\t{artifact.Sha256}";

  private static void AppendArtifacts(
      ICollection<string> lines,
      string prefix,
      IReadOnlyList<RaidArtifactReference> artifacts)
  {
    for (var index = 0; index < artifacts.Count; index++)
    {
      lines.Add($"{prefix}.{index.ToString(CultureInfo.InvariantCulture)}={Artifact(artifacts[index])}");
    }
  }

  private static void AppendCodes(
      ICollection<string> lines,
      string prefix,
      IReadOnlyList<string> codes)
  {
    for (var index = 0; index < codes.Count; index++)
    {
      lines.Add($"{prefix}.{index.ToString(CultureInfo.InvariantCulture)}={codes[index]}");
    }
  }
}

internal static class RaidCanonicalCodes
{
  public static string Element(RaidElement value) => value switch
  {
    RaidElement.Fire => "fire",
    RaidElement.Water => "water",
    RaidElement.Wind => "wind",
    RaidElement.Electric => "electric",
    RaidElement.Iron => "iron",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string AdmissionRule(ChallengeAdmissionRule value) => value switch
  {
    ChallengeAdmissionRule.ElectricWeakToIron => "electric_weak_to_iron",
    ChallengeAdmissionRule.Season40Explicit => "season_40_explicit",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string AssetBundleRole(AssetBundleRole value) => value switch
  {
    Domain.Raid.AssetBundleRole.Stage => "stage",
    Domain.Raid.AssetBundleRole.Model => "model",
    Domain.Raid.AssetBundleRole.Behavior => "behavior",
    Domain.Raid.AssetBundleRole.Timeline => "timeline",
    Domain.Raid.AssetBundleRole.Animation => "animation",
    Domain.Raid.AssetBundleRole.Audio => "audio",
    Domain.Raid.AssetBundleRole.Other => "other",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string ClockBasis(ClockBasis value) => value switch
  {
    Domain.Raid.ClockBasis.BehaviorTick => "behavior_tick",
    Domain.Raid.ClockBasis.RenderFrame => "render_frame",
    Domain.Raid.ClockBasis.FixedUpdate => "fixed_update",
    Domain.Raid.ClockBasis.WallClock => "wall_clock",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string TimingResolution(TimingEvidenceResolution value) => value switch
  {
    TimingEvidenceResolution.Unresolved => "unresolved",
    TimingEvidenceResolution.StaticAnalysis => "static_analysis",
    TimingEvidenceResolution.RuntimeTrace => "runtime_trace",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string CompatibilityTier(RaidCompatibilityTier value) => value switch
  {
    RaidCompatibilityTier.StaticExact => "static_exact",
    RaidCompatibilityTier.BehaviorExact => "behavior_exact",
    RaidCompatibilityTier.AssetExactRuntimeCurrent => "asset_exact_runtime_current",
    RaidCompatibilityTier.HistoricalRuntimeExact => "historical_runtime_exact",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };

  public static string RuntimeRelation(RuntimeRelation value) => value switch
  {
    Domain.Raid.RuntimeRelation.NotEvaluated => "not_evaluated",
    Domain.Raid.RuntimeRelation.CurrentRuntimeMatch => "current_runtime_match",
    Domain.Raid.RuntimeRelation.HistoricalRuntimeMatch => "historical_runtime_match",
    _ => throw new ArgumentOutOfRangeException(nameof(value)),
  };
}
