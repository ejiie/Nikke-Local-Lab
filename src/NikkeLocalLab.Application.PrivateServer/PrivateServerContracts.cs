using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.PrivateServer;

public enum PrivateServerFailureKind
{
  InvalidRequest,
  NotFound,
  Conflict,
  Forbidden,
  PolicyUnresolved,
  Unsupported,
  Unavailable
}

public sealed class PrivateServerApplicationException : Exception
{
  public PrivateServerApplicationException(
      PrivateServerFailureKind kind,
      string code)
      : base(code)
  {
    if (!Enum.IsDefined(kind) || string.IsNullOrEmpty(code) || code.Length > 64 ||
        code[0] is < 'a' or > 'z' ||
        code.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new ArgumentException("A controlled private-server failure is required.");
    }

    Kind = kind;
    Code = code;
  }

  public PrivateServerFailureKind Kind { get; }

  public string Code { get; }
}

public sealed record RevisionProjection(
    EntityUid RevisionUid,
    long RevisionNumber,
    Sha256Digest ContentSha256);

public sealed record SessionRequestPin(
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ExpectedContextRevisionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record BootQuery(DateTimeOffset ObservedAtUtc);

public sealed record ValidateLocalSessionAccessQuery(
    EntityUid LocalSessionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record OpenLocalSessionCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedBootRevisionUid,
    Sha256Digest ExpectedBootContentSha256,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc);

public sealed record ConnectLocalSessionCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid ExpectedDirectoryUid,
    Sha256Digest ExpectedDirectorySha256,
    EntityUid SelectedRaidSnapshotUid);

public sealed record EnterLobbyCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin);

public sealed record SeasonDirectoryQuery(
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ExpectedContextRevisionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record LobbyBootstrapQuery(
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ExpectedContextRevisionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record SelectRaidSeasonCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid ExpectedSelectionRevisionUid,
    EntityUid ExpectedDirectoryUid,
    Sha256Digest ExpectedDirectorySha256,
    EntityUid SelectedRaidSnapshotUid);

public sealed record SoloRaidStateQuery(
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ExpectedContextRevisionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record ChallengePolicyStateQuery(DateTimeOffset ObservedAtUtc);

public sealed record PublishChallengeOperationalPolicyCommand(
    EntityUid OperationUid,
    ChallengeOperationalPolicy Policy,
    DateTimeOffset PublishedAtUtc);

public sealed record ActivateChallengeOperationalPolicyCommand(
    EntityUid OperationUid,
    EntityUid PolicyUid,
    Sha256Digest ExpectedPolicySha256,
    RaidDayKey EffectiveRaidDayKey,
    EntityUid? ExpectedActivationRevisionUid,
    DateTimeOffset ObservedAtUtc);

public sealed record SaveRuntimeExecutionProfileCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ProfileUid,
    EntityUid? ExpectedCurrentRevisionUid,
    RuntimeExecutionProfileContent Content,
    DateTimeOffset MaterializedAtUtc);

public sealed record SaveCombatControlProfileCommand(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ProfileUid,
    EntityUid? ExpectedCurrentRevisionUid,
    CombatControlProfileContent Content,
    DateTimeOffset MaterializedAtUtc);

public sealed record OpenChallengeRunCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid ExpectedSelectedSeasonRevisionUid,
    EntityUid ProfileRevisionUid,
    EntityUid AccountCombatStateRevisionUid,
    EntityUid RuntimeExecutionProfileRevisionUid,
    EntityUid CombatControlProfileRevisionUid,
    IReadOnlyList<EntityUid> OrderedSquadRevisionUids,
    bool IsMockBattle);

public sealed record EnterChallengeTeamCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid,
    int TeamOrdinal);

public sealed record GetChallengeRunQuery(
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ExpectedContextRevisionUid,
    EntityUid RunUid,
    DateTimeOffset ObservedAtUtc);

public sealed record SubmitChallengeTeamResultCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid,
    int TeamOrdinal,
    NonNegativeIntegerDamage ObservedDamage,
    BattleFrameTelemetry Telemetry,
    IReadOnlyList<ExecutionSegment> ExecutionSegments,
    IReadOnlyList<string> WarningCodes);

public sealed record PrepareChallengeRegroupCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid);

public sealed record CloseChallengeRunCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid,
    EntityUid ResultUid);

public sealed record AbandonChallengeRunCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid,
    EntityUid AbandonmentUid,
    string ReasonCode);

public sealed record RecoverStrandedChallengeRunCommand(
    EntityUid OperationUid,
    SessionRequestPin RequestPin,
    EntityUid RunUid,
    EntityUid ExpectedRunRevisionUid);

public sealed record ClientContextProjection(
    EntityUid ClientContextUid,
    RevisionProjection Revision,
    EntityUid SessionUid,
    EntityUid AccountUid,
    EntityUid ApplicationBuildUid,
    Sha256Digest ApplicationBuildSha256,
    string ApplicationContractId,
    EntityUid CapabilityManifestUid,
    Sha256Digest CapabilityManifestSha256,
    DateTimeOffset IssuedAtUtc,
    DateTimeOffset ExpiresAtUtc,
    string StageCode,
    EntityUid? SelectedSeasonRevisionUid,
    Sha256Digest? SelectedSeasonContentSha256);

public sealed record ChallengeOperationalPolicyProjection(
    ChallengeOperationalPolicy Policy,
    DateTimeOffset PublishedAtUtc,
    bool IsActive,
    RaidDayKey? EffectiveRaidDayKey);

public sealed record ChallengePolicyActivationProjection(
    EntityUid ActivationUid,
    RevisionProjection Revision,
    EntityUid PolicyUid,
    Sha256Digest PolicySha256,
    RaidDayKey EffectiveRaidDayKey);

public sealed record ChallengePolicyStateProjection(
    ChallengeOperationalPolicyProjection Current,
    ChallengeOperationalPolicyProjection? Scheduled,
    ChallengePolicyActivationProjection Activation);

public sealed record PrivateServerCapabilityManifestProjection(
    PrivateServerCapabilityManifest Manifest);

public sealed record RaidSeasonDirectoryProjection(RaidSeasonDirectory Directory);

public sealed record PrivateServerBootProjection(
    RevisionProjection Revision,
    EntityUid ApplicationBuildUid,
    Sha256Digest ApplicationBuildSha256,
    string ApplicationContractId,
    RaidSeasonDirectoryProjection Directory,
    SoloRaidFixedCapabilities FixedCapabilities,
    ChallengeOperationalPolicyProjection OperationalPolicy,
    PrivateServerCapabilityManifestProjection CapabilityManifest);

public sealed record SelectedRaidSeasonProjection(
    SelectedRaidSeasonRevision Selection,
    ClientContextProjection Context);

public sealed record ChallengeDailyStateProjection(
    EntityUid DailyStateUid,
    RevisionProjection Revision,
    RaidDayKey RaidDayKey,
    string CounterScopeCode,
    EntityUid? RaidSnapshotUid,
    int ConsumedEntries,
    int? DailyEntryLimit);

public sealed record ChallengeRuntimeExecutionPinProjection(
    EntityUid RevisionUid,
    Sha256Digest ContentSha256,
    bool IsHarnessValidationReady);

public sealed record ChallengeCombatControlPinProjection(
    EntityUid RevisionUid,
    Sha256Digest ContentSha256,
    bool IsManualBattleReady);

public sealed record ChallengeAdmissionPinProjection(
    EntityUid ProfileRevisionUid,
    Sha256Digest ProfileContentSha256,
    EntityUid AccountCombatStateRevisionUid,
    ChallengeRuntimeExecutionPinProjection? RuntimeExecution,
    ChallengeCombatControlPinProjection? CombatControl);

public sealed record SoloRaidStateProjection(
    ClientContextProjection Context,
    RaidSeasonDirectoryProjection Directory,
    SelectedRaidSeasonProjection Selection,
    ChallengeAdmissionPinProjection AdmissionPins,
    SoloRaidFixedCapabilities FixedCapabilities,
    ChallengeOperationalPolicyProjection OperationalPolicy,
    ChallengeDailyStateProjection? DailyState,
    ChallengeRunProjection? ActiveRun,
    PrivateServerCapabilityManifestProjection CapabilityManifest);

public sealed record LobbyBootstrapProjection(
    ClientContextProjection Context,
    PrivateServerAccountProjection Account,
    RaidSeasonDirectoryProjection Directory,
    SelectedRaidSeasonProjection Selection,
    SoloRaidFixedCapabilities FixedCapabilities,
    ChallengeOperationalPolicyProjection OperationalPolicy,
    PrivateServerCapabilityManifestProjection CapabilityManifest);

public sealed record PrivateServerAccountProjection(
    EntityUid AccountUid,
    Sha256Digest RevisionSetSha256,
    CurrentProfileProjection Profile,
    LobbyPresentationProjection Lobby,
    WalletProjection Wallet,
    IReadOnlyList<RosterEntryProjection> Roster,
    SquadProjection? Squad,
    InventorySubsetProjection Inventory);

public sealed record RuntimeExecutionProfileProjection(RuntimeExecutionProfileRevision Revision);

public sealed record CombatControlProfileProjection(CombatControlProfileRevision Revision);

public sealed record ChallengeRunProjection(ChallengeRun Run);

public sealed record RecoveredChallengeRunProjection(
    ClientContextProjection RequestingContext,
    ChallengeRunProjection Run);

public interface IPrivateServerService
{
  Task<PrivateServerBootProjection> GetBootAsync(
      BootQuery query,
      CancellationToken cancellationToken = default);

  Task ValidateSessionAccessAsync(
      ValidateLocalSessionAccessQuery query,
      CancellationToken cancellationToken = default);

  Task<ClientContextProjection> OpenSessionAsync(
      OpenLocalSessionCommand command,
      CancellationToken cancellationToken = default);

  Task<RaidSeasonDirectoryProjection> GetSeasonDirectoryAsync(
      SeasonDirectoryQuery query,
      CancellationToken cancellationToken = default);

  Task<ClientContextProjection> ConnectSessionAsync(
      ConnectLocalSessionCommand command,
      CancellationToken cancellationToken = default);

  Task<LobbyBootstrapProjection> EnterLobbyAsync(
      EnterLobbyCommand command,
      CancellationToken cancellationToken = default);

  Task<LobbyBootstrapProjection> GetLobbyBootstrapAsync(
      LobbyBootstrapQuery query,
      CancellationToken cancellationToken = default);

  Task<SelectedRaidSeasonProjection> SelectSeasonAsync(
      SelectRaidSeasonCommand command,
      CancellationToken cancellationToken = default);

  Task<SoloRaidStateProjection> GetSoloRaidStateAsync(
      SoloRaidStateQuery query,
      CancellationToken cancellationToken = default);

  Task<ChallengeOperationalPolicyProjection> PublishChallengeOperationalPolicyAsync(
      PublishChallengeOperationalPolicyCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengePolicyStateProjection> GetChallengeOperationalPolicyAsync(
      ChallengePolicyStateQuery query,
      CancellationToken cancellationToken = default);

  Task<ChallengePolicyStateProjection> ActivateChallengeOperationalPolicyAsync(
      ActivateChallengeOperationalPolicyCommand command,
      CancellationToken cancellationToken = default);

  Task<RuntimeExecutionProfileProjection> SaveRuntimeExecutionProfileAsync(
      SaveRuntimeExecutionProfileCommand command,
      CancellationToken cancellationToken = default);

  Task<CombatControlProfileProjection> SaveCombatControlProfileAsync(
      SaveCombatControlProfileCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> OpenChallengeRunAsync(
      OpenChallengeRunCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> EnterChallengeTeamAsync(
      EnterChallengeTeamCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection?> GetChallengeRunAsync(
      GetChallengeRunQuery query,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> SubmitChallengeTeamResultAsync(
      SubmitChallengeTeamResultCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> PrepareChallengeRegroupAsync(
      PrepareChallengeRegroupCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> CloseChallengeRunAsync(
      CloseChallengeRunCommand command,
      CancellationToken cancellationToken = default);

  Task<ChallengeRunProjection> AbandonChallengeRunAsync(
      AbandonChallengeRunCommand command,
      CancellationToken cancellationToken = default);

  Task<RecoveredChallengeRunProjection> RecoverStrandedChallengeRunAsync(
      RecoverStrandedChallengeRunCommand command,
      CancellationToken cancellationToken = default);
}

public sealed class UnavailablePrivateServerService : IPrivateServerService
{
  private static PrivateServerApplicationException Unavailable() =>
      new(PrivateServerFailureKind.Unavailable, "private_server_not_configured");

  public Task<PrivateServerBootProjection> GetBootAsync(BootQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task ValidateSessionAccessAsync(ValidateLocalSessionAccessQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ClientContextProjection> OpenSessionAsync(OpenLocalSessionCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<RaidSeasonDirectoryProjection> GetSeasonDirectoryAsync(SeasonDirectoryQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ClientContextProjection> ConnectSessionAsync(ConnectLocalSessionCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<LobbyBootstrapProjection> EnterLobbyAsync(EnterLobbyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<LobbyBootstrapProjection> GetLobbyBootstrapAsync(LobbyBootstrapQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<SelectedRaidSeasonProjection> SelectSeasonAsync(SelectRaidSeasonCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<SoloRaidStateProjection> GetSoloRaidStateAsync(SoloRaidStateQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeOperationalPolicyProjection> PublishChallengeOperationalPolicyAsync(PublishChallengeOperationalPolicyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengePolicyStateProjection> GetChallengeOperationalPolicyAsync(ChallengePolicyStateQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengePolicyStateProjection> ActivateChallengeOperationalPolicyAsync(ActivateChallengeOperationalPolicyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<RuntimeExecutionProfileProjection> SaveRuntimeExecutionProfileAsync(SaveRuntimeExecutionProfileCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<CombatControlProfileProjection> SaveCombatControlProfileAsync(SaveCombatControlProfileCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> OpenChallengeRunAsync(OpenChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> EnterChallengeTeamAsync(EnterChallengeTeamCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection?> GetChallengeRunAsync(GetChallengeRunQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> SubmitChallengeTeamResultAsync(SubmitChallengeTeamResultCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> PrepareChallengeRegroupAsync(PrepareChallengeRegroupCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> CloseChallengeRunAsync(CloseChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<ChallengeRunProjection> AbandonChallengeRunAsync(AbandonChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
  public Task<RecoveredChallengeRunProjection> RecoverStrandedChallengeRunAsync(RecoverStrandedChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
}
