using System.Text;
using NikkeLocalLab.Application.ProfileManagement;
using NikkeLocalLab.Identity;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class ProfileManagementContractTests
{
  [Fact]
  public void ProfileEditRequiresOneTypedScalar()
  {
    var valid = new ProfileEditOperation(
        "character_level",
        new EntityUid(Guid.NewGuid()),
        "integer",
        IntegerValue: 400);
    valid.Validate();

    var invalid = valid with { BooleanValue = true };
    var exception = Assert.Throws<ProfileManagementException>(invalid.Validate);
    Assert.Equal("profile_edit_value_invalid", exception.Code);
  }

  [Fact]
  public void ProfileEditAcceptsControlledNotApplicableApplicabilityValue()
  {
    var operation = new ProfileEditOperation(
        "bond_level",
        new EntityUid(Guid.NewGuid()),
        "controlled",
        ControlledValue: "not_applicable");

    operation.Validate();
  }

  [Fact]
  public void ProfileEditRejectsUncontrolledFieldCodes()
  {
    var operation = new ProfileEditOperation(
        "raw/path",
        null,
        "integer",
        IntegerValue: 1);

    Assert.Throws<ArgumentException>(operation.Validate);
  }

  [Fact]
  public void LobbyNameUsesNfcAndUnicodeScalarLength()
  {
    var uid = new EntityUid(Guid.NewGuid());
    var valid = new SaveLobbyPresentationCommand(
        uid,
        new EntityUid(Guid.NewGuid()),
        new EntityUid(Guid.NewGuid()),
        $"  {string.Concat(Enumerable.Repeat("😀", 32))}  ",
        1,
        null,
        null,
        null,
        null);
    Assert.Equal(32, valid.DisplayName.EnumerateRunes().Count());

    var exception = Assert.Throws<ProfileManagementException>(() =>
        new SaveLobbyPresentationCommand(
            uid,
            new EntityUid(Guid.NewGuid()),
            new EntityUid(Guid.NewGuid()),
            string.Concat(Enumerable.Repeat("😀", 33)),
            1,
            null,
            null,
            null,
            null));
    Assert.Equal("lobby_presentation_value_invalid", exception.Code);
  }
}
