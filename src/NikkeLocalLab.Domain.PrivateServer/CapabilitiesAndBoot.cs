using NikkeLocalLab.Domain.LocalGameState;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public enum PrivateServerCapabilityStatus
{
  Supported,
  Unsupported,
  VisibleNoOp,
  BlockedByGate,
  Unresolved
}

public sealed record PrivateServerCapabilityEntry
{
  public PrivateServerCapabilityEntry(
      string capabilityCode,
      PrivateServerCapabilityStatus status,
      string? reasonCode = null)
  {
    CapabilityCode = PrivateServerGuard.RequireCode(
        capabilityCode,
        nameof(capabilityCode),
        maximumLength: 96);
    if (!Enum.IsDefined(status) ||
        (status is PrivateServerCapabilityStatus.BlockedByGate or
            PrivateServerCapabilityStatus.Unresolved) != (reasonCode is not null))
    {
      throw new PrivateServerIntegrityException("private_server_capability_shape_invalid");
    }

    Status = status;
    ReasonCode = reasonCode is null
        ? null
        : PrivateServerGuard.RequireCode(reasonCode, nameof(reasonCode));
  }

  public string CapabilityCode { get; }

  public PrivateServerCapabilityStatus Status { get; }

  public string? ReasonCode { get; }
}

public sealed class PrivateServerCapabilityManifest
{
  public const string ContractId = "nll/private-server-capabilities/v1";
  public const int Version = 1;

  private PrivateServerCapabilityManifest(
      EntityUid manifestUid,
      EntityUid clientFeatureManifestUid,
      ClientFeatureManifestContent clientFeatureManifest,
      EntityUid operationalPolicyUid,
      Sha256Digest operationalPolicySha256,
      IReadOnlyList<PrivateServerCapabilityEntry> entries)
  {
    ManifestUid = PrivateServerGuard.RequireUid(manifestUid, nameof(manifestUid));
    ClientFeatureManifestUid = PrivateServerGuard.RequireUid(
        clientFeatureManifestUid,
        nameof(clientFeatureManifestUid));
    ClientFeatureManifest = clientFeatureManifest ??
        throw new ArgumentNullException(nameof(clientFeatureManifest));
    ClientFeatureManifestSha256 = PrivateServerGuard.RequireDigest(
        clientFeatureManifest.ContentSha256,
        nameof(clientFeatureManifest));
    OperationalPolicyUid = PrivateServerGuard.RequireUid(
        operationalPolicyUid,
        nameof(operationalPolicyUid));
    OperationalPolicySha256 = PrivateServerGuard.RequireDigest(
        operationalPolicySha256,
        nameof(operationalPolicySha256));
    Entries = entries;
    ContentSha256 = PrivateServerHash.Compute(ContractId, hash =>
    {
      PrivateServerHash.Append(hash, Version);
      PrivateServerHash.Append(hash, ClientFeatureManifestUid);
      PrivateServerHash.Append(hash, ClientFeatureManifestSha256);
      PrivateServerHash.Append(hash, OperationalPolicyUid);
      PrivateServerHash.Append(hash, OperationalPolicySha256);
      foreach (var entry in entries)
      {
        PrivateServerHash.Append(hash, entry.CapabilityCode);
        PrivateServerHash.Append(hash, Code(entry.Status));
        PrivateServerHash.Append(hash, entry.ReasonCode ?? string.Empty);
      }
    });
  }

  public EntityUid ManifestUid { get; }

  public EntityUid ClientFeatureManifestUid { get; }

  public ClientFeatureManifestContent ClientFeatureManifest { get; }

  public Sha256Digest ClientFeatureManifestSha256 { get; }

  public EntityUid OperationalPolicyUid { get; }

  public Sha256Digest OperationalPolicySha256 { get; }

  public IReadOnlyList<PrivateServerCapabilityEntry> Entries { get; }

  public Sha256Digest ContentSha256 { get; }

  public bool IsBackendChallengeStateSupported => Get("solo_raid.challenge_state").Status ==
      PrivateServerCapabilityStatus.Supported;

  public bool IsOriginalClientPresentationAdapterBlocked =>
      Get("original_client.presentation_adapter").Status ==
      PrivateServerCapabilityStatus.BlockedByGate;

  public PrivateServerCapabilityEntry Get(string capabilityCode)
  {
    var code = PrivateServerGuard.RequireCode(
        capabilityCode,
        nameof(capabilityCode),
        maximumLength: 96);
    return Entries.Single(entry => string.Equals(entry.CapabilityCode, code, StringComparison.Ordinal));
  }

  public static PrivateServerCapabilityManifest CreatePhase2B(
      EntityUid manifestUid,
      EntityUid clientFeatureManifestUid,
      ClientFeatureManifestContent clientFeatureManifest,
      ChallengeOperationalPolicy operationalPolicy)
  {
    ValidatePhase2BClientFeatureManifest(clientFeatureManifest);
    ArgumentNullException.ThrowIfNull(operationalPolicy);
    var entries = new List<PrivateServerCapabilityEntry>
    {
      new("private_server.boot", PrivateServerCapabilityStatus.Supported),
      new("private_server.lobby", PrivateServerCapabilityStatus.Supported),
      new("solo_raid.directory", PrivateServerCapabilityStatus.Supported),
      new("solo_raid.challenge_state", PrivateServerCapabilityStatus.Supported),
      new("solo_raid.challenge_run", operationalPolicy.IsAdmissionReady
          ? PrivateServerCapabilityStatus.Supported
          : PrivateServerCapabilityStatus.Unresolved,
          operationalPolicy.IsAdmissionReady ? null : "challenge_operational_policy_unresolved"),
      new("solo_raid.normal_combat", PrivateServerCapabilityStatus.Unsupported),
      new("solo_raid.quick_battle", PrivateServerCapabilityStatus.Unsupported),
      CreateMockBattleEntry(operationalPolicy),
      CreateLocalRankingEntry(operationalPolicy),
      new("recruit.navigation", PrivateServerCapabilityStatus.VisibleNoOp),
      new(
          "original_client.wire_adapter",
          PrivateServerCapabilityStatus.BlockedByGate,
          "original_client_gate_not_satisfied"),
      new(
          "original_client.presentation_adapter",
          PrivateServerCapabilityStatus.BlockedByGate,
          "original_client_presentation_gate_not_satisfied")
    };

    var normalized = entries
        .OrderBy(static entry => entry.CapabilityCode, StringComparer.Ordinal)
        .ToArray();
    return new PrivateServerCapabilityManifest(
        manifestUid,
        clientFeatureManifestUid,
        clientFeatureManifest,
        operationalPolicy.PolicyUid,
        operationalPolicy.ContentSha256,
        Array.AsReadOnly(normalized));
  }

  private static void ValidatePhase2BClientFeatureManifest(
      ClientFeatureManifestContent manifest)
  {
    ArgumentNullException.ThrowIfNull(manifest);
    if (!string.Equals(
            manifest.ContractVersion,
            "nll/client-feature-manifest/v2",
            StringComparison.Ordinal))
    {
      throw new PrivateServerIntegrityException("phase2b_client_feature_manifest_contract_invalid");
    }

    var expected = new Dictionary<string, ClientFeatureCapability>(StringComparer.Ordinal)
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
    };
    if (manifest.Entries.Count != expected.Count || manifest.Entries.Any(entry =>
            !expected.TryGetValue(entry.RouteCode, out var capability) ||
            entry.Capability != capability))
    {
      throw new PrivateServerIntegrityException("phase2b_client_feature_manifest_entries_invalid");
    }
  }

  private static PrivateServerCapabilityEntry CreateMockBattleEntry(
      ChallengeOperationalPolicy policy)
  {
    if (!policy.MockBattleCapability.IsConfigured)
    {
      return new PrivateServerCapabilityEntry(
          "solo_raid.mock_battle",
          PrivateServerCapabilityStatus.Unresolved,
          policy.MockBattleCapability.UnresolvedReasonCode);
    }

    return new PrivateServerCapabilityEntry(
        "solo_raid.mock_battle",
        policy.MockBattleCapability.RequireConfigured() ==
            global::NikkeLocalLab.Domain.PrivateServer.MockBattleCapability.LabOwnedOnly
            ? PrivateServerCapabilityStatus.Supported
            : PrivateServerCapabilityStatus.Unsupported);
  }

  private static PrivateServerCapabilityEntry CreateLocalRankingEntry(
      ChallengeOperationalPolicy policy)
  {
    if (!policy.LocalRankingCapability.IsConfigured)
    {
      return new PrivateServerCapabilityEntry(
          "solo_raid.local_ranking",
          PrivateServerCapabilityStatus.Unresolved,
          policy.LocalRankingCapability.UnresolvedReasonCode);
    }

    return new PrivateServerCapabilityEntry(
        "solo_raid.local_ranking",
        policy.LocalRankingCapability.RequireConfigured() ==
            global::NikkeLocalLab.Domain.PrivateServer.LocalRankingCapability.LocalRecordsOnly
            ? PrivateServerCapabilityStatus.Supported
            : PrivateServerCapabilityStatus.Unsupported);
  }

  public static string Code(PrivateServerCapabilityStatus value) => value switch
  {
    PrivateServerCapabilityStatus.Supported => "supported",
    PrivateServerCapabilityStatus.Unsupported => "unsupported",
    PrivateServerCapabilityStatus.VisibleNoOp => "visible_no_op",
    PrivateServerCapabilityStatus.BlockedByGate => "blocked_by_gate",
    PrivateServerCapabilityStatus.Unresolved => "unresolved",
    _ => throw new PrivateServerIntegrityException("private_server_capability_status_invalid")
  };
}

public sealed class SoloRaidFixedCapabilities
{
  public const string ContractId = "nll/solo-raid-fixed-capabilities/v1";

  private SoloRaidFixedCapabilities()
  {
    ContentSha256 = PrivateServerHash.Compute(ContractId, hash =>
    {
      PrivateServerHash.Append(hash, NormalStagesImplemented);
      PrivateServerHash.Append(hash, NormalLastClearLevel);
      PrivateServerHash.Append(hash, ChallengeUnlocked);
      PrivateServerHash.Append(hash, NormalCombatCapabilityCode);
      PrivateServerHash.Append(hash, QuickBattleCapabilityCode);
      PrivateServerHash.Append(hash, SeasonAvailabilityCode);
      PrivateServerHash.Append(hash, SeasonEndsAtUtc);
    });
  }

  public static SoloRaidFixedCapabilities V1 { get; } = new();

  public bool NormalStagesImplemented => false;

  public int NormalLastClearLevel => 7;

  public bool ChallengeUnlocked => true;

  public string NormalCombatCapabilityCode => "unsupported";

  public string QuickBattleCapabilityCode => "unsupported";

  public string SeasonAvailabilityCode => "permanent";

  public DateTimeOffset? SeasonEndsAtUtc => null;

  public Sha256Digest ContentSha256 { get; }
}

public enum ClientContextStage
{
  Loading,
  LocalConnected,
  LobbyReady,
  Closed
}

public sealed class LocalClientContext
{
  public const string ContractId = "nll/private-server-client-context/v1";

  private LocalClientContext(
      EntityUid clientContextUid,
      EntityUid contextRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid sessionUid,
      EntityUid accountUid,
      EntityUid applicationBuildUid,
      Sha256Digest applicationBuildSha256,
      string applicationContractId,
      EntityUid capabilityManifestUid,
      Sha256Digest capabilityManifestSha256,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc,
      ClientContextStage stage,
      DateTimeOffset? connectedAtUtc,
      DateTimeOffset? lobbyReadyAtUtc,
      Sha256Digest? accountRevisionSetSha256,
      EntityUid? selectedSeasonRevisionUid,
      Sha256Digest? selectedSeasonContentSha256,
      DateTimeOffset? closedAtUtc)
  {
    PrivateServerGuard.RequireRevisionShape(revisionNumber, predecessorRevisionUid);
    ClientContextUid = PrivateServerGuard.RequireUid(clientContextUid, nameof(clientContextUid));
    ContextRevisionUid = PrivateServerGuard.RequireUid(contextRevisionUid, nameof(contextRevisionUid));
    RevisionNumber = revisionNumber;
    PredecessorRevisionUid = predecessorRevisionUid;
    SessionUid = PrivateServerGuard.RequireUid(sessionUid, nameof(sessionUid));
    AccountUid = PrivateServerGuard.RequireUid(accountUid, nameof(accountUid));
    ApplicationBuildUid = PrivateServerGuard.RequireUid(
        applicationBuildUid,
        nameof(applicationBuildUid));
    ApplicationBuildSha256 = PrivateServerGuard.RequireDigest(
        applicationBuildSha256,
        nameof(applicationBuildSha256));
    ApplicationContractId = PrivateServerGuard.RequireVersionedContract(
        applicationContractId,
        "nll/private-server-application/",
        nameof(applicationContractId));
    CapabilityManifestUid = PrivateServerGuard.RequireUid(
        capabilityManifestUid,
        nameof(capabilityManifestUid));
    CapabilityManifestSha256 = PrivateServerGuard.RequireDigest(
        capabilityManifestSha256,
        nameof(capabilityManifestSha256));
    IssuedAtUtc = PrivateServerGuard.NormalizeUtc(issuedAtUtc, nameof(issuedAtUtc));
    ExpiresAtUtc = PrivateServerGuard.NormalizeUtc(expiresAtUtc, nameof(expiresAtUtc));
    if (ExpiresAtUtc <= IssuedAtUtc || !Enum.IsDefined(stage))
    {
      throw new PrivateServerIntegrityException("private_server_client_context_shape_invalid");
    }

    Stage = stage;
    ConnectedAtUtc = connectedAtUtc.HasValue
        ? PrivateServerGuard.NormalizeUtc(connectedAtUtc.Value, nameof(connectedAtUtc))
        : null;
    LobbyReadyAtUtc = lobbyReadyAtUtc.HasValue
        ? PrivateServerGuard.NormalizeUtc(lobbyReadyAtUtc.Value, nameof(lobbyReadyAtUtc))
        : null;
    AccountRevisionSetSha256 = accountRevisionSetSha256;
    SelectedSeasonRevisionUid = selectedSeasonRevisionUid;
    SelectedSeasonContentSha256 = selectedSeasonContentSha256;
    ClosedAtUtc = closedAtUtc.HasValue
        ? PrivateServerGuard.NormalizeUtc(closedAtUtc.Value, nameof(closedAtUtc))
        : null;
    ValidateStageShape();
    ContentSha256 = ComputeContentSha256(this);
  }

  public EntityUid ClientContextUid { get; }

  public EntityUid ContextRevisionUid { get; }

  public long RevisionNumber { get; }

  public EntityUid? PredecessorRevisionUid { get; }

  public EntityUid SessionUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ApplicationBuildUid { get; }

  public Sha256Digest ApplicationBuildSha256 { get; }

  public string ApplicationContractId { get; }

  public EntityUid CapabilityManifestUid { get; }

  public Sha256Digest CapabilityManifestSha256 { get; }

  public DateTimeOffset IssuedAtUtc { get; }

  public DateTimeOffset ExpiresAtUtc { get; }

  public ClientContextStage Stage { get; }

  public DateTimeOffset? ConnectedAtUtc { get; }

  public DateTimeOffset? LobbyReadyAtUtc { get; }

  public Sha256Digest? AccountRevisionSetSha256 { get; }

  public EntityUid? SelectedSeasonRevisionUid { get; }

  public Sha256Digest? SelectedSeasonContentSha256 { get; }

  public DateTimeOffset? ClosedAtUtc { get; }

  public Sha256Digest ContentSha256 { get; }

  public static LocalClientContext Open(
      EntityUid clientContextUid,
      EntityUid contextRevisionUid,
      EntityUid sessionUid,
      EntityUid accountUid,
      EntityUid applicationBuildUid,
      Sha256Digest applicationBuildSha256,
      string applicationContractId,
      PrivateServerCapabilityManifest capabilityManifest,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc)
  {
    ArgumentNullException.ThrowIfNull(capabilityManifest);
    return new LocalClientContext(
        clientContextUid,
        contextRevisionUid,
        1,
        null,
        sessionUid,
        accountUid,
        applicationBuildUid,
        applicationBuildSha256,
        applicationContractId,
        capabilityManifest.ManifestUid,
        capabilityManifest.ContentSha256,
        issuedAtUtc,
        expiresAtUtc,
        ClientContextStage.Loading,
        null,
        null,
        null,
        null,
        null,
        null);
  }

  public static LocalClientContext Restore(
      EntityUid clientContextUid,
      EntityUid contextRevisionUid,
      long revisionNumber,
      EntityUid? predecessorRevisionUid,
      EntityUid sessionUid,
      EntityUid accountUid,
      EntityUid applicationBuildUid,
      Sha256Digest applicationBuildSha256,
      string applicationContractId,
      EntityUid capabilityManifestUid,
      Sha256Digest capabilityManifestSha256,
      DateTimeOffset issuedAtUtc,
      DateTimeOffset expiresAtUtc,
      ClientContextStage stage,
      DateTimeOffset? connectedAtUtc,
      DateTimeOffset? lobbyReadyAtUtc,
      Sha256Digest? accountRevisionSetSha256,
      EntityUid? selectedSeasonRevisionUid,
      Sha256Digest? selectedSeasonContentSha256,
      DateTimeOffset? closedAtUtc) =>
      new(
          clientContextUid,
          contextRevisionUid,
          revisionNumber,
          predecessorRevisionUid,
          sessionUid,
          accountUid,
          applicationBuildUid,
          applicationBuildSha256,
          applicationContractId,
          capabilityManifestUid,
          capabilityManifestSha256,
          issuedAtUtc,
          expiresAtUtc,
          stage,
          connectedAtUtc,
          lobbyReadyAtUtc,
          accountRevisionSetSha256,
          selectedSeasonRevisionUid,
          selectedSeasonContentSha256,
          closedAtUtc);

  public LocalClientContext Connect(
      EntityUid nextRevisionUid,
      DateTimeOffset observedAtUtc,
      EntityUid selectedSeasonRevisionUid,
      Sha256Digest selectedSeasonContentSha256)
  {
    RequireStage(ClientContextStage.Loading);
    var observed = RequireActiveInstant(observedAtUtc);
    return Advance(
        nextRevisionUid,
        ClientContextStage.LocalConnected,
        observed,
        null,
        null,
        PrivateServerGuard.RequireUid(
            selectedSeasonRevisionUid,
            nameof(selectedSeasonRevisionUid)),
        PrivateServerGuard.RequireDigest(
            selectedSeasonContentSha256,
            nameof(selectedSeasonContentSha256)),
        null);
  }

  public LocalClientContext BindLobby(
      EntityUid nextRevisionUid,
      DateTimeOffset observedAtUtc,
      Sha256Digest accountRevisionSetSha256,
      EntityUid selectedSeasonRevisionUid,
      Sha256Digest selectedSeasonContentSha256)
  {
    RequireStage(ClientContextStage.LocalConnected);
    var observed = RequireActiveInstant(observedAtUtc);
    if (selectedSeasonRevisionUid != SelectedSeasonRevisionUid ||
        selectedSeasonContentSha256 != SelectedSeasonContentSha256)
    {
      throw new PrivateServerIntegrityException("selected_raid_season_context_mismatch");
    }

    return Advance(
        nextRevisionUid,
        ClientContextStage.LobbyReady,
        ConnectedAtUtc,
        observed,
        PrivateServerGuard.RequireDigest(
            accountRevisionSetSha256,
            nameof(accountRevisionSetSha256)),
        PrivateServerGuard.RequireUid(
            selectedSeasonRevisionUid,
            nameof(selectedSeasonRevisionUid)),
        PrivateServerGuard.RequireDigest(
            selectedSeasonContentSha256,
            nameof(selectedSeasonContentSha256)),
        null);
  }

  public LocalClientContext Close(EntityUid nextRevisionUid, DateTimeOffset observedAtUtc)
  {
    if (Stage == ClientContextStage.Closed)
    {
      return this;
    }

    var observed = PrivateServerGuard.NormalizeUtc(observedAtUtc, nameof(observedAtUtc));
    if (observed < IssuedAtUtc)
    {
      throw new PrivateServerIntegrityException("private_server_client_context_time_invalid");
    }

    return Advance(
        nextRevisionUid,
        ClientContextStage.Closed,
        ConnectedAtUtc,
        LobbyReadyAtUtc,
        AccountRevisionSetSha256,
        SelectedSeasonRevisionUid,
        SelectedSeasonContentSha256,
        observed);
  }

  public LocalClientContext RebindSelectedSeason(
      EntityUid nextRevisionUid,
      DateTimeOffset observedAtUtc,
      EntityUid selectedSeasonRevisionUid,
      Sha256Digest selectedSeasonContentSha256)
  {
    RequireStage(ClientContextStage.LobbyReady);
    _ = RequireActiveInstant(observedAtUtc);
    var selectedRevisionUid = PrivateServerGuard.RequireUid(
        selectedSeasonRevisionUid,
        nameof(selectedSeasonRevisionUid));
    var selectedContentSha256 = PrivateServerGuard.RequireDigest(
        selectedSeasonContentSha256,
        nameof(selectedSeasonContentSha256));
    if (selectedRevisionUid == SelectedSeasonRevisionUid &&
        selectedContentSha256 == SelectedSeasonContentSha256)
    {
      return this;
    }

    return Advance(
        nextRevisionUid,
        ClientContextStage.LobbyReady,
        ConnectedAtUtc,
        LobbyReadyAtUtc,
        AccountRevisionSetSha256,
        selectedRevisionUid,
        selectedContentSha256,
        null);
  }

  public void RequireLobbyReady(DateTimeOffset observedAtUtc)
  {
    RequireStage(ClientContextStage.LobbyReady);
    _ = RequireActiveInstant(observedAtUtc);
  }

  private LocalClientContext Advance(
      EntityUid nextRevisionUid,
      ClientContextStage stage,
      DateTimeOffset? connectedAtUtc,
      DateTimeOffset? lobbyReadyAtUtc,
      Sha256Digest? accountRevisionSetSha256,
      EntityUid? selectedSeasonRevisionUid,
      Sha256Digest? selectedSeasonContentSha256,
      DateTimeOffset? closedAtUtc)
  {
    var requiredRevisionUid = PrivateServerGuard.RequireUid(nextRevisionUid, nameof(nextRevisionUid));
    if (requiredRevisionUid == ContextRevisionUid)
    {
      throw new PrivateServerIntegrityException("private_server_revision_uid_reused");
    }

    return new LocalClientContext(
        ClientContextUid,
        requiredRevisionUid,
        RevisionNumber + 1,
        ContextRevisionUid,
        SessionUid,
        AccountUid,
        ApplicationBuildUid,
        ApplicationBuildSha256,
        ApplicationContractId,
        CapabilityManifestUid,
        CapabilityManifestSha256,
        IssuedAtUtc,
        ExpiresAtUtc,
        stage,
        connectedAtUtc,
        lobbyReadyAtUtc,
        accountRevisionSetSha256,
        selectedSeasonRevisionUid,
        selectedSeasonContentSha256,
        closedAtUtc);
  }

  private DateTimeOffset RequireActiveInstant(DateTimeOffset observedAtUtc)
  {
    var observed = PrivateServerGuard.NormalizeUtc(observedAtUtc, nameof(observedAtUtc));
    if (observed < IssuedAtUtc || observed >= ExpiresAtUtc)
    {
      throw new PrivateServerIntegrityException("private_server_local_session_not_active");
    }

    return observed;
  }

  private void RequireStage(ClientContextStage expected)
  {
    if (Stage != expected)
    {
      throw new PrivateServerIntegrityException("private_server_client_context_transition_invalid");
    }
  }

  private void ValidateStageShape()
  {
    var hasSelectedSeasonRevision = SelectedSeasonRevisionUid.HasValue;
    var hasSelectedSeasonContent = SelectedSeasonContentSha256.HasValue;
    var selectedSeasonPairIsValid =
        hasSelectedSeasonRevision == hasSelectedSeasonContent;
    var connectedInstantIsValid = !ConnectedAtUtc.HasValue ||
        (ConnectedAtUtc.Value >= IssuedAtUtc && ConnectedAtUtc.Value < ExpiresAtUtc);
    var lobbyReadyInstantIsValid = !LobbyReadyAtUtc.HasValue ||
        (ConnectedAtUtc.HasValue &&
            LobbyReadyAtUtc.Value >= ConnectedAtUtc.Value &&
            LobbyReadyAtUtc.Value < ExpiresAtUtc);
    var closedInstantIsValid = !ClosedAtUtc.HasValue ||
        (ClosedAtUtc.Value >= IssuedAtUtc &&
            (!ConnectedAtUtc.HasValue || ClosedAtUtc.Value >= ConnectedAtUtc.Value) &&
            (!LobbyReadyAtUtc.HasValue || ClosedAtUtc.Value >= LobbyReadyAtUtc.Value));

    var valid = Stage switch
    {
      ClientContextStage.Loading =>
          ConnectedAtUtc is null && LobbyReadyAtUtc is null && AccountRevisionSetSha256 is null &&
          SelectedSeasonRevisionUid is null && SelectedSeasonContentSha256 is null && ClosedAtUtc is null,
      ClientContextStage.LocalConnected =>
          ConnectedAtUtc.HasValue && LobbyReadyAtUtc is null && AccountRevisionSetSha256 is null &&
          SelectedSeasonRevisionUid.HasValue && SelectedSeasonContentSha256.HasValue && ClosedAtUtc is null,
      ClientContextStage.LobbyReady =>
          ConnectedAtUtc.HasValue && LobbyReadyAtUtc.HasValue && AccountRevisionSetSha256.HasValue &&
          SelectedSeasonRevisionUid.HasValue && SelectedSeasonContentSha256.HasValue && ClosedAtUtc is null,
      ClientContextStage.Closed => ClosedAtUtc.HasValue &&
          ((ConnectedAtUtc is null && LobbyReadyAtUtc is null &&
                AccountRevisionSetSha256 is null && !hasSelectedSeasonRevision) ||
              (ConnectedAtUtc.HasValue && LobbyReadyAtUtc is null &&
                AccountRevisionSetSha256 is null && hasSelectedSeasonRevision) ||
              (ConnectedAtUtc.HasValue && LobbyReadyAtUtc.HasValue &&
                AccountRevisionSetSha256.HasValue && hasSelectedSeasonRevision)),
      _ => false
    };
    if (!valid || !selectedSeasonPairIsValid || !connectedInstantIsValid ||
        !lobbyReadyInstantIsValid || !closedInstantIsValid)
    {
      throw new PrivateServerIntegrityException("private_server_client_context_shape_invalid");
    }
  }

  private static Sha256Digest ComputeContentSha256(LocalClientContext value) =>
      PrivateServerHash.Compute(ContractId, hash =>
      {
        PrivateServerHash.Append(hash, value.ClientContextUid);
        PrivateServerHash.Append(hash, value.SessionUid);
        PrivateServerHash.Append(hash, value.AccountUid);
        PrivateServerHash.Append(hash, value.ApplicationBuildUid);
        PrivateServerHash.Append(hash, value.ApplicationBuildSha256);
        PrivateServerHash.Append(hash, value.ApplicationContractId);
        PrivateServerHash.Append(hash, value.CapabilityManifestUid);
        PrivateServerHash.Append(hash, value.CapabilityManifestSha256);
        PrivateServerHash.Append(hash, value.IssuedAtUtc);
        PrivateServerHash.Append(hash, value.ExpiresAtUtc);
        PrivateServerHash.Append(hash, Code(value.Stage));
        PrivateServerHash.Append(hash, value.ConnectedAtUtc);
        PrivateServerHash.Append(hash, value.LobbyReadyAtUtc);
        PrivateServerHash.Append(hash, value.AccountRevisionSetSha256);
        PrivateServerHash.Append(hash, value.SelectedSeasonRevisionUid);
        PrivateServerHash.Append(hash, value.SelectedSeasonContentSha256);
        PrivateServerHash.Append(hash, value.ClosedAtUtc);
      });

  public static string Code(ClientContextStage value) => value switch
  {
    ClientContextStage.Loading => "loading",
    ClientContextStage.LocalConnected => "local_connected",
    ClientContextStage.LobbyReady => "lobby_ready",
    ClientContextStage.Closed => "closed",
    _ => throw new PrivateServerIntegrityException("private_server_client_context_stage_invalid")
  };
}
