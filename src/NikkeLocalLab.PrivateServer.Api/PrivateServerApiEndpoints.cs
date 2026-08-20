using NikkeLocalLab.Application.PrivateServer;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.PrivateServer.Api;

internal static class PrivateServerApiEndpoints
{
  private const string ContextRevisionHeader = "X-NLL-Context-Revision";
  private const string SelectionRevisionHeader = "X-NLL-Selection-Revision";

  internal static void MapPrivateServerApiEndpoints(this WebApplication app)
  {
    app.MapGet(
        "/lab-api/v1/boot",
        async (
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          var projection = await service.GetBootAsync(
              new BootQuery(ObservedNow(timeProvider)),
              context.RequestAborted).ConfigureAwait(false);
          context.Response.Headers.ETag = Quote(projection.Revision.RevisionUid.ToString());
          return Results.Json(PrivateServerApiProjectionMapper.Boot(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/open",
        async (
            OpenSessionApiRequest request,
            IPrivateServerService service,
            PrivateServerSessionTokenProtector tokens,
            PrivateServerApiHostOptions options,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(request.AccountUid, "account_uid_invalid");
          RequireUid(request.ExpectedBootRevisionUid, "boot_revision_uid_invalid");
          if (request.ExpectedBootContentSha256 == default)
          {
            throw Invalid("boot_pin_invalid");
          }

          var issuedAtUtc = ObservedNow(timeProvider);
          var expiresAtUtc = issuedAtUtc.Add(options.LocalSessionLifetime);
          var projection = await service.OpenSessionAsync(
              new OpenLocalSessionCommand(
                  request.OperationUid,
                  request.AccountUid,
                  request.ExpectedBootRevisionUid,
                  request.ExpectedBootContentSha256,
                  issuedAtUtc,
                  expiresAtUtc),
              context.RequestAborted).ConfigureAwait(false);
          RequireOpenProjection(request, projection);
          var grant = tokens.Issue(projection.SessionUid, projection.ExpiresAtUtc);
          SetContextRevisionHeaders(context.Response, projection);
          return Results.Json(new SessionGrantApiResponse(
              grant.Token,
              grant.ExpiresAtUtc,
              PrivateServerApiProjectionMapper.Context(projection)));
        });

    app.MapGet(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/seasons",
        async (
            string sessionUid,
            string contextUid,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request));
          var projection = await service.GetSeasonDirectoryAsync(
              new SeasonDirectoryQuery(
                  pin.SessionUid,
                  pin.ClientContextUid,
                  pin.ExpectedContextRevisionUid,
                  ObservedNow(timeProvider)),
              context.RequestAborted).ConfigureAwait(false);
          context.Response.Headers.ETag = Quote(pin.ExpectedContextRevisionUid.ToString());
          return Results.Json(PrivateServerApiProjectionMapper.Directory(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/connect",
        async (
            string sessionUid,
            string contextUid,
            ConnectSessionApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(request.ExpectedDirectoryUid, "directory_uid_invalid");
          RequireUid(request.SelectedRaidSnapshotUid, "selected_raid_snapshot_uid_required");
          if (request.ExpectedDirectorySha256 == default)
          {
            throw Invalid("directory_pin_invalid");
          }

          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request));
          var projection = await service.ConnectSessionAsync(
              new ConnectLocalSessionCommand(
                  request.OperationUid,
                  pin with { ObservedAtUtc = ObservedNow(timeProvider) },
                  request.ExpectedDirectoryUid,
                  request.ExpectedDirectorySha256,
                  request.SelectedRaidSnapshotUid),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection);
          if (!string.Equals(projection.StageCode, "local_connected", StringComparison.Ordinal) ||
              !projection.SelectedSeasonRevisionUid.HasValue ||
              !projection.SelectedSeasonContentSha256.HasValue)
          {
            throw new InvalidOperationException("private_server_connect_projection_invalid");
          }

          SetContextRevisionHeaders(context.Response, projection);
          return Results.Json(PrivateServerApiProjectionMapper.Context(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/lobby/enter",
        async (
            string sessionUid,
            string contextUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request)) with
          {
            ObservedAtUtc = ObservedNow(timeProvider)
          };
          var projection = await service.EnterLobbyAsync(
              new EnterLobbyCommand(request.OperationUid, pin),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection.Context);
          RequireLobbyReady(projection);
          SetLobbyHeaders(context.Response, projection);
          return Results.Json(PrivateServerApiProjectionMapper.Lobby(projection));
        });

    app.MapGet(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/lobby",
        async (
            string sessionUid,
            string contextUid,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request));
          var projection = await service.GetLobbyBootstrapAsync(
              new LobbyBootstrapQuery(
                  pin.SessionUid,
                  pin.ClientContextUid,
                  pin.ExpectedContextRevisionUid,
                  ObservedNow(timeProvider)),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection.Context);
          RequireLobbyReady(projection);
          SetLobbyHeaders(context.Response, projection);
          return Results.Json(PrivateServerApiProjectionMapper.Lobby(projection));
        });

    app.MapPut(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/solo-raid/selection",
        async (
            string sessionUid,
            string contextUid,
            SelectSeasonApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(request.ExpectedSelectionRevisionUid, "selection_revision_uid_invalid");
          RequireUid(request.ExpectedDirectoryUid, "directory_uid_invalid");
          RequireUid(request.SelectedRaidSnapshotUid, "selected_raid_snapshot_uid_required");
          if (request.ExpectedDirectorySha256 == default)
          {
            throw Invalid("directory_pin_invalid");
          }

          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request)) with
          {
            ObservedAtUtc = ObservedNow(timeProvider)
          };
          var projection = await service.SelectSeasonAsync(
              new SelectRaidSeasonCommand(
                  request.OperationUid,
                  pin,
                  request.ExpectedSelectionRevisionUid,
                  request.ExpectedDirectoryUid,
                  request.ExpectedDirectorySha256,
                  request.SelectedRaidSnapshotUid),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection.Context);
          SetContextRevisionHeaders(context.Response, projection.Context);
          context.Response.Headers[SelectionRevisionHeader] =
              Quote(projection.Selection.SelectionRevisionUid.ToString());
          return Results.Json(new SelectedSeasonWithContextApiResponse(
              PrivateServerApiProjectionMapper.Selection(projection),
              PrivateServerApiProjectionMapper.Context(projection.Context)));
        });

    app.MapGet(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/solo-raid",
        async (
            string sessionUid,
            string contextUid,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          var projection = await GetSoloRaidStateAsync(
              sessionUid,
              contextUid,
              service,
              timeProvider,
              context).ConfigureAwait(false);
          SetContextRevisionHeaders(context.Response, projection.Context);
          context.Response.Headers[SelectionRevisionHeader] =
              Quote(projection.Selection.Selection.SelectionRevisionUid.ToString());
          return Results.Json(PrivateServerApiProjectionMapper.SoloRaid(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs",
        async (
            string sessionUid,
            string contextUid,
            OpenChallengeRunApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(
              request.ExpectedSelectedSeasonRevisionUid,
              "selected_season_revision_uid_required");
          RequireUid(request.ProfileRevisionUid, "profile_revision_uid_invalid");
          RequireUid(
              request.AccountCombatStateRevisionUid,
              "account_combat_state_revision_uid_invalid");
          RequireUid(
              request.RuntimeExecutionProfileRevisionUid,
              "runtime_execution_profile_revision_uid_invalid");
          RequireUid(
              request.CombatControlProfileRevisionUid,
              "combat_control_profile_revision_uid_invalid");
          if (request.OrderedSquadRevisionUids is null ||
              !request.IsMockBattle.HasValue ||
              request.OrderedSquadRevisionUids.Count is < 1 or > 5 ||
              request.OrderedSquadRevisionUids.Any(static uid => uid.Value == Guid.Empty) ||
              request.OrderedSquadRevisionUids.Distinct().Count() !=
                  request.OrderedSquadRevisionUids.Count)
          {
            throw Invalid("ordered_squad_revision_set_invalid");
          }

          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request)) with
          {
            ObservedAtUtc = ObservedNow(timeProvider)
          };
          var projection = await service.OpenChallengeRunAsync(
              new OpenChallengeRunCommand(
                  request.OperationUid,
                  pin,
                  request.ExpectedSelectedSeasonRevisionUid,
                  request.ProfileRevisionUid,
                  request.AccountCombatStateRevisionUid,
                  request.RuntimeExecutionProfileRevisionUid,
                  request.CombatControlProfileRevisionUid,
                  request.OrderedSquadRevisionUids,
                  request.IsMockBattle.Value),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapGet(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request)) with
          {
            ObservedAtUtc = ObservedNow(timeProvider)
          };
          var parsedRunUid = ParseUid(runUid, "challenge_run_uid_invalid");
          var projection = await service.GetChallengeRunAsync(
              new GetChallengeRunQuery(
                  pin.SessionUid,
                  pin.ClientContextUid,
                  pin.ExpectedContextRevisionUid,
                  parsedRunUid,
                  pin.ObservedAtUtc),
              context.RequestAborted).ConfigureAwait(false);
          if (projection is null)
          {
            throw new PrivateServerApplicationException(
                PrivateServerFailureKind.NotFound,
                "challenge_run_not_found");
          }

          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/teams/enter",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            EnterChallengeTeamApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          if (request.TeamOrdinal is null or < 1 or > 5)
          {
            throw Invalid("challenge_team_ordinal_invalid");
          }

          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.EnterChallengeTeamAsync(
              new EnterChallengeTeamCommand(
                  request.OperationUid,
                  pin,
                  ParseUid(runUid, "challenge_run_uid_invalid"),
                  RequireRunIfMatch(context.Request),
                  request.TeamOrdinal.Value),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/team-result",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            SubmitChallengeTeamResultApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          if (request.TeamOrdinal is null or < 1 or > 5 ||
              !NonNegativeIntegerDamage.TryParse(request.ObservedDamage, out var damage) ||
              request.Telemetry is null || request.ExecutionSegments is null ||
              request.ExecutionSegments.Count is < 1 or > 64 ||
              request.ExecutionSegments.Any(static segment => segment is null) ||
              !AreExactWarningCodes(request.WarningCodes) ||
              !AreExactWarningCodes(request.Telemetry.WarningCodes) ||
              !HasCompleteTelemetry(request.Telemetry))
          {
            throw Invalid("challenge_team_result_invalid");
          }

          var telemetry = MaterializeRequestValue(() => new BattleFrameTelemetry(
              request.Telemetry.RenderFrameCount!.Value,
              request.Telemetry.BehaviorTickCount!.Value,
              request.Telemetry.FixedUpdateCount!.Value,
              request.Telemetry.WallClockMicroseconds!.Value,
              request.Telemetry.FrameTimeMedianMilliseconds!.Value,
              request.Telemetry.FrameTimeP95Milliseconds!.Value,
              request.Telemetry.FrameTimeP99Milliseconds!.Value,
              request.Telemetry.DroppedFrameCount!.Value,
              request.Telemetry.StalledFrameCount!.Value,
              request.Telemetry.WarningCodes!.Select(static code => code!).ToArray()));
          var segments = request.ExecutionSegments.Select(nullableSegment =>
          {
            var segment = nullableSegment!;
            if (!HasCompleteExecutionSegment(segment))
            {
              throw Invalid("execution_segment_shape_invalid");
            }

            if (!NonNegativeIntegerDamage.TryParse(segment.StartDamage, out var startDamage) ||
                !NonNegativeIntegerDamage.TryParse(segment.EndDamage, out var endDamage))
            {
              throw Invalid("execution_segment_damage_invalid");
            }

            return MaterializeRequestValue(() => new ExecutionSegment(
                segment.Ordinal!.Value,
                segment.RuntimeExecutionProfileRevisionUid,
                segment.CombatControlProfileRevisionUid,
                segment.StartRenderFrame!.Value,
                segment.EndRenderFrame!.Value,
                segment.StartBehaviorTick!.Value,
                segment.EndBehaviorTick!.Value,
                segment.StartFixedUpdate!.Value,
                segment.EndFixedUpdate!.Value,
                segment.StartWallClockMicroseconds!.Value,
                segment.EndWallClockMicroseconds!.Value,
                startDamage,
                endDamage));
          }).ToArray();

          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.SubmitChallengeTeamResultAsync(
              new SubmitChallengeTeamResultCommand(
                  request.OperationUid,
                  pin,
                  ParseUid(runUid, "challenge_run_uid_invalid"),
                  RequireRunIfMatch(context.Request),
                  request.TeamOrdinal.Value,
                  damage,
                  telemetry,
                  segments,
                  request.WarningCodes!.Select(static code => code!).ToArray()),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/regroup",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.PrepareChallengeRegroupAsync(
              new PrepareChallengeRegroupCommand(
                  request.OperationUid,
                  pin,
                  ParseUid(runUid, "challenge_run_uid_invalid"),
                  RequireRunIfMatch(context.Request)),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/close",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            CloseChallengeRunApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(request.ResultUid, "challenge_result_uid_invalid");
          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.CloseChallengeRunAsync(
              new CloseChallengeRunCommand(
                  request.OperationUid,
                  pin,
                  ParseUid(runUid, "challenge_run_uid_invalid"),
                  RequireRunIfMatch(context.Request),
                  request.ResultUid),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/abandon",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            AbandonChallengeRunApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          RequireUid(request.AbandonmentUid, "challenge_abandonment_uid_invalid");
          if (!IsControlledCode(request.ReasonCode, 64))
          {
            throw Invalid("challenge_abandonment_reason_invalid");
          }

          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.AbandonChallengeRunAsync(
              new AbandonChallengeRunCommand(
                  request.OperationUid,
                  pin,
                  ParseUid(runUid, "challenge_run_uid_invalid"),
                  RequireRunIfMatch(context.Request),
                  request.AbandonmentUid,
                  request.ReasonCode!),
              context.RequestAborted).ConfigureAwait(false);
          RequireRunScope(pin, projection);
          SetRunHeaders(context.Response, pin, projection);
          return Results.Json(PrivateServerApiProjectionMapper.ChallengeRun(projection));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/challenge-runs/{runUid}/recover-stranded",
        async (
            string sessionUid,
            string contextUid,
            string runUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          var parsedRunUid = ParseUid(runUid, "challenge_run_uid_invalid");
          var pin = RunRequestPin(context, sessionUid, contextUid, timeProvider);
          var projection = await service.RecoverStrandedChallengeRunAsync(
              new RecoverStrandedChallengeRunCommand(
                  request.OperationUid,
                  pin,
                  parsedRunUid,
                  RequireRunIfMatch(context.Request)),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection.RequestingContext);
          if (projection.RequestingContext.Revision.RevisionUid !=
                  pin.ExpectedContextRevisionUid ||
              projection.Run.Run.RunUid != parsedRunUid ||
              projection.Run.Run.Binding.AccountUid != projection.RequestingContext.AccountUid ||
              projection.Run.Run.State != ChallengeRunState.Abandoned ||
              !string.Equals(
                  projection.Run.Run.AbandonReasonCode,
                  ChallengeRun.OwningSessionInactiveRecoveryReasonCode,
                  StringComparison.Ordinal))
          {
            throw new InvalidOperationException("challenge_run_recovery_projection_invalid");
          }

          context.Response.Headers.ETag =
              Quote(projection.Run.Run.RunRevisionUid.ToString());
          context.Response.Headers[ContextRevisionHeader] =
              Quote(projection.RequestingContext.Revision.RevisionUid.ToString());
          return Results.Json(
              PrivateServerApiProjectionMapper.ChallengeRun(projection.Run));
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/solo-raid/normal-battle",
        async (
            string sessionUid,
            string contextUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          _ = await GetSoloRaidStateAsync(
              sessionUid,
              contextUid,
              service,
              timeProvider,
              context).ConfigureAwait(false);
          throw new PrivateServerApplicationException(
              PrivateServerFailureKind.Unsupported,
              "solo_raid_normal_battle_unsupported");
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/solo-raid/quick-battle",
        async (
            string sessionUid,
            string contextUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          _ = await GetSoloRaidStateAsync(
              sessionUid,
              contextUid,
              service,
              timeProvider,
              context).ConfigureAwait(false);
          throw new PrivateServerApplicationException(
              PrivateServerFailureKind.Unsupported,
              "solo_raid_quick_battle_unsupported");
        });

    app.MapPost(
        "/lab-api/v1/sessions/{sessionUid}/contexts/{contextUid}/lobby/recruit",
        async (
            string sessionUid,
            string contextUid,
            OperationApiRequest request,
            IPrivateServerService service,
            TimeProvider timeProvider,
            HttpContext context) =>
        {
          RequireUid(request.OperationUid, "operation_uid_invalid");
          var pin = RequestPin(
              context,
              sessionUid,
              contextUid,
              RequireIfMatch(context.Request));
          var projection = await service.GetLobbyBootstrapAsync(
              new LobbyBootstrapQuery(
                  pin.SessionUid,
                  pin.ClientContextUid,
                  pin.ExpectedContextRevisionUid,
                  ObservedNow(timeProvider)),
              context.RequestAborted).ConfigureAwait(false);
          RequireContextScope(pin, projection.Context);
          RequireLobbyReady(projection);
          SetContextRevisionHeaders(context.Response, projection.Context);
          return Results.Json(new NoNavigationInteractionApiResponse(
              request.OperationUid,
              "click_acknowledged_no_navigation",
              false));
        });
  }

  private static async Task<SoloRaidStateProjection> GetSoloRaidStateAsync(
      string sessionUid,
      string contextUid,
      IPrivateServerService service,
      TimeProvider timeProvider,
      HttpContext context)
  {
    var pin = RequestPin(
        context,
        sessionUid,
        contextUid,
        RequireIfMatch(context.Request));
    var projection = await service.GetSoloRaidStateAsync(
        new SoloRaidStateQuery(
            pin.SessionUid,
            pin.ClientContextUid,
            pin.ExpectedContextRevisionUid,
            ObservedNow(timeProvider)),
        context.RequestAborted).ConfigureAwait(false);
    RequireContextScope(pin, projection.Context);
    return projection;
  }

  private static SessionRequestPin RunRequestPin(
      HttpContext context,
      string sessionUid,
      string contextUid,
      TimeProvider timeProvider) => RequestPin(
      context,
      sessionUid,
      contextUid,
      RequireContextRevisionHeader(context.Request)) with
      {
        ObservedAtUtc = ObservedNow(timeProvider)
      };

  private static SessionRequestPin RequestPin(
      HttpContext context,
      string sessionUid,
      string contextUid,
      EntityUid expectedContextRevisionUid)
  {
    var session = ParseUid(sessionUid, "session_uid_invalid");
    var clientContext = ParseUid(contextUid, "client_context_uid_invalid");
    if (!context.Items.TryGetValue(
            PrivateServerApiRoutes.AuthenticatedSessionItem,
            out var authenticatedValue) ||
        authenticatedValue is not EntityUid authenticatedSession ||
        authenticatedSession != session)
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status403Forbidden,
          "local_session_scope_rejected");
    }

    return new SessionRequestPin(
        session,
        clientContext,
        expectedContextRevisionUid,
        DateTimeOffset.UnixEpoch);
  }

  private static EntityUid RequireIfMatch(HttpRequest request) =>
      ParseQuotedUidHeader(request.Headers.IfMatch, "context_revision_required");

  internal static EntityUid RequireContextRevisionHeader(HttpRequest request) =>
      ParseQuotedUidHeader(request.Headers[ContextRevisionHeader], "context_revision_required");

  internal static EntityUid RequireRunIfMatch(HttpRequest request) =>
      ParseQuotedUidHeader(request.Headers.IfMatch, "run_revision_required");

  private static EntityUid ParseQuotedUidHeader(
      Microsoft.Extensions.Primitives.StringValues values,
      string missingCode)
  {
    if (values.Count != 1)
    {
      throw new PrivateServerApiRequestException(
          StatusCodes.Status428PreconditionRequired,
          missingCode);
    }

    var value = values[0];
    if (value is null || value.Length != 38 || value[0] != '"' || value[^1] != '"' ||
        !Guid.TryParseExact(value.AsSpan(1, 36), "D", out var parsed) ||
        parsed == Guid.Empty)
    {
      throw Invalid("revision_precondition_invalid");
    }

    return new EntityUid(parsed);
  }

  private static EntityUid ParseUid(string value, string code)
  {
    if (!Guid.TryParseExact(value, "D", out var parsed) || parsed == Guid.Empty)
    {
      throw Invalid(code);
    }

    return new EntityUid(parsed);
  }

  private static void RequireUid(EntityUid value, string code)
  {
    if (value.Value == Guid.Empty)
    {
      throw Invalid(code);
    }
  }

  private static void RequireOpenProjection(
      OpenSessionApiRequest request,
      ClientContextProjection projection)
  {
    if (projection.AccountUid != request.AccountUid ||
        projection.SessionUid.Value == Guid.Empty ||
        projection.ClientContextUid.Value == Guid.Empty ||
        projection.Revision.RevisionUid.Value == Guid.Empty ||
        projection.Revision.RevisionNumber < 1 ||
        projection.Revision.ContentSha256 == default ||
        projection.ApplicationBuildUid.Value == Guid.Empty ||
        projection.ApplicationBuildSha256 == default ||
        string.IsNullOrWhiteSpace(projection.ApplicationContractId) ||
        projection.CapabilityManifestUid.Value == Guid.Empty ||
        projection.CapabilityManifestSha256 == default ||
        projection.IssuedAtUtc.Offset != TimeSpan.Zero ||
        projection.ExpiresAtUtc.Offset != TimeSpan.Zero ||
        projection.ExpiresAtUtc <= projection.IssuedAtUtc ||
        !string.Equals(projection.StageCode, "loading", StringComparison.Ordinal) ||
        projection.SelectedSeasonRevisionUid.HasValue ||
        projection.SelectedSeasonContentSha256.HasValue)
    {
      throw new InvalidOperationException("private_server_open_projection_invalid");
    }
  }

  private static void RequireContextScope(
      SessionRequestPin pin,
      ClientContextProjection projection)
  {
    if (projection.SessionUid != pin.SessionUid ||
        projection.ClientContextUid != pin.ClientContextUid)
    {
      throw new InvalidOperationException("private_server_context_scope_invalid");
    }
  }

  private static void RequireRunScope(
      SessionRequestPin pin,
      ChallengeRunProjection projection)
  {
    if (projection.Run.Binding.SessionUid != pin.SessionUid ||
        projection.Run.Binding.ClientContextUid != pin.ClientContextUid ||
        projection.Run.Binding.ClientContextRevisionUid != pin.ExpectedContextRevisionUid)
    {
      throw new InvalidOperationException("private_server_run_scope_invalid");
    }
  }

  private static void RequireLobbyReady(LobbyBootstrapProjection projection)
  {
    if (!string.Equals(projection.Context.StageCode, "lobby_ready", StringComparison.Ordinal) ||
        projection.Account.AccountUid != projection.Context.AccountUid ||
        projection.Selection.Context.ClientContextUid != projection.Context.ClientContextUid ||
        projection.Selection.Selection.SelectionRevisionUid !=
            projection.Context.SelectedSeasonRevisionUid)
    {
      throw new InvalidOperationException("private_server_lobby_projection_invalid");
    }
  }

  private static void SetLobbyHeaders(
      HttpResponse response,
      LobbyBootstrapProjection projection)
  {
    SetContextRevisionHeaders(response, projection.Context);
    response.Headers[SelectionRevisionHeader] =
        Quote(projection.Selection.Selection.SelectionRevisionUid.ToString());
  }

  private static void SetContextRevisionHeaders(
      HttpResponse response,
      ClientContextProjection projection) =>
      response.Headers.ETag = Quote(projection.Revision.RevisionUid.ToString());

  private static void SetRunHeaders(
      HttpResponse response,
      SessionRequestPin pin,
      ChallengeRunProjection projection)
  {
    response.Headers.ETag = Quote(projection.Run.RunRevisionUid.ToString());
    response.Headers[ContextRevisionHeader] =
        Quote(pin.ExpectedContextRevisionUid.ToString());
  }

  private static T MaterializeRequestValue<T>(Func<T> factory)
  {
    try
    {
      return factory();
    }
    catch (PrivateServerIntegrityException exception)
    {
      throw Invalid(exception.Code);
    }
  }

  private static bool HasCompleteTelemetry(BattleFrameTelemetryApiRequest value) =>
      value.RenderFrameCount.HasValue &&
      value.BehaviorTickCount.HasValue &&
      value.FixedUpdateCount.HasValue &&
      value.WallClockMicroseconds.HasValue &&
      value.FrameTimeMedianMilliseconds.HasValue &&
      value.FrameTimeP95Milliseconds.HasValue &&
      value.FrameTimeP99Milliseconds.HasValue &&
      value.DroppedFrameCount.HasValue &&
      value.StalledFrameCount.HasValue;

  private static bool HasCompleteExecutionSegment(ExecutionSegmentApiRequest value) =>
      value.Ordinal.HasValue &&
      value.RuntimeExecutionProfileRevisionUid.Value != Guid.Empty &&
      value.CombatControlProfileRevisionUid.Value != Guid.Empty &&
      value.StartRenderFrame.HasValue &&
      value.EndRenderFrame.HasValue &&
      value.StartBehaviorTick.HasValue &&
      value.EndBehaviorTick.HasValue &&
      value.StartFixedUpdate.HasValue &&
      value.EndFixedUpdate.HasValue &&
      value.StartWallClockMicroseconds.HasValue &&
      value.EndWallClockMicroseconds.HasValue &&
      value.StartDamage is not null &&
      value.EndDamage is not null;

  private static bool AreExactWarningCodes(IReadOnlyList<string?>? values)
  {
    if (values is null || values.Count > 64)
    {
      return false;
    }

    var seen = new HashSet<string>(StringComparer.Ordinal);
    foreach (var value in values)
    {
      if (string.IsNullOrEmpty(value) || value.Length > 64 ||
          value[0] is < 'a' or > 'z' ||
          value.Any(static character =>
              !((character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9') ||
                character is '.' or '_' or '-')) ||
          !seen.Add(value))
      {
        return false;
      }
    }

    return true;
  }

  private static bool IsControlledCode(string? value, int maximumLength) =>
      !string.IsNullOrEmpty(value) && value.Length <= maximumLength &&
      value[0] is >= 'a' and <= 'z' &&
      value.All(static character =>
          (character >= 'a' && character <= 'z') ||
          (character >= '0' && character <= '9') ||
          character is '.' or '_' or '-');

  private static DateTimeOffset ObservedNow(TimeProvider timeProvider)
  {
    var utc = timeProvider.GetUtcNow().ToUniversalTime();
    var normalizedTicks = utc.Ticks - (utc.Ticks % 10);
    return new DateTimeOffset(normalizedTicks, TimeSpan.Zero);
  }

  private static string Quote(string value) => $"\"{value}\"";

  private static PrivateServerApiRequestException Invalid(string code) =>
      new(StatusCodes.Status400BadRequest, code);
}
