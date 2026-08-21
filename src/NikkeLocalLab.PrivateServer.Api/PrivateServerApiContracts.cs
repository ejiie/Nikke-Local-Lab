using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Domain.LocalGameState;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.PrivateServer.Api;

internal sealed record OpenSessionApiRequest(
    EntityUid OperationUid,
    EntityUid AccountUid,
    EntityUid ExpectedBootRevisionUid,
    Sha256Digest ExpectedBootContentSha256);

internal sealed record ConnectSessionApiRequest(
    EntityUid OperationUid,
    EntityUid ExpectedDirectoryUid,
    Sha256Digest ExpectedDirectorySha256,
    EntityUid SelectedRaidSnapshotUid);

internal sealed record OperationApiRequest(EntityUid OperationUid);

internal sealed record SelectSeasonApiRequest(
    EntityUid OperationUid,
    EntityUid ExpectedSelectionRevisionUid,
    EntityUid ExpectedDirectoryUid,
    Sha256Digest ExpectedDirectorySha256,
    EntityUid SelectedRaidSnapshotUid);

internal sealed record OpenChallengeRunApiRequest(
    EntityUid OperationUid,
    EntityUid ExpectedSelectedSeasonRevisionUid,
    EntityUid ProfileRevisionUid,
    EntityUid AccountCombatStateRevisionUid,
    EntityUid RuntimeExecutionProfileRevisionUid,
    EntityUid CombatControlProfileRevisionUid,
    IReadOnlyList<EntityUid>? OrderedSquadRevisionUids,
    bool? IsMockBattle);

internal sealed record EnterChallengeTeamApiRequest(
    EntityUid OperationUid,
    int? TeamOrdinal);

internal sealed record SubmitChallengeTeamResultApiRequest(
    EntityUid OperationUid,
    int? TeamOrdinal,
    string? ObservedDamage,
    BattleFrameTelemetryApiRequest? Telemetry,
    IReadOnlyList<ExecutionSegmentApiRequest?>? ExecutionSegments,
    IReadOnlyList<string?>? WarningCodes);

internal sealed record BattleFrameTelemetryApiRequest(
    long? RenderFrameCount,
    long? BehaviorTickCount,
    long? FixedUpdateCount,
    long? WallClockMicroseconds,
    decimal? FrameTimeMedianMilliseconds,
    decimal? FrameTimeP95Milliseconds,
    decimal? FrameTimeP99Milliseconds,
    long? DroppedFrameCount,
    long? StalledFrameCount,
    IReadOnlyList<string?>? WarningCodes);

internal sealed record ExecutionSegmentApiRequest(
    int? Ordinal,
    EntityUid RuntimeExecutionProfileRevisionUid,
    EntityUid CombatControlProfileRevisionUid,
    long? StartRenderFrame,
    long? EndRenderFrame,
    long? StartBehaviorTick,
    long? EndBehaviorTick,
    long? StartFixedUpdate,
    long? EndFixedUpdate,
    long? StartWallClockMicroseconds,
    long? EndWallClockMicroseconds,
    string? StartDamage,
    string? EndDamage);

internal sealed record CloseChallengeRunApiRequest(
    EntityUid OperationUid,
    EntityUid ResultUid);

internal sealed record AbandonChallengeRunApiRequest(
    EntityUid OperationUid,
    EntityUid AbandonmentUid,
    string? ReasonCode);

internal sealed record BootApiResponse(
    string ContractId,
    string SurfaceKind,
    string ClientFeatureManifestContractId,
    string OriginalClientWireAdapter,
    string OriginalClientPresentationAdapter,
    string ResultObservationContractId,
    string FinalDamageAuthority,
    string OriginalRuntimeObservationStatus,
    string RaidDayPolicyId,
    RevisionApiResponse Revision,
    EntityUid ApplicationBuildUid,
    Sha256Digest ApplicationBuildSha256,
    string ApplicationContractId,
    SeasonDirectoryApiResponse Directory,
    FixedSoloRaidCapabilitiesApiResponse FixedCapabilities,
    ChallengeOperationalPolicyApiResponse OperationalPolicy,
    CapabilityManifestApiResponse CapabilityManifest);

internal sealed record SessionGrantApiResponse(
    string AccessToken,
    DateTimeOffset AccessTokenExpiresAtUtc,
    ClientContextApiResponse Context);

internal sealed record RevisionApiResponse(
    EntityUid RevisionUid,
    long RevisionNumber,
    Sha256Digest ContentSha256);

internal sealed record ClientContextApiResponse(
    EntityUid ClientContextUid,
    RevisionApiResponse Revision,
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

internal sealed record ClientFeatureEntryApiResponse(
    string RouteCode,
    string CapabilityCode);

internal sealed record ClientFeatureManifestApiResponse(
    EntityUid ManifestUid,
    string ContractId,
    Sha256Digest ContentSha256,
    IReadOnlyList<ClientFeatureEntryApiResponse> Entries);

internal sealed record CapabilityEntryApiResponse(
    string CapabilityCode,
    string StatusCode,
    string? ReasonCode);

internal sealed record CapabilityManifestApiResponse(
    EntityUid ManifestUid,
    string ContractId,
    int Version,
    Sha256Digest ContentSha256,
    EntityUid OperationalPolicyUid,
    Sha256Digest OperationalPolicySha256,
    ClientFeatureManifestApiResponse ClientFeatures,
    IReadOnlyList<CapabilityEntryApiResponse> Entries);

internal sealed record SeasonPresentationApiResponse(
    string StatusCode,
    EntityUid? PresentationUid,
    string? UnresolvedReasonCode);

internal sealed record SeasonDirectoryMemberApiResponse(
    int SeasonNumber,
    EntityUid RaidSnapshotUid,
    EntityUid DatasetSnapshotUid,
    EntityUid ChallengeEncounterUid,
    EntityUid BossVariantUid,
    Sha256Digest RaidSnapshotContentSha256,
    string CompatibilityTierCode,
    string AvailabilityCode,
    DateTimeOffset? SeasonEndsAtUtc,
    SeasonPresentationApiResponse Presentation);

internal sealed record SeasonDirectoryApiResponse(
    EntityUid DirectoryUid,
    string ContractId,
    int Version,
    DateTimeOffset PublishedAtUtc,
    Sha256Digest ContentSha256,
    IReadOnlyList<SeasonDirectoryMemberApiResponse> Members);

internal sealed record SelectedSeasonApiResponse(
    EntityUid SelectionUid,
    RevisionApiResponse Revision,
    EntityUid DirectoryUid,
    Sha256Digest DirectoryContentSha256,
    SeasonDirectoryMemberApiResponse Member,
    DateTimeOffset MaterializedAtUtc);

internal sealed record FixedSoloRaidCapabilitiesApiResponse(
    string ContractId,
    Sha256Digest ContentSha256,
    bool NormalStagesImplemented,
    int NormalLastClearLevel,
    bool ChallengeUnlocked,
    string NormalCombatCapabilityCode,
    string QuickBattleCapabilityCode,
    string SeasonAvailabilityCode,
    DateTimeOffset? SeasonEndsAtUtc);

internal sealed record IntegerPolicyFactApiResponse(
    string StatusCode,
    int? Value,
    string? UnresolvedReasonCode);

internal sealed record CodePolicyFactApiResponse(
    string StatusCode,
    string? ValueCode,
    string? UnresolvedReasonCode);

internal sealed record ChallengeOperationalPolicyApiResponse(
    EntityUid PolicyUid,
    string PolicyId,
    string ResolutionStatusCode,
    Sha256Digest ContentSha256,
    DateTimeOffset PublishedAtUtc,
    bool IsActive,
    string? EffectiveRaidDayKey,
    IntegerPolicyFactApiResponse DailyEntryLimit,
    CodePolicyFactApiResponse EntryConsumptionPoint,
    CodePolicyFactApiResponse ActiveRunAtReset,
    CodePolicyFactApiResponse DailyCounterScope,
    CodePolicyFactApiResponse MockBattleCapability,
    CodePolicyFactApiResponse LocalRankingCapability);

internal sealed record ChallengeDailyStateApiResponse(
    EntityUid DailyStateUid,
    RevisionApiResponse Revision,
    string RaidDayKey,
    string CounterScopeCode,
    EntityUid? RaidSnapshotUid,
    int ConsumedEntries,
    int? DailyEntryLimit);

internal sealed record SelectedSeasonWithContextApiResponse(
    SelectedSeasonApiResponse Selection,
    ClientContextApiResponse Context);

internal sealed record ChallengeRuntimeExecutionPinApiResponse(
    EntityUid RevisionUid,
    Sha256Digest ContentSha256,
    bool IsHarnessValidationReady);

internal sealed record ChallengeCombatControlPinApiResponse(
    EntityUid RevisionUid,
    Sha256Digest ContentSha256,
    bool IsManualBattleReady);

internal sealed record ChallengeAdmissionPinApiResponse(
    EntityUid ProfileRevisionUid,
    Sha256Digest ProfileContentSha256,
    EntityUid AccountCombatStateRevisionUid,
    ChallengeRuntimeExecutionPinApiResponse? RuntimeExecution,
    ChallengeCombatControlPinApiResponse? CombatControl);

internal sealed record SoloRaidStateApiResponse(
    ClientContextApiResponse Context,
    SeasonDirectoryApiResponse Directory,
    SelectedSeasonApiResponse Selection,
    ChallengeAdmissionPinApiResponse AdmissionPins,
    FixedSoloRaidCapabilitiesApiResponse FixedCapabilities,
    ChallengeOperationalPolicyApiResponse OperationalPolicy,
    ChallengeDailyStateApiResponse? DailyState,
    ChallengeRunApiResponse? ActiveRun,
    CapabilityManifestApiResponse CapabilityManifest);

internal sealed record ChallengeCharacterPinApiResponse(
    int Slot,
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid BuildRevisionUid,
    Sha256Digest BuildContentSha256);

internal sealed record ChallengeTeamPinApiResponse(
    int Ordinal,
    EntityUid ProfileRevisionUid,
    Sha256Digest ProfileContentSha256,
    EntityUid AccountCombatStateRevisionUid,
    EntityUid SquadUid,
    EntityUid SquadRevisionUid,
    Sha256Digest SquadContentSha256,
    Sha256Digest ContentSha256,
    IReadOnlyList<ChallengeCharacterPinApiResponse> Members);

internal sealed record BattleFrameTelemetryApiResponse(
    string ContractId,
    long RenderFrameCount,
    long BehaviorTickCount,
    long FixedUpdateCount,
    long WallClockMicroseconds,
    decimal FrameTimeMedianMilliseconds,
    decimal FrameTimeP95Milliseconds,
    decimal FrameTimeP99Milliseconds,
    long DroppedFrameCount,
    long StalledFrameCount,
    IReadOnlyList<string> WarningCodes,
    Sha256Digest ContentSha256);

internal sealed record ExecutionSegmentApiResponse(
    int Ordinal,
    EntityUid RuntimeExecutionProfileRevisionUid,
    EntityUid CombatControlProfileRevisionUid,
    long StartRenderFrame,
    long EndRenderFrame,
    long StartBehaviorTick,
    long EndBehaviorTick,
    long StartFixedUpdate,
    long EndFixedUpdate,
    long StartWallClockMicroseconds,
    long EndWallClockMicroseconds,
    string StartDamage,
    string EndDamage);

internal sealed record LabHarnessResultReceiptApiResponse(
    EntityUid ReceiptUid,
    string ObservationSourceCode,
    bool IsOriginalClientRuntimeObservation,
    string DamageContractId,
    string ObservedDamage,
    BattleFrameTelemetryApiResponse Telemetry,
    IReadOnlyList<ExecutionSegmentApiResponse> ExecutionSegments,
    IReadOnlyList<string> WarningCodes,
    DateTimeOffset ObservedAtUtc,
    Sha256Digest ContentSha256);

internal sealed record ChallengeTeamAttemptApiResponse(
    ChallengeTeamPinApiResponse Team,
    DateTimeOffset EnteredAtUtc,
    LabHarnessResultReceiptApiResponse? ResultReceipt);

internal sealed record ChallengeRunBindingApiResponse(
    EntityUid AccountUid,
    EntityUid SessionUid,
    EntityUid ClientContextUid,
    EntityUid ClientContextRevisionUid,
    EntityUid ApplicationBuildUid,
    Sha256Digest ApplicationBuildSha256,
    string ApplicationContractId,
    EntityUid CapabilityManifestUid,
    Sha256Digest CapabilityManifestSha256,
    EntityUid DirectoryUid,
    Sha256Digest DirectoryContentSha256,
    EntityUid SelectedSeasonRevisionUid,
    Sha256Digest SelectedSeasonContentSha256,
    EntityUid RaidSnapshotUid,
    EntityUid RaidDatasetSnapshotUid,
    Sha256Digest RaidSnapshotContentSha256,
    EntityUid ProfileRevisionUid,
    Sha256Digest ProfileContentSha256,
    EntityUid AccountCombatStateRevisionUid,
    EntityUid RuntimeExecutionProfileRevisionUid,
    Sha256Digest RuntimeExecutionProfileContentSha256,
    EntityUid CombatControlProfileRevisionUid,
    Sha256Digest CombatControlProfileContentSha256,
    EntityUid OperationalPolicyUid,
    Sha256Digest OperationalPolicySha256,
    EntityUid DailyStateUid,
    EntityUid DailyStateRevisionUid,
    Sha256Digest DailyStateContentSha256,
    string EntryConsumptionPointCode,
    string ActiveRunAtResetCode,
    string DailyCounterScopeCode,
    bool IsMockBattle,
    string RaidDayKey,
    string ExecutionSourceCode,
    Sha256Digest ContentSha256,
    IReadOnlyList<ChallengeTeamPinApiResponse> PlannedTeams);

internal sealed record ChallengeRunApiResponse(
    EntityUid RunUid,
    RevisionApiResponse Revision,
    string StateCode,
    DateTimeOffset OpenedAtUtc,
    DateTimeOffset UpdatedAtUtc,
    string DamageContractId,
    string CumulativeDamage,
    EntityUid? FinalResultUid,
    EntityUid? AbandonmentUid,
    string? AbandonReasonCode,
    ChallengeRunBindingApiResponse Binding,
    IReadOnlyList<ChallengeTeamAttemptApiResponse> Attempts);

internal sealed record LobbyAccountStateApiResponse(
    EntityUid AccountUid,
    Sha256Digest RevisionSetSha256,
    CurrentProfileProjection Profile,
    LobbyPresentationProjection Lobby,
    WalletProjection Wallet,
    IReadOnlyList<RosterEntryProjection> Roster,
    SquadProjection? Squad,
    InventorySubsetProjection Inventory);

internal sealed record LobbyBootstrapApiResponse(
    ClientContextApiResponse Context,
    LobbyAccountStateApiResponse Account,
    SeasonDirectoryApiResponse Directory,
    SelectedSeasonApiResponse Selection,
    FixedSoloRaidCapabilitiesApiResponse FixedCapabilities,
    ChallengeOperationalPolicyApiResponse OperationalPolicy,
    CapabilityManifestApiResponse CapabilityManifest);

internal sealed record UnsupportedInteractionApiResponse(
    string CapabilityCode,
    string StatusCode);

internal sealed record NoNavigationInteractionApiResponse(
    EntityUid OperationUid,
    string InteractionCode,
    bool Navigated);

internal static class PrivateServerApiProjectionMapper
{
  internal static ClientContextApiResponse Context(ClientContextProjection value) => new(
      value.ClientContextUid,
      Revision(value.Revision),
      value.SessionUid,
      value.AccountUid,
      value.ApplicationBuildUid,
      value.ApplicationBuildSha256,
      value.ApplicationContractId,
      value.CapabilityManifestUid,
      value.CapabilityManifestSha256,
      value.IssuedAtUtc,
      value.ExpiresAtUtc,
      value.StageCode,
      value.SelectedSeasonRevisionUid,
      value.SelectedSeasonContentSha256);

  internal static RevisionApiResponse Revision(RevisionProjection value) => new(
      value.RevisionUid,
      value.RevisionNumber,
      value.ContentSha256);

  internal static SeasonDirectoryApiResponse Directory(RaidSeasonDirectoryProjection value)
  {
    var directory = value.Directory;
    return new SeasonDirectoryApiResponse(
        directory.DirectoryUid,
        RaidSeasonDirectory.ContractId,
        RaidSeasonDirectory.Version,
        directory.PublishedAtUtc,
        directory.ContentSha256,
        directory.Members.Select(Member).ToArray());
  }

  internal static SeasonDirectoryMemberApiResponse Member(RaidSeasonDirectoryMember value) => new(
      value.SeasonNumber,
      value.RaidSnapshotUid,
      value.DatasetSnapshotUid,
      value.ChallengeEncounterUid,
      value.BossVariantUid,
      value.RaidSnapshotContentSha256,
      value.CompatibilityTierCode,
      RaidSeasonDirectory.AvailabilityCode(value.Availability),
      value.SeasonEndsAtUtc,
      new SeasonPresentationApiResponse(
          RaidSeasonDirectory.PresentationCode(value.Presentation.Status),
          value.Presentation.PresentationUid,
          value.Presentation.UnresolvedReasonCode));

  internal static SelectedSeasonApiResponse Selection(SelectedRaidSeasonProjection value) =>
      Selection(value.Selection);

  internal static SelectedSeasonApiResponse Selection(SelectedRaidSeasonRevision value) => new(
      value.SelectionUid,
      new RevisionApiResponse(
          value.SelectionRevisionUid,
          value.RevisionNumber,
          value.ContentSha256),
      value.DirectoryUid,
      value.DirectoryContentSha256,
      Member(value.Member),
      value.MaterializedAtUtc);

  internal static FixedSoloRaidCapabilitiesApiResponse Fixed(
      SoloRaidFixedCapabilities value) => new(
      SoloRaidFixedCapabilities.ContractId,
      value.ContentSha256,
      value.NormalStagesImplemented,
      value.NormalLastClearLevel,
      value.ChallengeUnlocked,
      value.NormalCombatCapabilityCode,
      value.QuickBattleCapabilityCode,
      value.SeasonAvailabilityCode,
      value.SeasonEndsAtUtc);

  internal static ChallengeOperationalPolicyApiResponse Policy(
      ChallengeOperationalPolicyProjection value)
  {
    var policy = value.Policy;
    return new ChallengeOperationalPolicyApiResponse(
        policy.PolicyUid,
        policy.PolicyId,
        ChallengeOperationalPolicy.Code(policy.ResolutionStatus),
        policy.ContentSha256,
        value.PublishedAtUtc,
        value.IsActive,
        value.EffectiveRaidDayKey?.Value,
        new IntegerPolicyFactApiResponse(
            ChallengeOperationalPolicy.Code(policy.DailyEntryLimit.Status),
            policy.DailyEntryLimit.Value,
            policy.DailyEntryLimit.UnresolvedReasonCode),
        CodeFact(policy.EntryConsumptionPoint, ChallengeOperationalPolicy.Code),
        CodeFact(policy.ActiveRunAtReset, ChallengeOperationalPolicy.Code),
        CodeFact(policy.DailyCounterScope, ChallengeOperationalPolicy.Code),
        CodeFact(policy.MockBattleCapability, ChallengeOperationalPolicy.Code),
        CodeFact(policy.LocalRankingCapability, ChallengeOperationalPolicy.Code));
  }

  internal static CapabilityManifestApiResponse Capabilities(
      PrivateServerCapabilityManifestProjection value)
  {
    var manifest = value.Manifest;
    return new CapabilityManifestApiResponse(
        manifest.ManifestUid,
        PrivateServerCapabilityManifest.ContractId,
        PrivateServerCapabilityManifest.Version,
        manifest.ContentSha256,
        manifest.OperationalPolicyUid,
        manifest.OperationalPolicySha256,
        new ClientFeatureManifestApiResponse(
            manifest.ClientFeatureManifestUid,
            manifest.ClientFeatureManifest.ContractVersion,
            manifest.ClientFeatureManifest.ContentSha256,
            manifest.ClientFeatureManifest.Entries.Select(static entry =>
                new ClientFeatureEntryApiResponse(
                    entry.RouteCode,
                    LocalGameStateCanonicalizer.Code(entry.Capability))).ToArray()),
        manifest.Entries.Select(static entry => new CapabilityEntryApiResponse(
            entry.CapabilityCode,
            PrivateServerCapabilityManifest.Code(entry.Status),
            entry.ReasonCode)).ToArray());
  }

  internal static SoloRaidStateApiResponse SoloRaid(SoloRaidStateProjection value) => new(
      Context(value.Context),
      Directory(value.Directory),
      Selection(value.Selection),
      new ChallengeAdmissionPinApiResponse(
          value.AdmissionPins.ProfileRevisionUid,
          value.AdmissionPins.ProfileContentSha256,
          value.AdmissionPins.AccountCombatStateRevisionUid,
          value.AdmissionPins.RuntimeExecution is null
              ? null
              : new ChallengeRuntimeExecutionPinApiResponse(
                  value.AdmissionPins.RuntimeExecution.RevisionUid,
                  value.AdmissionPins.RuntimeExecution.ContentSha256,
                  value.AdmissionPins.RuntimeExecution.IsHarnessValidationReady),
          value.AdmissionPins.CombatControl is null
              ? null
              : new ChallengeCombatControlPinApiResponse(
                  value.AdmissionPins.CombatControl.RevisionUid,
                  value.AdmissionPins.CombatControl.ContentSha256,
                  value.AdmissionPins.CombatControl.IsManualBattleReady)),
      Fixed(value.FixedCapabilities),
      Policy(value.OperationalPolicy),
      value.DailyState is null
          ? null
          : new ChallengeDailyStateApiResponse(
              value.DailyState.DailyStateUid,
              Revision(value.DailyState.Revision),
              value.DailyState.RaidDayKey.Value,
              value.DailyState.CounterScopeCode,
              value.DailyState.RaidSnapshotUid,
              value.DailyState.ConsumedEntries,
              value.DailyState.DailyEntryLimit),
      value.ActiveRun is null ? null : ChallengeRun(value.ActiveRun),
      Capabilities(value.CapabilityManifest));

  internal static ChallengeRunApiResponse ChallengeRun(ChallengeRunProjection value)
  {
    var run = value.Run;
    var binding = run.Binding;
    return new ChallengeRunApiResponse(
        run.RunUid,
        new RevisionApiResponse(run.RunRevisionUid, run.RevisionNumber, run.ContentSha256),
        Domain.PrivateServer.ChallengeRun.StateCode(run.State),
        run.OpenedAtUtc,
        run.UpdatedAtUtc,
        NonNegativeIntegerDamage.ContractId,
        run.CumulativeDamage.CanonicalDigits,
        run.FinalResultUid,
        run.AbandonmentUid,
        run.AbandonReasonCode,
        new ChallengeRunBindingApiResponse(
            binding.AccountUid,
            binding.SessionUid,
            binding.ClientContextUid,
            binding.ClientContextRevisionUid,
            binding.ApplicationBuildUid,
            binding.ApplicationBuildSha256,
            binding.ApplicationContractId,
            binding.CapabilityManifestUid,
            binding.CapabilityManifestSha256,
            binding.DirectoryUid,
            binding.DirectoryContentSha256,
            binding.SelectedSeasonRevisionUid,
            binding.SelectedSeasonContentSha256,
            binding.RaidSnapshotUid,
            binding.RaidDatasetSnapshotUid,
            binding.RaidSnapshotContentSha256,
            binding.ProfileRevisionUid,
            binding.ProfileContentSha256,
            binding.AccountCombatStateRevisionUid,
            binding.RuntimeExecutionProfileRevisionUid,
            binding.RuntimeExecutionProfileContentSha256,
            binding.CombatControlProfileRevisionUid,
            binding.CombatControlProfileContentSha256,
            binding.OperationalPolicyUid,
            binding.OperationalPolicySha256,
            binding.DailyStateUid,
            binding.DailyStateRevisionUid,
            binding.DailyStateContentSha256,
            ChallengeOperationalPolicy.Code(binding.EntryConsumptionPoint),
            ChallengeOperationalPolicy.Code(binding.ActiveRunAtReset),
            ChallengeOperationalPolicy.Code(binding.DailyCounterScope),
            binding.IsMockBattle,
            binding.RaidDayKey.Value,
            binding.ExecutionSourceCode,
            binding.ContentSha256,
            binding.Plan.Teams.Select(Team).ToArray()),
        run.Attempts.Select(static attempt => new ChallengeTeamAttemptApiResponse(
            Team(attempt.Team),
            attempt.EnteredAtUtc,
            attempt.ResultReceipt is null ? null : Receipt(attempt.ResultReceipt))).ToArray());
  }

  private static ChallengeTeamPinApiResponse Team(ChallengeTeamPin value) => new(
      value.Ordinal,
      value.ProfileRevisionUid,
      value.ProfileContentSha256,
      value.AccountCombatStateRevisionUid,
      value.SquadUid,
      value.SquadRevisionUid,
      value.SquadContentSha256,
      value.ContentSha256,
      value.Members.Select(static member => new ChallengeCharacterPinApiResponse(
          member.Slot,
          member.CharacterUid,
          member.CharacterBuildUid,
          member.BuildRevisionUid,
          member.BuildContentSha256)).ToArray());

  private static LabHarnessResultReceiptApiResponse Receipt(
      LabHarnessTeamResultReceipt value) => new(
      value.ReceiptUid,
      value.ObservationSourceCode,
      value.IsOriginalClientRuntimeObservation,
      NonNegativeIntegerDamage.ContractId,
      value.ObservedDamage.CanonicalDigits,
      new BattleFrameTelemetryApiResponse(
          BattleFrameTelemetry.ContractId,
          value.Telemetry.RenderFrameCount,
          value.Telemetry.BehaviorTickCount,
          value.Telemetry.FixedUpdateCount,
          value.Telemetry.WallClockMicroseconds,
          value.Telemetry.FrameTimeMedianMilliseconds,
          value.Telemetry.FrameTimeP95Milliseconds,
          value.Telemetry.FrameTimeP99Milliseconds,
          value.Telemetry.DroppedFrameCount,
          value.Telemetry.StalledFrameCount,
          value.Telemetry.WarningCodes,
          value.Telemetry.ContentSha256),
      value.ExecutionSegments.Select(static segment => new ExecutionSegmentApiResponse(
          segment.Ordinal,
          segment.RuntimeExecutionProfileRevisionUid,
          segment.CombatControlProfileRevisionUid,
          segment.StartRenderFrame,
          segment.EndRenderFrame,
          segment.StartBehaviorTick,
          segment.EndBehaviorTick,
          segment.StartFixedUpdate,
          segment.EndFixedUpdate,
          segment.StartWallClockMicroseconds,
          segment.EndWallClockMicroseconds,
          segment.StartDamage.CanonicalDigits,
          segment.EndDamage.CanonicalDigits)).ToArray(),
      value.WarningCodes,
      value.ObservedAtUtc,
      value.ContentSha256);

  internal static LobbyBootstrapApiResponse Lobby(LobbyBootstrapProjection value) => new(
      Context(value.Context),
      new LobbyAccountStateApiResponse(
          value.Account.AccountUid,
          value.Account.RevisionSetSha256,
          value.Account.Profile,
          value.Account.Lobby,
          value.Account.Wallet,
          value.Account.Roster,
          value.Account.Squad,
          value.Account.Inventory),
      Directory(value.Directory),
      Selection(value.Selection),
      Fixed(value.FixedCapabilities),
      Policy(value.OperationalPolicy),
      Capabilities(value.CapabilityManifest));

  internal static BootApiResponse Boot(PrivateServerBootProjection value) => new(
      "nll/private-server-harness-api/v1",
      "lab_owned_private_server_harness",
      "nll/client-feature-manifest/v2",
      "blocked_by_gate",
      "blocked_by_gate",
      LabHarnessTeamResultReceipt.ObservationContractId,
      "original_client_runtime",
      "blocked_by_gate",
      AsiaSeoulRaidDay.PolicyId,
      Revision(value.Revision),
      value.ApplicationBuildUid,
      value.ApplicationBuildSha256,
      value.ApplicationContractId,
      Directory(value.Directory),
      Fixed(value.FixedCapabilities),
      Policy(value.OperationalPolicy),
      Capabilities(value.CapabilityManifest));

  private static CodePolicyFactApiResponse CodeFact<T>(
      PolicyFact<T> fact,
      Func<T, string> formatter)
      where T : struct => new(
      ChallengeOperationalPolicy.Code(fact.Status),
      fact.Value.HasValue ? formatter(fact.Value.Value) : null,
      fact.UnresolvedReasonCode);
}
