using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Raid;

public enum ClockBasis
{
  BehaviorTick,
  RenderFrame,
  FixedUpdate,
  WallClock,
}

public enum TimingEvidenceResolution
{
  Unresolved,
  StaticAnalysis,
  RuntimeTrace,
}

public sealed class ClockBasisEvidence
{
  private ClockBasisEvidence(
      ClockBasis basis,
      TimingEvidenceResolution resolution,
      IReadOnlyList<RaidArtifactReference> evidenceArtifacts,
      string? reasonCode)
  {
    Basis = basis;
    Resolution = resolution;
    EvidenceArtifacts = evidenceArtifacts;
    ReasonCode = reasonCode;
  }

  public ClockBasis Basis { get; }

  public TimingEvidenceResolution Resolution { get; }

  public IReadOnlyList<RaidArtifactReference> EvidenceArtifacts { get; }

  public string? ReasonCode { get; }

  public static ClockBasisEvidence Unresolved(ClockBasis basis, string reasonCode) =>
      new(
          basis,
          TimingEvidenceResolution.Unresolved,
          Array.Empty<RaidArtifactReference>(),
          ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static ClockBasisEvidence Resolved(
      ClockBasis basis,
      TimingEvidenceResolution resolution,
      IEnumerable<RaidArtifactReference> evidenceArtifacts)
  {
    if (resolution == TimingEvidenceResolution.Unresolved)
    {
      throw new ArgumentException("Use Unresolved to create an unresolved clock basis claim.", nameof(resolution));
    }

    return new ClockBasisEvidence(
        basis,
        resolution,
        TimingEvidence.NormalizeArtifacts(evidenceArtifacts, nameof(evidenceArtifacts)),
        null);
  }
}

public sealed class SchedulerEvidence
{
  private SchedulerEvidence(
      TimingEvidenceResolution resolution,
      IReadOnlyList<ClockBasis> relatedClockBases,
      IReadOnlyList<RaidArtifactReference> evidenceArtifacts,
      string? reasonCode)
  {
    Resolution = resolution;
    RelatedClockBases = relatedClockBases;
    EvidenceArtifacts = evidenceArtifacts;
    ReasonCode = reasonCode;
  }

  public TimingEvidenceResolution Resolution { get; }

  public IReadOnlyList<ClockBasis> RelatedClockBases { get; }

  public IReadOnlyList<RaidArtifactReference> EvidenceArtifacts { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Resolution != TimingEvidenceResolution.Unresolved;

  public static SchedulerEvidence Unresolved(
      IEnumerable<ClockBasis> relatedClockBases,
      string reasonCode) =>
      new(
          TimingEvidenceResolution.Unresolved,
          TimingEvidence.NormalizeRelatedClockBases(relatedClockBases),
          Array.Empty<RaidArtifactReference>(),
          ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static SchedulerEvidence Resolved(
      TimingEvidenceResolution resolution,
      IEnumerable<ClockBasis> relatedClockBases,
      IEnumerable<RaidArtifactReference> evidenceArtifacts)
  {
    if (resolution == TimingEvidenceResolution.Unresolved)
    {
      throw new ArgumentException("Use Unresolved to create unresolved scheduler evidence.", nameof(resolution));
    }

    return new SchedulerEvidence(
        resolution,
        TimingEvidence.NormalizeRelatedClockBases(relatedClockBases),
        TimingEvidence.NormalizeArtifacts(evidenceArtifacts, nameof(evidenceArtifacts)),
        null);
  }
}

public sealed class TimingProvenance
{
  public TimingProvenance(
      IEnumerable<ClockBasisEvidence> clockBases,
      SchedulerEvidence scheduler)
  {
    ArgumentNullException.ThrowIfNull(clockBases);
    Scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));

    var normalized = clockBases
        .Select(static evidence => evidence ??
            throw new ArgumentException("Clock-basis evidence cannot contain null entries.", nameof(clockBases)))
        .ToArray();
    var expected = Enum.GetValues<ClockBasis>();
    if (normalized.Length != expected.Length ||
        normalized.GroupBy(static evidence => evidence.Basis).Any(static group => group.Count() != 1) ||
        expected.Any(basis => normalized.All(evidence => evidence.Basis != basis)))
    {
      throw new ArgumentException(
          "Timing provenance must contain exactly one claim for every supported clock basis.",
          nameof(clockBases));
    }

    ClockBases = Array.AsReadOnly(normalized
        .OrderBy(static evidence => RaidCanonicalCodes.ClockBasis(evidence.Basis), StringComparer.Ordinal)
        .ToArray());
  }

  public IReadOnlyList<ClockBasisEvidence> ClockBases { get; }

  public SchedulerEvidence Scheduler { get; }

  public ClockBasisEvidence Get(ClockBasis basis) =>
      ClockBases.Single(evidence => evidence.Basis == basis);
}

internal static class TimingEvidence
{
  public static IReadOnlyList<RaidArtifactReference> NormalizeArtifacts(
      IEnumerable<RaidArtifactReference> artifacts,
      string parameterName)
  {
    ArgumentNullException.ThrowIfNull(artifacts, parameterName);
    var normalized = artifacts
        .Select(artifact => artifact ??
            throw new ArgumentException("Timing evidence cannot contain null artifacts.", parameterName))
        .ToArray();
    if (normalized.Length == 0 ||
        normalized.GroupBy(static artifact => artifact.ArtifactUid).Any(static group => group.Count() != 1))
    {
      throw new ArgumentException(
          "Resolved timing evidence must contain unique artifact UIDs.",
          parameterName);
    }

    return Array.AsReadOnly(normalized
        .OrderBy(static artifact => artifact.ArtifactUid.ToString(), StringComparer.Ordinal)
        .ToArray());
  }

  public static IReadOnlyList<ClockBasis> NormalizeRelatedClockBases(IEnumerable<ClockBasis> clockBases)
  {
    ArgumentNullException.ThrowIfNull(clockBases);
    var normalized = clockBases
        .Distinct()
        .OrderBy(RaidCanonicalCodes.ClockBasis, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length < 2)
    {
      throw new ArgumentException(
          "Scheduler evidence must relate at least two clock bases.",
          nameof(clockBases));
    }

    return Array.AsReadOnly(normalized);
  }
}
