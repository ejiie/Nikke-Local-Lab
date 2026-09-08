[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
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
    @($Paths | Sort-Object | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        $relative = [IO.Path]::GetRelativePath($BasePath, $item.FullName).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length, (Get-Sha256Hex $item.FullName)
    })
}

$systemDisk = Get-Partition -DriveLetter C | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB') `
    'phase3b2_physical_p2_deploy_must_run_from_samsung'
$micronLetter = $MicronDrive.TrimEnd(':')
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_physical_p2_offline_micron_not_verified'

$projectRoot = Join-Path $RepositoryRoot 'tools\Phase3B2\PhysicalBootstrap'
$projectPath = Join-Path $projectRoot `
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.csproj'
$sharedSourcePath = Join-Path $RepositoryRoot `
    'tools\Phase3B2\LocalBootstrap\Program.cs'
$dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
$sourceSailPath = Join-Path $MicronDrive `
    'NLL\Runtime\LocalBootstrap-v1\artifact\sail_api_impl64.dll'
$clientPath = Join-Path $MicronDrive `
    'NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
$runtimeRoot = Join-Path $MicronDrive 'NLL\Runtime\PhysicalBootstrap-v1'
$artifactRoot = Join-Path $runtimeRoot 'artifact'
$evidenceRoot = Join-Path $runtimeRoot 'evidence'
$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v1'
$toolDestinationRoot = Join-Path $MicronDrive 'NLL\Tools'

$toolNames = @(
    'prepare-phase3b2-physical-p2-in-micron.ps1',
    'rollback-phase3b2-physical-bootstrap-extension-in-micron.ps1',
    'start-phase3b2-physical-p2-client-in-micron.ps1',
    'complete-phase3b2-physical-p2-client-in-micron.ps1',
    'Start-Phase3B2-Physical-P2.ps1'
)
$toolSources = @($toolNames | ForEach-Object {
    Join-Path $RepositoryRoot "scripts\$_"
})

foreach ($path in @($projectPath, $sharedSourcePath, $dotnetPath,
        $sourceSailPath, $clientPath) + $toolSources) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_physical_p2_deploy_input_missing'
}
Assert-True ((Get-Item -LiteralPath $clientPath).Length -eq 794152L -and
    (Get-Sha256Hex $clientPath) -ceq
        '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') `
    'phase3b2_physical_p2_client_pin_mismatch'
Assert-True ((Get-Item -LiteralPath $sourceSailPath).Length -eq 18944L -and
    (Get-Sha256Hex $sourceSailPath) -ceq
        '8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d') `
    'phase3b2_physical_p2_sail_pin_mismatch'
Assert-True (-not (Test-Path -LiteralPath $runtimeRoot) -and
    -not (Test-Path -LiteralPath $transferRoot)) `
    'phase3b2_physical_p2_deploy_destination_already_exists'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_runtime_not_cold'

$previousDotnetRoot = $env:DOTNET_ROOT
$previousDotnetHome = $env:DOTNET_CLI_HOME
$previousTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
$publishRoot = Join-Path $projectRoot 'bin\Release\net10.0\win-x64\publish'
try {
    $env:DOTNET_ROOT = Join-Path $MicronDrive 'Program Files\dotnet'
    $env:DOTNET_CLI_HOME = Join-Path $env:TEMP `
        'nll-phase3b2-physical-p2-dotnet-home'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    Push-Location $projectRoot
    try {
        $sdkVersion = (& $dotnetPath --version | Out-String).Trim()
        Assert-True ($sdkVersion -ceq '10.0.400') `
            'phase3b2_physical_p2_sdk_pin_mismatch'
        & $dotnetPath restore $projectPath --locked-mode `
            --ignore-failed-sources --nologo
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_physical_p2_restore_failed'
        & $dotnetPath publish $projectPath -c Release --no-restore --nologo
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_physical_p2_publish_failed'
    }
    finally { Pop-Location }
}
finally {
    $env:DOTNET_ROOT = $previousDotnetRoot
    $env:DOTNET_CLI_HOME = $previousDotnetHome
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = $previousTelemetry
}

$artifactNames = @(
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.deps.json',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe',
    'NikkeLocalLab.Phase3B2.PhysicalBootstrap.runtimeconfig.json'
)
$publishMembers = @($artifactNames | ForEach-Object {
    Join-Path $publishRoot $_
})
Assert-True (@($publishMembers | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_physical_p2_publish_shape_invalid'

New-Item -ItemType Directory -Path $artifactRoot, $evidenceRoot,
    $transferRoot, $toolDestinationRoot, $SamsungProtectedRoot -Force | Out-Null
foreach ($path in $publishMembers) {
    Copy-Item -LiteralPath $path -Destination $artifactRoot
}
Copy-Item -LiteralPath $sourceSailPath -Destination $artifactRoot

$sourceMembers = @(
    $sharedSourcePath,
    $projectPath,
    (Join-Path $projectRoot 'global.json'),
    (Join-Path $projectRoot 'packages.lock.json')
)
$sourceManifestPath = Join-Path $evidenceRoot 'source.manifest.tsv'
$sourceManifestText = (Get-ManifestLines $sourceMembers $RepositoryRoot) -join "`n"
Write-AtomicUtf8NoBom $sourceManifestPath ($sourceManifestText + "`n")

$artifactMembers = @(Get-ChildItem -LiteralPath $artifactRoot -File |
    Select-Object -ExpandProperty FullName)
$artifactManifestPath = Join-Path $evidenceRoot 'artifact.manifest.tsv'
$artifactManifestText = (Get-ManifestLines $artifactMembers $artifactRoot) -join "`n"
Write-AtomicUtf8NoBom $artifactManifestPath ($artifactManifestText + "`n")

foreach ($path in $toolSources) {
    $destination = Join-Path $toolDestinationRoot (Split-Path -Leaf $path)
    Assert-True (-not (Test-Path -LiteralPath $destination)) `
        'phase3b2_physical_p2_tool_destination_already_exists'
    Copy-Item -LiteralPath $path -Destination $destination
}
$toolDestinations = @($toolNames | ForEach-Object {
    Join-Path $toolDestinationRoot $_
})

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-offline-deployment/v1'
    deployedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    preparationBootDisk = 'Samsung SSD 980 1TB'
    targetDisk = 'Micron_2200_MTFDHBA512TCK'
    targetOsOfflineDuringDeployment = $true
    runtimePathAtTargetBoot = 'C:\NLL\Runtime\PhysicalBootstrap-v1'
    clientPathAtTargetBoot =
        'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
    dotnetSdkVersion = $sdkVersion
    sourceMemberCount = $sourceMembers.Count
    sourceManifestByteLength = (Get-Item $sourceManifestPath).Length
    sourceManifestSha256 = Get-Sha256Hex $sourceManifestPath
    artifactMemberCount = $artifactMembers.Count
    artifactManifestByteLength = (Get-Item $artifactManifestPath).Length
    artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
    physicalBootstrapExeByteLength =
        (Get-Item (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')).Length
    physicalBootstrapExeSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
    sailAbiByteLength = (Get-Item (Join-Path $artifactRoot `
            'sail_api_impl64.dll')).Length
    sailAbiSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
        'sail_api_impl64.dll')
    sailUpstreamHead = '3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3'
    sailUpstreamTree = '54b85eb6fbaa74feae0c6b441d66a5a703073ba3'
    clientBuild = '150.6.9'
    clientExeSha256 = Get-Sha256Hex $clientPath
    transferredToolCount = $toolDestinations.Count
    tools = @($toolDestinations | ForEach-Object {
        [ordered]@{
            name = Split-Path -Leaf $_
            byteLength = (Get-Item $_).Length
            sha256 = Get-Sha256Hex $_
        }
    })
    officialLauncherBuilt = $false
    officialLauncherExecutionStarted = $false
    antiCheatSubstitutionApplied = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_and_start_physical_p2_once'
}
$receiptPath = Join-Path $transferRoot 'deployment.receipt.json'
Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + "`n")
$protectedReceiptPath = Join-Path $SamsungProtectedRoot `
    'offline-deployment.receipt.json'
Copy-Item -LiteralPath $receiptPath -Destination $protectedReceiptPath
Assert-True ((Get-Sha256Hex $protectedReceiptPath) -ceq
    (Get-Sha256Hex $receiptPath)) `
    'phase3b2_physical_p2_protected_receipt_copy_failed'

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $receiptPath
    MicronReceiptByteLength = (Get-Item $receiptPath).Length
    MicronReceiptSha256 = Get-Sha256Hex $receiptPath
    SamsungProtectedReceiptPath = $protectedReceiptPath
} | ConvertTo-Json -Depth 10
