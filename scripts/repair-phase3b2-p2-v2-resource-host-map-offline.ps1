[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$EpinelRepositoryRoot =
        'C:\Users\zih44\Documents\Github\EpinelPS',
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\V2Deployment'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$expectedHead = '7fdff8f4341a240e85259b5a1e5fd9be415f5a46'
$expectedTree = 'f042e5843638233b5fb4708829409179669ae934'
$failedAssessmentUid = 'cf8433fe-ea3d-4594-94d3-863bd0846cd3'
$mutationsStarted = $false
$archiveMoves = [Collections.Generic.List[object]]::new()
$testRoot = $null

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

function Invoke-PinnedTest {
    param(
        [string]$DotnetPath,
        [string]$ProjectPath,
        [string]$ResultsRoot,
        [string]$RoleCode,
        [int]$ExpectedPassedCount
    )
    $trxName = "$RoleCode.trx"
    & $DotnetPath test $ProjectPath -c Release --no-restore --nologo `
        --verbosity quiet --results-directory $ResultsRoot `
        --logger "trx;LogFileName=$trxName"
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_${RoleCode}_test_failed"
    $trxPath = Join-Path $ResultsRoot $trxName
    [xml]$trx = Get-Content -LiteralPath $trxPath -Raw -Encoding UTF8
    $counters = $trx.TestRun.ResultSummary.Counters
    Assert-True ($null -ne $counters -and [int]$counters.failed -eq 0 -and
        [int]$counters.passed -eq $ExpectedPassedCount -and
        [int]$counters.total -eq $ExpectedPassedCount) `
        "phase3b2_${RoleCode}_test_count_invalid"
    [ordered]@{
        passedCount = [int]$counters.passed
        trxPath = $trxPath
        trxByteLength = (Get-Item $trxPath).Length
        trxSha256 = Get-Sha256Hex $trxPath
    }
}

function Add-ArchiveMove {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Source) {
        Assert-True (-not (Test-Path -LiteralPath $Destination)) `
            'phase3b2_resource_host_map_archive_destination_present'
        Move-Item -LiteralPath $Source -Destination $Destination
        $archiveMoves.Add([pscustomobject]@{
            Source = $Source
            Destination = $Destination
        })
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_resource_host_map_repair_requires_administrator'
$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_resource_host_map_repair_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_resource_host_map_repair_runtime_not_cold'

$p2Root = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$runRoot = Join-Path $p2Root $failedAssessmentUid
$failureReceiptPath = Join-Path $runRoot 'core-key-failure.receipt.json'
$recoveryReceiptPath = Join-Path $runRoot `
    'core-key-cold-recovery.receipt.json'
if (-not (Test-Path -LiteralPath $recoveryReceiptPath -PathType Leaf)) {
    & (Join-Path $RepositoryRoot `
        'scripts\recover-phase3b2-p2-v2-core-key-failure-offline.ps1') `
        -MicronDrive $MicronDrive | Out-Host
}
Assert-True ((Test-Path -LiteralPath $failureReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $recoveryReceiptPath -PathType Leaf)) `
    'phase3b2_resource_host_map_recovery_missing'
$failure = Get-Content -LiteralPath $failureReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$recovery = Get-Content -LiteralPath $recoveryReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($failure.contractId -ceq
        'nll/phase3b2-p2-v2-core-key-failure/v1' -and
    $failure.assessmentUid -ceq $failedAssessmentUid -and
    $failure.reasonCode -ceq 'addressable_catalog_group_core_key_missing' -and
    $failure.missingDictionaryKeyCode -ceq 'core' -and
    $recovery.contractId -ceq
        'nll/phase3b2-p2-v2-core-key-cold-recovery/v1' -and
    $recovery.failedAssessmentUid -ceq $failedAssessmentUid -and
    $recovery.databaseRestored -and $recovery.sqliteRuntimeRemoved) `
    'phase3b2_resource_host_map_recovery_invalid'

$gitCandidates = @(
    (Join-Path $MicronDrive 'Program Files\Git\cmd\git.exe'),
    (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
)
$gitPath = @($gitCandidates | Where-Object {
    Test-Path -LiteralPath $_ -PathType Leaf
} | Select-Object -First 1)
Assert-True ($gitPath.Count -eq 1) `
    'phase3b2_resource_host_map_git_missing'
$gitPath = [string]$gitPath[0]
$externalHead = (& $gitPath -c safe.directory=$EpinelRepositoryRoot `
    -C $EpinelRepositoryRoot rev-parse HEAD | Out-String).Trim()
$externalTree = (& $gitPath -c safe.directory=$EpinelRepositoryRoot `
    -C $EpinelRepositoryRoot rev-parse 'HEAD^{tree}' | Out-String).Trim()
$externalBranch = (& $gitPath -c safe.directory=$EpinelRepositoryRoot `
    -C $EpinelRepositoryRoot rev-parse --abbrev-ref HEAD | Out-String).Trim()
$externalStatus = (& $gitPath -c safe.directory=$EpinelRepositoryRoot `
    -C $EpinelRepositoryRoot status --porcelain=v1 --untracked-files=all |
    Out-String).Trim()
Assert-True ($externalHead -ceq $expectedHead -and
    $externalTree -ceq $expectedTree -and
    $externalBranch -ceq 'agent/phase3b2-resource-host-map' -and
    $externalStatus.Length -eq 0) `
    'phase3b2_resource_host_map_external_source_invalid'

$sourceGameConfig = Join-Path $EpinelRepositoryRoot 'EpinelPS\gameconfig.json'
$sourceController = Join-Path $EpinelRepositoryRoot `
    'EpinelPS\LobbyServer\Controllers\SystemController.cs'
$sourceConfigClass = Join-Path $EpinelRepositoryRoot `
    'EpinelPS\Utils\GameConfig.cs'
$gameConfig = Get-Content -LiteralPath $sourceGameConfig -Raw -Encoding UTF8 |
    ConvertFrom-Json
$controllerText = Get-Content -LiteralPath $sourceController -Raw -Encoding UTF8
Assert-True ($gameConfig.TargetVersion -ceq '150.6.9' -and
    $gameConfig.ResourceCoreVersion -ceq '150.6.b15' -and
    $gameConfig.ResourceDataPackVersion -ceq '651' -and
    $controllerText -cmatch 'CoreVersionMap\.Add' -and
    $controllerText -cmatch 'DataPackVersionMap\.Add') `
    'phase3b2_resource_host_map_source_contract_invalid'

$dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
$handlerTestPath = Join-Path $EpinelRepositoryRoot `
    'tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj'
$selectedTestPath = Join-Path $EpinelRepositoryRoot `
    'tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj'
$serverProjectPath = Join-Path $EpinelRepositoryRoot 'EpinelPS\EpinelPS.csproj'
$buildInputPaths = @($dotnetPath, $handlerTestPath, $selectedTestPath,
    $serverProjectPath, $sourceGameConfig, $sourceController,
    $sourceConfigClass)
$missingBuildInputPaths = @($buildInputPaths | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Leaf)
})
Assert-True ($missingBuildInputPaths.Count -eq 0) `
    'phase3b2_resource_host_map_build_input_missing'

$testRoot = Join-Path $env:TEMP `
    ('nll-resource-host-map-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$oldRoot = $env:DOTNET_ROOT
$oldHome = $env:DOTNET_CLI_HOME
$oldTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    $env:DOTNET_ROOT = Join-Path $MicronDrive 'Program Files\dotnet'
    $env:DOTNET_CLI_HOME = Join-Path $env:TEMP 'nll-resource-host-map-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Assert-True (((& $dotnetPath --version | Out-String).Trim()) -ceq
        '10.0.400') 'phase3b2_resource_host_map_sdk_mismatch'
    Push-Location $EpinelRepositoryRoot
    try {
        $handlerResult = Invoke-PinnedTest $dotnetPath $handlerTestPath `
            $testRoot 'handler_isolation' 15
        $selectedResult = Invoke-PinnedTest $dotnetPath $selectedTestPath `
            $testRoot 'selected_manager' 64
        & $dotnetPath build $serverProjectPath -c Release --no-restore --nologo
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_resource_host_map_server_build_failed'
    }
    finally { Pop-Location }
}
finally {
    $env:DOTNET_ROOT = $oldRoot
    $env:DOTNET_CLI_HOME = $oldHome
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldTelemetry
}

$builtServerDll = Join-Path $EpinelRepositoryRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
Assert-True ((Test-Path -LiteralPath $builtServerDll -PathType Leaf) -and
    (Get-Item -LiteralPath $builtServerDll).Length -eq 15371776L) `
    'phase3b2_resource_host_map_server_build_pin_mismatch'

$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
$deploymentReceiptPath = Join-Path $transferRoot 'deployment.receipt.json'
$authorizationPath = Join-Path $transferRoot `
    'resource-host-map-repair.receipt.json'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-ResourceHostMap-v1'
$rollbackManifestPath = Join-Path $backupRoot 'rollback.manifest.json'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$runtimeServerDll = Join-Path $serverRoot 'EpinelPS.dll'
$runtimeGameConfig = Join-Path $serverRoot 'gameconfig.json'
$targetSourceRoot = Join-Path $MicronDrive 'NLL\EpinelPS'
$projectionPath = Join-Path $serverRoot `
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$priorConsumptionPath = Join-Path $p2Root `
    'catalog-parser-exact-retry.consumed.json'
$toolRoot = Join-Path $MicronDrive 'NLL\Tools'
$toolManifestPath = Join-Path $MicronDrive `
    'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
$toolNames = @(
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1',
    'complete-phase3b2-physical-p2-v2-client-in-micron.ps1',
    'Start-Phase3B2-Physical-P2-V2.ps1'
)
$preparationEvidence = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
$preparationBackup = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-v2'
$protectedPreparation =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\PreparationV2'

Assert-True ((Test-Path -LiteralPath $deploymentReceiptPath -PathType Leaf) -and
    (Test-PathDigest $priorConsumptionPath 1022L `
        'da5c1a73d878b6c5eb2c11d0bb2063a2f1d51eb10c9320bfc4c9fad112a8099e') -and
    (Test-Path -LiteralPath $runtimeServerDll -PathType Leaf) -and
    (Test-Path -LiteralPath $runtimeGameConfig -PathType Leaf) -and
    -not (Test-Path -LiteralPath $authorizationPath) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $projectionPath)) `
    'phase3b2_resource_host_map_mutation_precondition_invalid'

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$backupPairs = [ordered]@{
    'EpinelPS.dll' = $runtimeServerDll
    'gameconfig.runtime.json' = $runtimeGameConfig
    'deployment.receipt.json' = $deploymentReceiptPath
    'tools.manifest.tsv' = $toolManifestPath
}
foreach ($toolName in $toolNames) {
    $backupPairs["tool.$toolName"] = Join-Path $toolRoot $toolName
}
foreach ($relative in @('EpinelPS\Utils\GameConfig.cs',
        'EpinelPS\LobbyServer\Controllers\SystemController.cs',
        'EpinelPS\gameconfig.json')) {
    $backupPairs['source.' + $relative.Replace('\', '.')] =
        Join-Path $targetSourceRoot $relative
}
foreach ($entry in $backupPairs.GetEnumerator()) {
    Assert-True (Test-Path -LiteralPath $entry.Value -PathType Leaf) `
        'phase3b2_resource_host_map_backup_source_missing'
    Copy-Item -LiteralPath $entry.Value `
        -Destination (Join-Path $backupRoot $entry.Key)
}
$mutationsStarted = $true

try {
    Copy-Item -LiteralPath $builtServerDll -Destination $runtimeServerDll -Force
    Copy-Item -LiteralPath $sourceGameConfig -Destination $runtimeGameConfig -Force
    foreach ($relative in @('EpinelPS\Utils\GameConfig.cs',
            'EpinelPS\LobbyServer\Controllers\SystemController.cs',
            'EpinelPS\gameconfig.json')) {
        Copy-Item -LiteralPath (Join-Path $EpinelRepositoryRoot $relative) `
            -Destination (Join-Path $targetSourceRoot $relative) -Force
    }
    foreach ($toolName in $toolNames) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot "scripts\$toolName") `
            -Destination (Join-Path $toolRoot $toolName) -Force
    }

    $projectionText = @(
        'core:150.6.b15,552831',
        'dp:1d5645e,553076',
        'en:dee9e75,552072',
        'ja:8995876,552078',
        'ko:bef9fc2,551960',
        'fd:85b12fc,552446',
        'saus:19e939d,552998'
    ) -join "`n"
    New-Item -ItemType Directory -Path (Split-Path -Parent $projectionPath) `
        -Force | Out-Null
    [IO.File]::WriteAllText(
        $projectionPath, $projectionText, [Text.UTF8Encoding]::new($false))
    Assert-True (Test-PathDigest $projectionPath 131L `
        'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') `
        'phase3b2_resource_host_map_projection_invalid'

    $deployment = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($deployment.contractId -ceq
        'nll/phase3b2-physical-p2-v2-offline-deployment/v1') `
        'phase3b2_resource_host_map_prior_deployment_invalid'
    $deployment | Add-Member NoteProperty amendedAtUtc `
        ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Force
    $deployment | Add-Member NoteProperty amendmentCode `
        'resource_host_version_map_projection' -Force
    $deployment | Add-Member NoteProperty externalHead $externalHead -Force
    $deployment | Add-Member NoteProperty externalTree $externalTree -Force
    $deployment | Add-Member NoteProperty handlerIsolationPassedCount `
        $handlerResult.passedCount -Force
    $deployment | Add-Member NoteProperty selectedManagerPassedCount `
        $selectedResult.passedCount -Force
    $deployment | Add-Member NoteProperty appliedServerDllByteLength `
        (Get-Item $runtimeServerDll).Length -Force
    $deployment | Add-Member NoteProperty appliedServerDllSha256 `
        (Get-Sha256Hex $runtimeServerDll) -Force
    $deployment | Add-Member NoteProperty resourceCoreVersion '150.6.b15' -Force
    $deployment | Add-Member NoteProperty resourceDataPackVersion '651' -Force
    $deployment | Add-Member NoteProperty coreVersionMapProjected $true -Force
    $deployment | Add-Member NoteProperty dataPackVersionMapProjected $true -Force
    foreach ($tool in @($deployment.tools)) {
        $toolPath = Join-Path $toolRoot ([string]$tool.name)
        Assert-True (Test-Path -LiteralPath $toolPath -PathType Leaf) `
            'phase3b2_resource_host_map_deployment_tool_missing'
        $tool.byteLength = (Get-Item $toolPath).Length
        $tool.sha256 = Get-Sha256Hex $toolPath
    }
    $toolManifestLines = @($deployment.tools | Sort-Object name | ForEach-Object {
        "{0}`t{1}`t{2}" -f $_.name, $_.byteLength, $_.sha256
    })
    Write-AtomicUtf8NoBom $toolManifestPath (($toolManifestLines -join "`n") + "`n")
    $deployment | Add-Member NoteProperty toolManifestByteLength `
        (Get-Item $toolManifestPath).Length -Force
    $deployment | Add-Member NoteProperty toolManifestSha256 `
        (Get-Sha256Hex $toolManifestPath) -Force
    Write-AtomicUtf8NoBom $deploymentReceiptPath `
        (($deployment | ConvertTo-Json -Depth 10) + "`n")

    $rollback = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-p2-v2-resource-host-map-rollback/v1'
        createdAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        backupMembers = @($backupPairs.GetEnumerator() | ForEach-Object {
            $backupPath = Join-Path $backupRoot $_.Key
            [ordered]@{
                roleCode = $_.Key
                destinationPath = $_.Value
                byteLength = (Get-Item $backupPath).Length
                sha256 = Get-Sha256Hex $backupPath
            }
        })
        exactProjectionWasAbsentBeforeRepair = $true
        exactProjectionRollbackActionCode = 'remove_exact_projection'
        runtimeCold = $true
    }
    Write-AtomicUtf8NoBom $rollbackManifestPath `
        (($rollback | ConvertTo-Json -Depth 9) + "`n")

    $authorization = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-p2-v2-resource-host-map-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReasonCode = 'addressable_catalog_group_core_key_missing'
        failureReceiptByteLength = (Get-Item $failureReceiptPath).Length
        failureReceiptSha256 = Get-Sha256Hex $failureReceiptPath
        recoveryReceiptByteLength = (Get-Item $recoveryReceiptPath).Length
        recoveryReceiptSha256 = Get-Sha256Hex $recoveryReceiptPath
        externalHead = $externalHead
        externalTree = $externalTree
        handlerIsolationPassedCount = $handlerResult.passedCount
        selectedManagerPassedCount = $selectedResult.passedCount
        resourceCoreVersion = '150.6.b15'
        resourceDataPackVersion = '651'
        localContentVersionDataPackTag = '1d5645e'
        coreVersionMapProjected = $true
        dataPackVersionMapProjected = $true
        appliedServerDllByteLength = (Get-Item $runtimeServerDll).Length
        appliedServerDllSha256 = Get-Sha256Hex $runtimeServerDll
        appliedGameConfigByteLength = (Get-Item $runtimeGameConfig).Length
        appliedGameConfigSha256 = Get-Sha256Hex $runtimeGameConfig
        deploymentReceiptByteLength = (Get-Item $deploymentReceiptPath).Length
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        rollbackManifestByteLength = (Get-Item $rollbackManifestPath).Length
        rollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
        projectedByteLength = (Get-Item $projectionPath).Length
        projectedSha256 = Get-Sha256Hex $projectionPath
        priorCatalogParserExactRetryConsumptionSha256 =
            Get-Sha256Hex $priorConsumptionPath
        completionTaskkillRaceHandledByPinnedProcessRecheck = $true
        interactiveMeasurementSeconds = 30
        endpointContractChanged = $false
        singleResourceHostMapRetryAuthorized = $true
        retryConsumed = $false
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_as_nlloperator_and_run_resource_host_map_retry_once'
    }
    Write-AtomicUtf8NoBom $authorizationPath `
        (($authorization | ConvertTo-Json -Depth 9) + "`n")

    Add-ArchiveMove $preparationEvidence `
        (Join-Path $backupRoot 'p2-preparation-v2.before-resource-host-map')
    Add-ArchiveMove $preparationBackup `
        (Join-Path $backupRoot 'PhysicalP2-v2.before-resource-host-map')
    Add-ArchiveMove $protectedPreparation `
        ($protectedPreparation + '.before-resource-host-map')

    New-Item -ItemType Directory -Path $SamsungProtectedRoot -Force | Out-Null
    foreach ($path in @($authorizationPath, $deploymentReceiptPath,
            $rollbackManifestPath, $failureReceiptPath, $recoveryReceiptPath)) {
        $copy = Join-Path $SamsungProtectedRoot `
            ('resource-host-map.' + (Split-Path -Leaf $path))
        Copy-Item -LiteralPath $path -Destination $copy -Force
        Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_resource_host_map_protected_copy_failed'
    }

    [pscustomobject]@{
        Receipt = $authorization
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength = (Get-Item $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        RuntimeServerDllSha256 = Get-Sha256Hex $runtimeServerDll
        RuntimeGameConfigSha256 = Get-Sha256Hex $runtimeGameConfig
        ExactProjectionSha256 = Get-Sha256Hex $projectionPath
        RetryConsumed = $false
    } | ConvertTo-Json -Depth 11
}
catch {
    if ($mutationsStarted) {
        for ($index = $archiveMoves.Count - 1; $index -ge 0; $index--) {
            $move = $archiveMoves[$index]
            if ((Test-Path -LiteralPath $move.Destination) -and
                -not (Test-Path -LiteralPath $move.Source)) {
                Move-Item -LiteralPath $move.Destination `
                    -Destination $move.Source -ErrorAction SilentlyContinue
            }
        }
        foreach ($entry in $backupPairs.GetEnumerator()) {
            $backupPath = Join-Path $backupRoot $entry.Key
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Copy-Item -LiteralPath $backupPath -Destination $entry.Value `
                    -Force -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $projectionPath -PathType Leaf) {
            Remove-Item -LiteralPath $projectionPath -Force `
                -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $authorizationPath -PathType Leaf) {
            Remove-Item -LiteralPath $authorizationPath -Force `
                -ErrorAction SilentlyContinue
        }
    }
    throw
}
finally {
    if ($testRoot -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
}
