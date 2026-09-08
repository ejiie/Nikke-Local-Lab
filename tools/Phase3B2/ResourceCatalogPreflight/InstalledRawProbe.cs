using System.Data.HashFunction.SpookyHash;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ResourceCatalogPreflight;

internal static class InstalledRawProbe
{
  // Read-only hypotheses, not a provider: filenames and original keys never
  // leave this process. A hypothesis match is reported separately from readiness.
  internal static object Inspect(CatalogDatabase catalog, string directory, string headerPath, string role)
  {
    if (CatalogInspection.Read(catalog).LayoutCode != "chunk_catalog_v1")
      throw new PreflightException("resource_chunk_layout_required");
    var header = NikkeLocalLab.Automation.LegacyVersionHeader.Parse(File.ReadAllText(headerPath));
    var revision = header[role];
    var rawDirectory = Path.Combine(directory, "raw");
    var names = Directory.Exists(rawDirectory)
        ? Directory.GetFiles(rawDirectory).ToDictionary(path => Path.GetFileName(path)!, StringComparer.OrdinalIgnoreCase)
        : new Dictionary<string, string>();
    var spooky = SpookyHashV2Factory.Instance.Create(new SpookyHashConfig { HashSizeInBits = 128 });
    using var command = catalog.Connection.CreateCommand();
    command.CommandText = "SELECT key,hash,extension,size FROM files_rawtype ORDER BY file_id";
    using var reader = command.ExecuteReader();
    var rows = new List<object>();
    while (reader.Read())
    {
      var key = reader.GetString(0);
      var hash = reader.GetValue(1) is byte[] blob ? Convert.ToHexString(blob) : reader.GetString(1);
      var extension = reader.GetString(2).TrimStart('.');
      if (!Regex.IsMatch(hash, "^[A-Fa-f0-9]{32}$") || !Regex.IsMatch(extension, "^[A-Za-z0-9]{1,8}$"))
        throw new PreflightException("resource_raw_identity_shape_unresolved");
      var keyMd5 = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(key)));
      var keySpooky = Convert.ToHexString(spooky.ComputeHash(Encoding.UTF8.GetBytes(key)).Hash);
      var candidates = new[] { ("catalog_hash", hash), ("key_md5", keyMd5), ("key_spooky128", keySpooky) };
      var found = candidates.Where(candidate => names.ContainsKey(candidate.Item2 + "." + extension)).ToArray();
      var unique = found.Select(candidate => names[candidate.Item2 + "." + extension]).Distinct().ToArray();
      var lengthMatches = false;
      string contentAlgorithm = "not_evaluated";
      bool? spookyStreamAndArrayAgree = null;
      string? contentSha256 = null;
      if (unique.Length == 1)
      {
        using var source = new FileStream(unique[0], FileMode.Open, FileAccess.Read, FileShare.Read);
        lengthMatches = source.Length == reader.GetInt64(3);
        contentSha256 = Convert.ToHexString(SHA256.HashData(source)).ToLowerInvariant();
        source.Position = 0;
        var md5 = Convert.ToHexString(MD5.HashData(source));
        source.Position = 0;
        var spookyHash = Convert.ToHexString(spooky.ComputeHash(source).Hash);
        if (source.Length <= 64 * 1024 * 1024)
        {
          var arrayHash = Convert.ToHexString(spooky.ComputeHash(File.ReadAllBytes(unique[0])).Hash);
          spookyStreamAndArrayAgree = spookyHash == arrayHash;
          spookyHash = arrayHash;
        }
        contentAlgorithm = hash.Equals(spookyHash, StringComparison.OrdinalIgnoreCase) ? "spooky_hash_v2_128" :
            hash.Equals(md5, StringComparison.OrdinalIgnoreCase) ? "md5" : "unresolved";
        if (contentAlgorithm == "unresolved")
        {
          source.Position = 0;
          var segmented = Convert.ToHexString(SegmentedSpookyHash.Compute(source, source.Length));
          if (hash.Equals(segmented, StringComparison.OrdinalIgnoreCase))
            contentAlgorithm = "spooky_hash_v2_128_seeded_128k_blocks";
        }
        if (contentAlgorithm == "unresolved" && source.Length is >= 4 and <= 64 * 1024 * 1024)
        {
          source.Position = 0;
          var magic = new byte[4];
          source.ReadExactly(magic);
          if (magic.AsSpan().SequenceEqual("NKDB"u8))
          {
            var decoded = BoundedCatalogDecoder.Decode(File.ReadAllBytes(unique[0]));
            try
            {
              if (hash.Equals(Convert.ToHexString(spooky.ComputeHash(decoded).Hash), StringComparison.OrdinalIgnoreCase))
                contentAlgorithm = "nkdb_decoded_spooky_hash_v2_128";
            }
            finally { CryptographicOperations.ZeroMemory(decoded); }
          }
        }
      }
      rows.Add(new
      {
        keySha256 = CatalogDatabase.Hash(Encoding.UTF8.GetBytes(key)),
        extensionCode = extension.ToLowerInvariant(),
        catalogLength = reader.GetInt64(3),
        catalogHashByteLength = hash.Length / 2,
        matchedNamingHypotheses = found.Select(candidate => candidate.Item1).ToArray(),
        uniqueMatchedFileCount = unique.Length,
        lengthMatches,
        contentHashAlgorithm = contentAlgorithm,
        contentSha256,
        spookyStreamAndArrayAgree,
        keyContainsSelectedRevision = key.Contains(revision, StringComparison.Ordinal),
        keyIsRelative = !Uri.TryCreate(key, UriKind.Absolute, out _),
        keyHasPathSeparator = key.Contains('/') || key.Contains('\\')
      });
    }
    return new { roleCode = role, catalog.BodySha256, rows, nativeReadiness = "not_evaluated" };
  }
}
