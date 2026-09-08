using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Application.ProfileManagement;

public sealed record AccountWorkspaceBaseRevisions(
    EntityUid ProfileRevisionUid,
    EntityUid AccountStateRevisionUid,
    EntityUid? ProgressionRevisionUid,
    Sha256Digest RevisionSetSha256);

public sealed record AccountSummaryProjection(
    EntityUid WorkspaceUid,
    EntityUid AccountUid,
    string AccountLabel,
    RevisionReference ProfileRevision,
    EntityUid AccountStateRevisionUid,
    DateTimeOffset AccountCreatedAtUtc,
    DateTimeOffset ProfileMaterializedAtUtc,
    EntityUid? FetchedSnapshotUid,
    DateTimeOffset? LastFetchedAtUtc,
    string? LastExecutionResultCode,
    string ValidationStatusCode,
    IReadOnlyList<string> ValidationReasonCodes,
    EntityUid? SaveAsParentAccountUid);

public sealed record AccountWorkspaceProjection(
    int SchemaVersion,
    string ContractId,
    EntityUid WorkspaceUid,
    EntityUid AccountUid,
    string AccountLabel,
    AccountWorkspaceBaseRevisions BaseRevisions,
    EntityUid? FetchedSnapshotUid,
    Sha256Digest PendingEditSetSha256,
    int PendingEditCount,
    string ValidationStatusCode,
    IReadOnlyList<string> ValidationReasonCodes,
    EntityUid? SaveAsParentAccountUid);

public sealed record AccountRevisionProjection(
    RevisionReference ProfileRevision,
    EntityUid AccountStateRevisionUid,
    EntityUid? PreviousProfileRevisionUid,
    string OriginCode,
    DateTimeOffset MaterializedAtUtc);

public sealed record AccountRevisionHistoryProjection(
    EntityUid AccountUid,
    string AccountLabel,
    IReadOnlyList<AccountRevisionProjection> Revisions);

public sealed record RenameAccountCommand(
    EntityUid AccountUid,
    string ExpectedAccountLabel,
    string AccountLabel);

public sealed record SaveAccountWorkspaceCommand(
    EntityUid OperationUid,
    bool SaveAs,
    EntityUid SourceAccountUid,
    Sha256Digest ExpectedWorkspaceRevisionSetSha256,
    EntityUid ExpectedProfileRevisionUid,
    EntityUid ExpectedLobbyRevisionUid,
    EntityUid ExpectedWalletRevisionUid,
    EntityUid CandidateDraftUid,
    Sha256Digest CandidateSha256,
    Sha256Digest ExpectedDiffSha256,
    string ExpectedAccountLabel,
    string AccountLabel,
    string DisplayName,
    int CommanderLevel,
    EntityUid? ProfileIconSelectionUid,
    EntityUid? ProfileFrameSelectionUid,
    EntityUid? LobbyCharacterSelectionUid,
    EntityUid? LobbyBackgroundSelectionUid,
    IReadOnlyList<WalletBalanceProjection> Balances)
{
  public Sha256Digest RequestSha256 =>
      AccountWorkspaceCanonicalizer.ComputeSaveRequest(this);
}

public sealed record SaveAccountWorkspaceReceipt(
    EntityUid OperationUid,
    bool IsIdempotentReplay,
    bool SaveAs,
    EntityUid SourceAccountUid,
    EntityUid AccountUid,
    string AccountLabel,
    RevisionReference ProfileRevision,
    RevisionReference LobbyRevision,
    RevisionReference WalletRevision,
    Sha256Digest RevisionSetSha256,
    EntityUid? ObservationSourceSnapshotUid);

public sealed record RuntimeProjectionCandidate(
    int SchemaVersion,
    string ContractId,
    Sha256Digest CandidateSha256,
    EntityUid AccountUid,
    string AccountLabel,
    AccountWorkspaceBaseRevisions BaseRevisions,
    string ValidationStatusCode,
    IReadOnlyList<string> ValidationReasonCodes,
    IReadOnlyList<ProfileValueProjection> Values);

// An in-process launch input, not a new wire format. Both components are captured
// from one completed database view; callers must not refresh either independently.
public sealed record RuntimeProjectionSnapshot(
    RuntimeProjectionCandidate Candidate,
    LobbyPresentationProjection? Lobby);

public static class AccountWorkspaceCanonicalizer
{
  private static readonly Sha256Digest EmptyEditSet =
      Sha256Digest.ComputeUtf8("nll/account-workspace-empty-edit-set/v1");

  public static Sha256Digest EmptyPendingEditSetSha256 => EmptyEditSet;

  public static Sha256Digest ComputeRevisionSet(
      EntityUid profileRevisionUid,
      EntityUid accountStateRevisionUid,
      EntityUid? progressionRevisionUid)
  {
    var text = string.Join(
        "\n",
        "nll/account-workspace-revision-set/v1",
        profileRevisionUid.ToString(),
        accountStateRevisionUid.ToString(),
        progressionRevisionUid?.ToString() ?? "null");
    return Sha256Digest.ComputeUtf8(text);
  }

  public static Sha256Digest ComputeRuntimeCandidate(
      EntityUid accountUid,
      string accountLabel,
      AccountWorkspaceBaseRevisions revisions,
      string validationStatusCode,
      IReadOnlyList<string> validationReasonCodes,
      IReadOnlyList<ProfileValueProjection> values)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/runtime-projection-candidate/v1");
    Append(hash, accountUid.ToString());
    Append(hash, accountLabel);
    Append(hash, revisions.ProfileRevisionUid.ToString());
    Append(hash, revisions.AccountStateRevisionUid.ToString());
    Append(hash, revisions.ProgressionRevisionUid?.ToString() ?? "null");
    Append(hash, revisions.RevisionSetSha256.ToString());
    Append(hash, validationStatusCode);
    foreach (var reason in validationReasonCodes.Order(StringComparer.Ordinal))
    {
      Append(hash, reason);
    }

    foreach (var value in values
        .OrderBy(static item => item.FieldCode, StringComparer.Ordinal)
        .ThenBy(static item => item.SubjectUid?.ToString(), StringComparer.Ordinal))
    {
      Append(hash, value.FieldCode);
      Append(hash, value.SubjectUid?.ToString() ?? "null");
      Append(hash, value.Status);
      Append(hash, value.IntegerValue?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "null");
      Append(hash, value.BooleanValue?.ToString() ?? "null");
      Append(hash, value.ReferenceUid?.ToString() ?? "null");
      Append(hash, value.UnscaledValue?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "null");
      Append(hash, value.DecimalScale?.ToString(System.Globalization.CultureInfo.InvariantCulture) ?? "null");
      Append(hash, value.ControlledValue ?? "null");
      Append(hash, value.ReasonCode ?? "null");
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static Sha256Digest ComputeSaveRequest(SaveAccountWorkspaceCommand command)
  {
    ArgumentNullException.ThrowIfNull(command);
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/account-workspace-save-request/v1");
    Append(hash, command.SaveAs ? "save_as" : "save");
    Append(hash, command.SourceAccountUid.ToString());
    Append(hash, command.ExpectedWorkspaceRevisionSetSha256.ToString());
    Append(hash, command.ExpectedProfileRevisionUid.ToString());
    Append(hash, command.ExpectedLobbyRevisionUid.ToString());
    Append(hash, command.ExpectedWalletRevisionUid.ToString());
    Append(hash, command.CandidateDraftUid.ToString());
    Append(hash, command.CandidateSha256.ToString());
    Append(hash, command.ExpectedDiffSha256.ToString());
    Append(hash, command.ExpectedAccountLabel);
    Append(hash, command.AccountLabel);
    Append(hash, command.DisplayName);
    Append(hash, command.CommanderLevel.ToString(System.Globalization.CultureInfo.InvariantCulture));
    Append(hash, command.ProfileIconSelectionUid?.ToString() ?? "null");
    Append(hash, command.ProfileFrameSelectionUid?.ToString() ?? "null");
    Append(hash, command.LobbyCharacterSelectionUid?.ToString() ?? "null");
    Append(hash, command.LobbyBackgroundSelectionUid?.ToString() ?? "null");
    foreach (var balance in command.Balances.OrderBy(
        static item => item.CurrencyCode,
        StringComparer.Ordinal))
    {
      Append(hash, balance.CurrencyCode);
      Append(hash, balance.Balance.ToString(System.Globalization.CultureInfo.InvariantCulture));
    }

    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  public static Sha256Digest ComputeSaveRevisionSet(
      EntityUid accountUid,
      string accountLabel,
      RevisionReference profileRevision,
      RevisionReference lobbyRevision,
      RevisionReference walletRevision)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, "nll/account-workspace-save-revision-set/v1");
    Append(hash, accountUid.ToString());
    Append(hash, accountLabel);
    AppendRevision(hash, profileRevision);
    AppendRevision(hash, lobbyRevision);
    AppendRevision(hash, walletRevision);
    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  private static void AppendRevision(IncrementalHash hash, RevisionReference revision)
  {
    Append(hash, revision.RevisionUid.ToString());
    Append(hash, revision.ContentSha256.ToString());
    Append(hash, revision.RevisionNumber.ToString(System.Globalization.CultureInfo.InvariantCulture));
  }

  private static void Append(IncrementalHash hash, string value)
  {
    hash.AppendData(Encoding.UTF8.GetBytes(value));
    hash.AppendData([0]);
  }
}
