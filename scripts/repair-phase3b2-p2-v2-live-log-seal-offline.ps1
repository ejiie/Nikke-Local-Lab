[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$FailedAssessmentUid =
        '88245ca5-08d2-4b09-a855-e875bf37bc22',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$mutationStarted = $false
$backupVerified = $false
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
            'phase3b2_p2_v2_live_log_repair_manifest_member_outside_base'
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
            'phase3b2_p2_v2_live_log_repair_requires_administrator'
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
            'phase3b2_p2_v2_live_log_repair_disk_boundary_invalid'
        $diskBoundaryVerified = $true
    }
    else {
        Assert-True ($ValidateOnly -and
            (Test-Path -LiteralPath (Join-Path $MicronDrive 'Windows') `
                -PathType Container)) `
            'phase3b2_p2_v2_live_log_repair_disk_boundary_deferred_invalid'
    }
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_p2_v2_live_log_repair_runtime_not_cold'

    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $sourceStartPath = Join-Path $RepositoryRoot `
        'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetStartPath = Join-Path $toolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $manifestPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
    $protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
    $protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
        'offline-deployment.receipt.json'
    $priorRepairPath = Join-Path $transferRoot `
        'measurement-observation-repair.receipt.json'
    $protectedPriorRepairPath = Join-Path $protectedDeploymentRoot `
        'measurement-observation-repair.receipt.json'
    $repairReceiptPath = Join-Path $transferRoot `
        'live-log-seal-repair.receipt.json'
    $protectedRepairPath = Join-Path $protectedDeploymentRoot `
        'live-log-seal-repair.receipt.json'

    $p2EvidenceRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
    $failedRunRoot = Join-Path $p2EvidenceRoot $FailedAssessmentUid
    $failurePath = Join-Path $failedRunRoot 'run-failure.receipt.json'
    $bootstrapPath = Join-Path $failedRunRoot 'bootstrap-start.receipt.json'
    $healthPath = Join-Path $failedRunRoot 'client-health-samples.json'
    $requestSummaryPath = Join-Path $failedRunRoot `
        'server-request-stage-summary.json'
    $priorRetryConsumptionPath = Join-Path $p2EvidenceRoot `
        'measurement-observation-retry.consumed.json'
    $newRetryConsumptionPath = Join-Path $p2EvidenceRoot `
        'live-log-seal-retry.consumed.json'
    $protectedFailedRunRoot = Join-Path `
        (Join-Path $SamsungProtectedRoot 'RunsV2') $FailedAssessmentUid
    $protectedFailurePath = Join-Path $protectedFailedRunRoot `
        'run-failure.receipt.json'

    $preparationRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
    $preparationReceiptPath = Join-Path $preparationRoot `
        'preparation.receipt.json'
    $runtimeBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2'
    $protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'PreparationV2'
    $protectedPreparationReceiptPath = Join-Path $protectedPreparationRoot `
        'preparation.receipt.json'
    $archiveSuffix = '.failed-live-log-seal-' + $FailedAssessmentUid
    $preparationArchive = $preparationRoot + $archiveSuffix
    $runtimeBackupArchive = $runtimeBackupRoot + $archiveSuffix
    $protectedPreparationArchive = $protectedPreparationRoot + $archiveSuffix

    $repairBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2-LiveLogSealRepair-v1'
    $repairBackupToolPath = Join-Path $repairBackupRoot `
        'start.before.ps1'
    $repairBackupManifestPath = Join-Path $repairBackupRoot `
        'tools.manifest.before.tsv'
    $repairBackupDeploymentPath = Join-Path $repairBackupRoot `
        'micron-deployment.before.json'
    $repairBackupProtectedDeploymentPath = Join-Path $repairBackupRoot `
        'samsung-deployment.before.json'
    $existingRepairBackupPresent = Test-Path -LiteralPath $repairBackupRoot `
        -PathType Container

    Assert-True ((Test-PathDigest $targetStartPath 51530L `
            'a96d05bbf48eabc5891ed0d33f5241d041b9fe5f0fadad7ae1fb25cc843f553f') -and
        (Test-PathDigest $manifestPath 799L `
            'b03fead1851f4c51198fbfb6b1df07d3821077ab9029d7132f701562c21cd4f3') -and
        (Test-PathDigest $deploymentPath 5998L `
            '3b37c74a7f8644327ad27353ffac7f4e61c37fee6cd32714d6f9246fa1e57850') -and
        (Test-PathDigest $protectedDeploymentPath 5998L `
            '3b37c74a7f8644327ad27353ffac7f4e61c37fee6cd32714d6f9246fa1e57850') -and
        (Test-PathDigest $priorRepairPath 4542L `
            'c684dd498cef0b79ac3da97835ea958f189708384cda3e0e727c89fcf9b8c448') -and
        (Test-PathDigest $protectedPriorRepairPath 4542L `
            'c684dd498cef0b79ac3da97835ea958f189708384cda3e0e727c89fcf9b8c448')) `
        'phase3b2_p2_v2_live_log_repair_deployment_baseline_invalid'
    Assert-True ((Test-PathDigest $failurePath 1606L `
            '7a049da69dcbb077fbb5eeff8f8ab6ddfcbfc7063bda2520a76d8915cd64e139') -and
        (Test-PathDigest $protectedFailurePath 1606L `
            '7a049da69dcbb077fbb5eeff8f8ab6ddfcbfc7063bda2520a76d8915cd64e139') -and
        (Test-PathDigest $bootstrapPath 1088L `
            'fa0a8436a5babd306927996a95da66307684fbb5a91c806b23ca6dbbac2b5b6e') -and
        (Test-PathDigest $healthPath 98472L `
            '936f5ef327076e88ed9f2769eee23a06a35549c77057353a5a11f71efc337f12') -and
        (Test-PathDigest $requestSummaryPath 2027L `
            'fd4cd710e5d3db148fe8bdb37738b5ccb1651b03787d08a0ff8c6f93656237f4') -and
        (Test-PathDigest $priorRetryConsumptionPath 589L `
            '6a98bdbf5e7893fd3a2e5973c358fc6037909a0a79f1ce4e6bbccc3baef01eac')) `
        'phase3b2_p2_v2_live_log_repair_failure_evidence_invalid'
    Assert-True ((Test-PathDigest $preparationReceiptPath 1693L `
            'b8eafb6717c9ce6377cd9b011bd6f9ed30a4d9e80d0028ea06ad3a8493a0f98a') -and
        (Test-PathDigest $protectedPreparationReceiptPath 1693L `
            'b8eafb6717c9ce6377cd9b011bd6f9ed30a4d9e80d0028ea06ad3a8493a0f98a') -and
        (Test-Path -LiteralPath $runtimeBackupRoot -PathType Container) -and
        (Test-PathDigest (Join-Path $MicronDrive `
                'Windows\System32\drivers\etc\hosts') 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
        -not (Test-Path -LiteralPath $preparationArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $repairReceiptPath) -and
        -not (Test-Path -LiteralPath $protectedRepairPath) -and
        -not (Test-Path -LiteralPath $newRetryConsumptionPath)) `
        'phase3b2_p2_v2_live_log_repair_state_shape_invalid'

    $failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $requestSummary = Get-Content -LiteralPath $requestSummaryPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($failure.contractId -ceq
            'nll/phase3b2-physical-p2-v2-client-start-failure/v1' -and
        $failure.assessmentUid -ceq $FailedAssessmentUid -and
        $failure.failedStageCode -ceq 'dns_wfp_and_server_stage_seal' -and
        [long]$failure.measurementDurationMilliseconds -ge 600000L -and
        [int]$failure.measurementExpectedSampleCount -eq 121 -and
        [int]$failure.measurementObservedSampleCount -eq 121 -and
        [int]$failure.respondingSampleCount -eq 121 -and
        [int]$failure.unresponsiveSampleCount -eq 0 -and
        $failure.runtimeStopped -and $failure.databaseRestored -and
        $failure.sqliteRuntimeRemoved -and $failure.hostsRestored -and
        $failure.extensionFirewallRolledBack -and
        $bootstrap.sailNamedPipeClosedAfterPayload -and
        $bootstrap.sailHandoffLifecycleCode -ceq
            'payload_then_pipe_eof_shared_memory_retained' -and
        [int]$requestSummary.requestStartedCount -eq 16 -and
        [int]$requestSummary.requestCompletedCount -eq 16) `
        'phase3b2_p2_v2_live_log_repair_failure_contract_invalid'

    $screenshotRoot = Join-Path $MicronDrive `
        'Users\nlloperator\Pictures\Screenshots'
    $screenshotMatches = @(Get-ChildItem -LiteralPath $screenshotRoot -File `
        -Filter '*.png' -ErrorAction SilentlyContinue | Where-Object {
            $_.Length -eq 554363L -and
            (Get-Sha256Hex $_.FullName) -ceq
                '219cd5c99391216dfe53ec0f265139b1cf513fb04dd99916d4cde974126c72c2'
        })
    Assert-True ($screenshotMatches.Count -eq 1) `
        'phase3b2_p2_v2_live_log_repair_screenshot_resolution_invalid'
    $serverSelectionScreenshotPath = $screenshotMatches[0].FullName

    Assert-True (Test-PathDigest $sourceStartPath 54125L `
        '7e6384b5df8cbba5160b17ff1b127502849591c0c14afd41ceaf658f76c96031') `
        'phase3b2_p2_v2_live_log_repair_source_pin_invalid'
    $sourceText = Get-Content -LiteralPath $sourceStartPath -Raw -Encoding UTF8
    Assert-True ($sourceText -cmatch
            'shared_read_bounded_in_memory_digest_no_raw_persistence' -and
        $sourceText -cmatch '\[IO\.FileShare\]::ReadWrite\s+-bor\s+' -and
        $sourceText -cmatch '\[IO\.FileShare\]::Delete' -and
        $sourceText -cmatch 'live-log-seal-repair\.receipt\.json') `
        'phase3b2_p2_v2_live_log_repair_source_contract_invalid'

    if ($existingRepairBackupPresent) {
        Assert-True ((Test-PathDigest $repairBackupToolPath 51530L `
                'a96d05bbf48eabc5891ed0d33f5241d041b9fe5f0fadad7ae1fb25cc843f553f') -and
            (Test-PathDigest $repairBackupManifestPath 799L `
                'b03fead1851f4c51198fbfb6b1df07d3821077ab9029d7132f701562c21cd4f3') -and
            (Test-PathDigest $repairBackupDeploymentPath 5998L `
                '3b37c74a7f8644327ad27353ffac7f4e61c37fee6cd32714d6f9246fa1e57850') -and
            (Test-PathDigest $repairBackupProtectedDeploymentPath 5998L `
                '3b37c74a7f8644327ad27353ffac7f4e61c37fee6cd32714d6f9246fa1e57850')) `
            'phase3b2_p2_v2_live_log_repair_existing_backup_invalid'
    }

    if ($ValidateOnly) {
        [pscustomobject]@{
            ContractId =
                'nll/phase3b2-p2-v2-live-log-seal-repair-preflight/v1'
            FailedAssessmentUid = $FailedAssessmentUid
            ServerSelectionObserved = $true
            TenMinuteObservationCompleted = $true
            RespondingSampleCount = 121
            UnresponsiveSampleCount = 0
            SailHandoffVerified = $true
            FailureCauseCode = 'exclusive_live_player_log_hash_read'
            SharedReadDigestRepairPlanned = $true
            RawPlayerLogCopyPlanned = $false
            EndpointContractChangePlanned = $false
            ExistingVerifiedRollbackBackupReusable =
                $existingRepairBackupPresent
            MutationRequiresAdministrator = $true
            CurrentProcessIsAdministrator = $isAdministrator
            DiskBoundaryVerified = $diskBoundaryVerified
            MutationPerformed = $false
        } | ConvertTo-Json -Depth 6
        return
    }

    if (-not $existingRepairBackupPresent) {
        New-Item -ItemType Directory -Path $repairBackupRoot -Force |
            Out-Null
        Copy-Item -LiteralPath $targetStartPath `
            -Destination $repairBackupToolPath
        Copy-Item -LiteralPath $manifestPath `
            -Destination $repairBackupManifestPath
        Copy-Item -LiteralPath $deploymentPath `
            -Destination $repairBackupDeploymentPath
        Copy-Item -LiteralPath $protectedDeploymentPath `
            -Destination $repairBackupProtectedDeploymentPath
    }
    $backupVerified = $true
    $mutationStarted = $true
    Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    $entry = @($deployment.tools | Where-Object {
        $_.name -ceq 'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    })
    Assert-True ($entry.Count -eq 1 -and
        [string]$entry[0].sha256 -ceq
            'a96d05bbf48eabc5891ed0d33f5241d041b9fe5f0fadad7ae1fb25cc843f553f') `
        'phase3b2_p2_v2_live_log_repair_tool_entry_invalid'
    $entry[0].byteLength = (Get-Item $targetStartPath).Length
    $entry[0].sha256 = Get-Sha256Hex $targetStartPath
    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_p2_v2_live_log_repair_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength = (Get-Item $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment | Add-Member -NotePropertyName livePlayerLogSharedReadEnabled `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName playerLogObservationModeCode `
        -NotePropertyValue `
            'shared_read_bounded_in_memory_digest_no_raw_persistence' -Force
    $deployment | Add-Member -NotePropertyName rawPlayerLogCopyEnabled `
        -NotePropertyValue $false -Force
    $deployment | Add-Member -NotePropertyName serverSelectionObserved `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName latestFailedAssessmentUid `
        -NotePropertyValue $FailedAssessmentUid -Force
    $deployment | Add-Member -NotePropertyName endpointContractChanged `
        -NotePropertyValue $false -Force
    $deployment | Add-Member -NotePropertyName singleRetryAuthorized `
        -NotePropertyValue $true -Force
    $deployment.nextStepCode =
        'boot_micron_as_nlloperator_and_run_live_log_seal_retry_once'
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 11) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force
    Assert-True ((Get-Sha256Hex $targetStartPath) -ceq
            (Get-Sha256Hex $sourceStartPath) -and
        (Get-Sha256Hex $deploymentPath) -ceq
            (Get-Sha256Hex $protectedDeploymentPath)) `
        'phase3b2_p2_v2_live_log_repair_post_apply_invalid'

    $preparationReceiptSha256 = Get-Sha256Hex $preparationReceiptPath
    Move-Item -LiteralPath $preparationRoot -Destination $preparationArchive
    $preparationArchived = $true
    Move-Item -LiteralPath $runtimeBackupRoot `
        -Destination $runtimeBackupArchive
    $runtimeBackupArchived = $true
    Move-Item -LiteralPath $protectedPreparationRoot `
        -Destination $protectedPreparationArchive
    $protectedPreparationArchived = $true

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-p2-v2-live-log-seal-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $FailedAssessmentUid
        failureReceiptByteLength = (Get-Item $failurePath).Length
        failureReceiptSha256 = Get-Sha256Hex $failurePath
        priorRepairReceiptSha256 = Get-Sha256Hex $priorRepairPath
        preparationReceiptSha256 = $preparationReceiptSha256
        serverSelectionObserved = $true
        serverSelectionScreenshotByteLength =
            (Get-Item $serverSelectionScreenshotPath).Length
        serverSelectionScreenshotSha256 =
            Get-Sha256Hex $serverSelectionScreenshotPath
        rawScreenshotCopied = $false
        sailNamedPipePayloadWritten = $true
        sailNamedPipeClosedAfterPayload = $true
        sailPayloadClearedAfterWrite = $true
        sailSharedMemoryRetainedForClientLifetime = $true
        sailHandoffLifecycleCode =
            'payload_then_pipe_eof_shared_memory_retained'
        blackScreenRegressionCauseCode =
            'sail_named_pipe_eof_withheld_and_payload_zeroization_race'
        tenMinuteObservationCompleted = $true
        measurementExpectedSampleCount = 121
        measurementObservedSampleCount = 121
        respondingSampleCount = 121
        unresponsiveSampleCount = 0
        failedStageCode = 'dns_wfp_and_server_stage_seal'
        failureCauseCode = 'exclusive_live_player_log_hash_read'
        livePlayerLogSharedReadEnabled = $true
        playerLogObservationModeCode =
            'shared_read_bounded_in_memory_digest_no_raw_persistence'
        rawPlayerLogCopied = $false
        endpointContractChanged = $false
        admittedEndpointCount = 1
        dedicatedOperatorCachePreserved = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        priorAutomaticRollbackVerified = $true
        priorRetryConsumptionPreserved = $true
        priorRetryConsumptionSha256 = Get-Sha256Hex $priorRetryConsumptionPath
        priorPreparationArchived = $true
        verifiedRollbackBackupPresent = $true
        singleRetryAuthorized = $true
        retryConsumed = $false
        repairedStartToolByteLength = (Get-Item $targetStartPath).Length
        repairedStartToolSha256 = Get-Sha256Hex $targetStartPath
        repairedToolManifestByteLength = (Get-Item $manifestPath).Length
        repairedToolManifestSha256 = Get-Sha256Hex $manifestPath
        repairedDeploymentReceiptByteLength = (Get-Item $deploymentPath).Length
        repairedDeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStartedAfterRepair = $false
        nextStepCode =
            'boot_micron_as_nlloperator_and_run_live_log_seal_retry_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 9) + "`n")
    Copy-Item -LiteralPath $repairReceiptPath -Destination $protectedRepairPath
    Assert-True ((Get-Sha256Hex $repairReceiptPath) -ceq
        (Get-Sha256Hex $protectedRepairPath)) `
        'phase3b2_p2_v2_live_log_repair_protected_copy_invalid'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $repairReceiptPath
        MicronReceiptByteLength = (Get-Item $repairReceiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        SamsungProtectedReceiptPath = $protectedRepairPath
    } | ConvertTo-Json -Depth 11
}
catch {
    if ($mutationStarted -and $backupVerified) {
        Copy-Item -LiteralPath $repairBackupToolPath `
            -Destination $targetStartPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repairBackupManifestPath `
            -Destination $manifestPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repairBackupDeploymentPath `
            -Destination $deploymentPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $repairBackupProtectedDeploymentPath `
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
    @($repairReceiptPath, $protectedRepairPath) | Where-Object { $_ } |
        ForEach-Object {
            Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue
        }
    throw
}
