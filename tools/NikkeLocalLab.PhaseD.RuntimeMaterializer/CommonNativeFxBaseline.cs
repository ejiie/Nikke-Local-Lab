using System.Security.Cryptography;
using NikkeLocalLab.PhaseD;
using static CommonDeliveryFiles;

// Installation authority for the currently admitted isolated physical store.
// This path is shared by all profiles and runtime bundles, never by season/UID.
internal static class CommonNativeFxBaseline
{
  private static void Require([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool ok) => CommonDeliveryFiles.Require(ok);
  internal static string StoreRoot(CommonFilePin store)
  {
    var build = InstalledStoreBuild(store.Path);
    const string legacy = @"C:\NLL\RuntimeInputs\CommonBossExecution\native-fx";
    return build == "151.8.5" ? legacy : legacy + "-" + build;
  }

  internal static void ValidateRegistration(CommonFilePin pin, CommonNativeRegistration registration)
  {
    var root = StoreRoot(registration.OriginalStore);
    var RegistrationPath = Path.Combine(root, "baseline.private.json");
    var JournalPath = Path.Combine(root, "store-state.private.json");
    Require(Plain(pin.Path) == RegistrationPath && Plain(registration.JournalPath) == JournalPath);
    // Paths are rechecked before each operation. Existing admission additionally
    // verifies the isolated CDB path, no links, and physical identity on its handle.
    _ = Plain(JournalPath + ".lock");
    Require(File.Exists(JournalPath));
  }

  internal static (CommonFilePin Pin, CommonNativeRegistration Registration) Load(CommonFilePin originalStore)
  {
    var root = StoreRoot(originalStore);
    var RegistrationPath = Path.Combine(root, "baseline.private.json");
    var JournalPath = Path.Combine(root, "store-state.private.json");
    if (!File.Exists(RegistrationPath) || !File.Exists(JournalPath))
      throw new InvalidDataException("phase_d_common_native_fx_baseline_required");
    var pin = Pin(RegistrationPath);
    var registration = NativeFxExecutionDelivery.Registration(pin);
    ValidateRegistration(pin, registration);
    Require(registration.OriginalStore == originalStore);
    return (pin, registration);
  }

  // Explicit cold installation only. This is the sole new whole-CDB scan and
  // has no call path from Stage, Apply, Restore, or normal preparation.
  internal static CommonFilePin Register(CommonFilePin originalStore, string installationId, string version)
  {
    var Root = StoreRoot(originalStore);
    var RegistrationPath = Path.Combine(Root, "baseline.private.json");
    var JournalPath = Path.Combine(Root, "store-state.private.json");
    CommonNativeFx.Cold();
    _ = Plain(Root);
    Require(!Directory.Exists(Root));
    using var stream = CommonNativeFx.OpenStore(originalStore, false);
    Require(Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() == originalStore.Sha256);
    var baseline = new NativeFxBaseline(installationId, version, CommonNativeFx.Identity(stream), originalStore.Sha256);
    NativeFxRangeTransaction.ValidateBaseline(baseline);
    CommonNativeFx.Cold();
    Directory.CreateDirectory(Root);
    new NativeFxRangeJournal(JournalPath).RegisterVerifiedBaseline(baseline);
    Publish(RegistrationPath, new CommonNativeRegistration(NativeFxExecutionDelivery.RegistrationContract,
        originalStore, baseline, JournalPath));
    return Pin(RegistrationPath);
  }
}
