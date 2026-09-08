using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.ProfileManagement;

public sealed record WorkspaceSaveRecoveryProjection(
    EntityUid OperationUid, EntityUid SourceAccountUid, bool SaveAs,
    string StatusCode, Sha256Digest RequestSha256, DateTimeOffset CreatedAtUtc,
    string RecoveryCode, SaveAccountWorkspaceReceipt? CompletedReceipt);

public sealed record ResumeWorkspaceSaveCommand(
    EntityUid SourceAccountUid, EntityUid OperationUid, Sha256Digest ExpectedRequestSha256);

// Private persistence format, not a browser credential or an original-account dump.
// Keep the existing save-request hash independent of this versioned byte envelope.
public static class WorkspaceSaveRequestCodec
{
  public const string ContractId = "nll/account-workspace-save-envelope/v1";
  public const int MaximumBytes = 16_384;
  private static readonly JsonSerializerOptions Options = new()
  {
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    MaxDepth = 8
  };

  public static byte[] Encode(SaveAccountWorkspaceCommand command)
  {
    ArgumentNullException.ThrowIfNull(command);
    var payload = new Payload(ContractId, command.OperationUid.ToString(), command.SaveAs,
        command.SourceAccountUid.ToString(), command.ExpectedWorkspaceRevisionSetSha256.ToString(),
        command.ExpectedProfileRevisionUid.ToString(), command.ExpectedLobbyRevisionUid.ToString(),
        command.ExpectedWalletRevisionUid.ToString(), command.CandidateDraftUid.ToString(),
        command.CandidateSha256.ToString(), command.ExpectedDiffSha256.ToString(),
        command.ExpectedAccountLabel, command.AccountLabel, command.DisplayName, command.CommanderLevel,
        command.ProfileIconSelectionUid?.ToString(), command.ProfileFrameSelectionUid?.ToString(),
        command.LobbyCharacterSelectionUid?.ToString(), command.LobbyBackgroundSelectionUid?.ToString(),
        command.Balances.OrderBy(static item => item.CurrencyCode, StringComparer.Ordinal).ToArray());
    var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, Options);
    if (bytes.Length > MaximumBytes) throw Invalid();
    return bytes;
  }

  public static SaveAccountWorkspaceCommand Decode(ReadOnlySpan<byte> bytes)
  {
    try
    {
      if (bytes.Length is 0 or > MaximumBytes) throw Invalid();
      var payload = JsonSerializer.Deserialize<Payload>(bytes, Options) ?? throw Invalid();
      if (payload.ContractId != ContractId || payload.Balances is null) throw Invalid();
      var command = new SaveAccountWorkspaceCommand(Uid(payload.OperationUid), payload.SaveAs,
          Uid(payload.SourceAccountUid), Digest(payload.ExpectedWorkspaceRevisionSetSha256),
          Uid(payload.ExpectedProfileRevisionUid), Uid(payload.ExpectedLobbyRevisionUid),
          Uid(payload.ExpectedWalletRevisionUid), Uid(payload.CandidateDraftUid), Digest(payload.CandidateSha256),
          Digest(payload.ExpectedDiffSha256), ProfileManagementText.NormalizeAccountLabel(payload.ExpectedAccountLabel),
          ProfileManagementText.NormalizeAccountLabel(payload.AccountLabel),
          ProfileManagementText.NormalizeDisplayName(payload.DisplayName), payload.CommanderLevel,
          OptionalUid(payload.ProfileIconSelectionUid), OptionalUid(payload.ProfileFrameSelectionUid),
          OptionalUid(payload.LobbyCharacterSelectionUid), OptionalUid(payload.LobbyBackgroundSelectionUid), payload.Balances);
      if (command.CommanderLevel < 1 || command.Balances.Count != 2 ||
          !command.Balances.Select(static item => item.CurrencyCode).SequenceEqual(["credit", "jewel"]) ||
          command.Balances.Any(static item => item.Balance < 0) || !bytes.SequenceEqual(Encode(command)))
        throw Invalid();
      // Re-encoding enforces the exact property set/order, nulls, NFC, integers,
      // unique properties and canonical UUID/digest representation (also on read).
      return command;
    }
    catch (Exception error) when (error is JsonException or ArgumentException or FormatException or
        InvalidOperationException or ProfileManagementException or NullReferenceException)
    {
      throw Invalid();
    }
  }

  private static EntityUid Uid(string text) => Guid.TryParseExact(text, "D", out var uid) && uid != Guid.Empty
      ? new EntityUid(uid) : throw Invalid();
  private static EntityUid? OptionalUid(string? text) => text is null ? null : Uid(text);
  private static Sha256Digest Digest(string text) => Sha256Digest.Parse(text);
  private static ProfileManagementException Invalid() => new(
      ProfileManagementFailureKind.Conflict, "account_workspace_save_request_invalid");

  private sealed record Payload(
      string ContractId, string OperationUid, bool SaveAs, string SourceAccountUid,
      string ExpectedWorkspaceRevisionSetSha256, string ExpectedProfileRevisionUid,
      string ExpectedLobbyRevisionUid, string ExpectedWalletRevisionUid, string CandidateDraftUid,
      string CandidateSha256, string ExpectedDiffSha256, string ExpectedAccountLabel, string AccountLabel,
      string DisplayName, int CommanderLevel, string? ProfileIconSelectionUid, string? ProfileFrameSelectionUid,
      string? LobbyCharacterSelectionUid, string? LobbyBackgroundSelectionUid, IReadOnlyList<WalletBalanceProjection> Balances);
}
