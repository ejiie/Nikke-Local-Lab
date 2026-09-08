[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$FailedAssessmentUid =
        '82756ba7-7551-450e-94fc-f72bcd9bd8e2',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$mutationStarted = $false
$backupCreated = $false
$preparationArchived = $false
$backupArchived = $false
$protectedPreparationArchived = $false
$artifactReplaced = $false

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
            'phase3b2_p2_v2_measurement_repair_manifest_member_outside_base'
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
            'phase3b2_p2_v2_measurement_repair_requires_administrator'
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
            'phase3b2_p2_v2_measurement_repair_disk_boundary_invalid'
        $diskBoundaryVerified = $true
    }
    else {
        Assert-True ($ValidateOnly -and
            (Test-Path -LiteralPath (Join-Path $MicronDrive 'Windows') `
                -PathType Container)) `
            'phase3b2_p2_v2_measurement_repair_disk_boundary_deferred_invalid'
    }
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_p2_v2_measurement_repair_runtime_not_cold'

    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $sourceStartPath = Join-Path $RepositoryRoot `
        'scripts\start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $sourceCompletionPath = Join-Path $RepositoryRoot `
        'scripts\complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $bootstrapProjectPath = Join-Path $RepositoryRoot `
        'tools\Phase3B2\PhysicalBootstrap\NikkeLocalLab.Phase3B2.PhysicalBootstrap.csproj'
    $bootstrapSourcePath = Join-Path $RepositoryRoot `
        'tools\Phase3B2\LocalBootstrap\Program.cs'
    $bootstrapPublishRoot = Join-Path $RepositoryRoot `
        'tools\Phase3B2\PhysicalBootstrap\bin\Release\net10.0\win-x64\publish'
    $targetStartPath = Join-Path $toolRoot `
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $targetCompletionPath = Join-Path $toolRoot `
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $manifestPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
    $artifactRoot = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\artifact'
    $artifactManifestPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\evidence\artifact.manifest.tsv'
    $artifactNames = @(
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.deps.json',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.runtimeconfig.json'
    )
    $targetArtifactPaths = @($artifactNames | ForEach-Object {
        Join-Path $artifactRoot $_
    })
    $publishedArtifactPaths = @($artifactNames | ForEach-Object {
        Join-Path $bootstrapPublishRoot $_
    })
    $protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
    $protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
        'offline-deployment.receipt.json'
    $repairReceiptPath = Join-Path $transferRoot `
        'measurement-observation-repair.receipt.json'
    $protectedRepairPath = Join-Path $protectedDeploymentRoot `
        'measurement-observation-repair.receipt.json'
    $retryConsumptionPath = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\measurement-observation-retry.consumed.json'

    $failedRunRoot = Join-Path $MicronDrive `
        "NLL\Evidence\Phase3B2\Physical\p2-client-start-v2\$FailedAssessmentUid"
    $failurePath = Join-Path $failedRunRoot 'run-failure.receipt.json'
    $bootstrapPath = Join-Path $failedRunRoot 'bootstrap-start.receipt.json'
    $requestStagePath = Join-Path $failedRunRoot 'server-request-stage.jsonl'
    $protectedFailedRunRoot = Join-Path `
        (Join-Path $SamsungProtectedRoot 'RunsV2') $FailedAssessmentUid
    $protectedFailurePath = Join-Path $protectedFailedRunRoot `
        'run-failure.receipt.json'
    $preparationReceiptPath = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2\preparation.receipt.json'
    $protectedPreparationReceiptPath = Join-Path $SamsungProtectedRoot `
        'PreparationV2\preparation.receipt.json'
    $operatorProfileReceiptPath = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\operator-profile-v1\profile-isolation.receipt.json'
    $protectedOperatorProfileReceiptPath = Join-Path $SamsungProtectedRoot `
        'Operator\profile-isolation.receipt.json'
    $playerLogPath = Join-Path $MicronDrive `
        'Users\nlloperator\AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
    $operatorScreenshotRoot = Join-Path $MicronDrive `
        'Users\nlloperator\Pictures\Screenshots'
    $screenshotCandidates = @(Get-ChildItem -LiteralPath `
        $operatorScreenshotRoot -File -Filter '*.png' -ErrorAction SilentlyContinue)
    $unresponsiveScreenshotMatches = @($screenshotCandidates | Where-Object {
        $_.Length -eq 128608L -and
        (Get-Sha256Hex $_.FullName) -ceq
            '5a85793332ab291c674ac652c98629498ceb3fce698fe06b51d308d62b4ace0c'
    })
    $blackScreenScreenshotMatches = @($screenshotCandidates | Where-Object {
        $_.Length -eq 70565L -and
        (Get-Sha256Hex $_.FullName) -ceq
            '8409206111635324092cb66c06cdee448196060ceb2c61fa89875f495bcf33e5'
    })
    Assert-True ($unresponsiveScreenshotMatches.Count -eq 1 -and
        $blackScreenScreenshotMatches.Count -eq 1) `
        'phase3b2_p2_v2_measurement_repair_screenshot_resolution_invalid'
    $unresponsiveScreenshotPath = $unresponsiveScreenshotMatches[0].FullName
    $blackScreenScreenshotPath = $blackScreenScreenshotMatches[0].FullName

    $preparationRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
    $runtimeBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2'
    $protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'PreparationV2'
    $preparationArchive = $preparationRoot + '.failed-' + $FailedAssessmentUid
    $runtimeBackupArchive = $runtimeBackupRoot + '.failed-' +
        $FailedAssessmentUid
    $protectedPreparationArchive = $protectedPreparationRoot + '.failed-' +
        $FailedAssessmentUid
    $repairBackupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2-MeasurementObservationRepair-v1'
    $repairBackupToolsRoot = Join-Path $repairBackupRoot 'tools'
    $repairBackupArtifactRoot = Join-Path $repairBackupRoot 'artifact'
    $repairBackupEvidenceRoot = Join-Path $repairBackupRoot 'evidence'
    $repairBackupReceiptRoot = Join-Path $repairBackupRoot 'receipts'
    $existingRepairBackupPresent = Test-Path -LiteralPath $repairBackupRoot `
        -PathType Container
    if ($existingRepairBackupPresent) {
        Assert-True ((Test-PathDigest (Join-Path $repairBackupToolsRoot `
                    'start-phase3b2-physical-p2-v2-client-in-micron.ps1') `
                39719L `
                'e0a33dcd89a937415af8a8f8ddf035b43d3413bff9f173baf12789f7741bc828') -and
            (Test-PathDigest (Join-Path $repairBackupToolsRoot `
                    'complete-phase3b2-physical-p2-v2-client-in-micron.ps1') `
                14963L `
                '185ff7cfcfa93466b9f2b33d858f5cb749eb8ca26892abba627c94311a1ed38f') -and
            (Test-PathDigest (Join-Path $repairBackupArtifactRoot `
                    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll') 28672L `
                '664011151c761e6f9ffbb74a17805bc40adf30b22aa7a92b294cd80d3cd1e1d6') -and
            (Test-PathDigest (Join-Path $repairBackupEvidenceRoot `
                    'artifact.manifest.tsv') 573L `
                'd21a708aef49ea7352ff2185b7c65255456ae6a1d76c44aac3dcbd4f1f62bb5c') -and
            (Test-PathDigest (Join-Path $repairBackupEvidenceRoot `
                    'tools.manifest.tsv') 799L `
                'ebb617f4f068c2a5db6d3639cabd880933fdf75ea9a5aac7cfb2198f9ed43146') -and
            (Test-PathDigest (Join-Path $repairBackupReceiptRoot `
                    'micron-deployment.receipt.json') 4980L `
                '0c7ae9cc2f48ecf5a500ed7f659d84e1c2352151ba2bb11863e3360e508ff8b1') -and
            (Test-PathDigest (Join-Path $repairBackupReceiptRoot `
                    'samsung-offline-deployment.receipt.json') 4980L `
                '0c7ae9cc2f48ecf5a500ed7f659d84e1c2352151ba2bb11863e3360e508ff8b1')) `
            'phase3b2_p2_v2_measurement_repair_existing_backup_invalid'
    }

    Assert-True ((Test-PathDigest $targetStartPath 39719L `
            'e0a33dcd89a937415af8a8f8ddf035b43d3413bff9f173baf12789f7741bc828') -and
        (Test-PathDigest $targetCompletionPath 14963L `
            '185ff7cfcfa93466b9f2b33d858f5cb749eb8ca26892abba627c94311a1ed38f') -and
        (Test-PathDigest $manifestPath 799L `
            'ebb617f4f068c2a5db6d3639cabd880933fdf75ea9a5aac7cfb2198f9ed43146') -and
        (Test-PathDigest $deploymentPath 4980L `
            '0c7ae9cc2f48ecf5a500ed7f659d84e1c2352151ba2bb11863e3360e508ff8b1') -and
        (Test-PathDigest $protectedDeploymentPath 4980L `
            '0c7ae9cc2f48ecf5a500ed7f659d84e1c2352151ba2bb11863e3360e508ff8b1')) `
        'phase3b2_p2_v2_measurement_repair_deployment_baseline_invalid'
    Assert-True ((Test-PathDigest $artifactManifestPath 573L `
            'd21a708aef49ea7352ff2185b7c65255456ae6a1d76c44aac3dcbd4f1f62bb5c') -and
        (Test-PathDigest (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.deps.json') 568L `
            '3e86d91886ea017e46876c84041e925cd53e55fdf2757f9f772612c2244da95d') -and
        (Test-PathDigest (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll') 28672L `
            '664011151c761e6f9ffbb74a17805bc40adf30b22aa7a92b294cd80d3cd1e1d6') -and
        (Test-PathDigest (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe') 162816L `
            'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f') -and
        (Test-PathDigest (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.runtimeconfig.json') `
            342L `
            'c230a317a54dd960bcbeb5f347f52e18dc665a26f7efda2159fced9a5ac7e097') -and
        (Test-PathDigest (Join-Path $artifactRoot 'sail_api_impl64.dll') `
            18944L `
            '8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d')) `
        'phase3b2_p2_v2_sail_handoff_repair_artifact_baseline_invalid'
    Assert-True ((Test-PathDigest $failurePath 999L `
            '666aed3adacda9c71f7da3f59a26349e2cf2eb5e1b95663c5205fbe0c64104ad') -and
        (Test-PathDigest $protectedFailurePath 999L `
            '666aed3adacda9c71f7da3f59a26349e2cf2eb5e1b95663c5205fbe0c64104ad') -and
        (Test-PathDigest $bootstrapPath 829L `
            '5b1d8afb7eec022e18d613d709d92c60605ce6f1c4e3165ec86c6231447a0f1e') -and
        (Test-PathDigest $requestStagePath 872L `
            '19730e874378791e87346d217988c42af38f23d0a795b4165bbec849e640da06') -and
        (Test-PathDigest $preparationReceiptPath 1693L `
            'e75774fc670c700443a55dcf49cdd0e4385dba1c1ca15d00b2ebfd263bd88bc2') -and
        (Test-PathDigest $protectedPreparationReceiptPath 1693L `
            'e75774fc670c700443a55dcf49cdd0e4385dba1c1ca15d00b2ebfd263bd88bc2') -and
        (Test-PathDigest $operatorProfileReceiptPath 836L `
            '96a72eb5846a856c89d9d69a8e1ec9d5ae9884fafa27b7e5f8c0841eceb1a131') -and
        (Test-PathDigest $protectedOperatorProfileReceiptPath 836L `
            '96a72eb5846a856c89d9d69a8e1ec9d5ae9884fafa27b7e5f8c0841eceb1a131') -and
        (Test-PathDigest $playerLogPath 2521L `
            '5a11526a77362d19b5fb3faa79cc0abdabb1baf67ac3750c3d72e5004c36414a') -and
        (Test-PathDigest $unresponsiveScreenshotPath 128608L `
            '5a85793332ab291c674ac652c98629498ceb3fce698fe06b51d308d62b4ace0c') -and
        (Test-PathDigest $blackScreenScreenshotPath 70565L `
            '8409206111635324092cb66c06cdee448196060ceb2c61fa89875f495bcf33e5')) `
        'phase3b2_p2_v2_measurement_repair_failure_evidence_invalid'
    $offlineHostsPath = Join-Path $MicronDrive `
        'Windows\System32\drivers\etc\hosts'
    Assert-True ((Test-PathDigest $offlineHostsPath 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
        (Test-Path -LiteralPath $preparationRoot -PathType Container) -and
        (Test-Path -LiteralPath $runtimeBackupRoot -PathType Container) -and
        (Test-Path -LiteralPath $protectedPreparationRoot `
            -PathType Container) -and
        -not (Test-Path -LiteralPath $preparationArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $repairReceiptPath) -and
        -not (Test-Path -LiteralPath $protectedRepairPath) -and
        -not (Test-Path -LiteralPath $retryConsumptionPath)) `
        'phase3b2_p2_v2_measurement_repair_state_shape_invalid'

    $failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $requestRecords = @(Get-Content -LiteralPath $requestStagePath `
        -Encoding UTF8 | Where-Object { $_ } | ForEach-Object {
            $_ | ConvertFrom-Json
        })
    Assert-True ($failure.contractId -ceq
            'nll/phase3b2-physical-p2-v2-client-start-failure/v1' -and
        $failure.assessmentUid -ceq $FailedAssessmentUid -and
        $failure.failureCode -ceq
            'phase3b2_physical_p2_v2_measurement_duration_invalid' -and
        $failure.runtimeStopped -and $failure.databaseRestored -and
        $failure.hostsRestored -and $failure.extensionFirewallRolledBack -and
        $bootstrap.sailNamedPipeConnected -and
        $bootstrap.clientExecutionStarted -and
        @($requestRecords | Where-Object {
            $_.transitionCode -ceq 'handler_started'
        }).Count -eq 0) `
        'phase3b2_p2_v2_measurement_repair_failure_contract_invalid'

    $sourceStartText = Get-Content -LiteralPath $sourceStartPath -Raw `
        -Encoding UTF8
    $bootstrapSourceText = Get-Content -LiteralPath $bootstrapSourcePath -Raw `
        -Encoding UTF8
    Assert-True ((Test-Path -LiteralPath $sourceStartPath -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceCompletionPath -PathType Leaf) -and
        (Test-PathDigest $bootstrapSourcePath 19793L `
            'c3a7c388d0f16c59292f66f9cd92d13807c78d592a0170b4866224109416d264') -and
        $sourceStartText -cmatch
            'monotonic_deadline_compensated_interval_v2' -and
        $sourceStartText -cmatch
            'preserved_first_run_cache_authorized_single_retry' -and
        $sourceStartText -cmatch 'rawPlayerLogPersisted = \$false' -and
        $sourceStartText -cmatch
            'payload_then_pipe_eof_shared_memory_retained' -and
        $bootstrapSourceText -cmatch
            'await pipeTask;\s*pipePayload\.AsSpan\(\)\.Clear\(\);\s*\}' -and
        $bootstrapSourceText -cmatch
            'sailNamedPipeClosedAfterPayload') `
        'phase3b2_p2_v2_measurement_repair_source_invalid'

    $dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
    Assert-True ((Test-Path -LiteralPath $dotnetPath -PathType Leaf) -and
        (Test-Path -LiteralPath $bootstrapProjectPath -PathType Leaf)) `
        'phase3b2_p2_v2_sail_handoff_repair_toolchain_missing'
    $oldDotnetHome = $env:DOTNET_CLI_HOME
    $oldDotnetTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
    $oldDotnetFirstRun = $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE
    Push-Location $env:TEMP
    try {
        $env:DOTNET_CLI_HOME = Join-Path $env:TEMP `
            'nll-phase3b2-p2-v2-sail-handoff-build'
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
        $sdkVersion = (& $dotnetPath --version | Out-String).Trim()
        Assert-True ($sdkVersion -ceq '10.0.400') `
            'phase3b2_p2_v2_sail_handoff_repair_sdk_pin_mismatch'
        & $dotnetPath publish $bootstrapProjectPath -c Release --no-restore `
            --nologo
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_p2_v2_sail_handoff_repair_publish_failed'
    }
    finally {
        Pop-Location
        $env:DOTNET_CLI_HOME = $oldDotnetHome
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldDotnetTelemetry
        $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = $oldDotnetFirstRun
    }
    Assert-True (@($publishedArtifactPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_p2_v2_sail_handoff_publish_shape_invalid'

    if ($ValidateOnly) {
        [pscustomobject]@{
            ContractId =
                'nll/phase3b2-p2-v2-measurement-observation-repair-preflight/v1'
            FailedAssessmentUid = $FailedAssessmentUid
            BaselineValidated = $true
            AutomaticRollbackVerified = $true
            SailNamedPipeConnected = $true
            SailNamedPipeEofRepairPlanned = $true
            SailPayloadZeroizationRaceRemoved = $true
            SailSharedMemoryLifetimePreserved = $true
            SailHandoffLifecycleCode =
                'payload_then_pipe_eof_shared_memory_retained'
            PriorServerHandlerStartedCount = 0
            EndpointContractChangePlanned = $false
            DedicatedOperatorCachePreserved = $true
            ExistingCccccCacheMutationPlanned = $false
            ExistingVerifiedRollbackBackupReusable =
                $existingRepairBackupPresent
            MutationRequiresAdministrator = $true
            CurrentProcessIsAdministrator = $isAdministrator
            DiskBoundaryVerified = $diskBoundaryVerified
            DiskBoundaryDeferredToElevatedMutation = -not $diskBoundaryVerified
            MutationPerformed = $false
        } | ConvertTo-Json -Depth 5
        return
    }

    if (-not $existingRepairBackupPresent) {
        New-Item -ItemType Directory -Path $repairBackupRoot,
            $repairBackupToolsRoot, $repairBackupArtifactRoot,
            $repairBackupEvidenceRoot, $repairBackupReceiptRoot -Force |
            Out-Null
        foreach ($path in @($targetStartPath, $targetCompletionPath)) {
            Copy-Item -LiteralPath $path -Destination $repairBackupToolsRoot
        }
        foreach ($path in $targetArtifactPaths) {
            Copy-Item -LiteralPath $path -Destination $repairBackupArtifactRoot
        }
        Copy-Item -LiteralPath $artifactManifestPath `
            -Destination $repairBackupEvidenceRoot
        Copy-Item -LiteralPath $manifestPath `
            -Destination $repairBackupEvidenceRoot
        Copy-Item -LiteralPath $deploymentPath `
            -Destination (Join-Path $repairBackupReceiptRoot `
                'micron-deployment.receipt.json')
        Copy-Item -LiteralPath $protectedDeploymentPath `
            -Destination (Join-Path $repairBackupReceiptRoot `
                'samsung-offline-deployment.receipt.json')
    }
    $backupCreated = $true
    Assert-True ((Test-PathDigest (Join-Path $repairBackupToolsRoot `
                'start-phase3b2-physical-p2-v2-client-in-micron.ps1') `
            39719L 'e0a33dcd89a937415af8a8f8ddf035b43d3413bff9f173baf12789f7741bc828') -and
        (Test-PathDigest (Join-Path $repairBackupToolsRoot `
                'complete-phase3b2-physical-p2-v2-client-in-micron.ps1') `
            14963L '185ff7cfcfa93466b9f2b33d858f5cb749eb8ca26892abba627c94311a1ed38f') -and
        (Test-PathDigest (Join-Path $repairBackupArtifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll') 28672L `
            '664011151c761e6f9ffbb74a17805bc40adf30b22aa7a92b294cd80d3cd1e1d6') -and
        (Test-PathDigest (Join-Path $repairBackupEvidenceRoot `
                'artifact.manifest.tsv') 573L `
            'd21a708aef49ea7352ff2185b7c65255456ae6a1d76c44aac3dcbd4f1f62bb5c')) `
        'phase3b2_p2_v2_measurement_repair_backup_invalid'

    $mutationStarted = $true
    Copy-Item -LiteralPath $sourceStartPath -Destination $targetStartPath -Force
    Copy-Item -LiteralPath $sourceCompletionPath `
        -Destination $targetCompletionPath -Force
    foreach ($path in $publishedArtifactPaths) {
        Copy-Item -LiteralPath $path -Destination $artifactRoot -Force
    }
    $artifactReplaced = $true

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($deployment.contractId -ceq
            'nll/phase3b2-physical-p2-v2-offline-deployment/v1' -and
        [int]$deployment.transferredToolCount -eq 7 -and
        [int]$deployment.admittedEndpointCount -eq 1 -and
        $deployment.admittedEndpoint -ceq 'global-match.nikke-kr.com') `
        'phase3b2_p2_v2_measurement_repair_deployment_invalid'
    $artifactPaths = @(Get-ChildItem -LiteralPath $artifactRoot -File |
        Select-Object -ExpandProperty FullName)
    Assert-True ($artifactPaths.Count -eq 5 -and
        (Test-PathDigest (Join-Path $artifactRoot 'sail_api_impl64.dll') `
            18944L `
            '8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d')) `
        'phase3b2_p2_v2_sail_handoff_repair_artifact_shape_invalid'
    $artifactManifestText =
        (Get-ManifestLines $artifactPaths $artifactRoot) -join "`n"
    Write-AtomicUtf8NoBom $artifactManifestPath `
        ($artifactManifestText + "`n")
    $deployment.bootstrapSharedSourceByteLength =
        (Get-Item $bootstrapSourcePath).Length
    $deployment.bootstrapSharedSourceSha256 = Get-Sha256Hex $bootstrapSourcePath
    $deployment.artifactManifestByteLength =
        (Get-Item $artifactManifestPath).Length
    $deployment.artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
    $deployment.physicalBootstrapExeByteLength =
        (Get-Item (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')).Length
    $deployment.physicalBootstrapExeSha256 = Get-Sha256Hex (Join-Path `
        $artifactRoot 'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
    $deployment | Add-Member -NotePropertyName physicalBootstrapDllByteLength `
        -NotePropertyValue (Get-Item (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll')).Length -Force
    $deployment | Add-Member -NotePropertyName physicalBootstrapDllSha256 `
        -NotePropertyValue (Get-Sha256Hex (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll')) -Force
    foreach ($replacement in @(
            [pscustomobject]@{
                Name = 'start-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetStartPath
                OldSha256 =
                    'e0a33dcd89a937415af8a8f8ddf035b43d3413bff9f173baf12789f7741bc828'
            },
            [pscustomobject]@{
                Name = 'complete-phase3b2-physical-p2-v2-client-in-micron.ps1'
                Path = $targetCompletionPath
                OldSha256 =
                    '185ff7cfcfa93466b9f2b33d858f5cb749eb8ca26892abba627c94311a1ed38f'
            })) {
        $entry = @($deployment.tools | Where-Object {
            $_.name -ceq $replacement.Name
        })
        Assert-True ($entry.Count -eq 1 -and
            [string]$entry[0].sha256 -ceq $replacement.OldSha256) `
            'phase3b2_p2_v2_measurement_repair_tool_entry_invalid'
        $entry[0].byteLength = (Get-Item $replacement.Path).Length
        $entry[0].sha256 = Get-Sha256Hex $replacement.Path
    }
    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_p2_v2_measurement_repair_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength = (Get-Item $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment | Add-Member -NotePropertyName measurementSchedulerRepairApplied `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName measurementSchedulerCode `
        -NotePropertyValue 'monotonic_deadline_compensated_interval_v2' -Force
    $deployment | Add-Member `
        -NotePropertyName measurementFailureEvidencePreservationEnabled `
        -NotePropertyValue $true -Force
    $deployment | Add-Member `
        -NotePropertyName perUserPlayerLogMetadataObservationEnabled `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName singleRetryAuthorized `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName failedAssessmentUid `
        -NotePropertyValue $FailedAssessmentUid -Force
    $deployment | Add-Member -NotePropertyName endpointContractChanged `
        -NotePropertyValue $false -Force
    $deployment | Add-Member -NotePropertyName sailHandoffLifecycleRepairApplied `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName sailNamedPipePayloadWritten `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName sailNamedPipeClosedAfterPayload `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName sailPayloadClearedAfterWrite `
        -NotePropertyValue $true -Force
    $deployment | Add-Member `
        -NotePropertyName sailSharedMemoryRetainedForClientLifetime `
        -NotePropertyValue $true -Force
    $deployment | Add-Member -NotePropertyName sailHandoffLifecycleCode `
        -NotePropertyValue `
            'payload_then_pipe_eof_shared_memory_retained' -Force
    $deployment | Add-Member -NotePropertyName blackScreenRegressionCauseCode `
        -NotePropertyValue `
            'sail_named_pipe_eof_withheld_and_payload_zeroization_race' -Force
    $deployment | Add-Member -NotePropertyName serverRevisionCausalDeltaExcluded `
        -NotePropertyValue $true -Force
    $deployment.nextStepCode =
        'boot_micron_as_nlloperator_and_run_sail_handoff_retry_once'
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 10) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force
    Assert-True ((Get-Sha256Hex $protectedDeploymentPath) -ceq
            (Get-Sha256Hex $deploymentPath) -and
        (Get-Sha256Hex $targetStartPath) -ceq
            (Get-Sha256Hex $sourceStartPath) -and
        (Get-Sha256Hex $targetCompletionPath) -ceq
            (Get-Sha256Hex $sourceCompletionPath) -and
        (Test-PathDigest $artifactManifestPath `
            ([long]$deployment.artifactManifestByteLength) `
            ([string]$deployment.artifactManifestSha256)) -and
        (Test-PathDigest (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll') `
            ([long]$deployment.physicalBootstrapDllByteLength) `
            ([string]$deployment.physicalBootstrapDllSha256))) `
        'phase3b2_p2_v2_sail_handoff_repair_post_apply_invalid'

    $preparationReceiptSha256 = Get-Sha256Hex $preparationReceiptPath
    $operatorProfileReceiptSha256 = Get-Sha256Hex $operatorProfileReceiptPath
    Move-Item -LiteralPath $preparationRoot -Destination $preparationArchive
    $preparationArchived = $true
    Move-Item -LiteralPath $runtimeBackupRoot `
        -Destination $runtimeBackupArchive
    $backupArchived = $true
    Move-Item -LiteralPath $protectedPreparationRoot `
        -Destination $protectedPreparationArchive
    $protectedPreparationArchived = $true

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-p2-v2-measurement-observation-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $FailedAssessmentUid
        failureReceiptByteLength = (Get-Item $failurePath).Length
        failureReceiptSha256 = Get-Sha256Hex $failurePath
        bootstrapStartReceiptSha256 = Get-Sha256Hex $bootstrapPath
        sailNamedPipeConnected = $true
        sailNamedPipePayloadWritten = $true
        sailNamedPipeClosedAfterPayload = $true
        sailPayloadClearedAfterWrite = $true
        sailSharedMemoryRetainedForClientLifetime = $true
        sailHandoffLifecycleCode =
            'payload_then_pipe_eof_shared_memory_retained'
        blackScreenRegressionCauseCode =
            'sail_named_pipe_eof_withheld_and_payload_zeroization_race'
        priorThreeOfSevenProgressExplanationCode =
            'bootstrap_failure_closed_pipe_before_server_rollback'
        priorFailedToLoadExplanationCode =
            'server_rollback_after_client_consumed_sail_payload'
        serverRevisionCausalDeltaExcluded = $true
        endpointContractCausalDeltaExcluded = $true
        clientExecutionStarted = $true
        priorFailureCode =
            'phase3b2_physical_p2_v2_measurement_duration_invalid'
        measurementFailureCauseCode =
            'fixed_sleep_sampling_overhead_reduced_sample_count'
        measurementSchedulerCode =
            'monotonic_deadline_compensated_interval_v2'
        measurementFailureEvidencePreservationEnabled = $true
        playerLogMetadataObservationEnabled = $true
        playerLogByteLength = (Get-Item $playerLogPath).Length
        playerLogSha256 = Get-Sha256Hex $playerLogPath
        rawPlayerLogCopied = $false
        unresponsiveScreenshotByteLength =
            (Get-Item $unresponsiveScreenshotPath).Length
        unresponsiveScreenshotSha256 = Get-Sha256Hex $unresponsiveScreenshotPath
        blackScreenScreenshotByteLength =
            (Get-Item $blackScreenScreenshotPath).Length
        blackScreenScreenshotSha256 = Get-Sha256Hex $blackScreenScreenshotPath
        rawScreenshotCopied = $false
        preparationReceiptSha256 = $preparationReceiptSha256
        operatorProfileReceiptSha256 = $operatorProfileReceiptSha256
        priorServerHandlerStartedCount = 0
        offlineEventLogInspectionPerformed = $true
        offlineDnsEventCount = 0
        offlineClientWfpMatchingEventCount = 0
        networkPreStageEvidenceCode =
            'no_dns_wfp_or_server_handler_activity_observed'
        endpointContractChanged = $false
        admittedEndpointCount = 1
        admittedEndpointCode = 'global_match_local_get_server_info'
        dedicatedCachePreserved = $true
        dedicatedOperatorLocalLowReadForDiagnosis = $true
        dedicatedOperatorLocalLowWritePerformed = $false
        existingOperatorNikkeCacheMutationPerformed = $false
        existingCccccLocalLowReadPerformed = $false
        existingCccccNikkeCacheMutationPerformed = $false
        priorPreparationArchived = $true
        priorAutomaticRollbackVerified = $true
        hostsRestoredVerified = $true
        singleRetryAuthorized = $true
        retryConsumed = $false
        repairedStartToolByteLength = (Get-Item $targetStartPath).Length
        repairedStartToolSha256 = Get-Sha256Hex $targetStartPath
        repairedCompletionToolByteLength =
            (Get-Item $targetCompletionPath).Length
        repairedCompletionToolSha256 = Get-Sha256Hex $targetCompletionPath
        repairedBootstrapSourceByteLength =
            (Get-Item $bootstrapSourcePath).Length
        repairedBootstrapSourceSha256 = Get-Sha256Hex $bootstrapSourcePath
        repairedBootstrapDllByteLength =
            (Get-Item (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll')).Length
        repairedBootstrapDllSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll')
        repairedArtifactManifestByteLength =
            (Get-Item $artifactManifestPath).Length
        repairedArtifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
        repairedToolManifestByteLength = (Get-Item $manifestPath).Length
        repairedToolManifestSha256 = Get-Sha256Hex $manifestPath
        repairedDeploymentReceiptByteLength = (Get-Item $deploymentPath).Length
        repairedDeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStartedAfterRepair = $false
        nextStepCode =
            'boot_micron_as_nlloperator_and_run_sail_handoff_retry_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $repairReceiptPath -Destination $protectedRepairPath
    Assert-True ((Get-Sha256Hex $protectedRepairPath) -ceq
        (Get-Sha256Hex $repairReceiptPath)) `
        'phase3b2_p2_v2_measurement_repair_protected_copy_failed'

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $repairReceiptPath
        MicronReceiptByteLength = (Get-Item $repairReceiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        SamsungProtectedReceiptPath = $protectedRepairPath
    } | ConvertTo-Json -Depth 10
}
catch {
    if ($mutationStarted -and $backupCreated) {
        Copy-Item -LiteralPath (Join-Path $repairBackupToolsRoot `
                'start-phase3b2-physical-p2-v2-client-in-micron.ps1') `
            -Destination $targetStartPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $repairBackupToolsRoot `
                'complete-phase3b2-physical-p2-v2-client-in-micron.ps1') `
            -Destination $targetCompletionPath -Force `
            -ErrorAction SilentlyContinue
        if ($artifactReplaced) {
            foreach ($artifactName in $artifactNames) {
                Copy-Item -LiteralPath (Join-Path $repairBackupArtifactRoot `
                        $artifactName) -Destination (Join-Path $artifactRoot `
                        $artifactName) -Force -ErrorAction SilentlyContinue
            }
        }
        Copy-Item -LiteralPath (Join-Path $repairBackupEvidenceRoot `
                'artifact.manifest.tsv') -Destination $artifactManifestPath `
            -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $repairBackupEvidenceRoot `
                'tools.manifest.tsv') -Destination $manifestPath -Force `
            -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $repairBackupReceiptRoot `
                'micron-deployment.receipt.json') `
            -Destination $deploymentPath -Force `
            -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $repairBackupReceiptRoot `
                'samsung-offline-deployment.receipt.json') `
            -Destination $protectedDeploymentPath -Force `
            -ErrorAction SilentlyContinue
    }
    if ($protectedPreparationArchived -and
        (Test-Path -LiteralPath $protectedPreparationArchive) -and
        -not (Test-Path -LiteralPath $protectedPreparationRoot)) {
        Move-Item -LiteralPath $protectedPreparationArchive `
            -Destination $protectedPreparationRoot -ErrorAction SilentlyContinue
    }
    if ($backupArchived -and (Test-Path -LiteralPath $runtimeBackupArchive) -and
        -not (Test-Path -LiteralPath $runtimeBackupRoot)) {
        Move-Item -LiteralPath $runtimeBackupArchive `
            -Destination $runtimeBackupRoot -ErrorAction SilentlyContinue
    }
    if ($preparationArchived -and (Test-Path -LiteralPath $preparationArchive) -and
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
