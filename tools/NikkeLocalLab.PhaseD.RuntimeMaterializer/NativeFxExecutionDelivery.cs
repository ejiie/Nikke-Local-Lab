using System.Text.Json;
using NikkeLocalLab.PhaseD;
using static CommonDeliveryFiles;

internal sealed record CommonNativeRegistration(string ContractId, CommonFilePin OriginalStore,
    NativeFxBaseline Baseline, string JournalPath);
internal sealed record CommonNativeExecutionV2(string ContractId, string ExecutionUid, string ProfileSha256,
    string CandidateSealSha256, string RecipeSha256, string WeaknessCode,
    CommonFilePin BaselineRegistration, string RangePlanSha256, CommonNativePatch[] Patches);
internal sealed record CommonNativeRangeCompletion(string ContractId, string ManifestSha256,
    string? TerminationReceiptSha256, NativeFxRangeReceipt RangeReceipt, bool ActualGameAcceptanceClaimed);

// Shared Stage/apply/cleanup implementation, also exercised with synthetic files.
// The production adapter supplies fixed installation paths and exact Job/cold checks.
internal static class NativeFxExecutionDelivery
{
  private static void Require([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool ok) => CommonDeliveryFiles.Require(ok);
  internal const string RegistrationContract = "nll/common-native-fx-baseline/v2";
  internal static string Target(string weakness) => weakness switch
  { "fire" => "wind", "water" => "fire", "wind" => "iron", "electric" => "water", "iron" => "electric", _ => throw new InvalidDataException("phase_d_common_weakness_invalid") };

  internal static CommonNativeRegistration Registration(CommonFilePin pin)
  {
    var registration = JsonSerializer.Deserialize<CommonNativeRegistration>(Read(pin), Json)!;
    Require(registration is not null && registration.ContractId == RegistrationContract);
    NativeFxRangeTransaction.ValidateBaseline(registration.Baseline);
    Require(registration.OriginalStore is not null &&
        registration.OriginalStore.Length == registration.Baseline.Store.Length &&
        registration.OriginalStore.Sha256 == registration.Baseline.OriginalSha256);
    _ = Plain(registration.OriginalStore.Path); _ = Plain(registration.JournalPath);
    return registration;
  }

  internal static object? Stage(string launchRoot, string profile, string candidate, string recipe, string weakness,
      CommonFilePin baselinePin, CommonNativeRegistration registration, CommonNativePatch[] patches)
  {
    if (patches.Length == 0) return null;
    Require(Registration(baselinePin) == registration);
    var uid = Guid.ParseExact(Path.GetFileName(Plain(launchRoot)), "D");
    var output = Path.Combine(launchRoot, "runtime", "execution-fx");
    Require(patches.Length is > 0 and <= 32 && !Directory.Exists(output));
    // Validate all source ranges before staging anything; never open the CDB.
    var sourcePlan = Plan(uid, profile, candidate, recipe, weakness, registration, patches,
        pin => Read(pin, 16777216));
    Directory.CreateDirectory(output);
    var copied = new List<CommonNativePatch>();
    for (var i = 0; i < patches.Length; i++)
    {
      CommonFilePin Copy(byte[] bytes, string kind)
      {
        var path = Path.Combine(output, $"{i}.{kind}.chunk");
        using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
        { file.Write(bytes); file.Flush(true); }
        return new(path, bytes.Length, Hash(bytes));
      }
      copied.Add(new(patches[i].RoleCode, patches[i].Offset,
          Copy(sourcePlan.Ranges[i].Before, "before"), Copy(sourcePlan.Ranges[i].After, "after")));
    }
    var manifest = new CommonNativeExecutionV2(NativeFxRangeTransaction.Contract, uid.ToString("N"), profile,
        candidate, recipe, weakness, baselinePin, NativeFxRangeTransaction.Digest(sourcePlan), copied.ToArray());
    var path = Path.Combine(output, "manifest.private.json"); Publish(path, manifest);
    // No journal reservation in Stage: failure before Job creation cannot strand
    // store ownership. Rollback inputs and manifest are already durable at apply.
    return new { manifestSha256 = FileHash(path), candidateSealSha256 = candidate, profileSha256 = profile, weaknessCode = weakness };
  }

  internal static NativeFxRangeResult Execute(string root, string manifestHash, string executionUid,
      string profile, string candidate, string weakness, string termination, bool apply, Action verify,
      Action<CommonFilePin, CommonNativeRegistration> validateRegistration,
      Func<CommonNativeRegistration, NativeFxStoreAccess> openStore)
  {
    root = Plain(root);
    Require(Path.GetFileName(root) == "execution-fx" && Path.GetFileName(Path.GetDirectoryName(root)) == "runtime");
    var launchUid = Guid.ParseExact(Path.GetFileName(Path.GetDirectoryName(Path.GetDirectoryName(root))) ?? "", "D");
    Require(launchUid != Guid.Empty && launchUid.ToString("N") == executionUid);
    Require(apply || termination.Length == 64 && termination.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'));
    var manifestPath = Path.Combine(root, "manifest.private.json");
    using var document = ReadJson(manifestPath, manifestHash);
    var manifest = document.RootElement.Deserialize<CommonNativeExecutionV2>(Json)!;
    Require(manifest is not null && manifest.ContractId == NativeFxRangeTransaction.Contract &&
        manifest.ExecutionUid == executionUid && manifest.ProfileSha256 == profile &&
        manifest.CandidateSealSha256 == candidate && manifest.WeaknessCode == weakness &&
        manifest.Patches is { Length: > 0 and <= 32 });
    var registration = Registration(manifest.BaselineRegistration);
    validateRegistration(manifest.BaselineRegistration, registration);
    var leases = new List<FileStream>();
    try
    {
      for (var i = 0; i < manifest.Patches.Length; i++)
      {
        Require(Plain(manifest.Patches[i].Before.Path) == Path.Combine(root, $"{i}.before.chunk") &&
            Plain(manifest.Patches[i].After.Path) == Path.Combine(root, $"{i}.after.chunk"));
      }
      byte[] Chunk(CommonFilePin pin)
      {
        Require(pin.Length is > 0 and <= 16777216);
        var file = new FileStream(Plain(pin.Path), FileMode.Open, FileAccess.Read, FileShare.Read);
        leases.Add(file); Require(file.Length == pin.Length);
        var bytes = new byte[(int)file.Length]; file.ReadExactly(bytes);
        Require(Hash(bytes) == pin.Sha256); return bytes;
      }
      var plan = Plan(launchUid, profile, candidate, manifest.RecipeSha256, weakness, registration, manifest.Patches, Chunk);
      var planHash = NativeFxRangeTransaction.Digest(plan);
      Require(manifest.RangePlanSha256 == planHash);
      var completionPath = Path.Combine(root, apply ? "applied.json" : "retired.json");
      var completionContract = apply ? "nll/common-native-fx-applied/v2" : "nll/common-native-fx-retired/v2";
      void CheckCompletion()
      {
        using var old = JsonDocument.Parse(File.ReadAllBytes(Plain(completionPath)));
        var receipt = old.RootElement.Deserialize<CommonNativeRangeCompletion>(Json)!;
        Require(receipt is not null && receipt.ContractId == completionContract && receipt.ManifestSha256 == manifestHash &&
            receipt.TerminationReceiptSha256 == (apply ? null : termination) && !receipt.ActualGameAcceptanceClaimed &&
            receipt.RangeReceipt is { } range && range.ContractId == NativeFxRangeTransaction.ReceiptContract &&
            range.ExecutionUid == launchUid && range.PlanSha256 == planHash && range.ValidationScope == "patched_ranges" &&
            range.State == (apply ? "applied" : "restored") &&
            range.SelectedBytes == plan.Ranges.Sum(x => (long)x.Before.Length) &&
            range.BytesRead >= range.SelectedBytes && range.BytesRead <= 2 * range.SelectedBytes &&
            range.BytesWritten >= 0 && range.BytesWritten <= range.SelectedBytes);
      }
      if (File.Exists(completionPath)) CheckCompletion();
      void Verify()
      {
        verify(); Require(FileHash(manifestPath) == manifestHash);
        _ = Read(manifest.BaselineRegistration);
        validateRegistration(manifest.BaselineRegistration, registration);
      }
      Verify();
      var journal = new NativeFxRangeJournal(Plain(registration.JournalPath));
      NativeFxRangeTransaction.Prepare(journal, plan, allowCompleted: !apply);
      var result = NativeFxRangeTransaction.Execute(journal, plan, !apply, () =>
      { Verify(); return openStore(registration); }, Verify);
      Verify();
      if (File.Exists(completionPath)) CheckCompletion();
      else
      {
        try
        {
          Publish(completionPath, new CommonNativeRangeCompletion(completionContract, manifestHash,
            apply ? null : termination, result.Receipt, false));
        }
        catch (IOException) when (File.Exists(completionPath)) { CheckCompletion(); }
      }
      return result;
    }
    finally { foreach (var lease in leases) lease.Dispose(); }
  }

  private static NativeFxRangePlan Plan(Guid uid, string profile, string candidate, string recipe, string weakness,
      CommonNativeRegistration registration, CommonNativePatch[] patches, Func<CommonFilePin, byte[]> read)
  {
    var target = Target(weakness);
    Require(patches is { Length: > 0 and <= 32 } && patches.Sum(x => x.Before.Length) <= 67108864);
    var ranges = patches.Select(row =>
    {
      Require(row.RoleCode == target && row.Before.Length == row.After.Length);
      return new NativeFxRange(row.Offset, read(row.Before), read(row.After), row.Before.Sha256, row.After.Sha256);
    }).ToArray();
    return NativeFxRangeTransaction.Snapshot(new(NativeFxRangeTransaction.Contract, uid, registration.Baseline,
        profile, recipe, candidate, ranges));
  }
}
