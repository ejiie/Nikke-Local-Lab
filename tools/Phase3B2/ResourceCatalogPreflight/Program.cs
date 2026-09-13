using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using NikkeLocalLab.Automation;
using NikkeLocalLab.Provenance;
using ResourceCatalogPreflight;

var options = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
string? currentRole = null;
try
{
  if (args is ["stage-boss-catalog-locales", var bossLocaleSource, var bossLocaleDestination, var bossLocaleCatalogHash, var bossLocaleSignatureHash])
  {
    Console.WriteLine(JsonSerializer.Serialize(BossCatalogLocales.Stage(bossLocaleSource, bossLocaleDestination,
        bossLocaleCatalogHash, bossLocaleSignatureHash), options));
    return 0;
  }
  if (args is ["stage-native-fx-chunks", var chunkSource, var layoutRoot, var layoutSha256, var chunkDestination])
  {
    Console.WriteLine(JsonSerializer.Serialize(NativeFxChunkCandidate.Stage(chunkSource, layoutRoot, layoutSha256, chunkDestination), options));
    return 0; // Offline candidate only. The operator owns native-game acceptance.
  }
  if (args is ["export-native-fx", var fxPlan, var fxPlanSha256, var fxDestination])
  {
    Console.WriteLine(JsonSerializer.Serialize(NativeFxExport.Export(fxPlan, fxPlanSha256, fxDestination), options));
    return 0; // Exact offline payload binding is not native execution admission.
  }
  if (args is ["stage-probe-server-locales", var localeSource, var localeDestination, var localeCatalogHash, var localeSignatureHash])
  {
    Console.WriteLine(JsonSerializer.Serialize(ProbeServerLocales.Stage(localeSource, localeDestination,
        localeCatalogHash, localeSignatureHash), options));
    return 0;
  }
  if (args is ["inspect-route-probe" or "serve-route-probe", var routeProbePlan, var routeProbeDigest])
  {
    var result = await ResourceRouteProbeHost.RunAsync(routeProbePlan, routeProbeDigest,
        start: args[0] == "serve-route-probe");
    Console.WriteLine(JsonSerializer.Serialize(result, options));
    return 0; // Observation or server shutdown is never native game admission.
  }
  if (args is ["inspect-index-digest", var indexDirectory])
  {
    Console.WriteLine(JsonSerializer.Serialize(IndexDigestProbe.Inspect(indexDirectory), options));
    return 0;
  }
  if (args is ["patch-preflight" or "verify-patch-raw", var patchRoot, var patchMetadata, var patchLanguage, var patchScope,
      var lodCode, var textureCode, var spineCode])
  {
    var voiceScope = patchScope switch
    {
      "minimal" => VoiceDownloadScope.Minimal,
      "full" => VoiceDownloadScope.Full,
      "none" => VoiceDownloadScope.None,
      _ => throw new PreflightException("resource_voice_selection_invalid")
    };
    ResourceQuality Quality(string value) => value switch
    {
      "sd" => ResourceQuality.Sd,
      "hd" => ResourceQuality.Hd,
      _ => throw new PreflightException("resource_quality_invalid")
    };
    var plan = new PatchResourcePlan(new ResourceSelection(patchLanguage == "none" ? null : patchLanguage, voiceScope),
        Quality(lodCode), Quality(textureCode), Quality(spineCode));
    Console.WriteLine(JsonSerializer.Serialize(PatchInstallPreflight.Inspect(patchRoot, patchMetadata, plan,
        verifyRaw: args[0] == "verify-patch-raw"), options));
    return 0; // Successful inspection is explicitly not native admission.
  }
  if (args is ["verify-pak-samples", var pakRole, var pakDirectory])
  {
    PatchResourcePlan.RequireRole(pakRole);
    Console.WriteLine(JsonSerializer.Serialize(PatchInstallPreflight.VerifyPakSamples(pakRole, pakDirectory), options));
    return 0;
  }
  if (args is ["inspect-patch-groups", var groupRole, var groupDirectory])
  {
    if (groupRole is not ("core" or "dp" or "fd" or "saus" or "en" or "ko" or "ja"))
      throw new PreflightException("resource_role_invalid");
    Console.WriteLine(JsonSerializer.Serialize(PatchGroupProbe.Inspect(groupRole, groupDirectory), options));
    return 0;
  }
  if (args is ["inspect-linked-role", var linkedRole, var linkedDirectory])
  {
    if (linkedRole is not ("core" or "dp" or "fd" or "saus" or "en" or "ko" or "ja"))
      throw new PreflightException("resource_role_invalid");
    Console.WriteLine(JsonSerializer.Serialize(CatalogLinkageProbe.Inspect(linkedRole, linkedDirectory), options));
    return 0;
  }
  if (args is ["inspect-installed-raw", var rawRole, var rawDirectory, var rawHeader])
  {
    if (rawRole is not ("core" or "dp" or "fd" or "saus" or "en" or "ko" or "ja"))
      throw new PreflightException("resource_role_invalid");
    var bodyPath = Path.Combine(rawDirectory, "catalog.ndb");
    using var database = new CatalogDatabase(bodyPath, bodyPath + ".nds");
    Console.WriteLine(JsonSerializer.Serialize(InstalledRawProbe.Inspect(database, rawDirectory, rawHeader, rawRole), options));
    return 0;
  }
  if (args is ["inspect-version-header", var versionHeaderPath])
  {
    var info = new FileInfo(versionHeaderPath);
    if (!info.Exists || info.Length is < 1 or > 65536)
      throw new PreflightException("resource_version_header_size_invalid");
    var bytes = File.ReadAllBytes(versionHeaderPath);
    var header = LegacyVersionHeader.Parse(new System.Text.UTF8Encoding(false, true).GetString(bytes));
    Console.WriteLine(JsonSerializer.Serialize(new
    {
      contractId = "nll/resource-version-header-inspection/v1",
      formatCode = "legacy_eight_line_v1",
      byteLength = bytes.Length,
      sha256 = CatalogDatabase.Hash(bytes),
      roles = header.Keys.Order(StringComparer.Ordinal),
      coreVersion = header["core"],
      installationCatalogBindingVerified = false,
      nativeReadiness = "not_evaluated"
    }, options));
    return 0;
  }
  if (args is ["inspect-metadata-schema", var metadataBody, var metadataSignature])
  {
    using var metadata = new CatalogDatabase(metadataBody, metadataSignature);
    var embeddedCoreVersions = new HashSet<string>(StringComparer.Ordinal);
    var tableVersions = new List<object>();
    if (metadata.Tables.Contains("TableVersion", StringComparer.Ordinal))
    {
      using var versions = metadata.Connection.CreateCommand();
      versions.CommandText = "SELECT Key,Value FROM TableVersion LIMIT 32";
      using var values = versions.ExecuteReader();
      while (values.Read())
      {
        var key = values.GetString(0);
        var value = values.GetString(1);
        tableVersions.Add(new
        {
          keyCode = Regex.IsMatch(key, "^[A-Za-z_]{1,48}$") ? key : "unresolved",
          versionValue = Regex.IsMatch(value, "^[a-f0-9.]{1,48}$") ? value : "unresolved",
          valueSha256 = CatalogDatabase.Hash(System.Text.Encoding.UTF8.GetBytes(value))
        });
      }
    }
    var schemas = metadata.Tables.Select(table =>
    {
      using var command = metadata.Connection.CreateCommand();
      command.CommandText = "SELECT name,type FROM pragma_table_info($table) ORDER BY cid";
      command.Parameters.AddWithValue("$table", table);
      using var reader = command.ExecuteReader();
      var columns = new List<object>();
      while (reader.Read())
      {
        var column = reader.GetString(0);
        var type = reader.GetString(1);
        columns.Add(new { name = column, type });
        if (table == "internal_ids" && type == "TEXT")
        {
          using var scan = metadata.Connection.CreateCommand();
          scan.CommandText = "SELECT \"" + column.Replace("\"", "\"\"") + "\" FROM internal_ids LIMIT 100000";
          using var values = scan.ExecuteReader();
          while (values.Read())
          {
            if (values.IsDBNull(0)) continue;
            foreach (Match match in Regex.Matches(values.GetString(0), @"\b\d{3}\.\d+\.b\d+\b"))
              embeddedCoreVersions.Add(match.Value);
          }
        }
      }
      return new { table, columns };
    }).ToArray();
    Console.WriteLine(JsonSerializer.Serialize(new { schemas, tableVersions, embeddedCoreVersions, metadata.BodySha256, sourceMutationPerformed = false }, options));
    return 0;
  }
  if (args is ["assemble-single", var sourceDirectory, var destinationPath])
  {
    var bodyPath = Path.Combine(sourceDirectory, "catalog.ndb");
    using var catalog = new CatalogDatabase(bodyPath, bodyPath + ".nds");
    Console.WriteLine(JsonSerializer.Serialize(ChunkFileAssembler.AssembleSingle(catalog, sourceDirectory, destinationPath), options));
    return 0;
  }
  if (args is ["inspect-install" or "verify-installed", var installedRole, var installedDirectory])
  {
    if (installedRole is not ("core" or "dp" or "fd" or "saus" or "en" or "ko" or "ja"))
      throw new PreflightException("resource_role_invalid");
    currentRole = installedRole;
    var installedBody = Path.Combine(installedDirectory, "catalog.ndb");
    using var catalog = new CatalogDatabase(installedBody, installedBody + ".nds");
    var observation = ChunkStoreProbe.Inspect(catalog, installedDirectory, verifyAll: args[0] == "verify-installed");
    Console.WriteLine(JsonSerializer.Serialize(new
    {
      contractId = "nll/resource-chunk-store-inspection/v1",
      roleCode = installedRole,
      observation,
      sourceMutationPerformed = false,
      rawContentEmitted = false
    }, options));
    return 0;
  }
  if (args is ["loopback-verify", var receiptPath])
  {
    await LoopbackTransport.VerifyAsync(receiptPath);
    Console.WriteLine("{\"contractId\":\"nll/resource-loopback-preflight/v1\",\"statusCode\":\"verified\",\"officialOutboundPerformed\":false}");
    return 0;
  }
  if (args is ["inspect", var role, var body, var signature])
  {
    if (role is not ("core" or "dp" or "fd" or "saus" or "en" or "ko" or "ja"))
      throw new PreflightException("resource_role_invalid");
    currentRole = role;
    using var database = new CatalogDatabase(body, signature);
    var inspection = CatalogInspection.Read(database);
    Console.WriteLine(JsonSerializer.Serialize(new
    {
      contractId = "nll/resource-catalog-inspection/v1",
      roleCode = role,
      database.BodySha256,
      database.SignatureSha256,
      database.BodyByteLength,
      schemaSha256 = database.SchemaSha256(),
      inspection,
      decryptedContentPersisted = false,
      sourceMutationPerformed = false
    }, options));
    return 0;
  }

  if (args is not ["legacy-preflight", var serverRoot, var clientExecutable, var language, var scope])
  {
    Console.Error.WriteLine("usage: ResourceCatalogPreflight inspect <role> <body> <signature> | legacy-preflight <server-root> <client-executable> <voice-language> <minimal|full|none|unresolved>");
    return 2;
  }
  var selection = new ResourceSelection(language == "none" ? null : language, scope switch
  {
    "minimal" => VoiceDownloadScope.Minimal,
    "full" => VoiceDownloadScope.Full,
    "none" => VoiceDownloadScope.None,
    _ => VoiceDownloadScope.Unresolved
  });
  var roles = selection.RequiredCatalogRoles();
  serverRoot = Path.GetFullPath(serverRoot);
  using var config = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(serverRoot, "gameconfig.json")));
  var root = config.RootElement;
  var version = root.GetProperty("TargetVersion").GetString()!;
  if (!Regex.IsMatch(version, @"^\d+\.\d+\.\d+$") ||
      FileVersionInfo.GetVersionInfo(clientExecutable).FileVersion != version)
    throw new PreflightException("resource_client_server_build_mismatch");
  var cache = Path.Combine(serverRoot, "cache");
  var resourceBase = root.GetProperty("ResourceBaseURL").GetString()!
      .Replace("{Platform}", "StandaloneWindows64", StringComparison.Ordinal);
  var resourceUri = new Uri(resourceBase.TrimEnd('/') + "/pck/");
  if (resourceUri.Scheme != "https" || resourceUri.Host != "cloud.nikke-kr.com" ||
      !Regex.IsMatch(resourceUri.AbsolutePath, @"^/prdenv/[a-z0-9-]+/StandaloneWindows64/pck/$"))
    throw new PreflightException("resource_base_invalid");
  var packVersion = root.GetProperty("ResourceDataPackVersion").GetString()!;
  if (!Regex.IsMatch(packVersion, "^[0-9]+$")) throw new PreflightException("resource_pack_version_invalid");
  var packRoot = SafePath(cache, resourceUri.AbsolutePath.Trim('/'));
  var headerPath = SafePath(packRoot, "latest-" + packVersion + ".txt");
  if (!File.Exists(headerPath) || new FileInfo(headerPath).Length is < 1 or > 4096)
    throw new PreflightException("resource_version_header_missing_or_invalid");
  var revisions = LegacyVersionHeader.Parse(File.ReadAllText(headerPath));
  if (revisions["core"] != root.GetProperty("ResourceCoreVersion").GetString())
    throw new PreflightException("resource_core_version_mismatch");
  var profilePath = Path.Combine(AppContext.BaseDirectory, "resource-profile-legacy-" + version + ".json");
  if (!File.Exists(profilePath)) throw new PreflightException("resource_catalog_profile_unsealed");
  using var profile = JsonDocument.Parse(File.ReadAllBytes(profilePath));
  var sealedProfile = profile.RootElement;
  if (sealedProfile.GetProperty("contractId").GetString() != "nll/sealed-resource-catalog-profile/v1" ||
      sealedProfile.GetProperty("clientBuildCode").GetString() != "build_" + version ||
      sealedProfile.GetProperty("clientExecutableSha256").GetString() != Digest(clientExecutable).Hex ||
      sealedProfile.GetProperty("headerSha256").GetString() != Digest(headerPath).Hex)
    throw new PreflightException("resource_catalog_profile_binding_mismatch");
  var observations = new List<object>();
  var transports = new List<object>();
  foreach (var requiredRole in roles)
  {
    currentRole = requiredRole;
    var leaf = requiredRole is "core" or "dp" or "fd" ? "catalog.db" : "asset-catalog.cat";
    var relative = requiredRole + "/" + revisions[requiredRole] + "/" + leaf;
    var path = SafePath(packRoot, relative);
    using var catalog = new CatalogDatabase(path, path + ".nds");
    var sealedMembers = sealedProfile.GetProperty("members").EnumerateArray()
        .Where(member => member.GetProperty("roleCode").GetString() == requiredRole).ToArray();
    if (sealedMembers.Length != 1) throw new PreflightException("resource_catalog_member_unsealed");
    if (sealedMembers[0].GetProperty("bodySha256").GetString() != catalog.BodySha256 ||
        sealedMembers[0].GetProperty("signatureSha256").GetString() != catalog.SignatureSha256)
      throw new PreflightException("resource_catalog_pair_digest_mismatch");
    var inspection = CatalogInspection.Read(catalog);
    if (inspection.LayoutCode != (leaf == "catalog.db" ? "legacy_native_v1" : "legacy_saus_v1"))
      throw new PreflightException("resource_catalog_layout_mismatch");
    observations.Add(new
    {
      roleCode = requiredRole,
      schemaSha256 = catalog.SchemaSha256(),
      catalog.BodySha256,
      catalog.SignatureSha256,
      catalog.BodyByteLength,
      inspection.LayoutCode
    });
    // Build-local transport URLs are emitted only into the private launch
    // receipt. The public summary below does not contain original paths.
    transports.Add(new
    {
      roleCode = requiredRole,
      bodyUrl = new Uri(resourceUri, relative).AbsoluteUri,
      bodyTransportCode = leaf == "catalog.db" ? "decrypted_sqlite" : "original_nkdb",
      encryptedByteLength = catalog.BodyByteLength,
      encryptedSha256 = catalog.BodySha256,
      decryptedByteLength = catalog.SqliteByteLength,
      decryptedSha256 = catalog.SqliteSha256,
      signatureUrl = new Uri(resourceUri, relative + ".nds").AbsoluteUri,
      signatureByteLength = 96,
      signatureSha256 = catalog.SignatureSha256
    });
  }
  currentRole = "static_data";
  var staticUri = new Uri(root.GetProperty("StaticDataMpk").GetProperty("Url").GetString()!);
  if (staticUri.Scheme != "https" || staticUri.Host != "cloud.nikke-kr.com")
    throw new PreflightException("resource_static_data_binding_invalid");
  var staticPath = SafePath(cache, staticUri.AbsolutePath.Trim('/'));
  var binding = new ResourceBinding("build_" + version, Digest(clientExecutable),
      Digest(Path.Combine(serverRoot, "EpinelPS.dll")), Digest(Path.Combine(serverRoot, "gameconfig.json")),
      Digest(staticPath), "legacy_catalog_v1", selection);
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/resource-catalog-preflight/v1",
    statusCode = "catalogs_verified",
    bindingSha256 = binding.ContentSha256.Hex,
    clientBuildCode = binding.ClientBuildCode,
    voiceLanguage = selection.VoiceLanguage,
    downloadScope = selection.ScopeCode,
    headerSha256 = Digest(headerPath).Hex,
    headerByteLength = new FileInfo(headerPath).Length,
    headerUrl = new Uri(resourceUri, "latest-" + packVersion + ".txt").AbsoluteUri,
    observations,
    transports,
    catalogProfileSha256 = Digest(profilePath).Hex,
    signatureVerificationStatusCode = "pair_hashes_only",
    payloadClosureStatusCode = "not_evaluated",
    actualPlayVerified = false,
    sourceMutationPerformed = false,
    officialOutboundPerformed = false
  }, options));
  return 0;
}
catch (Exception error) when (error is PreflightException or PipelineManifestException or IOException or
    UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException or
    System.Security.Cryptography.CryptographicException or Microsoft.Data.Sqlite.SqliteException or ArgumentException or
    HttpRequestException or OperationCanceledException)
{
  var code = error is PreflightException ? error.Message : error is PipelineManifestException manifest
      ? manifest.FailureCode : "resource_catalog_preflight_failed";
  Console.WriteLine(JsonSerializer.Serialize(new
  {
    contractId = "nll/resource-catalog-preflight/v1",
    statusCode = "blocked",
    failureCode = code,
    roleCode = currentRole,
    sourceMutationPerformed = false,
    officialOutboundPerformed = false
  }, options));
  return 10;
}

static Sha256Digest Digest(string path)
{
  using var stream = File.OpenRead(path);
  return Sha256Digest.Parse(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream)).ToLowerInvariant());
}

static string SafePath(string root, string relative)
{
  if (Path.IsPathRooted(relative) || relative.Contains(':') || relative.Contains('%') ||
      relative.Replace('\\', '/').Split('/').Any(part => part is ".." or "." or ""))
    throw new PreflightException("resource_path_invalid");
  var path = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
  var boundary = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
  if (!path.StartsWith(boundary, StringComparison.OrdinalIgnoreCase))
    throw new PreflightException("resource_path_escaped_root");
  // The declared root may be the approved shared cache junction. Descendant
  // reparse points are not accepted as an implicit second source root.
  var partPath = Path.GetFullPath(root);
  foreach (var part in relative.Replace('\\', '/').Split('/'))
  {
    partPath = Path.Combine(partPath, part);
    if ((File.Exists(partPath) || Directory.Exists(partPath)) &&
        (File.GetAttributes(partPath) & FileAttributes.ReparsePoint) != 0)
      throw new PreflightException("resource_path_reparse_point");
  }
  return path;
}
