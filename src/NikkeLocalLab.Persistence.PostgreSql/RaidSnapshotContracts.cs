using System.Globalization;
using System.Text;
using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class RaidSnapshotIntegrityException : Exception
{
  public RaidSnapshotIntegrityException(string code)
      : base(code)
  {
    Code = ControlledCode.Require(code, nameof(code));
  }

  public string Code { get; }
}

public sealed record RaidEvidenceArtifactPublication
{
  public RaidEvidenceArtifactPublication(Sha256Digest sha256, long byteLength)
  {
    if (sha256 == default)
    {
      throw new RaidSnapshotIntegrityException("raid_artifact_digest_invalid");
    }

    if (byteLength < 0)
    {
      throw new RaidSnapshotIntegrityException("raid_artifact_length_invalid");
    }

    Sha256 = sha256;
    ByteLength = byteLength;
  }

  public Sha256Digest Sha256 { get; }

  public long ByteLength { get; }
}

public sealed record RaidClientRuntimePublication
{
  public RaidClientRuntimePublication(
      RaidEvidenceArtifactPublication artifact,
      string localBuildLabel)
  {
    Artifact = artifact ?? throw new ArgumentNullException(nameof(artifact));
    LocalBuildLabel = ControlledCode.Require(localBuildLabel, nameof(localBuildLabel));
  }

  public RaidEvidenceArtifactPublication Artifact { get; }

  public string LocalBuildLabel { get; }
}

public sealed record RaidAssetBundlePublication
{
  public RaidAssetBundlePublication(
      RaidEvidenceArtifactPublication artifact,
      IEnumerable<AssetBundleRole> roles)
  {
    Artifact = artifact ?? throw new ArgumentNullException(nameof(artifact));
    ArgumentNullException.ThrowIfNull(roles);
    var normalized = roles.Distinct().OrderBy(ToCode, StringComparer.Ordinal).ToArray();
    if (normalized.Length == 0)
    {
      throw new RaidSnapshotIntegrityException("raid_bundle_role_missing");
    }

    Roles = Array.AsReadOnly(normalized);
  }

  public RaidEvidenceArtifactPublication Artifact { get; }

  public IReadOnlyList<AssetBundleRole> Roles { get; }

  internal static string ToCode(AssetBundleRole value) => value switch
  {
    AssetBundleRole.Stage => "stage",
    AssetBundleRole.Model => "model",
    AssetBundleRole.Behavior => "behavior",
    AssetBundleRole.Timeline => "timeline",
    AssetBundleRole.Animation => "animation",
    AssetBundleRole.Audio => "audio",
    AssetBundleRole.Other => "other",
    _ => throw new RaidSnapshotIntegrityException("raid_bundle_role_invalid")
  };
}

public sealed record RaidTimelinePublication
{
  public RaidTimelinePublication(
      RaidEvidenceArtifactPublication artifact,
      IEnumerable<ClockBasis> clockBases)
  {
    Artifact = artifact ?? throw new ArgumentNullException(nameof(artifact));
    ArgumentNullException.ThrowIfNull(clockBases);
    var normalized = clockBases.Distinct().OrderBy(RaidPublicationCodes.ClockBasis, StringComparer.Ordinal).ToArray();
    if (normalized.Length == 0)
    {
      throw new RaidSnapshotIntegrityException("raid_timeline_clock_missing");
    }

    ClockBases = Array.AsReadOnly(normalized);
  }

  public RaidEvidenceArtifactPublication Artifact { get; }

  public IReadOnlyList<ClockBasis> ClockBases { get; }
}

public sealed record RaidStaticPartPublication
{
  public RaidStaticPartPublication(
      int ordinal,
      string typeCode,
      int damageHpRatio,
      int hpRatio,
      int defenceRatio,
      int energyResistRatio,
      int metalResistRatio,
      int bioResistRatio,
      int attackRatio,
      bool isMainPart,
      bool isDamageable,
      bool isHpVisible,
      int? linkedPartOrdinal = null)
  {
    if (ordinal < 0 || linkedPartOrdinal < 0 || linkedPartOrdinal == ordinal ||
        damageHpRatio < 0 || hpRatio < 0 || defenceRatio < 0 ||
        energyResistRatio < 0 || metalResistRatio < 0 || bioResistRatio < 0 ||
        attackRatio < 0)
    {
      throw new RaidSnapshotIntegrityException("raid_part_shape_invalid");
    }

    Ordinal = ordinal;
    TypeCode = ControlledCode.Require(typeCode, nameof(typeCode));
    DamageHpRatio = damageHpRatio;
    HpRatio = hpRatio;
    DefenceRatio = defenceRatio;
    EnergyResistRatio = energyResistRatio;
    MetalResistRatio = metalResistRatio;
    BioResistRatio = bioResistRatio;
    AttackRatio = attackRatio;
    IsMainPart = isMainPart;
    IsDamageable = isDamageable;
    IsHpVisible = isHpVisible;
    LinkedPartOrdinal = linkedPartOrdinal;
  }

  public int Ordinal { get; }

  public string TypeCode { get; }

  public int DamageHpRatio { get; }

  public int HpRatio { get; }

  public int DefenceRatio { get; }

  public int EnergyResistRatio { get; }

  public int MetalResistRatio { get; }

  public int BioResistRatio { get; }

  public int AttackRatio { get; }

  public bool IsMainPart { get; }

  public bool IsDamageable { get; }

  public bool IsHpVisible { get; }

  public int? LinkedPartOrdinal { get; }
}

public sealed record RaidStaticSkillPublication
{
  public RaidStaticSkillPublication(int ordinal, string roleCode)
  {
    if (ordinal < 0)
    {
      throw new RaidSnapshotIntegrityException("raid_skill_shape_invalid");
    }

    Ordinal = ordinal;
    RoleCode = ControlledCode.Require(roleCode, nameof(roleCode));
  }

  public int Ordinal { get; }

  public string RoleCode { get; }
}

public sealed record RaidClockEvidencePublication
{
  public RaidClockEvidencePublication(
      ClockBasis clockBasis,
      TimingEvidenceResolution resolution,
      IEnumerable<RaidEvidenceArtifactPublication>? evidenceArtifacts = null,
      string? reasonCode = null)
  {
    var artifacts = (evidenceArtifacts ?? []).ToArray();
    if (artifacts.Any(static artifact => artifact is null) ||
        artifacts.GroupBy(static artifact => artifact.Sha256).Any(static group => group.Count() != 1))
    {
      throw new RaidSnapshotIntegrityException("raid_timing_evidence_invalid");
    }

    if ((resolution == TimingEvidenceResolution.Unresolved &&
         (artifacts.Length != 0 || reasonCode is null)) ||
        (resolution != TimingEvidenceResolution.Unresolved &&
         (artifacts.Length == 0 || reasonCode is not null)))
    {
      throw new RaidSnapshotIntegrityException("raid_timing_evidence_invalid");
    }

    ClockBasis = clockBasis;
    Resolution = resolution;
    EvidenceArtifacts = Array.AsReadOnly(artifacts
        .OrderBy(static artifact => artifact.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());
    ReasonCode = reasonCode is null ? null : ControlledCode.Require(reasonCode, nameof(reasonCode));
  }

  public ClockBasis ClockBasis { get; }

  public TimingEvidenceResolution Resolution { get; }

  public IReadOnlyList<RaidEvidenceArtifactPublication> EvidenceArtifacts { get; }

  public string? ReasonCode { get; }
}

public sealed record RaidSchedulerEvidencePublication
{
  public RaidSchedulerEvidencePublication(
      TimingEvidenceResolution resolution,
      IEnumerable<ClockBasis> relatedClockBases,
      IEnumerable<RaidEvidenceArtifactPublication>? evidenceArtifacts = null,
      string? reasonCode = null)
  {
    ArgumentNullException.ThrowIfNull(relatedClockBases);
    var clockBases = relatedClockBases
        .Distinct()
        .OrderBy(RaidPublicationCodes.ClockBasis, StringComparer.Ordinal)
        .ToArray();
    var artifacts = (evidenceArtifacts ?? []).ToArray();
    if (clockBases.Length < 2 ||
        artifacts.Any(static artifact => artifact is null) ||
        artifacts.GroupBy(static artifact => artifact.Sha256).Any(static group => group.Count() != 1) ||
        (resolution == TimingEvidenceResolution.Unresolved &&
         (artifacts.Length != 0 || reasonCode is null)) ||
        (resolution != TimingEvidenceResolution.Unresolved &&
         (artifacts.Length == 0 || reasonCode is not null)))
    {
      throw new RaidSnapshotIntegrityException("raid_scheduler_evidence_invalid");
    }

    Resolution = resolution;
    RelatedClockBases = Array.AsReadOnly(clockBases);
    EvidenceArtifacts = Array.AsReadOnly(artifacts
        .OrderBy(static artifact => artifact.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());
    ReasonCode = reasonCode is null ? null : ControlledCode.Require(reasonCode, nameof(reasonCode));
  }

  public TimingEvidenceResolution Resolution { get; }

  public IReadOnlyList<ClockBasis> RelatedClockBases { get; }

  public IReadOnlyList<RaidEvidenceArtifactPublication> EvidenceArtifacts { get; }

  public string? ReasonCode { get; }
}

public sealed record RaidSnapshotPublication
{
  public RaidSnapshotPublication(
      int seasonNumber,
      RaidElement bossElement,
      RaidElement weaknessCode,
      RaidEvidenceArtifactPublication staticData,
      IEnumerable<RaidStaticPartPublication> parts,
      IEnumerable<RaidStaticSkillPublication> skills,
      RaidCompatibilityTier compatibilityTier,
      RuntimeRelation runtimeRelation,
      RaidEvidenceArtifactPublication? behavior = null,
      IEnumerable<RaidAssetBundlePublication>? selectedAssetBundles = null,
      IEnumerable<RaidTimelinePublication>? timelines = null,
      RaidClientRuntimePublication? clientRuntime = null,
      IEnumerable<RaidClockEvidencePublication>? clockEvidence = null,
      RaidSchedulerEvidencePublication? schedulerEvidence = null,
      IEnumerable<string>? evidenceWarningCodes = null,
      IEnumerable<string>? readinessWarningCodes = null)
  {
    if (seasonNumber < 1)
    {
      throw new RaidSnapshotIntegrityException("raid_season_invalid");
    }

    StaticData = staticData ?? throw new ArgumentNullException(nameof(staticData));
    Parts = NormalizeOrdinals(parts, static part => part.Ordinal, "raid_part_set_invalid");
    if (Parts.Any(part => part.LinkedPartOrdinal is { } linked &&
            Parts.All(candidate => candidate.Ordinal != linked)))
    {
      throw new RaidSnapshotIntegrityException("raid_part_link_invalid");
    }

    Skills = NormalizeOrdinals(skills, static skill => skill.Ordinal, "raid_skill_set_invalid");

    var bundles = (selectedAssetBundles ?? []).ToArray();
    var timelineArray = (timelines ?? []).ToArray();
    if (bundles.Any(static bundle => bundle is null) ||
        bundles.GroupBy(static bundle => bundle.Artifact.Sha256).Any(static group => group.Count() != 1) ||
        timelineArray.Any(static timeline => timeline is null) ||
        timelineArray.GroupBy(static timeline => timeline.Artifact.Sha256).Any(static group => group.Count() != 1))
    {
      throw new RaidSnapshotIntegrityException("raid_evidence_set_invalid");
    }

    SelectedAssetBundles = Array.AsReadOnly(bundles
        .OrderBy(static bundle => bundle.Artifact.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());
    Timelines = Array.AsReadOnly(timelineArray
        .OrderBy(static timeline => timeline.Artifact.Sha256.Hex, StringComparer.Ordinal)
        .ToArray());

    var clocks = (clockEvidence ?? []).ToArray();
    var normalizedScheduler = schedulerEvidence;
    if (clocks.Length == 0 && normalizedScheduler is null)
    {
      clocks = Enum.GetValues<ClockBasis>()
          .Select(static basis => new RaidClockEvidencePublication(
              basis,
              TimingEvidenceResolution.Unresolved,
              reasonCode: "timing_not_evaluated"))
          .ToArray();
      normalizedScheduler = new RaidSchedulerEvidencePublication(
          TimingEvidenceResolution.Unresolved,
          Enum.GetValues<ClockBasis>(),
          reasonCode: "timing_not_evaluated");
    }

    if (clocks.Length != Enum.GetValues<ClockBasis>().Length ||
        clocks.GroupBy(static clock => clock.ClockBasis).Any(static group => group.Count() != 1))
    {
      throw new RaidSnapshotIntegrityException("raid_timing_clock_set_invalid");
    }

    ClockEvidence = Array.AsReadOnly(clocks
        .OrderBy(static clock => RaidPublicationCodes.ClockBasis(clock.ClockBasis), StringComparer.Ordinal)
        .ToArray());
    SchedulerEvidence = normalizedScheduler ??
        throw new RaidSnapshotIntegrityException("raid_timing_shape_invalid");
    if (SchedulerEvidence.RelatedClockBases.Any(basis =>
            ClockEvidence.All(clock => clock.ClockBasis != basis)))
    {
      throw new RaidSnapshotIntegrityException("raid_timing_shape_invalid");
    }

    var decision = ChallengeBossSupportPolicy.Evaluate(
        seasonNumber,
        bossElement,
        weaknessCode,
        authoritativeChallengeChainResolved: true);
    if (!decision.IsSupported)
    {
      throw new RaidSnapshotIntegrityException("raid_admission_invalid");
    }

    var evidenceWarnings = NormalizeCodes(evidenceWarningCodes);
    var readinessWarnings = NormalizeCodes(readinessWarningCodes);
    if (compatibilityTier == RaidCompatibilityTier.StaticExact && evidenceWarnings.Count == 0)
    {
      throw new RaidSnapshotIntegrityException("raid_static_warning_required");
    }

    if (compatibilityTier != RaidCompatibilityTier.StaticExact &&
        (behavior is null || SelectedAssetBundles.Count == 0))
    {
      throw new RaidSnapshotIntegrityException("raid_behavior_evidence_required");
    }

    if (compatibilityTier is RaidCompatibilityTier.AssetExactRuntimeCurrent or
        RaidCompatibilityTier.HistoricalRuntimeExact)
    {
      var expectedRelation = compatibilityTier == RaidCompatibilityTier.AssetExactRuntimeCurrent
          ? RuntimeRelation.CurrentRuntimeMatch
          : RuntimeRelation.HistoricalRuntimeMatch;
      if (clientRuntime is null || runtimeRelation != expectedRelation ||
          SchedulerEvidence.Resolution == TimingEvidenceResolution.Unresolved ||
          SchedulerEvidence.RelatedClockBases.Any(basis =>
              ClockEvidence.Single(clock => clock.ClockBasis == basis).Resolution ==
              TimingEvidenceResolution.Unresolved))
      {
        throw new RaidSnapshotIntegrityException("raid_runtime_evidence_required");
      }
    }
    else if (runtimeRelation != RuntimeRelation.NotEvaluated && clientRuntime is null)
    {
      throw new RaidSnapshotIntegrityException("raid_runtime_relation_invalid");
    }

    SeasonNumber = seasonNumber;
    BossElement = bossElement;
    WeaknessCode = weaknessCode;
    AdmissionRule = decision.Rule!.Value;
    Behavior = behavior;
    ClientRuntime = clientRuntime;
    CompatibilityTier = compatibilityTier;
    RuntimeRelation = runtimeRelation;
    EvidenceWarningCodes = evidenceWarnings;
    ReadinessWarningCodes = readinessWarnings;
  }

  public int SeasonNumber { get; }

  public RaidElement BossElement { get; }

  public RaidElement WeaknessCode { get; }

  public ChallengeAdmissionRule AdmissionRule { get; }

  public RaidEvidenceArtifactPublication StaticData { get; }

  public IReadOnlyList<RaidStaticPartPublication> Parts { get; }

  public IReadOnlyList<RaidStaticSkillPublication> Skills { get; }

  public RaidEvidenceArtifactPublication? Behavior { get; }

  public IReadOnlyList<RaidAssetBundlePublication> SelectedAssetBundles { get; }

  public IReadOnlyList<RaidTimelinePublication> Timelines { get; }

  public RaidClientRuntimePublication? ClientRuntime { get; }

  public IReadOnlyList<RaidClockEvidencePublication> ClockEvidence { get; }

  public RaidSchedulerEvidencePublication SchedulerEvidence { get; }

  public RaidCompatibilityTier CompatibilityTier { get; }

  public RuntimeRelation RuntimeRelation { get; }

  public IReadOnlyList<string> EvidenceWarningCodes { get; }

  public IReadOnlyList<string> ReadinessWarningCodes { get; }

  private static IReadOnlyList<T> NormalizeOrdinals<T>(
      IEnumerable<T> values,
      Func<T, int> ordinal,
      string errorCode)
  {
    ArgumentNullException.ThrowIfNull(values);
    var normalized = values.ToArray();
    if (normalized.Any(static value => value is null) ||
        !normalized.Select(ordinal).Order().SequenceEqual(Enumerable.Range(0, normalized.Length)))
    {
      throw new RaidSnapshotIntegrityException(errorCode);
    }

    return Array.AsReadOnly(normalized.OrderBy(ordinal).ToArray());
  }

  private static IReadOnlyList<string> NormalizeCodes(IEnumerable<string>? values) =>
      Array.AsReadOnly((values ?? [])
          .Select(value => ControlledCode.Require(value, nameof(values)))
          .Distinct(StringComparer.Ordinal)
          .OrderBy(static value => value, StringComparer.Ordinal)
          .ToArray());
}

public sealed record RaidCatalogImportDiagnosticPublication
{
  public RaidCatalogImportDiagnosticPublication(
      string diagnosticCode,
      int? seasonNumber,
      int occurrenceCount = 1)
  {
    if (seasonNumber < 1 || occurrenceCount < 1)
    {
      throw new RaidSnapshotIntegrityException("raid_diagnostic_invalid");
    }

    DiagnosticCode = ControlledCode.Require(diagnosticCode, nameof(diagnosticCode));
    SeasonNumber = seasonNumber;
    OccurrenceCount = occurrenceCount;
  }

  public string DiagnosticCode { get; }

  public int? SeasonNumber { get; }

  public int OccurrenceCount { get; }
}

public sealed record RaidCatalogPublication
{
  public RaidCatalogPublication(
      IEnumerable<RaidSnapshotPublication> snapshots,
      IEnumerable<RaidCatalogImportDiagnosticPublication>? diagnostics = null)
  {
    ArgumentNullException.ThrowIfNull(snapshots);
    var normalizedSnapshots = snapshots.ToArray();
    var normalizedDiagnostics = (diagnostics ?? []).ToArray();
    if (normalizedSnapshots.Length == 0 ||
        normalizedSnapshots.Any(static snapshot => snapshot is null) ||
        normalizedSnapshots.GroupBy(static snapshot => snapshot.SeasonNumber)
            .Any(static group => group.Count() != 1) ||
        normalizedDiagnostics.Any(static diagnostic => diagnostic is null))
    {
      throw new RaidSnapshotIntegrityException("raid_catalog_publication_invalid");
    }

    Snapshots = Array.AsReadOnly(normalizedSnapshots
        .OrderBy(static snapshot => snapshot.SeasonNumber)
        .ToArray());
    Diagnostics = Array.AsReadOnly(normalizedDiagnostics
        .OrderBy(static diagnostic => diagnostic.DiagnosticCode, StringComparer.Ordinal)
        .ThenBy(static diagnostic => diagnostic.SeasonNumber)
        .ToArray());
    CanonicalSha256 = Sha256Digest.ComputeUtf8(ToCanonicalText());
  }

  public IReadOnlyList<RaidSnapshotPublication> Snapshots { get; }

  public IReadOnlyList<RaidCatalogImportDiagnosticPublication> Diagnostics { get; }

  public Sha256Digest CanonicalSha256 { get; }

  private string ToCanonicalText()
  {
    var builder = new StringBuilder("nll/raid-catalog-publication/v1")
        .Append('\n').Append("snapshot-count=").Append(Snapshots.Count.ToString(CultureInfo.InvariantCulture));
    foreach (var snapshot in Snapshots)
    {
      Append(builder, "season", snapshot.SeasonNumber.ToString(CultureInfo.InvariantCulture));
      Append(builder, "element", RaidPublicationCodes.Element(snapshot.BossElement));
      Append(builder, "weakness", RaidPublicationCodes.Element(snapshot.WeaknessCode));
      Append(builder, "admission", RaidPublicationCodes.AdmissionRule(snapshot.AdmissionRule));
      Append(builder, "static", Artifact(snapshot.StaticData));
      Append(builder, "behavior", snapshot.Behavior is null ? "unresolved" : Artifact(snapshot.Behavior));
      Append(builder, "runtime", snapshot.ClientRuntime is null
          ? "unresolved"
          : $"{Artifact(snapshot.ClientRuntime.Artifact)}:{snapshot.ClientRuntime.LocalBuildLabel}");
      Append(builder, "tier", RaidPublicationCodes.CompatibilityTier(snapshot.CompatibilityTier));
      Append(builder, "runtime-relation", RaidPublicationCodes.RuntimeRelation(snapshot.RuntimeRelation));
      foreach (var part in snapshot.Parts)
      {
        Append(builder, $"part.{part.Ordinal.ToString(CultureInfo.InvariantCulture)}", string.Join(':',
            part.TypeCode,
            part.DamageHpRatio.ToString(CultureInfo.InvariantCulture),
            part.HpRatio.ToString(CultureInfo.InvariantCulture),
            part.DefenceRatio.ToString(CultureInfo.InvariantCulture),
            part.EnergyResistRatio.ToString(CultureInfo.InvariantCulture),
            part.MetalResistRatio.ToString(CultureInfo.InvariantCulture),
            part.BioResistRatio.ToString(CultureInfo.InvariantCulture),
            part.AttackRatio.ToString(CultureInfo.InvariantCulture),
            part.IsMainPart ? "true" : "false",
            part.IsDamageable ? "true" : "false",
            part.IsHpVisible ? "true" : "false",
            part.LinkedPartOrdinal?.ToString(CultureInfo.InvariantCulture) ?? "none"));
      }

      foreach (var skill in snapshot.Skills)
      {
        Append(builder, $"skill.{skill.Ordinal.ToString(CultureInfo.InvariantCulture)}", skill.RoleCode);
      }

      for (var index = 0; index < snapshot.SelectedAssetBundles.Count; index++)
      {
        var bundle = snapshot.SelectedAssetBundles[index];
        Append(builder, $"bundle.{index.ToString(CultureInfo.InvariantCulture)}",
            $"{Artifact(bundle.Artifact)}:{string.Join(',', bundle.Roles.Select(RaidAssetBundlePublication.ToCode))}");
      }

      for (var index = 0; index < snapshot.Timelines.Count; index++)
      {
        var timeline = snapshot.Timelines[index];
        Append(builder, $"timeline.{index.ToString(CultureInfo.InvariantCulture)}",
            $"{Artifact(timeline.Artifact)}:{string.Join(',', timeline.ClockBases.Select(RaidPublicationCodes.ClockBasis))}");
      }

      foreach (var clock in snapshot.ClockEvidence)
      {
        var prefix = $"clock.{RaidPublicationCodes.ClockBasis(clock.ClockBasis)}";
        Append(builder, prefix, RaidPublicationCodes.TimingResolution(clock.Resolution));
        Append(builder, $"{prefix}.reason", clock.ReasonCode ?? "none");
        for (var index = 0; index < clock.EvidenceArtifacts.Count; index++)
        {
          Append(builder, $"{prefix}.artifact.{index.ToString(CultureInfo.InvariantCulture)}",
              Artifact(clock.EvidenceArtifacts[index]));
        }
      }

      var scheduler = snapshot.SchedulerEvidence;
      Append(builder, "scheduler", RaidPublicationCodes.TimingResolution(scheduler.Resolution));
      Append(builder, "scheduler.reason", scheduler.ReasonCode ?? "none");
      Append(builder, "scheduler.clocks", string.Join(',',
          scheduler.RelatedClockBases.Select(RaidPublicationCodes.ClockBasis)));
      for (var index = 0; index < scheduler.EvidenceArtifacts.Count; index++)
      {
        Append(builder, $"scheduler.artifact.{index.ToString(CultureInfo.InvariantCulture)}",
            Artifact(scheduler.EvidenceArtifacts[index]));
      }

      for (var index = 0; index < snapshot.EvidenceWarningCodes.Count; index++)
      {
        Append(builder, $"evidence-warning.{index.ToString(CultureInfo.InvariantCulture)}",
            snapshot.EvidenceWarningCodes[index]);
      }

      for (var index = 0; index < snapshot.ReadinessWarningCodes.Count; index++)
      {
        Append(builder, $"readiness-warning.{index.ToString(CultureInfo.InvariantCulture)}",
            snapshot.ReadinessWarningCodes[index]);
      }
    }

    Append(builder, "diagnostic-count", Diagnostics.Count.ToString(CultureInfo.InvariantCulture));
    for (var index = 0; index < Diagnostics.Count; index++)
    {
      var diagnostic = Diagnostics[index];
      Append(builder, $"diagnostic.{index.ToString(CultureInfo.InvariantCulture)}", string.Join(':',
          diagnostic.DiagnosticCode,
          diagnostic.SeasonNumber?.ToString(CultureInfo.InvariantCulture) ?? "none",
          diagnostic.OccurrenceCount.ToString(CultureInfo.InvariantCulture)));
    }

    return builder.ToString();
  }

  private static string Artifact(RaidEvidenceArtifactPublication artifact) =>
      $"{artifact.Sha256}:{artifact.ByteLength.ToString(CultureInfo.InvariantCulture)}";

  private static void Append(StringBuilder builder, string key, string value) =>
      builder.Append('\n').Append(key).Append('=').Append(value);
}

public sealed record RaidSnapshotMemberReceipt(
    int Ordinal,
    int SeasonNumber,
    EntityUid RaidSnapshotUid,
    Sha256Digest ContentSha256);

public sealed record RaidCatalogImportReceipt(
    ImportReceipt Import,
    EntityUid RaidCatalogSnapshotUid,
    Sha256Digest CatalogManifestSha256,
    IReadOnlyList<RaidSnapshotMemberReceipt> Members);

internal static class RaidPublicationCodes
{
  public static string Element(RaidElement value) => value switch
  {
    RaidElement.Fire => "fire",
    RaidElement.Water => "water",
    RaidElement.Wind => "wind",
    RaidElement.Electric => "electric",
    RaidElement.Iron => "iron",
    _ => throw new RaidSnapshotIntegrityException("raid_element_invalid")
  };

  public static string AdmissionRule(ChallengeAdmissionRule value) => value switch
  {
    ChallengeAdmissionRule.ElectricWeakToIron => "electric_weak_to_iron",
    ChallengeAdmissionRule.Season40Explicit => "season_40_explicit",
    _ => throw new RaidSnapshotIntegrityException("raid_admission_rule_invalid")
  };

  public static string ClockBasis(ClockBasis value) => value switch
  {
    Domain.Raid.ClockBasis.BehaviorTick => "behavior_tick",
    Domain.Raid.ClockBasis.RenderFrame => "render_frame",
    Domain.Raid.ClockBasis.FixedUpdate => "fixed_update",
    Domain.Raid.ClockBasis.WallClock => "wall_clock",
    _ => throw new RaidSnapshotIntegrityException("raid_clock_basis_invalid")
  };

  public static string TimingResolution(TimingEvidenceResolution value) => value switch
  {
    TimingEvidenceResolution.Unresolved => "unresolved",
    TimingEvidenceResolution.StaticAnalysis => "static_analysis",
    TimingEvidenceResolution.RuntimeTrace => "runtime_trace",
    _ => throw new RaidSnapshotIntegrityException("raid_timing_resolution_invalid")
  };

  public static string CompatibilityTier(RaidCompatibilityTier value) => value switch
  {
    RaidCompatibilityTier.StaticExact => "static_exact",
    RaidCompatibilityTier.BehaviorExact => "behavior_exact",
    RaidCompatibilityTier.AssetExactRuntimeCurrent => "asset_exact_runtime_current",
    RaidCompatibilityTier.HistoricalRuntimeExact => "historical_runtime_exact",
    _ => throw new RaidSnapshotIntegrityException("raid_compatibility_tier_invalid")
  };

  public static string RuntimeRelation(RuntimeRelation value) => value switch
  {
    Domain.Raid.RuntimeRelation.NotEvaluated => "not_evaluated",
    Domain.Raid.RuntimeRelation.CurrentRuntimeMatch => "current_runtime_match",
    Domain.Raid.RuntimeRelation.HistoricalRuntimeMatch => "historical_runtime_match",
    _ => throw new RaidSnapshotIntegrityException("raid_runtime_relation_invalid")
  };
}
