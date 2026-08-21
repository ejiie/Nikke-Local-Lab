using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using NikkeLocalLab.Application.PrivateServer;
using ProfileApp = NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Domain.LocalGameState;
using NikkeLocalLab.Domain.PrivateServer;
using NikkeLocalLab.Identity;
using NikkeLocalLab.PrivateServer.Api;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.PrivateServer.Api.UnitTests;

[CollectionDefinition("Private server API environment", DisableParallelization = true)]
public sealed class PrivateServerApiEnvironmentCollection;

[Collection("Private server API environment")]
public sealed class PrivateServerApiSecurityTests
{
  [Theory]
  [InlineData("1")]
  [InlineData("{}")]
  [InlineData("[]")]
  [InlineData("true")]
  [InlineData("null")]
  public void SourceFreeScalarConvertersRejectWrongJsonTokenKinds(string json)
  {
    var assembly = typeof(PrivateServerApiHost).Assembly;
    var uidConverter = (JsonConverter)Activator.CreateInstance(
        assembly.GetType(
            "NikkeLocalLab.PrivateServer.Api.EntityUidJsonConverter",
            throwOnError: true)!,
        nonPublic: true)!;
    var digestConverter = (JsonConverter)Activator.CreateInstance(
        assembly.GetType(
            "NikkeLocalLab.PrivateServer.Api.Sha256DigestJsonConverter",
            throwOnError: true)!,
        nonPublic: true)!;

    var uidOptions = new JsonSerializerOptions();
    uidOptions.Converters.Add(uidConverter);
    Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<EntityUid>(json, uidOptions));

    var digestOptions = new JsonSerializerOptions();
    digestOptions.Converters.Add(digestConverter);
    Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<Sha256Digest>(json, digestOptions));
  }

  [Fact]
  public void ProductionCompositionAndHostArgumentsFailClosed()
  {
    var arguments = Assert.Throws<InvalidOperationException>(() =>
        PrivateServerApiHost.Build(
            ["--Kestrel:Endpoints:Evil:Url=http://0.0.0.0:0"],
            new PrivateServerApiHostOptions
            {
              AllowMissingPrivateServerServiceForTests = true
            }));
    Assert.Equal("private_server_host_arguments_not_supported", arguments.Message);

    var composition = Assert.Throws<InvalidOperationException>(() =>
        PrivateServerApiHost.Build(
            [],
            new PrivateServerApiHostOptions { Port = 0 }));
    Assert.Equal("private_server_composition_missing", composition.Message);
  }

  [Fact]
  public async Task BootAndOpenAreLabOwnedStrictAndDoNotSelectASeason()
  {
    await using var fixture = await RunningApi.StartAsync();
    var boot = await fixture.Client.GetAsync("/lab-api/v1/boot");
    Assert.Equal(HttpStatusCode.OK, boot.StatusCode);
    var bootJson = await boot.Content.ReadAsStringAsync();
    Assert.Contains("nll/private-server-harness-api/v1", bootJson, StringComparison.Ordinal);
    Assert.Contains("nll/client-feature-manifest/v2", bootJson, StringComparison.Ordinal);
    Assert.Contains("lab_harness_observation/v1", bootJson, StringComparison.Ordinal);
    Assert.Contains(
        "\"finalDamageAuthority\":\"original_client_runtime\"",
        bootJson,
        StringComparison.Ordinal);
    Assert.Contains(
        "\"originalRuntimeObservationStatus\":\"blocked_by_gate\"",
        bootJson,
        StringComparison.Ordinal);
    Assert.DoesNotContain("original_runtime_or", bootJson, StringComparison.Ordinal);
    Assert.Equal("DENY", boot.Headers.GetValues("X-Frame-Options").Single());

    using (var bootDocument = JsonDocument.Parse(bootJson))
    {
      var root = bootDocument.RootElement;
      Assert.Equal("lab_harness_observation/v1", root.GetProperty("resultObservationContractId").GetString());
      Assert.Equal("original_client_runtime", root.GetProperty("finalDamageAuthority").GetString());
      Assert.Equal("blocked_by_gate", root.GetProperty("originalRuntimeObservationStatus").GetString());

      var fixedCapabilities = root.GetProperty("fixedCapabilities");
      Assert.False(fixedCapabilities.GetProperty("normalStagesImplemented").GetBoolean());
      Assert.Equal(7, fixedCapabilities.GetProperty("normalLastClearLevel").GetInt32());
      Assert.True(fixedCapabilities.GetProperty("challengeUnlocked").GetBoolean());
      Assert.Equal("unsupported", fixedCapabilities.GetProperty("normalCombatCapabilityCode").GetString());
      Assert.Equal("unsupported", fixedCapabilities.GetProperty("quickBattleCapabilityCode").GetString());
      Assert.Equal("unresolved", root.GetProperty("operationalPolicy").GetProperty("resolutionStatusCode").GetString());

      var members = root.GetProperty("directory").GetProperty("members").EnumerateArray().ToArray();
      Assert.Equal(new[] { 7, 13, 26, 29, 34, 40 }, members.Select(static member =>
          member.GetProperty("seasonNumber").GetInt32()));
      Assert.All(members, static member =>
      {
        Assert.Equal("permanent", member.GetProperty("availabilityCode").GetString());
        Assert.Equal(JsonValueKind.Null, member.GetProperty("seasonEndsAtUtc").ValueKind);
      });

      var featureEntries = root.GetProperty("capabilityManifest")
          .GetProperty("clientFeatures")
          .GetProperty("entries")
          .EnumerateArray()
          .ToDictionary(
              static entry => entry.GetProperty("routeCode").GetString()!,
              static entry => entry.GetProperty("capabilityCode").GetString()!,
              StringComparer.Ordinal);
      Assert.Equal(22, featureEntries.Count);
      Assert.Equal("supported", featureEntries["lobby.solo_raid"]);
      Assert.Equal("supported", featureEntries["solo_raid.directory"]);
      Assert.Equal("supported", featureEntries["solo_raid.challenge"]);
      Assert.Equal("not_supported", featureEntries["solo_raid.normal_battle"]);
      Assert.Equal("not_supported", featureEntries["solo_raid.quick_battle"]);
      Assert.Equal("visible_no_op", featureEntries["lobby.recruit"]);
      Assert.Equal("hidden", featureEntries["lobby.messenger"]);
      Assert.Equal("hidden", featureEntries["lobby.outpost_defense"]);
    }

    using var noOrigin = fixture.CreateOpenRequest(includeOrigin: false);
    var rejected = await fixture.Client.SendAsync(noOrigin);
    Assert.Equal(HttpStatusCode.Forbidden, rejected.StatusCode);
    Assert.Equal("origin_rejected", await ReadCodeAsync(rejected));

    var grant = await fixture.OpenAsync();
    Assert.StartsWith("nll1.", grant.Token, StringComparison.Ordinal);
    Assert.Equal("loading", grant.StageCode);
    Assert.Null(grant.SelectedSeasonRevisionUid);
    Assert.Null(grant.SelectedSeasonContentSha256);
    Assert.NotNull(fixture.Service.LastOpenCommand);
    Assert.Equal(0, fixture.Service.LastOpenCommand!.IssuedAtUtc.Ticks % 10);
    Assert.Equal(
        TimeSpan.FromMinutes(30),
        fixture.Service.LastOpenCommand.ExpiresAtUtc -
            fixture.Service.LastOpenCommand.IssuedAtUtc);

    using var nonAnonymousVerb = new HttpRequestMessage(HttpMethod.Post, "/lab-api/v1/boot");
    nonAnonymousVerb.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    nonAnonymousVerb.Content = JsonContent.Create(new { });
    var verbResponse = await fixture.Client.SendAsync(nonAnonymousVerb);
    Assert.Equal(HttpStatusCode.Unauthorized, verbResponse.StatusCode);
    Assert.Equal("local_session_access_required", await ReadCodeAsync(verbResponse));
  }

  [Fact]
  public async Task DelayedOpenReplayReturnsTheOriginallySealedSessionGrant()
  {
    await using var fixture = await RunningApi.StartAsync();
    var operationUid = Guid.NewGuid();

    using var firstRequest = fixture.CreateOpenRequest(
        includeOrigin: true,
        operationUid: operationUid);
    var firstResponse = await fixture.Client.SendAsync(firstRequest);
    firstResponse.EnsureSuccessStatusCode();
    var firstBody = await firstResponse.Content.ReadAsStringAsync();

    fixture.Time.Advance(TimeSpan.FromSeconds(10));
    using var replayRequest = fixture.CreateOpenRequest(
        includeOrigin: true,
        operationUid: operationUid);
    var replayResponse = await fixture.Client.SendAsync(replayRequest);
    replayResponse.EnsureSuccessStatusCode();
    var replayBody = await replayResponse.Content.ReadAsStringAsync();

    Assert.Equal(firstBody, replayBody);
    fixture.Time.Advance(TimeSpan.FromMinutes(31));
    using var expiredReplayRequest = fixture.CreateOpenRequest(
        includeOrigin: true,
        operationUid: operationUid);
    var expiredReplayResponse = await fixture.Client.SendAsync(expiredReplayRequest);
    expiredReplayResponse.EnsureSuccessStatusCode();
    var expiredReplayBody = await expiredReplayResponse.Content.ReadAsStringAsync();
    // The process-local signing key makes the sealed token byte-identical in this API lifetime.
    Assert.Equal(firstBody, expiredReplayBody);

    using var document = JsonDocument.Parse(firstBody);
    var root = document.RootElement;
    var token = root.GetProperty("accessToken").GetString()!;
    var context = root.GetProperty("context");
    var seasonsPath = $"/lab-api/v1/sessions/" +
        $"{context.GetProperty("sessionUid").GetGuid():D}/contexts/" +
        $"{context.GetProperty("clientContextUid").GetGuid():D}/seasons";
    using var expiredProtectedRequest = fixture.CreateProtectedGet(seasonsPath, token);
    var expiredProtectedResponse = await fixture.Client.SendAsync(expiredProtectedRequest);
    Assert.Equal(HttpStatusCode.Unauthorized, expiredProtectedResponse.StatusCode);
    Assert.Equal(
        "local_session_access_required",
        await ReadCodeAsync(expiredProtectedResponse));
    Assert.Equal(0, fixture.Service.AccessValidationCalls);

    Assert.Equal(3, fixture.Service.OpenCalls);
    Assert.Single(fixture.Service.SealedOpenOperations);
  }

  [Fact]
  public async Task LoadingContextReadsDirectoryWithoutImplicitSeasonSelection()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();

    using var request = fixture.CreateProtectedGet(grant.SeasonsPath, grant.Token);
    var response = await fixture.Client.SendAsync(request);
    response.EnsureSuccessStatusCode();

    Assert.Equal(
        $"\"{grant.ContextRevisionUid:D}\"",
        response.Headers.ETag?.Tag);
    using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    Assert.Equal(
        new[] { 7, 13, 26, 29, 34, 40 },
        document.RootElement.GetProperty("members").EnumerateArray().Select(static member =>
            member.GetProperty("seasonNumber").GetInt32()));
    Assert.Equal(1, fixture.Service.AccessValidationCalls);
    Assert.Equal(1, fixture.Service.SeasonDirectoryValidationCalls);
  }

  [Fact]
  public async Task SoloRaidStateExposesExactChallengeAdmissionPinsWithoutInventingMissingProfiles()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();

    using var request = fixture.CreateProtectedGet(grant.SoloRaidPath, grant.Token);
    var response = await fixture.Client.SendAsync(request);
    response.EnsureSuccessStatusCode();

    using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    var pins = document.RootElement.GetProperty("admissionPins");
    Assert.Equal(
        fixture.Service.ProfileRevisionUid.Value,
        pins.GetProperty("profileRevisionUid").GetGuid());
    Assert.Equal(
        fixture.Service.ProfileContentSha256.ToString(),
        pins.GetProperty("profileContentSha256").GetString());
    Assert.Equal(
        fixture.Service.AccountCombatStateRevisionUid.Value,
        pins.GetProperty("accountCombatStateRevisionUid").GetGuid());

    var runtime = pins.GetProperty("runtimeExecution");
    Assert.Equal(
        fixture.Service.RuntimeExecutionRevisionUid.Value,
        runtime.GetProperty("revisionUid").GetGuid());
    Assert.Equal(
        fixture.Service.RuntimeExecutionContentSha256.ToString(),
        runtime.GetProperty("contentSha256").GetString());
    Assert.True(runtime.GetProperty("isHarnessValidationReady").GetBoolean());
    Assert.Equal(JsonValueKind.Null, pins.GetProperty("combatControl").ValueKind);
  }

  [Fact]
  public async Task UnsupportedBattlesAndVisibleRecruitNoOpRemainControlled()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();

    async Task<HttpResponseMessage> PostAsync(string suffix)
    {
      var request = fixture.CreateProtectedJson(
          HttpMethod.Post,
          $"/lab-api/v1/sessions/{grant.SessionUid:D}/contexts/" +
              $"{grant.ContextUid:D}/{suffix}",
          grant.Token,
          new { operationUid = Guid.NewGuid() });
      request.Headers.TryAddWithoutValidation(
          "If-Match",
          $"\"{grant.ContextRevisionUid:D}\"");
      return await fixture.Client.SendAsync(request);
    }

    using var normal = await PostAsync("solo-raid/normal-battle");
    Assert.Equal(HttpStatusCode.NotImplemented, normal.StatusCode);
    Assert.Equal("solo_raid_normal_battle_unsupported", await ReadCodeAsync(normal));

    using var quick = await PostAsync("solo-raid/quick-battle");
    Assert.Equal(HttpStatusCode.NotImplemented, quick.StatusCode);
    Assert.Equal("solo_raid_quick_battle_unsupported", await ReadCodeAsync(quick));

    using var recruit = await PostAsync("lobby/recruit");
    recruit.EnsureSuccessStatusCode();
    using var recruitDocument = JsonDocument.Parse(
        await recruit.Content.ReadAsStringAsync());
    Assert.Equal(
        "click_acknowledged_no_navigation",
        recruitDocument.RootElement.GetProperty("interactionCode").GetString());
    Assert.False(recruitDocument.RootElement.GetProperty("navigated").GetBoolean());
  }

  [Fact]
  public async Task TransportTokenIsScopedExpiresAndCannotOverridePersistedRevocation()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();

    using var wrongScope = fixture.CreateProtectedGet(
        $"/lab-api/v1/sessions/{EntityUid.New()}/contexts/{grant.ContextUid}/seasons",
        grant.Token);
    var wrongScopeResponse = await fixture.Client.SendAsync(wrongScope);
    Assert.Equal(HttpStatusCode.Forbidden, wrongScopeResponse.StatusCode);
    Assert.Equal("local_session_scope_rejected", await ReadCodeAsync(wrongScopeResponse));

    const string base64UrlAlphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    var finalCharacterIndex = base64UrlAlphabet.IndexOf(grant.Token[^1]);
    Assert.True(finalCharacterIndex >= 0);
    Assert.Equal(0, finalCharacterIndex % 4);
    var nonCanonicalEquivalent =
        grant.Token[..^1] + base64UrlAlphabet[finalCharacterIndex + 1];
    using var tampered = fixture.CreateProtectedGet(
        grant.SeasonsPath,
        nonCanonicalEquivalent);
    var tamperedResponse = await fixture.Client.SendAsync(tampered);
    Assert.Equal(HttpStatusCode.Unauthorized, tamperedResponse.StatusCode);

    fixture.Service.RejectPersistedSession = true;
    using var revoked = fixture.CreateProtectedGet(grant.SeasonsPath, grant.Token);
    var revokedResponse = await fixture.Client.SendAsync(revoked);
    Assert.Equal(HttpStatusCode.Forbidden, revokedResponse.StatusCode);
    Assert.Equal("persisted_local_session_revoked", await ReadCodeAsync(revokedResponse));
    Assert.Equal(1, fixture.Service.AccessValidationCalls);
    Assert.Equal(0, fixture.Service.SeasonDirectoryValidationCalls);

    using var malformedAfterRevocation = new HttpRequestMessage(
        HttpMethod.Post,
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}/challenge-runs");
    malformedAfterRevocation.Headers.TryAddWithoutValidation(
        "Authorization",
        $"NLL-Session {grant.Token}");
    malformedAfterRevocation.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    malformedAfterRevocation.Content = new StringContent(
        "{\"operationUid\":1,\"operationUid\":2}",
        Encoding.UTF8,
        "application/json");
    var malformedAfterRevocationResponse =
        await fixture.Client.SendAsync(malformedAfterRevocation);
    Assert.Equal(HttpStatusCode.Forbidden, malformedAfterRevocationResponse.StatusCode);
    Assert.Equal(
        "persisted_local_session_revoked",
        await ReadCodeAsync(malformedAfterRevocationResponse));
    Assert.Equal(2, fixture.Service.AccessValidationCalls);

    fixture.Service.RejectPersistedSession = false;
    fixture.Time.Advance(TimeSpan.FromMinutes(31));
    using var expired = fixture.CreateProtectedGet(grant.SeasonsPath, grant.Token);
    var expiredResponse = await fixture.Client.SendAsync(expired);
    Assert.Equal(HttpStatusCode.Unauthorized, expiredResponse.StatusCode);
    Assert.Equal("local_session_access_required", await ReadCodeAsync(expiredResponse));
    Assert.Equal(2, fixture.Service.AccessValidationCalls);
    Assert.Equal(0, fixture.Service.SeasonDirectoryValidationCalls);
  }

  [Fact]
  public async Task NonAnonymousApiPathsNeverBypassSessionAuthentication()
  {
    await using var fixture = await RunningApi.StartAsync();
    var response = await fixture.Client.GetAsync("/lab-api/v1/not-a-session-route");
    Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    Assert.Equal("local_session_access_required", await ReadCodeAsync(response));
  }

  [Fact]
  public async Task JsonIsBoundedDuplicateFreeCaseSensitiveAndScalarStrict()
  {
    await using var fixture = await RunningApi.StartAsync(maximumBodyBytes: 1024);
    using var duplicate = new HttpRequestMessage(HttpMethod.Post, "/lab-api/v1/sessions/open");
    duplicate.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    duplicate.Content = new StringContent(
        "{\"operationUid\":\"00000000-0000-0000-0000-000000000001\"," +
        "\"operationUid\":\"00000000-0000-0000-0000-000000000002\"}",
        Encoding.UTF8,
        "application/json");
    var duplicateResponse = await fixture.Client.SendAsync(duplicate);
    Assert.Equal(HttpStatusCode.BadRequest, duplicateResponse.StatusCode);
    Assert.Equal("request_json_duplicate_property", await ReadCodeAsync(duplicateResponse));

    using var wrongScalar = new HttpRequestMessage(HttpMethod.Post, "/lab-api/v1/sessions/open");
    wrongScalar.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    wrongScalar.Content = new StringContent(
        "{\"operationUid\":1,\"accountUid\":\"00000000-0000-0000-0000-000000000001\"," +
        "\"expectedBootRevisionUid\":\"00000000-0000-0000-0000-000000000002\"," +
        $"\"expectedBootContentSha256\":\"{new string('a', 64)}\"}}",
        Encoding.UTF8,
        "application/json");
    var scalarResponse = await fixture.Client.SendAsync(wrongScalar);
    Assert.Equal(HttpStatusCode.BadRequest, scalarResponse.StatusCode);
    Assert.Equal("request_json_invalid", await ReadCodeAsync(scalarResponse));

    using var wrongCase = fixture.CreateOpenRequest(includeOrigin: true, operationName: "OperationUid");
    var wrongCaseResponse = await fixture.Client.SendAsync(wrongCase);
    Assert.Equal(HttpStatusCode.BadRequest, wrongCaseResponse.StatusCode);

    using var oversized = new HttpRequestMessage(HttpMethod.Post, "/lab-api/v1/sessions/open");
    oversized.Headers.TryAddWithoutValidation("Origin", fixture.Origin);
    oversized.Content = new StringContent(
        "{\"padding\":\"" + new string('x', 1500) + "\"}",
        Encoding.UTF8,
        "application/json");
    var oversizedResponse = await fixture.Client.SendAsync(oversized);
    Assert.Equal(HttpStatusCode.RequestEntityTooLarge, oversizedResponse.StatusCode);
    Assert.Equal("request_body_too_large", await ReadCodeAsync(oversizedResponse));
  }

  [Fact]
  public async Task OmittedRunAndReceiptScalarsAndOriginalRuntimeClaimsAreRejected()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();

    using var omittedMock = fixture.CreateProtectedJson(
        HttpMethod.Post,
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}/challenge-runs",
        grant.Token,
        new
        {
          operationUid = Guid.NewGuid(),
          expectedSelectedSeasonRevisionUid = Guid.NewGuid(),
          profileRevisionUid = Guid.NewGuid(),
          accountCombatStateRevisionUid = Guid.NewGuid(),
          runtimeExecutionProfileRevisionUid = Guid.NewGuid(),
          combatControlProfileRevisionUid = Guid.NewGuid(),
          orderedSquadRevisionUids = new[] { Guid.NewGuid() }
        });
    omittedMock.Headers.TryAddWithoutValidation("If-Match", $"\"{grant.ContextRevisionUid}\"");
    var omittedMockResponse = await fixture.Client.SendAsync(omittedMock);
    Assert.Equal(HttpStatusCode.BadRequest, omittedMockResponse.StatusCode);
    Assert.Equal("ordered_squad_revision_set_invalid", await ReadCodeAsync(omittedMockResponse));

    using var originalClaim = fixture.CreateProtectedJson(
        HttpMethod.Post,
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}/challenge-runs/{Guid.NewGuid():D}/team-result",
        grant.Token,
        new
        {
          operationUid = Guid.NewGuid(),
          teamOrdinal = 1,
          observedDamage = "1",
          sourceCode = "original_runtime",
          telemetry = new { },
          executionSegments = Array.Empty<object>(),
          warningCodes = Array.Empty<string>()
        });
    originalClaim.Headers.TryAddWithoutValidation(
        "X-NLL-Context-Revision",
        $"\"{grant.ContextRevisionUid}\"");
    originalClaim.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    var claimResponse = await fixture.Client.SendAsync(originalClaim);
    Assert.Equal(HttpStatusCode.BadRequest, claimResponse.StatusCode);
    Assert.NotEqual("internal_error", await ReadCodeAsync(claimResponse));

    using var missingTelemetryScalar = fixture.CreateProtectedJson(
        HttpMethod.Post,
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}/challenge-runs/{Guid.NewGuid():D}/team-result",
        grant.Token,
        new
        {
          operationUid = Guid.NewGuid(),
          teamOrdinal = 1,
          observedDamage = "1",
          telemetry = new
          {
            behaviorTickCount = 0,
            fixedUpdateCount = 0,
            wallClockMicroseconds = 0,
            frameTimeMedianMilliseconds = 0,
            frameTimeP95Milliseconds = 0,
            frameTimeP99Milliseconds = 0,
            droppedFrameCount = 0,
            stalledFrameCount = 0,
            warningCodes = Array.Empty<string>()
          },
          executionSegments = Array.Empty<object>(),
          warningCodes = Array.Empty<string>()
        });
    missingTelemetryScalar.Headers.TryAddWithoutValidation(
        "X-NLL-Context-Revision",
        $"\"{grant.ContextRevisionUid}\"");
    missingTelemetryScalar.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    var missingTelemetryResponse = await fixture.Client.SendAsync(missingTelemetryScalar);
    Assert.Equal(HttpStatusCode.BadRequest, missingTelemetryResponse.StatusCode);
    Assert.Equal("challenge_team_result_invalid", await ReadCodeAsync(missingTelemetryResponse));
  }

  [Fact]
  public async Task UnresolvedOperationalPolicyBlocksChallengeAdmissionWithControlledStatus()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();
    using var request = fixture.CreateProtectedJson(
        HttpMethod.Post,
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}/challenge-runs",
        grant.Token,
        new
        {
          operationUid = Guid.NewGuid(),
          expectedSelectedSeasonRevisionUid = Guid.NewGuid(),
          profileRevisionUid = Guid.NewGuid(),
          accountCombatStateRevisionUid = Guid.NewGuid(),
          runtimeExecutionProfileRevisionUid = Guid.NewGuid(),
          combatControlProfileRevisionUid = Guid.NewGuid(),
          orderedSquadRevisionUids = new[] { Guid.NewGuid() },
          isMockBattle = false
        });
    request.Headers.TryAddWithoutValidation(
        "If-Match",
        $"\"{grant.ContextRevisionUid:D}\"");

    var response = await fixture.Client.SendAsync(request);
    Assert.Equal(HttpStatusCode.UnprocessableEntity, response.StatusCode);
    Assert.Equal("challenge_operational_policy_unresolved", await ReadCodeAsync(response));
  }

  [Fact]
  public async Task StrandedRecoveryAcceptsNoCallerReasonAndRejectsAnActiveOwner()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();
    var path =
        $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}" +
        $"/challenge-runs/{Guid.NewGuid():D}/recover-stranded";

    using var callerReason = fixture.CreateProtectedJson(
        HttpMethod.Post,
        path,
        grant.Token,
        new { operationUid = Guid.NewGuid(), reasonCode = "caller_selected" });
    callerReason.Headers.TryAddWithoutValidation(
        "X-NLL-Context-Revision",
        $"\"{grant.ContextRevisionUid:D}\"");
    callerReason.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    var callerReasonResponse = await fixture.Client.SendAsync(callerReason);
    Assert.Equal(HttpStatusCode.BadRequest, callerReasonResponse.StatusCode);
    Assert.Equal("request_json_invalid", await ReadCodeAsync(callerReasonResponse));

    using var stillActive = fixture.CreateProtectedJson(
        HttpMethod.Post,
        path,
        grant.Token,
        new { operationUid = Guid.NewGuid() });
    stillActive.Headers.TryAddWithoutValidation(
        "X-NLL-Context-Revision",
        $"\"{grant.ContextRevisionUid:D}\"");
    stillActive.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
    var stillActiveResponse = await fixture.Client.SendAsync(stillActive);
    Assert.Equal(HttpStatusCode.Conflict, stillActiveResponse.StatusCode);
    Assert.Equal("challenge_run_owner_session_still_active", await ReadCodeAsync(stillActiveResponse));
  }

  [Fact]
  public async Task WarningListsUseTheExactSixtyFourBySixtyFourStorageBoundary()
  {
    await using var fixture = await RunningApi.StartAsync();
    var grant = await fixture.OpenAsync();
    var exact = Enumerable.Range(0, 64).Select(index => $"warning_{index}").ToArray();

    async Task<HttpResponseMessage> SendAsync(
        IReadOnlyList<string> receiptWarnings,
        IReadOnlyList<string> telemetryWarnings)
    {
      var runtimeRevisionUid = Guid.NewGuid();
      var controlRevisionUid = Guid.NewGuid();
      using var request = fixture.CreateProtectedJson(
          HttpMethod.Post,
          $"/lab-api/v1/sessions/{grant.SessionUid}/contexts/{grant.ContextUid}" +
          $"/challenge-runs/{Guid.NewGuid():D}/team-result",
          grant.Token,
          new
          {
            operationUid = Guid.NewGuid(),
            teamOrdinal = 1,
            observedDamage = "1",
            telemetry = new
            {
              renderFrameCount = 1,
              behaviorTickCount = 1,
              fixedUpdateCount = 1,
              wallClockMicroseconds = 1,
              frameTimeMedianMilliseconds = 1m,
              frameTimeP95Milliseconds = 1m,
              frameTimeP99Milliseconds = 1m,
              droppedFrameCount = 0,
              stalledFrameCount = 0,
              warningCodes = telemetryWarnings
            },
            executionSegments = new[]
            {
              new
              {
                ordinal = 1,
                runtimeExecutionProfileRevisionUid = runtimeRevisionUid,
                combatControlProfileRevisionUid = controlRevisionUid,
                startRenderFrame = 0,
                endRenderFrame = 1,
                startBehaviorTick = 0,
                endBehaviorTick = 1,
                startFixedUpdate = 0,
                endFixedUpdate = 1,
                startWallClockMicroseconds = 0,
                endWallClockMicroseconds = 1,
                startDamage = "0",
                endDamage = "1"
              }
            },
            warningCodes = receiptWarnings
          });
      request.Headers.TryAddWithoutValidation(
          "X-NLL-Context-Revision",
          $"\"{grant.ContextRevisionUid:D}\"");
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{Guid.NewGuid():D}\"");
      return await fixture.Client.SendAsync(request);
    }

    using var exactResponse = await SendAsync(exact, exact);
    Assert.Equal(HttpStatusCode.ServiceUnavailable, exactResponse.StatusCode);
    Assert.Equal("stub_not_configured", await ReadCodeAsync(exactResponse));

    using var tooManyReceipt = await SendAsync(exact.Append("warning_64").ToArray(), exact);
    Assert.Equal(HttpStatusCode.BadRequest, tooManyReceipt.StatusCode);
    Assert.Equal("challenge_team_result_invalid", await ReadCodeAsync(tooManyReceipt));

    using var tooManyTelemetry = await SendAsync(exact, exact.Append("warning_64").ToArray());
    Assert.Equal(HttpStatusCode.BadRequest, tooManyTelemetry.StatusCode);
    Assert.Equal("challenge_team_result_invalid", await ReadCodeAsync(tooManyTelemetry));

    using var tooLong = await SendAsync(["a" + new string('b', 64)], Array.Empty<string>());
    Assert.Equal(HttpStatusCode.BadRequest, tooLong.StatusCode);
    Assert.Equal("challenge_team_result_invalid", await ReadCodeAsync(tooLong));
  }

  private static async Task<string?> ReadCodeAsync(HttpResponseMessage response)
  {
    using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
    return document.RootElement.GetProperty("code").GetString();
  }

  private sealed class RunningApi : IAsyncDisposable
  {
    private readonly WebApplication _application;

    private RunningApi(
        WebApplication application,
        HttpClient client,
        string origin,
        StubPrivateServerService service,
        ManualTimeProvider time)
    {
      _application = application;
      Client = client;
      Origin = origin;
      Service = service;
      Time = time;
    }

    public HttpClient Client { get; }

    public string Origin { get; }

    public StubPrivateServerService Service { get; }

    public ManualTimeProvider Time { get; }

    public static async Task<RunningApi> StartAsync(long maximumBodyBytes = 16_384)
    {
      var service = new StubPrivateServerService();
      var time = new ManualTimeProvider(
          new DateTimeOffset(2026, 8, 20, 3, 4, 5, TimeSpan.Zero).AddTicks(7));
      var application = PrivateServerApiHost.Build(
          [],
          new PrivateServerApiHostOptions
          {
            Port = 0,
            MaximumRequestBodyBytes = maximumBodyBytes,
            TimeProvider = time,
            ConfigureServices = services =>
                services.AddSingleton<IPrivateServerService>(service)
          });
      await application.StartAsync();
      var address = application.Urls.Single(static value =>
          value.StartsWith("http://127.0.0.1:", StringComparison.Ordinal));
      return new RunningApi(
          application,
          new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
          {
            BaseAddress = new Uri(address)
          },
          address,
          service,
          time);
    }

    public HttpRequestMessage CreateOpenRequest(
        bool includeOrigin,
        string operationName = "operationUid",
        Guid? operationUid = null)
    {
      var json = JsonSerializer.Serialize(new Dictionary<string, object>
      {
        [operationName] = operationUid ?? Guid.NewGuid(),
        ["accountUid"] = Service.AccountUid.Value,
        ["expectedBootRevisionUid"] = Service.Boot.Revision.RevisionUid.Value,
        ["expectedBootContentSha256"] = Service.Boot.Revision.ContentSha256.ToString()
      });
      var request = new HttpRequestMessage(HttpMethod.Post, "/lab-api/v1/sessions/open")
      {
        Content = new StringContent(json, Encoding.UTF8, "application/json")
      };
      if (includeOrigin)
      {
        request.Headers.TryAddWithoutValidation("Origin", Origin);
      }

      return request;
    }

    public async Task<SessionGrant> OpenAsync()
    {
      using var request = CreateOpenRequest(includeOrigin: true);
      var response = await Client.SendAsync(request);
      response.EnsureSuccessStatusCode();
      using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
      var root = document.RootElement;
      var context = root.GetProperty("context");
      return new SessionGrant(
          root.GetProperty("accessToken").GetString()!,
          context.GetProperty("sessionUid").GetGuid(),
          context.GetProperty("clientContextUid").GetGuid(),
          context.GetProperty("revision").GetProperty("revisionUid").GetGuid(),
          context.GetProperty("stageCode").GetString()!,
          context.GetProperty("selectedSeasonRevisionUid").ValueKind == JsonValueKind.Null
              ? null
              : context.GetProperty("selectedSeasonRevisionUid").GetGuid(),
          context.GetProperty("selectedSeasonContentSha256").ValueKind == JsonValueKind.Null
              ? null
              : context.GetProperty("selectedSeasonContentSha256").GetString());
    }

    public HttpRequestMessage CreateProtectedGet(string path, string token)
    {
      var request = new HttpRequestMessage(HttpMethod.Get, path);
      request.Headers.TryAddWithoutValidation("Authorization", $"NLL-Session {token}");
      request.Headers.TryAddWithoutValidation("If-Match", $"\"{Service.ContextRevisionUid}\"");
      return request;
    }

    public HttpRequestMessage CreateProtectedJson(
        HttpMethod method,
        string path,
        string token,
        object body)
    {
      var request = new HttpRequestMessage(method, path);
      request.Headers.TryAddWithoutValidation("Authorization", $"NLL-Session {token}");
      request.Headers.TryAddWithoutValidation("Origin", Origin);
      request.Content = JsonContent.Create(body);
      return request;
    }

    public async ValueTask DisposeAsync()
    {
      Client.Dispose();
      await _application.StopAsync();
      await _application.DisposeAsync();
    }
  }

  private sealed record SessionGrant(
      string Token,
      Guid SessionUid,
      Guid ContextUid,
      Guid ContextRevisionUid,
      string StageCode,
      Guid? SelectedSeasonRevisionUid,
      string? SelectedSeasonContentSha256)
  {
    public string SeasonsPath =>
        $"/lab-api/v1/sessions/{SessionUid:D}/contexts/{ContextUid:D}/seasons";

    public string SoloRaidPath =>
        $"/lab-api/v1/sessions/{SessionUid:D}/contexts/{ContextUid:D}/solo-raid";
  }

  private sealed class ManualTimeProvider : TimeProvider
  {
    private DateTimeOffset _utcNow;

    public ManualTimeProvider(DateTimeOffset utcNow)
    {
      _utcNow = utcNow;
    }

    public override DateTimeOffset GetUtcNow() => _utcNow;

    public void Advance(TimeSpan value) => _utcNow = _utcNow.Add(value);
  }

  private sealed class StubPrivateServerService : IPrivateServerService
  {
    private readonly Dictionary<EntityUid, ClientContextProjection> _sealedOpenOperations = [];

    public const string ApplicationContract = "nll/private-server-application/harness/v1";

    public EntityUid AccountUid { get; } = EntityUid.New();
    public EntityUid SessionUid { get; } = EntityUid.New();
    public EntityUid ContextUid { get; } = EntityUid.New();
    public EntityUid ContextRevisionUid { get; } = EntityUid.New();
    public EntityUid ProfileRevisionUid { get; } = EntityUid.New();
    public Sha256Digest ProfileContentSha256 { get; } =
        Sha256Digest.ComputeUtf8("profile-revision");
    public EntityUid AccountCombatStateRevisionUid { get; } = EntityUid.New();
    public EntityUid RuntimeExecutionRevisionUid { get; } = EntityUid.New();
    public Sha256Digest RuntimeExecutionContentSha256 { get; } =
        Sha256Digest.ComputeUtf8("runtime-execution-revision");

    public PrivateServerBootProjection Boot { get; }

    public SoloRaidStateProjection SoloRaidState { get; }

    public LobbyBootstrapProjection LobbyBootstrap { get; }

    public StubPrivateServerService()
    {
      Boot = CreateBoot();
      var materializedAtUtc = new DateTimeOffset(2026, 8, 20, 3, 0, 0, TimeSpan.Zero);
      var selection = SelectedRaidSeasonRevision.CreateInitial(
          EntityUid.New(),
          EntityUid.New(),
          AccountUid,
          SessionUid,
          ContextUid,
          Boot.Directory.Directory,
          Boot.Directory.Directory.Members[0].RaidSnapshotUid,
          materializedAtUtc);
      var lobbyContext = new ClientContextProjection(
          ContextUid,
          new RevisionProjection(
              ContextRevisionUid,
              2,
              Sha256Digest.ComputeUtf8("lobby-context")),
          SessionUid,
          AccountUid,
          Boot.ApplicationBuildUid,
          Boot.ApplicationBuildSha256,
          Boot.ApplicationContractId,
          Boot.CapabilityManifest.Manifest.ManifestUid,
          Boot.CapabilityManifest.Manifest.ContentSha256,
          materializedAtUtc,
          materializedAtUtc.AddMinutes(30),
          "lobby_ready",
          selection.SelectionRevisionUid,
          selection.ContentSha256);
      SoloRaidState = new SoloRaidStateProjection(
          lobbyContext,
          Boot.Directory,
          new SelectedRaidSeasonProjection(selection, lobbyContext),
          new ChallengeAdmissionPinProjection(
              ProfileRevisionUid,
              ProfileContentSha256,
              AccountCombatStateRevisionUid,
              new ChallengeRuntimeExecutionPinProjection(
                  RuntimeExecutionRevisionUid,
                  RuntimeExecutionContentSha256,
                  true),
              null),
          Boot.FixedCapabilities,
          Boot.OperationalPolicy,
          null,
          null,
          Boot.CapabilityManifest);
      var profileRevision = new ProfileApp.RevisionReference(
          ProfileRevisionUid,
          ProfileContentSha256,
          1);
      LobbyBootstrap = new LobbyBootstrapProjection(
          lobbyContext,
          new PrivateServerAccountProjection(
              AccountUid,
              Sha256Digest.ComputeUtf8("account-revision-set"),
              new ProfileApp.CurrentProfileProjection(
                  AccountUid,
                  profileRevision,
                  new ProfileApp.CatalogBindingProjection(
                      EntityUid.New(),
                      EntityUid.New(),
                      Sha256Digest.ComputeUtf8("character-catalog")),
                  new ProfileApp.CatalogBindingProjection(
                      EntityUid.New(),
                      EntityUid.New(),
                      Sha256Digest.ComputeUtf8("combat-support-catalog")),
                  true,
                  true,
                  true,
                  Array.Empty<ProfileApp.ProfileValueProjection>(),
                  Array.Empty<ProfileApp.ProfileIssueProjection>()),
              new ProfileApp.LobbyPresentationProjection(
                  AccountUid,
                  new ProfileApp.RevisionReference(
                      EntityUid.New(),
                      Sha256Digest.ComputeUtf8("lobby-revision"),
                      1),
                  "Commander",
                  1,
                  null,
                  null,
                  null,
                  null),
              new ProfileApp.WalletProjection(
                  AccountUid,
                  new ProfileApp.RevisionReference(
                      EntityUid.New(),
                      Sha256Digest.ComputeUtf8("wallet-revision"),
                      1),
                  Array.Empty<ProfileApp.WalletBalanceProjection>()),
              Array.Empty<ProfileApp.RosterEntryProjection>(),
              null,
              new ProfileApp.InventorySubsetProjection(
                  "profile_bound_subset",
                  profileRevision,
                  false,
                  true,
                  Array.Empty<ProfileApp.InventoryItemProjection>())),
          Boot.Directory,
          SoloRaidState.Selection,
          Boot.FixedCapabilities,
          Boot.OperationalPolicy,
          Boot.CapabilityManifest);
    }

    public OpenLocalSessionCommand? LastOpenCommand { get; private set; }

    public IReadOnlyDictionary<EntityUid, ClientContextProjection> SealedOpenOperations =>
        _sealedOpenOperations;

    public int OpenCalls { get; private set; }

    public bool RejectPersistedSession { get; set; }

    public int SeasonDirectoryValidationCalls { get; private set; }

    public int AccessValidationCalls { get; private set; }

    public Task ValidateSessionAccessAsync(
        ValidateLocalSessionAccessQuery query,
        CancellationToken cancellationToken = default)
    {
      AccessValidationCalls++;
      if (RejectPersistedSession)
      {
        throw new PrivateServerApplicationException(
            PrivateServerFailureKind.Forbidden,
            "persisted_local_session_revoked");
      }

      if (query.LocalSessionUid != SessionUid)
      {
        throw new PrivateServerApplicationException(
            PrivateServerFailureKind.Forbidden,
            "persisted_local_session_scope_rejected");
      }

      return Task.CompletedTask;
    }

    public Task<ClientContextProjection> OpenSessionAsync(
        OpenLocalSessionCommand command,
        CancellationToken cancellationToken = default)
    {
      OpenCalls++;
      LastOpenCommand = command;
      if (_sealedOpenOperations.TryGetValue(command.OperationUid, out var replay))
      {
        return Task.FromResult(replay);
      }

      var projection = new ClientContextProjection(
          ContextUid,
          new RevisionProjection(
              ContextRevisionUid,
              1,
              Sha256Digest.ComputeUtf8("context")),
          SessionUid,
          command.AccountUid,
          Boot.ApplicationBuildUid,
          Boot.ApplicationBuildSha256,
          Boot.ApplicationContractId,
          Boot.CapabilityManifest.Manifest.ManifestUid,
          Boot.CapabilityManifest.Manifest.ContentSha256,
          command.IssuedAtUtc,
          command.ExpiresAtUtc,
          "loading",
          null,
          null);
      _sealedOpenOperations.Add(command.OperationUid, projection);
      return Task.FromResult(projection);
    }

    public Task<PrivateServerBootProjection> GetBootAsync(
        BootQuery query,
        CancellationToken cancellationToken = default) => Task.FromResult(Boot);

    public Task<RaidSeasonDirectoryProjection> GetSeasonDirectoryAsync(
        SeasonDirectoryQuery query,
        CancellationToken cancellationToken = default)
    {
      SeasonDirectoryValidationCalls++;
      if (RejectPersistedSession)
      {
        throw new PrivateServerApplicationException(
            PrivateServerFailureKind.Forbidden,
            "persisted_local_session_revoked");
      }

      return Task.FromResult(Boot.Directory);
    }

    public Task<ClientContextProjection> ConnectSessionAsync(ConnectLocalSessionCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<LobbyBootstrapProjection> EnterLobbyAsync(EnterLobbyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<LobbyBootstrapProjection> GetLobbyBootstrapAsync(LobbyBootstrapQuery query, CancellationToken cancellationToken = default) => Task.FromResult(LobbyBootstrap);
    public Task<SelectedRaidSeasonProjection> SelectSeasonAsync(SelectRaidSeasonCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<SoloRaidStateProjection> GetSoloRaidStateAsync(SoloRaidStateQuery query, CancellationToken cancellationToken = default) => Task.FromResult(SoloRaidState);
    public Task<ChallengeOperationalPolicyProjection> PublishChallengeOperationalPolicyAsync(PublishChallengeOperationalPolicyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengePolicyStateProjection> GetChallengeOperationalPolicyAsync(ChallengePolicyStateQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengePolicyStateProjection> ActivateChallengeOperationalPolicyAsync(ActivateChallengeOperationalPolicyCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<RuntimeExecutionProfileProjection> SaveRuntimeExecutionProfileAsync(SaveRuntimeExecutionProfileCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<CombatControlProfileProjection> SaveCombatControlProfileAsync(SaveCombatControlProfileCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection> OpenChallengeRunAsync(OpenChallengeRunCommand command, CancellationToken cancellationToken = default) =>
        throw new PrivateServerApplicationException(
            PrivateServerFailureKind.PolicyUnresolved,
            "challenge_operational_policy_unresolved");
    public Task<ChallengeRunProjection> EnterChallengeTeamAsync(EnterChallengeTeamCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection?> GetChallengeRunAsync(GetChallengeRunQuery query, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection> SubmitChallengeTeamResultAsync(SubmitChallengeTeamResultCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection> PrepareChallengeRegroupAsync(PrepareChallengeRegroupCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection> CloseChallengeRunAsync(CloseChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<ChallengeRunProjection> AbandonChallengeRunAsync(AbandonChallengeRunCommand command, CancellationToken cancellationToken = default) => throw Unavailable();
    public Task<RecoveredChallengeRunProjection> RecoverStrandedChallengeRunAsync(RecoverStrandedChallengeRunCommand command, CancellationToken cancellationToken = default) =>
        throw new PrivateServerApplicationException(
            PrivateServerFailureKind.Conflict,
            "challenge_run_owner_session_still_active");

    private static PrivateServerBootProjection CreateBoot()
    {
      var featureManifest = new ClientFeatureManifestContent(
          "nll/client-feature-manifest/v2",
          new Dictionary<string, ClientFeatureCapability>(StringComparer.Ordinal)
          {
            ["lobby.profile"] = ClientFeatureCapability.Supported,
            ["lobby.wallet"] = ClientFeatureCapability.Supported,
            ["lobby.nikke"] = ClientFeatureCapability.Supported,
            ["lobby.squad"] = ClientFeatureCapability.Supported,
            ["lobby.inventory"] = ClientFeatureCapability.Supported,
            ["lobby.recruit"] = ClientFeatureCapability.VisibleNoOp,
            ["lobby.messenger"] = ClientFeatureCapability.Hidden,
            ["lobby.tracing_the_stars"] = ClientFeatureCapability.Hidden,
            ["lobby.costume_pick"] = ClientFeatureCapability.Hidden,
            ["lobby.trail_marker"] = ClientFeatureCapability.Hidden,
            ["lobby.more"] = ClientFeatureCapability.Hidden,
            ["lobby.pickup_banner"] = ClientFeatureCapability.Hidden,
            ["lobby.right_side"] = ClientFeatureCapability.Hidden,
            ["lobby.shop"] = ClientFeatureCapability.Hidden,
            ["lobby.cash_shop"] = ClientFeatureCapability.Hidden,
            ["lobby.outpost"] = ClientFeatureCapability.Hidden,
            ["lobby.outpost_defense"] = ClientFeatureCapability.Hidden,
            ["lobby.solo_raid"] = ClientFeatureCapability.Supported,
            ["solo_raid.directory"] = ClientFeatureCapability.Supported,
            ["solo_raid.normal_battle"] = ClientFeatureCapability.NotSupported,
            ["solo_raid.quick_battle"] = ClientFeatureCapability.NotSupported,
            ["solo_raid.challenge"] = ClientFeatureCapability.Supported
          }.Select(static pair => new ClientFeatureEntry(pair.Key, pair.Value)));
      var policy = ChallengeOperationalPolicy.CreateUnresolvedV1(EntityUid.New());
      var capability = PrivateServerCapabilityManifest.CreatePhase2B(
          EntityUid.New(),
          EntityUid.New(),
          featureManifest,
          policy);
      var members = new[] { 7, 13, 26, 29, 34, 40 }.Select(season =>
          new RaidSeasonDirectoryMember(
              season,
              EntityUid.New(),
              EntityUid.New(),
              EntityUid.New(),
              EntityUid.New(),
              Sha256Digest.ComputeUtf8($"raid-{season}"),
              "static_exact",
              SeasonPresentationBinding.Unresolved())).ToArray();
      var publishedAt = new DateTimeOffset(2026, 8, 20, 0, 0, 0, TimeSpan.Zero);
      var directory = new RaidSeasonDirectory(EntityUid.New(), publishedAt, members);
      return new PrivateServerBootProjection(
          new RevisionProjection(EntityUid.New(), 1, Sha256Digest.ComputeUtf8("boot")),
          EntityUid.New(),
          Sha256Digest.ComputeUtf8("application-build"),
          ApplicationContract,
          new RaidSeasonDirectoryProjection(directory),
          SoloRaidFixedCapabilities.V1,
          new ChallengeOperationalPolicyProjection(
              policy,
              publishedAt,
              true,
              RaidDayKey.FromDate(new DateOnly(2026, 8, 20))),
          new PrivateServerCapabilityManifestProjection(capability));
    }

    private static PrivateServerApplicationException Unavailable() =>
        new(PrivateServerFailureKind.Unavailable, "stub_not_configured");
  }
}
