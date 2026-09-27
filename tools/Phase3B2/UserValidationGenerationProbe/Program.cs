using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using NikkeLocalLab.Phase3B2.UserValidation;

// No arbitrary file inputs. Only NEW, clearly synthetic files under a new root.
if (args.Length != 2 || args[0] is not ("--once" or "--warm20")) return 64;
var root = Path.GetFullPath(args[1]);
if (Directory.Exists(root) || File.Exists(root)) return 64;
Directory.CreateDirectory(root);
var path = Path.Combine(root, "synthetic.bin");
var rows = new List<object>(); var valid = new List<double>(); var invalid = new List<double>();
var rejectedReplacement = false; var rejectedHardlink = false;
var count = args[0] == "--once" ? 1 : 20;
try
{
  for (var i = 0; i < count; i++)
  {
    File.WriteAllBytes(path, Enumerable.Range(0, 4096).Select(n => (byte)n).ToArray());
    var prepared = UserValidationGenerationPrototype.Prepare(path);
    var watch = Stopwatch.StartNew();
    UserValidationGenerationPrototype.Verify(path, prepared); valid.Add(watch.Elapsed.TotalMilliseconds);
    var timestamp = File.GetLastWriteTimeUtc(path);
    using (var writer = File.OpenWrite(path)) { writer.WriteByte(255); writer.Flush(true); }
    File.SetLastWriteTimeUtc(path, timestamp);
    watch.Restart(); var rejected = false;
    try { UserValidationGenerationPrototype.Verify(path, prepared); }
    catch (InvalidOperationException) { rejected = true; }
    invalid.Add(watch.Elapsed.TotalMilliseconds);
    if (!rejected) throw new InvalidOperationException("synthetic_changed_file_accepted");
    rows.Add(new { iteration = i, validMilliseconds = valid[^1], invalidMilliseconds = invalid[^1], contentReadBytesDuringVerify = 0 });
  }
  var original = UserValidationGenerationPrototype.Prepare(path);
  var backup = path + ".original"; File.Move(path, backup); File.Copy(backup, path);
  try { UserValidationGenerationPrototype.Verify(path, original); }
  catch (InvalidOperationException) { rejectedReplacement = true; }
  var replacement = UserValidationGenerationPrototype.Prepare(path);
  if (!Native.CreateHardLink(path + ".hardlink", path, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  try { UserValidationGenerationPrototype.Verify(path, replacement); }
  catch (InvalidOperationException) { rejectedHardlink = true; }
  if (!rejectedReplacement || !rejectedHardlink) throw new InvalidOperationException("synthetic_identity_change_accepted");
  static object Stats(List<double> samples)
  {
    var sorted = samples.Order().ToArray();
    return new
    {
      count = sorted.Length,
      p50Milliseconds = sorted[(int)Math.Ceiling(sorted.Length * .5) - 1],
      p95Milliseconds = sorted[(int)Math.Ceiling(sorted.Length * .95) - 1],
      maxMilliseconds = sorted[^1]
    };
  }
  var receipt = new
  {
    contractId = "nll/user-validation-generation-prototype-benchmark/v1",
    statusCode = "synthetic_file_checks_passed",
    processMode = args[0] == "--once" ? "cold_process_sample" : "warm_process_samples",
    syntheticFileBytes = 4096,
    valid = Stats(valid),
    invalid = Stats(invalid),
    rows,
    equalSizeTimestampResetRejected = true,
    fileReplacementRejected = rejectedReplacement,
    hardlinkRejected = rejectedHardlink,
    productionPipelineMeasured = false,
    crossProcessLeaseHandoffVerified = false,
    fastAdmissionEnabled = false,
    gameStarted = false,
    actualGameAcceptanceClaimed = false
  };
  File.WriteAllBytes(Path.Combine(root, "receipt.json"), JsonSerializer.SerializeToUtf8Bytes(receipt));
  return 0;
}
catch (Exception error)
{
  File.WriteAllBytes(Path.Combine(root, "failure.json"), JsonSerializer.SerializeToUtf8Bytes(new
  {
    statusCode = "synthetic_probe_failed",
    exceptionType = error.GetType().FullName,
    nativeErrorCode = (error as System.ComponentModel.Win32Exception)?.NativeErrorCode,
    hResult = error.HResult,
    fastAdmissionEnabled = false,
    gameStarted = false
  }));
  return 1;
}
internal static class Native
{
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  internal static extern bool CreateHardLink(string name, string existing, IntPtr security);
}
