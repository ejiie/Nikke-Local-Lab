[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$BaselineAssessmentUid =
        '78c37245-ea49-442d-becf-b1e871f98d68',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}

$mutationStarted = $false
$backupCreated = $false
$preparationArchived = $false
$runtimeBackupArchived = $false
$protectedPreparationArchived = $false

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ManifestLines {
    param([string[]]$Paths, [string]$BasePath)
    $canonicalBase = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    @($Paths | Sort-Object | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        $canonicalPath = [IO.Path]::GetFullPath($item.FullName)
        Assert-True ($canonicalPath.StartsWith(
                $canonicalBase, [StringComparison]::OrdinalIgnoreCase)) `
            'phase3b2_baseline_interactive_manifest_member_outside_base'
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
}

try {
    $isAdministrator = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $ValidateOnly) {
        Assert-True $isAdministrator `
            'phase3b2_baseline_interactive_repair_requires_administrator'
    }

    $micronLetter = $MicronDrive.TrimEnd(':')
    $diskBoundaryVerified = $false
    if ($isAdministrator) {
        $systemDisk = Get-Partition -DriveLetter C | Get-Disk
        $micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
        Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
            $systemDisk.IsBoot -and $systemDisk.IsSystem -and
            $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
            -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
            'phase3b2_baseline_interactive_repair_disk_boundary_invalid'
        $diskBoundaryVerified = $true
    }
    else {
        Assert-True ($ValidateOnly -and
            (Test-Path -LiteralPath (Join-Path $MicronDrive 'Windows') `
                -PathType Container)) `
            'phase3b2_baseline_interactive_repair_disk_boundary_deferred_invalid'
    }
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_baseline_interactive_repair_runtime_not_cold'

    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $sourceStartPath = Join-Path $RepositoryRoot `
        'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $sourceCompletionPath = Join-Path $RepositoryRoot `
        'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $sourceWrapperPath = Join-Path $RepositoryRoot `
        'scripts\Start-Phase3B2-Physical-P2-V2.ps1'
    $targetStartPath = Join-Path $toolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetCompletionPath = Join-Path $toolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetWrapperPath = Join-Path $toolRoot `
        'Start-Phase3B2-Physical-P2-V2.ps1'
    $manifestPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $repairReceiptPath = Join-Path $transferRoot `
        'baseline-backed-interactive-repair.receipt.json'
    $protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
    $protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
        'offline-deployment.receipt.json'
    $protectedRepairPath = Join-Path $protectedDeploymentRoot `
        'baseline-backed-interactive-repair.receipt.json'

    $p2EvidenceRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
    $baselineRunRoot = Join-Path $p2EvidenceRoot $BaselineAssessmentUid
    $baselineMeasurementPath = Join-Path $baselineRunRoot `
        'ten-minute-measurement.receipt.json'
    $baselineRunStartPath = Join-Path $baselineRunRoot `
        'run-start.receipt.json'
    $baselineFailurePath = Join-Path $baselineRunRoot `
        'run-failure.receipt.json'
    $baselineRequestStagePath = Join-Path $baselineRunRoot `
        'server-request-stage.jsonl'
    $protectedBaselineRunRoot = Join-Path `
        (Join-Path $SamsungProtectedRoot 'RunsV2') $BaselineAssessmentUid
    $protectedBaselineMeasurementPath = Join-Path $protectedBaselineRunRoot `
        'ten-minute-measurement.receipt.json'
    $protectedBaselineRunStartPath = Join-Path $protectedBaselineRunRoot `
        'run-start.receipt.json'
    $protectedBaselineFailurePath = Join-Path $protectedBaselineRunRoot `
        'run-failure.receipt.json'
    $priorRetryConsumptionPath = Join-Path $p2EvidenceRoot `
        'live-log-seal-retry.consumed.json'
    $newRetryConsumptionPath = Join-Path $p2EvidenceRoot `
        'baseline-backed-interactive-retry.consumed.json'

    $preparationRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
    $preparationReceiptPath = Join-Path $preparationRoot `
        'preparation.receipt.json'
    $runtimeBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2'
    $protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'PreparationV2'
    $protectedPreparationReceiptPath = Join-Path $protectedPreparationRoot `
        'preparation.receipt.json'
    $archiveSuffix = '.baseline-interactive-' + $BaselineAssessmentUid
    $preparationArchive = $preparationRoot + $archiveSuffix
    $runtimeBackupArchive = $runtimeBackupRoot + $archiveSuffix
    $protectedPreparationArchive = $protectedPreparationRoot + $archiveSuffix

    $backupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2-BaselineInteractiveRepair-v1'
    $backupToolRoot = Join-Path $backupRoot 'tools'
    $backupEvidenceRoot = Join-Path $backupRoot 'evidence'
    $backupReceiptRoot = Join-Path $backupRoot 'receipts'
    $backupStartPath = Join-Path $backupToolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupCompletionPath = Join-Path $backupToolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $backupWrapperPath = Join-Path $backupToolRoot `
        'Start-Phase3B2-Physical-P2-V2.ps1'
    $backupManifestPath = Join-Path $backupEvidenceRoot 'tools.manifest.tsv'
    $backupDeploymentPath = Join-Path $backupReceiptRoot `
        'micron-deployment.receipt.json'
    $backupProtectedDeploymentPath = Join-Path $backupReceiptRoot `
        'samsung-offline-deployment.receipt.json'

    Assert-True ((Test-PathDigest $targetStartPath 54125L `
            '7e6384b5df8cbba5160b17ff1b127502849591c0c14afd41ceaf658f76c96031') -and
        (Test-PathDigest $targetCompletionPath 16172L `
            'b692400a6bc30c2067e669bd0cf5f9b52f6b7510423ae8b8144e27e3bece21f1') -and
        (Test-PathDigest $targetWrapperPath 672L `
            '2f948ed8a3c2f158a9b6d8bbb67a3624116e005026e4de3810364c3c367b5394') -and
        (Test-PathDigest $manifestPath 799L `
            'abf29a09e8e8285807bbc74498dd6323e0d1f8a30997f873d6b0f5d964fd6823') -and
        (Test-PathDigest $deploymentPath 6296L `
            '0f9f5aefc8325adfe8cb26cb887af7dcc3c0cdc64e4e41f8ed703bdc6f5770e8') -and
        (Test-PathDigest $protectedDeploymentPath 6296L `
            '0f9f5aefc8325adfe8cb26cb887af7dcc3c0cdc64e4e41f8ed703bdc6f5770e8')) `
        'phase3b2_baseline_interactive_deployment_baseline_invalid'

    Assert-True ((Test-PathDigest $sourceStartPath 59278L `
            '96105d2cdc092467dbb3bfb66b8b1b2ac8f60a80f73def68406ae4ec9827b0eb') -and
        (Test-PathDigest $sourceCompletionPath 18812L `
            'a32f229d12e786f7a32f1575ef3eea3bfa6c3e3255d2c21c4e7892a7db16f0df') -and
        (Test-PathDigest $sourceWrapperPath 670L `
            '1d904ed6c43cf5659b77e9c61a07ebdaae64b8a01b2b8c65ac9f2c12662be211')) `
        'phase3b2_baseline_interactive_source_pin_invalid'
    $sourceStartText = Get-Content -LiteralPath $sourceStartPath -Raw `
        -Encoding UTF8
    $sourceCompletionText = Get-Content -LiteralPath $sourceCompletionPath `
        -Raw -Encoding UTF8
    $sourceWrapperText = Get-Content -LiteralPath $sourceWrapperPath -Raw `
        -Encoding UTF8
    $copyBlockStart = $sourceStartText.IndexOf(
        '$stageCode = ''protected_immutable_evidence_copy''',
        [StringComparison]::Ordinal)
    $copyBlockEnd = $sourceStartText.IndexOf(
        '$receipt | ConvertTo-Json', $copyBlockStart,
        [StringComparison]::Ordinal)
    Assert-True ($copyBlockStart -ge 0 -and $copyBlockEnd -gt $copyBlockStart) `
        'phase3b2_baseline_interactive_immutable_copy_block_missing'
    $copyBlock = $sourceStartText.Substring(
        $copyBlockStart, $copyBlockEnd - $copyBlockStart)
    Assert-True ($copyBlock -cnotmatch
            '\$(stdoutPath|stderrPath|requestStagePath)' -and
        $sourceStartText -cmatch
            'liveRuntimeFilesDeferredToCompletion\s*=\s*\$true' -and
        $sourceCompletionText -cmatch
            'liveRuntimeFilesCollectedAfterStop\s*=\s*\$true' -and
        $sourceCompletionText -cmatch
            'startup-health-measurement/v1' -and
        $sourceWrapperText -cmatch
            '-MeasurementSeconds\s+30\s+-SampleIntervalSeconds\s+2') `
        'phase3b2_baseline_interactive_source_contract_invalid'

    Assert-True ((Test-PathDigest $baselineMeasurementPath 2696L `
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538') -and
        (Test-PathDigest $baselineRunStartPath 2096L `
            '777657d03588a4c8a32d35f350f1faaee74eb1a50ce99cb8407d2b33dd06f5ac') -and
        (Test-PathDigest $baselineFailurePath 1717L `
            '2ea848a0e066226701a635441ec9b94f55f313c9cf2194789f068b2b2fa3a782') -and
        (Test-PathDigest $protectedBaselineMeasurementPath 2696L `
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538') -and
        (Test-PathDigest $protectedBaselineRunStartPath 2096L `
            '777657d03588a4c8a32d35f350f1faaee74eb1a50ce99cb8407d2b33dd06f5ac') -and
        (Test-PathDigest $protectedBaselineFailurePath 1717L `
            '2ea848a0e066226701a635441ec9b94f55f313c9cf2194789f068b2b2fa3a782') -and
        (Test-PathDigest $priorRetryConsumptionPath 579L `
            '99434f40047836ea387932b38a38f74ce9713a86a273a9f6b0899fd1c9ee0655')) `
        'phase3b2_baseline_interactive_evidence_pin_invalid'

    $baselineMeasurement = Get-Content -LiteralPath $baselineMeasurementPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    $baselineRunStart = Get-Content -LiteralPath $baselineRunStartPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    $baselineFailure = Get-Content -LiteralPath $baselineFailurePath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    $requestStageItem = Get-Item -LiteralPath $baselineRequestStagePath
    Assert-True ($baselineMeasurement.contractId -ceq
            'nll/phase3b2-physical-p2-v2-ten-minute-measurement/v1' -and
        $baselineMeasurement.assessmentUid -ceq $BaselineAssessmentUid -and
        [long]$baselineMeasurement.measuredDurationMilliseconds -ge 600000L -and
        [int]$baselineMeasurement.sampleCount -eq 121 -and
        [int]$baselineMeasurement.expectedSampleCount -eq 121 -and
        [int]$baselineMeasurement.respondingSampleCount -eq 121 -and
        [int]$baselineMeasurement.unresponsiveSampleCount -eq 0 -and
        [int]$baselineMeasurement.successfulNonLoopbackConnectionCount -eq 0 -and
        $baselineMeasurement.auditPolicyRestored -and
        $baselineMeasurement.dnsChannelRestored -and
        $baselineRunStart.contractId -ceq
            'nll/phase3b2-physical-p2-v2-client-start/v1' -and
        $baselineRunStart.assessmentUid -ceq $BaselineAssessmentUid -and
        $baselineRunStart.minimumTenMinuteObservationCompleted -and
        $baselineRunStart.serverRunning -and
        $baselineRunStart.clientExecutionStarted -and
        $baselineFailure.contractId -ceq
            'nll/phase3b2-physical-p2-v2-client-start-failure/v1' -and
        $baselineFailure.assessmentUid -ceq $BaselineAssessmentUid -and
        $baselineFailure.runtimeStopped -and
        $baselineFailure.databaseRestored -and
        $baselineFailure.sqliteRuntimeRemoved -and
        $baselineFailure.hostsRestored -and
        $baselineFailure.extensionFirewallRolledBack -and
        $requestStageItem.LastWriteTimeUtc -gt
            ([DateTimeOffset]::Parse([string]$baselineRunStart.startedAtUtc)).UtcDateTime) `
        'phase3b2_baseline_interactive_evidence_contract_invalid'

    Assert-True ((Test-PathDigest $preparationReceiptPath 1693L `
            '1de277d6421ae0bb81e98ed02401389e475c8dba00327c94f055ee8a9af4f795') -and
        (Test-PathDigest $protectedPreparationReceiptPath 1693L `
            '1de277d6421ae0bb81e98ed02401389e475c8dba00327c94f055ee8a9af4f795') -and
        (Test-Path -LiteralPath $runtimeBackupRoot -PathType Container) -and
        (Test-PathDigest (Join-Path $MicronDrive `
                'Windows\System32\drivers\etc\hosts') 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
        -not (Test-Path -LiteralPath (Join-Path $p2EvidenceRoot `
                'active-run.pointer.json')) -and
        -not (Test-Path -LiteralPath $newRetryConsumptionPath) -and
        -not (Test-Path -LiteralPath $preparationArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $backupRoot) -and
        -not (Test-Path -LiteralPath $repairReceiptPath) -and
        -not (Test-Path -LiteralPath $protectedRepairPath)) `
        'phase3b2_baseline_interactive_state_shape_invalid'

    if ($ValidateOnly) {
        [pscustomobject]@{
            ContractId =
                'nll/phase3b2-p2-v2-baseline-backed-interactive-repair-preflight/v1'
            BaselineAssessmentUid = $BaselineAssessmentUid
            BaselineTenMinuteMeasurementVerified = $true
            BaselineMeasurementSeconds = 600
            BaselineObservedSampleCount = 121
            BaselineRespondingSampleCount = 121
            BaselineUnresponsiveSampleCount = 0
            LiveRuntimeCopyBlockingCauseConfirmed = $true
            LiveRuntimeFilesDeferredToCompletion = $true
            InteractiveMeasurementSeconds = 30
            InteractiveSampleIntervalSeconds = 2
            EndpointContractChangePlanned = $false
            MutationRequiresAdministrator = $true
            CurrentProcessIsAdministrator = $isAdministrator
            DiskBoundaryVerified = $diskBoundaryVerified
            MutationPerformed = $false
        } | ConvertTo-Json -Depth 6
        return
    }

    New-Item -ItemType Directory -Path $backupToolRoot, $backupEvidenceRoot,
        $backupReceiptRoot -Force | Out-Null
    Copy-Item -LiteralPath $targetStartPath -Destination $backupStartPath
    Copy-Item -LiteralPath $targetCompletionPath `
        -Destination $backupCompletionPath
    Copy-Item -LiteralPath $targetWrapperPath -Destination $backupWrapperPath
    Copy-Item -LiteralPath $manifestPath -Destination $backupManifestPath
    Copy-Item -LiteralPath $deploymentPath -Destination $backupDeploymentPath
    Copy-Item -LiteralPath $protectedDeploymentPath `
        -Destination $backupProtectedDeploymentPath
    $backupCreated = $true
    Assert-True ((Test-PathDigest $backupStartPath 54125L `
            '7e6384b5df8cbba5160b17ff1b127502849591c0c14afd41ceaf658f76c96031') -and
        (Test-PathDigest $backupCompletionPath 16172L `
            'b692400a6bc30c2067e669bd0cf5f9b52f6b7510423ae8b8144e27e3bece21f1') -and
        (Test-PathDigest $backupWrapperPath 672L `
            '2f948ed8a3c2f158a9b6d8bbb67a3624116e005026e4de3810364c3c367b5394') -and
        (Test-PathDigest $backupManifestPath 799L `
            'abf29a09e8e8285807bbc74498dd6323e0d1f8a30997f873d6b0f5d964fd6823') -and
        (Test-PathDigest $backupDeploymentPath 6296L `
            '0f9f5aefc8325adfe8cb26cb887af7dcc3c0cdc64e4e41f8ed703bdc6f5770e8') -and
        (Test-PathDigest $backupProtectedDeploymentPath 6296L `
            '0f9f5aefc8325adfe8cb26cb887af7dcc3c0cdc64e4e41f8ed703bdc6f5770e8')) `
        'phase3b2_baseline_interactive_backup_verification_failed'

    $mutationStarted = $true
    Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force
    Copy-Item -LiteralPath $sourceCompletionPath `
        -Destination $targetCompletionPath -Force
    Copy-Item -LiteralPath $sourceWrapperPath `
        -Destination $targetWrapperPath -Force

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    foreach ($toolUpdate in @(
            [pscustomobject]@{
                Name = 'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetStartPath
                PriorSha256 =
                    '7e6384b5df8cbba5160b17ff1b127502849591c0c14afd41ceaf658f76c96031'
            },
            [pscustomobject]@{
                Name = 'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetCompletionPath
                PriorSha256 =
                    'b692400a6bc30c2067e669bd0cf5f9b52f6b7510423ae8b8144e27e3bece21f1'
            },
            [pscustomobject]@{
                Name = 'Start-Phase3B2-Physical-P2-V2.ps1'
                Path = $targetWrapperPath
                PriorSha256 =
                    '2f948ed8a3c2f158a9b6d8bbb67a3624116e005026e4de3810364c3c367b5394'
            })) {
        $entry = @($deployment.tools | Where-Object {
            $_.name -ceq $toolUpdate.Name
        })
        Assert-True ($entry.Count -eq 1 -and
            [string]$entry[0].sha256 -ceq $toolUpdate.PriorSha256) `
            'phase3b2_baseline_interactive_deployment_tool_entry_invalid'
        $entry[0].byteLength = (Get-Item -LiteralPath $toolUpdate.Path).Length
        $entry[0].sha256 = Get-Sha256Hex $toolUpdate.Path
    }
    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_baseline_interactive_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength = (Get-Item $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment.minimumMeasurementSeconds = 30
    $deployment | Add-Member -NotePropertyName measurementModeCode `
        -NotePropertyValue `
            'verified_ten_minute_baseline_backed_interactive_startup' -Force
    $deployment | Add-Member -NotePropertyName baselineAssessmentUid `
        -NotePropertyValue $BaselineAssessmentUid -Force
    $deployment | Add-Member -NotePropertyName baselineMeasurementSeconds `
        -NotePropertyValue 600 -Force
    $deployment | Add-Member -NotePropertyName baselineTenMinuteMeasurementSha256 `
        -NotePropertyValue `
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538' -Force
    $deployment | Add-Member -NotePropertyName `
        baselineTenMinuteMeasurementVerified -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName interactiveMeasurementSeconds `
        -NotePropertyValue 30 -Force
    $deployment | Add-Member -NotePropertyName interactiveSampleIntervalSeconds `
        -NotePropertyValue 2 -Force
    $deployment | Add-Member -NotePropertyName liveRuntimeFilesDeferredToCompletion `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName singleInteractiveRetryAuthorized `
        -NotePropertyValue $true -Force
    $deployment.latestFailedAssessmentUid = $BaselineAssessmentUid
    $deployment.endpointContractChanged = $false
    $deployment.nextStepCode =
        'boot_micron_as_nlloperator_and_run_baseline_backed_interactive_start_once'
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 12) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force

    $preparationReceiptSha256 = Get-Sha256Hex $preparationReceiptPath
    Move-Item -LiteralPath $preparationRoot -Destination $preparationArchive
    $preparationArchived = $true
    Move-Item -LiteralPath $runtimeBackupRoot -Destination $runtimeBackupArchive
    $runtimeBackupArchived = $true
    Move-Item -LiteralPath $protectedPreparationRoot `
        -Destination $protectedPreparationArchive
    $protectedPreparationArchived = $true

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-baseline-backed-interactive-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        baselineAssessmentUid = $BaselineAssessmentUid
        baselineTenMinuteMeasurementVerified = $true
        baselineTenMinuteMeasurementByteLength = 2696
        baselineTenMinuteMeasurementSha256 =
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        baselineRunStartReceiptSha256 =
            '777657d03588a4c8a32d35f350f1faaee74eb1a50ce99cb8407d2b33dd06f5ac'
        baselineFailureReceiptSha256 =
            '2ea848a0e066226701a635441ec9b94f55f313c9cf2194789f068b2b2fa3a782'
        baselineMeasurementSeconds = 600
        baselineExpectedSampleCount = 121
        baselineObservedSampleCount = 121
        baselineRespondingSampleCount = 121
        baselineUnresponsiveSampleCount = 0
        serverSelectionObserved = $true
        causeCode = 'live_server_request_stage_copy_waited_for_writer_shutdown'
        causeEvidenceCode =
            'run_start_sealed_before_live_request_log_final_write_and_failure'
        liveRuntimeFilesDeferredToCompletion = $true
        deferredRuntimeFileRoleCodes = @(
            'server_stdout', 'server_stderr', 'server_request_stage')
        immutableStartEvidenceProtectedCopyEnabled = $true
        interactiveMeasurementSeconds = 30
        interactiveSampleIntervalSeconds = 2
        measurementModeCode =
            'verified_ten_minute_baseline_backed_interactive_startup'
        endpointContractChanged = $false
        admittedEndpointCount = 1
        dedicatedOperatorCachePreserved = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        priorAutomaticRollbackVerified = $true
        priorRetryConsumptionPreserved = $true
        priorRetryConsumptionSha256 = Get-Sha256Hex $priorRetryConsumptionPath
        priorPreparationArchived = $true
        verifiedRollbackBackupPresent = $true
        singleInteractiveRetryAuthorized = $true
        retryConsumed = $false
        repairedStartToolByteLength = (Get-Item $targetStartPath).Length
        repairedStartToolSha256 = Get-Sha256Hex $targetStartPath
        repairedCompletionToolByteLength =
            (Get-Item $targetCompletionPath).Length
        repairedCompletionToolSha256 = Get-Sha256Hex $targetCompletionPath
        repairedWrapperToolByteLength = (Get-Item $targetWrapperPath).Length
        repairedWrapperToolSha256 = Get-Sha256Hex $targetWrapperPath
        repairedToolManifestByteLength = (Get-Item $manifestPath).Length
        repairedToolManifestSha256 = Get-Sha256Hex $manifestPath
        repairedDeploymentReceiptByteLength = (Get-Item $deploymentPath).Length
        repairedDeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStartedAfterRepair = $false
        nextStepCode =
            'boot_micron_as_nlloperator_and_run_baseline_backed_interactive_start_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 9) + "`n")
    Copy-Item -LiteralPath $repairReceiptPath `
        -Destination $protectedRepairPath -Force
    Assert-True ((Get-Sha256Hex $targetStartPath) -ceq
            (Get-Sha256Hex $sourceStartPath) -and
        (Get-Sha256Hex $targetCompletionPath) -ceq
            (Get-Sha256Hex $sourceCompletionPath) -and
        (Get-Sha256Hex $targetWrapperPath) -ceq
            (Get-Sha256Hex $sourceWrapperPath) -and
        (Get-Sha256Hex $deploymentPath) -ceq
            (Get-Sha256Hex $protectedDeploymentPath) -and
        (Get-Sha256Hex $repairReceiptPath) -ceq
            (Get-Sha256Hex $protectedRepairPath)) `
        'phase3b2_baseline_interactive_post_apply_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $repairReceiptPath
        MicronReceiptByteLength = (Get-Item $repairReceiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        SamsungProtectedReceiptPath = $protectedRepairPath
    } | ConvertTo-Json -Depth 11
}
catch {
    if ($mutationStarted -and $backupCreated) {
        Copy-Item -LiteralPath $backupStartPath -Destination $targetStartPath `
            -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupCompletionPath `
            -Destination $targetCompletionPath -Force `
            -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupWrapperPath `
            -Destination $targetWrapperPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupManifestPath -Destination $manifestPath `
            -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupDeploymentPath `
            -Destination $deploymentPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $backupProtectedDeploymentPath `
            -Destination $protectedDeploymentPath -Force `
            -ErrorAction SilentlyContinue
    }
    if ($protectedPreparationArchived -and
        (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationRoot)) {
        Move-Item -LiteralPath $protectedPreparationArchive `
            -Destination $protectedPreparationRoot -ErrorAction SilentlyContinue
    }
    if ($runtimeBackupArchived -and
        (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupRoot)) {
        Move-Item -LiteralPath $runtimeBackupArchive `
            -Destination $runtimeBackupRoot -ErrorAction SilentlyContinue
    }
    if ($preparationArchived -and
        (Test-Path -LiteralPath $preparationArchive) -and
        -not (Test-Path -LiteralPath $preparationRoot)) {
        Move-Item -LiteralPath $preparationArchive `
            -Destination $preparationRoot -ErrorAction SilentlyContinue
    }
    foreach ($path in @($repairReceiptPath, $protectedRepairPath)) {
        if ($path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    throw
}
