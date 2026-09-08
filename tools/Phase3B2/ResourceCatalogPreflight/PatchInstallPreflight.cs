using NikkeLocalLab.Automation;

namespace ResourceCatalogPreflight;

internal static class PatchInstallPreflight
{
  internal static object Inspect(string root, string metadataPath, PatchResourcePlan plan, bool verifyRaw = false)
  {
    if (new FileInfo(metadataPath).Length is < 1 or > 65536)
      throw new PreflightException("resource_version_header_size_invalid");
    var metadata = PatchVersionMetadata.Parse(File.ReadAllBytes(metadataPath));
    var roles = new List<object>();
    long missingChunks = 0, badLengths = 0, missingRaw = 0, verifiedRaw = 0;
    foreach (var role in PatchResourcePlan.MetadataRoles)
    {
      var directory = Path.Combine(root, role);
      using var catalog = new CatalogDatabase(Path.Combine(directory, "catalog.ndb"), Path.Combine(directory, "catalog.ndb.nds"));
      if (CatalogInspection.Read(catalog).LayoutCode != "chunk_catalog_v1")
        throw new PreflightException("resource_chunk_layout_required");
      var available = catalog.Strings("SELECT group_name FROM groups_chunktype UNION SELECT group_name FROM groups_rawtype");
      var wanted = plan.GroupsForRole(role);
      if (wanted.Any(name => !available.Contains(name, StringComparer.OrdinalIgnoreCase)))
        throw new PreflightException("resource_selected_group_missing");
      var selected = available.Where(name => wanted.Contains(name, StringComparer.OrdinalIgnoreCase)).ToArray();
      var counts = PatchGroupProbe.Count(catalog.Connection, selected);
      using var store = File.Exists(Path.Combine(directory, "chunk", "store.cdb.idx"))
          ? new ChunkStoreReader(directory) : null;
      var coverage = PatchGroupProbe.CompareInstalled(catalog.Connection, selected,
          store?.Entries ?? new Dictionary<string, ChunkStoreReader.Location>());
      long rawCount = 0, rawUnavailable = 0, roleVerifiedRaw = 0;
      using var command = catalog.Connection.CreateCommand();
      command.CommandText = """
          SELECT f.key,g.group_name,f.size,hex(f.hash) FROM files_rawtype f
          JOIN groups_rawtype g ON g.group_id=f.group_id
          """;
      using var reader = command.ExecuteReader();
      while (reader.Read())
      {
        if (!wanted.Contains(reader.GetString(1), StringComparer.OrdinalIgnoreCase)) continue;
        rawCount++;
        try
        {
          var rawPath = CatalogLinkageProbe.ResolveRawFile(catalog, directory, reader.GetString(0));
          if (verifyRaw)
          {
            using var input = new FileStream(rawPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            var sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(input)).ToLowerInvariant();
            using var source = new SealedResourceFile(rawPath, reader.GetInt64(2), sha256, reader.GetString(3));
            roleVerifiedRaw++;
          }
        }
        catch (PreflightException error) when (error.Message == "resource_inner_catalog_file_missing_or_incomplete")
        {
          rawUnavailable++;
        }
      }
      missingChunks += coverage.MissingSelectedChunkCount;
      badLengths += coverage.LengthMismatchCount;
      missingRaw += rawUnavailable;
      verifiedRaw += roleVerifiedRaw;
      roles.Add(new
      {
        roleCode = role,
        catalog.BodySha256,
        catalog.SignatureSha256,
        selectedGroups = wanted,
        counts,
        coverage,
        selectedRawFileCount = rawCount,
        checksumVerifiedRawFileCount = roleVerifiedRaw,
        missingOrIncompleteRawFileCount = rawUnavailable
      });
    }

    var reasons = new List<string> { "resource_catalog_version_binding_unresolved", "resource_native_transport_unresolved" };
    if (!plan.NoAudioPreferenceContractResolved) reasons.Add("resource_no_audio_contract_unresolved");
    if (missingChunks > 0) reasons.Add("resource_selected_chunks_missing");
    if (badLengths > 0) reasons.Add("resource_selected_chunk_length_mismatch");
    if (missingRaw > 0) reasons.Add("resource_selected_raw_files_missing");
    return new
    {
      contractId = "nll/patch-install-preflight/v1",
      profileCode = PatchResourcePlan.ProfileCode,
      metadataSha256 = metadata.SourceSha256.Hex,
      selectionSha256 = plan.ContentSha256.Hex,
      metadataProjectCount = roles.Count,
      roles,
      selectedPayloadPresenceResolved = missingChunks == 0 && badLengths == 0 && missingRaw == 0,
      selectedRawChecksumStatus = !verifyRaw ? "not_evaluated" : missingRaw == 0 ? "verified" : "incomplete",
      checksumVerifiedRawFileCount = verifiedRaw,
      cryptographicPayloadClosureResolved = false,
      nativeAdmission = "blocked",
      reasonCodes = reasons,
      sourceMutationPerformed = false,
      officialOutboundPerformed = false
    };
  }

  internal static object VerifyPakSamples(string role, string directory)
  {
    using var catalog = new CatalogDatabase(Path.Combine(directory, "catalog.ndb"), Path.Combine(directory, "catalog.ndb.nds"));
    CatalogInspection.Read(catalog);
    using var store = new ChunkStoreReader(directory);
    using var command = catalog.Connection.CreateCommand();
    command.CommandText = "SELECT pak_id,pak_offset,compressed_size,hex(hash) FROM chunks ORDER BY chunk_id";
    using var reader = command.ExecuteReader();
    var observations = new List<object>();
    while (reader.Read() && observations.Count < 3)
    {
      var hash = reader.GetString(3);
      if (!store.Entries.ContainsKey(hash)) continue;
      var size = reader.GetInt32(2);
      var offset = reader.GetInt64(1);
      var bytes = VirtualPakReader.ReadRange(catalog.Connection, store, reader.GetInt64(0), offset, size);
      try { observations.Add(new { byteLength = bytes.Length, sha256 = CatalogDatabase.Hash(bytes) }); }
      finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(bytes); }
    }
    if (observations.Count == 0) throw new PreflightException("resource_pak_samples_unavailable");
    return new
    {
      roleCode = role,
      samples = observations,
      nativeTransportVerified = false,
      sourceMutationPerformed = false,
      rawContentEmitted = false
    };
  }
}
