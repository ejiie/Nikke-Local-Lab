using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class AccountWorkspaceContractTests
{
  [Fact]
  public void AccountLabelsAreNormalizedAndPathLikeValuesAreRejected()
  {
    Assert.Equal("계정_1", ProfileManagementText.NormalizeAccountLabel("  계정_1  "));
    Assert.Throws<ProfileManagementException>(() =>
        ProfileManagementText.NormalizeAccountLabel("account/one"));
    Assert.Throws<ProfileManagementException>(() =>
        ProfileManagementText.NormalizeAccountLabel(new string('a', 65)));
  }

  [Fact]
  public void RuntimeCandidateHashIsStableAcrossInputOrderingAndBindsValues()
  {
    var accountUid = Uid("10000000-0000-4000-8000-000000000001");
    var profileUid = Uid("10000000-0000-4000-8000-000000000002");
    var stateUid = Uid("10000000-0000-4000-8000-000000000003");
    var subjectUid = Uid("10000000-0000-4000-8000-000000000004");
    var revisions = new AccountWorkspaceBaseRevisions(
        profileUid,
        stateUid,
        null,
        AccountWorkspaceCanonicalizer.ComputeRevisionSet(profileUid, stateUid, null));
    ProfileValueProjection[] values =
    [
      new("synchro_level", null, "ready", IntegerValue: 400),
      new("character_level", subjectUid, "ready", IntegerValue: 400)
    ];

    var first = AccountWorkspaceCanonicalizer.ComputeRuntimeCandidate(
        accountUid, "계정_1", revisions, "ready", [], values);
    var reordered = AccountWorkspaceCanonicalizer.ComputeRuntimeCandidate(
        accountUid, "계정_1", revisions, "ready", [], values.Reverse().ToArray());
    var changed = AccountWorkspaceCanonicalizer.ComputeRuntimeCandidate(
        accountUid,
        "계정_1",
        revisions,
        "ready",
        [],
        [values[0], values[1] with { IntegerValue = 399 }]);

    Assert.Equal(first, reordered);
    Assert.NotEqual(first, changed);
    Assert.NotEqual(default(Sha256Digest), first);
  }

  [Fact]
  public void AggregateSaveHashBindsEveryHeadAndIgnoresBalanceOrdering()
  {
    var command = new SaveAccountWorkspaceCommand(
        Uid("20000000-0000-4000-8000-000000000001"),
        false,
        Uid("20000000-0000-4000-8000-000000000002"),
        Sha256Digest.ComputeUtf8("workspace"),
        Uid("20000000-0000-4000-8000-000000000003"),
        Uid("20000000-0000-4000-8000-000000000004"),
        Uid("20000000-0000-4000-8000-000000000005"),
        Uid("20000000-0000-4000-8000-000000000006"),
        Sha256Digest.ComputeUtf8("candidate"),
        Sha256Digest.ComputeUtf8("diff"),
        "원본",
        "저장본",
        "지휘관",
        896,
        null,
        null,
        null,
        null,
        [new("jewel", 1_000), new("credit", 2_000)]);

    var reordered = command with { Balances = command.Balances.Reverse().ToArray() };
    var changedWalletHead = command with
    {
      ExpectedWalletRevisionUid = Uid("20000000-0000-4000-8000-000000000007")
    };

    Assert.Equal(command.RequestSha256, reordered.RequestSha256);
    Assert.NotEqual(command.RequestSha256, changedWalletHead.RequestSha256);
  }

  private static EntityUid Uid(string value) => new(Guid.ParseExact(value, "D"));
}
