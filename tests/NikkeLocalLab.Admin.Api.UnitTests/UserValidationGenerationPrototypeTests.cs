using NikkeLocalLab.Phase3B2.UserValidation;

namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class UserValidationGenerationPrototypeTests
{
  private static UserValidationGenerationWitness Witness() => new(123, 456, 4096, 100, 99, 50, 200, 1,
      Guid.Parse("10000000-0000-0000-0000-000000000001"));
  [Fact]
  public void UnrelatedJournalActivityDoesNotInvalidateAnUnchangedFile()
  {
    var before = Witness();
    Assert.True(UserValidationGenerationPrototype.Reusable(before, before));
    Assert.True(UserValidationGenerationPrototype.Reusable(before, before with { NextUsn = 300, FirstUsn = 150 }));
  }
  [Fact]
  public void IdentityContentJournalGapRollbackAndBootChangeInvalidate()
  {
    var before = Witness();
    foreach (var changed in new[] { before with { Volume = 124 }, before with { FileId = 457 },
        before with { Length = 4097 }, before with { FileUsn = 101 }, before with { JournalId = 100 },
        before with { FirstUsn = 201 }, before with { LowestValidUsn = 201 }, before with { NextUsn = 199 },
        before with { BootId = Guid.NewGuid() }, before with { FirstUsn = -1 }, before with { LowestValidUsn = -1 } })
      Assert.False(UserValidationGenerationPrototype.Reusable(before, changed));
    Assert.False(UserValidationGenerationPrototype.Reusable(before with { BootId = Guid.Empty }, before));
  }
}
