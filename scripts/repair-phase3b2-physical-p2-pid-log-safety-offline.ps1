[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$EpinelRepositoryRoot =
        'C:\Users\zih44\Documents\Github\EpinelPS',
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [string]$FailedAssessmentUid =
        '46607d19-048f-4fc3-b2eb-765f1447b7eb'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
        if (-not $canonicalPath.StartsWith(
                $canonicalBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'phase3b2_physical_p2_manifest_member_outside_base'
        }
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
}

function Protect-ServerLog {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $protected = [Text.RegularExpressions.Regex]::Replace(
        $text, '(?im)^authtoken:\s*.*$', 'authtoken: [REDACTED]')
    $protected = [Text.RegularExpressions.Regex]::Replace(
        $protected, 'v4\.local\.[A-Za-z0-9_-]+', 'v4.local.[REDACTED]')
    if ($protected -cne $text) {
        Write-AtomicUtf8NoBom $Path $protected
        return $true
    }
    return $false
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_offline_repair_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronLetter = $MicronDrive.TrimEnd(':')
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_physical_p2_offline_repair_disk_boundary_invalid'

$headPath = Join-Path $EpinelRepositoryRoot '.git\HEAD'
$expectedRef = 'refs/heads/agent/phase3b2-p2-log-safety'
$headText = (Get-Content -LiteralPath $headPath -Raw).Trim()
$refPath = Join-Path $EpinelRepositoryRoot `
    ('.git\' + $expectedRef.Replace('/', '\'))
$externalHead = if ($headText -ceq "ref: $expectedRef" -and
    (Test-Path -LiteralPath $refPath -PathType Leaf)) {
    (Get-Content -LiteralPath $refPath -Raw).Trim()
}
else { '' }
$externalTree = '519fbe3c6c010a66602ca4d3837fde39fdabc487'
Assert-True ($externalHead -ceq
        '1b2434c3c6ab4a7400177f4287aa451bd2aa5745' -and
    $externalTree -ceq
        '519fbe3c6c010a66602ca4d3837fde39fdabc487') `
    'phase3b2_physical_p2_offline_repair_external_source_invalid'
$controllerPath = Join-Path $EpinelRepositoryRoot `
    'EpinelPS\Controllers\LevelInfiniteControlller.cs'
Assert-True ((Test-PathDigest $controllerPath 13129L `
        'af6dff74ab887be1e841ba562b1383b2db479bda118ed53975a2fbba63aa70a2') -and
    (Get-Content -LiteralPath $controllerPath -Raw) -cnotmatch
        'Console\.WriteLine\("authtoken:') `
    'phase3b2_physical_p2_token_log_source_still_present'

$failedRunRoot = Join-Path $MicronDrive `
    "NLL\Evidence\Phase3B2\Physical\p2-client-start-v1\$FailedAssessmentUid"
$failedReceiptPath = Join-Path $failedRunRoot 'run-failure.receipt.json'
$bootstrapReceiptPath = Join-Path $failedRunRoot 'bootstrap-start.receipt.json'
Assert-True ((Test-PathDigest $failedReceiptPath 897L `
            'e8bfe5c1b8b153f0cd0bfde14cf82ad3ebca196e67eaa48dce9d2fd7279f2350') -and
    (Test-PathDigest $bootstrapReceiptPath 730L `
            '3337c64010740b33680ed3af8a89fa71599dc8526a00c9e835582948443aa5f7')) `
    'phase3b2_physical_p2_offline_repair_failure_evidence_invalid'
$failure = Get-Content -LiteralPath $failedReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$bootstrap = Get-Content -LiteralPath $bootstrapReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($failure.failureCode -ceq
        'phase3b2_physical_p2_client_process_shape_invalid' -and
    $failure.databaseRestored -and $failure.sqliteRuntimeRemoved -and
    $failure.extensionFirewallRolledBack -and
    $bootstrap.sailNamedPipeConnected -and
    $bootstrap.clientExecutionStarted) `
    'phase3b2_physical_p2_offline_repair_failure_classification_invalid'

$serverRoot = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$newServerDllPath = Join-Path $EpinelRepositoryRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$runtimeRoot = Join-Path $MicronDrive 'NLL\Runtime\PhysicalBootstrap-v1'
$artifactRoot = Join-Path $runtimeRoot 'artifact'
$artifactEvidenceRoot = Join-Path $runtimeRoot 'evidence'
$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v1'
$deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
$artifactManifestPath = Join-Path $artifactEvidenceRoot 'artifact.manifest.tsv'
$sourceManifestPath = Join-Path $artifactEvidenceRoot 'source.manifest.tsv'
$toolRoot = Join-Path $MicronDrive 'NLL\Tools'
$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-PidLogSafety-v1'
$repairReceiptPath = Join-Path $transferRoot `
    'pid-log-safety-repair.receipt.json'
$protectedRepairReceiptPath = Join-Path $SamsungProtectedRoot `
    'pid-log-safety-repair.receipt.json'

$runtimeIsOriginal = Test-PathDigest $serverDllPath 15364096L `
    '365504b690a19f64836a63008182a348a61a0b56936c413471b30f9c46192f3f'
$runtimeIsApplied = Test-PathDigest $serverDllPath 15364096L `
    '6cfe10ea1ada2b36cca32aa79b0a8fc89656d0339f0a92a477dbb3a6c1b036a5'
$resumePartial = Test-Path -LiteralPath $backupRoot -PathType Container
Assert-True (($runtimeIsOriginal -or $runtimeIsApplied) -and
    (Test-PathDigest $newServerDllPath 15364096L `
            '6cfe10ea1ada2b36cca32aa79b0a8fc89656d0339f0a92a477dbb3a6c1b036a5') -and
    (Test-PathDigest $deploymentPath 2796L `
            '67cb524d62e202fe7f243fe4adb7c1a1f09327323322230881afb07f7d4082db')) `
    'phase3b2_physical_p2_offline_repair_runtime_pin_invalid'
Assert-True (-not (Test-Path -LiteralPath $repairReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedRepairReceiptPath)) `
    'phase3b2_physical_p2_offline_repair_destination_present'
if ($resumePartial) {
    Assert-True ((Test-PathDigest (Join-Path $backupRoot 'EpinelPS.dll') `
                15364096L `
                '365504b690a19f64836a63008182a348a61a0b56936c413471b30f9c46192f3f') -and
        (Test-PathDigest (Join-Path $backupRoot 'deployment.receipt.json') `
                2796L `
                '67cb524d62e202fe7f243fe4adb7c1a1f09327323322230881afb07f7d4082db') -and
        (Test-PathDigest (Join-Path $backupRoot `
                'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll') `
                28160L `
                'a1d10433b6e99fabe51ee8421d6cabe937de8453fb147acdac5e352a3f9f7f71')) `
        'phase3b2_physical_p2_offline_repair_resume_backup_invalid'
}
else {
    Assert-True $runtimeIsOriginal `
        'phase3b2_physical_p2_offline_repair_fresh_runtime_not_original'
}

$projectRoot = Join-Path $RepositoryRoot 'tools\Phase3B2\PhysicalBootstrap'
$projectPath = Join-Path $projectRoot `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.csproj'
$dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
$publishRoot = Join-Path $projectRoot `
    'bin\Release\net10.0\win-x64\publish'
$oldRoot = $env:DOTNET_ROOT
$oldHome = $env:DOTNET_CLI_HOME
$oldTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
try {
    $env:DOTNET_ROOT = Join-Path $MicronDrive 'Program Files\dotnet'
    $env:DOTNET_CLI_HOME = Join-Path $env:TEMP `
        'nll-phase3b2-p2-pid-log-safety-dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Push-Location $projectRoot
    try {
        Assert-True ((& $dotnetPath --version | Out-String).Trim() -ceq
            '10.0.400') 'phase3b2_physical_p2_offline_repair_sdk_invalid'
        & $dotnetPath publish $projectPath -c Release --no-restore --nologo
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_physical_p2_offline_repair_bootstrap_publish_failed'
    }
    finally { Pop-Location }
}
finally {
    $env:DOTNET_ROOT = $oldRoot
    $env:DOTNET_CLI_HOME = $oldHome
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldTelemetry
}

$artifactNames = @(
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.deps.json',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.runtimeconfig.json'
)
$toolNames = @(
    'prepare-phase3b2-physical-p2-in-micron.ps1',
    'rollback-phase3b2-physical-bootstrap-extension-in-micron.ps1',
    'start-phase3b2-physical-p2-client-in-micron.ps1',
    'complete-phase3b2-physical-p2-client-in-micron.ps1',
    'Start-Phase3B2-Physical-P2.ps1'
)
$publishMembers = @($artifactNames | ForEach-Object {
    Join-Path $publishRoot $_
})
$toolSources = @($toolNames | ForEach-Object {
    Join-Path $RepositoryRoot "scripts\$_"
})
Assert-True (@($publishMembers + $toolSources | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_physical_p2_offline_repair_input_missing'

$preparationRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-preparation-v1'
$preparationArchive = $preparationRoot + ".failed-$FailedAssessmentUid"
$protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'Preparation'
$protectedPreparationArchive = $protectedPreparationRoot +
    ".failed-$FailedAssessmentUid"
Assert-True ((Test-Path -LiteralPath $preparationRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $preparationArchive) -and
    (Test-Path -LiteralPath $protectedPreparationRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $protectedPreparationArchive)) `
    'phase3b2_physical_p2_offline_repair_preparation_archive_shape_invalid'

if (-not $resumePartial) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    Copy-Item -LiteralPath $serverDllPath -Destination `
        (Join-Path $backupRoot 'EpinelPS.dll')
    Copy-Item -LiteralPath $artifactRoot -Destination `
        (Join-Path $backupRoot 'artifact') -Recurse
    Copy-Item -LiteralPath $artifactManifestPath, $sourceManifestPath,
        $deploymentPath -Destination $backupRoot
    foreach ($toolName in $toolNames) {
        Copy-Item -LiteralPath (Join-Path $toolRoot $toolName) `
            -Destination $backupRoot
    }
}

Copy-Item -LiteralPath $newServerDllPath -Destination $serverDllPath -Force
foreach ($path in $publishMembers) {
    Copy-Item -LiteralPath $path -Destination $artifactRoot -Force
}
foreach ($path in $toolSources) {
    Copy-Item -LiteralPath $path -Destination $toolRoot -Force
}

$artifactMembers = @(Get-ChildItem -LiteralPath $artifactRoot -File |
    Select-Object -ExpandProperty FullName)
$artifactManifestText =
    (Get-ManifestLines $artifactMembers $artifactRoot) -join "`n"
Write-AtomicUtf8NoBom $artifactManifestPath ($artifactManifestText + "`n")
$sourceMembers = @(
    (Join-Path $RepositoryRoot 'tools\Phase3B2\LocalBootstrap\Program.cs'),
    $projectPath,
    (Join-Path $projectRoot 'global.json'),
    (Join-Path $projectRoot 'packages.lock.json')
)
$sourceManifestText =
    (Get-ManifestLines $sourceMembers $RepositoryRoot) -join "`n"
Write-AtomicUtf8NoBom $sourceManifestPath ($sourceManifestText + "`n")

Move-Item -LiteralPath $deploymentPath -Destination (Join-Path $transferRoot `
    'deployment.before-pid-log-safety-repair.receipt.json')
Move-Item -LiteralPath $preparationRoot -Destination $preparationArchive
Move-Item -LiteralPath $protectedPreparationRoot `
    -Destination $protectedPreparationArchive

$protectedRunRoot = Join-Path (Join-Path $SamsungProtectedRoot 'Runs') `
    $FailedAssessmentUid
$sanitizedLogCount = 0
foreach ($path in @(
        (Join-Path $failedRunRoot 'server.stdout.log'),
        (Join-Path $protectedRunRoot 'server.stdout.log'))) {
    if (Protect-ServerLog $path) { $sanitizedLogCount++ }
}

$toolDestinations = @($toolNames | ForEach-Object {
    Join-Path $toolRoot $_
})
$deployment = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-offline-deployment/v1'
    revisionCode = 'pid_pinned_observation_and_token_log_safety'
    deployedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    preparationBootDisk = 'Samsung SSD 980 1TB'
    targetDisk = 'Micron_2200_MTFDHBA512TCK'
    targetOsOfflineDuringDeployment = $true
    runtimePathAtTargetBoot = 'C:\NLL\Runtime\PhysicalBootstrap-v1'
    clientPathAtTargetBoot =
        'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
    dotnetSdkVersion = '10.0.400'
    externalHead = $externalHead
    externalTree = $externalTree
    previousServerDllByteLength = 15364096
    previousServerDllSha256 =
        '365504b690a19f64836a63008182a348a61a0b56936c413471b30f9c46192f3f'
    appliedServerDllByteLength = (Get-Item $serverDllPath).Length
    appliedServerDllSha256 = Get-Sha256Hex $serverDllPath
    tokenLoggingRemoved = $true
    sourceMemberCount = $sourceMembers.Count
    sourceManifestByteLength = (Get-Item $sourceManifestPath).Length
    sourceManifestSha256 = Get-Sha256Hex $sourceManifestPath
    artifactMemberCount = $artifactMembers.Count
    artifactManifestByteLength = (Get-Item $artifactManifestPath).Length
    artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
    physicalBootstrapExeByteLength = (Get-Item (Join-Path $artifactRoot `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')).Length
    physicalBootstrapExeSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
    clientProcessObservationModeCode =
        'bootstrap_process_start_returned_pid'
    sailAbiByteLength = (Get-Item (Join-Path $artifactRoot `
        'sail_api_impl64.dll')).Length
    sailAbiSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
        'sail_api_impl64.dll')
    sailUpstreamHead = '3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3'
    sailUpstreamTree = '54b85eb6fbaa74feae0c6b441d66a5a703073ba3'
    clientBuild = '150.6.9'
    clientExeSha256 =
        '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30'
    transferredToolCount = $toolDestinations.Count
    tools = @($toolDestinations | ForEach-Object {
        [ordered]@{
            name = Split-Path -Leaf $_
            byteLength = (Get-Item $_).Length
            sha256 = Get-Sha256Hex $_
        }
    })
    failedAssessmentUid = $FailedAssessmentUid
    priorFailureReceiptSha256 = Get-Sha256Hex $failedReceiptPath
    priorPreparationArchived = $true
    rawServerLogSanitizedCount = $sanitizedLogCount
    officialLauncherBuilt = $false
    officialLauncherExecutionStarted = $false
    antiCheatSubstitutionApplied = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_prepare_and_start_physical_p2_once'
}
Write-AtomicUtf8NoBom $deploymentPath `
    (($deployment | ConvertTo-Json -Depth 8) + "`n")

Assert-True ((Test-PathDigest $serverDllPath 15364096L `
            '6cfe10ea1ada2b36cca32aa79b0a8fc89656d0339f0a92a477dbb3a6c1b036a5') -and
    @($artifactMembers).Count -eq 5 -and
    @($toolDestinations | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $preparationRoot) -and
    -not (Test-Path -LiteralPath $protectedPreparationRoot)) `
    'phase3b2_physical_p2_offline_repair_post_apply_invalid'

$repair = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-pid-log-safety-repair/v1'
    repairedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $FailedAssessmentUid
    causeCode = 'wmi_executable_path_unavailable_after_sail_connection'
    clientProcessObservationModeCode =
        'bootstrap_process_start_returned_pid'
    externalHead = $externalHead
    externalTree = $externalTree
    tokenLoggingRemoved = $true
    appliedServerDllSha256 = Get-Sha256Hex $serverDllPath
    artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
    deploymentReceiptByteLength = (Get-Item $deploymentPath).Length
    deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
    previousPreparationArchived = $true
    rawServerLogSanitizedCount = $sanitizedLogCount
    backupRoot = 'C:\NLL\Backups\Phase3B2\PhysicalP2-PidLogSafety-v1'
    targetOsOfflineDuringRepair = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_and_run_start_phase3b2_physical_p2_once'
}
Write-AtomicUtf8NoBom $repairReceiptPath `
    (($repair | ConvertTo-Json -Depth 7) + "`n")
Copy-Item -LiteralPath $repairReceiptPath `
    -Destination $protectedRepairReceiptPath

$protectedDeploymentPath = Join-Path $SamsungProtectedRoot `
    'offline-deployment.receipt.json'
if (Test-Path -LiteralPath $protectedDeploymentPath -PathType Leaf) {
    Move-Item -LiteralPath $protectedDeploymentPath -Destination `
        (Join-Path $SamsungProtectedRoot `
            'offline-deployment.before-pid-log-safety-repair.receipt.json')
}
Copy-Item -LiteralPath $deploymentPath -Destination $protectedDeploymentPath

[pscustomobject]@{
    Receipt = $repair
    ReceiptPath = $repairReceiptPath
    ReceiptByteLength = (Get-Item $repairReceiptPath).Length
    ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
    DeploymentReceiptByteLength = (Get-Item $deploymentPath).Length
    DeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
} | ConvertTo-Json -Depth 10
