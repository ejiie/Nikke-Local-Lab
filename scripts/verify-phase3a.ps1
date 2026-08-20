param(
    [switch]$ContractOnly,
    [string]$LocalAssessmentPath
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Assert-FileContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$FailureCode
    )

    $content = [System.IO.File]::ReadAllText($Path)
    if ($content -notmatch $Pattern) {
        throw $FailureCode
    }
}

function Test-GateJson {
    param(
        [string]$Json,
        [string]$SchemaPath
    )

    return Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
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

function Resolve-SafeLocalPath {
    param(
        [string]$Path,
        [string]$FailurePrefix
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.Path]::IsPathFullyQualified($Path) -or
        $Path -notmatch '^[A-Za-z]:[\\/]' -or
        $Path.StartsWith('\\', [System.StringComparison]::Ordinal) -or
        $Path.StartsWith('//', [System.StringComparison]::Ordinal) -or
        $Path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or
        $Path.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or
        $Path.Substring(2).Contains(':')) {
        throw "${FailurePrefix}_not_local_drive_path"
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetPathRoot($fullPath)
        $relative = [System.IO.Path]::GetRelativePath($root, $fullPath)
        $current = $root
        foreach ($segment in $relative -split '[\\/]') {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') {
                continue
            }

            $current = Join-Path $current $segment
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "${FailurePrefix}_reparse_point_rejected"
                }
            }
        }

        return $fullPath
    }
    catch {
        if ($_.Exception.Message -like "${FailurePrefix}_*") {
            throw
        }

        throw "${FailurePrefix}_probe_failed"
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$Phase2B = Join-Path $ScriptDirectory "verify-phase2b.ps1"
$SchemaPath = Join-Path $RepositoryRoot "contracts/original-client-compatibility-gate.schema.json"
$BlockedFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/original-client-compatibility-gate.blocked.json"
$Phase3PlanPath = Join-Path $RepositoryRoot "docs/PHASE3.md"
$Phase3AAssessmentPath = Join-Path $RepositoryRoot "docs/PHASE3A.md"
$Phase3RebaselinePath = Join-Path $RepositoryRoot "docs/PHASE3AR.md"
$ImplementationPlanPath = Join-Path $RepositoryRoot "docs/IMPLEMENTATION_PLAN.md"
$ConfigPath = Join-Path $RepositoryRoot "config/appsettings.example.json"

foreach ($requiredPath in @(
    $SchemaPath,
    $BlockedFixturePath,
    $Phase3PlanPath,
    $Phase3AAssessmentPath,
    $Phase3RebaselinePath,
    $ImplementationPlanPath,
    $ConfigPath
)) {
    Assert-True (Test-Path -LiteralPath $requiredPath -PathType Leaf) "phase3a_required_artifact_missing"
}

if (-not $ContractOnly) {
    Invoke-Checked pwsh @("-NoProfile", "-File", $Phase2B)
}

$BlockedFixtureText = [System.IO.File]::ReadAllText($BlockedFixturePath)
Assert-True (Test-GateJson $BlockedFixtureText $SchemaPath) "phase3a_blocked_fixture_schema_invalid"

$BlockedFixture = $BlockedFixtureText | ConvertFrom-Json
$BlockedFixtureDocument = [System.Text.Json.JsonDocument]::Parse($BlockedFixtureText)
$BlockedFixtureInstant = $BlockedFixtureDocument.RootElement.GetProperty("assessedAtUtc").GetString()
Assert-True ($BlockedFixture.contractId -eq "nll/original-client-compatibility-gate/v1") "phase3a_contract_id_mismatch"
Assert-True (Test-UtcSecondInstant $BlockedFixtureInstant) "phase3a_blocked_fixture_instant_invalid"
Assert-True ($BlockedFixture.verdict -eq "blocked_insufficient_evidence") "phase3a_checked_in_verdict_must_be_blocked"
Assert-True ($BlockedFixture.route.kind -eq "unresolved") "phase3a_checked_in_route_must_be_unresolved"
Assert-True ($BlockedFixture.clientBuild.bindingStatus -eq "unbound") "phase3a_checked_in_build_must_be_unbound"
Assert-True ($BlockedFixture.outboundIsolation.status -eq "not_evaluated") "phase3a_checked_in_outbound_must_be_unevaluated"
Assert-True (@($BlockedFixture.unresolvedReasonCodes).Count -ge 1) "phase3a_blocked_reasons_missing"
$SortedBlockedReasons = @($BlockedFixture.unresolvedReasonCodes | Sort-Object -CaseSensitive)
Assert-True ((@($BlockedFixture.unresolvedReasonCodes) -join "`n") -ceq ($SortedBlockedReasons -join "`n")) "phase3a_blocked_reasons_not_canonical"

$RepositoryPaths = @(& git -c "safe.directory=$RepositoryRoot" -c core.excludesFile= -C $RepositoryRoot ls-files --cached --others --exclude-standard)
Assert-True ($LASTEXITCODE -eq 0) "phase3a_repository_file_inventory_failed"
foreach ($relativePath in $RepositoryPaths) {
    $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativePath))
    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        continue
    }

    try {
        $candidateText = [System.IO.File]::ReadAllText($candidatePath)
        if (-not $candidateText.TrimStart().StartsWith("{", [System.StringComparison]::Ordinal)) {
            continue
        }

        $candidateDocument = $candidateText | ConvertFrom-Json -ErrorAction Stop
        if ($candidateDocument.contractId -eq "nll/original-client-compatibility-gate/v1" -and
            $candidateDocument.verdict -eq "ready_for_phase3b") {
            throw "phase3a_ready_assessment_must_not_be_stored_in_repository"
        }
    }
    catch {
        if ($_.Exception.Message -eq "phase3a_ready_assessment_must_not_be_stored_in_repository") {
            throw
        }
    }
}

$ForbiddenEvidenceKeys = '(?i)"(source(path|_?id)|file(name|path)?|executable(path|name)|endpoint|host(name)?|account|cookie|token|credential|wire(capture|dump)|asset(path|_?id)|client(local)?reference)"\s*:'
Assert-True ($BlockedFixtureText -notmatch $ForbiddenEvidenceKeys) "phase3a_fixture_exposes_forbidden_evidence"

$ReadyWithoutEvidence = $BlockedFixtureText | ConvertFrom-Json
$ReadyWithoutEvidence.verdict = "ready_for_phase3b"
$ReadyWithoutEvidence.unresolvedReasonCodes = @()
$ReadyWithoutEvidenceText = $ReadyWithoutEvidence | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $ReadyWithoutEvidenceText $SchemaPath)) "phase3a_ready_without_evidence_accepted"

$UnsafeCandidate = $BlockedFixtureText | ConvertFrom-Json
$UnsafeCandidate.prohibitedTechniques.hooking = $true
$UnsafeCandidateText = $UnsafeCandidate | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $UnsafeCandidateText $SchemaPath)) "phase3a_forbidden_technique_accepted"

$CredentialCandidate = $BlockedFixtureText | ConvertFrom-Json
$CredentialCandidate.sessionBoundary.officialCredentialsUsed = $true
$CredentialCandidateText = $CredentialCandidate | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $CredentialCandidateText $SchemaPath)) "phase3a_official_credentials_accepted"

$InvalidInstantCandidate = $BlockedFixtureText | ConvertFrom-Json
$InvalidInstantCandidate.assessedAtUtc = "2026-02-31T00:00:00Z"
$InvalidInstantCandidateText = $InvalidInstantCandidate | ConvertTo-Json -Depth 100
$InvalidInstantAccepted = (Test-GateJson $InvalidInstantCandidateText $SchemaPath) -and
    (Test-UtcSecondInstant $InvalidInstantCandidate.assessedAtUtc)
Assert-True (-not $InvalidInstantAccepted) "phase3a_invalid_assessment_instant_accepted"

$RepositoryLeakCandidate = $BlockedFixtureText | ConvertFrom-Json
$RepositoryLeakCandidate.route | Add-Member -NotePropertyName "sourcePath" -NotePropertyValue "synthetic"
$RepositoryLeakCandidateText = $RepositoryLeakCandidate | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $RepositoryLeakCandidateText $SchemaPath)) "phase3a_source_path_accepted"

$ContradictoryHandshake = $BlockedFixtureText | ConvertFrom-Json
$ContradictoryHandshake.handshakeContract.status = "supported"
$ContradictoryHandshakeText = $ContradictoryHandshake | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $ContradictoryHandshakeText $SchemaPath)) "phase3a_partial_handshake_status_accepted"

$ContradictorySession = $BlockedFixtureText | ConvertFrom-Json
$ContradictorySession.sessionBoundary.status = "enforcement_plan_ready"
$ContradictorySessionText = $ContradictorySession | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $ContradictorySessionText $SchemaPath)) "phase3a_partial_session_plan_accepted"

$ContradictoryOutbound = $BlockedFixtureText | ConvertFrom-Json
$ContradictoryOutbound.outboundIsolation.status = "verification_plan_ready"
$ContradictoryOutboundText = $ContradictoryOutbound | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $ContradictoryOutboundText $SchemaPath)) "phase3a_partial_outbound_plan_accepted"

$StructurallyReady = $BlockedFixtureText | ConvertFrom-Json
$StructurallyReady.verdict = "ready_for_phase3b"
$StructurallyReady.route.kind = "rights_holder_approved_local_test"
$StructurallyReady.route.authorizationStatus = "verified"
$StructurallyReady.route.scopeStatus = "current"
$StructurallyReady.route.authorizationEvidence = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000003"
    kindCode = "authorization_scope"
    byteLength = 1
    sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}
$StructurallyReady.route.selectorInterfaceCode = "supported_local_selector"
$StructurallyReady.route.selectorEvidence = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000004"
    kindCode = "supported_route_selector"
    byteLength = 1
    sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
}
$StructurallyReady.route.allowedPurposeCode = "local_private_server_compatibility"
$StructurallyReady.clientBuild.bindingStatus = "exact"
$StructurallyReady.clientBuild.buildUid = "30000000-0000-0000-0000-000000000002"
$StructurallyReady.clientBuild.executableObservation = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000005"
    kindCode = "client_executable"
    byteLength = 1
    sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
$StructurallyReady.clientBuild.contentSet = [pscustomobject]@{
    contractId = "nll/client-content-set/v1"
    canonicalization = "role_length_sha256_lf_ordinal/v1"
    closureStatus = "exact_for_approved_route"
    memberCount = 1
    canonicalManifestByteLength = 1
    sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}
$StructurallyReady.clientBuild.adapterContractId = "nll/original-client-adapter/v1"
$StructurallyReady.handshakeContract.status = "supported"
$StructurallyReady.handshakeContract.contractId = "approved/client-handshake/v1"
$StructurallyReady.handshakeContract.evidence = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000008"
    kindCode = "supported_handshake_contract"
    byteLength = 1
    sha256 = "9999999999999999999999999999999999999999999999999999999999999999"
}
$StructurallyReady.sessionBoundary.status = "enforcement_plan_ready"
$StructurallyReady.sessionBoundary.syntheticLocalSessionOnly = $true
$StructurallyReady.sessionBoundary.evidence = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000006"
    kindCode = "synthetic_session_enforcement_plan"
    byteLength = 1
    sha256 = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
}
$StructurallyReady.outboundIsolation.status = "verification_plan_ready"
$StructurallyReady.outboundIsolation.processTreeScopeStatus = "defined"
$StructurallyReady.outboundIsolation.coversIpv4 = $true
$StructurallyReady.outboundIsolation.coversIpv6 = $true
$StructurallyReady.outboundIsolation.coversDns = $true
$StructurallyReady.outboundIsolation.coversTcp = $true
$StructurallyReady.outboundIsolation.coversUdp = $true
$StructurallyReady.outboundIsolation.evidence = [pscustomobject]@{
    artifactUid = "30000000-0000-0000-0000-000000000007"
    kindCode = "outbound_isolation_verification_plan"
    byteLength = 1
    sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
}
$StructurallyReady.unresolvedReasonCodes = @()
$StructurallyReadyText = $StructurallyReady | ConvertTo-Json -Depth 100
Assert-True (Test-GateJson $StructurallyReadyText $SchemaPath) "phase3a_ready_shape_unrepresentable"

$ReadyWithoutHandshake = $StructurallyReadyText | ConvertFrom-Json
$ReadyWithoutHandshake.handshakeContract.status = "not_verified"
$ReadyWithoutHandshake.handshakeContract.contractId = $null
$ReadyWithoutHandshake.handshakeContract.evidence = $null
$ReadyWithoutHandshakeText = $ReadyWithoutHandshake | ConvertTo-Json -Depth 100
Assert-True (-not (Test-GateJson $ReadyWithoutHandshakeText $SchemaPath)) "phase3a_ready_without_handshake_evidence_accepted"

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
Assert-True ($Config.originalClientCompatibility.enabled -eq $false) "phase3a_adapter_must_remain_disabled"
Assert-True ($Config.originalClientCompatibility.status -eq "blocked") "phase3a_runtime_status_must_remain_blocked"

Assert-FileContains $Phase3PlanPath '(?m)^## 3A — approval-first evidence audit — 역사적 완료$' "phase3a_historical_plan_missing"
Assert-FileContains $Phase3PlanPath '(?m)^## 3B-0 — 시즌 26 static/runtime closure$' "phase3b0_plan_split_missing"
Assert-FileContains $Phase3PlanPath '(?m)^## 3B-2 — isolated live season 26 proof$' "phase3b2_plan_split_missing"
Assert-FileContains $Phase3AAssessmentPath 'blocked_insufficient_evidence' "phase3a_assessment_verdict_missing"
Assert-FileContains $Phase3RebaselinePath 'ready_for_local_compatibility_spike' "phase3ar_rebaseline_verdict_missing"
Assert-FileContains $Phase3RebaselinePath '시즌 26' "phase3ar_season26_target_missing"
Assert-FileContains $Phase3RebaselinePath 'SoloRaidMuseum' "phase3ar_museum_exclusion_missing"
Assert-FileContains $ImplementationPlanPath '(?m)^### 3D\. Season 26 end-to-end sealing$' "phase3d_implementation_split_missing"

$UnsafePathRejected = $false
try {
    [void](Resolve-SafeLocalPath '\\server\share\assessment.json' "phase3a_test_unc")
}
catch {
    $UnsafePathRejected = $_.Exception.Message -eq "phase3a_test_unc_not_local_drive_path"
}
Assert-True $UnsafePathRejected "phase3a_unc_assessment_path_accepted"

$DevicePathRejected = $false
try {
    [void](Resolve-SafeLocalPath '\\?\C:\assessment.json' "phase3a_test_device")
}
catch {
    $DevicePathRejected = $_.Exception.Message -eq "phase3a_test_device_not_local_drive_path"
}
Assert-True $DevicePathRejected "phase3a_device_assessment_path_accepted"

$AlternateStreamRejected = $false
try {
    [void](Resolve-SafeLocalPath 'C:\assessment.json:hidden' "phase3a_test_ads")
}
catch {
    $AlternateStreamRejected = $_.Exception.Message -eq "phase3a_test_ads_not_local_drive_path"
}
Assert-True $AlternateStreamRejected "phase3a_alternate_stream_assessment_path_accepted"

if (-not [string]::IsNullOrWhiteSpace($LocalAssessmentPath)) {
    Assert-True (-not [string]::IsNullOrWhiteSpace($env:NIKKE_LAB_PHASE3A_EVIDENCE_ROOT)) "phase3a_local_evidence_root_required"
    $resolvedEvidenceRoot = Resolve-SafeLocalPath $env:NIKKE_LAB_PHASE3A_EVIDENCE_ROOT "phase3a_local_evidence_root"
    $resolvedAssessmentPath = Resolve-SafeLocalPath $LocalAssessmentPath "phase3a_local_assessment"
    $repositoryPrefix = $RepositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    Assert-True (-not $resolvedAssessmentPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "phase3a_local_assessment_must_remain_outside_repository"
    $evidenceRootPrefix = $resolvedEvidenceRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    Assert-True ($resolvedAssessmentPath.StartsWith($evidenceRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "phase3a_local_assessment_outside_evidence_root"

    try {
        Assert-True (Test-Path -LiteralPath $resolvedEvidenceRoot -PathType Container) "phase3a_local_evidence_root_missing"
        Assert-True (Test-Path -LiteralPath $resolvedAssessmentPath -PathType Leaf) "phase3a_local_assessment_missing"
        $assessmentInfo = Get-Item -LiteralPath $resolvedAssessmentPath -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -like "phase3a_local_*") {
            throw
        }

        throw "phase3a_local_assessment_probe_failed"
    }

    Assert-True ($assessmentInfo.Length -le 1MB) "phase3a_local_assessment_too_large"
    try {
        $assessmentText = [System.IO.File]::ReadAllText($resolvedAssessmentPath)
    }
    catch {
        throw "phase3a_local_assessment_read_failed"
    }

    Assert-True (Test-GateJson $assessmentText $SchemaPath) "phase3a_local_assessment_schema_invalid"
    $assessment = $assessmentText | ConvertFrom-Json
    $assessmentDocument = [System.Text.Json.JsonDocument]::Parse($assessmentText)
    $assessmentInstant = $assessmentDocument.RootElement.GetProperty("assessedAtUtc").GetString()
    Assert-True (Test-UtcSecondInstant $assessmentInstant) "phase3a_local_assessment_instant_invalid"

    if ($assessment.verdict -eq "ready_for_phase3b") {
        Assert-True (-not $resolvedAssessmentPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "phase3a_ready_assessment_must_remain_outside_repository"
    }

    Write-Output "Local Phase 3A assessment is structurally valid; factual evidence still requires local operator review."
    Write-Output "Phase 3A local verdict: $($assessment.verdict)"
}

$Mode = if ($ContractOnly) { "contract-only" } else { "full baseline and contract" }
Write-Output "Phase 3A $Mode verification passed; the checked-in v1 verdict remains blocked_insufficient_evidence and the 3A-R documentation records ready_for_local_compatibility_spike."
