using System.Globalization;
using NikkeLocalLab.Domain.Raid;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public enum SeasonAvailability
{
  Permanent
}

public enum PresentationBindingStatus
{
  Ready,
  Unresolved
}

public sealed record SeasonPresentationBinding
{
  public SeasonPresentationBinding(
      PresentationBindingStatus status,
      EntityUid? presentationUid = null,
      string? unresolvedReasonCode = null)
  {
    if (!Enum.IsDefined(status) ||
        (status == PresentationBindingStatus.Ready &&
            (!presentationUid.HasValue || unresolvedReasonCode is not null)) ||
        (status == PresentationBindingStatus.Unresolved &&
            (presentationUid.HasValue || unresolvedReasonCode is null)))
    {
      throw new PrivateServerIntegrityException("raid_season_presentation_binding_invalid");
    }

    Status = status;
    PresentationUid = presentationUid.HasValue
        ? PrivateServerGuard.RequireUid(presentationUid.Value, nameof(presentationUid))
        : null;
    UnresolvedReasonCode = unresolvedReasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(unresolvedReasonCode, nameof(unresolvedReasonCode));
  }

  public PresentationBindingStatus Status { get; }

  public EntityUid? PresentationUid { get; }

  public string? UnresolvedReasonCode { get; }

  public static SeasonPresentationBinding Ready(EntityUid presentationUid) =>
      new(PresentationBindingStatus.Ready, presentationUid);

  public static SeasonPresentationBinding Unresolved(
      string reasonCode = "presentation_binding_unresolved") =>
      new(PresentationBindingStatus.Unresolved, unresolvedReasonCode: reasonCode);
}

public sealed record RaidSeasonDirectoryMember
{
  public RaidSeasonDirectoryMember(
      int seasonNumber,
      EntityUid raidSnapshotUid,
      EntityUid datasetSnapshotUid,
      EntityUid challengeEncounterUid,
      EntityUid bossVariantUid,
      Sha256Digest raidSnapshotContentSha256,
      string compatibilityTierCode,
      SeasonPresentationBinding presentation)
  {
    if (seasonNumber < 1)
    {
      throw new PrivateServerIntegrityException("raid_season_number_invalid");
    }

    SeasonNumber = seasonNumber;
    RaidSnapshotUid = PrivateServerGuard.RequireUid(raidSnapshotUid, nameof(raidSnapshotUid));
    DatasetSnapshotUid = PrivateServerGuard.RequireUid(
        datasetSnapshotUid,
        nameof(datasetSnapshotUid));
    ChallengeEncounterUid = PrivateServerGuard.RequireUid(
        challengeEncounterUid,
        nameof(challengeEncounterUid));
    BossVariantUid = PrivateServerGuard.RequireUid(bossVariantUid, nameof(bossVariantUid));
    RaidSnapshotContentSha256 = PrivateServerGuard.RequireDigest(
        raidSnapshotContentSha256,
        nameof(raidSnapshotContentSha256));
    CompatibilityTierCode = PrivateServerGuard.RequireCode(
        compatibilityTierCode,
        nameof(compatibilityTierCode));
    Presentation = presentation ?? throw new ArgumentNullException(nameof(presentation));
  }

  public int SeasonNumber { get; }

  public EntityUid RaidSnapshotUid { get; }

  public EntityUid DatasetSnapshotUid { get; }

  public EntityUid ChallengeEncounterUid { get; }

  public EntityUid BossVariantUid { get; }

  public Sha256Digest RaidSnapshotContentSha256 { get; }

  public string CompatibilityTierCode { get; }

  public SeasonPresentationBinding Presentation { get; }

  public SeasonAvailability Availability => SeasonAvailability.Permanent;

  public DateTimeOffset? SeasonEndsAtUtc => null;

  public static RaidSeasonDirectoryMember FromPublishedSnapshot(
      RaidSnapshot snapshot,
      SeasonPresentationBinding? presentation = null)
  {
    ArgumentNullException.ThrowIfNull(snapshot);
    if (!string.Equals(snapshot.ReadinessStatus, "ready", StringComparison.Ordinal) ||
        !snapshot.Admission.IsSupported)
    {
      throw new PrivateServerIntegrityException("raid_season_snapshot_not_publish_ready");
    }

    return new RaidSeasonDirectoryMember(
        snapshot.SeasonNumber,
        snapshot.RaidSnapshotUid,
        snapshot.DatasetSnapshotUid,
        snapshot.ChallengeEncounterUid,
        snapshot.BossVariantUid,
        snapshot.ContentSha256,
        CompatibilityCode(snapshot.Compatibility.Tier),
        presentation ?? SeasonPresentationBinding.Unresolved());
  }

  public static string CompatibilityCode(RaidCompatibilityTier value) => value switch
  {
    RaidCompatibilityTier.StaticExact => "static_exact",
    RaidCompatibilityTier.BehaviorExact => "behavior_exact",
    RaidCompatibilityTier.AssetExactRuntimeCurrent => "asset_exact_runtime_current",
    RaidCompatibilityTier.HistoricalRuntimeExact => "historical_runtime_exact",
    _ => throw new PrivateServerIntegrityException("raid_compatibility_tier_invalid")
  };
}

public sealed class RaidSeasonDirectory
{
  public const string ContractId = "nll/raid-season-directory/v1";
  public const int Version = 1;

  private static readonly int[] V1SeasonNumbers = [7, 13, 26, 29, 34, 40];

  public RaidSeasonDirectory(
      EntityUid directoryUid,
      DateTimeOffset publishedAtUtc,
      IEnumerable<RaidSeasonDirectoryMember> members)
  {
    DirectoryUid = PrivateServerGuard.RequireUid(directoryUid, nameof(directoryUid));
    PublishedAtUtc = PrivateServerGuard.NormalizeUtc(publishedAtUtc, nameof(publishedAtUtc));
    ArgumentNullException.ThrowIfNull(members);
    var normalized = members
        .Select(static member => member ??
            throw new PrivateServerIntegrityException("raid_season_directory_member_null"))
        .OrderBy(static member => member.SeasonNumber)
        .ToArray();
    if (!normalized.Select(static member => member.SeasonNumber).SequenceEqual(V1SeasonNumbers) ||
        normalized.Select(static member => member.RaidSnapshotUid).Distinct().Count() !=
            normalized.Length ||
        normalized.Select(static member => member.ChallengeEncounterUid).Distinct().Count() !=
            normalized.Length ||
        normalized.Any(static member =>
            member.Availability != SeasonAvailability.Permanent ||
            member.SeasonEndsAtUtc.HasValue))
    {
      throw new PrivateServerIntegrityException("raid_season_directory_v1_members_invalid");
    }

    Members = Array.AsReadOnly(normalized);
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid DirectoryUid { get; }

  public DateTimeOffset PublishedAtUtc { get; }

  public IReadOnlyList<RaidSeasonDirectoryMember> Members { get; }

  public Sha256Digest ContentSha256 { get; }

  public RaidSeasonDirectoryMember RequireMember(EntityUid raidSnapshotUid)
  {
    var uid = PrivateServerGuard.RequireUid(raidSnapshotUid, nameof(raidSnapshotUid));
    var member = Members.SingleOrDefault(candidate => candidate.RaidSnapshotUid == uid);
    return member ?? throw new PrivateServerIntegrityException("raid_season_not_in_directory");
  }

  public RaidSeasonDirectoryMember RequireMember(int seasonNumber)
  {
    var member = Members.SingleOrDefault(candidate => candidate.SeasonNumber == seasonNumber);
    return member ?? throw new PrivateServerIntegrityException("raid_season_not_in_directory");
  }

  private static Sha256Digest ComputeContentSha256(RaidSeasonDirectory value) =>
      PrivateServerHash.Compute(ContractId, hash =>
      {
        PrivateServerHash.Append(hash, Version);
        foreach (var member in value.Members)
        {
          PrivateServerHash.Append(hash, member.SeasonNumber);
          PrivateServerHash.Append(hash, member.RaidSnapshotUid);
          PrivateServerHash.Append(hash, member.DatasetSnapshotUid);
          PrivateServerHash.Append(hash, member.ChallengeEncounterUid);
          PrivateServerHash.Append(hash, member.BossVariantUid);
          PrivateServerHash.Append(hash, member.RaidSnapshotContentSha256);
          PrivateServerHash.Append(hash, member.CompatibilityTierCode);
          PrivateServerHash.Append(hash, AvailabilityCode(member.Availability));
          PrivateServerHash.Append(hash, member.SeasonEndsAtUtc);
          PrivateServerHash.Append(hash, PresentationCode(member.Presentation.Status));
          PrivateServerHash.Append(hash, member.Presentation.PresentationUid);
          PrivateServerHash.Append(hash, member.Presentation.UnresolvedReasonCode ?? string.Empty);
        }
      });

  public static string AvailabilityCode(SeasonAvailability value) => value switch
  {
    SeasonAvailability.Permanent => "permanent",
    _ => throw new PrivateServerIntegrityException("raid_season_availability_invalid")
  };

  public static string PresentationCode(PresentationBindingStatus value) => value switch
  {
    PresentationBindingStatus.Ready => "ready",
    PresentationBindingStatus.Unresolved => "unresolved",
    _ => throw new PrivateServerIntegrityException("raid_season_presentation_status_invalid")
  };
}

public sealed class SelectedRaidSeasonRevision
{
  private SelectedRaidSeasonRevision(
      EntityUid selectionUid,
      EntityUid selectionRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid accountUid,
      EntityUid sessionUid,
      EntityUid clientContextUid,
      EntityUid directoryUid,
      Sha256Digest directoryContentSha256,
      RaidSeasonDirectoryMember member,
      DateTimeOffset materializedAtUtc)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    SelectionUid = PrivateServerGuard.RequireUid(selectionUid, nameof(selectionUid));
    SelectionRevisionUid = PrivateServerGuard.RequireUid(
        selectionRevisionUid,
        nameof(selectionRevisionUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    AccountUid = PrivateServerGuard.RequireUid(accountUid, nameof(accountUid));
    SessionUid = PrivateServerGuard.RequireUid(sessionUid, nameof(sessionUid));
    ClientContextUid = PrivateServerGuard.RequireUid(clientContextUid, nameof(clientContextUid));
    DirectoryUid = PrivateServerGuard.RequireUid(directoryUid, nameof(directoryUid));
    DirectoryContentSha256 = PrivateServerGuard.RequireDigest(
        directoryContentSha256,
        nameof(directoryContentSha256));
    Member = member ?? throw new ArgumentNullException(nameof(member));
    MaterializedAtUtc = PrivateServerGuard.NormalizeUtc(
        materializedAtUtc,
        nameof(materializedAtUtc));
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid SelectionUid { get; }

  public EntityUid SelectionRevisionUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid SessionUid { get; }

  public EntityUid ClientContextUid { get; }

  public EntityUid DirectoryUid { get; }

  public Sha256Digest DirectoryContentSha256 { get; }

  public RaidSeasonDirectoryMember Member { get; }

  public DateTimeOffset MaterializedAtUtc { get; }

  public Sha256Digest ContentSha256 { get; }

  public static SelectedRaidSeasonRevision CreateInitial(
      EntityUid selectionUid,
      EntityUid selectionRevisionUid,
      EntityUid accountUid,
      EntityUid sessionUid,
      EntityUid clientContextUid,
      RaidSeasonDirectory directory,
      EntityUid selectedRaidSnapshotUid,
      DateTimeOffset materializedAtUtc)
  {
    ArgumentNullException.ThrowIfNull(directory);
    return new SelectedRaidSeasonRevision(
        selectionUid,
        selectionRevisionUid,
        1,
        null,
        accountUid,
        sessionUid,
        clientContextUid,
        directory.DirectoryUid,
        directory.ContentSha256,
        directory.RequireMember(selectedRaidSnapshotUid),
        materializedAtUtc);
  }

  public SelectedRaidSeasonRevision Select(
      EntityUid nextRevisionUid,
      RaidSeasonDirectory directory,
      EntityUid selectedRaidSnapshotUid,
      DateTimeOffset materializedAtUtc)
  {
    ArgumentNullException.ThrowIfNull(directory);
    if (directory.DirectoryUid != DirectoryUid ||
        directory.ContentSha256 != DirectoryContentSha256)
    {
      throw new PrivateServerIntegrityException("raid_season_directory_binding_changed");
    }

    var selected = directory.RequireMember(selectedRaidSnapshotUid);
    if (selected.RaidSnapshotUid == Member.RaidSnapshotUid)
    {
      return this;
    }

    return new SelectedRaidSeasonRevision(
        SelectionUid,
        nextRevisionUid,
        RevisionNumber + 1,
        SelectionRevisionUid,
        AccountUid,
        SessionUid,
        ClientContextUid,
        DirectoryUid,
        DirectoryContentSha256,
        selected,
        materializedAtUtc);
  }

  public static SelectedRaidSeasonRevision Restore(
      EntityUid selectionUid,
      EntityUid selectionRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid accountUid,
      EntityUid sessionUid,
      EntityUid clientContextUid,
      RaidSeasonDirectory directory,
      EntityUid selectedRaidSnapshotUid,
      DateTimeOffset materializedAtUtc)
  {
    ArgumentNullException.ThrowIfNull(directory);
    return new SelectedRaidSeasonRevision(
        selectionUid,
        selectionRevisionUid,
        revisionNumber,
        predecessorRevisionUid,
        accountUid,
        sessionUid,
        clientContextUid,
        directory.DirectoryUid,
        directory.ContentSha256,
        directory.RequireMember(selectedRaidSnapshotUid),
        materializedAtUtc);
  }

  private static Sha256Digest ComputeContentSha256(SelectedRaidSeasonRevision value) =>
      PrivateServerHash.Compute("nll/selected-raid-season/v1", hash =>
      {
        PrivateServerHash.Append(hash, value.AccountUid);
        PrivateServerHash.Append(hash, value.SessionUid);
        PrivateServerHash.Append(hash, value.ClientContextUid);
        PrivateServerHash.Append(hash, value.DirectoryUid);
        PrivateServerHash.Append(hash, value.DirectoryContentSha256);
        PrivateServerHash.Append(hash, value.Member.SeasonNumber);
        PrivateServerHash.Append(hash, value.Member.RaidSnapshotUid);
        PrivateServerHash.Append(hash, value.Member.DatasetSnapshotUid);
        PrivateServerHash.Append(hash, value.Member.RaidSnapshotContentSha256);
      });
}

public readonly record struct RaidDayKey : IComparable<RaidDayKey>
{
  private RaidDayKey(DateOnly date)
  {
    Date = date;
  }

  public DateOnly Date { get; }

  public string Value => Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

  public static RaidDayKey FromDate(DateOnly date) => new(date);

  public static RaidDayKey Parse(string value)
  {
    if (!DateOnly.TryParseExact(
            value,
            "yyyy-MM-dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out var date))
    {
      throw new PrivateServerIntegrityException("raid_day_key_invalid");
    }

    return new RaidDayKey(date);
  }

  public int CompareTo(RaidDayKey other) => Date.CompareTo(other.Date);

  public override string ToString() => Value;
}

public sealed record RaidDayWindow(
    RaidDayKey Key,
    DateTimeOffset StartsAtUtc,
    DateTimeOffset EndsAtUtc);

public static class AsiaSeoulRaidDay
{
  public const string PolicyId = "asia-seoul-0500/v1";
  public const string TimeZoneId = "Asia/Seoul";
  public static readonly TimeOnly ResetLocalTime = new(5, 0, 0);

  private static readonly TimeZoneInfo Seoul = LoadSeoulTimeZone();

  public static RaidDayKey GetKey(DateTimeOffset instant) => WindowContaining(instant).Key;

  public static RaidDayWindow WindowContaining(DateTimeOffset instant)
  {
    var local = TimeZoneInfo.ConvertTime(instant, Seoul);
    var shifted = local.DateTime.Subtract(ResetLocalTime.ToTimeSpan());
    var key = RaidDayKey.FromDate(DateOnly.FromDateTime(shifted));
    var starts = GetBoundaryUtc(key);
    return new RaidDayWindow(key, starts, GetBoundaryUtc(RaidDayKey.FromDate(key.Date.AddDays(1))));
  }

  public static DateTimeOffset GetBoundaryUtc(RaidDayKey key)
  {
    var local = key.Date.ToDateTime(ResetLocalTime, DateTimeKind.Unspecified);
    if (Seoul.IsInvalidTime(local) || Seoul.IsAmbiguousTime(local))
    {
      throw new PrivateServerIntegrityException("raid_day_boundary_unresolved");
    }

    return new DateTimeOffset(local, Seoul.GetUtcOffset(local)).ToUniversalTime();
  }

  private static TimeZoneInfo LoadSeoulTimeZone()
  {
    try
    {
      var zone = TimeZoneInfo.FindSystemTimeZoneById(TimeZoneId);
      if (zone.BaseUtcOffset != TimeSpan.FromHours(9))
      {
        throw new PrivateServerIntegrityException("raid_day_timezone_invalid");
      }

      return zone;
    }
    catch (TimeZoneNotFoundException)
    {
      throw new PrivateServerIntegrityException("raid_day_timezone_unavailable");
    }
    catch (InvalidTimeZoneException)
    {
      throw new PrivateServerIntegrityException("raid_day_timezone_unavailable");
    }
  }
}

public sealed class ChallengeDailyStateRevision
{
  private ChallengeDailyStateRevision(
      EntityUid dailyStateUid,
      EntityUid dailyStateRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid accountUid,
      EntityUid policyUid,
      Sha256Digest policyContentSha256,
      EntityUid directoryUid,
      Sha256Digest directoryContentSha256,
      RaidDayKey raidDayKey,
      DailyCounterScope counterScope,
      EntityUid? raidSnapshotUid,
      int consumedEntries)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    DailyStateUid = PrivateServerGuard.RequireUid(dailyStateUid, nameof(dailyStateUid));
    DailyStateRevisionUid = PrivateServerGuard.RequireUid(
        dailyStateRevisionUid,
        nameof(dailyStateRevisionUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    AccountUid = PrivateServerGuard.RequireUid(accountUid, nameof(accountUid));
    PolicyUid = PrivateServerGuard.RequireUid(policyUid, nameof(policyUid));
    PolicyContentSha256 = PrivateServerGuard.RequireDigest(
        policyContentSha256,
        nameof(policyContentSha256));
    DirectoryUid = PrivateServerGuard.RequireUid(directoryUid, nameof(directoryUid));
    DirectoryContentSha256 = PrivateServerGuard.RequireDigest(
        directoryContentSha256,
        nameof(directoryContentSha256));
    RaidDayKey = raidDayKey;
    if (!Enum.IsDefined(counterScope) ||
        (counterScope == DailyCounterScope.PerSeason) != raidSnapshotUid.HasValue ||
        consumedEntries < 0)
    {
      throw new PrivateServerIntegrityException("challenge_daily_state_shape_invalid");
    }

    CounterScope = counterScope;
    RaidSnapshotUid = raidSnapshotUid.HasValue
        ? PrivateServerGuard.RequireUid(raidSnapshotUid.Value, nameof(raidSnapshotUid))
        : null;
    ConsumedEntries = consumedEntries;
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid DailyStateUid { get; }

  public EntityUid DailyStateRevisionUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid PolicyUid { get; }

  public Sha256Digest PolicyContentSha256 { get; }

  public EntityUid DirectoryUid { get; }

  public Sha256Digest DirectoryContentSha256 { get; }

  public RaidDayKey RaidDayKey { get; }

  public DailyCounterScope CounterScope { get; }

  public EntityUid? RaidSnapshotUid { get; }

  public int ConsumedEntries { get; }

  public Sha256Digest ContentSha256 { get; }

  public static ChallengeDailyStateRevision Open(
      EntityUid dailyStateUid,
      EntityUid dailyStateRevisionUid,
      EntityUid accountUid,
      RaidDayKey raidDayKey,
      EntityUid? raidSnapshotUid,
      RaidSeasonDirectory directory,
      ChallengeOperationalPolicy policy)
  {
    ArgumentNullException.ThrowIfNull(directory);
    ArgumentNullException.ThrowIfNull(policy);
    policy.RequireAdmissionReady();
    var scope = policy.DailyCounterScope.RequireConfigured();
    if (scope == DailyCounterScope.PerSeason)
    {
      if (!raidSnapshotUid.HasValue)
      {
        throw new PrivateServerIntegrityException("challenge_daily_season_binding_required");
      }

      _ = directory.RequireMember(raidSnapshotUid.Value);
    }
    else if (raidSnapshotUid.HasValue)
    {
      throw new PrivateServerIntegrityException("challenge_daily_shared_scope_has_season");
    }

    return new ChallengeDailyStateRevision(
        dailyStateUid,
        dailyStateRevisionUid,
        1,
        null,
        accountUid,
        policy.PolicyUid,
        policy.ContentSha256,
        directory.DirectoryUid,
        directory.ContentSha256,
        raidDayKey,
        scope,
        raidSnapshotUid,
        0);
  }

  public static ChallengeDailyStateRevision Restore(
      EntityUid dailyStateUid,
      EntityUid dailyStateRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid accountUid,
      EntityUid policyUid,
      Sha256Digest policyContentSha256,
      EntityUid directoryUid,
      Sha256Digest directoryContentSha256,
      RaidDayKey raidDayKey,
      DailyCounterScope counterScope,
      EntityUid? raidSnapshotUid,
      int consumedEntries) =>
      new(
          dailyStateUid,
          dailyStateRevisionUid,
          revisionNumber,
          predecessorRevisionUid,
          accountUid,
          policyUid,
          policyContentSha256,
          directoryUid,
          directoryContentSha256,
          raidDayKey,
          counterScope,
          raidSnapshotUid,
          consumedEntries);

  public ChallengeDailyStateRevision ConsumeEntry(
      EntityUid nextRevisionUid,
      ChallengeOperationalPolicy policy)
  {
    ArgumentNullException.ThrowIfNull(policy);
    policy.RequireAdmissionReady();
    if (policy.PolicyUid != PolicyUid || policy.ContentSha256 != PolicyContentSha256 ||
        policy.DailyCounterScope.RequireConfigured() != CounterScope)
    {
      throw new PrivateServerIntegrityException("challenge_daily_policy_binding_mismatch");
    }

    if (ConsumedEntries >= policy.DailyEntryLimit.RequireConfigured())
    {
      throw new PrivateServerIntegrityException("challenge_daily_entry_limit_reached");
    }

    return new ChallengeDailyStateRevision(
        DailyStateUid,
        nextRevisionUid,
        RevisionNumber + 1,
        DailyStateRevisionUid,
        AccountUid,
        PolicyUid,
        PolicyContentSha256,
        DirectoryUid,
        DirectoryContentSha256,
        RaidDayKey,
        CounterScope,
        RaidSnapshotUid,
        ConsumedEntries + 1);
  }

  private static Sha256Digest ComputeContentSha256(ChallengeDailyStateRevision value) =>
      PrivateServerHash.Compute("nll/challenge-daily-state/v1", hash =>
      {
        PrivateServerHash.Append(hash, value.AccountUid);
        PrivateServerHash.Append(hash, value.PolicyUid);
        PrivateServerHash.Append(hash, value.PolicyContentSha256);
        PrivateServerHash.Append(hash, value.DirectoryUid);
        PrivateServerHash.Append(hash, value.DirectoryContentSha256);
        PrivateServerHash.Append(hash, value.RaidDayKey.Value);
        PrivateServerHash.Append(hash, ChallengeOperationalPolicy.Code(value.CounterScope));
        PrivateServerHash.Append(hash, value.RaidSnapshotUid);
        PrivateServerHash.Append(hash, value.ConsumedEntries);
      });
}
