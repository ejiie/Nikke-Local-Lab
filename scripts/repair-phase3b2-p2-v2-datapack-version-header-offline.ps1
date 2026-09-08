[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$failedAssessmentUid = 'deafa3e3-d889-4a09-8a66-fc7dc3e27305'
$projectedByteLength = 139L
$projectedSha256 =
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$mutationsStarted = $false
$projectionCreated = $false
$archiveMoves = [Collections.Generic.List[object]]::new()
$scratchRoot = $null
$projectionBytes = $null
$baselineManifestBytes = $null

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ByteArraySha256Hex {
    param([byte[]]$Bytes)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha256.ComputeHash($Bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
    }
    finally { $sha256.Dispose() }
}

function Get-ToolManifestText {
    param([object[]]$Tools)
    [string[]]$names = @($Tools | ForEach-Object { [string]$_.name })
    [Array]::Sort($names, [StringComparer]::OrdinalIgnoreCase)
    ((@($names | ForEach-Object {
        $name = $_
        $matches = @($Tools | Where-Object {
            [string]$_.name -ceq $name
        })
        Assert-True ($matches.Count -eq 1) `
            'phase3b2_datapack_header_manifest_tool_name_invalid'
        "{0}`t{1}`t{2}" -f $matches[0].name, $matches[0].byteLength,
            $matches[0].sha256
    }) -join "`n") + "`n")
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

function Add-ArchiveMove {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Source) {
        Assert-True (-not (Test-Path -LiteralPath $Destination)) `
            'phase3b2_datapack_header_archive_destination_present'
        Move-Item -LiteralPath $Source -Destination $Destination
        $archiveMoves.Add([pscustomobject]@{
            Source = $Source
            Destination = $Destination
        })
    }
}

function Assert-PowerShellFileParses {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) `
        'phase3b2_datapack_header_powershell_parse_failed'
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_datapack_header_repair_requires_administrator'
$micronLetter = $MicronDrive.TrimEnd(':')
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_datapack_header_repair_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_datapack_header_repair_runtime_not_cold'

$p2Root = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-client-start-v2'
$runRoot = Join-Path $p2Root $failedAssessmentUid
$failurePath = Join-Path $runRoot 'resource-host-map-failure.receipt.json'
$recoveryPath = Join-Path $runRoot `
    'resource-host-map-cold-recovery.receipt.json'
$priorConsumptionPath = Join-Path $p2Root `
    'resource-host-map-retry.consumed.json'
$activePointerPath = Join-Path $p2Root 'active-run.pointer.json'
$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
$authorizationPath = Join-Path $transferRoot `
    'datapack-version-header-repair.receipt.json'
$projectionReceiptPath = Join-Path $transferRoot `
    'datapack-version-header-projection.receipt.json'
$staticAnalysisPath = Join-Path $transferRoot `
    'datapack-version-header-static-analysis.receipt.json'
$deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
$toolManifestPath = Join-Path $transferRoot 'tools.manifest.tsv'
$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$projectionPath = Join-Path $serverRoot `
    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$lcvPath = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\.lcv.dat'
$gameConfigPath = Join-Path $MicronDrive 'NLL\EpinelPS\EpinelPS\gameconfig.json'
$gameAssemblyPath = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\GameAssembly.dll'
$toolRoot = Join-Path $MicronDrive 'NLL\Tools'
$toolNames = @(
    'start-phase3b2-physical-p2-v2-client-in-micron.ps1',
    'complete-phase3b2-physical-p2-v2-client-in-micron.ps1',
    'Start-Phase3B2-Physical-P2-V2.ps1'
)
$projectionProjectRoot = Join-Path $RepositoryRoot `
    'tools\Phase3B2\ContentVersionProjection'
$projectionProject = Join-Path $projectionProjectRoot `
    'NikkeLocalLab.Phase3B2.ContentVersionProjection.csproj'
$projectionDll = Join-Path $projectionProjectRoot `
    'bin\Release\net10.0\NikkeLocalLab.Phase3B2.ContentVersionProjection.dll'
$dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-DataPackVersionHeader-v1'
$backupToolRoot = Join-Path $backupRoot 'tools'
$backupDeploymentPath = Join-Path $backupRoot 'deployment.receipt.json'
$backupProtectedDeploymentPath = Join-Path $backupRoot `
    'protected-offline-deployment.receipt.json'
$backupManifestPath = Join-Path $backupRoot 'tools.manifest.tsv'
$rollbackManifestPath = Join-Path $backupRoot 'rollback.manifest.json'
$protectedDeploymentRoot = Join-Path $SamsungProtectedRoot 'V2Deployment'
$protectedAuthorizationPath = Join-Path $protectedDeploymentRoot `
    'datapack-version-header-repair.receipt.json'
$protectedProjectionReceiptPath = Join-Path $protectedDeploymentRoot `
    'datapack-version-header-projection.receipt.json'
$protectedStaticAnalysisPath = Join-Path $protectedDeploymentRoot `
    'datapack-version-header-static-analysis.receipt.json'
$protectedDeploymentPath = Join-Path $protectedDeploymentRoot `
    'offline-deployment.receipt.json'
$micronPreparationRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-preparation-v2'
$micronPreparationBackupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-v2'
$protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'PreparationV2'
$archiveSuffix = '.before-datapack-version-header-' + $failedAssessmentUid

$requiredFiles = @($failurePath, $recoveryPath, $priorConsumptionPath,
    $deploymentPath, $serverDllPath, $lcvPath,
    $gameConfigPath, $gameAssemblyPath, $projectionProject, $dotnetPath,
    $protectedDeploymentPath) + @($toolNames | ForEach-Object {
        Join-Path $RepositoryRoot "scripts\$_"
    }) + @($toolNames | ForEach-Object {
        Join-Path $toolRoot $_
    })
$missingInputPaths = @($requiredFiles | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Leaf)
})
if ($missingInputPaths.Count -ne 0) {
    throw ('phase3b2_datapack_header_repair_input_missing:missing=[' +
        ($missingInputPaths -join ';') + ']')
}
Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
    -not (Test-Path -LiteralPath $projectionPath) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $authorizationPath) -and
    -not (Test-Path -LiteralPath $projectionReceiptPath) -and
    -not (Test-Path -LiteralPath $staticAnalysisPath) -and
    -not (Test-Path -LiteralPath $protectedAuthorizationPath) -and
    -not (Test-Path -LiteralPath $protectedProjectionReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedStaticAnalysisPath)) `
    'phase3b2_datapack_header_repair_destination_present'

$failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$recovery = Get-Content -LiteralPath $recoveryPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$consumption = Get-Content -LiteralPath $priorConsumptionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$baselineDeployment = Get-Content -LiteralPath $deploymentPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$baselineManifestText = Get-ToolManifestText @($baselineDeployment.tools)
$baselineManifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(
    $baselineManifestText)
$toolManifestWasPresentBeforeRepair = Test-Path -LiteralPath $toolManifestPath `
    -PathType Leaf
Assert-True ($baselineDeployment.contractId -ceq
        'nll/phase3b2-physical-p2-v2-offline-deployment/v1' -and
    [int]$baselineDeployment.transferredToolCount -eq
        @($baselineDeployment.tools).Count -and
    [long]$baselineDeployment.toolManifestByteLength -eq
        $baselineManifestBytes.Length -and
    $baselineDeployment.toolManifestSha256 -ceq
        (Get-ByteArraySha256Hex $baselineManifestBytes) -and
    (-not $toolManifestWasPresentBeforeRepair -or
        (Test-PathDigest $toolManifestPath `
            ([long]$baselineDeployment.toolManifestByteLength) `
            ([string]$baselineDeployment.toolManifestSha256)))) `
    'phase3b2_datapack_header_baseline_manifest_invalid'
foreach ($tool in @($baselineDeployment.tools)) {
    Assert-True (Test-PathDigest (Join-Path $toolRoot ([string]$tool.name)) `
            ([long]$tool.byteLength) ([string]$tool.sha256)) `
        ('phase3b2_datapack_header_baseline_tool_invalid:' +
            [string]$tool.name)
}
Assert-True ((Test-PathDigest $failurePath 1366L `
        'ab7fee0b2f540b4839e8ffc04288dbfa2625436b16768d123a55b93ed1523f4a') -and
    (Test-PathDigest $recoveryPath 2709L `
        'ff29dbed6fdc1e58906cdc0b94c01ebda4e2d5e5945bce85ba695f03af295c03') -and
    (Test-PathDigest $priorConsumptionPath 1065L `
        '003e7c815adff246d29f31c348ecd3d0775dc793c74b9657d1dd978f6e2a3779') -and
    $failure.contractId -ceq
        'nll/phase3b2-p2-v2-resource-host-map-failure/v1' -and
    $failure.assessmentUid -ceq $failedAssessmentUid -and
    $failure.failureStageCode -ceq 'catalogue_resource_path_upgrade' -and
    $failure.reasonCode -ceq
        'core_key_missing_after_resource_host_version_map_projection' -and
    $failure.resourceHostVersionMapHypothesisFalsified -and
    $failure.missingDictionaryKeyCode -ceq 'core' -and
    $recovery.contractId -ceq
        'nll/phase3b2-p2-v2-resource-host-map-cold-recovery/v1' -and
    $recovery.failedAssessmentUid -ceq $failedAssessmentUid -and
    $recovery.databaseRestored -and $recovery.sqliteRuntimeRemoved -and
    $recovery.exactProjectionRemoved -and
    $recovery.resourceHostMapMutationRolledBack -and
    $consumption.contractId -ceq
        'nll/phase3b2-p2-v2-resource-host-map-retry-consumption/v1' -and
    $consumption.assessmentUid -ceq $failedAssessmentUid -and
    $consumption.singleRetryConsumed) `
    'phase3b2_datapack_header_failure_recovery_invalid'
Assert-True ((Test-PathDigest $lcvPath 3775L `
        'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
    (Test-PathDigest $gameAssemblyPath 265846312L `
        'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954') -and
    (Test-PathDigest $serverDllPath 15371264L `
        'af7a4165e9ff2da5f4e0f4117ab546e04ddfc095d4e1e9916b4bc83458f8c58c')) `
    'phase3b2_datapack_header_pinned_binary_invalid'
foreach ($toolName in $toolNames) {
    Assert-PowerShellFileParses (Join-Path $RepositoryRoot "scripts\$toolName")
}

$oldRoot = $env:DOTNET_ROOT
$oldHome = $env:DOTNET_CLI_HOME
$oldTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    $env:DOTNET_ROOT = Join-Path $MicronDrive 'Program Files\dotnet'
    $env:DOTNET_CLI_HOME = Join-Path $env:TEMP 'nll-datapack-header-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Push-Location $projectionProjectRoot
    try {
        & $dotnetPath build $projectionProject -c Release --no-restore --nologo
        Assert-True ($LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $projectionDll -PathType Leaf)) `
            'phase3b2_datapack_header_projection_build_failed'
    }
    finally { Pop-Location }
}
finally {
    $env:DOTNET_ROOT = $oldRoot
    $env:DOTNET_CLI_HOME = $oldHome
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldTelemetry
}

$scratchRoot = Join-Path $env:TEMP `
    ('nll-datapack-header-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
$projectionOutput = & $dotnetPath $projectionDll $lcvPath $gameConfigPath `
    $scratchRoot
Assert-True ($LASTEXITCODE -eq 0) `
    'phase3b2_datapack_header_projection_execution_failed'
$projection = (($projectionOutput | Out-String).Trim()) | ConvertFrom-Json
$scratchProjection = Join-Path $scratchRoot `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$projectionBytes = [IO.File]::ReadAllBytes($scratchProjection)
$projectionLines = [IO.File]::ReadAllLines(
    $scratchProjection, [Text.UTF8Encoding]::new($false, $true))
Assert-True ($projection.contractId -ceq
        'nll/phase3b2-local-content-version-projection/v3' -and
    $projection.standaloneVersionHeader -ceq '1c27990' -and
    -not $projection.standaloneVersionMatchesLatestPostfix -and
    [int]$projection.projectedLineCount -eq 8 -and
    [int]$projection.entryCount -eq 7 -and
    [long]$projection.projectedByteLength -eq $projectedByteLength -and
    $projection.projectedSha256 -ceq $projectedSha256 -and
    (Test-PathDigest $scratchProjection $projectedByteLength $projectedSha256) -and
    $projectionBytes[$projectionBytes.Length - 1] -ne 10 -and
    $projectionLines.Count -eq 8 -and
    $projectionLines[0] -ceq '1c27990' -and
    $projectionLines[1] -ceq 'core:150.6.b15,552831' -and
    $projectionLines[2] -ceq 'dp:1d5645e,553076') `
    'phase3b2_datapack_header_projection_contract_invalid'

try {
    New-Item -ItemType Directory -Path $backupToolRoot, $transferRoot,
        $protectedDeploymentRoot -Force | Out-Null
    foreach ($toolName in $toolNames) {
        Copy-Item -LiteralPath (Join-Path $toolRoot $toolName) `
            -Destination (Join-Path $backupToolRoot $toolName)
    }
    Copy-Item -LiteralPath $deploymentPath -Destination $backupDeploymentPath
    Copy-Item -LiteralPath $protectedDeploymentPath `
        -Destination $backupProtectedDeploymentPath
    if ($toolManifestWasPresentBeforeRepair) {
        Copy-Item -LiteralPath $toolManifestPath `
            -Destination $backupManifestPath
    }

    $mutationsStarted = $true
    Add-ArchiveMove $micronPreparationRoot `
        ($micronPreparationRoot + $archiveSuffix)
    Add-ArchiveMove $micronPreparationBackupRoot `
        ($micronPreparationBackupRoot + $archiveSuffix)
    Add-ArchiveMove $protectedPreparationRoot `
        ($protectedPreparationRoot + $archiveSuffix)

    foreach ($toolName in $toolNames) {
        Copy-Item -LiteralPath (Join-Path $RepositoryRoot "scripts\$toolName") `
            -Destination (Join-Path $toolRoot $toolName) -Force
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $projectionPath) `
        -Force | Out-Null
    [IO.File]::WriteAllBytes($projectionPath, $projectionBytes)
    $projectionCreated = $true
    Assert-True (Test-PathDigest $projectionPath $projectedByteLength `
            $projectedSha256) `
        'phase3b2_datapack_header_projection_apply_failed'

    $projectionReceiptText = (($projection | ConvertTo-Json -Depth 8) + "`n")
    Write-AtomicUtf8NoBom $projectionReceiptPath $projectionReceiptText
    $staticAnalysis = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-datapack-version-header-static-analysis/v1'
        analyzedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        analysisModeCode = 'offline_static_il2cpp_disassembly_and_lcv_projection'
        clientBuild = '150.6.9'
        gameAssemblyByteLength = 265846312
        gameAssemblySha256 =
            'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954'
        parserMethodCode =
            'ContentVersion2.DataPackEntry.GetVersionAsync.MoveNext'
        parserMethodRva = '0x648bc80'
        runtimeHelpersMethodCode = 'RuntimeHelpers.GetSubArray<object>'
        runtimeHelpersMethodRva = '0x12fb150'
        firstLineRoleCode = 'standalone_datapack_version'
        remainingLineRoleCode = 'named_subentry'
        nativeFirstLineConsumedAsVersion = $true
        nativeRemainingLinesParsedAsEntries = $true
        priorFirstNamedEntryOmittedFromDictionary = 'core'
        priorFailureMissingDictionaryKey = 'core'
        standaloneVersionHeader = '1c27990'
        headerSourceCode = 'installed_client_serialized_datapack_version'
        projectedLineCount = 8
        namedEntryCount = 7
        coreEntryPresentAfterHeader = $true
        terminalNewlinePresent = $false
        officialOutboundUsed = $false
        processInjectionOrHookingAttempted = $false
        memoryPatchAttempted = $false
        gameBinaryModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $staticAnalysisPath `
        (($staticAnalysis | ConvertTo-Json -Depth 7) + "`n")
    $rollback = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-datapack-version-header-rollback/v1'
        createdAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        targetRoleCode = 'epinelps_local_content_version_cache'
        targetWasAbsentBeforeRepair = $true
        projectedByteLength = $projectedByteLength
        projectedSha256 = $projectedSha256
        removeOnlyWhenExactDigestMatches = $true
        backedUpToolCount = $toolNames.Count
        preparationStateArchived = $true
        officialOutboundUsed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $rollbackManifestPath `
        (($rollback | ConvertTo-Json -Depth 7) + "`n")

    $deployment = Get-Content -LiteralPath $deploymentPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($deployment.contractId -ceq
        'nll/phase3b2-physical-p2-v2-offline-deployment/v1') `
        'phase3b2_datapack_header_deployment_invalid'
    foreach ($tool in @($deployment.tools)) {
        $toolPath = Join-Path $toolRoot ([string]$tool.name)
        Assert-True (Test-Path -LiteralPath $toolPath -PathType Leaf) `
            'phase3b2_datapack_header_deployment_tool_missing'
        $tool.byteLength = (Get-Item -LiteralPath $toolPath).Length
        $tool.sha256 = Get-Sha256Hex $toolPath
    }
    $manifestText = Get-ToolManifestText @($deployment.tools)
    Write-AtomicUtf8NoBom $toolManifestPath $manifestText
    $deployment.toolManifestByteLength = (Get-Item $toolManifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $toolManifestPath
    $deployment | Add-Member NoteProperty amendedAtUtc `
        ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) -Force
    $deployment | Add-Member NoteProperty amendmentCode `
        'datapack_version_header_projection' -Force
    $deployment | Add-Member NoteProperty dataPackVersionHeaderApplied `
        $true -Force
    $deployment | Add-Member NoteProperty standaloneDataPackVersionHeader `
        '1c27990' -Force
    $deployment | Add-Member NoteProperty catalogVersionProjectionByteLength `
        $projectedByteLength -Force
    $deployment | Add-Member NoteProperty catalogVersionProjectionSha256 `
        $projectedSha256 -Force
    $deployment | Add-Member NoteProperty resourceHostMapMutationRolledBack `
        $true -Force
    $deployment | Add-Member NoteProperty completionNormalWindowCloseEnabled `
        $true -Force
    $deployment | Add-Member NoteProperty singleDataPackVersionHeaderRetryAuthorized `
        $true -Force
    $deployment.nextStepCode =
        'boot_micron_as_nlloperator_and_run_datapack_version_header_retry_once'
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 10) + "`n")
    Copy-Item -LiteralPath $deploymentPath -Destination $protectedDeploymentPath `
        -Force

    $authorization = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-p2-v2-datapack-version-header-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReasonCode =
            'first_line_consumed_as_standalone_version_core_entry_omitted'
        failureReceiptByteLength = (Get-Item $failurePath).Length
        failureReceiptSha256 = Get-Sha256Hex $failurePath
        recoveryReceiptByteLength = (Get-Item $recoveryPath).Length
        recoveryReceiptSha256 = Get-Sha256Hex $recoveryPath
        priorRetryConsumptionByteLength =
            (Get-Item $priorConsumptionPath).Length
        priorRetryConsumptionSha256 = Get-Sha256Hex $priorConsumptionPath
        priorToolManifestPresent = $toolManifestWasPresentBeforeRepair
        priorToolManifestReconstructedFromDeployment =
            (-not $toolManifestWasPresentBeforeRepair)
        priorToolManifestByteLength = $baselineManifestBytes.Length
        priorToolManifestSha256 = Get-ByteArraySha256Hex $baselineManifestBytes
        sourceLcvByteLength = (Get-Item $lcvPath).Length
        sourceLcvSha256 = Get-Sha256Hex $lcvPath
        projectionReceiptByteLength = (Get-Item $projectionReceiptPath).Length
        projectionReceiptSha256 = Get-Sha256Hex $projectionReceiptPath
        staticAnalysisReceiptByteLength = (Get-Item $staticAnalysisPath).Length
        staticAnalysisReceiptSha256 = Get-Sha256Hex $staticAnalysisPath
        rollbackManifestByteLength = (Get-Item $rollbackManifestPath).Length
        rollbackManifestSha256 = Get-Sha256Hex $rollbackManifestPath
        standaloneVersionHeader = '1c27990'
        projectedLineCount = 8
        namedEntryCount = 7
        projectedByteLength = $projectedByteLength
        projectedSha256 = $projectedSha256
        nativeFirstLineConsumedAsVersion = $true
        nativeRemainingLinesParsedAsEntries = $true
        coreEntryPresentAfterHeader = $true
        resourceHostMapHypothesisFalsified = $true
        resourceHostMapMutationRolledBack = $true
        runtimeServerDllByteLength = (Get-Item $serverDllPath).Length
        runtimeServerDllSha256 = Get-Sha256Hex $serverDllPath
        preparationStateArchivedForReapply = $true
        completionNormalWindowCloseEnabled = $true
        deploymentReceiptByteLength = (Get-Item $deploymentPath).Length
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        interactiveMeasurementSeconds = 30
        endpointContractChanged = $false
        singleDataPackVersionHeaderRetryAuthorized = $true
        retryConsumed = $false
        officialOutboundUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode =
            'boot_micron_as_nlloperator_and_run_datapack_version_header_retry_once'
    }
    Write-AtomicUtf8NoBom $authorizationPath `
        (($authorization | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $authorizationPath `
        -Destination $protectedAuthorizationPath
    Copy-Item -LiteralPath $projectionReceiptPath `
        -Destination $protectedProjectionReceiptPath
    Copy-Item -LiteralPath $staticAnalysisPath `
        -Destination $protectedStaticAnalysisPath

    Assert-True ((Test-PathDigest $projectionPath $projectedByteLength `
            $projectedSha256) -and
        (Get-Sha256Hex $authorizationPath) -ceq
            (Get-Sha256Hex $protectedAuthorizationPath) -and
        (Get-Sha256Hex $projectionReceiptPath) -ceq
            (Get-Sha256Hex $protectedProjectionReceiptPath) -and
        (Get-Sha256Hex $staticAnalysisPath) -ceq
            (Get-Sha256Hex $protectedStaticAnalysisPath) -and
        (Get-Sha256Hex $deploymentPath) -ceq
            (Get-Sha256Hex $protectedDeploymentPath) -and
        -not (Test-Path -LiteralPath $micronPreparationRoot) -and
        -not (Test-Path -LiteralPath $micronPreparationBackupRoot) -and
        -not (Test-Path -LiteralPath $protectedPreparationRoot)) `
        'phase3b2_datapack_header_post_apply_invalid'

    [pscustomobject]@{
        Receipt = $authorization
        MicronReceiptPath = $authorizationPath
        MicronReceiptByteLength = (Get-Item $authorizationPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $authorizationPath
        SamsungProtectedReceiptPath = $protectedAuthorizationPath
    } | ConvertTo-Json -Depth 9
}
catch {
    if ($mutationsStarted) {
        foreach ($toolName in $toolNames) {
            $backupPath = Join-Path $backupToolRoot $toolName
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Copy-Item -LiteralPath $backupPath `
                    -Destination (Join-Path $toolRoot $toolName) -Force
            }
        }
        if (Test-Path -LiteralPath $backupDeploymentPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupDeploymentPath `
                -Destination $deploymentPath -Force
        }
        if (Test-Path -LiteralPath $backupProtectedDeploymentPath `
                -PathType Leaf) {
            Copy-Item -LiteralPath $backupProtectedDeploymentPath `
                -Destination $protectedDeploymentPath -Force
        }
        if (Test-Path -LiteralPath $backupManifestPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupManifestPath `
                -Destination $toolManifestPath -Force
        }
        elseif (-not $toolManifestWasPresentBeforeRepair -and
            (Test-Path -LiteralPath $toolManifestPath -PathType Leaf)) {
            Remove-Item -LiteralPath $toolManifestPath -Force
        }
        if ($projectionCreated -and (Test-Path -LiteralPath $projectionPath)) {
            Remove-Item -LiteralPath $projectionPath -Force
        }
        foreach ($path in @($authorizationPath, $projectionReceiptPath,
                $staticAnalysisPath, $protectedAuthorizationPath,
                $protectedProjectionReceiptPath, $protectedStaticAnalysisPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        for ($index = $archiveMoves.Count - 1; $index -ge 0; $index--) {
            $move = $archiveMoves[$index]
            if ((Test-Path -LiteralPath $move.Destination) -and
                -not (Test-Path -LiteralPath $move.Source)) {
                Move-Item -LiteralPath $move.Destination `
                    -Destination $move.Source
            }
        }
    }
    throw
}
finally {
    if ($scratchRoot -and (Test-Path -LiteralPath $scratchRoot)) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
    if ($projectionBytes) {
        [Array]::Clear($projectionBytes, 0, $projectionBytes.Length)
    }
    if ($baselineManifestBytes) {
        [Array]::Clear($baselineManifestBytes, 0, $baselineManifestBytes.Length)
    }
}
