[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
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
            else { throw "phase3b2_observation_noncanonical_number" }
            break
        }
        ([System.Text.Json.JsonValueKind]::True) { $Writer.WriteBooleanValue($true); break }
        ([System.Text.Json.JsonValueKind]::False) { $Writer.WriteBooleanValue($false); break }
        ([System.Text.Json.JsonValueKind]::Null) { $Writer.WriteNullValue(); break }
        default { throw "phase3b2_observation_unsupported_json_kind" }
    }
}

function Get-CanonicalObservationManifest {
    param([object[]]$Observations)
    $json = $Observations | ConvertTo-Json -Depth 100 -Compress
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    $stream = [System.IO.MemoryStream]::new()
    try {
        foreach ($member in @($document.RootElement.EnumerateArray()) | Sort-Object { $_.GetProperty("ordinal").GetInt32() }) {
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
        $canonical = $stream.ToArray()
        return [pscustomobject]@{ MemberCount = $Observations.Count; ByteLength = $canonical.Length; Sha256 = Get-Sha256Hex $canonical }
    }
    finally {
        $stream.Dispose()
        $document.Dispose()
    }
}

function Copy-Digest {
    param([object]$Value)
    return [ordered]@{ byteLength = [long]$Value.byteLength; sha256 = [string]$Value.sha256 }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory ".."))
$evidenceFullPath = [System.IO.Path]::GetFullPath($EvidenceRoot)
$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
Assert-OutsideRepository $evidenceFullPath $repositoryRoot "phase3b2_observation_evidence_inside_repository"
Assert-OutsideRepository $outputFullPath $repositoryRoot "phase3b2_observation_output_inside_repository"
Assert-True (Test-Path -LiteralPath $evidenceFullPath -PathType Container) "phase3b2_observation_evidence_missing"
Assert-True (-not (Test-Path -LiteralPath $outputFullPath)) "phase3b2_observation_output_exists"

$status = Get-Content -Raw -LiteralPath (Join-Path $evidenceFullPath "status.json") | ConvertFrom-Json -Depth 20
Assert-True ($status.statusCode -ceq "p1_measurement_complete" -and -not $status.clientExecutionStarted) "phase3b2_observation_p1_not_complete"
$projection = Get-Content -Raw -LiteralPath (Join-Path $evidenceFullPath "host-input-projection.json") | ConvertFrom-Json -Depth 20
$cold = Get-Content -Raw -LiteralPath (Join-Path $evidenceFullPath "cold-staging.json") | ConvertFrom-Json -Depth 20
$p0 = Get-Content -Raw -LiteralPath (Join-Path $evidenceFullPath "p0-seal.json") | ConvertFrom-Json -Depth 30
$p1 = Get-Content -Raw -LiteralPath (Join-Path $evidenceFullPath "p1-measurement.json") | ConvertFrom-Json -Depth 20
Assert-True ($projection.assessmentUid -ceq $cold.assessmentUid) "phase3b2_observation_assessment_binding_mismatch"
Assert-True (-not $cold.clientExecutionStarted -and -not $p0.clientExecutionStarted -and -not $p1.clientExecutionStarted) "phase3b2_observation_client_started"

$inputByRole = @{}
foreach ($input in $projection.inputs) { $inputByRole[[string]$input.roleCode] = $input }
$requiredInputs = @("runtime_pack_staticdata", "locale_bgm", "locale_character", "locale_costume", "locale_item")
foreach ($role in $requiredInputs) { Assert-True ($null -ne $inputByRole[$role]) "phase3b2_observation_runtime_input_missing" }

$templatePath = Join-Path $repositoryRoot "tests/fixtures/synthetic/season26-classic-live-preflight-observation-set.valid.json"
$document = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json -Depth 100
$document.assessmentUid = $projection.assessmentUid
$document.observedAtUtc = $p1.observedAtUtc
$members = @($document.observations)
$members[0].environmentKindCode = "snapshot_capable_disposable_vm"
$members[0].resetIdentity = Copy-Digest $p1.resetIdentity
$members[1].beforeState = Copy-Digest $cold.primaryManifest
$members[2].contentSet = Copy-Digest $cold.clientManifest
$members[3].toolchainObservation = Copy-Digest $cold.toolchainEvidence
$members[3].buildArtifactObservation = Copy-Digest $cold.buildManifest
$members[3].focusedTestObservation = Copy-Digest $cold.focusedEvidence
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
$members[9].identityObservation = Copy-Digest $p1.syntheticIdentity
$members[10].observationEvidence = Copy-Digest $p1.networkObservation
$members[10].nonLoopbackAttemptCount = [int]$p1.nonLoopbackAttemptCount
$members[10].nonLoopbackSuccessfulConnectionCount = [int]$p1.nonLoopbackSuccessfulConnectionCount
$members[11].systemHosts.beforeState = Copy-Digest $p0.mutations.systemHosts.beforeState
$members[11].systemHosts.appliedState = Copy-Digest $p0.mutations.systemHosts.appliedState
$members[11].systemHosts.backupState = Copy-Digest $p0.mutations.systemHosts.backupState
$members[11].systemHosts.rollbackPlan = Copy-Digest $p0.mutations.systemHosts.rollbackPlan
$members[11].rootCa.beforeState = Copy-Digest $p0.mutations.rootCa.beforeState
$members[11].rootCa.appliedState = Copy-Digest $p0.mutations.rootCa.appliedState
$members[11].rootCa.backupState = Copy-Digest $p0.mutations.rootCa.backupState
$members[11].rootCa.rollbackPlan = Copy-Digest $p0.mutations.rootCa.rollbackPlan
$members[11].clientCertificateBundle.beforeState = Copy-Digest $p0.mutations.clientCertificateBundle.beforeState
$members[11].clientCertificateBundle.appliedState = Copy-Digest $p0.mutations.clientCertificateBundle.appliedState
$members[11].clientCertificateBundle.backupState = Copy-Digest $p0.mutations.clientCertificateBundle.backupState
$members[11].clientCertificateBundle.rollbackPlan = Copy-Digest $p0.mutations.clientCertificateBundle.rollbackPlan
$members[11].nativeCompatibilityShim.beforeState = Copy-Digest $p0.mutations.nativeCompatibilityShim.beforeState
$members[11].nativeCompatibilityShim.appliedState = Copy-Digest $p0.mutations.nativeCompatibilityShim.appliedState
$members[11].nativeCompatibilityShim.backupState = Copy-Digest $p0.mutations.nativeCompatibilityShim.backupState
$members[11].nativeCompatibilityShim.rollbackPlan = Copy-Digest $p0.mutations.nativeCompatibilityShim.rollbackPlan
$members[12].configObservation = Copy-Digest $p1.localOnlyConfigObservation
$members[13].listenerObservation = Copy-Digest $p1.listenerObservation
$members[15].bootstrapObservation = Copy-Digest $p1.bootstrapObservation
$members[16].stateObservation = Copy-Digest $p1.activeStateObservation
$members[17].logObservation = Copy-Digest $p1.logSafetyObservation

$manifest = Get-CanonicalObservationManifest $members
Assert-True ($manifest.MemberCount -eq 18) "phase3b2_observation_member_count_mismatch"
$document.canonicalManifest.memberCount = $manifest.MemberCount
$document.canonicalManifest.canonicalByteLength = $manifest.ByteLength
$document.canonicalManifest.sha256 = $manifest.Sha256
$schemaPath = Join-Path $repositoryRoot "contracts/season26-classic-live-preflight-observation-set.schema.json"
$text = $document | ConvertTo-Json -Depth 100
Assert-True (Test-Json -Json $text -SchemaFile $schemaPath -ErrorAction SilentlyContinue) "phase3b2_observation_schema_invalid"
[System.IO.File]::WriteAllText($outputFullPath, $text + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output "Phase 3B-2 source-free observation set created outside the repository; server remains running and client remains cold."
