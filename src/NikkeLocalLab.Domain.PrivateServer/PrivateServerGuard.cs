using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.PrivateServer;

public sealed class PrivateServerIntegrityException : Exception
{
  public PrivateServerIntegrityException(string code)
      : base(code)
  {
    Code = PrivateServerGuard.RequireCode(code, nameof(code));
  }

  public string Code { get; }
}

internal static class PrivateServerGuard
{
  internal static EntityUid RequireUid(EntityUid value, string parameterName)
  {
    if (value.Value == Guid.Empty)
    {
      throw new PrivateServerIntegrityException("private_server_uid_invalid");
    }

    return value;
  }

  internal static Sha256Digest RequireDigest(Sha256Digest value, string parameterName)
  {
    if (value == default)
    {
      throw new PrivateServerIntegrityException("private_server_digest_invalid");
    }

    return value;
  }

  internal static DateTimeOffset NormalizeUtc(DateTimeOffset value, string parameterName)
  {
    if (value == default)
    {
      throw new PrivateServerIntegrityException("private_server_timestamp_invalid");
    }

    var utc = value.ToUniversalTime();
    return new DateTimeOffset(utc.Ticks - (utc.Ticks % 10), TimeSpan.Zero);
  }

  internal static decimal RequireStorageDecimal(
      decimal value,
      int maximumIntegerDigits,
      int maximumScale,
      string errorCode)
  {
    var bits = decimal.GetBits(value);
    var scale = (bits[3] >> 16) & 0xff;
    decimal exclusiveMaximum = 1m;
    for (var index = 0; index < maximumIntegerDigits; index++)
    {
      exclusiveMaximum *= 10m;
    }

    if (scale > maximumScale || Math.Abs(value) >= exclusiveMaximum)
    {
      throw new PrivateServerIntegrityException(errorCode);
    }

    return value;
  }

  internal static string RequireCode(string value, string parameterName, int maximumLength = 64)
  {
    if (string.IsNullOrEmpty(value) || value.Length > maximumLength || value[0] is < 'a' or > 'z' ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-')))
    {
      throw new PrivateServerIntegrityException("private_server_code_invalid");
    }

    return value;
  }

  internal static string RequireVersionedContract(
      string value,
      string requiredPrefix,
      string parameterName)
  {
    if (string.IsNullOrEmpty(value) || value.Length > 128 ||
        value.Any(static character =>
            !((character >= 'a' && character <= 'z') ||
              (character >= '0' && character <= '9') ||
              character is '.' or '_' or '-' or '/')) ||
        !value.StartsWith(requiredPrefix, StringComparison.Ordinal))
    {
      throw new PrivateServerIntegrityException("private_server_contract_invalid");
    }

    var separatorIndex = value.LastIndexOf("/v", StringComparison.Ordinal);
    var nameLength = separatorIndex - requiredPrefix.Length;
    if (separatorIndex < requiredPrefix.Length || nameLength is < 1 or > 48)
    {
      throw new PrivateServerIntegrityException("private_server_contract_invalid");
    }

    var name = value.AsSpan(requiredPrefix.Length, nameLength);
    if (name[0] is < 'a' or > 'z' || name.IndexOf('/') >= 0 ||
        name[1..].IndexOfAnyExcept(
            "abcdefghijklmnopqrstuvwxyz0123456789._-") >= 0)
    {
      throw new PrivateServerIntegrityException("private_server_contract_invalid");
    }

    var versionIndex = separatorIndex + 2;
    if (versionIndex >= value.Length || value[versionIndex] == '0' ||
        value.AsSpan(versionIndex).IndexOfAnyExceptInRange('0', '9') >= 0)
    {
      throw new PrivateServerIntegrityException("private_server_contract_invalid");
    }

    return value;
  }

  internal static IReadOnlyList<string> NormalizeCodes(
      IEnumerable<string>? values,
      string parameterName)
  {
    if (values is null)
    {
      return Array.Empty<string>();
    }

    var normalized = values
        .Select(value => RequireCode(value, parameterName))
        .Distinct(StringComparer.Ordinal)
        .OrderBy(static value => value, StringComparer.Ordinal)
        .ToArray();
    if (normalized.Length > 64)
    {
      throw new PrivateServerIntegrityException("private_server_code_set_too_large");
    }

    return Array.AsReadOnly(normalized);
  }

  internal static void RequireRevisionShape(
      long revisionNumber,
      EntityUid? predecessorRevisionUid)
  {
    if (revisionNumber < 1 ||
        (revisionNumber == 1 && predecessorRevisionUid.HasValue) ||
        (revisionNumber > 1 && !predecessorRevisionUid.HasValue))
    {
      throw new PrivateServerIntegrityException("private_server_revision_shape_invalid");
    }

    if (predecessorRevisionUid.HasValue)
    {
      RequireUid(predecessorRevisionUid.Value, nameof(predecessorRevisionUid));
    }
  }
}

internal static class PrivateServerHash
{
  internal static Sha256Digest Compute(string contractId, Action<IncrementalHash> append)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    Append(hash, contractId);
    append(hash);
    return Sha256Digest.FromBytes(hash.GetHashAndReset());
  }

  internal static void Append(IncrementalHash hash, string value)
  {
    var bytes = Encoding.UTF8.GetBytes(value);
    Span<byte> length = stackalloc byte[4];
    System.Buffers.Binary.BinaryPrimitives.WriteInt32BigEndian(length, bytes.Length);
    hash.AppendData(length);
    hash.AppendData(bytes);
  }

  internal static void Append(IncrementalHash hash, EntityUid value) => Append(hash, value.ToString());

  internal static void Append(IncrementalHash hash, EntityUid? value) =>
      Append(hash, value?.ToString() ?? string.Empty);

  internal static void Append(IncrementalHash hash, Sha256Digest value) => Append(hash, value.ToString());

  internal static void Append(IncrementalHash hash, Sha256Digest? value) =>
      Append(hash, value?.ToString() ?? string.Empty);

  internal static void Append(IncrementalHash hash, bool value) =>
      Append(hash, value ? "true" : "false");

  internal static void Append(IncrementalHash hash, int value) =>
      Append(hash, value.ToString(CultureInfo.InvariantCulture));

  internal static void Append(IncrementalHash hash, long value) =>
      Append(hash, value.ToString(CultureInfo.InvariantCulture));

  internal static void Append(IncrementalHash hash, decimal value) =>
      Append(hash, value.ToString("G29", CultureInfo.InvariantCulture));

  internal static void Append(IncrementalHash hash, DateTimeOffset value) =>
      Append(
          hash,
          PrivateServerGuard.NormalizeUtc(value, nameof(value))
              .ToString("O", CultureInfo.InvariantCulture));

  internal static void Append(IncrementalHash hash, DateTimeOffset? value) =>
      Append(
          hash,
          value.HasValue
              ? PrivateServerGuard.NormalizeUtc(value.Value, nameof(value))
                  .ToString("O", CultureInfo.InvariantCulture)
              : string.Empty);
}
