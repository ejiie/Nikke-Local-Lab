using System.Data;
using System.Globalization;
using System.Numerics;
using App = NikkeLocalLab.Application.PrivateServer;
using PrivateServerDomain = global::NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using Npgsql;
using NpgsqlTypes;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed partial class PostgreSqlPrivateServerService
{
  private const long PrivateServerRunOperationLockSeed = 5_614_803_147_991_271_097;

  private sealed record StoredRunOperation(
      string Kind,
      Sha256Digest RequestSha256,
      long ResultRevisionId,
      EntityUid RunUid);

  private sealed record StoredDailyState(
      long Id,
      long RevisionId,
      PrivateServerDomain.ChallengeDailyStateRevision Revision);

  private sealed record StoredRun(
      long Id,
      long RevisionId,
      long AccountId,
      long ContextId,
      long DailyStateId,
      long RuntimeRevisionId,
      long ControlRevisionId,
      PrivateServerDomain.ChallengeRun Run);

  private sealed record StoredTeam(
      long SquadRevisionId,
      PrivateServerDomain.ChallengeTeamPin Pin,
      IReadOnlyList<StoredTeamMember> Members);

  private sealed record StoredTeamMember(
      long CharacterEntityId,
      long CharacterBuildId,
      long BuildRevisionId,
      PrivateServerDomain.ChallengeCharacterPin Pin);

  private sealed record StoredReceipt(
      long Id,
      PrivateServerDomain.LabHarnessTeamResultReceipt Receipt);

  public Task<App.ChallengeRunProjection> OpenChallengeRunAsync(
      App.OpenChallengeRunCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    if (command.OrderedSquadRevisionUids is null ||
        command.OrderedSquadRevisionUids.Count is < 1 or > 5)
    {
      throw Failure(App.PrivateServerFailureKind.InvalidRequest, "challenge_run_plan_invalid");
    }

    var requestSha256 = RequestHash(
        "nll/private-server-open-challenge-run-request/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        command.ExpectedSelectedSeasonRevisionUid,
        command.ProfileRevisionUid,
        command.AccountCombatStateRevisionUid,
        command.RuntimeExecutionProfileRevisionUid,
        command.CombatControlProfileRevisionUid,
        string.Join(',', command.OrderedSquadRevisionUids.Select(static uid => uid.ToString())),
        command.IsMockBattle);
    return RunStoreAsync(
        () => OpenChallengeRunCoreAsync(command, requestSha256, cancellationToken));
  }

  public Task<App.ChallengeRunProjection> EnterChallengeTeamAsync(
      App.EnterChallengeTeamCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    if (command.TeamOrdinal is < 1 or > 5)
    {
      throw Failure(
          App.PrivateServerFailureKind.InvalidRequest,
          "challenge_team_ordinal_invalid");
    }
    return ExecuteOwnedRunMutationAsync(
        command.OperationUid,
        command.RequestPin,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        "enter_team",
        RequestHash(
            "nll/private-server-enter-challenge-team-request/v1",
            command.RequestPin.SessionUid,
            command.RequestPin.ClientContextUid,
            command.RequestPin.ExpectedContextRevisionUid,
            command.RunUid,
            command.ExpectedRunRevisionUid,
            command.TeamOrdinal),
        command.TeamOrdinal,
        (stored, observedAtUtc) => stored.Run.EnterTeam(
            _uidGenerator.NewUid(),
            command.TeamOrdinal,
            observedAtUtc),
        receiptFactory: null,
        resultUid: null,
        abandonmentUid: null,
        abandonReasonCode: null,
        cancellationToken);
  }

  public Task<App.ChallengeRunProjection?> GetChallengeRunAsync(
      App.GetChallengeRunQuery query,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(query);
    return RunStoreAsync(async () =>
    {
      var observed = NormalizeInstant(query.ObservedAtUtc);
      await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
          .ConfigureAwait(false);
      var context = await RequireCurrentContextAsync(
          connection,
          transaction: null,
          query.SessionUid,
          query.ClientContextUid,
          query.ExpectedContextRevisionUid,
          observed,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(context);
      var stored = await LoadRunByUidAsync(
          connection,
          transaction: null,
          query.RunUid,
          revisionId: null,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      if (stored is null)
      {
        return null;
      }

      RequireOwnedRun(context, stored);
      return new App.ChallengeRunProjection(stored.Run);
    });
  }

  public Task<App.ChallengeRunProjection> SubmitChallengeTeamResultAsync(
      App.SubmitChallengeTeamResultCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    if (command.TeamOrdinal is < 1 or > 5 || command.Telemetry is null ||
        command.ExecutionSegments is null || command.WarningCodes is null ||
        command.ExecutionSegments.Count is < 1 or > 64 ||
        command.ExecutionSegments.Any(static segment => segment is null))
    {
      throw Failure(
          App.PrivateServerFailureKind.InvalidRequest,
          "challenge_team_result_request_invalid");
    }

    var normalizedWarnings = NormalizeRunWarningCodes(command.WarningCodes);
    var segmentIdentity = string.Join('|', command.ExecutionSegments.Select(static segment =>
        string.Join(',',
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
            segment.EndDamage.CanonicalDigits)));
    var warningIdentity = string.Join(',', normalizedWarnings);
    var requestSha256 = RequestHash(
        "nll/private-server-submit-challenge-team-result-request/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        command.TeamOrdinal,
        command.ObservedDamage.CanonicalDigits,
        command.Telemetry.ContentSha256,
        segmentIdentity,
        warningIdentity);
    return ExecuteOwnedRunMutationAsync(
        command.OperationUid,
        command.RequestPin,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        "accept_team_damage",
        requestSha256,
        command.TeamOrdinal,
        (stored, observedAtUtc) =>
        {
          if (command.TeamOrdinal > stored.Run.Binding.Plan.Teams.Count)
          {
            throw Failure(
                App.PrivateServerFailureKind.InvalidRequest,
                "challenge_team_ordinal_invalid");
          }

          var receipt = new PrivateServerDomain.LabHarnessTeamResultReceipt(
              _uidGenerator.NewUid(),
              stored.Run.RunUid,
              stored.Run.Binding.Plan.Teams[command.TeamOrdinal - 1],
              command.ObservedDamage,
              command.Telemetry,
              command.ExecutionSegments,
              normalizedWarnings,
              observedAtUtc);
          return stored.Run.AcceptTeamResult(_uidGenerator.NewUid(), receipt);
        },
        (stored, next) => next.Attempts[^1].ResultReceipt,
        resultUid: null,
        abandonmentUid: null,
        abandonReasonCode: null,
        cancellationToken);
  }

  public Task<App.ChallengeRunProjection> PrepareChallengeRegroupAsync(
      App.PrepareChallengeRegroupCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    return ExecuteOwnedRunMutationAsync(
        command.OperationUid,
        command.RequestPin,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        "regroup",
        RequestHash(
            "nll/private-server-prepare-challenge-regroup-request/v1",
            command.RequestPin.SessionUid,
            command.RequestPin.ClientContextUid,
            command.RequestPin.ExpectedContextRevisionUid,
            command.RunUid,
            command.ExpectedRunRevisionUid),
        teamOrdinal: null,
        (stored, observedAtUtc) => stored.Run.PrepareRegroup(
            _uidGenerator.NewUid(),
            observedAtUtc),
        receiptFactory: null,
        resultUid: null,
        abandonmentUid: null,
        abandonReasonCode: null,
        cancellationToken);
  }

  public Task<App.ChallengeRunProjection> CloseChallengeRunAsync(
      App.CloseChallengeRunCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    return ExecuteOwnedRunMutationAsync(
        command.OperationUid,
        command.RequestPin,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        "close_run",
        RequestHash(
            "nll/private-server-close-challenge-run-request/v1",
            command.RequestPin.SessionUid,
            command.RequestPin.ClientContextUid,
            command.RequestPin.ExpectedContextRevisionUid,
            command.RunUid,
            command.ExpectedRunRevisionUid,
            command.ResultUid),
        teamOrdinal: null,
        (stored, observedAtUtc) => stored.Run.Close(
            _uidGenerator.NewUid(),
            command.ResultUid,
            observedAtUtc),
        receiptFactory: null,
        resultUid: command.ResultUid,
        abandonmentUid: null,
        abandonReasonCode: null,
        cancellationToken);
  }

  public Task<App.ChallengeRunProjection> AbandonChallengeRunAsync(
      App.AbandonChallengeRunCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    if (command.ReasonCode is null)
    {
      throw Failure(
          App.PrivateServerFailureKind.InvalidRequest,
          "challenge_abandon_reason_invalid");
    }
    return ExecuteOwnedRunMutationAsync(
        command.OperationUid,
        command.RequestPin,
        command.RunUid,
        command.ExpectedRunRevisionUid,
        "abandon_run",
        RequestHash(
            "nll/private-server-abandon-challenge-run-request/v1",
            command.RequestPin.SessionUid,
            command.RequestPin.ClientContextUid,
            command.RequestPin.ExpectedContextRevisionUid,
            command.RunUid,
            command.ExpectedRunRevisionUid,
            command.AbandonmentUid,
            command.ReasonCode),
        teamOrdinal: null,
        (stored, observedAtUtc) => stored.Run.Abandon(
            _uidGenerator.NewUid(),
            command.AbandonmentUid,
            command.ReasonCode,
            observedAtUtc),
        receiptFactory: null,
        resultUid: null,
        abandonmentUid: command.AbandonmentUid,
        abandonReasonCode: command.ReasonCode,
        cancellationToken);
  }

  public Task<App.RecoveredChallengeRunProjection> RecoverStrandedChallengeRunAsync(
      App.RecoverStrandedChallengeRunCommand command,
      CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(command);
    RequireRunRequestPin(command.RequestPin);
    var requestSha256 = RequestHash(
        "nll/private-server-recover-stranded-challenge-run-request/v1",
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        command.RunUid,
        command.ExpectedRunRevisionUid);
    return RunStoreAsync(
        () => RecoverStrandedChallengeRunCoreAsync(
            command,
            requestSha256,
            cancellationToken));
  }

  private async Task<App.ChallengeRunProjection> OpenChallengeRunCoreAsync(
      App.OpenChallengeRunCommand command,
      Sha256Digest requestSha256,
      CancellationToken cancellationToken)
  {
    RequireUid(command.OperationUid, "operation_uid_invalid");
    if (command.OrderedSquadRevisionUids is null ||
        command.OrderedSquadRevisionUids.Count is < 1 or > 5 ||
        command.OrderedSquadRevisionUids.Any(static uid => uid.Value == Guid.Empty) ||
        command.OrderedSquadRevisionUids.Distinct().Count() !=
            command.OrderedSquadRevisionUids.Count)
    {
      throw Failure(App.PrivateServerFailureKind.InvalidRequest, "challenge_run_plan_invalid");
    }

    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        WriteIsolation,
        cancellationToken).ConfigureAwait(false);
    await AcquireRunOperationLockAsync(
        connection,
        transaction,
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    var replay = await LoadRunOperationAsync(
        connection,
        transaction,
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    if (replay is not null)
    {
      RequireRunReplay(replay, "open_run", requestSha256);
      var replayObserved = NormalizeInstant(command.RequestPin.ObservedAtUtc);
      var replayContext = await RequireCurrentContextAsync(
          connection,
          transaction,
          command.RequestPin.SessionUid,
          command.RequestPin.ClientContextUid,
          command.RequestPin.ExpectedContextRevisionUid,
          replayObserved,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(replayContext);
      var replayed = await RequireRunRevisionAsync(
          connection,
          transaction,
          replay.ResultRevisionId,
          cancellationToken).ConfigureAwait(false);
      RequireOwnedRun(replayContext, replayed);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.ChallengeRunProjection(replayed.Run);
    }

    var observed = NormalizeInstant(command.RequestPin.ObservedAtUtc);
    var context = await RequireCurrentContextAsync(
        connection,
        transaction,
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        observed,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false);
    RequireLobbyReady(context);
    var selection = await RequireCurrentSelectionAsync(
        connection,
        transaction,
        context,
        cancellationToken).ConfigureAwait(false);
    if (selection.Revision.SelectionRevisionUid !=
        command.ExpectedSelectedSeasonRevisionUid)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "selected_raid_season_revision_conflict");
    }

    var boot = await LoadBootByIdAsync(
        connection,
        transaction,
        context.BootId,
        cancellationToken).ConfigureAwait(false);
    var effectiveBoot = await LoadBootAsync(
        connection,
        transaction,
        observed,
        cancellationToken).ConfigureAwait(false);
    if (effectiveBoot.ActivationRevisionId != boot.ActivationRevisionId ||
        effectiveBoot.PolicyId != boot.PolicyId ||
        effectiveBoot.CapabilityManifestId != boot.CapabilityManifestId)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_context_boot_refresh_required");
    }

    var policy = boot.Projection.OperationalPolicy.Policy;
    if (!policy.IsAdmissionReady)
    {
      throw Failure(
          App.PrivateServerFailureKind.PolicyUnresolved,
          "challenge_operational_policy_unresolved");
    }

    if (!policy.AllowsMockBattle(command.IsMockBattle))
    {
      throw Failure(
          App.PrivateServerFailureKind.Unsupported,
          "challenge_mock_battle_unsupported");
    }

    var pins = await RequireStoredAccountPinsAsync(
        connection,
        transaction,
        context,
        cancellationToken).ConfigureAwait(false);
    if (pins.ProfileTemplateRevisionUid != command.ProfileRevisionUid ||
        pins.AccountStateRevisionUid != command.AccountCombatStateRevisionUid)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_profile_revision_conflict");
    }

    var runtime = await LoadRuntimeExecutionProfileRevisionAsync(
        connection,
        transaction,
        context.AccountId,
        command.RuntimeExecutionProfileRevisionUid,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.NotFound,
            "runtime_execution_profile_revision_not_found");
    var control = await LoadCombatControlProfileRevisionAsync(
        connection,
        transaction,
        context.AccountId,
        command.CombatControlProfileRevisionUid,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.NotFound,
            "combat_control_profile_revision_not_found");
    if (!runtime.Content.IsHarnessValidationReady || !control.Content.IsManualBattleReady)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_execution_profiles_not_ready");
    }

    var teams = await LoadRequestedTeamsAsync(
        connection,
        transaction,
        context.AccountId,
        pins,
        command.OrderedSquadRevisionUids,
        cancellationToken).ConfigureAwait(false);
    var plan = new PrivateServerDomain.ChallengeRunPlan(
        teams.Select(static team => team.Pin));
    var daily = await GetOrCreateDailyStateAsync(
        connection,
        transaction,
        context,
        boot,
        selection,
        observed,
        cancellationToken).ConfigureAwait(false);
    var entryLimit = policy.DailyEntryLimit.RequireConfigured();
    if (!command.IsMockBattle && daily.Revision.ConsumedEntries >= entryLimit)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_daily_entry_limit_reached");
    }

    var consumesOnOpen = !command.IsMockBattle &&
        policy.EntryConsumptionPoint.RequireConfigured() ==
            PrivateServerDomain.ChallengeEntryConsumptionPoint.RunOpened;
    if (consumesOnOpen)
    {
      daily = await ConsumeDailyStateAsync(
          connection,
          transaction,
          daily.Id,
          policy,
          command.OperationUid,
          observed,
          cancellationToken).ConfigureAwait(false);
    }

    var binding = PrivateServerDomain.ChallengeRunBinding.Restore(
        new PrivateServerDomain.ChallengeRunBindingSnapshot(
            context.Context.AccountUid,
            context.Context.SessionUid,
            context.Context.ClientContextUid,
            context.Context.ContextRevisionUid,
            context.Context.ApplicationBuildUid,
            context.Context.ApplicationBuildSha256,
            context.Context.ApplicationContractId,
            boot.Projection.CapabilityManifest.Manifest.ManifestUid,
            boot.Projection.CapabilityManifest.Manifest.ContentSha256,
            boot.Projection.Directory.Directory.DirectoryUid,
            boot.Projection.Directory.Directory.ContentSha256,
            daily.Revision.DailyStateUid,
            daily.Revision.DailyStateRevisionUid,
            daily.Revision.ContentSha256,
            selection.Revision.SelectionRevisionUid,
            selection.Revision.ContentSha256,
            selection.Revision.Member.RaidSnapshotUid,
            selection.Revision.Member.DatasetSnapshotUid,
            selection.Revision.Member.RaidSnapshotContentSha256,
            pins.ProfileTemplateRevisionUid,
            pins.ProfileTemplateContentSha256,
            pins.AccountStateRevisionUid,
            runtime.RevisionUid,
            runtime.ContentSha256,
            control.RevisionUid,
            control.ContentSha256,
            policy.PolicyUid,
            policy.ContentSha256,
            policy.EntryConsumptionPoint.RequireConfigured(),
            policy.ActiveRunAtReset.RequireConfigured(),
            policy.DailyCounterScope.RequireConfigured(),
            command.IsMockBattle,
            PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observed)),
        plan);
    var run = PrivateServerDomain.ChallengeRun.Open(
        _uidGenerator.NewUid(),
        _uidGenerator.NewUid(),
        binding,
        observed);
    var executionIds = await ResolveExecutionRevisionIdsAsync(
        connection,
        transaction,
        context.AccountId,
        runtime.RevisionUid,
        control.RevisionUid,
        cancellationToken).ConfigureAwait(false);
    var raidSnapshotId = await ResolveSelectedSnapshotIdAsync(
        connection,
        transaction,
        selection.RevisionId,
        cancellationToken).ConfigureAwait(false);
    var runId = await InsertRunAggregateAsync(
        connection,
        transaction,
        command.OperationUid,
        context,
        selection,
        boot,
        pins,
        daily,
        raidSnapshotId,
        executionIds.RuntimeRevisionId,
        executionIds.ControlRevisionId,
        run,
        cancellationToken).ConfigureAwait(false);
    await InsertRunTeamsAsync(
        connection,
        transaction,
        runId,
        context.AccountId,
        pins.ProfileTemplateRevisionId,
        teams,
        cancellationToken).ConfigureAwait(false);
    var revisionId = await InsertRunRevisionAsync(
        connection,
        transaction,
        runId,
        context.AccountId,
        run,
        cancellationToken).ConfigureAwait(false);
    await InsertRunOperationAsync(
        connection,
        transaction,
        command.OperationUid,
        "open_run",
        requestSha256,
        expected: null,
        runId,
        run,
        teamOrdinal: null,
        receiptId: null,
        resultId: null,
        consumedDailyAttempt: consumesOnOpen,
        dailyResultRevisionId: consumesOnOpen ? daily.RevisionId : null,
        abandonmentUid: null,
        abandonReasonCode: null,
        requestingContext: null,
        observed,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    await AdvanceRunHeadAsync(
        connection,
        transaction,
        runId,
        command.OperationUid,
        revisionId,
        run,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return new App.ChallengeRunProjection(run);
  }

  private Task<App.ChallengeRunProjection> ExecuteOwnedRunMutationAsync(
      EntityUid operationUid,
      App.SessionRequestPin requestPin,
      EntityUid runUid,
      EntityUid expectedRunRevisionUid,
      string operationKind,
      Sha256Digest requestSha256,
      int? teamOrdinal,
      Func<StoredRun, DateTimeOffset, PrivateServerDomain.ChallengeRun> transition,
      Func<StoredRun, PrivateServerDomain.ChallengeRun,
          PrivateServerDomain.LabHarnessTeamResultReceipt?>? receiptFactory,
      EntityUid? resultUid,
      EntityUid? abandonmentUid,
      string? abandonReasonCode,
      CancellationToken cancellationToken) => RunStoreAsync(async () =>
  {
    RequireUid(operationUid, "operation_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        WriteIsolation,
        cancellationToken).ConfigureAwait(false);
    await AcquireRunOperationLockAsync(
        connection,
        transaction,
        operationUid,
        cancellationToken).ConfigureAwait(false);
    var replay = await LoadRunOperationAsync(
        connection,
        transaction,
        operationUid,
        cancellationToken).ConfigureAwait(false);
    if (replay is not null)
    {
      RequireRunReplay(replay, operationKind, requestSha256);
      var replayObserved = NormalizeInstant(requestPin.ObservedAtUtc);
      var replayContext = await RequireCurrentContextAsync(
          connection,
          transaction,
          requestPin.SessionUid,
          requestPin.ClientContextUid,
          requestPin.ExpectedContextRevisionUid,
          replayObserved,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(replayContext);
      var replayed = await RequireRunRevisionAsync(
          connection,
          transaction,
          replay.ResultRevisionId,
          cancellationToken).ConfigureAwait(false);
      RequireOwnedRun(replayContext, replayed);
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.ChallengeRunProjection(replayed.Run);
    }

    var observed = NormalizeInstant(requestPin.ObservedAtUtc);
    var context = await RequireCurrentContextAsync(
        connection,
        transaction,
        requestPin.SessionUid,
        requestPin.ClientContextUid,
        requestPin.ExpectedContextRevisionUid,
        observed,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false);
    RequireLobbyReady(context);
    var stored = await LoadRunByUidAsync(
        connection,
        transaction,
        runUid,
        revisionId: null,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.NotFound,
            "challenge_run_not_found");
    RequireOwnedRun(context, stored);
    if (stored.Run.RunRevisionUid != expectedRunRevisionUid)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_run_revision_conflict");
    }

    var next = transition(stored, observed);
    var receipt = receiptFactory?.Invoke(stored, next);
    long? receiptId = null;
    if (receipt is not null)
    {
      receiptId = await InsertDamageReceiptAsync(
          connection,
          transaction,
          stored,
          receipt,
          next.CumulativeDamage,
          cancellationToken).ConfigureAwait(false);
    }

    var consumes = operationKind switch
    {
      "enter_team" => teamOrdinal == 1 && next.TransitionConsumesAttempt(
          PrivateServerDomain.ChallengeEntryConsumptionPoint.FirstTeamEntered),
      "close_run" => next.TransitionConsumesAttempt(
          PrivateServerDomain.ChallengeEntryConsumptionPoint.RunClosed),
      "abandon_run" => next.AbandonmentConsumesAttempt,
      _ => false
    };
    StoredDailyState? consumedDaily = null;
    if (consumes)
    {
      var policy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          next.Binding.OperationalPolicyUid,
          cancellationToken).ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.Unavailable,
              "challenge_run_policy_missing");
      consumedDaily = await ConsumeDailyStateAsync(
          connection,
          transaction,
          stored.DailyStateId,
          policy.Policy,
          operationUid,
          observed,
          cancellationToken).ConfigureAwait(false);
    }

    long? resultId = null;
    if (resultUid.HasValue)
    {
      resultId = await InsertRunResultAsync(
          connection,
          transaction,
          stored.Id,
          next,
          resultUid.Value,
          cancellationToken).ConfigureAwait(false);
    }

    var revisionId = await InsertRunRevisionAsync(
        connection,
        transaction,
        stored.Id,
        stored.AccountId,
        next,
        cancellationToken).ConfigureAwait(false);
    var ledgerTeamOrdinal = operationKind == "regroup"
        ? next.Attempts.Count
        : teamOrdinal;
    await InsertRunOperationAsync(
        connection,
        transaction,
        operationUid,
        operationKind,
        requestSha256,
        stored,
        stored.Id,
        next,
        ledgerTeamOrdinal,
        receiptId,
        resultId,
        consumes,
        consumedDaily?.RevisionId,
        abandonmentUid,
        abandonReasonCode,
        requestingContext: null,
        observed,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    await AdvanceRunHeadAsync(
        connection,
        transaction,
        stored.Id,
        operationUid,
        revisionId,
        next,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return new App.ChallengeRunProjection(next);
  });

  private async Task<App.RecoveredChallengeRunProjection>
      RecoverStrandedChallengeRunCoreAsync(
          App.RecoverStrandedChallengeRunCommand command,
          Sha256Digest requestSha256,
          CancellationToken cancellationToken)
  {
    RequireUid(command.OperationUid, "operation_uid_invalid");
    await using var connection = await _dataSource.OpenConnectionAsync(cancellationToken)
        .ConfigureAwait(false);
    await using var transaction = await connection.BeginTransactionAsync(
        WriteIsolation,
        cancellationToken).ConfigureAwait(false);
    await AcquireRunOperationLockAsync(
        connection,
        transaction,
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    var replay = await LoadRunOperationAsync(
        connection,
        transaction,
        command.OperationUid,
        cancellationToken).ConfigureAwait(false);
    if (replay is not null)
    {
      RequireRunReplay(replay, "recover_stranded_run", requestSha256);
      var replayObserved = NormalizeInstant(command.RequestPin.ObservedAtUtc);
      var activeRequester = await RequireCurrentContextAsync(
          connection,
          transaction,
          command.RequestPin.SessionUid,
          command.RequestPin.ClientContextUid,
          command.RequestPin.ExpectedContextRevisionUid,
          replayObserved,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false);
      RequireLobbyReady(activeRequester);
      var replayed = await RequireRunRevisionAsync(
          connection,
          transaction,
          replay.ResultRevisionId,
          cancellationToken).ConfigureAwait(false);
      var replayContext = await LoadRequestingContextForOperationAsync(
          connection,
          transaction,
          command.OperationUid,
          cancellationToken).ConfigureAwait(false);
      if (activeRequester.AccountId != replayed.AccountId ||
          activeRequester.Context.ContextRevisionUid !=
              replayContext.Context.ContextRevisionUid)
      {
        throw Failure(
            App.PrivateServerFailureKind.Forbidden,
            "challenge_recovery_requester_mismatch");
      }
      await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
      return new App.RecoveredChallengeRunProjection(
          Project(replayContext.Context),
          new App.ChallengeRunProjection(replayed.Run));
    }

    var observed = NormalizeInstant(command.RequestPin.ObservedAtUtc);
    var requester = await RequireCurrentContextAsync(
        connection,
        transaction,
        command.RequestPin.SessionUid,
        command.RequestPin.ClientContextUid,
        command.RequestPin.ExpectedContextRevisionUid,
        observed,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false);
    RequireLobbyReady(requester);
    var stored = await LoadRunByUidAsync(
        connection,
        transaction,
        command.RunUid,
        revisionId: null,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.NotFound,
            "challenge_run_not_found");
    if (stored.AccountId != requester.AccountId)
    {
      throw Failure(App.PrivateServerFailureKind.Forbidden, "challenge_run_account_mismatch");
    }

    if (stored.Run.RunRevisionUid != command.ExpectedRunRevisionUid)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_run_revision_conflict");
    }

    await RequireOwningSessionInactiveAsync(
        connection,
        transaction,
        stored.ContextId,
        observed,
        cancellationToken).ConfigureAwait(false);
    var abandonmentUid = _uidGenerator.NewUid();
    var next = stored.Run.RecoverAfterOwningSessionInactive(
        _uidGenerator.NewUid(),
        abandonmentUid,
        observed);
    var consumes = next.AbandonmentConsumesAttempt;
    StoredDailyState? consumedDaily = null;
    if (consumes)
    {
      var policy = await LoadPolicyByUidAsync(
          connection,
          transaction,
          next.Binding.OperationalPolicyUid,
          cancellationToken).ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.Unavailable,
              "challenge_run_policy_missing");
      consumedDaily = await ConsumeDailyStateAsync(
          connection,
          transaction,
          stored.DailyStateId,
          policy.Policy,
          command.OperationUid,
          observed,
          cancellationToken).ConfigureAwait(false);
    }

    var revisionId = await InsertRunRevisionAsync(
        connection,
        transaction,
        stored.Id,
        stored.AccountId,
        next,
        cancellationToken).ConfigureAwait(false);
    await InsertRunOperationAsync(
        connection,
        transaction,
        command.OperationUid,
        "recover_stranded_run",
        requestSha256,
        stored,
        stored.Id,
        next,
        teamOrdinal: null,
        receiptId: null,
        resultId: null,
        consumedDailyAttempt: consumes,
        dailyResultRevisionId: consumedDaily?.RevisionId,
        abandonmentUid,
        PrivateServerDomain.ChallengeRun.OwningSessionInactiveRecoveryReasonCode,
        requester,
        observed,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    await AdvanceRunHeadAsync(
        connection,
        transaction,
        stored.Id,
        command.OperationUid,
        revisionId,
        next,
        cancellationToken).ConfigureAwait(false);
    await transaction.CommitAsync(cancellationToken).ConfigureAwait(false);
    return new App.RecoveredChallengeRunProjection(
        Project(requester.Context),
        new App.ChallengeRunProjection(next));
  }

  private static async Task AcquireRunOperationLockAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        "SELECT pg_advisory_xact_lock(hashtextextended(@operation_uid, @seed))",
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Text, operationUid.ToString());
    Add(command, "seed", NpgsqlDbType.Bigint, PrivateServerRunOperationLockSeed);
    _ = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task<StoredRunOperation?> LoadRunOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT operation.operation_kind, operation.request_sha256,
               operation.result_challenge_run_revision_id,
               operation.challenge_run_uid
          FROM lab_private_server.challenge_run_operation operation
         WHERE operation.operation_uid = @operation_uid
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    return await reader.ReadAsync(cancellationToken).ConfigureAwait(false)
        ? new StoredRunOperation(
            reader.GetString(0),
            Digest(reader.GetValue(1)),
            reader.GetInt64(2),
            Uid(reader.GetValue(3)))
        : null;
  }

  private async Task<App.ChallengeRunProjection?>
      LoadActiveChallengeRunForSoloRaidAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long accountId,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT challenge_run_uid
          FROM lab_private_server.challenge_run
         WHERE local_account_id = @account_id
           AND status NOT IN ('completed', 'abandoned')
        """,
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null or DBNull)
    {
      return null;
    }

    var stored = await LoadRunByUidAsync(
        connection,
        transaction,
        Uid(value),
        revisionId: null,
        forUpdate: false,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "active_challenge_run_missing");
    if (stored.AccountId != accountId)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "active_challenge_run_account_mismatch");
    }

    return new App.ChallengeRunProjection(stored.Run);
  }

  private static void RequireRunReplay(
      StoredRunOperation replay,
      string expectedKind,
      Sha256Digest expectedRequestSha256)
  {
    if (!string.Equals(replay.Kind, expectedKind, StringComparison.Ordinal) ||
        replay.RequestSha256 != expectedRequestSha256)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "operation_uid_payload_conflict");
    }
  }

  private static void RequireRunRequestPin(App.SessionRequestPin? requestPin)
  {
    if (requestPin is null)
    {
      throw Failure(
          App.PrivateServerFailureKind.InvalidRequest,
          "session_request_pin_invalid");
    }
  }

  private static void RequireOwnedRun(StoredContext context, StoredRun run)
  {
    if (run.AccountId != context.AccountId || run.ContextId != context.Id ||
        run.Run.Binding.AccountUid != context.Context.AccountUid ||
        run.Run.Binding.SessionUid != context.Context.SessionUid ||
        run.Run.Binding.ClientContextUid != context.Context.ClientContextUid)
    {
      throw Failure(App.PrivateServerFailureKind.Forbidden, "challenge_run_owner_mismatch");
    }
  }

  private static async Task RequireOwningSessionInactiveAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long contextId,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT session.expires_at_utc, session.revoked_at_utc
          FROM lab_private_server.local_client_context context
          JOIN lab_profile.local_session session
            ON session.local_session_id = context.local_session_id
         WHERE context.local_client_context_id = @context_id
         FOR UPDATE OF session
        """,
        connection,
        transaction);
    Add(command, "context_id", NpgsqlDbType.Bigint, contextId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "challenge_run_owner_not_found");
    }

    var expires = Instant(reader.GetValue(0));
    var revoked = !reader.IsDBNull(1);
    if (!revoked && observedAtUtc < expires)
    {
      throw Failure(
          App.PrivateServerFailureKind.Forbidden,
          "challenge_run_owning_session_still_active");
    }
  }

  private static async Task<StoredContext> LoadRequestingContextForOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid operationUid,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT revision.local_client_context_revision_uid
          FROM lab_private_server.challenge_run_operation operation
          JOIN lab_private_server.local_client_context_revision revision
            ON revision.local_client_context_revision_id =
               operation.requesting_local_client_context_revision_id
         WHERE operation.operation_uid = @operation_uid
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    var value = await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (value is null or DBNull)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_recovery_context_missing");
    }

    return await LoadContextByRevisionUidAsync(
        connection,
        transaction,
        Uid(value),
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_recovery_context_missing");
  }

  private async Task<StoredDailyState> GetOrCreateDailyStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      StoredContext context,
      StoredBoot boot,
      StoredSelection selection,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    var policy = boot.Projection.OperationalPolicy.Policy;
    policy.RequireAdmissionReady();
    var scope = policy.DailyCounterScope.RequireConfigured();
    var raidDay = PrivateServerDomain.AsiaSeoulRaidDay.GetKey(observedAtUtc);
    var snapshotUid = scope == PrivateServerDomain.DailyCounterScope.PerSeason
        ? selection.Revision.Member.RaidSnapshotUid
        : (EntityUid?)null;
    var snapshotId = snapshotUid.HasValue
        ? await ResolveSelectedSnapshotIdAsync(
            connection,
            transaction,
            selection.RevisionId,
            cancellationToken).ConfigureAwait(false)
        : (long?)null;
    await using var lookup = new NpgsqlCommand(
        """
        SELECT challenge_daily_state_id
          FROM lab_private_server.challenge_daily_state
         WHERE local_account_id = @account_id
           AND challenge_operational_policy_id = @policy_id
           AND raid_season_directory_id = @directory_id
           AND raid_day_key = @raid_day
           AND counter_scope = @counter_scope
           AND raid_snapshot_id IS NOT DISTINCT FROM @snapshot_id
         FOR UPDATE
        """,
        connection,
        transaction);
    Add(lookup, "account_id", NpgsqlDbType.Bigint, context.AccountId);
    Add(lookup, "policy_id", NpgsqlDbType.Bigint, boot.PolicyId);
    Add(lookup, "directory_id", NpgsqlDbType.Bigint, boot.DirectoryId);
    Add(lookup, "raid_day", NpgsqlDbType.Date, raidDay.Date);
    Add(
        lookup,
        "counter_scope",
        NpgsqlDbType.Text,
        PrivateServerDomain.ChallengeOperationalPolicy.Code(scope));
    Add(lookup, "snapshot_id", NpgsqlDbType.Bigint, snapshotId);
    var found = await lookup.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
    if (found is not null and not DBNull)
    {
      return await LoadDailyStateByIdAsync(
          connection,
          transaction,
          Convert.ToInt64(found, CultureInfo.InvariantCulture),
          revisionId: null,
          forUpdate: true,
          cancellationToken).ConfigureAwait(false);
    }

    var daily = PrivateServerDomain.ChallengeDailyStateRevision.Open(
        _uidGenerator.NewUid(),
        _uidGenerator.NewUid(),
        context.Context.AccountUid,
        raidDay,
        snapshotUid,
        boot.Projection.Directory.Directory,
        policy);
    long stateId;
    await using (var insert = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_daily_state (
            challenge_daily_state_uid, local_account_id,
            challenge_operational_policy_id, policy_content_sha256,
            raid_season_directory_id, raid_day_key, counter_scope,
            raid_snapshot_id, first_observed_at_utc
        ) VALUES (
            @state_uid, @account_id, @policy_id, @policy_sha256,
            @directory_id, @raid_day, @counter_scope, @snapshot_id, @observed_at_utc
        )
        RETURNING challenge_daily_state_id
        """,
        connection,
        transaction))
    {
      Add(insert, "state_uid", NpgsqlDbType.Uuid, daily.DailyStateUid.Value);
      Add(insert, "account_id", NpgsqlDbType.Bigint, context.AccountId);
      Add(insert, "policy_id", NpgsqlDbType.Bigint, boot.PolicyId);
      Add(insert, "policy_sha256", NpgsqlDbType.Bytea, policy.ContentSha256.ToByteArray());
      Add(insert, "directory_id", NpgsqlDbType.Bigint, boot.DirectoryId);
      Add(insert, "raid_day", NpgsqlDbType.Date, daily.RaidDayKey.Date);
      Add(insert, "counter_scope", NpgsqlDbType.Text,
          PrivateServerDomain.ChallengeOperationalPolicy.Code(scope));
      Add(insert, "snapshot_id", NpgsqlDbType.Bigint, snapshotId);
      Add(insert, "observed_at_utc", NpgsqlDbType.TimestampTz, observedAtUtc);
      stateId = Convert.ToInt64(
          await insert.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    var revisionId = await InsertDailyStateRevisionAsync(
        connection,
        transaction,
        stateId,
        context.AccountId,
        boot.PolicyId,
        boot.DirectoryId,
        snapshotId,
        daily,
        consumptionOperationUid: null,
        observedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await AdvanceDailyHeadAsync(
        connection,
        transaction,
        stateId,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    return new StoredDailyState(stateId, revisionId, daily);
  }

  private async Task<StoredDailyState> ConsumeDailyStateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long dailyStateId,
      PrivateServerDomain.ChallengeOperationalPolicy policy,
      EntityUid operationUid,
      DateTimeOffset observedAtUtc,
      CancellationToken cancellationToken)
  {
    var current = await LoadDailyStateByIdAsync(
        connection,
        transaction,
        dailyStateId,
        revisionId: null,
        forUpdate: true,
        cancellationToken).ConfigureAwait(false);
    var next = current.Revision.ConsumeEntry(_uidGenerator.NewUid(), policy);
    var ids = await LoadDailyTopologyIdsAsync(
        connection,
        transaction,
        dailyStateId,
        cancellationToken).ConfigureAwait(false);
    var revisionId = await InsertDailyStateRevisionAsync(
        connection,
        transaction,
        dailyStateId,
        ids.AccountId,
        ids.PolicyId,
        ids.DirectoryId,
        ids.SnapshotId,
        next,
        operationUid,
        observedAtUtc,
        cancellationToken).ConfigureAwait(false);
    await AdvanceDailyHeadAsync(
        connection,
        transaction,
        dailyStateId,
        revisionId,
        cancellationToken).ConfigureAwait(false);
    return new StoredDailyState(dailyStateId, revisionId, next);
  }

  private static async Task<StoredDailyState> LoadDailyStateByIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long dailyStateId,
      long? revisionId,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    var revisionJoin = revisionId.HasValue
        ? "revision.challenge_daily_state_revision_id = @revision_id"
        : "revision.challenge_daily_state_revision_id = state.current_challenge_daily_state_revision_id";
    var sql = $"""
        SELECT state.challenge_daily_state_id,
               revision.challenge_daily_state_revision_id,
               state.challenge_daily_state_uid,
               revision.challenge_daily_state_revision_uid,
               revision.revision_number,
               previous.challenge_daily_state_revision_uid,
               account.local_account_uid,
               policy.challenge_operational_policy_uid,
               state.policy_content_sha256,
               directory.raid_season_directory_uid,
               directory.content_sha256,
               state.raid_day_key,
               state.counter_scope,
               snapshot.raid_snapshot_uid,
               revision.consumed_entries,
               revision.content_sha256
          FROM lab_private_server.challenge_daily_state state
          JOIN lab_private_server.challenge_daily_state_revision revision
            ON {revisionJoin}
           AND revision.challenge_daily_state_id = state.challenge_daily_state_id
          JOIN lab_profile.local_account account
            ON account.local_account_id = state.local_account_id
          JOIN lab_private_server.challenge_operational_policy policy
            ON policy.challenge_operational_policy_id =
               state.challenge_operational_policy_id
          JOIN lab_private_server.raid_season_directory directory
            ON directory.raid_season_directory_id = state.raid_season_directory_id
          LEFT JOIN lab_raid.raid_snapshot snapshot
            ON snapshot.raid_snapshot_id = state.raid_snapshot_id
          LEFT JOIN lab_private_server.challenge_daily_state_revision previous
            ON previous.challenge_daily_state_revision_id =
               revision.previous_challenge_daily_state_revision_id
         WHERE state.challenge_daily_state_id = @state_id
         {(forUpdate ? "FOR UPDATE OF state" : string.Empty)}
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    Add(command, "state_id", NpgsqlDbType.Bigint, dailyStateId);
    if (revisionId.HasValue)
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId.Value);
    }

    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "challenge_daily_state_not_found");
    }

    var daily = PrivateServerDomain.ChallengeDailyStateRevision.Restore(
        Uid(reader.GetValue(2)),
        Uid(reader.GetValue(3)),
        reader.GetInt32(4),
        NullableUid(reader.GetValue(5)),
        Uid(reader.GetValue(6)),
        Uid(reader.GetValue(7)),
        Digest(reader.GetValue(8)),
        Uid(reader.GetValue(9)),
        Digest(reader.GetValue(10)),
        PrivateServerDomain.RaidDayKey.FromDate(Date(reader.GetValue(11))),
        ParseDailyCounterScope(reader.GetString(12)),
        NullableUid(reader.GetValue(13)),
        reader.GetInt32(14));
    if (daily.ContentSha256 != Digest(reader.GetValue(15)))
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_daily_state_persisted_content_invalid");
    }

    return new StoredDailyState(reader.GetInt64(0), reader.GetInt64(1), daily);
  }

  private static async Task<(long AccountId, long PolicyId, long DirectoryId,
      long? SnapshotId)> LoadDailyTopologyIdsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long dailyStateId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT local_account_id, challenge_operational_policy_id,
               raid_season_directory_id, raid_snapshot_id
          FROM lab_private_server.challenge_daily_state
         WHERE challenge_daily_state_id = @state_id
         FOR UPDATE
        """,
        connection,
        transaction);
    Add(command, "state_id", NpgsqlDbType.Bigint, dailyStateId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(App.PrivateServerFailureKind.NotFound, "challenge_daily_state_not_found");
    }

    return (
        reader.GetInt64(0),
        reader.GetInt64(1),
        reader.GetInt64(2),
        reader.IsDBNull(3) ? null : reader.GetInt64(3));
  }

  private static async Task<long> InsertDailyStateRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateId,
      long accountId,
      long policyId,
      long directoryId,
      long? snapshotId,
      PrivateServerDomain.ChallengeDailyStateRevision revision,
      EntityUid? consumptionOperationUid,
      DateTimeOffset materializedAtUtc,
      CancellationToken cancellationToken)
  {
    long? previousId = null;
    if (revision.PredecessorRevisionUid.HasValue)
    {
      await using var previous = new NpgsqlCommand(
          """
          SELECT challenge_daily_state_revision_id
            FROM lab_private_server.challenge_daily_state_revision
           WHERE challenge_daily_state_revision_uid = @revision_uid
             AND challenge_daily_state_id = @state_id
          """,
          connection,
          transaction);
      Add(previous, "revision_uid", NpgsqlDbType.Uuid,
          revision.PredecessorRevisionUid.Value.Value);
      Add(previous, "state_id", NpgsqlDbType.Bigint, stateId);
      previousId = Convert.ToInt64(
          await previous.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
              throw Failure(
                  App.PrivateServerFailureKind.Conflict,
                  "challenge_daily_predecessor_not_found"),
          CultureInfo.InvariantCulture);
    }

    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_daily_state_revision (
            challenge_daily_state_revision_uid, challenge_daily_state_id,
            local_account_id, challenge_operational_policy_id,
            raid_season_directory_id, raid_day_key, counter_scope,
            raid_snapshot_id, revision_number,
            previous_challenge_daily_state_revision_id, consumed_entries,
            consumption_operation_uid, content_sha256, materialized_at_utc
        ) VALUES (
            @revision_uid, @state_id, @account_id, @policy_id,
            @directory_id, @raid_day, @counter_scope, @snapshot_id,
            @revision_number, @previous_id, @consumed_entries,
            @operation_uid, @content_sha256, @materialized_at_utc
        )
        RETURNING challenge_daily_state_revision_id
        """,
        connection,
        transaction);
    Add(command, "revision_uid", NpgsqlDbType.Uuid, revision.DailyStateRevisionUid.Value);
    Add(command, "state_id", NpgsqlDbType.Bigint, stateId);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "policy_id", NpgsqlDbType.Bigint, policyId);
    Add(command, "directory_id", NpgsqlDbType.Bigint, directoryId);
    Add(command, "raid_day", NpgsqlDbType.Date, revision.RaidDayKey.Date);
    Add(command, "counter_scope", NpgsqlDbType.Text,
        PrivateServerDomain.ChallengeOperationalPolicy.Code(revision.CounterScope));
    Add(command, "snapshot_id", NpgsqlDbType.Bigint, snapshotId);
    Add(command, "revision_number", NpgsqlDbType.Integer,
        checked((int)revision.RevisionNumber));
    Add(command, "previous_id", NpgsqlDbType.Bigint, previousId);
    Add(command, "consumed_entries", NpgsqlDbType.Integer, revision.ConsumedEntries);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, consumptionOperationUid?.Value);
    Add(command, "content_sha256", NpgsqlDbType.Bytea,
        revision.ContentSha256.ToByteArray());
    Add(command, "materialized_at_utc", NpgsqlDbType.TimestampTz, materializedAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
  }

  private static async Task AdvanceDailyHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long stateId,
      long revisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_daily_state
           SET current_challenge_daily_state_revision_id = @revision_id
         WHERE challenge_daily_state_id = @state_id
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    Add(command, "state_id", NpgsqlDbType.Bigint, stateId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_daily_head_conflict");
    }
  }

  private static async Task<IReadOnlyList<StoredTeam>> LoadRequestedTeamsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long accountId,
      StoredAccountPins pins,
      IReadOnlyList<EntityUid> orderedSquadRevisionUids,
      CancellationToken cancellationToken)
  {
    var teams = new List<StoredTeam>(orderedSquadRevisionUids.Count);
    for (var index = 0; index < orderedSquadRevisionUids.Count; index++)
    {
      await using var squadCommand = new NpgsqlCommand(
          """
          SELECT revision.squad_revision_id, squad.local_squad_uid,
                 revision.squad_revision_uid, revision.content_sha256,
                 revision.selection_readiness_status
            FROM lab_profile.squad_revision revision
            JOIN lab_profile.local_squad squad
              ON squad.local_squad_id = revision.local_squad_id
           WHERE revision.squad_revision_uid = @revision_uid
             AND revision.local_account_id = @account_id
          """,
          connection,
          transaction);
      Add(squadCommand, "revision_uid", NpgsqlDbType.Uuid,
          orderedSquadRevisionUids[index].Value);
      Add(squadCommand, "account_id", NpgsqlDbType.Bigint, accountId);
      long squadRevisionId;
      EntityUid squadUid;
      EntityUid squadRevisionUid;
      Sha256Digest squadSha256;
      await using (var reader = await squadCommand.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false))
      {
        if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          throw Failure(App.PrivateServerFailureKind.NotFound,
              "challenge_squad_revision_not_found");
        }

        if (!string.Equals(reader.GetString(4), "ready", StringComparison.Ordinal))
        {
          throw Failure(App.PrivateServerFailureKind.Conflict,
              "challenge_squad_revision_not_ready");
        }

        squadRevisionId = reader.GetInt64(0);
        squadUid = Uid(reader.GetValue(1));
        squadRevisionUid = Uid(reader.GetValue(2));
        squadSha256 = Digest(reader.GetValue(3));
      }

      var members = new List<StoredTeamMember>(5);
      await using var memberCommand = new NpgsqlCommand(
          """
          SELECT member.position, character.character_uid,
                 build.character_build_id, build.character_build_uid,
                 revision.build_revision_id, revision.build_revision_uid,
                 revision.content_sha256, build.character_entity_id
            FROM lab_profile.squad_revision_member member
            JOIN lab_profile.character_build build
              ON build.character_build_id = member.character_build_id
            JOIN lab_catalog.character_entity character
              ON character.character_entity_id = build.character_entity_id
            JOIN lab_profile.character_build_revision revision
              ON revision.build_revision_id = member.build_revision_id
            JOIN lab_profile.profile_template_revision_build profile_member
              ON profile_member.profile_template_revision_id = @profile_revision_id
             AND profile_member.character_build_id = member.character_build_id
             AND profile_member.build_revision_id = member.build_revision_id
           WHERE member.squad_revision_id = @squad_revision_id
           ORDER BY member.position
          """,
          connection,
          transaction);
      Add(memberCommand, "profile_revision_id", NpgsqlDbType.Bigint,
          pins.ProfileTemplateRevisionId);
      Add(memberCommand, "squad_revision_id", NpgsqlDbType.Bigint, squadRevisionId);
      await using (var reader = await memberCommand.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false))
      {
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          var pin = new PrivateServerDomain.ChallengeCharacterPin(
              reader.GetInt16(0),
              Uid(reader.GetValue(1)),
              Uid(reader.GetValue(3)),
              Uid(reader.GetValue(5)),
              Digest(reader.GetValue(6)));
          members.Add(new StoredTeamMember(
              reader.GetInt64(7),
              reader.GetInt64(2),
              reader.GetInt64(4),
              pin));
        }
      }

      var teamPin = PrivateServerDomain.ChallengeTeamPin.Restore(
          index + 1,
          pins.ProfileTemplateRevisionUid,
          pins.ProfileTemplateContentSha256,
          pins.AccountStateRevisionUid,
          squadUid,
          squadRevisionUid,
          squadSha256,
          members.Select(static member => member.Pin));
      teams.Add(new StoredTeam(squadRevisionId, teamPin, members));
    }

    _ = new PrivateServerDomain.ChallengeRunPlan(
        teams.Select(static team => team.Pin));
    return teams;
  }

  private static async Task<(long RuntimeRevisionId, long ControlRevisionId)>
      ResolveExecutionRevisionIdsAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction transaction,
          long accountId,
          EntityUid runtimeRevisionUid,
          EntityUid controlRevisionUid,
          CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT runtime_revision.runtime_execution_profile_revision_id,
               control_revision.combat_control_profile_revision_id
          FROM lab_private_server.runtime_execution_profile runtime_profile
          JOIN lab_private_server.runtime_execution_profile_revision runtime_revision
            ON runtime_revision.runtime_execution_profile_revision_id =
               runtime_profile.current_runtime_execution_profile_revision_id
          JOIN lab_private_server.combat_control_profile control_profile
            ON control_profile.local_account_id = runtime_profile.local_account_id
          JOIN lab_private_server.combat_control_profile_revision control_revision
            ON control_revision.combat_control_profile_revision_id =
               control_profile.current_combat_control_profile_revision_id
         WHERE runtime_profile.local_account_id = @account_id
           AND runtime_revision.runtime_execution_profile_revision_uid = @runtime_uid
           AND control_revision.combat_control_profile_revision_uid = @control_uid
         FOR UPDATE OF runtime_profile, control_profile
        """,
        connection,
        transaction);
    Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
    Add(command, "runtime_uid", NpgsqlDbType.Uuid, runtimeRevisionUid.Value);
    Add(command, "control_uid", NpgsqlDbType.Uuid, controlRevisionUid.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "challenge_execution_profile_head_conflict");
    }

    return (reader.GetInt64(0), reader.GetInt64(1));
  }

  private static async Task<long> ResolveSelectedSnapshotIdAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long selectionRevisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT raid_snapshot_id
          FROM lab_private_server.selected_raid_season_revision
         WHERE selected_raid_season_revision_id = @revision_id
        """,
        connection,
        transaction);
    Add(command, "revision_id", NpgsqlDbType.Bigint, selectionRevisionId);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
            throw Failure(
                App.PrivateServerFailureKind.NotFound,
                "selected_raid_snapshot_not_found"),
        CultureInfo.InvariantCulture);
  }

  private static async Task<long> InsertRunAggregateAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      StoredContext context,
      StoredSelection selection,
      StoredBoot boot,
      StoredAccountPins pins,
      StoredDailyState daily,
      long raidSnapshotId,
      long runtimeRevisionId,
      long controlRevisionId,
      PrivateServerDomain.ChallengeRun run,
      CancellationToken cancellationToken)
  {
    var shape = RunShape(run);
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run (
            challenge_run_uid, local_account_id, local_client_context_id,
            local_client_context_revision_id, selected_raid_season_revision_id,
            raid_season_directory_id, raid_snapshot_id,
            profile_template_revision_id, account_state_revision_id,
            runtime_execution_profile_revision_id,
            combat_control_profile_revision_id,
            challenge_policy_activation_revision_id,
            challenge_operational_policy_id, challenge_daily_state_id,
            admission_daily_state_revision_id,
            admission_daily_state_content_sha256, opening_raid_day_key,
            execution_lane, is_mock_battle, configured_team_count,
            status, state_version, next_team_ordinal, active_team_ordinal,
            accepted_team_count, canonical_cumulative_damage,
            cumulative_damage, final_result_uid, abandonment_uid,
            abandon_reason_code, last_operation_uid, binding_sha256,
            opened_at_utc, updated_at_utc
        ) VALUES (
            @run_uid, @account_id, @context_id, @context_revision_id,
            @selection_revision_id, @directory_id, @snapshot_id,
            @profile_revision_id, @account_state_revision_id,
            @runtime_revision_id, @control_revision_id,
            @activation_revision_id, @policy_id, @daily_state_id,
            @daily_revision_id, @daily_sha256, @raid_day,
            @execution_lane, @is_mock, @team_count,
            @status, @state_version, @next_team, @active_team,
            @accepted_count, @canonical_damage, @damage,
            @result_uid, @abandonment_uid, @abandon_reason,
            @operation_uid, @binding_sha256, @opened_at, @updated_at
        )
        RETURNING challenge_run_id
        """,
        connection,
        transaction);
    Add(command, "run_uid", NpgsqlDbType.Uuid, run.RunUid.Value);
    Add(command, "account_id", NpgsqlDbType.Bigint, context.AccountId);
    Add(command, "context_id", NpgsqlDbType.Bigint, context.Id);
    Add(command, "context_revision_id", NpgsqlDbType.Bigint, context.RevisionId);
    Add(command, "selection_revision_id", NpgsqlDbType.Bigint, selection.RevisionId);
    Add(command, "directory_id", NpgsqlDbType.Bigint, boot.DirectoryId);
    Add(command, "snapshot_id", NpgsqlDbType.Bigint, raidSnapshotId);
    Add(command, "profile_revision_id", NpgsqlDbType.Bigint,
        pins.ProfileTemplateRevisionId);
    Add(command, "account_state_revision_id", NpgsqlDbType.Bigint,
        pins.AccountStateRevisionId);
    Add(command, "runtime_revision_id", NpgsqlDbType.Bigint, runtimeRevisionId);
    Add(command, "control_revision_id", NpgsqlDbType.Bigint, controlRevisionId);
    Add(command, "activation_revision_id", NpgsqlDbType.Bigint,
        boot.ActivationRevisionId);
    Add(command, "policy_id", NpgsqlDbType.Bigint, boot.PolicyId);
    Add(command, "daily_state_id", NpgsqlDbType.Bigint, daily.Id);
    Add(command, "daily_revision_id", NpgsqlDbType.Bigint, daily.RevisionId);
    Add(command, "daily_sha256", NpgsqlDbType.Bytea,
        daily.Revision.ContentSha256.ToByteArray());
    Add(command, "raid_day", NpgsqlDbType.Date, run.Binding.RaidDayKey.Date);
    Add(command, "execution_lane", NpgsqlDbType.Text, run.Binding.ExecutionSourceCode);
    Add(command, "is_mock", NpgsqlDbType.Boolean, run.Binding.IsMockBattle);
    Add(command, "team_count", NpgsqlDbType.Smallint,
        checked((short)run.Binding.Plan.Teams.Count));
    AddRunShape(command, run, shape);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "binding_sha256", NpgsqlDbType.Bytea,
        run.Binding.ContentSha256.ToByteArray());
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
  }

  private static async Task InsertRunTeamsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      long accountId,
      long profileRevisionId,
      IReadOnlyList<StoredTeam> teams,
      CancellationToken cancellationToken)
  {
    foreach (var team in teams)
    {
      await using (var command = new NpgsqlCommand(
          """
          INSERT INTO lab_private_server.challenge_run_team (
              challenge_run_id, team_ordinal, local_account_id,
              profile_template_revision_id, squad_revision_id,
              squad_revision_uid, squad_content_sha256, team_content_sha256
          ) VALUES (
              @run_id, @ordinal, @account_id, @profile_revision_id,
              @squad_revision_id, @squad_revision_uid,
              @squad_sha256, @team_sha256
          )
          """,
          connection,
          transaction))
      {
        Add(command, "run_id", NpgsqlDbType.Bigint, runId);
        Add(command, "ordinal", NpgsqlDbType.Smallint, checked((short)team.Pin.Ordinal));
        Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
        Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profileRevisionId);
        Add(command, "squad_revision_id", NpgsqlDbType.Bigint, team.SquadRevisionId);
        Add(command, "squad_revision_uid", NpgsqlDbType.Uuid,
            team.Pin.SquadRevisionUid.Value);
        Add(command, "squad_sha256", NpgsqlDbType.Bytea,
            team.Pin.SquadContentSha256.ToByteArray());
        Add(command, "team_sha256", NpgsqlDbType.Bytea,
            team.Pin.ContentSha256.ToByteArray());
        _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }

      foreach (var member in team.Members)
      {
        await using var command = new NpgsqlCommand(
            """
            INSERT INTO lab_private_server.challenge_run_team_member (
                challenge_run_id, team_ordinal, local_account_id, position,
                profile_template_revision_id, squad_revision_id,
                character_entity_id, character_build_id, build_revision_id
            ) VALUES (
                @run_id, @team_ordinal, @account_id, @position,
                @profile_revision_id, @squad_revision_id,
                @character_id, @build_id, @build_revision_id
            )
            """,
            connection,
            transaction);
        Add(command, "run_id", NpgsqlDbType.Bigint, runId);
        Add(command, "team_ordinal", NpgsqlDbType.Smallint,
            checked((short)team.Pin.Ordinal));
        Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
        Add(command, "position", NpgsqlDbType.Smallint, checked((short)member.Pin.Slot));
        Add(command, "profile_revision_id", NpgsqlDbType.Bigint, profileRevisionId);
        Add(command, "squad_revision_id", NpgsqlDbType.Bigint, team.SquadRevisionId);
        Add(command, "character_id", NpgsqlDbType.Bigint, member.CharacterEntityId);
        Add(command, "build_id", NpgsqlDbType.Bigint, member.CharacterBuildId);
        Add(command, "build_revision_id", NpgsqlDbType.Bigint, member.BuildRevisionId);
        _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
      }
    }
  }

  private static async Task<long> InsertRunRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      long accountId,
      PrivateServerDomain.ChallengeRun run,
      CancellationToken cancellationToken)
  {
    long? predecessorId = null;
    if (run.PredecessorRevisionUid.HasValue)
    {
      await using var predecessor = new NpgsqlCommand(
          """
          SELECT challenge_run_revision_id
            FROM lab_private_server.challenge_run_revision
           WHERE challenge_run_revision_uid = @revision_uid
             AND challenge_run_id = @run_id
          """,
          connection,
          transaction);
      Add(predecessor, "revision_uid", NpgsqlDbType.Uuid,
          run.PredecessorRevisionUid.Value.Value);
      Add(predecessor, "run_id", NpgsqlDbType.Bigint, runId);
      predecessorId = Convert.ToInt64(
          await predecessor.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
              throw Failure(
                  App.PrivateServerFailureKind.Conflict,
                  "challenge_run_predecessor_not_found"),
          CultureInfo.InvariantCulture);
    }

    var shape = RunShape(run);
    long revisionId;
    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_revision (
            challenge_run_revision_uid, challenge_run_id, challenge_run_uid,
            local_account_id, revision_number,
            previous_challenge_run_revision_id, status,
            next_team_ordinal, active_team_ordinal, accepted_team_count,
            canonical_cumulative_damage, cumulative_damage,
            final_result_uid, abandonment_uid, abandon_reason_code,
            opened_at_utc, updated_at_utc, content_sha256
        ) VALUES (
            @run_revision_uid, @run_id, @run_uid, @account_id,
            @state_version, @predecessor_id, @status,
            @next_team, @active_team, @accepted_count,
            @canonical_damage, @damage, @result_uid,
            @abandonment_uid, @abandon_reason, @opened_at, @updated_at,
            @content_sha256
        )
        RETURNING challenge_run_revision_id
        """,
        connection,
        transaction))
    {
      Add(command, "run_revision_uid", NpgsqlDbType.Uuid, run.RunRevisionUid.Value);
      Add(command, "run_id", NpgsqlDbType.Bigint, runId);
      Add(command, "run_uid", NpgsqlDbType.Uuid, run.RunUid.Value);
      Add(command, "account_id", NpgsqlDbType.Bigint, accountId);
      Add(command, "predecessor_id", NpgsqlDbType.Bigint, predecessorId);
      AddRunShape(command, run, shape);
      Add(command, "content_sha256", NpgsqlDbType.Bytea, run.ContentSha256.ToByteArray());
      revisionId = Convert.ToInt64(
          await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    for (var index = 0; index < run.Attempts.Count; index++)
    {
      var attempt = run.Attempts[index];
      long? receiptId = null;
      if (attempt.ResultReceipt is not null)
      {
        await using var receiptLookup = new NpgsqlCommand(
            """
            SELECT challenge_team_damage_receipt_id
              FROM lab_private_server.challenge_team_damage_receipt
             WHERE challenge_team_damage_receipt_uid = @receipt_uid
            """,
            connection,
            transaction);
        Add(receiptLookup, "receipt_uid", NpgsqlDbType.Uuid,
            attempt.ResultReceipt.ReceiptUid.Value);
        receiptId = Convert.ToInt64(
            await receiptLookup.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false) ??
                throw Failure(
                    App.PrivateServerFailureKind.Unavailable,
                    "challenge_damage_receipt_missing"),
            CultureInfo.InvariantCulture);
      }

      await using var attemptCommand = new NpgsqlCommand(
          """
          INSERT INTO lab_private_server.challenge_run_revision_attempt (
              challenge_run_revision_id, challenge_run_id, attempt_ordinal,
              team_ordinal, team_content_sha256, entered_at_utc,
              challenge_team_damage_receipt_id, receipt_sha256
          ) VALUES (
              @revision_id, @run_id, @attempt_ordinal, @team_ordinal,
              @team_sha256, @entered_at_utc, @receipt_id, @receipt_sha256
          )
          """,
          connection,
          transaction);
      Add(attemptCommand, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(attemptCommand, "run_id", NpgsqlDbType.Bigint, runId);
      Add(attemptCommand, "attempt_ordinal", NpgsqlDbType.Smallint,
          checked((short)(index + 1)));
      Add(attemptCommand, "team_ordinal", NpgsqlDbType.Smallint,
          checked((short)attempt.Team.Ordinal));
      Add(attemptCommand, "team_sha256", NpgsqlDbType.Bytea,
          attempt.Team.ContentSha256.ToByteArray());
      Add(attemptCommand, "entered_at_utc", NpgsqlDbType.TimestampTz,
          attempt.EnteredAtUtc);
      Add(attemptCommand, "receipt_id", NpgsqlDbType.Bigint, receiptId);
      Add(attemptCommand, "receipt_sha256", NpgsqlDbType.Bytea,
          attempt.ResultReceipt?.ContentSha256.ToByteArray());
      _ = await attemptCommand.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return revisionId;
  }

  private static async Task<long> InsertDamageReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      StoredRun stored,
      PrivateServerDomain.LabHarnessTeamResultReceipt receipt,
      PrivateServerDomain.NonNegativeIntegerDamage cumulativeDamage,
      CancellationToken cancellationToken)
  {
    var telemetry = receipt.Telemetry;
    long receiptId;
    await using (var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_team_damage_receipt (
            challenge_team_damage_receipt_uid, challenge_run_id,
            team_ordinal, local_account_id, observation_source,
            canonical_damage, damage_value, canonical_cumulative_damage,
            cumulative_damage_value, telemetry_contract_id,
            telemetry_sha256, render_frame_count, behavior_tick_count,
            fixed_update_count, wall_clock_microseconds,
            frame_time_median_milliseconds, frame_time_p95_milliseconds,
            frame_time_p99_milliseconds, dropped_frame_count,
            stalled_frame_count, telemetry_warning_count, segment_count,
            warning_count, receipt_sha256, observed_at_utc
        ) VALUES (
            @receipt_uid, @run_id, @team_ordinal, @account_id,
            @observation_source, @canonical_damage, @damage,
            @canonical_cumulative_damage, @cumulative_damage,
            @telemetry_contract_id, @telemetry_sha256,
            @render_frames, @behavior_ticks, @fixed_updates,
            @wall_clock_us, @median_ms, @p95_ms, @p99_ms,
            @dropped_frames, @stalled_frames, @telemetry_warning_count,
            @segment_count, @warning_count, @receipt_sha256, @observed_at
        )
        RETURNING challenge_team_damage_receipt_id
        """,
        connection,
        transaction))
    {
      Add(command, "receipt_uid", NpgsqlDbType.Uuid, receipt.ReceiptUid.Value);
      Add(command, "run_id", NpgsqlDbType.Bigint, stored.Id);
      Add(command, "team_ordinal", NpgsqlDbType.Smallint,
          checked((short)receipt.Team.Ordinal));
      Add(command, "account_id", NpgsqlDbType.Bigint, stored.AccountId);
      Add(command, "observation_source", NpgsqlDbType.Text,
          receipt.ObservationSourceCode);
      Add(command, "canonical_damage", NpgsqlDbType.Text,
          receipt.ObservedDamage.CanonicalDigits);
      Add(command, "damage", NpgsqlDbType.Numeric, receipt.ObservedDamage.ToBigInteger());
      Add(command, "canonical_cumulative_damage", NpgsqlDbType.Text,
          cumulativeDamage.CanonicalDigits);
      Add(command, "cumulative_damage", NpgsqlDbType.Numeric,
          cumulativeDamage.ToBigInteger());
      Add(command, "telemetry_contract_id", NpgsqlDbType.Text,
          PrivateServerDomain.BattleFrameTelemetry.ContractId);
      Add(command, "telemetry_sha256", NpgsqlDbType.Bytea,
          telemetry.ContentSha256.ToByteArray());
      Add(command, "render_frames", NpgsqlDbType.Bigint, telemetry.RenderFrameCount);
      Add(command, "behavior_ticks", NpgsqlDbType.Bigint, telemetry.BehaviorTickCount);
      Add(command, "fixed_updates", NpgsqlDbType.Bigint, telemetry.FixedUpdateCount);
      Add(command, "wall_clock_us", NpgsqlDbType.Bigint, telemetry.WallClockMicroseconds);
      Add(command, "median_ms", NpgsqlDbType.Numeric,
          telemetry.FrameTimeMedianMilliseconds);
      Add(command, "p95_ms", NpgsqlDbType.Numeric, telemetry.FrameTimeP95Milliseconds);
      Add(command, "p99_ms", NpgsqlDbType.Numeric, telemetry.FrameTimeP99Milliseconds);
      Add(command, "dropped_frames", NpgsqlDbType.Bigint, telemetry.DroppedFrameCount);
      Add(command, "stalled_frames", NpgsqlDbType.Bigint, telemetry.StalledFrameCount);
      Add(command, "telemetry_warning_count", NpgsqlDbType.Smallint,
          checked((short)telemetry.WarningCodes.Count));
      Add(command, "segment_count", NpgsqlDbType.Smallint,
          checked((short)receipt.ExecutionSegments.Count));
      Add(command, "warning_count", NpgsqlDbType.Smallint,
          checked((short)receipt.WarningCodes.Count));
      Add(command, "receipt_sha256", NpgsqlDbType.Bytea,
          receipt.ContentSha256.ToByteArray());
      Add(command, "observed_at", NpgsqlDbType.TimestampTz, receipt.ObservedAtUtc);
      receiptId = Convert.ToInt64(
          await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
          CultureInfo.InvariantCulture);
    }

    await InsertWarningCodesAsync(
        connection,
        transaction,
        "challenge_team_telemetry_warning",
        receiptId,
        telemetry.WarningCodes,
        cancellationToken).ConfigureAwait(false);
    await InsertWarningCodesAsync(
        connection,
        transaction,
        "challenge_team_damage_warning",
        receiptId,
        receipt.WarningCodes,
        cancellationToken).ConfigureAwait(false);
    foreach (var segment in receipt.ExecutionSegments)
    {
      await using var command = new NpgsqlCommand(
          """
          INSERT INTO lab_private_server.challenge_execution_segment (
              challenge_team_damage_receipt_id, challenge_run_id,
              team_ordinal, local_account_id, segment_ordinal,
              runtime_execution_profile_revision_id,
              combat_control_profile_revision_id,
              start_render_frame, end_render_frame,
              start_behavior_tick, end_behavior_tick,
              start_fixed_update, end_fixed_update,
              start_wall_clock_microseconds, end_wall_clock_microseconds,
              canonical_start_damage, start_damage,
              canonical_end_damage, end_damage
          ) VALUES (
              @receipt_id, @run_id, @team_ordinal, @account_id, @ordinal,
              @runtime_revision_id, @control_revision_id,
              @start_render, @end_render, @start_tick, @end_tick,
              @start_fixed, @end_fixed, @start_wall, @end_wall,
              @canonical_start_damage, @start_damage,
              @canonical_end_damage, @end_damage
          )
          """,
          connection,
          transaction);
      Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
      Add(command, "run_id", NpgsqlDbType.Bigint, stored.Id);
      Add(command, "team_ordinal", NpgsqlDbType.Smallint,
          checked((short)receipt.Team.Ordinal));
      Add(command, "account_id", NpgsqlDbType.Bigint, stored.AccountId);
      Add(command, "ordinal", NpgsqlDbType.Smallint, checked((short)segment.Ordinal));
      Add(command, "runtime_revision_id", NpgsqlDbType.Bigint,
          stored.RuntimeRevisionId);
      Add(command, "control_revision_id", NpgsqlDbType.Bigint,
          stored.ControlRevisionId);
      Add(command, "start_render", NpgsqlDbType.Bigint, segment.StartRenderFrame);
      Add(command, "end_render", NpgsqlDbType.Bigint, segment.EndRenderFrame);
      Add(command, "start_tick", NpgsqlDbType.Bigint, segment.StartBehaviorTick);
      Add(command, "end_tick", NpgsqlDbType.Bigint, segment.EndBehaviorTick);
      Add(command, "start_fixed", NpgsqlDbType.Bigint, segment.StartFixedUpdate);
      Add(command, "end_fixed", NpgsqlDbType.Bigint, segment.EndFixedUpdate);
      Add(command, "start_wall", NpgsqlDbType.Bigint,
          segment.StartWallClockMicroseconds);
      Add(command, "end_wall", NpgsqlDbType.Bigint,
          segment.EndWallClockMicroseconds);
      Add(command, "canonical_start_damage", NpgsqlDbType.Text,
          segment.StartDamage.CanonicalDigits);
      Add(command, "start_damage", NpgsqlDbType.Numeric,
          segment.StartDamage.ToBigInteger());
      Add(command, "canonical_end_damage", NpgsqlDbType.Text,
          segment.EndDamage.CanonicalDigits);
      Add(command, "end_damage", NpgsqlDbType.Numeric,
          segment.EndDamage.ToBigInteger());
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    return receiptId;
  }

  private static async Task InsertWarningCodesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      string tableName,
      long receiptId,
      IReadOnlyList<string> warningCodes,
      CancellationToken cancellationToken)
  {
    if (tableName is not ("challenge_team_damage_warning" or
        "challenge_team_telemetry_warning"))
    {
      throw new InvalidOperationException("challenge_warning_table_invalid");
    }

    for (var index = 0; index < warningCodes.Count; index++)
    {
      await using var command = new NpgsqlCommand(
          $"""
          INSERT INTO lab_private_server.{tableName} (
              challenge_team_damage_receipt_id, ordinal, warning_code
          ) VALUES (@receipt_id, @ordinal, @warning_code)
          """,
          connection,
          transaction);
      Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
      Add(command, "ordinal", NpgsqlDbType.Smallint, checked((short)(index + 1)));
      Add(command, "warning_code", NpgsqlDbType.Text, warningCodes[index]);
      _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }
  }

  private static async Task<long> InsertRunResultAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      PrivateServerDomain.ChallengeRun run,
      EntityUid resultUid,
      CancellationToken cancellationToken)
  {
    var resultSha256 = RequestHash(
        "nll/challenge-run-result/v1",
        run.RunUid,
        resultUid,
        run.Attempts.Count,
        run.CumulativeDamage.CanonicalDigits,
        run.UpdatedAtUtc);
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_result (
            challenge_run_result_uid, challenge_run_id,
            accepted_team_count, canonical_total_damage, total_damage,
            result_sha256, completed_at_utc
        ) VALUES (
            @result_uid, @run_id, @accepted_count,
            @canonical_damage, @damage, @result_sha256, @completed_at
        )
        RETURNING challenge_run_result_id
        """,
        connection,
        transaction);
    Add(command, "result_uid", NpgsqlDbType.Uuid, resultUid.Value);
    Add(command, "run_id", NpgsqlDbType.Bigint, runId);
    Add(command, "accepted_count", NpgsqlDbType.Smallint,
        checked((short)run.Attempts.Count));
    Add(command, "canonical_damage", NpgsqlDbType.Text,
        run.CumulativeDamage.CanonicalDigits);
    Add(command, "damage", NpgsqlDbType.Numeric, run.CumulativeDamage.ToBigInteger());
    Add(command, "result_sha256", NpgsqlDbType.Bytea, resultSha256.ToByteArray());
    Add(command, "completed_at", NpgsqlDbType.TimestampTz, run.UpdatedAtUtc);
    return Convert.ToInt64(
        await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false),
        CultureInfo.InvariantCulture);
  }

  private static async Task InsertRunOperationAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      EntityUid operationUid,
      string operationKind,
      Sha256Digest requestSha256,
      StoredRun? expected,
      long runId,
      PrivateServerDomain.ChallengeRun run,
      int? teamOrdinal,
      long? receiptId,
      long? resultId,
      bool consumedDailyAttempt,
      long? dailyResultRevisionId,
      EntityUid? abandonmentUid,
      string? abandonReasonCode,
      StoredContext? requestingContext,
      DateTimeOffset completedAtUtc,
      long revisionId,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        INSERT INTO lab_private_server.challenge_run_operation (
            operation_uid, operation_kind, request_sha256,
            challenge_run_uid, expected_run_revision_uid,
            expected_state_version, result_challenge_run_revision_id,
            result_run_revision_uid, result_run_content_sha256,
            result_state_version, result_status, team_ordinal,
            challenge_team_damage_receipt_id, challenge_run_result_id,
            consumed_daily_attempt, result_daily_state_revision_id,
            abandonment_uid, abandon_reason_code,
            requesting_local_account_id,
            requesting_local_client_context_revision_id,
            completed_at_utc
        ) VALUES (
            @operation_uid, @operation_kind, @request_sha256,
            @run_uid, @expected_revision_uid, @expected_state_version,
            @result_revision_id, @result_revision_uid, @result_sha256,
            @result_state_version, @result_status, @team_ordinal,
            @receipt_id, @result_id, @consumed_daily,
            @daily_revision_id, @abandonment_uid, @abandon_reason,
            @requesting_account_id, @requesting_context_revision_id,
            @completed_at
        )
        """,
        connection,
        transaction);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "operation_kind", NpgsqlDbType.Text, operationKind);
    Add(command, "request_sha256", NpgsqlDbType.Bytea, requestSha256.ToByteArray());
    Add(command, "run_uid", NpgsqlDbType.Uuid, run.RunUid.Value);
    Add(command, "expected_revision_uid", NpgsqlDbType.Uuid,
        expected?.Run.RunRevisionUid.Value);
    Add(command, "expected_state_version", NpgsqlDbType.Integer,
        expected is null ? null : checked((int)expected.Run.RevisionNumber));
    Add(command, "result_revision_id", NpgsqlDbType.Bigint, revisionId);
    Add(command, "result_revision_uid", NpgsqlDbType.Uuid, run.RunRevisionUid.Value);
    Add(command, "result_sha256", NpgsqlDbType.Bytea, run.ContentSha256.ToByteArray());
    Add(command, "result_state_version", NpgsqlDbType.Integer,
        checked((int)run.RevisionNumber));
    Add(command, "result_status", NpgsqlDbType.Text,
        PrivateServerDomain.ChallengeRun.StateCode(run.State));
    Add(command, "team_ordinal", NpgsqlDbType.Smallint,
        teamOrdinal.HasValue ? checked((short)teamOrdinal.Value) : null);
    Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
    Add(command, "result_id", NpgsqlDbType.Bigint, resultId);
    Add(command, "consumed_daily", NpgsqlDbType.Boolean, consumedDailyAttempt);
    Add(command, "daily_revision_id", NpgsqlDbType.Bigint, dailyResultRevisionId);
    Add(command, "abandonment_uid", NpgsqlDbType.Uuid, abandonmentUid?.Value);
    Add(command, "abandon_reason", NpgsqlDbType.Text, abandonReasonCode);
    Add(command, "requesting_account_id", NpgsqlDbType.Bigint,
        requestingContext?.AccountId);
    Add(command, "requesting_context_revision_id", NpgsqlDbType.Bigint,
        requestingContext?.RevisionId);
    Add(command, "completed_at", NpgsqlDbType.TimestampTz, completedAtUtc);
    _ = await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
  }

  private static async Task AdvanceRunHeadAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction transaction,
      long runId,
      EntityUid operationUid,
      long revisionId,
      PrivateServerDomain.ChallengeRun run,
      CancellationToken cancellationToken)
  {
    var shape = RunShape(run);
    await using var command = new NpgsqlCommand(
        """
        UPDATE lab_private_server.challenge_run
           SET status = @status,
               state_version = @state_version,
               next_team_ordinal = @next_team,
               active_team_ordinal = @active_team,
               accepted_team_count = @accepted_count,
               canonical_cumulative_damage = @canonical_damage,
               cumulative_damage = @damage,
               final_result_uid = @result_uid,
               abandonment_uid = @abandonment_uid,
               abandon_reason_code = @abandon_reason,
               last_operation_uid = @operation_uid,
               current_challenge_run_revision_id = @revision_id,
               updated_at_utc = @updated_at
         WHERE challenge_run_id = @run_id
        """,
        connection,
        transaction);
    AddRunShape(command, run, shape);
    Add(command, "operation_uid", NpgsqlDbType.Uuid, operationUid.Value);
    Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
    Add(command, "run_id", NpgsqlDbType.Bigint, runId);
    if (await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false) != 1)
    {
      throw Failure(App.PrivateServerFailureKind.Conflict, "challenge_run_head_conflict");
    }
  }

  private static (short? NextTeam, short? ActiveTeam, short AcceptedCount)
      RunShape(PrivateServerDomain.ChallengeRun run)
  {
    var accepted = checked((short)run.Attempts.Count(static attempt =>
        attempt.ResultReceipt is not null));
    return run.State switch
    {
      PrivateServerDomain.ChallengeRunState.Open => (1, null, 0),
      PrivateServerDomain.ChallengeRunState.TeamInProgress =>
          (checked((short)run.Attempts.Count), checked((short)run.Attempts.Count), accepted),
      PrivateServerDomain.ChallengeRunState.TeamResultAccepted =>
          (checked((short)run.Attempts.Count), checked((short)run.Attempts.Count), accepted),
      PrivateServerDomain.ChallengeRunState.RegroupReady =>
          (checked((short)(accepted + 1)), null, accepted),
      PrivateServerDomain.ChallengeRunState.Completed or
          PrivateServerDomain.ChallengeRunState.Abandoned => (null, null, accepted),
      _ => throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_run_state_invalid")
    };
  }

  private static void AddRunShape(
      NpgsqlCommand command,
      PrivateServerDomain.ChallengeRun run,
      (short? NextTeam, short? ActiveTeam, short AcceptedCount) shape)
  {
    Add(command, "status", NpgsqlDbType.Text,
        PrivateServerDomain.ChallengeRun.StateCode(run.State));
    Add(command, "state_version", NpgsqlDbType.Integer, checked((int)run.RevisionNumber));
    Add(command, "next_team", NpgsqlDbType.Smallint, shape.NextTeam);
    Add(command, "active_team", NpgsqlDbType.Smallint, shape.ActiveTeam);
    Add(command, "accepted_count", NpgsqlDbType.Smallint, shape.AcceptedCount);
    Add(command, "canonical_damage", NpgsqlDbType.Text,
        run.CumulativeDamage.CanonicalDigits);
    Add(command, "damage", NpgsqlDbType.Numeric, run.CumulativeDamage.ToBigInteger());
    Add(command, "result_uid", NpgsqlDbType.Uuid, run.FinalResultUid?.Value);
    Add(command, "abandonment_uid", NpgsqlDbType.Uuid, run.AbandonmentUid?.Value);
    Add(command, "abandon_reason", NpgsqlDbType.Text, run.AbandonReasonCode);
    Add(command, "opened_at", NpgsqlDbType.TimestampTz, run.OpenedAtUtc);
    Add(command, "updated_at", NpgsqlDbType.TimestampTz, run.UpdatedAtUtc);
  }

  private async Task<StoredRun> RequireRunRevisionAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long revisionId,
      CancellationToken cancellationToken) =>
      await LoadRunByUidAsync(
          connection,
          transaction,
          runUid: null,
          revisionId,
          forUpdate: false,
          cancellationToken).ConfigureAwait(false) ?? throw Failure(
              App.PrivateServerFailureKind.Unavailable,
              "challenge_run_operation_result_missing");

  private Task<StoredRun?> LoadRunByUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid runUid,
      long? revisionId,
      bool forUpdate,
      CancellationToken cancellationToken) => LoadRunByUidAsync(
      connection,
      transaction,
      (EntityUid?)runUid,
      revisionId,
      forUpdate,
      cancellationToken);

  private async Task<StoredRun?> LoadRunByUidAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      EntityUid? runUid,
      long? revisionId,
      bool forUpdate,
      CancellationToken cancellationToken)
  {
    if (!runUid.HasValue && !revisionId.HasValue)
    {
      throw new ArgumentException("A run or revision identity is required.");
    }

    var revisionJoin = revisionId.HasValue
        ? "revision.challenge_run_revision_id = @revision_id"
        : "revision.challenge_run_revision_id = run.current_challenge_run_revision_id";
    var predicate = runUid.HasValue
        ? "run.challenge_run_uid = @run_uid"
        : "revision.challenge_run_revision_id = @revision_id";
    var sql = $"""
        SELECT run.challenge_run_id,
               revision.challenge_run_revision_id,
               run.local_account_id,
               run.local_client_context_id,
               run.challenge_daily_state_id,
               run.runtime_execution_profile_revision_id,
               run.combat_control_profile_revision_id,
               run.challenge_run_uid,
               context_revision.local_client_context_revision_uid,
               run.selected_raid_season_revision_id,
               run.raid_season_directory_id,
               run.raid_snapshot_id,
               run.profile_template_revision_id,
               run.account_state_revision_id,
               run.challenge_operational_policy_id,
               run.admission_daily_state_revision_id,
               run.binding_sha256,
               revision.challenge_run_revision_uid,
               revision.revision_number,
               previous.challenge_run_revision_uid,
               revision.status,
               revision.opened_at_utc,
               revision.updated_at_utc,
               revision.canonical_cumulative_damage,
               revision.final_result_uid,
               revision.abandonment_uid,
               revision.abandon_reason_code,
               run.is_mock_battle,
               run.opening_raid_day_key,
               runtime_revision.runtime_execution_profile_revision_uid,
               runtime_revision.content_sha256,
               control_revision.combat_control_profile_revision_uid,
               control_revision.content_sha256,
               profile.profile_template_revision_uid,
               profile.content_sha256,
               account_state.account_state_revision_uid,
               policy.challenge_operational_policy_uid,
               policy.content_sha256,
               revision.content_sha256
          FROM lab_private_server.challenge_run run
          JOIN lab_private_server.challenge_run_revision revision
            ON {revisionJoin}
           AND revision.challenge_run_id = run.challenge_run_id
          LEFT JOIN lab_private_server.challenge_run_revision previous
            ON previous.challenge_run_revision_id =
               revision.previous_challenge_run_revision_id
          JOIN lab_private_server.local_client_context_revision context_revision
            ON context_revision.local_client_context_revision_id =
               run.local_client_context_revision_id
          JOIN lab_private_server.runtime_execution_profile_revision runtime_revision
            ON runtime_revision.runtime_execution_profile_revision_id =
               run.runtime_execution_profile_revision_id
          JOIN lab_private_server.combat_control_profile_revision control_revision
            ON control_revision.combat_control_profile_revision_id =
               run.combat_control_profile_revision_id
          JOIN lab_profile.profile_template_revision profile
            ON profile.profile_template_revision_id = run.profile_template_revision_id
          JOIN lab_profile.account_state_revision account_state
            ON account_state.account_state_revision_id = run.account_state_revision_id
          JOIN lab_private_server.challenge_operational_policy policy
            ON policy.challenge_operational_policy_id =
               run.challenge_operational_policy_id
         WHERE {predicate}
         {(forUpdate ? "FOR UPDATE OF run" : string.Empty)}
        """;
    await using var command = new NpgsqlCommand(sql, connection, transaction);
    if (runUid.HasValue)
    {
      Add(command, "run_uid", NpgsqlDbType.Uuid, runUid.Value.Value);
    }

    if (revisionId.HasValue)
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId.Value);
    }

    long runId;
    long loadedRevisionId;
    long accountId;
    long contextId;
    long dailyStateId;
    long runtimeRevisionId;
    long controlRevisionId;
    EntityUid loadedRunUid;
    EntityUid contextRevisionUid;
    long selectionRevisionId;
    long directoryId;
    long snapshotId;
    long profileRevisionId;
    long accountStateRevisionId;
    long policyId;
    long admissionDailyRevisionId;
    Sha256Digest storedBindingSha256;
    EntityUid loadedRunRevisionUid;
    long revisionNumber;
    EntityUid? predecessorUid;
    string statusCode;
    DateTimeOffset openedAtUtc;
    DateTimeOffset updatedAtUtc;
    string canonicalDamage;
    EntityUid? finalResultUid;
    EntityUid? abandonmentUid;
    string? abandonReason;
    bool isMock;
    PrivateServerDomain.RaidDayKey openingDay;
    EntityUid runtimeUid;
    Sha256Digest runtimeSha;
    EntityUid controlUid;
    Sha256Digest controlSha;
    EntityUid profileUid;
    Sha256Digest profileSha;
    EntityUid accountStateUid;
    EntityUid policyUid;
    Sha256Digest policySha;
    Sha256Digest storedRunSha;
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false))
    {
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        return null;
      }

      runId = reader.GetInt64(0);
      loadedRevisionId = reader.GetInt64(1);
      accountId = reader.GetInt64(2);
      contextId = reader.GetInt64(3);
      dailyStateId = reader.GetInt64(4);
      runtimeRevisionId = reader.GetInt64(5);
      controlRevisionId = reader.GetInt64(6);
      loadedRunUid = Uid(reader.GetValue(7));
      contextRevisionUid = Uid(reader.GetValue(8));
      selectionRevisionId = reader.GetInt64(9);
      directoryId = reader.GetInt64(10);
      snapshotId = reader.GetInt64(11);
      profileRevisionId = reader.GetInt64(12);
      accountStateRevisionId = reader.GetInt64(13);
      policyId = reader.GetInt64(14);
      admissionDailyRevisionId = reader.GetInt64(15);
      storedBindingSha256 = Digest(reader.GetValue(16));
      loadedRunRevisionUid = Uid(reader.GetValue(17));
      revisionNumber = reader.GetInt32(18);
      predecessorUid = NullableUid(reader.GetValue(19));
      statusCode = reader.GetString(20);
      openedAtUtc = Instant(reader.GetValue(21));
      updatedAtUtc = Instant(reader.GetValue(22));
      canonicalDamage = reader.GetString(23);
      finalResultUid = NullableUid(reader.GetValue(24));
      abandonmentUid = NullableUid(reader.GetValue(25));
      abandonReason = reader.IsDBNull(26) ? null : reader.GetString(26);
      isMock = reader.GetBoolean(27);
      openingDay = PrivateServerDomain.RaidDayKey.FromDate(Date(reader.GetValue(28)));
      runtimeUid = Uid(reader.GetValue(29));
      runtimeSha = Digest(reader.GetValue(30));
      controlUid = Uid(reader.GetValue(31));
      controlSha = Digest(reader.GetValue(32));
      profileUid = Uid(reader.GetValue(33));
      profileSha = Digest(reader.GetValue(34));
      accountStateUid = Uid(reader.GetValue(35));
      policyUid = Uid(reader.GetValue(36));
      policySha = Digest(reader.GetValue(37));
      storedRunSha = Digest(reader.GetValue(38));
    }

    var context = await LoadContextByRevisionUidAsync(
        connection,
        transaction,
        contextRevisionUid,
        cancellationToken).ConfigureAwait(false) ?? throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_run_context_missing");
    var boot = await LoadBootByIdAsync(
        connection,
        transaction,
        context.BootId,
        cancellationToken).ConfigureAwait(false);
    var selection = await LoadSelectionAsync(
        connection,
        transaction,
        context,
        requireCurrent: false,
        cancellationToken).ConfigureAwait(false);
    var selectedSnapshotId = await ResolveSelectedSnapshotIdAsync(
        connection,
        transaction,
        selection.RevisionId,
        cancellationToken).ConfigureAwait(false);
    var daily = await LoadDailyStateByIdAsync(
        connection,
        transaction,
        dailyStateId,
        admissionDailyRevisionId,
        forUpdate: false,
        cancellationToken).ConfigureAwait(false);
    var storedPolicy = await LoadPolicyByIdAsync(
        connection,
        transaction,
        policyId,
        cancellationToken).ConfigureAwait(false);
    var runtime = await LoadRuntimeExecutionProfileRevisionAsync(
        connection,
        transaction,
        accountId,
        runtimeUid,
        cancellationToken).ConfigureAwait(false);
    var control = await LoadCombatControlProfileRevisionAsync(
        connection,
        transaction,
        accountId,
        controlUid,
        cancellationToken).ConfigureAwait(false);
    var teams = await LoadStoredTeamsAsync(
        connection,
        transaction,
        runId,
        profileUid,
        profileSha,
        accountStateUid,
        cancellationToken).ConfigureAwait(false);
    var plan = new PrivateServerDomain.ChallengeRunPlan(
        teams.Select(static team => team.Pin));
    var binding = PrivateServerDomain.ChallengeRunBinding.Restore(
        new PrivateServerDomain.ChallengeRunBindingSnapshot(
            context.Context.AccountUid,
            context.Context.SessionUid,
            context.Context.ClientContextUid,
            context.Context.ContextRevisionUid,
            context.Context.ApplicationBuildUid,
            context.Context.ApplicationBuildSha256,
            context.Context.ApplicationContractId,
            boot.Projection.CapabilityManifest.Manifest.ManifestUid,
            boot.Projection.CapabilityManifest.Manifest.ContentSha256,
            boot.Projection.Directory.Directory.DirectoryUid,
            boot.Projection.Directory.Directory.ContentSha256,
            daily.Revision.DailyStateUid,
            daily.Revision.DailyStateRevisionUid,
            daily.Revision.ContentSha256,
            selection.Revision.SelectionRevisionUid,
            selection.Revision.ContentSha256,
            selection.Revision.Member.RaidSnapshotUid,
            selection.Revision.Member.DatasetSnapshotUid,
            selection.Revision.Member.RaidSnapshotContentSha256,
            profileUid,
            profileSha,
            accountStateUid,
            runtimeUid,
            runtimeSha,
            controlUid,
            controlSha,
            policyUid,
            policySha,
            storedPolicy.Policy.EntryConsumptionPoint.RequireConfigured(),
            storedPolicy.Policy.ActiveRunAtReset.RequireConfigured(),
            storedPolicy.Policy.DailyCounterScope.RequireConfigured(),
            isMock,
            openingDay),
        plan);
    if (binding.ContentSha256 != storedBindingSha256 ||
        context.Id != contextId || context.AccountId != accountId ||
        selection.RevisionId != selectionRevisionId ||
        boot.DirectoryId != directoryId ||
        selectedSnapshotId != snapshotId ||
        selection.Revision.Member.RaidSnapshotUid != binding.RaidSnapshotUid ||
        runtime is null || runtime.ContentSha256 != runtimeSha ||
        control is null || control.ContentSha256 != controlSha ||
        storedPolicy.Policy.PolicyUid != policyUid ||
        storedPolicy.Policy.ContentSha256 != policySha)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_run_binding_persisted_content_invalid");
    }

    _ = profileRevisionId;
    _ = accountStateRevisionId;
    var attempts = await LoadRunAttemptsAsync(
        connection,
        transaction,
        runId,
        loadedRevisionId,
        plan,
        loadedRunUid,
        cancellationToken).ConfigureAwait(false);
    var run = PrivateServerDomain.ChallengeRun.Restore(
        loadedRunUid,
        loadedRunRevisionUid,
        revisionNumber,
        predecessorUid,
        binding,
        ParseRunState(statusCode),
        openedAtUtc,
        updatedAtUtc,
        attempts,
        PrivateServerDomain.NonNegativeIntegerDamage.Parse(canonicalDamage),
        finalResultUid,
        abandonmentUid,
        abandonReason);
    if (run.ContentSha256 != storedRunSha)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_run_persisted_content_invalid");
    }

    if (run.State == PrivateServerDomain.ChallengeRunState.Completed)
    {
      await RequireStoredRunResultAsync(
          connection,
          transaction,
          runId,
          run,
          cancellationToken).ConfigureAwait(false);
    }

    return new StoredRun(
        runId,
        loadedRevisionId,
        accountId,
        contextId,
        dailyStateId,
        runtimeRevisionId,
        controlRevisionId,
        run);
  }

  private static async Task RequireStoredRunResultAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long runId,
      PrivateServerDomain.ChallengeRun run,
      CancellationToken cancellationToken)
  {
    await using var command = new NpgsqlCommand(
        """
        SELECT challenge_run_result_uid, accepted_team_count,
               canonical_total_damage, result_sha256, completed_at_utc
          FROM lab_private_server.challenge_run_result
         WHERE challenge_run_id = @run_id
        """,
        connection,
        transaction);
    Add(command, "run_id", NpgsqlDbType.Bigint, runId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
        !run.FinalResultUid.HasValue)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_run_result_persisted_content_invalid");
    }

    var resultUid = Uid(reader.GetValue(0));
    var acceptedTeamCount = reader.GetInt16(1);
    var canonicalDamage = reader.GetString(2);
    var storedSha256 = Digest(reader.GetValue(3));
    var completedAtUtc = Instant(reader.GetValue(4));
    var expectedSha256 = RequestHash(
        "nll/challenge-run-result/v1",
        run.RunUid,
        resultUid,
        run.Attempts.Count,
        run.CumulativeDamage.CanonicalDigits,
        run.UpdatedAtUtc);
    if (resultUid != run.FinalResultUid.Value ||
        acceptedTeamCount != run.Attempts.Count ||
        !string.Equals(
            canonicalDamage,
            run.CumulativeDamage.CanonicalDigits,
            StringComparison.Ordinal) ||
        completedAtUtc != run.UpdatedAtUtc ||
        storedSha256 != expectedSha256 ||
        await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_run_result_persisted_content_invalid");
    }
  }

  private static async Task<IReadOnlyList<StoredTeam>> LoadStoredTeamsAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long runId,
      EntityUid profileRevisionUid,
      Sha256Digest profileSha256,
      EntityUid accountStateRevisionUid,
      CancellationToken cancellationToken)
  {
    var headers = new List<(int Ordinal, long SquadRevisionId, EntityUid SquadUid,
        EntityUid SquadRevisionUid, Sha256Digest SquadSha, Sha256Digest TeamSha)>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT team.team_ordinal, team.squad_revision_id,
               squad.local_squad_uid, team.squad_revision_uid,
               team.squad_content_sha256, team.team_content_sha256
          FROM lab_private_server.challenge_run_team team
          JOIN lab_profile.squad_revision revision
            ON revision.squad_revision_id = team.squad_revision_id
          JOIN lab_profile.local_squad squad
            ON squad.local_squad_id = revision.local_squad_id
         WHERE team.challenge_run_id = @run_id
         ORDER BY team.team_ordinal
        """,
        connection,
        transaction))
    {
      Add(command, "run_id", NpgsqlDbType.Bigint, runId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        headers.Add((
            reader.GetInt16(0),
            reader.GetInt64(1),
            Uid(reader.GetValue(2)),
            Uid(reader.GetValue(3)),
            Digest(reader.GetValue(4)),
            Digest(reader.GetValue(5))));
      }
    }

    var teams = new List<StoredTeam>(headers.Count);
    foreach (var header in headers)
    {
      var members = new List<StoredTeamMember>(5);
      await using var command = new NpgsqlCommand(
          """
          SELECT member.position, character.character_uid,
                 build.character_build_id, build.character_build_uid,
                 revision.build_revision_id, revision.build_revision_uid,
                 revision.content_sha256, build.character_entity_id
            FROM lab_private_server.challenge_run_team_member member
            JOIN lab_profile.character_build build
              ON build.character_build_id = member.character_build_id
            JOIN lab_catalog.character_entity character
              ON character.character_entity_id = member.character_entity_id
            JOIN lab_profile.character_build_revision revision
              ON revision.build_revision_id = member.build_revision_id
           WHERE member.challenge_run_id = @run_id
             AND member.team_ordinal = @team_ordinal
           ORDER BY member.position
          """,
          connection,
          transaction);
      Add(command, "run_id", NpgsqlDbType.Bigint, runId);
      Add(command, "team_ordinal", NpgsqlDbType.Smallint, checked((short)header.Ordinal));
      await using (var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false))
      {
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
          var pin = new PrivateServerDomain.ChallengeCharacterPin(
              reader.GetInt16(0),
              Uid(reader.GetValue(1)),
              Uid(reader.GetValue(3)),
              Uid(reader.GetValue(5)),
              Digest(reader.GetValue(6)));
          members.Add(new StoredTeamMember(
              reader.GetInt64(7),
              reader.GetInt64(2),
              reader.GetInt64(4),
              pin));
        }
      }

      var pinValue = PrivateServerDomain.ChallengeTeamPin.Restore(
          header.Ordinal,
          profileRevisionUid,
          profileSha256,
          accountStateRevisionUid,
          header.SquadUid,
          header.SquadRevisionUid,
          header.SquadSha,
          members.Select(static member => member.Pin));
      if (pinValue.ContentSha256 != header.TeamSha)
      {
        throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_run_team_persisted_content_invalid");
      }

      teams.Add(new StoredTeam(header.SquadRevisionId, pinValue, members));
    }

    return teams;
  }

  private static async Task<IReadOnlyList<PrivateServerDomain.ChallengeTeamAttempt>>
      LoadRunAttemptsAsync(
          NpgsqlConnection connection,
          NpgsqlTransaction? transaction,
          long runId,
          long revisionId,
          PrivateServerDomain.ChallengeRunPlan plan,
          EntityUid runUid,
          CancellationToken cancellationToken)
  {
    var rows = new List<(int Ordinal, DateTimeOffset EnteredAt, long? ReceiptId)>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT attempt.team_ordinal, attempt.entered_at_utc,
               attempt.challenge_team_damage_receipt_id
          FROM lab_private_server.challenge_run_revision_attempt attempt
         WHERE attempt.challenge_run_revision_id = @revision_id
           AND attempt.challenge_run_id = @run_id
         ORDER BY attempt.attempt_ordinal
        """,
        connection,
        transaction))
    {
      Add(command, "revision_id", NpgsqlDbType.Bigint, revisionId);
      Add(command, "run_id", NpgsqlDbType.Bigint, runId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        rows.Add((
            reader.GetInt16(0),
            Instant(reader.GetValue(1)),
            reader.IsDBNull(2) ? null : reader.GetInt64(2)));
      }
    }

    var attempts = new List<PrivateServerDomain.ChallengeTeamAttempt>(rows.Count);
    foreach (var row in rows)
    {
      if (row.Ordinal < 1 || row.Ordinal > plan.Teams.Count)
      {
        throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_run_attempt_persisted_content_invalid");
      }

      PrivateServerDomain.LabHarnessTeamResultReceipt? receipt = null;
      if (row.ReceiptId.HasValue)
      {
        receipt = (await LoadDamageReceiptAsync(
            connection,
            transaction,
            row.ReceiptId.Value,
            runId,
            runUid,
            plan.Teams[row.Ordinal - 1],
            cancellationToken).ConfigureAwait(false)).Receipt;
      }

      attempts.Add(new PrivateServerDomain.ChallengeTeamAttempt(
          plan.Teams[row.Ordinal - 1],
          row.EnteredAt,
          receipt));
    }

    return attempts;
  }

  private static async Task<StoredReceipt> LoadDamageReceiptAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      long receiptId,
      long runId,
      EntityUid runUid,
      PrivateServerDomain.ChallengeTeamPin team,
      CancellationToken cancellationToken)
  {
    EntityUid receiptUid;
    string source;
    string canonicalDamage;
    Sha256Digest storedTelemetrySha;
    long renderFrames;
    long behaviorTicks;
    long fixedUpdates;
    long wallClock;
    decimal median;
    decimal p95;
    decimal p99;
    long dropped;
    long stalled;
    Sha256Digest storedReceiptSha;
    DateTimeOffset observedAt;
    await using (var command = new NpgsqlCommand(
        """
        SELECT challenge_team_damage_receipt_uid, observation_source,
               canonical_damage, telemetry_sha256, render_frame_count,
               behavior_tick_count, fixed_update_count,
               wall_clock_microseconds, frame_time_median_milliseconds,
               frame_time_p95_milliseconds, frame_time_p99_milliseconds,
               dropped_frame_count, stalled_frame_count,
               receipt_sha256, observed_at_utc, team_ordinal
          FROM lab_private_server.challenge_team_damage_receipt
         WHERE challenge_team_damage_receipt_id = @receipt_id
           AND challenge_run_id = @run_id
        """,
        connection,
        transaction))
    {
      Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
      Add(command, "run_id", NpgsqlDbType.Bigint, runId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      if (!await reader.ReadAsync(cancellationToken).ConfigureAwait(false) ||
          reader.GetInt16(15) != team.Ordinal)
      {
        throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_damage_receipt_missing");
      }

      receiptUid = Uid(reader.GetValue(0));
      source = reader.GetString(1);
      canonicalDamage = reader.GetString(2);
      storedTelemetrySha = Digest(reader.GetValue(3));
      renderFrames = reader.GetInt64(4);
      behaviorTicks = reader.GetInt64(5);
      fixedUpdates = reader.GetInt64(6);
      wallClock = reader.GetInt64(7);
      median = reader.GetDecimal(8);
      p95 = reader.GetDecimal(9);
      p99 = reader.GetDecimal(10);
      dropped = reader.GetInt64(11);
      stalled = reader.GetInt64(12);
      storedReceiptSha = Digest(reader.GetValue(13));
      observedAt = Instant(reader.GetValue(14));
    }

    if (source != PrivateServerDomain.LabHarnessTeamResultReceipt.ObservationContractId)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_damage_observation_source_invalid");
    }

    var telemetryWarnings = await LoadWarningCodesAsync(
        connection,
        transaction,
        "challenge_team_telemetry_warning",
        receiptId,
        cancellationToken).ConfigureAwait(false);
    var warnings = await LoadWarningCodesAsync(
        connection,
        transaction,
        "challenge_team_damage_warning",
        receiptId,
        cancellationToken).ConfigureAwait(false);
    var telemetry = new PrivateServerDomain.BattleFrameTelemetry(
        renderFrames,
        behaviorTicks,
        fixedUpdates,
        wallClock,
        median,
        p95,
        p99,
        dropped,
        stalled,
        telemetryWarnings);
    if (telemetry.ContentSha256 != storedTelemetrySha)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_telemetry_persisted_content_invalid");
    }

    var segments = new List<PrivateServerDomain.ExecutionSegment>();
    await using (var command = new NpgsqlCommand(
        """
        SELECT segment.segment_ordinal,
               runtime.runtime_execution_profile_revision_uid,
               control.combat_control_profile_revision_uid,
               segment.start_render_frame, segment.end_render_frame,
               segment.start_behavior_tick, segment.end_behavior_tick,
               segment.start_fixed_update, segment.end_fixed_update,
               segment.start_wall_clock_microseconds,
               segment.end_wall_clock_microseconds,
               segment.canonical_start_damage, segment.canonical_end_damage
          FROM lab_private_server.challenge_execution_segment segment
          JOIN lab_private_server.runtime_execution_profile_revision runtime
            ON runtime.runtime_execution_profile_revision_id =
               segment.runtime_execution_profile_revision_id
          JOIN lab_private_server.combat_control_profile_revision control
            ON control.combat_control_profile_revision_id =
               segment.combat_control_profile_revision_id
         WHERE segment.challenge_team_damage_receipt_id = @receipt_id
         ORDER BY segment.segment_ordinal
        """,
        connection,
        transaction))
    {
      Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken)
          .ConfigureAwait(false);
      while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
      {
        segments.Add(new PrivateServerDomain.ExecutionSegment(
            reader.GetInt16(0),
            Uid(reader.GetValue(1)),
            Uid(reader.GetValue(2)),
            reader.GetInt64(3),
            reader.GetInt64(4),
            reader.GetInt64(5),
            reader.GetInt64(6),
            reader.GetInt64(7),
            reader.GetInt64(8),
            reader.GetInt64(9),
            reader.GetInt64(10),
            PrivateServerDomain.NonNegativeIntegerDamage.Parse(reader.GetString(11)),
            PrivateServerDomain.NonNegativeIntegerDamage.Parse(reader.GetString(12))));
      }
    }

    var receipt = PrivateServerDomain.LabHarnessTeamResultReceipt.Restore(
        receiptUid,
        runUid,
        team,
        PrivateServerDomain.NonNegativeIntegerDamage.Parse(canonicalDamage),
        telemetry,
        segments,
        warnings,
        observedAt);
    if (receipt.ContentSha256 != storedReceiptSha)
    {
      throw Failure(
          App.PrivateServerFailureKind.Unavailable,
          "challenge_damage_receipt_persisted_content_invalid");
    }

    return new StoredReceipt(receiptId, receipt);
  }

  private static async Task<IReadOnlyList<string>> LoadWarningCodesAsync(
      NpgsqlConnection connection,
      NpgsqlTransaction? transaction,
      string tableName,
      long receiptId,
      CancellationToken cancellationToken)
  {
    if (tableName is not ("challenge_team_damage_warning" or
        "challenge_team_telemetry_warning"))
    {
      throw new InvalidOperationException("challenge_warning_table_invalid");
    }

    await using var command = new NpgsqlCommand(
        $"""
        SELECT warning_code
          FROM lab_private_server.{tableName}
         WHERE challenge_team_damage_receipt_id = @receipt_id
         ORDER BY ordinal
        """,
        connection,
        transaction);
    Add(command, "receipt_id", NpgsqlDbType.Bigint, receiptId);
    var values = new List<string>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken)
        .ConfigureAwait(false);
    while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
    {
      values.Add(reader.GetString(0));
    }

    return values;
  }

  private static PrivateServerDomain.ChallengeRunState ParseRunState(string value) =>
      value switch
      {
        "open" => PrivateServerDomain.ChallengeRunState.Open,
        "team_in_progress" => PrivateServerDomain.ChallengeRunState.TeamInProgress,
        "team_result_accepted" => PrivateServerDomain.ChallengeRunState.TeamResultAccepted,
        "regroup_ready" => PrivateServerDomain.ChallengeRunState.RegroupReady,
        "completed" => PrivateServerDomain.ChallengeRunState.Completed,
        "abandoned" => PrivateServerDomain.ChallengeRunState.Abandoned,
        _ => throw Failure(
            App.PrivateServerFailureKind.Unavailable,
            "challenge_run_state_invalid")
      };

  private static IReadOnlyList<string> NormalizeRunWarningCodes(
      IReadOnlyList<string> warningCodes)
  {
    var normalized = warningCodes
        .Select(static value => value ?? string.Empty)
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length > 64 || normalized.Any(static code =>
        code.Length is < 1 or > 64 || code[0] is < 'a' or > 'z' ||
        code.Any(static character => !(
            character is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '_' or '-'))))
    {
      throw Failure(
          App.PrivateServerFailureKind.InvalidRequest,
          "challenge_warning_code_set_invalid");
    }

    return Array.AsReadOnly(normalized);
  }

  private async Task<T> RunStoreAsync<T>(Func<Task<T>> action)
  {
    try
    {
      return await action().ConfigureAwait(false);
    }
    catch (PostgresException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (NpgsqlException exception)
    {
      throw MapDatabaseException(exception);
    }
    catch (PrivateServerDomain.PrivateServerIntegrityException exception)
    {
      throw Failure(
          App.PrivateServerFailureKind.Conflict,
          "private_server_challenge_run_integrity_conflict",
          exception);
    }
  }

}
