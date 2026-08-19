namespace NikkeLocalLab.Profile.UnitTests;

public sealed class LocalAccountAndStateTests
{
  [Fact]
  public void Local_session_has_no_secret_and_terminal_states_cannot_transition_again()
  {
    var account = ProfileTestData.Account();
    var issued = ProfileTestData.Timestamp;
    var session = LocalSession.Issue(
        ProfileTestData.Uid(2),
        account,
        issued,
        issued.AddHours(1));

    Assert.Equal(LocalSessionStatus.Active, session.Status);
    Assert.Equal(session.CanonicalSha256, LocalSessionCanonicalizer.ComputeHash(session));
    var revoked = session.Revoke(issued.AddMinutes(5));
    Assert.Equal(LocalSessionStatus.Revoked, revoked.Status);
    Assert.Throws<InvalidOperationException>(() => revoked.Expire(issued.AddHours(1)));
    Assert.Throws<InvalidOperationException>(() => revoked.Revoke(issued.AddMinutes(6)));
    Assert.DoesNotContain("token", LocalSessionCanonicalizer.ToCanonicalText(session), StringComparison.OrdinalIgnoreCase);
  }

  [Fact]
  public void Console_exp_can_be_unresolved_without_blocking_combat_readiness()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var revision = ProfileTestData.AccountState(
        ProfileTestData.Account(),
        catalog,
        experience: ProfileFact<long>.Unresolved("console_progress_not_retained"));

    Assert.Equal(ProfileReadiness.Ready, revision.Readiness);
    Assert.Equal(ProfileReadiness.Unresolved, revision.FullFidelityReadiness);
    Assert.Equal(9, revision.Content.Consoles.Count);
    Assert.All(revision.Content.Consoles, console =>
        Assert.Equal(ProfileFactStatus.Unresolved, console.Experience.Status));
  }

  [Fact]
  public void Account_state_requires_the_exact_nine_console_coordinate_grid()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var account = ProfileTestData.Account();
    var state = new AccountCombatState(ProfileTestData.Uid(50), account);
    var evidence = ProfileTestData.Evidence(
        new[] { ProfileTestData.CharacterVersion() },
        catalog.All);
    var missing = catalog.Consoles.Take(8).Select(definition =>
        new ConsoleProgressInput(
            definition,
            ProfileFact<int>.Ready(1),
            ProfileFact<long>.Ready(0)));

    Assert.Throws<ArgumentException>(() => AccountCombatStateRevision.Create(
        ProfileTestData.Uid(51),
        state,
        1,
        ProfileTestData.Provenance(),
        evidence,
        ProfileValidationMode.Research,
        ProfileFact<int>.Ready(50),
        missing));
  }

  [Fact]
  public void Game_legal_console_level_checks_its_minimum_synchro_but_level_zero_has_no_gate()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var lowSynchro = ProfileTestData.AccountState(
        ProfileTestData.Account(),
        catalog,
        ProfileValidationMode.GameLegal,
        synchroLevel: 20,
        consoleLevel: 3);
    var research = ProfileTestData.AccountState(
        ProfileTestData.Account(),
        catalog,
        ProfileValidationMode.Research,
        synchroLevel: 20,
        consoleLevel: 3);
    var zero = ProfileTestData.AccountState(
        ProfileTestData.Account(),
        catalog,
        ProfileValidationMode.GameLegal,
        synchroLevel: 1,
        consoleLevel: 0);

    Assert.Equal(ProfileReadiness.Invalid, lowSynchro.Readiness);
    Assert.Contains(
        lowSynchro.Validation.Combat.Issues,
        issue => issue.ReasonCode == "synchro_below_console_requirement");
    Assert.Equal(ProfileReadiness.Ready, research.Readiness);
    Assert.Equal(ProfileReadiness.Ready, zero.Readiness);
  }

  [Fact]
  public void Catalog_evidence_rejects_a_binding_whose_manifest_digest_does_not_match()
  {
    var catalog = ProfileTestData.SupportCatalog();
    var character = ProfileTestData.CharacterVersion();
    var exact = ProfileTestData.Evidence(new[] { character }, catalog.All);
    var changedBinding = new ProfileDatasetBinding(
        exact.DatasetBinding.CharacterCatalog,
        new ProfileCatalogBinding(
            ProfileTestData.Uid(9_999),
            ProfileTestData.Uid(200),
            Sha256Digest.ComputeUtf8("changed-support-manifest")));

    Assert.Throws<ArgumentException>(() => ProfileCatalogEvidence.RestoreTrustedCatalogSnapshot(
        changedBinding,
        exact.CharacterManifest,
        new[] { character },
        exact.CombatSupportManifest,
        catalog.All));
  }
}
