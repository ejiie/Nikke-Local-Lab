param(
    [Parameter(Mandatory = $true)]
    [string]$ObservationSetPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Test-UtcSecondInstant {
    param([string]$Value)
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot, [string]$FailureCode)
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $repository = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $repository + [System.IO.Path]::DirectorySeparatorChar
    Assert-True (-not $candidate.Equals($repository, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) $FailureCode
}

function Assert-NoReparsePoint {
    param([string]$Path, [string]$FailureCode)
    $current = Get-Item -LiteralPath $Path -Force
    while ($null -ne $current) {
        Assert-True (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) $FailureCode
        $current = $current.Parent
    }
}

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $forbiddenNames = @(
            "accountId", "assetId", "assetName", "backupPath", "certificatePath", "characterId",
            "decodedValue", "executablePath", "fileName", "filePath", "fullPath", "gameRoot",
            "localPath", "managerId", "managerName", "memberName", "modelId", "monsterId",
            "monsterName", "originalId", "originalPath", "partId", "presetId", "raidId", "rawId",
            "rawIdentifier", "rawValue", "sourceId", "sourcePath", "spotId", "stageId", "statId",
            "userId", "waveId"
        )
        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b2_seal_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) "phase3b2_seal_forbidden_evidence_property"
            Assert-SafeJsonElement $property.Value
        }
        return
    }
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) { Assert-SafeJsonElement $item }
        return
    }
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        Assert-True ($value -notmatch '^[A-Za-z]:[\\/]' -and
            -not $value.StartsWith('\\', [System.StringComparison]::Ordinal) -and
            -not $value.StartsWith('//', [System.StringComparison]::Ordinal) -and
            $value -notmatch '^/(home|mnt|private|root|tmp|Users|var)/' -and
            -not $value.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) "phase3b2_seal_local_path_value_exposed"
    }
}

function Write-CanonicalJsonElement {
    param([System.Text.Json.JsonElement]$Element, [System.Text.Json.Utf8JsonWriter]$Writer)
    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($property in $Element.EnumerateObject()) { $names.Add($property.Name) }
            $names.Sort([System.StringComparer]::Ordinal)
            $Writer.WriteStartObject()
            foreach ($name in $names) {
                $Writer.WritePropertyName($name)
                Write-CanonicalJsonElement $Element.GetProperty($name) $Writer
            }
            $Writer.WriteEndObject()
            break
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) { Write-CanonicalJsonElement $item $Writer }
            $Writer.WriteEndArray()
            break
        }
        ([System.Text.Json.JsonValueKind]::String) { $Writer.WriteStringValue($Element.GetString()); break }
        ([System.Text.Json.JsonValueKind]::Number) {
            $integer = [long]0
            $decimal = [decimal]0
            if ($Element.TryGetInt64([ref]$integer)) { $Writer.WriteNumberValue($integer) }
            elseif ($Element.TryGetDecimal([ref]$decimal)) { $Writer.WriteNumberValue($decimal) }
            else { throw "phase3b2_seal_noncanonical_observation_number" }
            break
        }
        ([System.Text.Json.JsonValueKind]::True) { $Writer.WriteBooleanValue($true); break }
        ([System.Text.Json.JsonValueKind]::False) { $Writer.WriteBooleanValue($false); break }
        ([System.Text.Json.JsonValueKind]::Null) { $Writer.WriteNullValue(); break }
        default { throw "phase3b2_seal_unsupported_observation_json_kind" }
    }
}

function Get-CanonicalObservationManifest {
    param([System.Text.Json.JsonElement]$ObservationSetRoot)
    $members = @($ObservationSetRoot.GetProperty("observations").EnumerateArray())
    $ordered = @($members | Sort-Object { $_.GetProperty("ordinal").GetInt32() })
    $ordinals = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($member in $ordered) {
        Assert-True ($ordinals.Add($member.GetProperty("ordinal").GetInt32())) "phase3b2_seal_duplicate_observation_ordinal"
    }
    $stream = [System.IO.MemoryStream]::new()
    try {
        foreach ($member in $ordered) {
            $memberStream = [System.IO.MemoryStream]::new()
            try {
                $writer = [System.Text.Json.Utf8JsonWriter]::new($memberStream, [System.Text.Json.JsonWriterOptions]@{ Indented = $false })
                try { Write-CanonicalJsonElement $member $writer; $writer.Flush() }
                finally { $writer.Dispose() }
                $bytes = $memberStream.ToArray()
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.WriteByte(0x0A)
            }
            finally { $memberStream.Dispose() }
        }
        $canonicalBytes = $stream.ToArray()
        return [pscustomobject]@{
            MemberCount = $ordered.Count
            ByteLength = $canonicalBytes.Length
            Sha256 = Get-Sha256Hex $canonicalBytes
        }
    }
    finally { $stream.Dispose() }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory ".."))
$observationSchemaPath = Join-Path $repositoryRoot "contracts/season26-classic-live-preflight-observation-set.schema.json"
$receiptSchemaPath = Join-Path $repositoryRoot "contracts/season26-classic-live-preflight.schema.json"
$verifierPath = Join-Path $scriptDirectory "verify-phase3b2.ps1"
$inputFullPath = [System.IO.Path]::GetFullPath($ObservationSetPath)
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)

Assert-OutsideRepository $inputFullPath $repositoryRoot "phase3b2_seal_observation_set_must_be_external"
Assert-OutsideRepository $outputFullPath $repositoryRoot "phase3b2_seal_output_must_be_external"
Assert-True (-not $inputFullPath.Equals($outputFullPath, [System.StringComparison]::OrdinalIgnoreCase)) "phase3b2_seal_input_output_collision"
Assert-True (Test-Path -LiteralPath $inputFullPath -PathType Leaf) "phase3b2_seal_observation_set_missing"
Assert-NoReparsePoint $inputFullPath "phase3b2_seal_observation_set_reparse_forbidden"
Assert-True (-not (Test-Path -LiteralPath $outputFullPath)) "phase3b2_seal_output_already_exists"
$outputDirectory = Split-Path -Parent $outputFullPath
Assert-True (Test-Path -LiteralPath $outputDirectory -PathType Container) "phase3b2_seal_output_directory_missing"
Assert-NoReparsePoint $outputDirectory "phase3b2_seal_output_directory_reparse_forbidden"
Assert-True (Test-Path -LiteralPath $observationSchemaPath -PathType Leaf) "phase3b2_seal_observation_schema_missing"
Assert-True (Test-Path -LiteralPath $receiptSchemaPath -PathType Leaf) "phase3b2_seal_receipt_schema_missing"

$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$observationText = [System.IO.File]::ReadAllText($inputFullPath, $utf8)
Assert-True (Test-Json -Json $observationText -SchemaFile $observationSchemaPath -ErrorAction SilentlyContinue) "phase3b2_seal_observation_schema_invalid"
$document = [System.Text.Json.JsonDocument]::Parse($observationText)
$temporaryPath = Join-Path $outputDirectory ((Split-Path -Leaf $outputFullPath) + ".tmp." + [Guid]::NewGuid().ToString("N"))
try {
    $root = $document.RootElement
    Assert-SafeJsonElement $root
    Assert-True (Test-UtcSecondInstant $root.GetProperty("observedAtUtc").GetString()) "phase3b2_seal_observed_at_invalid"
    $computed = Get-CanonicalObservationManifest $root
    $declared = $root.GetProperty("canonicalManifest")
    Assert-True ($computed.MemberCount -eq $root.GetProperty("observationCount").GetInt32() -and
        $computed.MemberCount -eq $declared.GetProperty("memberCount").GetInt32() -and
        $computed.ByteLength -eq $declared.GetProperty("canonicalByteLength").GetInt32() -and
        $computed.Sha256 -ceq $declared.GetProperty("sha256").GetString()) "phase3b2_seal_observation_manifest_mismatch"

    $input = $observationText | ConvertFrom-Json -Depth 100
    $byRole = @{}
    foreach ($observation in $input.observations) { $byRole[[string]$observation.roleCode] = $observation }
    $environment = $byRole["disposable_environment"]
    $primaryInstall = $byRole["primary_install"]
    $clientBuild = $byRole["client_build_content"]
    $externalBuild = $byRole["external_lineage_build"]
    $syntheticIdentity = $byRole["synthetic_identity"]
    $egress = $byRole["process_tree_egress"]
    $mutation = $byRole["mutation_backup_rollback"]
    $manifest = [ordered]@{
        contractId = "nll/season26-classic-live-preflight-observation-set/v1"
        canonicalizationCode = "role_ordered_ordinal_json_members_lf_v1"
        memberCount = $computed.MemberCount
        canonicalByteLength = $computed.ByteLength
        sha256 = $computed.Sha256
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = "nll/season26-classic-live-preflight/v1"
        assessmentUid = $root.GetProperty("assessmentUid").GetString()
        assessedAtUtc = $root.GetProperty("observedAtUtc").GetString()
        verdict = "ready_to_start_isolated_season26_reference_run"
        target = [ordered]@{ clientBuildVersion = $clientBuild.clientBuildVersion; seasonNumber = 26; modeCode = "classic_solo_raid_challenge"; wireModeCode = "trial"; challengeRaidLevel = 8; museumAllowed = $false; fallbackPolicyCode = "none" }
        externalLineage = [ordered]@{ repositoryCode = "epinelps_epinelps"; licenseCode = "agpl-3.0-only"; sourceBoundaryCode = "external_agpl_checkout"; upstreamBaseCommitSha = $externalBuild.upstreamBaseCommitSha; selectedManagerIntegrationCommitSha = $externalBuild.selectedManagerIntegrationCommitSha; preflightSealCommitSha = $externalBuild.preflightSealCommitSha; preflightHardeningCommitSha = $externalBuild.preflightHardeningCommitSha; latestExternalTreeCommitSha = $externalBuild.latestExternalTreeCommitSha }
        environment = [ordered]@{ environmentKindCode = $environment.environmentKindCode; snapshotStatusCode = if ($environment.snapshotRestoreReady) { "ready" } else { "violation" }; systemTrustIsolationStatusCode = "disposable_environment_only"; primaryInstallIntegrityStatusCode = $primaryInstall.statusCode; syntheticLocalAccountOnly = $syntheticIdentity.syntheticLocalAccountOnly; officialAccountMaterialPresent = $syntheticIdentity.officialAccountMaterialPresent; clientExecutionStarted = $primaryInstall.executionStarted }
        runtimeInputs = [ordered]@{ clientBuildStatusCode = $clientBuild.statusCode; externalLineageStatusCode = $externalBuild.statusCode; reviewedRuntimeInputStatusCode = "exact"; reviewedRuntimeInputExpectedMemberCount = 4; reviewedRuntimeInputObservedMemberCount = 4; canonicalManifest = $manifest }
        networkIsolation = [ordered]@{ processTreeScopeStatusCode = $egress.processTreeScopeStatusCode; loopbackBindStatusCode = "exact_127_0_0_1"; nonLoopbackEgressStatusCode = if ($egress.nonLoopbackAttemptCount -eq 0 -and $egress.nonLoopbackSuccessfulConnectionCount -eq 0) { "blocked" } else { "violation" }; coversIpv4 = $egress.coversIpv4; coversIpv6 = $egress.coversIpv6; coversDns = $egress.coversDns; coversTcp = $egress.coversTcp; coversUdp = $egress.coversUdp; canonicalManifest = $manifest }
        mutationRollback = [ordered]@{ statusCode = "prepared"; systemHostsStatusCode = $mutation.systemHosts.statusCode; rootCaStatusCode = $mutation.rootCa.statusCode; clientCertificateBundleStatusCode = $mutation.clientCertificateBundle.statusCode; nativeCompatibilityShimStatusCode = $mutation.nativeCompatibilityShim.statusCode; canonicalManifest = $manifest }
        prohibitedMaterial = $input.prohibitedMaterial
        measuredEvidence = [ordered]@{ statusCode = "measured_complete"; observationCount = $computed.MemberCount; canonicalManifest = $manifest }
        remainingBoundary = [ordered]@{ referenceRunExecuted = $false; originalClientBattleStarted = $false; originalClientResultVerified = $false; localLabShadowBridgeVerified = $false; phase3cVerified = $false; phase3dVerified = $false; phase4Verified = $false; nextPhaseCode = "phase3b2_isolated_season26_reference_run" }
        blockingReasonCodes = @()
        nextStepRequirementCodes = @("start_exact_bound_reference_run_once", "preserve_assessment_pins_until_client_start", "do_not_restart_or_restore_before_reference_run")
    }
    $receiptText = $receipt | ConvertTo-Json -Depth 100
    Assert-True (Test-Json -Json $receiptText -SchemaFile $receiptSchemaPath -ErrorAction SilentlyContinue) "phase3b2_seal_receipt_schema_invalid"
    $receiptDocument = [System.Text.Json.JsonDocument]::Parse($receiptText)
    try { Assert-SafeJsonElement $receiptDocument.RootElement }
    finally { $receiptDocument.Dispose() }

    [System.IO.File]::WriteAllText($temporaryPath, $receiptText + "`n", $utf8)
    & pwsh -NoProfile -File $verifierPath -ContractOnly -LocalObservationSetPath $inputFullPath -LocalPreflightAssessmentPath $temporaryPath
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_seal_verifier_rejected_candidate"
    [System.IO.File]::Move($temporaryPath, $outputFullPath)
    Write-Output "Phase 3B-2 source-free preflight candidate sealed and verified outside the repository; no server or client was launched."
}
finally {
    $document.Dispose()
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
}
