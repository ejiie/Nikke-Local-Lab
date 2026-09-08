[CmdletBinding()]
param(
    [ValidatePattern("^[A-Za-z0-9+/]+={0,2}$")]
    [string]$ProjectionBase64,

    [string]$ProjectionTranscriptPath,

    [string]$OutputRoot = "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv",
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [ValidateSet("disconnected", "private_vm_only_no_gateway")]
    [string]$NetworkModeCode = "disconnected",
    [ValidateSet("official_launcher", "source_built_sail_abi_local_bootstrap")]
    [string]$ClientBootstrapModeCode = "official_launcher",
    [string]$CheckpointReceiptPath,
    [string]$PrimaryPostReceiptPath = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\PrimaryPost\primary-post-verification.receipt.json",
    [string]$TransferReceiptPath
)

$ErrorActionPreference = "Stop"
$useLocalBootstrap = $NetworkModeCode -ceq "private_vm_only_no_gateway" -and
    $ClientBootstrapModeCode -ceq "source_built_sail_abi_local_bootstrap"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-FileDigest {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "phase3b2_hyperv_observation_host_evidence_missing"
    return [pscustomobject]@{
        byteLength = (Get-Item -LiteralPath $Path).Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-DigestShape {
    param([object]$Digest, [string]$FailureCode)
    Assert-True ($null -ne $Digest -and [long]$Digest.byteLength -ge 0 -and
        [string]$Digest.sha256 -cmatch '^[0-9a-f]{64}$') $FailureCode
}

function Copy-Digest {
    param([object]$Value)
    Assert-DigestShape $Value "phase3b2_hyperv_observation_digest_invalid"
    return [ordered]@{ byteLength = [long]$Value.byteLength; sha256 = [string]$Value.sha256 }
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot, [string]$FailureCode)
    $candidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    Assert-True (-not $candidate.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) $FailureCode
}

function Assert-NoReparsePoint {
    param([string]$Path, [string]$FailureCode)
    $current = Get-Item -LiteralPath $Path -Force
    while ($null -ne $current) {
        Assert-True (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) $FailureCode
        $current = $current.Parent
    }
}

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $forbiddenNames = @(
            "accountId", "assetId", "assetName", "backupPath", "certificatePath", "characterId",
            "decodedValue", "executablePath", "fileName", "filePath", "fullPath", "gameRoot",
            "localPath", "managerId", "managerName", "memberName", "modelId", "monsterId",
            "monsterName", "originalId", "originalPath", "partId", "presetId", "raidId", "rawId",
            "rawIdentifier", "rawValue", "sourceId", "sourcePath", "spotId", "stageId", "statId",
            "userId", "waveId"
        )
        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b2_hyperv_observation_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) `
                "phase3b2_hyperv_observation_forbidden_evidence_property"
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
            -not $value.StartsWith('\\', [StringComparison]::Ordinal) -and
            -not $value.StartsWith('//', [StringComparison]::Ordinal) -and
            $value -notmatch '^/(home|mnt|private|root|tmp|Users|var)/' -and
            -not $value.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) `
            "phase3b2_hyperv_observation_local_path_value_exposed"
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Write-CanonicalJsonElement {
    param([System.Text.Json.JsonElement]$Element, [System.Text.Json.Utf8JsonWriter]$Writer)
    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $names = [Collections.Generic.List[string]]::new()
            foreach ($property in $Element.EnumerateObject()) { $names.Add($property.Name) }
            $names.Sort([StringComparer]::Ordinal)
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
            else { throw "phase3b2_hyperv_observation_noncanonical_number" }
            break
        }
        ([System.Text.Json.JsonValueKind]::True) { $Writer.WriteBooleanValue($true); break }
        ([System.Text.Json.JsonValueKind]::False) { $Writer.WriteBooleanValue($false); break }
        ([System.Text.Json.JsonValueKind]::Null) { $Writer.WriteNullValue(); break }
        default { throw "phase3b2_hyperv_observation_unsupported_json_kind" }
    }
}

if ([string]::IsNullOrEmpty($CheckpointReceiptPath)) {
    $CheckpointReceiptPath = if ($NetworkModeCode -ceq "disconnected") {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\p0-isolated-checkpoint-v3.json"
    } elseif ($useLocalBootstrap) {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\p0-private-local-bootstrap-checkpoint-v1.json"
    } else {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\p0-private-sqlite-reset-checkpoint-v1.json"
    }
}
if ([string]::IsNullOrEmpty($TransferReceiptPath)) {
    $TransferReceiptPath = if ($NetworkModeCode -ceq "disconnected") {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\ready-projection-tool-transfer.receipt.json"
    } elseif ($useLocalBootstrap) {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\local-bootstrap-run-tool-transfer-v1.receipt.json"
    } else {
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\sqlite-rebootstrap-run-tool-transfer-v1.receipt.json"
    }
}

function Get-CanonicalObservationManifest {
    param([object[]]$Observations)
    $json = $Observations | ConvertTo-Json -Depth 100 -Compress
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($member in @($document.RootElement.EnumerateArray()) |
                Sort-Object { $_.GetProperty("ordinal").GetInt32() }) {
            $memberStream = [IO.MemoryStream]::new()
            try {
                $writer = [System.Text.Json.Utf8JsonWriter]::new(
                    $memberStream, [System.Text.Json.JsonWriterOptions]@{ Indented = $false })
                try { Write-CanonicalJsonElement $member $writer; $writer.Flush() }
                finally { $writer.Dispose() }
                $bytes = $memberStream.ToArray()
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.WriteByte(0x0A)
            }
            finally { $memberStream.Dispose() }
        }
        $canonical = $stream.ToArray()
        return [pscustomobject]@{
            MemberCount = $Observations.Count
            ByteLength = $canonical.Length
            Sha256 = Get-Sha256Hex $canonical
        }
    }
    finally {
        $stream.Dispose()
        $document.Dispose()
    }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $scriptDirectory ".."))
$outputRootFullPath = [IO.Path]::GetFullPath($OutputRoot)
Assert-OutsideRepository $outputRootFullPath $repositoryRoot `
    "phase3b2_hyperv_observation_output_inside_repository"
$outputParent = Split-Path -Parent $outputRootFullPath
Assert-True (Test-Path -LiteralPath $outputParent -PathType Container) `
    "phase3b2_hyperv_observation_output_parent_missing"
Assert-NoReparsePoint $outputParent "phase3b2_hyperv_observation_output_parent_reparse_forbidden"

$utf8 = [Text.UTF8Encoding]::new($false, $true)
Assert-True (([string]::IsNullOrEmpty($ProjectionBase64) -xor
        [string]::IsNullOrEmpty($ProjectionTranscriptPath))) `
    "phase3b2_hyperv_observation_projection_input_shape_invalid"
if (-not [string]::IsNullOrEmpty($ProjectionBase64)) {
    try { $projectionText = $utf8.GetString([Convert]::FromBase64String($ProjectionBase64)) }
    catch { throw "phase3b2_hyperv_observation_projection_base64_invalid" }
}
else {
    $transcriptFullPath = [IO.Path]::GetFullPath($ProjectionTranscriptPath)
    Assert-OutsideRepository $transcriptFullPath $repositoryRoot `
        "phase3b2_hyperv_observation_projection_transcript_inside_repository"
    Assert-True (Test-Path -LiteralPath $transcriptFullPath -PathType Leaf) `
        "phase3b2_hyperv_observation_projection_transcript_missing"
    Assert-NoReparsePoint $transcriptFullPath `
        "phase3b2_hyperv_observation_projection_transcript_reparse_forbidden"
    $transcript = [IO.File]::ReadAllText($transcriptFullPath, $utf8)
    $jsonStart = $transcript.IndexOf('{')
    $jsonEnd = $transcript.LastIndexOf('}')
    Assert-True ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) `
        "phase3b2_hyperv_observation_projection_json_not_found"
    $projectionText = $transcript.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
}
$projectionDocument = [System.Text.Json.JsonDocument]::Parse($projectionText)
try { Assert-SafeJsonElement $projectionDocument.RootElement }
finally { $projectionDocument.Dispose() }
$projection = $projectionText | ConvertFrom-Json -Depth 100 -DateKind String

Assert-True ($projection.schemaVersion -eq 1 -and
    $projection.contractId -ceq "nll/phase3b2-hyperv-ready-projection/v1" -and
    $projection.assessmentUid -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and
    $projection.observedAtUtc -cmatch $(if ($NetworkModeCode -ceq "disconnected") {
        '^2026-08-21T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    } else {
        '^2026-08-22T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
    }) -and
    $projection.clientBuildVersion -ceq "150.6.9" -and
    $projection.networkModeCode -ceq $NetworkModeCode -and
    $projection.clientBootstrapModeCode -ceq $ClientBootstrapModeCode -and
    -not $projection.clientExecutionStarted -and $projection.serverRunning) `
    "phase3b2_hyperv_observation_projection_header_invalid"
Assert-DigestShape $projection.checkpointReceipt "phase3b2_hyperv_observation_checkpoint_digest_invalid"
Assert-DigestShape $projection.primaryManifest "phase3b2_hyperv_observation_primary_digest_invalid"
Assert-DigestShape $projection.clientManifest "phase3b2_hyperv_observation_client_digest_invalid"
Assert-True ($(if ($NetworkModeCode -ceq "disconnected") {
        $projection.checkpointReceipt.byteLength -eq 1178 -and
        $projection.checkpointReceipt.sha256 -ceq
            "cbe57b9a5914a9c8fe3fee31f7140fe8d2f58e1e07ae9c7c7a3260b5c2b5210d"
    } else {
        [long]$projection.checkpointReceipt.byteLength -gt 0 -and
        [string]$projection.checkpointReceipt.sha256 -cmatch '^[0-9a-f]{64}$'
    }) -and
    $projection.primaryManifest.byteLength -eq 5397209 -and
    $projection.primaryManifest.sha256 -ceq "0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4" -and
    $projection.clientManifest.byteLength -eq 5397209 -and
    $projection.clientManifest.sha256 -ceq "0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4") `
    "phase3b2_hyperv_observation_environment_or_client_pin_mismatch"

$external = $projection.externalBuild
Assert-True ($external.latestExternalCommitSha -ceq "519c3db51ec24ca19307e93e85acde7885928a72" -and
    $external.latestExternalTreeCommitSha -ceq "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    $external.checkoutClean -and $external.dotnetSdkVersion -ceq "10.0.400" -and
    $external.selectedManagerPassedCount -eq 64 -and $external.handlerIsolationPassedCount -eq 5 -and
    $external.focusedTestFailedCount -eq 0 -and -not $external.localOnlyHttp3Enabled -and
    -not $external.localOnlyAssetCachePathLoggingEnabled) `
    "phase3b2_hyperv_observation_external_pin_mismatch"
Assert-True ($external.toolchainObservation.byteLength -eq 153 -and
    $external.toolchainObservation.sha256 -ceq "daa6ca1e91612ff2e506c2d4ff26b7b8db8b091ac72d8e62f9c1a0c0850ce31a" -and
    $external.buildArtifactObservation.byteLength -eq 63629 -and
    $external.buildArtifactObservation.sha256 -ceq "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37" -and
    $external.focusedTestObservation.byteLength -eq 142 -and
    $external.focusedTestObservation.sha256 -ceq "a4481b79e394d3d7f1a0ce1eec636c62258cb07aea48c281318a689cfd83d7bd") `
    "phase3b2_hyperv_observation_external_evidence_mismatch"

$inputByRole = @{}
foreach ($input in @($projection.runtimeInputs)) {
    Assert-True ($inputByRole.Count -lt 5 -and -not $inputByRole.ContainsKey([string]$input.roleCode)) `
        "phase3b2_hyperv_observation_runtime_input_duplicate"
    Assert-DigestShape $input.digest "phase3b2_hyperv_observation_runtime_input_digest_invalid"
    $inputByRole[[string]$input.roleCode] = $input.digest
}
$runtimePins = [ordered]@{
    runtime_pack_staticdata = [pscustomobject]@{ byteLength = 17177168; sha256 = "8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3" }
    locale_bgm = [pscustomobject]@{ byteLength = 25498; sha256 = "069143db0a70be3947d8bb68ff19a4815efbd3a35fc00401bd0bf93d460fd925" }
    locale_character = [pscustomobject]@{ byteLength = 5023222; sha256 = "d50727f15317fb09ab7c4bab2eed8f4083efc4cbd9880269d95f2e2b21bc7013" }
    locale_costume = [pscustomobject]@{ byteLength = 67547; sha256 = "3284a10c92890491e6b138a9c54c9e47d6816413f7e44493d10410b0a90cffa0" }
    locale_item = [pscustomobject]@{ byteLength = 1193697; sha256 = "e149ac84c9ddf9b428183d4f4ff4d99edc3f665d1ee38b3adccd0e0fa50330ff" }
}
Assert-True ($inputByRole.Count -eq 5) "phase3b2_hyperv_observation_runtime_input_count_mismatch"
foreach ($role in $runtimePins.Keys) {
    Assert-True ($null -ne $inputByRole[$role] -and
        $inputByRole[$role].byteLength -eq $runtimePins[$role].byteLength -and
        $inputByRole[$role].sha256 -ceq $runtimePins[$role].sha256) `
        "phase3b2_hyperv_observation_runtime_input_pin_mismatch"
}

foreach ($digest in @(
        $projection.syntheticIdentityObservation, $projection.networkObservation,
        $projection.localOnlyConfigObservation, $projection.listenerObservation,
        $projection.bootstrapObservation, $projection.activeStateObservation,
        $projection.logSafetyObservation, $projection.processTreeObservation)) {
    Assert-DigestShape $digest "phase3b2_hyperv_observation_measured_digest_invalid"
}
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-DigestShape $projection.p0Observation `
        "phase3b2_hyperv_observation_p0_digest_invalid"
    Assert-DigestShape $projection.profileAdapterBuildObservation `
        "phase3b2_hyperv_observation_profile_adapter_digest_invalid"
}
foreach ($mutationName in @("systemHosts", "rootCa", "clientCertificateBundle", "nativeCompatibilityShim")) {
    $mutation = $projection.mutations.$mutationName
    foreach ($stateName in @("beforeState", "appliedState", "backupState", "rollbackPlan")) {
        Assert-DigestShape $mutation.$stateName "phase3b2_hyperv_observation_mutation_digest_invalid"
    }
}
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-True ($projection.mutations.clientCertificateBundle.beforeState.byteLength -eq 292 -and
        $projection.mutations.clientCertificateBundle.beforeState.sha256 -ceq
            "7719ff22ad7de2602d84a37abe30365036a8e480b6460da3432b78b661631acc" -and
        $projection.mutations.clientCertificateBundle.appliedState.byteLength -eq 293 -and
        $projection.mutations.clientCertificateBundle.appliedState.sha256 -ceq
            "2e215ad2327c7550e41d0f755e0829bb9ef28e715c9c0ce32b0c08e0d8ddc054" -and
        $projection.mutations.clientCertificateBundle.backupState.byteLength -eq 275 -and
        $projection.mutations.clientCertificateBundle.backupState.sha256 -ceq
            "3b64f8160eaa7e18a51cf3be54b835b305e7051ce12c06a8ba4fb078380158f3" -and
        $(if ($useLocalBootstrap) {
            [long]$projection.mutations.clientCertificateBundle.rollbackPlan.byteLength -gt 0 -and
            [string]$projection.mutations.clientCertificateBundle.rollbackPlan.sha256 -cmatch
                '^[0-9a-f]{64}$'
        } else {
            $projection.mutations.clientCertificateBundle.rollbackPlan.byteLength -eq 3292 -and
            $projection.mutations.clientCertificateBundle.rollbackPlan.sha256 -ceq
                "823af896da3b0d83fa67e7f38d660edbc7b06a2d23ff8cde8042abdfcea12a7f"
        })) `
        "phase3b2_hyperv_observation_client_certificate_set_mismatch"
}
$facts = $projection.measuredFacts
Assert-True ($facts.httpIpv4LoopbackListenerCount -eq 1 -and
    $facts.httpsIpv4LoopbackListenerCount -eq 1 -and $facts.http3UdpListenerCount -eq 0 -and
    $facts.wildcardListenerCount -eq 0 -and $facts.lanListenerCount -eq 0 -and
    $facts.unexpectedListenerCount -eq 0 -and $facts.nonLoopbackAttemptCount -eq 0 -and
    $facts.nonLoopbackSuccessfulConnectionCount -eq 0 -and $facts.processTreeMemberCount -eq 1 -and
    $facts.selectionObservedNoLaterThanListener -and $facts.selectionRuntimeMutationCount -eq 0 -and
    $facts.latestFallbackCount -eq 0 -and $facts.activeRunCount -eq 0 -and
    $facts.rawSensitiveLogMatchCount -eq 0 -and -not $facts.officialIdentityPersisted -and
    -not $facts.officialCredentialPersisted -and -not $facts.credentialBearingGuestCopyPresent -and
    $facts.systemNetworkAvailable -eq ($NetworkModeCode -ceq "private_vm_only_no_gateway") -and
    $facts.upPhysicalNetworkAdapterCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $facts.networkProfileCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $facts.ipv4DefaultRouteCount -eq 0 -and $facts.ipv6DefaultRouteCount -eq 0) `
    "phase3b2_hyperv_observation_measured_fact_mismatch"

$checkpointDigest = Get-FileDigest $CheckpointReceiptPath
Assert-True ($checkpointDigest.byteLength -eq $projection.checkpointReceipt.byteLength -and
    $checkpointDigest.sha256 -ceq $projection.checkpointReceipt.sha256) `
    "phase3b2_hyperv_observation_checkpoint_receipt_drift"
$checkpoint = Get-Content -LiteralPath $CheckpointReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($checkpoint.contractId -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-p0-isolated-checkpoint/v3"
    } elseif ($useLocalBootstrap) {
        "nll/phase3b2-p0-private-local-bootstrap-checkpoint/v1"
    } else {
        "nll/phase3b2-p0-private-sqlite-credential-checkpoint/v1"
    }) -and
    $checkpoint.environmentKindCode -ceq "snapshot_capable_disposable_vm" -and
    $checkpoint.checkpointTypeCode -ceq "standard" -and
    $checkpoint.currentCheckpointCount -eq $(if ($NetworkModeCode -ceq "disconnected") {
        5
    } elseif ($useLocalBootstrap) { 10 } else { 9 }) -and
    $checkpoint.clientBuild -ceq "150.6.9" -and
    $checkpoint.externalHead -ceq $external.latestExternalCommitSha -and
    $checkpoint.externalTree -ceq $external.latestExternalTreeCommitSha -and
    $checkpoint.externalBuildManifestSha256 -ceq $external.buildArtifactObservation.sha256 -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $checkpoint.connectedSwitchCount -eq 0
    } elseif ($useLocalBootstrap) {
        $checkpoint.networkModeCode -ceq "private_vm_only_no_gateway" -and
        $checkpoint.switchTypeCode -ceq "private_vm_only" -and
        $checkpoint.connectedVmAdapterCount -eq 1 -and
        -not $checkpoint.hostVirtualAdapterPresent -and
        $checkpoint.parentCheckpointIdentitySha256 -ceq
            "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80" -and
        $checkpoint.guestP0V5ReceiptByteLength -eq
            $projection.p0Observation.byteLength -and
        $checkpoint.guestP0V5ReceiptSha256 -ceq
            $projection.p0Observation.sha256 -and
        $checkpoint.clientBootstrapModeCode -ceq
            "source_built_sail_abi_local_bootstrap" -and
        [bool]$checkpoint.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$checkpoint.sqliteCredentialBindingVerified -and
        [int]$checkpoint.sqliteRuntimeMemberCount -eq 0
    } else {
        $checkpoint.networkModeCode -ceq "private_vm_only_no_gateway" -and
        $checkpoint.switchTypeCode -ceq "private_vm_only" -and
        $checkpoint.connectedVmAdapterCount -eq 1 -and -not $checkpoint.hostVirtualAdapterPresent -and
        $checkpoint.parentCheckpointIdentitySha256 -ceq
            "80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2" -and
        $checkpoint.guestP0V4ReceiptByteLength -eq
            $projection.p0Observation.byteLength -and
        $checkpoint.guestP0V4ReceiptSha256 -ceq
            $projection.p0Observation.sha256 -and
        [bool]$checkpoint.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$checkpoint.sqliteCredentialBindingVerified -and
        [int]$checkpoint.sqliteRuntimeMemberCount -eq 0
    }) -and -not $checkpoint.guestServiceEnabled -and
    -not $checkpoint.credentialBearingGuestCopyPresent -and -not $checkpoint.clientExecutionStarted) `
    "phase3b2_hyperv_observation_checkpoint_receipt_invalid"

$primaryDigest = Get-FileDigest $PrimaryPostReceiptPath
Assert-True ($primaryDigest.byteLength -eq 459 -and
    $primaryDigest.sha256 -ceq "b04d3351ecac55819aad3d66adae46785787df1a83db639320a58900fceca2ab") `
    "phase3b2_hyperv_observation_primary_post_receipt_drift"
$primaryPost = Get-Content -LiteralPath $PrimaryPostReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($primaryPost.contractId -ceq "nll/phase3b2-host-primary-post-verification/v1" -and
    $primaryPost.primaryInstallIntegrityStatusCode -ceq "unchanged" -and
    $primaryPost.fileCount -eq 38670 -and $primaryPost.beforeManifestByteLength -eq 5397209 -and
    $primaryPost.afterManifestByteLength -eq 5397209 -and
    $primaryPost.beforeManifestSha256 -ceq $projection.primaryManifest.sha256 -and
    $primaryPost.afterManifestSha256 -ceq $projection.primaryManifest.sha256) `
    "phase3b2_hyperv_observation_primary_post_invalid"

$transferDigest = Get-FileDigest $TransferReceiptPath
$transfer = Get-Content -LiteralPath $TransferReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($transfer.contractId -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-ready-projection-tool-transfer/v1"
    } elseif ($useLocalBootstrap) {
        "nll/phase3b2-local-bootstrap-run-tool-transfer/v1"
    } else {
        "nll/phase3b2-sqlite-rebootstrap-run-tool-transfer/v1"
    }) -and $transfer.transferredMemberCount -eq $(if ($NetworkModeCode -ceq "disconnected") {
        1
    } elseif ($useLocalBootstrap) {
        [int]$transfer.transferredMemberCount
    } else {
        3
    }) -and $(if ($useLocalBootstrap) {
        [int]$transfer.transferredMemberCount -ge 8
    } else { $true }) -and $transfer.vmRunning -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $transfer.connectedSwitchCount -eq 0
    } else {
        $transfer.networkModeCode -ceq "private_vm_only_no_gateway" -and
        $transfer.switchTypeCode -ceq "private_vm_only" -and
        $transfer.connectedVmAdapterCount -eq 1
    }) -and -not $transfer.guestServiceEnabled -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $transfer.serverExecutionStateCode -ceq "preserved_running_unobserved_by_host"
    } elseif ($useLocalBootstrap) {
        $transfer.runtimeExecutionStateCode -ceq
            "local_bootstrap_artifacts_and_tools_staged_client_cold" -and
        -not $transfer.serverExecutionStarted
    } else {
        $transfer.runtimeExecutionStateCode -ceq "sqlite_reset_prepared_client_cold" -and
        -not $transfer.serverExecutionStarted
    }) -and
    -not $transfer.clientExecutionStarted) "phase3b2_hyperv_observation_transfer_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$privateSwitch = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-VMSwitch -Name $SwitchName -ErrorAction Stop
} else { $null }
$switchMembers = if ($null -ne $privateSwitch) {
    @(Get-VM | Get-VMNetworkAdapter | Where-Object SwitchName -CEQ $SwitchName)
} else { @() }
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $adapters.Count -eq 1 -and $(if ($NetworkModeCode -ceq "disconnected") {
        $null -eq $adapters[0].SwitchName
    } else {
        $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
        $adapters[0].SwitchName -ceq $SwitchName -and $switchMembers.Count -eq 1 -and
        [string]$switchMembers[0].VMId -ceq [string]$vm.Id
    }) -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_hyperv_observation_host_isolation_continuity_lost"

$templatePath = Join-Path $repositoryRoot `
    "tests/fixtures/synthetic/season26-classic-live-preflight-observation-set.valid.json"
$document = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 100
$document.assessmentUid = [string]$projection.assessmentUid
$document.observedAtUtc = [string]$projection.observedAtUtc
$members = @($document.observations)
$members[0].environmentKindCode = "snapshot_capable_disposable_vm"
$members[0].resetIdentity = Copy-Digest $projection.checkpointReceipt
$members[1].beforeState = Copy-Digest $projection.primaryManifest
$members[2].contentSet = Copy-Digest $projection.clientManifest
$members[3].toolchainObservation = Copy-Digest $external.toolchainObservation
$members[3].buildArtifactObservation = Copy-Digest $external.buildArtifactObservation
$members[3].focusedTestObservation = Copy-Digest $external.focusedTestObservation
$members[4].byteLength = [long]$inputByRole["runtime_pack_staticdata"].byteLength
$members[4].sha256 = [string]$inputByRole["runtime_pack_staticdata"].sha256
$members[5].byteLength = [long]$inputByRole["locale_bgm"].byteLength
$members[5].sha256 = [string]$inputByRole["locale_bgm"].sha256
$members[6].byteLength = [long]$inputByRole["locale_character"].byteLength
$members[6].sha256 = [string]$inputByRole["locale_character"].sha256
$members[7].byteLength = [long]$inputByRole["locale_costume"].byteLength
$members[7].sha256 = [string]$inputByRole["locale_costume"].sha256
$members[8].byteLength = [long]$inputByRole["locale_item"].byteLength
$members[8].sha256 = [string]$inputByRole["locale_item"].sha256
$members[9].identityObservation = Copy-Digest $projection.syntheticIdentityObservation
$members[10].observationEvidence = Copy-Digest $projection.networkObservation
$members[11].systemHosts.beforeState = Copy-Digest $projection.mutations.systemHosts.beforeState
$members[11].systemHosts.appliedState = Copy-Digest $projection.mutations.systemHosts.appliedState
$members[11].systemHosts.backupState = Copy-Digest $projection.mutations.systemHosts.backupState
$members[11].systemHosts.rollbackPlan = Copy-Digest $projection.mutations.systemHosts.rollbackPlan
$members[11].rootCa.beforeState = Copy-Digest $projection.mutations.rootCa.beforeState
$members[11].rootCa.appliedState = Copy-Digest $projection.mutations.rootCa.appliedState
$members[11].rootCa.backupState = Copy-Digest $projection.mutations.rootCa.backupState
$members[11].rootCa.rollbackPlan = Copy-Digest $projection.mutations.rootCa.rollbackPlan
$members[11].clientCertificateBundle.beforeState = Copy-Digest $projection.mutations.clientCertificateBundle.beforeState
$members[11].clientCertificateBundle.appliedState = Copy-Digest $projection.mutations.clientCertificateBundle.appliedState
$members[11].clientCertificateBundle.backupState = Copy-Digest $projection.mutations.clientCertificateBundle.backupState
$members[11].clientCertificateBundle.rollbackPlan = Copy-Digest $projection.mutations.clientCertificateBundle.rollbackPlan
$members[11].nativeCompatibilityShim.beforeState = Copy-Digest $projection.mutations.nativeCompatibilityShim.beforeState
$members[11].nativeCompatibilityShim.appliedState = Copy-Digest $projection.mutations.nativeCompatibilityShim.appliedState
$members[11].nativeCompatibilityShim.backupState = Copy-Digest $projection.mutations.nativeCompatibilityShim.backupState
$members[11].nativeCompatibilityShim.rollbackPlan = Copy-Digest $projection.mutations.nativeCompatibilityShim.rollbackPlan
$members[12].configObservation = Copy-Digest $projection.localOnlyConfigObservation
$members[13].listenerObservation = Copy-Digest $projection.listenerObservation
$members[15].bootstrapObservation = Copy-Digest $projection.bootstrapObservation
$members[16].stateObservation = Copy-Digest $projection.activeStateObservation
$members[17].logObservation = Copy-Digest $projection.logSafetyObservation

$manifest = Get-CanonicalObservationManifest $members
Assert-True ($manifest.MemberCount -eq 18) "phase3b2_hyperv_observation_member_count_mismatch"
$document.canonicalManifest.memberCount = $manifest.MemberCount
$document.canonicalManifest.canonicalByteLength = $manifest.ByteLength
$document.canonicalManifest.sha256 = $manifest.Sha256
$observationText = $document | ConvertTo-Json -Depth 100
$schemaPath = Join-Path $repositoryRoot `
    "contracts/season26-classic-live-preflight-observation-set.schema.json"
Assert-True (Test-Json -Json $observationText -SchemaFile $schemaPath -ErrorAction SilentlyContinue) `
    "phase3b2_hyperv_observation_schema_invalid"

$assessmentRoot = Join-Path $outputRootFullPath ([string]$projection.assessmentUid)
Assert-True (-not (Test-Path -LiteralPath $assessmentRoot)) `
    "phase3b2_hyperv_observation_assessment_output_exists"
New-Item -ItemType Directory -Path $assessmentRoot -Force | Out-Null
$projectionOutputPath = Join-Path $assessmentRoot "hyperv-ready-projection.json"
$observationOutputPath = Join-Path $assessmentRoot `
    "season26-classic-live-preflight-observation-set.json"
[IO.File]::WriteAllText($projectionOutputPath, ($projectionText.TrimEnd() + "`n"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($observationOutputPath, ($observationText + "`n"), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    contractId = "nll/phase3b2-hyperv-observation-set-generation/v1"
    assessmentUid = [string]$projection.assessmentUid
    observationCount = 18
    canonicalByteLength = $manifest.ByteLength
    canonicalSha256 = $manifest.Sha256
    projectionOutputPath = $projectionOutputPath
    observationSetOutputPath = $observationOutputPath
    serverRunning = $true
    clientExecutionStarted = $false
} | ConvertTo-Json
