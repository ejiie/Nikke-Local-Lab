#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Inspect')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Begin')]
    [switch]$BeginCapture,
    [Parameter(Mandatory = $true, ParameterSetName = 'Inspect')]
    [switch]$InspectCapture,
    [Parameter(Mandatory = $true, ParameterSetName = 'Inspect')]
    [string]$RequestManifestPath,
    [string]$RawFetchPath =
        'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json',
    [string]$SourceLocalLowRoot =
        'C:\Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE',
    [Parameter(ParameterSetName = 'Inspect')]
    [string]$ProgressionTemplateArchivePath = '',
    [string]$ParentSealReceiptPath =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c\seal.receipt.json',
    [string]$ParentGoldenDatabasePath =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c\db.json',
    [string]$StaticDataPackPath =
        'C:\NLL\Staging\PhysicalP0-v1\Inputs\staticdata\553116\StaticData.pack',
    [string]$OutputRoot = '',
    [Parameter(ParameterSetName = 'Inspect')]
    [switch]$RequireReady,
    [Parameter(ParameterSetName = 'Inspect')]
    [switch]$RequireFreshTriggerArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$requestContractId = 'nll/phase-c-same-capture-request/v1'
$inspectionContractId = 'nll/phase-c-same-capture-input-inspection/v2'
$expectedParentSealSha256 =
    'c4d5239fedf6520fd23043e963b704831689a3cf3baf35a533bd340a8cb5c3b0'
$expectedStaticDataSha256 =
    '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
$runtimeProcessNames = @(
    'NIKKE',
    'EpinelPS',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
)

function Write-PhaseCJson {
    param([string]$Path, [object]$Value)

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Get-PhaseCSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).
        Hash.ToLowerInvariant()
}

function Get-PhaseCDefaultOutputRoot {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $repositoryRoot 'artifacts\automation\phase-c-same-capture'
}

function Test-PhaseCRuntimeCold {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $runtimeProcessNames -contains $_.ProcessName }
    ).Count -eq 0
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Get-PhaseCDefaultOutputRoot
}
$outputRootResolved = [IO.Path]::GetFullPath($OutputRoot)

if ($PSCmdlet.ParameterSetName -ceq 'Begin') {
    if (-not (Test-PhaseCRuntimeCold)) {
        throw 'phase_c_same_capture_begin_runtime_not_cold'
    }

    $requestUid = [guid]::NewGuid().ToString('D')
    $requestRoot = Join-Path $outputRootResolved $requestUid
    $requestPath = Join-Path $requestRoot 'request.manifest.json'
    $requestedAt = [DateTimeOffset]::UtcNow
    $request = [ordered]@{
        schemaVersion = 1
        contractId = $requestContractId
        requestedAtUtc = $requestedAt.ToString('O')
        requestUid = $requestUid
        requiredInputCodes = @(
            'fresh_account_fetch_after_request',
            'fresh_matching_trigger_archive_after_request'
        )
        rawSourcePathPersisted = $false
        rawSourceHashPersisted = $false
        officialUserIdentifierPersisted = $false
        credentialOrSessionPersisted = $false
        officialLoginAutomated = $false
        officialFetchAutomated = $false
        clientExecutionStarted = $false
        serverExecutionStarted = $false
        nextStepCode = 'operator_produce_fresh_raw_and_trigger_archive_then_inspect'
    }
    Write-PhaseCJson -Path $requestPath -Value $request

    [ordered]@{
        Request = $request
        RequestManifestPath = $requestPath
        InspectCommand =
            "& '$PSCommandPath' -InspectCapture -RequestManifestPath '$requestPath' -RequireReady"
    } | ConvertTo-Json -Depth 8
    return
}

$reasons = New-Object System.Collections.Generic.List[string]
$runtimeCold = Test-PhaseCRuntimeCold
if (-not $runtimeCold) {
    $reasons.Add('runtime_not_cold')
}

$requestPresent = Test-Path -LiteralPath $RequestManifestPath -PathType Leaf
$request = $null
$requestValid = $false
$requestUid = $null
$requestedAt = [DateTimeOffset]::MinValue
if (-not $requestPresent) {
    $reasons.Add('request_manifest_missing')
}
else {
    try {
        $request = Get-Content -LiteralPath $RequestManifestPath -Raw |
            ConvertFrom-Json
        $parsedRequestUid = [guid]::Empty
        $parsedRequestedAt = [DateTimeOffset]::MinValue
        $requestValid =
            $request.schemaVersion -eq 1 -and
            $request.contractId -ceq $requestContractId -and
            [guid]::TryParse([string]$request.requestUid, [ref]$parsedRequestUid) -and
            [DateTimeOffset]::TryParse(
                [string]$request.requestedAtUtc,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsedRequestedAt) -and
            -not [bool]$request.rawSourcePathPersisted -and
            -not [bool]$request.rawSourceHashPersisted -and
            -not [bool]$request.officialUserIdentifierPersisted -and
            -not [bool]$request.credentialOrSessionPersisted -and
            -not [bool]$request.officialLoginAutomated -and
            -not [bool]$request.officialFetchAutomated
        if ($requestValid) {
            $requestUid = $parsedRequestUid.ToString('D')
            $requestedAt = $parsedRequestedAt.ToUniversalTime()
        }
        else {
            $reasons.Add('request_manifest_invalid')
        }
    }
    catch {
        $reasons.Add('request_manifest_invalid')
    }
}

$rawPresent = Test-Path -LiteralPath $RawFetchPath -PathType Leaf
$rawFresh = $false
$rawShapeValid = $false
$profileBasicInfoCount = 0
$rawText = $null
$raw = $null
if (-not $rawPresent) {
    $reasons.Add('raw_fetch_missing')
}
elseif ($requestValid) {
    $rawItem = Get-Item -LiteralPath $RawFetchPath
    $rawFresh = [DateTimeOffset]$rawItem.LastWriteTimeUtc -ge $requestedAt
    if (-not $rawFresh) {
        $reasons.Add('raw_fetch_predates_request')
    }
    try {
        $rawText = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RawFetchPath))
        $raw = $rawText | ConvertFrom-Json
        $packets = @($raw.phase_1_initial_load) + @($raw.phase_2_after_click)
        $profilePackets = @($packets | Where-Object {
                $_.endpoint -ceq 'GetUserProfileBasicInfo'
            })
        $profileBasicInfoCount = $profilePackets.Count
        $rawShapeValid =
            -not [string]::IsNullOrWhiteSpace([string]$raw.uid) -and
            $profilePackets.Count -eq 1 -and
            $null -ne $profilePackets[0].data.basic_info
        if (-not $rawShapeValid) {
            $reasons.Add('raw_fetch_shape_invalid')
        }
    }
    catch {
        $reasons.Add('raw_fetch_shape_invalid')
    }
}

$localLowPresent = Test-Path -LiteralPath $SourceLocalLowRoot -PathType Container
$triggerArchiveCount = 0
$freshTriggerArchiveCount = 0
$matchedFreshTriggerArchiveCount = 0
$matchedTriggerArchiveCount = 0
$matchingTriggerArchive = $false
$matchingTriggerArchiveFresh = $false
$stableTriggerReuseApplied = $false
$triggerArchiveFreshnessCode = 'no_unique_match'
$triggerArchiveBindingCode = 'unresolved'
$operatorSelectedProgressionTemplate = $false
if (-not $localLowPresent) {
    $reasons.Add('locallow_root_missing')
}
elseif ($requestValid) {
    $archiveCandidates = @(
        Get-ChildItem -LiteralPath $SourceLocalLowRoot -File -ErrorAction Stop |
            Where-Object { $_.Name -like 'NKSD_TRIGGER_*' }
    )
    $triggerArchiveCount = $archiveCandidates.Count
    $freshArchives = @($archiveCandidates | Where-Object {
            [DateTimeOffset]$_.LastWriteTimeUtc -ge $requestedAt
        })
    $freshTriggerArchiveCount = $freshArchives.Count
    if ($triggerArchiveCount -eq 0) {
        $reasons.Add('trigger_archive_missing')
    }
    if ($rawShapeValid) {
        $matched = @()
        if (-not [string]::IsNullOrWhiteSpace(
                $ProgressionTemplateArchivePath)) {
            try {
                $templateResolved =
                    [IO.Path]::GetFullPath($ProgressionTemplateArchivePath)
                $localLowPrefix =
                    [IO.Path]::GetFullPath($SourceLocalLowRoot).
                        TrimEnd([IO.Path]::DirectorySeparatorChar) +
                    [IO.Path]::DirectorySeparatorChar
                $templateValid =
                    $templateResolved.StartsWith(
                        $localLowPrefix,
                        [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath $templateResolved -PathType Leaf) -and
                    ([IO.Path]::GetFileName($templateResolved) -match
                        '^NKSD_TRIGGER_\d+_\d+$')
                if ($templateValid) {
                    $matched = @($archiveCandidates | Where-Object {
                            $_.FullName -ceq $templateResolved
                        })
                    $operatorSelectedProgressionTemplate =
                        $matched.Count -eq 1
                    if ($operatorSelectedProgressionTemplate) {
                        $triggerArchiveBindingCode =
                            'operator_selected_progression_template'
                    }
                }
                if (-not $operatorSelectedProgressionTemplate) {
                    $reasons.Add('progression_template_archive_invalid')
                }
            }
            catch {
                $reasons.Add('progression_template_archive_invalid')
            }
        }
        else {
            $matched = @($archiveCandidates | Where-Object {
                    if ($_.Name -notmatch '^NKSD_TRIGGER_\d+_(\d+)$') {
                        return $false
                    }
                    $identityToken = $Matches[1]
                    $pattern =
                        '(?<!\d)' + [regex]::Escape($identityToken) + '(?!\d)'
                    return [regex]::IsMatch($rawText, $pattern)
                })
            if ($matched.Count -eq 1) {
                $triggerArchiveBindingCode = 'raw_identity_matched_archive'
            }
        }
        $matchedTriggerArchiveCount = $matched.Count
        $matchedFreshTriggerArchiveCount = @($matched | Where-Object {
                [DateTimeOffset]$_.LastWriteTimeUtc -ge $requestedAt
            }).Count
        $matchingTriggerArchive = $matched.Count -eq 1
        if (-not $matchingTriggerArchive) {
            $reasons.Add('matching_trigger_archive_not_unique')
        }
        else {
            $matchingTriggerArchiveFresh =
                [DateTimeOffset]$matched[0].LastWriteTimeUtc -ge $requestedAt
            if ($matchingTriggerArchiveFresh) {
                $triggerArchiveFreshnessCode = 'fresh_after_request'
            }
            elseif ($RequireFreshTriggerArchive) {
                $triggerArchiveFreshnessCode = 'required_fresh_missing'
                $reasons.Add('trigger_archive_predates_request')
            }
            else {
                $triggerArchiveFreshnessCode = 'reused_stable_progression'
                $stableTriggerReuseApplied = $true
            }
        }
    }
}

$parentSealPresent = Test-Path -LiteralPath $ParentSealReceiptPath -PathType Leaf
$parentSealValid = $false
$parentGoldenDatabasePresent =
    Test-Path -LiteralPath $ParentGoldenDatabasePath -PathType Leaf
$parentGoldenDatabaseValid = $false
if (-not $parentSealPresent) {
    $reasons.Add('parent_seal_missing')
}
else {
    try {
        $parentSeal = Get-Content -LiteralPath $ParentSealReceiptPath -Raw |
            ConvertFrom-Json
        $parentSealValid =
            (Get-PhaseCSha256 $ParentSealReceiptPath) -ceq $expectedParentSealSha256 -and
            $parentSeal.contractId -ceq
                'nll/phase3b2-user-progression-parent-golden-seal/v1' -and
            [bool]$parentSeal.runtimeCold -and
            [bool]$parentSeal.databaseBackupVerified -and
            [bool]$parentSeal.sqliteAbsenceSealed
        if (-not $parentSealValid) {
            $reasons.Add('parent_seal_invalid')
        }
        if (-not $parentGoldenDatabasePresent) {
            $reasons.Add('parent_golden_database_missing')
        }
        else {
            $parentGoldenDatabaseValid =
                (Get-PhaseCSha256 $ParentGoldenDatabasePath) -ceq
                    ([string]$parentSeal.databaseSha256).ToLowerInvariant()
            if (-not $parentGoldenDatabaseValid) {
                $reasons.Add('parent_golden_database_drifted')
            }
        }
    }
    catch {
        if (-not ($reasons -contains 'parent_seal_invalid')) {
            $reasons.Add('parent_seal_invalid')
        }
    }
}

$staticDataPresent = Test-Path -LiteralPath $StaticDataPackPath -PathType Leaf
$staticDataValid = $false
if (-not $staticDataPresent) {
    $reasons.Add('static_data_pack_missing')
}
else {
    $staticDataValid =
        (Get-PhaseCSha256 $StaticDataPackPath) -ceq $expectedStaticDataSha256
    if (-not $staticDataValid) {
        $reasons.Add('static_data_pack_drifted')
    }
}

$uniqueReasons = @($reasons | Select-Object -Unique)
$ready =
    $requestValid -and $runtimeCold -and $rawFresh -and $rawShapeValid -and
    $matchingTriggerArchive -and
    (-not $RequireFreshTriggerArchive -or $matchingTriggerArchiveFresh) -and
    $parentSealValid -and
    $parentGoldenDatabaseValid -and $staticDataValid -and
    $uniqueReasons.Count -eq 0
$inspectionUid = [guid]::NewGuid().ToString('D')
$inspection = [ordered]@{
    schemaVersion = 1
    contractId = $inspectionContractId
    inspectedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    inspectionUid = $inspectionUid
    requestUid = $requestUid
    requestedAtUtc = if ($requestValid) { $requestedAt.ToString('O') } else { $null }
    runtimeCold = $runtimeCold
    rawFetchPresent = $rawPresent
    rawFetchFresh = $rawFresh
    rawFetchShapeValid = $rawShapeValid
    profileBasicInfoPacketCount = $profileBasicInfoCount
    localLowPresent = $localLowPresent
    triggerArchiveCount = $triggerArchiveCount
    freshTriggerArchiveCount = $freshTriggerArchiveCount
    matchedFreshTriggerArchiveCount = $matchedFreshTriggerArchiveCount
    matchedTriggerArchiveCount = $matchedTriggerArchiveCount
    matchingTriggerArchiveFresh = $matchingTriggerArchiveFresh
    freshTriggerArchiveRequired = [bool]$RequireFreshTriggerArchive
    stableTriggerReuseApplied = $stableTriggerReuseApplied
    triggerArchiveFreshnessCode = $triggerArchiveFreshnessCode
    triggerArchiveBindingCode = $triggerArchiveBindingCode
    operatorSelectedProgressionTemplate =
        $operatorSelectedProgressionTemplate
    parentSealValid = $parentSealValid
    parentGoldenDatabaseValid = $parentGoldenDatabaseValid
    staticDataPackValid = $staticDataValid
    readyForOfflineMaterialization = $ready
    reasonCodes = $uniqueReasons
    rawSourcePathPersisted = $false
    rawSourceHashPersisted = $false
    sourceTriggerArchivePathPersisted = $false
    sourceTriggerArchiveHashPersisted = $false
    officialUserIdentifierPersisted = $false
    credentialOrSessionPersisted = $false
    officialLoginAutomated = $false
    officialFetchAutomated = $false
    officialOutboundUsed = $false
    clientExecutionStarted = $false
    serverExecutionStarted = $false
    goldenModified = $false
    gameRuntimeModified = $false
    verdictCode = if ($ready) {
        'same_capture_inputs_ready_for_offline_materialization'
    } else {
        'same_capture_inputs_blocked'
    }
    nextStepCode = if ($ready) {
        'materialize_progression_and_account_snapshot_with_shared_uid'
    } else {
        'satisfy_reason_codes_and_reinspect'
    }
}

$requestRoot = if ($requestPresent) {
    Split-Path -Parent ([IO.Path]::GetFullPath($RequestManifestPath))
} else {
    Join-Path $outputRootResolved ('invalid-request-' + $inspectionUid)
}
$inspectionPath = Join-Path $requestRoot 'input-inspection.receipt.json'
Write-PhaseCJson -Path $inspectionPath -Value $inspection

$result = [ordered]@{
    Inspection = $inspection
    InspectionReceiptPath = $inspectionPath
    InspectionReceiptSha256 = Get-PhaseCSha256 $inspectionPath
}
$resultJson = $result | ConvertTo-Json -Depth 10
$resultJson

if ($RequireReady -and -not $ready) {
    throw ('phase_c_same_capture_inputs_blocked:' + ($uniqueReasons -join ','))
}
