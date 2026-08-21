using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;
using DomainLocalGameState = NikkeLocalLab.Domain.LocalGameState;

namespace NikkeLocalLab.Persistence.PostgreSql;

public sealed class LocalGameStateIntegrityException : Exception
{
  public LocalGameStateIntegrityException(string code)
      : base(code)
  {
    Code = LocalGameStateContractGuard.RequireCode(code);
  }

  public string Code { get; }
}

public enum LocalGameValueStatus
{
  Ready,
  Unresolved
}

public enum LocalGameRevisionOrigin
{
  SystemDefault,
  UserEdit,
  OfflineSanitizedImport,
  Rebase
}

public enum LocalWalletCurrency
{
  Jewel,
  Credit
}

public enum LocalClientFeatureCapability
{
  Supported,
  Hidden,
  VisibleNoOp,
  NotSupported
}

public sealed record LocalGameIntFact
{
  public LocalGameIntFact(
      LocalGameValueStatus status,
      int? value = null,
      string? unresolvedReasonCode = null)
  {
    _ = LocalGameStateDomainProjection.ToDomain(status, value, unresolvedReasonCode);
    Status = status;
    Value = value;
    UnresolvedReasonCode = unresolvedReasonCode;
  }

  public LocalGameValueStatus Status { get; }

  public int? Value { get; }

  public string? UnresolvedReasonCode { get; }

  public static LocalGameIntFact Ready(int value) => new(LocalGameValueStatus.Ready, value);

  public static LocalGameIntFact Unresolved(string reasonCode) =>
      new(LocalGameValueStatus.Unresolved, unresolvedReasonCode: reasonCode);
}

public sealed record LocalGameUidFact
{
  public LocalGameUidFact(
      LocalGameValueStatus status,
      EntityUid? value = null,
      string? unresolvedReasonCode = null)
  {
    _ = LocalGameStateDomainProjection.ToDomain(status, value, unresolvedReasonCode);

    Status = status;
    Value = value;
    UnresolvedReasonCode = unresolvedReasonCode;
  }

  public LocalGameValueStatus Status { get; }

  public EntityUid? Value { get; }

  public string? UnresolvedReasonCode { get; }

  public static LocalGameUidFact Ready(EntityUid value) =>
      new(LocalGameValueStatus.Ready, value);

  public static LocalGameUidFact Unresolved(string reasonCode) =>
      new(LocalGameValueStatus.Unresolved, unresolvedReasonCode: reasonCode);
}

public sealed record LocalLobbyPresentationWrite
{
  public LocalLobbyPresentationWrite(
      string displayName,
      LocalGameIntFact commanderLevel,
      LocalGameUidFact lobbyCharacter,
      LocalGameUidFact profileIcon,
      LocalGameUidFact profileFrame,
      LocalGameUidFact lobbyBackground,
      LocalGameRevisionOrigin origin = LocalGameRevisionOrigin.UserEdit)
  {
    CommanderLevel = commanderLevel ?? throw new ArgumentNullException(nameof(commanderLevel));
    LobbyCharacter = lobbyCharacter ?? throw new ArgumentNullException(nameof(lobbyCharacter));
    ProfileIcon = profileIcon ?? throw new ArgumentNullException(nameof(profileIcon));
    ProfileFrame = profileFrame ?? throw new ArgumentNullException(nameof(profileFrame));
    LobbyBackground = lobbyBackground ?? throw new ArgumentNullException(nameof(lobbyBackground));
    var domain = LocalGameStateDomainProjection.ToDomain(
        displayName,
        CommanderLevel,
        LobbyCharacter,
        ProfileIcon,
        ProfileFrame,
        LobbyBackground,
        origin);
    DisplayName = domain.DisplayName;
    Origin = origin;
    ContentSha256 = domain.ContentSha256;
  }

  public string DisplayName { get; }

  public LocalGameIntFact CommanderLevel { get; }

  public LocalGameUidFact LobbyCharacter { get; }

  public LocalGameUidFact ProfileIcon { get; }

  public LocalGameUidFact ProfileFrame { get; }

  public LocalGameUidFact LobbyBackground { get; }

  public LocalGameRevisionOrigin Origin { get; }

  public Sha256Digest ContentSha256 { get; }
}

public sealed record LocalWalletBalance
{
  public LocalWalletBalance(LocalWalletCurrency currency, long amount)
  {
    _ = LocalGameStateDomainProjection.ToDomain(currency, amount);
    Currency = currency;
    Amount = amount;
  }

  public LocalWalletCurrency Currency { get; }

  public long Amount { get; }
}

public sealed record LocalWalletWrite
{
  public LocalWalletWrite(
      IEnumerable<LocalWalletBalance> balances,
      LocalGameRevisionOrigin origin = LocalGameRevisionOrigin.UserEdit)
  {
    ArgumentNullException.ThrowIfNull(balances);
    var normalized = balances.OrderBy(static item => item.Currency).ToArray();
    var domain = LocalGameStateDomainProjection.ToDomain(normalized, origin);
    Balances = Array.AsReadOnly(normalized);
    Origin = origin;
    ContentSha256 = domain.ContentSha256;
  }

  public IReadOnlyList<LocalWalletBalance> Balances { get; }

  public LocalGameRevisionOrigin Origin { get; }

  public Sha256Digest ContentSha256 { get; }

  public static LocalWalletWrite CreateDefault() => new(
      [
        new LocalWalletBalance(LocalWalletCurrency.Jewel, 0),
        new LocalWalletBalance(LocalWalletCurrency.Credit, 0)
      ],
      LocalGameRevisionOrigin.SystemDefault);
}

public sealed record LocalClientFeatureEntry
{
  public LocalClientFeatureEntry(
      string routeCode,
      LocalClientFeatureCapability capability)
  {
    var domain = LocalGameStateDomainProjection.ToDomain(routeCode, capability);
    RouteCode = domain.RouteCode;
    Capability = capability;
  }

  public string RouteCode { get; }

  public LocalClientFeatureCapability Capability { get; }
}

public sealed record LocalClientFeatureManifestWrite
{
  public LocalClientFeatureManifestWrite(
      string contractVersion,
      IEnumerable<LocalClientFeatureEntry> entries)
  {
    ArgumentNullException.ThrowIfNull(entries);
    var normalized = entries.OrderBy(static item => item.RouteCode, StringComparer.Ordinal).ToArray();
    var domain = LocalGameStateDomainProjection.ToDomain(contractVersion, normalized);
    ContractVersion = domain.ContractVersion;
    Entries = Array.AsReadOnly(normalized);
    ContentSha256 = domain.ContentSha256;
  }

  public string ContractVersion { get; }

  public IReadOnlyList<LocalClientFeatureEntry> Entries { get; }

  public Sha256Digest ContentSha256 { get; }
}

public sealed record PublishLocalClientFeatureManifestCommand
{
  public PublishLocalClientFeatureManifestCommand(
      EntityUid operationUid,
      LocalClientFeatureManifestWrite manifest,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "local_game_operation_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    OperationUid = operationUid;
    Manifest = manifest ?? throw new ArgumentNullException(nameof(manifest));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = LocalGameStateContractCanonicalizer.ComputeFeatureRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public LocalClientFeatureManifestWrite Manifest { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record InitializeLocalGameStateCommand
{
  public InitializeLocalGameStateCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedProfileTemplateRevisionUid,
      EntityUid featureManifestUid,
      LocalLobbyPresentationWrite lobby,
      LocalWalletWrite wallet,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "local_game_operation_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedProfileTemplateRevisionUid,
        "local_game_profile_revision_uid_invalid");
    LocalGameStateContractGuard.RequireUid(featureManifestUid, "local_game_manifest_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    OperationUid = operationUid;
    AccountUid = accountUid;
    ExpectedProfileTemplateRevisionUid = expectedProfileTemplateRevisionUid;
    FeatureManifestUid = featureManifestUid;
    Lobby = lobby ?? throw new ArgumentNullException(nameof(lobby));
    Wallet = wallet ?? throw new ArgumentNullException(nameof(wallet));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = LocalGameStateContractCanonicalizer.ComputeInitializeRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedProfileTemplateRevisionUid { get; }

  public EntityUid FeatureManifestUid { get; }

  public LocalLobbyPresentationWrite Lobby { get; }

  public LocalWalletWrite Wallet { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record SaveLobbyPresentationCommand
{
  public SaveLobbyPresentationCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedLobbyPresentationRevisionUid,
      EntityUid expectedProfileTemplateRevisionUid,
      LocalLobbyPresentationWrite lobby,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "local_game_operation_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedLobbyPresentationRevisionUid,
        "local_game_expected_revision_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedProfileTemplateRevisionUid,
        "local_game_profile_revision_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    OperationUid = operationUid;
    AccountUid = accountUid;
    ExpectedLobbyPresentationRevisionUid = expectedLobbyPresentationRevisionUid;
    ExpectedProfileTemplateRevisionUid = expectedProfileTemplateRevisionUid;
    Lobby = lobby ?? throw new ArgumentNullException(nameof(lobby));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = LocalGameStateContractCanonicalizer.ComputeLobbyRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedLobbyPresentationRevisionUid { get; }

  public EntityUid ExpectedProfileTemplateRevisionUid { get; }

  public LocalLobbyPresentationWrite Lobby { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record SaveWalletCommand
{
  public SaveWalletCommand(
      EntityUid operationUid,
      EntityUid accountUid,
      EntityUid expectedWalletRevisionUid,
      LocalWalletWrite wallet,
      DateTimeOffset createdAtUtc)
  {
    LocalGameStateContractGuard.RequireUid(operationUid, "local_game_operation_uid_invalid");
    LocalGameStateContractGuard.RequireUid(accountUid, "local_game_account_uid_invalid");
    LocalGameStateContractGuard.RequireUid(
        expectedWalletRevisionUid,
        "local_game_expected_revision_uid_invalid");
    LocalGameStateContractGuard.RequireTimestamp(createdAtUtc);
    OperationUid = operationUid;
    AccountUid = accountUid;
    ExpectedWalletRevisionUid = expectedWalletRevisionUid;
    Wallet = wallet ?? throw new ArgumentNullException(nameof(wallet));
    CreatedAtUtc = createdAtUtc;
    RequestSha256 = LocalGameStateContractCanonicalizer.ComputeWalletRequestSha256(this);
  }

  public EntityUid OperationUid { get; }

  public EntityUid AccountUid { get; }

  public EntityUid ExpectedWalletRevisionUid { get; }

  public LocalWalletWrite Wallet { get; }

  public DateTimeOffset CreatedAtUtc { get; }

  public Sha256Digest RequestSha256 { get; }
}

public sealed record LocalGameRevisionLineage(
    int RevisionNumber,
    EntityUid? PreviousRevisionUid,
    LocalGameRevisionOrigin Origin,
    DateTimeOffset MaterializedAtUtc);

public sealed record LocalLobbyPresentationReceipt(
    EntityUid RevisionUid,
    LocalGameRevisionLineage Lineage,
    Sha256Digest ContentSha256,
    LocalLobbyPresentationWrite Content);

public sealed record LocalWalletReceipt(
    EntityUid RevisionUid,
    LocalGameRevisionLineage Lineage,
    Sha256Digest ContentSha256,
    LocalWalletWrite Content);

public sealed record LocalClientFeatureManifestReceipt(
    EntityUid ManifestUid,
    bool IsReused,
    string ContractVersion,
    Sha256Digest ContentSha256,
    DateTimeOffset PublishedAtUtc,
    IReadOnlyList<LocalClientFeatureEntry> Entries);

public sealed record LocalGameStateReceipt(
    EntityUid? OperationUid,
    bool IsIdempotentReplay,
    EntityUid AccountUid,
    EntityUid ProfileTemplateRevisionUid,
    LocalLobbyPresentationReceipt Lobby,
    LocalWalletReceipt Wallet,
    LocalClientFeatureManifestReceipt FeatureManifest);

public sealed record LocalClientRosterEntryProjection(
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid BuildRevisionUid,
    Sha256Digest BuildContentSha256,
    bool IsSelectionReady,
    bool HasCombatSemantics);

public sealed record LocalClientSquadMemberProjection(
    int Position,
    EntityUid CharacterUid,
    EntityUid CharacterBuildUid,
    EntityUid BuildRevisionUid);

public sealed record LocalClientSquadProjection(
    EntityUid SquadUid,
    EntityUid SquadRevisionUid,
    IReadOnlyList<LocalClientSquadMemberProjection> Members);

public sealed record LocalClientInventoryValueProjection(
    string FieldCode,
    string StatusCode,
    long? IntegerValue = null,
    bool? BooleanValue = null,
    EntityUid? ReferenceUid = null,
    long? UnscaledValue = null,
    int? DecimalScale = null,
    string? ControlledValue = null,
    string? UnresolvedReasonCode = null);

public sealed record LocalClientInventoryItemProjection(
    string ItemKind,
    EntityUid? ProjectionUid,
    EntityUid CharacterUid,
    EntityUid BuildRevisionUid,
    string? SlotCode,
    string StateCode,
    EntityUid? DefinitionUid,
    EntityUid? DefinitionVersionUid,
    string? LevelStatus,
    int? Level,
    string? LevelUnresolvedReasonCode,
    IReadOnlyList<LocalClientInventoryValueProjection>? Values = null);

public sealed record LocalClientInventorySubsetProjection(
    string ScopeCode,
    bool IsCompleteInventory,
    bool IsReadOnly,
    IReadOnlyList<LocalClientInventoryItemProjection> Items);

public sealed record LocalClientBootstrapProjection(
    EntityUid AccountUid,
    EntityUid ProfileTemplateRevisionUid,
    EntityUid AccountStateRevisionUid,
    Sha256Digest RevisionSetSha256,
    LocalLobbyPresentationReceipt Lobby,
    LocalWalletReceipt Wallet,
    LocalClientFeatureManifestReceipt FeatureManifest,
    IReadOnlyList<LocalClientRosterEntryProjection> Roster,
    LocalClientSquadProjection? Squad,
    LocalClientInventorySubsetProjection Inventory);

public static class LocalGameStateContractCanonicalizer
{
  public static Sha256Digest ComputeLobbySha256(LocalLobbyPresentationWrite value) =>
      LocalGameStateDomainProjection.ToDomain(value).ContentSha256;

  public static Sha256Digest ComputeWalletSha256(LocalWalletWrite value) =>
      LocalGameStateDomainProjection.ToDomain(value).ContentSha256;

  public static Sha256Digest ComputeFeatureManifestSha256(LocalClientFeatureManifestWrite value) =>
      LocalGameStateDomainProjection.ToDomain(value).ContentSha256;

  public static Sha256Digest ComputeFeatureRequestSha256(PublishLocalClientFeatureManifestCommand value) =>
      ComputeRequest(
          "nll/publish-client-feature-manifest-request/v1",
          value.Manifest.ContentSha256.ToString());

  public static Sha256Digest ComputeInitializeRequestSha256(InitializeLocalGameStateCommand value) =>
      ComputeRequest(
          "nll/initialize-local-game-state-request/v1",
          value.AccountUid.ToString(),
          value.ExpectedProfileTemplateRevisionUid.ToString(),
          value.FeatureManifestUid.ToString(),
          value.Lobby.ContentSha256.ToString(),
          value.Wallet.ContentSha256.ToString());

  public static Sha256Digest ComputeLobbyRequestSha256(SaveLobbyPresentationCommand value) =>
      ComputeRequest(
          "nll/save-lobby-presentation-request/v1",
          value.AccountUid.ToString(),
          value.ExpectedLobbyPresentationRevisionUid.ToString(),
          value.ExpectedProfileTemplateRevisionUid.ToString(),
          value.Lobby.ContentSha256.ToString());

  public static Sha256Digest ComputeWalletRequestSha256(SaveWalletCommand value) =>
      ComputeRequest(
          "nll/save-wallet-request/v1",
          value.AccountUid.ToString(),
          value.ExpectedWalletRevisionUid.ToString(),
          value.Wallet.ContentSha256.ToString());

  public static Sha256Digest ComputeRevisionSetSha256(params EntityUid[] revisionUids)
  {
    using var hash = Create("nll/client-bootstrap-revision-set/v1");
    foreach (var uid in revisionUids)
    {
      Append(hash, uid.ToString());
    }

    return Complete(hash);
  }

  public static string Code(LocalGameValueStatus value) =>
      DomainLocalGameState.LocalGameStateCanonicalizer.Code(
          LocalGameStateDomainProjection.ToDomain(value));

  public static string Code(LocalGameRevisionOrigin value) =>
      DomainLocalGameState.LocalGameStateCanonicalizer.Code(
          LocalGameStateDomainProjection.ToDomain(value));

  public static string Code(LocalWalletCurrency value) =>
      DomainLocalGameState.LocalGameStateCanonicalizer.Code(
          LocalGameStateDomainProjection.ToDomain(value));

  public static string Code(LocalClientFeatureCapability value) =>
      DomainLocalGameState.LocalGameStateCanonicalizer.Code(
          LocalGameStateDomainProjection.ToDomain(value));

  internal static LocalGameRevisionOrigin ParseOrigin(string value) => value switch
  {
    "system_default" => LocalGameRevisionOrigin.SystemDefault,
    "user_edit" => LocalGameRevisionOrigin.UserEdit,
    "offline_sanitized_import" => LocalGameRevisionOrigin.OfflineSanitizedImport,
    "rebase" => LocalGameRevisionOrigin.Rebase,
    _ => throw new LocalGameStateIntegrityException("local_game_revision_origin_invalid")
  };

  internal static LocalClientFeatureCapability ParseCapability(string value) => value switch
  {
    "supported" => LocalClientFeatureCapability.Supported,
    "hidden" => LocalClientFeatureCapability.Hidden,
    "visible_no_op" => LocalClientFeatureCapability.VisibleNoOp,
    "not_supported" => LocalClientFeatureCapability.NotSupported,
    _ => throw new LocalGameStateIntegrityException("local_game_feature_capability_invalid")
  };

  private static IncrementalHash Create(string domain)
  {
    var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, domain);
    return hash;
  }

  private static Sha256Digest ComputeRequest(string domain, params string[] fields)
  {
    using var hash = Create(domain);
    foreach (var field in fields)
    {
      Append(hash, field);
    }

    return Complete(hash);
  }

  private static void Append(IncrementalHash hash, string value)
  {
    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[4];
    System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  private static Sha256Digest Complete(IncrementalHash hash) =>
      Sha256Digest.FromBytes(hash.GetHashAndReset());

}

internal static class LocalGameStateDomainProjection
{
  internal static DomainLocalGameState.LocalGameFact<int> ToDomain(
      LocalGameValueStatus status,
      int? value,
      string? unresolvedReasonCode) =>
      Translate(() => new DomainLocalGameState.LocalGameFact<int>(
          ToDomain(status),
          value,
          unresolvedReasonCode));

  internal static DomainLocalGameState.LocalGameFact<EntityUid> ToDomain(
      LocalGameValueStatus status,
      EntityUid? value,
      string? unresolvedReasonCode) =>
      Translate(() => new DomainLocalGameState.LocalGameFact<EntityUid>(
          ToDomain(status),
          value,
          unresolvedReasonCode));

  internal static DomainLocalGameState.LobbyPresentationContent ToDomain(
      string displayName,
      LocalGameIntFact commanderLevel,
      LocalGameUidFact lobbyCharacter,
      LocalGameUidFact profileIcon,
      LocalGameUidFact profileFrame,
      LocalGameUidFact lobbyBackground,
      LocalGameRevisionOrigin origin) =>
      Translate(() => new DomainLocalGameState.LobbyPresentationContent(
          displayName,
          ToDomain(
              commanderLevel.Status,
              commanderLevel.Value,
              commanderLevel.UnresolvedReasonCode),
          ToDomain(
              lobbyCharacter.Status,
              lobbyCharacter.Value,
              lobbyCharacter.UnresolvedReasonCode),
          ToDomain(profileIcon.Status, profileIcon.Value, profileIcon.UnresolvedReasonCode),
          ToDomain(profileFrame.Status, profileFrame.Value, profileFrame.UnresolvedReasonCode),
          ToDomain(
              lobbyBackground.Status,
              lobbyBackground.Value,
              lobbyBackground.UnresolvedReasonCode),
          ToDomain(origin)));

  internal static DomainLocalGameState.LobbyPresentationContent ToDomain(
      LocalLobbyPresentationWrite value)
  {
    ArgumentNullException.ThrowIfNull(value);
    return ToDomain(
        value.DisplayName,
        value.CommanderLevel,
        value.LobbyCharacter,
        value.ProfileIcon,
        value.ProfileFrame,
        value.LobbyBackground,
        value.Origin);
  }

  internal static DomainLocalGameState.WalletBalance ToDomain(
      LocalWalletCurrency currency,
      long amount) =>
      Translate(() => new DomainLocalGameState.WalletBalance(ToDomain(currency), amount));

  internal static DomainLocalGameState.WalletContent ToDomain(
      IEnumerable<LocalWalletBalance> balances,
      LocalGameRevisionOrigin origin) =>
      Translate(() => new DomainLocalGameState.WalletContent(
          balances.Select(static item =>
          {
            if (item is null)
            {
              throw new DomainLocalGameState.LocalGameStateIntegrityException(
                  "local_game_wallet_set_invalid");
            }

            return ToDomain(item.Currency, item.Amount);
          }),
          ToDomain(origin)));

  internal static DomainLocalGameState.WalletContent ToDomain(LocalWalletWrite value)
  {
    ArgumentNullException.ThrowIfNull(value);
    return ToDomain(value.Balances, value.Origin);
  }

  internal static DomainLocalGameState.ClientFeatureEntry ToDomain(
      string routeCode,
      LocalClientFeatureCapability capability) =>
      Translate(() => new DomainLocalGameState.ClientFeatureEntry(
          routeCode,
          ToDomain(capability)));

  internal static DomainLocalGameState.ClientFeatureManifestContent ToDomain(
      string contractVersion,
      IEnumerable<LocalClientFeatureEntry> entries) =>
      Translate(() => new DomainLocalGameState.ClientFeatureManifestContent(
          contractVersion,
          entries.Select(static item =>
          {
            if (item is null)
            {
              throw new DomainLocalGameState.LocalGameStateIntegrityException(
                  "local_game_feature_set_invalid");
            }

            return ToDomain(item.RouteCode, item.Capability);
          })));

  internal static DomainLocalGameState.ClientFeatureManifestContent ToDomain(
      LocalClientFeatureManifestWrite value)
  {
    ArgumentNullException.ThrowIfNull(value);
    return ToDomain(value.ContractVersion, value.Entries);
  }

  internal static DomainLocalGameState.LocalGameFactStatus ToDomain(
      LocalGameValueStatus value) => value switch
      {
        LocalGameValueStatus.Ready => DomainLocalGameState.LocalGameFactStatus.Ready,
        LocalGameValueStatus.Unresolved => DomainLocalGameState.LocalGameFactStatus.Unresolved,
        _ => throw new LocalGameStateIntegrityException("local_game_fact_status_invalid")
      };

  internal static DomainLocalGameState.LocalGameRevisionOrigin ToDomain(
      LocalGameRevisionOrigin value) => value switch
      {
        LocalGameRevisionOrigin.SystemDefault =>
            DomainLocalGameState.LocalGameRevisionOrigin.SystemDefault,
        LocalGameRevisionOrigin.UserEdit => DomainLocalGameState.LocalGameRevisionOrigin.UserEdit,
        LocalGameRevisionOrigin.OfflineSanitizedImport =>
            DomainLocalGameState.LocalGameRevisionOrigin.OfflineSanitizedImport,
        LocalGameRevisionOrigin.Rebase => DomainLocalGameState.LocalGameRevisionOrigin.Rebase,
        _ => throw new LocalGameStateIntegrityException("local_game_revision_origin_invalid")
      };

  internal static DomainLocalGameState.WalletCurrency ToDomain(
      LocalWalletCurrency value) => value switch
      {
        LocalWalletCurrency.Jewel => DomainLocalGameState.WalletCurrency.Jewel,
        LocalWalletCurrency.Credit => DomainLocalGameState.WalletCurrency.Credit,
        _ => throw new LocalGameStateIntegrityException("local_game_currency_invalid")
      };

  internal static DomainLocalGameState.ClientFeatureCapability ToDomain(
      LocalClientFeatureCapability value) => value switch
      {
        LocalClientFeatureCapability.Supported =>
            DomainLocalGameState.ClientFeatureCapability.Supported,
        LocalClientFeatureCapability.Hidden => DomainLocalGameState.ClientFeatureCapability.Hidden,
        LocalClientFeatureCapability.VisibleNoOp =>
            DomainLocalGameState.ClientFeatureCapability.VisibleNoOp,
        LocalClientFeatureCapability.NotSupported =>
            DomainLocalGameState.ClientFeatureCapability.NotSupported,
        _ => throw new LocalGameStateIntegrityException("local_game_feature_capability_invalid")
      };

  private static T Translate<T>(Func<T> factory)
  {
    try
    {
      return factory();
    }
    catch (DomainLocalGameState.LocalGameStateIntegrityException exception)
    {
      throw new LocalGameStateIntegrityException(exception.Code);
    }
  }
}

internal static class LocalGameStateContractGuard
{
  internal static string RequireCode(string value)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 64 || value[0] is < 'a' or > 'z' ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new ArgumentException("A local-game code must be controlled.", nameof(value));
    }

    return value;
  }

  internal static void RequireUid(EntityUid value, string code)
  {
    if (value.Value == Guid.Empty)
    {
      throw new LocalGameStateIntegrityException(code);
    }
  }

  internal static void RequireTimestamp(DateTimeOffset value)
  {
    if (value.Offset != TimeSpan.Zero || value.Ticks % 10 != 0)
    {
      throw new LocalGameStateIntegrityException("local_game_timestamp_invalid");
    }
  }

}
