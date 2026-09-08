using System.Text;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class WorkspaceSaveRequestCodecTests
{
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void DurableEnvelopeRoundTripsEveryFieldAndExactLongBalances(bool saveAs)
  {
    var command = SyntheticRequest() with { SaveAs = saveAs };
    var bytes = WorkspaceSaveRequestCodec.Encode(command);
    var decoded = WorkspaceSaveRequestCodec.Decode(bytes);
    Assert.Equal(command.RequestSha256, decoded.RequestSha256);
    Assert.Equal(command.OperationUid, decoded.OperationUid);
    Assert.Equal(command with { Balances = decoded.Balances }, decoded);
    Assert.Equal(bytes, WorkspaceSaveRequestCodec.Encode(decoded));
    Assert.Equal(bytes, WorkspaceSaveRequestCodec.Encode(command with { Balances = command.Balances.Reverse().ToArray() }));
    Assert.Equal(long.MaxValue, decoded.Balances.Single(item => item.CurrencyCode == "credit").Balance);
  }

  [Theory]
  [InlineData("duplicate")]
  [InlineData("unknown")]
  [InlineData("missing")]
  [InlineData("null")]
  [InlineData("version")]
  [InlineData("noncanonical")]
  [InlineData("zero_uid")]
  [InlineData("balance")]
  [InlineData("oversized")]
  public void DurableEnvelopeRejectsNoncanonicalOrInvalidInput(string variant)
  {
    var text = Encoding.UTF8.GetString(WorkspaceSaveRequestCodec.Encode(SyntheticRequest()));
    text = variant switch
    {
      "duplicate" => text.Replace("\"saveAs\":false", "\"saveAs\":false,\"saveAs\":false", StringComparison.Ordinal),
      "unknown" => text.Insert(1, "\"token\":\"synthetic-canary\","),
      "missing" => text.Replace("\"profileFrameSelectionUid\":null,", "", StringComparison.Ordinal),
      "null" => text.Replace("\"balances\":[", "\"balances\":null,\"ignored\":[", StringComparison.Ordinal),
      "version" => text.Replace("envelope/v1", "envelope/v2", StringComparison.Ordinal),
      "zero_uid" => text.Replace(SyntheticRequest().OperationUid.ToString(), Guid.Empty.ToString("D"), StringComparison.Ordinal),
      "balance" => text.Replace(long.MaxValue.ToString(System.Globalization.CultureInfo.InvariantCulture), "-1", StringComparison.Ordinal),
      "oversized" => new string(' ', WorkspaceSaveRequestCodec.MaximumBytes + 1),
      _ => " " + text
    };
    var failure = Assert.Throws<ProfileManagementException>(() => WorkspaceSaveRequestCodec.Decode(Encoding.UTF8.GetBytes(text)));
    Assert.Equal("account_workspace_save_request_invalid", failure.Code);
    Assert.DoesNotContain("synthetic-canary", failure.Message, StringComparison.Ordinal);
  }

  private static SaveAccountWorkspaceCommand SyntheticRequest() => new(
      Uid(1), false, Uid(2), Hash("workspace"), Uid(3), Uid(4), Uid(5), Uid(6), Hash("candidate"), Hash("diff"),
      "원본", "저장본", "지휘관", 896, Uid(7), null, Uid(8), Uid(9), [new("credit", long.MaxValue), new("jewel", 200)]);
  private static EntityUid Uid(int index) => new(Guid.Parse($"10000000-0000-4000-8000-{index:D12}"));
  private static Sha256Digest Hash(string text) => Sha256Digest.ComputeUtf8(text);
}
