using System.Text.Json;
using System.Text.Json.Serialization;

namespace NikkeLocalLab.Domain.Raid;

public static class RaidSnapshotContractSerializer
{
  private static readonly JsonSerializerOptions ContractOptions = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = false,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    WriteIndented = true,
  };

  public static RaidSnapshotContractDocument ToDocument(RaidSnapshot snapshot)
  {
    ArgumentNullException.ThrowIfNull(snapshot);
    return new RaidSnapshotContractDocument(
        RaidSnapshot.SchemaVersion,
        snapshot.RaidSnapshotUid.ToString(),
        snapshot.DatasetSnapshotUid.ToString(),
        snapshot.ChallengeEncounterUid.ToString(),
        snapshot.BossVariantUid.ToString(),
        snapshot.CompatibilityMapUid.ToString(),
        snapshot.SeasonNumber,
        RaidSnapshot.Mode,
        new ChallengeCompatibilityContractDocument(
            RaidSnapshot.ChallengeDifficultyType,
            RaidSnapshot.ChallengeWaveOrder),
        new RaidAdmissionContractDocument(
            snapshot.Admission.PolicyId,
            RaidCanonicalCodes.AdmissionRule(snapshot.Admission.Rule!.Value),
            RaidCanonicalCodes.Element(snapshot.Admission.BossElement),
            RaidCanonicalCodes.Element(snapshot.Admission.WeaknessCode),
            "supported"),
        new RaidStaticRelationsContractDocument(
            snapshot.StaticRelations.Parts.Select(static part => new RaidPartContractDocument(
                part.PartUid.ToString(),
                part.Ordinal,
                part.TypeCode,
                part.DamageHpRatio,
                part.HpRatio,
                part.DefenceRatio,
                part.EnergyResistRatio,
                part.MetalResistRatio,
                part.BioResistRatio,
                part.AttackRatio,
                part.IsMainPart,
                part.IsDamageable,
                part.IsHpVisible,
                part.LinkedPartUid?.ToString())).ToArray(),
            snapshot.StaticRelations.Skills.Select(static skill => new RaidSkillContractDocument(
                skill.SkillUid.ToString(),
                skill.Ordinal,
                skill.RoleCode)).ToArray()),
        new RaidProvenanceContractDocument(
            Artifact(snapshot.Provenance.StaticData),
            snapshot.Provenance.SelectedAssetBundles.Select(static bundle =>
                new AssetBundleContractDocument(
                    bundle.ArtifactUid.ToString(),
                    bundle.Sha256.ToString(),
                    bundle.Roles.Select(RaidCanonicalCodes.AssetBundleRole).ToArray())).ToArray(),
            snapshot.Provenance.AssetBundleSetSha256?.ToString(),
            snapshot.Provenance.Behavior is null ? null : Artifact(snapshot.Provenance.Behavior),
            snapshot.Provenance.Timelines.Select(static timeline => new TimelineContractDocument(
                timeline.Artifact.ArtifactUid.ToString(),
                timeline.Artifact.Sha256.ToString(),
                timeline.ClockBases.Select(RaidCanonicalCodes.ClockBasis).ToArray())).ToArray(),
            snapshot.Provenance.ClientRuntime.IsResolved
                ? new ClientRuntimeContractDocument(
                    snapshot.Provenance.ClientRuntime.BuildUid!.Value.ToString(),
                    snapshot.Provenance.ClientRuntime.LocalBuildLabel,
                    snapshot.Provenance.ClientRuntime.Sha256!.Value.ToString())
                : new ClientRuntimeContractDocument(null, null, null),
            new TimingProvenanceContractDocument(
                snapshot.Provenance.Timing.ClockBases.Select(static clock =>
                    new ClockBasisEvidenceContractDocument(
                        RaidCanonicalCodes.ClockBasis(clock.Basis),
                        RaidCanonicalCodes.TimingResolution(clock.Resolution),
                        clock.EvidenceArtifacts.Select(Artifact).ToArray(),
                        clock.ReasonCode)).ToArray(),
                new SchedulerEvidenceContractDocument(
                    RaidCanonicalCodes.TimingResolution(snapshot.Provenance.Timing.Scheduler.Resolution),
                    snapshot.Provenance.Timing.Scheduler.RelatedClockBases
                        .Select(RaidCanonicalCodes.ClockBasis)
                        .ToArray(),
                    snapshot.Provenance.Timing.Scheduler.EvidenceArtifacts.Select(Artifact).ToArray(),
                    snapshot.Provenance.Timing.Scheduler.ReasonCode))),
        new RaidCompatibilityContractDocument(
            RaidCanonicalCodes.CompatibilityTier(snapshot.Compatibility.Tier),
            RaidCanonicalCodes.RuntimeRelation(snapshot.Compatibility.RuntimeRelation),
            snapshot.Compatibility.EvidenceWarningCodes.ToArray()),
        new RaidReadinessContractDocument(
            snapshot.ReadinessStatus,
            snapshot.ReadinessWarningCodes.ToArray()));
  }

  public static string Serialize(RaidSnapshot snapshot) =>
      JsonSerializer.Serialize(ToDocument(snapshot), ContractOptions);

  public static string Serialize(RaidSnapshotContractDocument document)
  {
    ArgumentNullException.ThrowIfNull(document);
    return JsonSerializer.Serialize(document, ContractOptions);
  }

  public static RaidSnapshotContractDocument Deserialize(string json)
  {
    ArgumentException.ThrowIfNullOrWhiteSpace(json);
    return JsonSerializer.Deserialize<RaidSnapshotContractDocument>(json, ContractOptions)
        ?? throw new JsonException("The raid snapshot contract document cannot be null.");
  }

  private static ArtifactContractDocument Artifact(RaidArtifactReference artifact) =>
      new(artifact.ArtifactUid.ToString(), artifact.Sha256.ToString());
}

public sealed record RaidSnapshotContractDocument(
    int SchemaVersion,
    string RaidSnapshotUid,
    string DatasetSnapshotUid,
    string ChallengeEncounterUid,
    string BossVariantUid,
    string CompatibilityMapUid,
    int SeasonNumber,
    string Mode,
    ChallengeCompatibilityContractDocument ChallengeCompatibility,
    RaidAdmissionContractDocument Admission,
    RaidStaticRelationsContractDocument StaticRelations,
    RaidProvenanceContractDocument Provenance,
    RaidCompatibilityContractDocument Compatibility,
    RaidReadinessContractDocument Readiness);

public sealed record ChallengeCompatibilityContractDocument(int DifficultyType, int WaveOrder);

public sealed record RaidAdmissionContractDocument(
    string PolicyId,
    string Rule,
    string BossElement,
    string WeaknessCode,
    string Status);

public sealed record RaidStaticRelationsContractDocument(
    IReadOnlyList<RaidPartContractDocument> Parts,
    IReadOnlyList<RaidSkillContractDocument> Skills);

public sealed record RaidPartContractDocument(
    string PartUid,
    int Ordinal,
    string TypeCode,
    int DamageHpRatio,
    int HpRatio,
    int DefenceRatio,
    int EnergyResistRatio,
    int MetalResistRatio,
    int BioResistRatio,
    int AttackRatio,
    bool IsMainPart,
    bool IsDamageable,
    bool IsHpVisible,
    string? LinkedPartUid);

public sealed record RaidSkillContractDocument(
    string SkillUid,
    int Ordinal,
    string RoleCode);

public sealed record ArtifactContractDocument(string ArtifactUid, string Sha256);

public sealed record AssetBundleContractDocument(
    string ArtifactUid,
    string Sha256,
    IReadOnlyList<string> Roles);

public sealed record TimelineContractDocument(
    string ArtifactUid,
    string Sha256,
    IReadOnlyList<string> ClockBases);

public sealed record ClientRuntimeContractDocument(
    string? BuildUid,
    string? LocalBuildLabel,
    string? Sha256);

public sealed record ClockBasisEvidenceContractDocument(
    string Basis,
    string Resolution,
    IReadOnlyList<ArtifactContractDocument> EvidenceArtifacts,
    string? ReasonCode);

public sealed record SchedulerEvidenceContractDocument(
    string Resolution,
    IReadOnlyList<string> RelatedClockBases,
    IReadOnlyList<ArtifactContractDocument> EvidenceArtifacts,
    string? ReasonCode);

public sealed record TimingProvenanceContractDocument(
    IReadOnlyList<ClockBasisEvidenceContractDocument> ClockBases,
    SchedulerEvidenceContractDocument Scheduler);

public sealed record RaidProvenanceContractDocument(
    ArtifactContractDocument StaticData,
    IReadOnlyList<AssetBundleContractDocument> SelectedAssetBundles,
    string? AssetBundleSetSha256,
    ArtifactContractDocument? Behavior,
    IReadOnlyList<TimelineContractDocument> Timelines,
    ClientRuntimeContractDocument ClientRuntime,
    TimingProvenanceContractDocument Timing);

public sealed record RaidCompatibilityContractDocument(
    string Tier,
    string RuntimeRelation,
    IReadOnlyList<string> EvidenceWarnings);

public sealed record RaidReadinessContractDocument(
    string Status,
    IReadOnlyList<string> Warnings);
