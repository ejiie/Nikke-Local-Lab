namespace NikkeLocalLab.Admin.Api.UnitTests;

// These tests start bounded Windows PowerShell children. Concurrent cold shell
// startup on hosted runners can consume the entire fixture deadline before the
// synthetic command runs. Serialize this collection against the other tests;
// keep production deadlines and the explicit timeout/cancellation checks intact.
[CollectionDefinition(Name, DisableParallelization = true)]
public sealed class WindowsProcessCollection
{
  public const string Name = "Windows process lifecycle";
}
