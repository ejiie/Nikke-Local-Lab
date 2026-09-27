namespace NikkeLocalLab.Phase3B2.UserValidation;

// The server reads the target observation only. Full asset/delivery admission
// remains the preparer/controller's responsibility; no fallback publication.
internal static class UserValidationProfileVersion
{
  internal static bool IsSupported(int schema, string? contract) => (schema, contract) is
      (1, "nll/boss-runtime-variant-profile/v1") or
      (2, "nll/boss-runtime-variant-profile/v2") or
      (3, "nll/boss-runtime-variant-profile/v3") or
      (4, "nll/boss-runtime-variant-profile/v4");
}
