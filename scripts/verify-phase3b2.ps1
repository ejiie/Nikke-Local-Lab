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

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $forbiddenNames = @(
            "accountId",
            "assetId",
            "assetName",
            "backupPath",
            "certificatePath",
            "characterId",
            "decodedValue",
            "executablePath",
            "fileName",
            "filePath",
            "fullPath",
            "gameRoot",
            "localPath",
            "managerId",
            "managerName",
            "memberName",
            "modelId",
            "monsterId",
            "monsterName",
            "originalId",
            "originalPath",
            "partId",
            "presetId",
            "raidId",
            "rawId",
            "rawIdentifier",
            "rawValue",
            "sourceId",
            "sourcePath",
            "spotId",
            "stageId",
            "statId",
            "userId",
            "waveId"
        )

        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b2_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) "phase3b2_forbidden_evidence_property"
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
            $value -notmatch '^/(home|mnt|private|root|tmp|Users|var)/' -and
            -not $value.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) "phase3b2_local_path_value_exposed"
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

function Assert-FixedTarget {
    param([object]$Assessment)

    Assert-True ($Assessment.target.clientBuildVersion -ceq "150.6.9") "phase3b2_client_build_mismatch"
    Assert-True ($Assessment.target.seasonNumber -eq 26) "phase3b2_season_mismatch"
    Assert-True ($Assessment.target.modeCode -ceq "classic_solo_raid_challenge") "phase3b2_classic_mode_required"
    Assert-True ($Assessment.target.wireModeCode -ceq "trial") "phase3b2_trial_wire_required"
    Assert-True ($Assessment.target.challengeRaidLevel -eq 8) "phase3b2_challenge_level_mismatch"
    Assert-True ($Assessment.target.museumAllowed -eq $false) "phase3b2_museum_allowed"
    Assert-True ($Assessment.target.fallbackPolicyCode -ceq "none") "phase3b2_fallback_allowed"
}

function Assert-FixedExternalLineage {
    param([object]$Assessment)

    $lineage = $Assessment.externalLineage
    Assert-True ($lineage.repositoryCode -ceq "epinelps_epinelps") "phase3b2_external_repository_mismatch"
    Assert-True ($lineage.licenseCode -ceq "agpl-3.0-only") "phase3b2_external_license_mismatch"
    Assert-True ($lineage.sourceBoundaryCode -ceq "external_agpl_checkout") "phase3b2_external_source_boundary_mismatch"
    Assert-True ($lineage.upstreamBaseCommitSha -ceq "28b2f5413a0a1e3521a11ae162f91851335c8b40") "phase3b2_upstream_base_pin_mismatch"
    Assert-True ($lineage.selectedManagerIntegrationCommitSha -ceq "92a6ca228aeb580988907b96189b2857dff2c62d") "phase3b2_selected_manager_pin_mismatch"
    Assert-True ($lineage.preflightSealCommitSha -ceq "e32e5f900775974d5736e7fb2b50f8c62638a004") "phase3b2_preflight_seal_pin_mismatch"
    Assert-True ($lineage.preflightHardeningCommitSha -ceq "4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f") "phase3b2_preflight_hardening_pin_mismatch"
    Assert-True ($lineage.latestExternalTreeCommitSha -ceq "ce353eeebee3c76672e483c6f735bb27f0227815") "phase3b2_latest_external_tree_pin_mismatch"
}

function Assert-ProhibitedMaterialBoundary {
    param([object]$Assessment)

    $properties = @($Assessment.prohibitedMaterial.PSObject.Properties)
    Assert-True ($properties.Count -eq 11) "phase3b2_prohibited_material_shape_mismatch"
    foreach ($property in $properties) {
        Assert-True ($property.Value -eq $false) "phase3b2_prohibited_material_claimed_present"
    }
}

function Get-RepositoryJsonPaths {
    param([string]$RepositoryRoot)

    $paths = @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard "*.json")
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_repository_json_inventory_failed"
    return @($paths | ForEach-Object { $_.Replace("\", "/") })
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$PreflightSchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-live-preflight.schema.json"
$ReferenceRunSchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-reference-run.schema.json"
$PreflightRelativePath = "tests/fixtures/synthetic/season26-classic-live-preflight.blocked.json"
$ReferenceRunRelativePath = "tests/fixtures/synthetic/season26-classic-reference-run.not-executed.json"
$PreflightPath = Join-Path $RepositoryRoot $PreflightRelativePath
$ReferenceRunPath = Join-Path $RepositoryRoot $ReferenceRunRelativePath
$PreflightContractId = "nll/season26-classic-live-preflight/v1"
$ReferenceRunContractId = "nll/season26-classic-reference-run/v1"

if ($ContractOnly) {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b1.ps1"), "-ContractOnly")
}
else {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b1.ps1"))
}

Assert-True (Test-Path -LiteralPath $PreflightSchemaPath -PathType Leaf) "phase3b2_preflight_schema_missing"
Assert-True (Test-Path -LiteralPath $ReferenceRunSchemaPath -PathType Leaf) "phase3b2_reference_run_schema_missing"
Assert-True (Test-Path -LiteralPath $PreflightPath -PathType Leaf) "phase3b2_blocked_preflight_fixture_missing"
Assert-True (Test-Path -LiteralPath $ReferenceRunPath -PathType Leaf) "phase3b2_not_executed_reference_run_fixture_missing"

$preflightText = [System.IO.File]::ReadAllText($PreflightPath, [System.Text.UTF8Encoding]::new($false, $true))
$referenceRunText = [System.IO.File]::ReadAllText($ReferenceRunPath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True (Test-CanonicalAssessment $preflightText $PreflightSchemaPath) "phase3b2_blocked_preflight_fixture_invalid"
Assert-True (Test-CanonicalAssessment $referenceRunText $ReferenceRunSchemaPath) "phase3b2_not_executed_reference_run_fixture_invalid"

$preflight = $preflightText | ConvertFrom-Json -Depth 100
$referenceRun = $referenceRunText | ConvertFrom-Json -Depth 100
Assert-True ($preflight.contractId -ceq $PreflightContractId) "phase3b2_preflight_contract_id_mismatch"
Assert-True ($referenceRun.contractId -ceq $ReferenceRunContractId) "phase3b2_reference_run_contract_id_mismatch"
Assert-True ($preflight.verdict -ceq "blocked_preflight_incomplete") "phase3b2_preflight_fixture_not_blocked"
Assert-True ($referenceRun.verdict -ceq "not_executed_contract_scaffold_only") "phase3b2_reference_run_fixture_not_scaffold_only"
Assert-FixedTarget $preflight
Assert-FixedTarget $referenceRun
Assert-FixedExternalLineage $preflight
Assert-FixedExternalLineage $referenceRun
Assert-ProhibitedMaterialBoundary $preflight
Assert-ProhibitedMaterialBoundary $referenceRun

Assert-True ($preflight.measuredEvidence.statusCode -ceq "not_measured") "phase3b2_preflight_evidence_already_measured"
Assert-True ($preflight.measuredEvidence.observationCount -eq 0) "phase3b2_preflight_observation_present"
Assert-True ($null -eq $preflight.measuredEvidence.canonicalManifest) "phase3b2_preflight_manifest_present"
Assert-True ($referenceRun.execution.statusCode -ceq "not_executed") "phase3b2_reference_run_already_executed"
Assert-True ($null -eq $referenceRun.execution.startedAtUtc -and
    $null -eq $referenceRun.execution.completedAtUtc) "phase3b2_reference_run_execution_time_present"
Assert-True ($referenceRun.execution.observationCount -eq 0) "phase3b2_reference_run_observation_present"
Assert-True ($null -eq $referenceRun.execution.canonicalManifest) "phase3b2_reference_run_manifest_present"
Assert-True ($referenceRun.originalClientResult.statusCode -ceq "not_observed" -and
    -not $referenceRun.originalClientResult.battleRuntimeStarted -and
    -not $referenceRun.originalClientResult.hudObserved -and
    -not $referenceRun.originalClientResult.damageObserved -and
    -not $referenceRun.originalClientResult.resultReturned) "phase3b2_original_client_result_overclaimed"

$readyPreflightCandidate = $preflightText | ConvertFrom-Json -Depth 100
$readyPreflightCandidate.verdict = "ready_to_start_isolated_season26_reference_run"
Assert-True (-not (Test-Json -Json ($readyPreflightCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_unmeasured_preflight_ready_verdict_accepted"

$unsupportedEnvironmentVerdictCandidate = $preflightText | ConvertFrom-Json -Depth 100
$unsupportedEnvironmentVerdictCandidate.verdict = "blocked_environment_violation"
Assert-True (-not (Test-Json -Json ($unsupportedEnvironmentVerdictCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_environment_violation_without_observation_accepted"

$officialMaterialCandidate = $preflightText | ConvertFrom-Json -Depth 100
$officialMaterialCandidate.verdict = "blocked_environment_violation"
$officialMaterialCandidate.environment.syntheticLocalAccountOnly = $false
$officialMaterialCandidate.environment.officialAccountMaterialPresent = $true
Assert-True (Test-Json -Json ($officialMaterialCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue) "phase3b2_controlled_official_material_violation_rejected"

$verifiedRunCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$verifiedRunCandidate.verdict = "verified_isolated_season26_original_client_result"
Assert-True (-not (Test-Json -Json ($verifiedRunCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_not_executed_verified_verdict_accepted"

$preflightPinCandidate = $preflightText | ConvertFrom-Json -Depth 100
$preflightPinCandidate.externalLineage.latestExternalTreeCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($preflightPinCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_preflight_external_pin_drift_accepted"

$referencePinCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$referencePinCandidate.externalLineage.latestExternalTreeCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($referencePinCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_reference_run_external_pin_drift_accepted"

$pathCandidate = $preflightText | ConvertFrom-Json -Depth 100
$pathCandidate.runtimeInputs | Add-Member -NotePropertyName "sourcePath" -NotePropertyValue "synthetic"
Assert-True (-not (Test-Json -Json ($pathCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_source_path_property_accepted"

$rawIdCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$rawIdCandidate.target | Add-Member -NotePropertyName "managerId" -NotePropertyValue 1
Assert-True (-not (Test-Json -Json ($rawIdCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_raw_manager_id_property_accepted"

$timestampCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$timestampCandidate.assessedAtUtc = "2026-02-31T00:00:00Z"
Assert-True (-not (Test-CanonicalAssessment ($timestampCandidate | ConvertTo-Json -Depth 100) $ReferenceRunSchemaPath)) "phase3b2_invalid_timestamp_accepted"

$inventory = Get-RepositoryJsonPaths $RepositoryRoot
$preflightMatchingPaths = [System.Collections.Generic.List[string]]::new()
$referenceRunMatchingPaths = [System.Collections.Generic.List[string]]::new()
foreach ($candidatePath in $inventory) {
    $fullPath = Join-Path $RepositoryRoot $candidatePath
    try {
        $candidateText = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($candidateText)
        try {
            if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                continue
            }

            $contractIdElement = [System.Text.Json.JsonElement]::new()
            if (-not $document.RootElement.TryGetProperty("contractId", [ref]$contractIdElement)) {
                continue
            }

            $contractId = $contractIdElement.GetString()
            if ($contractId -ceq $PreflightContractId) {
                Assert-SafeJsonElement $document.RootElement
                $preflightMatchingPaths.Add($candidatePath)
            }
            elseif ($contractId -ceq $ReferenceRunContractId) {
                Assert-SafeJsonElement $document.RootElement
                $referenceRunMatchingPaths.Add($candidatePath)
            }
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        if ($candidatePath -ceq $PreflightRelativePath -or $candidatePath -ceq $ReferenceRunRelativePath) {
            throw
        }
    }
}

Assert-True ($preflightMatchingPaths.Count -eq 1) "phase3b2_preflight_assessment_inventory_count_mismatch"
Assert-True ($preflightMatchingPaths[0] -ceq $PreflightRelativePath) "phase3b2_preflight_assessment_inventory_path_mismatch"
Assert-True ($referenceRunMatchingPaths.Count -eq 1) "phase3b2_reference_run_assessment_inventory_count_mismatch"
Assert-True ($referenceRunMatchingPaths[0] -ceq $ReferenceRunRelativePath) "phase3b2_reference_run_assessment_inventory_path_mismatch"

$mode = if ($ContractOnly) { "contract-only" } else { "full baseline and contract" }
Write-Output "Phase 3B-2 $mode scaffold verification passed; preflight remains blocked and unmeasured, the reference run is not executed, and no tracked receipt makes a live-ready or original-client-result claim."
