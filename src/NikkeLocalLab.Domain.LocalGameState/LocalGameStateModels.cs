using System.Buffers;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.LocalGameState;

public sealed class LocalGameStateIntegrityException : Exception
{
  public LocalGameStateIntegrityException(string code)
      : base(code)
  {
    Code = LocalGameStateGuard.RequireCode(code);
  }

  public string Code { get; }
}

public enum LocalGameFactStatus
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

public enum WalletCurrency
{
  Jewel,
  Credit
}

public enum ClientFeatureCapability
{
  Supported,
  Hidden,
  VisibleNoOp,
  NotSupported
}

public sealed record LocalGameFact<T>
    where T : struct
{
  public LocalGameFact(
      LocalGameFactStatus status,
      T? value = null,
      string? unresolvedReasonCode = null)
  {
    if (!Enum.IsDefined(status) ||
        (status == LocalGameFactStatus.Ready && (!value.HasValue || unresolvedReasonCode is not null)) ||
        (status == LocalGameFactStatus.Unresolved && (value.HasValue || unresolvedReasonCode is null)))
    {
      throw new LocalGameStateIntegrityException("local_game_fact_shape_invalid");
    }

    if (value is EntityUid uid && uid.Value == Guid.Empty)
    {
      throw new LocalGameStateIntegrityException("local_game_fact_uid_invalid");
    }

    Status = status;
    Value = value;
    UnresolvedReasonCode = unresolvedReasonCode is null
        ? null
        : LocalGameStateGuard.RequireCode(unresolvedReasonCode);
  }

  public LocalGameFactStatus Status { get; }

  public T? Value { get; }

  public string? UnresolvedReasonCode { get; }

  public static LocalGameFact<T> Ready(T value) => new(LocalGameFactStatus.Ready, value);

  public static LocalGameFact<T> Unresolved(string reasonCode) =>
      new(LocalGameFactStatus.Unresolved, unresolvedReasonCode: reasonCode);
}

public sealed record LobbyPresentationContent
{
  public LobbyPresentationContent(
      string displayName,
      LocalGameFact<int> commanderLevel,
      LocalGameFact<EntityUid> lobbyCharacter,
      LocalGameFact<EntityUid> profileIcon,
      LocalGameFact<EntityUid> profileFrame,
      LocalGameFact<EntityUid> lobbyBackground,
      LocalGameRevisionOrigin origin)
  {
    DisplayName = LocalGameStateGuard.NormalizeDisplayName(displayName);
    CommanderLevel = commanderLevel ?? throw new ArgumentNullException(nameof(commanderLevel));
    LobbyCharacter = lobbyCharacter ?? throw new ArgumentNullException(nameof(lobbyCharacter));
    ProfileIcon = profileIcon ?? throw new ArgumentNullException(nameof(profileIcon));
    ProfileFrame = profileFrame ?? throw new ArgumentNullException(nameof(profileFrame));
    LobbyBackground = lobbyBackground ?? throw new ArgumentNullException(nameof(lobbyBackground));
    if (!Enum.IsDefined(origin) || commanderLevel.Value is < 1 or > 1_000_000)
    {
      throw new LocalGameStateIntegrityException("local_game_lobby_value_invalid");
    }

    Origin = origin;
    ContentSha256 = LocalGameStateCanonicalizer.ComputeLobbySha256(this);
  }

  public string DisplayName { get; }

  public LocalGameFact<int> CommanderLevel { get; }

  public LocalGameFact<EntityUid> LobbyCharacter { get; }

  public LocalGameFact<EntityUid> ProfileIcon { get; }

  public LocalGameFact<EntityUid> ProfileFrame { get; }

  public LocalGameFact<EntityUid> LobbyBackground { get; }

  public LocalGameRevisionOrigin Origin { get; }

  public Sha256Digest ContentSha256 { get; }
}

public sealed record WalletBalance
{
  public WalletBalance(WalletCurrency currency, long amount)
  {
    if (!Enum.IsDefined(currency) || amount < 0)
    {
      throw new LocalGameStateIntegrityException("local_game_wallet_balance_invalid");
    }

    Currency = currency;
    Amount = amount;
  }

  public WalletCurrency Currency { get; }

  public long Amount { get; }
}

public sealed record WalletContent
{
  public WalletContent(
      IEnumerable<WalletBalance> balances,
      LocalGameRevisionOrigin origin)
  {
    ArgumentNullException.ThrowIfNull(balances);
    var materialized = balances.ToArray();
    if (!Enum.IsDefined(origin) || materialized.Length != 2 ||
        materialized.Any(static item => item is null))
    {
      throw new LocalGameStateIntegrityException("local_game_wallet_set_invalid");
    }

    var normalized = materialized.OrderBy(static item => item.Currency).ToArray();
    if (
        !normalized.Select(static item => item.Currency)
            .SequenceEqual(Enum.GetValues<WalletCurrency>().Order()))
    {
      throw new LocalGameStateIntegrityException("local_game_wallet_set_invalid");
    }

    Balances = Array.AsReadOnly(normalized);
    Origin = origin;
    ContentSha256 = LocalGameStateCanonicalizer.ComputeWalletSha256(this);
  }

  public IReadOnlyList<WalletBalance> Balances { get; }

  public LocalGameRevisionOrigin Origin { get; }

  public Sha256Digest ContentSha256 { get; }

  public static WalletContent CreateDefault() => new(
      [new WalletBalance(WalletCurrency.Jewel, 0), new WalletBalance(WalletCurrency.Credit, 0)],
      LocalGameRevisionOrigin.SystemDefault);
}

public sealed record ClientFeatureEntry
{
  public ClientFeatureEntry(string routeCode, ClientFeatureCapability capability)
  {
    RouteCode = LocalGameStateGuard.RequireRouteCode(routeCode);
    if (!Enum.IsDefined(capability))
    {
      throw new LocalGameStateIntegrityException("local_game_feature_capability_invalid");
    }

    Capability = capability;
  }

  public string RouteCode { get; }

  public ClientFeatureCapability Capability { get; }
}

public sealed record ClientFeatureManifestContent
{
  public ClientFeatureManifestContent(
      string contractVersion,
      IEnumerable<ClientFeatureEntry> entries)
  {
    ContractVersion = LocalGameStateGuard.RequireFeatureManifestContract(contractVersion);
    ArgumentNullException.ThrowIfNull(entries);
    var materialized = entries.ToArray();
    if (materialized.Length == 0 || materialized.Any(static item => item is null))
    {
      throw new LocalGameStateIntegrityException("local_game_feature_set_invalid");
    }

    var normalized = materialized
        .OrderBy(static item => item.RouteCode, StringComparer.Ordinal)
        .ToArray();
    if (
        normalized.Select(static item => item.RouteCode).Distinct(StringComparer.Ordinal).Count() !=
            normalized.Length)
    {
      throw new LocalGameStateIntegrityException("local_game_feature_set_invalid");
    }

    Entries = Array.AsReadOnly(normalized);
    ContentSha256 = LocalGameStateCanonicalizer.ComputeFeatureManifestSha256(this);
  }

  public string ContractVersion { get; }

  public IReadOnlyList<ClientFeatureEntry> Entries { get; }

  public Sha256Digest ContentSha256 { get; }
}

public static class LocalGameStateCanonicalizer
{
  public static Sha256Digest ComputeLobbySha256(LobbyPresentationContent value)
  {
    ArgumentNullException.ThrowIfNull(value);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/lobby-presentation/v1");
    Append(hash, value.DisplayName);
    AppendFact(hash, value.CommanderLevel, static item => item.ToString(CultureInfo.InvariantCulture));
    AppendFact(hash, value.LobbyCharacter, static item => item.ToString());
    AppendFact(hash, value.ProfileIcon, static item => item.ToString());
    AppendFact(hash, value.ProfileFrame, static item => item.ToString());
    AppendFact(hash, value.LobbyBackground, static item => item.ToString());
    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static Sha256Digest ComputeWalletSha256(WalletContent value)
  {
    ArgumentNullException.ThrowIfNull(value);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/wallet/v1");
    foreach (var balance in value.Balances)
    {
      Append(hash, Code(balance.Currency));
      Append(hash, balance.Amount.ToString(CultureInfo.InvariantCulture));
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static Sha256Digest ComputeFeatureManifestSha256(ClientFeatureManifestContent value)
  {
    ArgumentNullException.ThrowIfNull(value);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/client-feature-manifest/v1");
    Append(hash, value.ContractVersion);
    foreach (var entry in value.Entries)
    {
      Append(hash, entry.RouteCode);
      Append(hash, Code(entry.Capability));
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static string Code(LocalGameFactStatus value) => value switch
  {
    LocalGameFactStatus.Ready => "ready",
    LocalGameFactStatus.Unresolved => "unresolved",
    _ => throw new LocalGameStateIntegrityException("local_game_fact_status_invalid")
  };

  public static string Code(LocalGameRevisionOrigin value) => value switch
  {
    LocalGameRevisionOrigin.SystemDefault => "system_default",
    LocalGameRevisionOrigin.UserEdit => "user_edit",
    LocalGameRevisionOrigin.OfflineSanitizedImport => "offline_sanitized_import",
    LocalGameRevisionOrigin.Rebase => "rebase",
    _ => throw new LocalGameStateIntegrityException("local_game_revision_origin_invalid")
  };

  public static string Code(WalletCurrency value) => value switch
  {
    WalletCurrency.Jewel => "jewel",
    WalletCurrency.Credit => "credit",
    _ => throw new LocalGameStateIntegrityException("local_game_currency_invalid")
  };

  public static string Code(ClientFeatureCapability value) => value switch
  {
    ClientFeatureCapability.Supported => "supported",
    ClientFeatureCapability.Hidden => "hidden",
    ClientFeatureCapability.VisibleNoOp => "visible_no_op",
    ClientFeatureCapability.NotSupported => "not_supported",
    _ => throw new LocalGameStateIntegrityException("local_game_feature_capability_invalid")
  };

  private static void AppendFact<T>(
      IncrementalHash hash,
      LocalGameFact<T> fact,
      Func<T, string> format)
      where T : struct
  {
    Append(hash, Code(fact.Status));
    Append(hash, fact.Value is { } value ? format(value) : string.Empty);
    Append(hash, fact.UnresolvedReasonCode ?? string.Empty);
  }

  private static void Append(IncrementalHash hash, string value)
  {
    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[4];
    System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }
}

internal static class LocalGameStateGuard
{
  internal static string RequireCode(string value)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 64 || value[0] is < 'a' or > 'z' ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new LocalGameStateIntegrityException("local_game_code_invalid");
    }

    return value;
  }

  internal static string RequireRouteCode(string value)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 96 || value[0] is < 'a' or > 'z' ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new LocalGameStateIntegrityException("local_game_route_code_invalid");
    }

    return value;
  }

  internal static string RequireFeatureManifestContract(string value)
  {
    const string prefix = "nll/client-feature-manifest/v";
    if (value is null || !value.StartsWith(prefix, StringComparison.Ordinal) ||
        value.Length == prefix.Length || value.Length > 64 ||
        value[prefix.Length] == '0' ||
        value.AsSpan(prefix.Length).IndexOfAnyExceptInRange('0', '9') >= 0)
    {
      throw new LocalGameStateIntegrityException("local_game_feature_contract_invalid");
    }

    return value;
  }

  internal static string NormalizeDisplayName(string value)
  {
    ArgumentNullException.ThrowIfNull(value);
    var normalized = value.Trim().Normalize(NormalizationForm.FormC);
    if (normalized.Contains('/') || normalized.Contains('\\') || normalized.Contains(':') ||
        normalized.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
    {
      throw new LocalGameStateIntegrityException("local_game_display_name_semantics_invalid");
    }

    var count = 0;
    var remaining = normalized.AsSpan();
    while (!remaining.IsEmpty)
    {
      var status = Rune.DecodeFromUtf16(remaining, out var rune, out var consumed);
      if (status != OperationStatus.Done)
      {
        throw new LocalGameStateIntegrityException("local_game_display_name_unicode_invalid");
      }

      var category = Rune.GetUnicodeCategory(rune);
      if (category is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.Surrogate)
      {
        throw new LocalGameStateIntegrityException("local_game_display_name_unicode_invalid");
      }

      count++;
      remaining = remaining[consumed..];
    }

    if (count is < 1 or > 32)
    {
      throw new LocalGameStateIntegrityException("local_game_display_name_length_invalid");
    }

    return normalized;
  }
}
