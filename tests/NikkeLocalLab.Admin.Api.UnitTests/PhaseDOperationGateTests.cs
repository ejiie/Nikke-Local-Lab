namespace NikkeLocalLab.Admin.Api.UnitTests;

public sealed class PhaseDOperationGateTests
{
  [Theory]
  [InlineData(true)]
  [InlineData(false)]
  public async Task DisconnectOrDeadlineDoesNotReleaseOwnership(bool disconnect)
  {
    var root = Directory.CreateTempSubdirectory("nll-lifecycle-gate-").FullName;
    try
    {
      var gate = new PhaseDOperationGate(root, disconnect ? TimeSpan.FromSeconds(5) : TimeSpan.FromMilliseconds(50));
      var anotherInstance = new PhaseDOperationGate(root, TimeSpan.FromSeconds(2));
      var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      var complete = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
      using var caller = new CancellationTokenSource();
      var request = gate.RunAsync(async () => { entered.SetResult(); return await complete.Task; }, caller.Token);
      await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
      try
      {
        if (disconnect)
        {
          caller.Cancel();
          await Assert.ThrowsAnyAsync<OperationCanceledException>(() => request);
        }
        else
        {
          var timeout = await Assert.ThrowsAsync<PhaseDExecutionException>(() => request);
          Assert.Equal("phase_d_operation_pending", timeout.Message);
        }
        var count = 0;
        var failure = await Assert.ThrowsAsync<PhaseDExecutionException>(() => anotherInstance.RunAsync(
            () => Task.FromResult(++count), CancellationToken.None));
        Assert.Equal("phase_d_operation_in_progress", failure.Message);
        Assert.Equal(0, count);
      }
      finally { complete.TrySetResult(true); }
      // Synchronize with the release, not with the canceled HTTP task.
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
      while (true)
      {
        try { Assert.True(await anotherInstance.RunAsync(() => Task.FromResult(true), deadline.Token)); break; }
        catch (PhaseDExecutionException exception) when (exception.Message == "phase_d_operation_in_progress")
        { await Task.Delay(10, deadline.Token); }
      }
    }
    finally { Directory.Delete(root, recursive: true); }
  }

  [Fact]
  public async Task CancellationBeforeAdmissionDoesNotInvokeOperation()
  {
    var root = Directory.CreateTempSubdirectory("nll-lifecycle-gate-").FullName;
    try
    {
      var gate = new PhaseDOperationGate(root, TimeSpan.FromSeconds(1));
      await Assert.ThrowsAnyAsync<OperationCanceledException>(() => gate.RunAsync<bool>(
          () => throw new InvalidOperationException("must_not_run"), new CancellationToken(true)));
    }
    finally { Directory.Delete(root, recursive: true); }
  }
}
