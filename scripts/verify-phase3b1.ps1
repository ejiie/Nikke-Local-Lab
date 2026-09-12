param(
    [switch]$ContractOnly
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

    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $forbiddenNames = @(
            "assetId",
            "decodedValue",
            "filePath",
            "localPath",
            "managerId",
            "monsterId",
            "presetId",
            "raidId",
            "rawValue",
            "sourcePath",
            "statId",
            "waveId"
        )

        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b1_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) "phase3b1_forbidden_evidence_property"
            Assert-SafeJsonElement $property.Value
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-SafeJsonElement $item
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        Assert-True ($value -notmatch '^[A-Za-z]:[\\/]' -and
            -not $value.StartsWith('\\', [System.StringComparison]::Ordinal) -and
            -not $value.StartsWith('//', [System.StringComparison]::Ordinal) -and
            -not $value.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) "phase3b1_local_path_value_exposed"
    }
}

function Test-CanonicalAssessment {
    param(
        [string]$Json,
        [string]$SchemaPath
    )

    if (-not (Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        try {
            Assert-SafeJsonElement $document.RootElement
            $assessedAtUtc = $document.RootElement.GetProperty("assessedAtUtc").GetString()
            return Test-UtcSecondInstant $assessedAtUtc
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Get-CanonicalRoutePolicy {
    $lines = @(
        "/soloraid/close`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/enter`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/fastbattle`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/get`tselected_challenge`tperiod_success_or_failure",
        "/soloraid/getlevel`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/getlogs`tselected_challenge`ttrial_logs_or_empty_ban_success",
        "/soloraid/getperiod`tmanager_independent`tperiod_projection",
        "/soloraid/getranking`tmanager_independent`tempty_projection",
        "/soloraid/open`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/practice/close`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/practice/getlevel`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/practice/open`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/practice/setdamage`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/setdamage`tunsupported`tperiod_failure_zero_mutation",
        "/soloraid/trial/close`tselected_challenge`tperiod_success_or_failure",
        "/soloraid/trial/enter`tselected_challenge`tperiod_success_or_failure",
        "/soloraid/trial/getlevel`tselected_challenge`tperiod_success_or_failure",
        "/soloraid/trial/open`tselected_challenge`tperiod_success_or_failure",
        "/soloraid/trial/setdamage`tselected_challenge`tperiod_success_or_failure"
    )

    $canonical = ($lines -join "`n") + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    return [pscustomobject]@{
        MemberCount = $lines.Count
        ByteLength = $bytes.Length
        Sha256 = Get-Sha256Hex $bytes
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$SchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-selected-manager.schema.json"
$ReadyRelativePath = "tests/fixtures/evidence/season26-classic-selected-manager.ready.json"
$ReadyPath = Join-Path $RepositoryRoot $ReadyRelativePath
$ReadyByteLength = 4957
$ReadySha256 = "1b63fa2b825ff0bff7fc8c6e5fc043042fe9e022c9e5700adf00e69a1e6856e6"

if ($ContractOnly) {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b0.ps1"), "-ContractOnly")
}
else {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b0.ps1"))
    if ($env:OS -eq 'Windows_NT') {
        Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "test-nll-execution-fx-retirement.ps1"))
    }
}

Assert-True (Test-Path -LiteralPath $SchemaPath -PathType Leaf) "phase3b1_schema_missing"
Assert-True (Test-Path -LiteralPath $ReadyPath -PathType Leaf) "phase3b1_ready_receipt_missing"

$readyBytes = [System.IO.File]::ReadAllBytes($ReadyPath)
$readyText = [System.Text.Encoding]::UTF8.GetString($readyBytes)
Assert-True ($readyBytes.Length -eq $ReadyByteLength) "phase3b1_ready_receipt_length_mismatch"
Assert-True ((Get-Sha256Hex $readyBytes) -ceq $ReadySha256) "phase3b1_ready_receipt_sha256_mismatch"
Assert-True (Test-CanonicalAssessment $readyText $SchemaPath) "phase3b1_ready_receipt_invalid"

$ready = $readyText | ConvertFrom-Json -Depth 100
$routePolicy = Get-CanonicalRoutePolicy
Assert-True ($ready.sourceFreeDigests.routePolicyCanonicalizationCode -ceq "path_policy_outcome_tsv_lf_ordinal/v1") "phase3b1_route_policy_canonicalization_mismatch"
Assert-True ($ready.sourceFreeDigests.routePolicyMemberCount -eq $routePolicy.MemberCount) "phase3b1_route_policy_count_mismatch"
Assert-True ($ready.sourceFreeDigests.routePolicyCanonicalByteLength -eq $routePolicy.ByteLength) "phase3b1_route_policy_length_mismatch"
Assert-True ($ready.sourceFreeDigests.routePolicySha256 -ceq $routePolicy.Sha256) "phase3b1_route_policy_sha256_mismatch"
Assert-True ($ready.verification.focusedTestCaseCount -eq
    ($ready.verification.selectedManagerTestCaseCount + $ready.verification.handlerIsolationTestCaseCount)) "phase3b1_test_count_mismatch"
Assert-True (($ready.routePolicy.selectedChallengeRouteCount +
    $ready.routePolicy.controlledUnsupportedRouteCount +
    $ready.routePolicy.managerIndependentRouteCount) -eq $ready.routePolicy.classicHandlerCount) "phase3b1_route_count_mismatch"

$verdictCandidate = $readyText | ConvertFrom-Json -Depth 100
$verdictCandidate.verdict = "ready_for_selected_manager_patch"
Assert-True (-not (Test-Json -Json ($verdictCandidate | ConvertTo-Json -Depth 100) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "phase3b1_wrong_verdict_accepted"

$fallbackCandidate = $readyText | ConvertFrom-Json -Depth 100
$fallbackCandidate.selectionAndRunPin.latestFallbackAfter = 1
Assert-True (-not (Test-Json -Json ($fallbackCandidate | ConvertTo-Json -Depth 100) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "phase3b1_latest_fallback_accepted"

$museumCandidate = $readyText | ConvertFrom-Json -Depth 100
$museumCandidate.staticGuards.classicMuseumReferenceOccurrenceCount = 1
Assert-True (-not (Test-Json -Json ($museumCandidate | ConvertTo-Json -Depth 100) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "phase3b1_museum_reference_accepted"

$testCandidate = $readyText | ConvertFrom-Json -Depth 100
$testCandidate.verification.focusedTestFailureCount = 1
Assert-True (-not (Test-Json -Json ($testCandidate | ConvertTo-Json -Depth 100) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "phase3b1_failed_test_accepted"

$commitCandidate = $readyText | ConvertFrom-Json -Depth 100
$commitCandidate.integrationPin.integrationCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($commitCandidate | ConvertTo-Json -Depth 100) -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) "phase3b1_unreviewed_commit_accepted"

$timestampCandidate = $readyText | ConvertFrom-Json -Depth 100
$timestampCandidate.assessedAtUtc = "2026-02-31T00:00:00Z"
Assert-True (-not (Test-CanonicalAssessment ($timestampCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b1_invalid_timestamp_accepted"

$candidatePaths = @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard "*.json")
$matchingPaths = [System.Collections.Generic.List[string]]::new()
foreach ($candidatePath in $candidatePaths) {
    $fullPath = Join-Path $RepositoryRoot $candidatePath
    try {
        $candidate = Get-Content -Raw -LiteralPath $fullPath | ConvertFrom-Json -Depth 100
        if ($candidate.contractId -ceq "nll/season26-classic-selected-manager/v1") {
            $matchingPaths.Add($candidatePath.Replace("\", "/"))
        }
    }
    catch {
    }
}

Assert-True ($matchingPaths.Count -eq 1) "phase3b1_assessment_inventory_count_mismatch"
Assert-True ($matchingPaths[0] -ceq $ReadyRelativePath) "phase3b1_assessment_inventory_path_mismatch"

$mode = if ($ContractOnly) { "contract-only" } else { "full baseline and contract" }
Write-Output "Phase 3B-1 $mode verification passed; the selected-manager patch is ready for the isolated season 26 reference run, while original-client battle/HUD/result remains unverified."
