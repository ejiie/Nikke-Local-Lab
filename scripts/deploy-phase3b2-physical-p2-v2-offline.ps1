[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$EpinelRepositoryRoot =
        'C:\Users\zih44\Documents\Github\EpinelPS',
    [string]$MicronDrive = 'E:',
    [string]$GitPath = '',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\V2Deployment'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$runtimeCreated = $false
$transferCreated = $false
$backupCreated = $false
$serverReplaced = $false
$protectedCreated = $false
$copiedToolPaths = [Collections.Generic.List[string]]::new()
$testResultsRoot = $null

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
            throw 'phase3b2_physical_p2_v2_manifest_member_outside_base'
        }
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
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
    & $DotnetPath test $ProjectPath -c Release --nologo --no-restore `
        --verbosity quiet --results-directory $ResultsRoot `
        --logger "trx;LogFileName=$trxName"
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_physical_p2_v2_${RoleCode}_test_failed"
    $trxPath = Join-Path $ResultsRoot $trxName
    Assert-True (Test-Path -LiteralPath $trxPath -PathType Leaf) `
        "phase3b2_physical_p2_v2_${RoleCode}_trx_missing"
    [xml]$trx = Get-Content -LiteralPath $trxPath -Raw -Encoding UTF8
    $counters = $trx.TestRun.ResultSummary.Counters
    Assert-True ($null -ne $counters -and
        [int]$counters.failed -eq 0 -and
        [int]$counters.passed -eq $ExpectedPassedCount -and
        [int]$counters.total -eq $ExpectedPassedCount) `
        "phase3b2_physical_p2_v2_${RoleCode}_test_count_invalid"
    [ordered]@{
        roleCode = $RoleCode
        passedCount = [int]$counters.passed
        failedCount = [int]$counters.failed
        trxPath = $trxPath
        trxByteLength = (Get-Item -LiteralPath $trxPath).Length
        trxSha256 = Get-Sha256Hex $trxPath
    }
}

try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p2_v2_deploy_requires_administrator'
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronLetter = $MicronDrive.TrimEnd(':')
    $micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
    Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        $systemDisk.IsBoot -and $systemDisk.IsSystem -and
        $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
        'phase3b2_physical_p2_v2_offline_disk_boundary_invalid'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_v2_runtime_not_cold'

    if (-not $GitPath) {
        $gitCandidates = @(
            (Join-Path $MicronDrive 'Program Files\Git\cmd\git.exe'),
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
        )
        $resolvedGit = @($gitCandidates | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } | Select-Object -First 1)
        if ($resolvedGit.Count -eq 1) {
            $GitPath = [string]$resolvedGit[0]
        }
        else { $GitPath = '' }
    }
    Assert-True ($GitPath -and
        (Test-Path -LiteralPath $GitPath -PathType Leaf)) `
        'phase3b2_physical_p2_v2_git_executable_missing'
    $externalHead = (& $GitPath -c safe.directory=$EpinelRepositoryRoot `
        -C $EpinelRepositoryRoot rev-parse HEAD | Out-String).Trim()
    $externalTree = (& $GitPath -c safe.directory=$EpinelRepositoryRoot `
        -C $EpinelRepositoryRoot rev-parse 'HEAD^{tree}' | Out-String).Trim()
    $externalBranch = (& $GitPath -c safe.directory=$EpinelRepositoryRoot `
        -C $EpinelRepositoryRoot rev-parse --abbrev-ref HEAD | Out-String).Trim()
    $externalStatus = (& $GitPath -c safe.directory=$EpinelRepositoryRoot `
        -C $EpinelRepositoryRoot status --porcelain=v1 `
        --untracked-files=all | Out-String).Trim()
    Assert-True ($externalHead -ceq
            'ee406f46cdb2c2d7facc28a592b48c0e2739e1d7' -and
        $externalTree -ceq
            'bea0d6af46617c5294289fa17cc85b0ecc23e305' -and
        $externalBranch -ceq 'agent/phase3b2-p2-log-safety' -and
        $externalStatus.Length -eq 0) `
        'phase3b2_physical_p2_v2_external_source_invalid'

    $serverInfoPath = Join-Path $EpinelRepositoryRoot `
        'EpinelPS\LobbyServer\Misc\GetServerInfo.cs'
    $serverInfoText = Get-Content -LiteralPath $serverInfoPath -Raw `
        -Encoding UTF8
    Assert-True ($serverInfoText -cmatch
        'MatchUrl\s*=\s*"https://global-match\.nikke-kr\.com"') `
        'phase3b2_physical_p2_v2_endpoint_source_missing'

    $dotnetPath = Join-Path $MicronDrive 'Program Files\dotnet\dotnet.exe'
    $serverProjectPath = Join-Path $EpinelRepositoryRoot `
        'EpinelPS\EpinelPS.csproj'
    $handlerTestPath = Join-Path $EpinelRepositoryRoot `
        'tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj'
    $selectedTestPath = Join-Path $EpinelRepositoryRoot `
        'tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj'
    $bootstrapProjectRoot = Join-Path $RepositoryRoot `
        'tools\Phase3B2\PhysicalBootstrap'
    $bootstrapProjectPath = Join-Path $bootstrapProjectRoot `
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.csproj'
    $bootstrapSharedSourcePath = Join-Path $RepositoryRoot `
        'tools\Phase3B2\LocalBootstrap\Program.cs'
    $bootstrapPublishRoot = Join-Path $bootstrapProjectRoot `
        'bin\Release\net10.0\win-x64\publish'
    $sourceSailPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v1\artifact\sail_api_impl64.dll'
    $clientPath = Join-Path $MicronDrive `
        'NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
    $serverDllPath = Join-Path $MicronDrive `
        'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
    $newServerDllPath = Join-Path $EpinelRepositoryRoot `
        'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
    $runtimeRoot = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2'
    $artifactRoot = Join-Path $runtimeRoot 'artifact'
    $runtimeEvidenceRoot = Join-Path $runtimeRoot 'evidence'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $backupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2-Server'
    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $toolNames = @(
        'New-Phase3B2-Micron-Operator.ps1',
        'Test-Phase3B2-Micron-Operator-Profile.ps1',
        'prepare-phase3b2-physical-p2-v2-in-micron.ps1',
        'start-phase3b2-physical-p2-v2-client-in-micron.ps1',
        'complete-phase3b2-physical-p2-v2-client-in-micron.ps1',
        'rollback-phase3b2-physical-p2-v2-in-micron.ps1',
        'Start-Phase3B2-Physical-P2-V2.ps1'
    )
    $toolSources = @($toolNames | ForEach-Object {
        Join-Path $RepositoryRoot "scripts\$_"
    })
    foreach ($path in @($dotnetPath, $serverProjectPath, $handlerTestPath,
            $selectedTestPath, $bootstrapProjectPath,
            $bootstrapSharedSourcePath, $sourceSailPath,
            $clientPath, $serverDllPath, $serverInfoPath) + $toolSources) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase3b2_physical_p2_v2_deploy_input_missing'
    }
    Assert-True ((Test-PathDigest $clientPath 794152L `
            '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') -and
        (Test-PathDigest $sourceSailPath 18944L `
            '8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d') -and
        (Test-PathDigest $serverDllPath 15364096L `
            '6cfe10ea1ada2b36cca32aa79b0a8fc89656d0339f0a92a477dbb3a6c1b036a5')) `
        'phase3b2_physical_p2_v2_runtime_pin_invalid'
    Assert-True (-not (Test-Path -LiteralPath $runtimeRoot) -and
        -not (Test-Path -LiteralPath $transferRoot) -and
        -not (Test-Path -LiteralPath $backupRoot) -and
        -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
        'phase3b2_physical_p2_v2_deploy_destination_already_exists'
    foreach ($toolName in $toolNames) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $toolRoot $toolName))) `
            'phase3b2_physical_p2_v2_tool_destination_already_exists'
    }

    $testResultsRoot = Join-Path $env:TEMP `
        ('nll-phase3b2-p2v2-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testResultsRoot -Force | Out-Null
    $oldRoot = $env:DOTNET_ROOT
    $oldHome = $env:DOTNET_CLI_HOME
    $oldTelemetry = $env:DOTNET_CLI_TELEMETRY_OPTOUT
    try {
        $env:DOTNET_ROOT = Join-Path $MicronDrive 'Program Files\dotnet'
        $env:DOTNET_CLI_HOME = Join-Path $env:TEMP `
            'nll-phase3b2-p2v2-deploy-dotnet-home'
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
        $sdkVersion = (& $dotnetPath --version | Out-String).Trim()
        Assert-True ($sdkVersion -ceq '10.0.400') `
            'phase3b2_physical_p2_v2_sdk_pin_mismatch'
        Push-Location $EpinelRepositoryRoot
        try {
            $handlerResult = Invoke-PinnedTest $dotnetPath $handlerTestPath `
                $testResultsRoot 'handler_isolation' 14
            $selectedResult = Invoke-PinnedTest $dotnetPath $selectedTestPath `
                $testResultsRoot 'selected_manager' 64
        }
        finally { Pop-Location }
        Push-Location $bootstrapProjectRoot
        try {
            & $dotnetPath publish $bootstrapProjectPath -c Release `
                --no-restore --nologo
            Assert-True ($LASTEXITCODE -eq 0) `
                'phase3b2_physical_p2_v2_bootstrap_publish_failed'
        }
        finally { Pop-Location }
    }
    finally {
        $env:DOTNET_ROOT = $oldRoot
        $env:DOTNET_CLI_HOME = $oldHome
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = $oldTelemetry
    }

    Assert-True (Test-Path -LiteralPath $newServerDllPath -PathType Leaf) `
        'phase3b2_physical_p2_v2_server_build_missing'
    $artifactNames = @(
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.deps.json',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.dll',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe',
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap.runtimeconfig.json'
    )
    $publishMembers = @($artifactNames | ForEach-Object {
        Join-Path $bootstrapPublishRoot $_
    })
    Assert-True (@($publishMembers | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_physical_p2_v2_publish_shape_invalid'

    New-Item -ItemType Directory -Path $runtimeRoot, $artifactRoot,
        $runtimeEvidenceRoot -Force | Out-Null
    $runtimeCreated = $true
    New-Item -ItemType Directory -Path $transferRoot -Force | Out-Null
    $transferCreated = $true
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupCreated = $true
    New-Item -ItemType Directory -Path $SamsungProtectedRoot -Force | Out-Null
    $protectedCreated = $true

    $serverBackupPath = Join-Path $backupRoot 'EpinelPS.dll'
    Copy-Item -LiteralPath $serverDllPath -Destination $serverBackupPath
    Assert-True (Test-PathDigest $serverBackupPath 15364096L `
        '6cfe10ea1ada2b36cca32aa79b0a8fc89656d0339f0a92a477dbb3a6c1b036a5') `
        'phase3b2_physical_p2_v2_server_backup_failed'
    Copy-Item -LiteralPath $newServerDllPath -Destination $serverDllPath -Force
    $serverReplaced = $true

    foreach ($path in $publishMembers) {
        Copy-Item -LiteralPath $path -Destination $artifactRoot
    }
    Copy-Item -LiteralPath $sourceSailPath -Destination $artifactRoot
    foreach ($path in $toolSources) {
        $destination = Join-Path $toolRoot (Split-Path -Leaf $path)
        Copy-Item -LiteralPath $path -Destination $destination
        $copiedToolPaths.Add($destination)
    }
    Copy-Item -LiteralPath $handlerResult.trxPath, $selectedResult.trxPath `
        -Destination $runtimeEvidenceRoot

    $artifactMembers = @(Get-ChildItem -LiteralPath $artifactRoot -File |
        Select-Object -ExpandProperty FullName)
    $artifactManifestPath = Join-Path $runtimeEvidenceRoot `
        'artifact.manifest.tsv'
    $artifactManifestText =
        (Get-ManifestLines $artifactMembers $artifactRoot) -join "`n"
    Write-AtomicUtf8NoBom $artifactManifestPath ($artifactManifestText + "`n")
    $toolDestinations = @($copiedToolPaths)
    $toolManifestPath = Join-Path $runtimeEvidenceRoot 'tools.manifest.tsv'
    $toolManifestText =
        (Get-ManifestLines $toolDestinations $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $toolManifestPath ($toolManifestText + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-offline-deployment/v1'
        deployedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        preparationBootDisk = 'Samsung SSD 980 1TB'
        targetDisk = 'Micron_2200_MTFDHBA512TCK'
        targetOsOfflineDuringDeployment = $true
        externalHead = $externalHead
        externalTree = $externalTree
        externalCheckoutClean = $true
        dotnetSdkVersion = $sdkVersion
        selectedManagerPassedCount = $selectedResult.passedCount
        handlerIsolationPassedCount = $handlerResult.passedCount
        requestStageObservationEnabled = $true
        requestStageRawUrlLoggingEnabled = $false
        requestStagePayloadLoggingEnabled = $false
        requestStageAccountIdentityLoggingEnabled = $false
        endpointAdmissionCode =
            'global_match_returned_by_local_get_server_info'
        admittedEndpointCount = 1
        admittedEndpoint = 'global-match.nikke-kr.com'
        endpointSourceByteLength = (Get-Item $serverInfoPath).Length
        endpointSourceSha256 = Get-Sha256Hex $serverInfoPath
        bootstrapSharedSourceByteLength =
            (Get-Item $bootstrapSharedSourcePath).Length
        bootstrapSharedSourceSha256 = Get-Sha256Hex $bootstrapSharedSourcePath
        physicalEvidenceLaneCode = 'p2-client-start-v2'
        previousServerDllByteLength = (Get-Item $serverBackupPath).Length
        previousServerDllSha256 = Get-Sha256Hex $serverBackupPath
        appliedServerDllByteLength = (Get-Item $serverDllPath).Length
        appliedServerDllSha256 = Get-Sha256Hex $serverDllPath
        artifactMemberCount = $artifactMembers.Count
        artifactManifestByteLength = (Get-Item $artifactManifestPath).Length
        artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
        physicalBootstrapExeByteLength =
            (Get-Item (Join-Path $artifactRoot `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')).Length
        physicalBootstrapExeSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
        sailAbiByteLength =
            (Get-Item (Join-Path $artifactRoot 'sail_api_impl64.dll')).Length
        sailAbiSha256 = Get-Sha256Hex (Join-Path $artifactRoot `
            'sail_api_impl64.dll')
        clientBuild = '150.6.9'
        clientExeSha256 = Get-Sha256Hex $clientPath
        transferredToolCount = $toolDestinations.Count
        toolManifestByteLength = (Get-Item $toolManifestPath).Length
        toolManifestSha256 = Get-Sha256Hex $toolManifestPath
        tools = @($toolDestinations | ForEach-Object {
            [ordered]@{
                name = Split-Path -Leaf $_
                byteLength = (Get-Item $_).Length
                sha256 = Get-Sha256Hex $_
            }
        })
        dedicatedOperatorCreationDeferredToMicronBoot = $true
        existingOperatorLocalLowReadPerformed = $false
        existingOperatorNikkeCacheMutationPerformed = $false
        minimumMeasurementSeconds = 600
        dnsObservationEnabled = $true
        wfpObservationEnabled = $true
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        officialLauncherExecutionStarted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode =
            'boot_micron_create_nlloperator_sign_in_and_run_p2_v2_once'
    }
    $receiptPath = Join-Path $transferRoot 'deployment.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath `
        (($receipt | ConvertTo-Json -Depth 9) + "`n")
    $protectedReceiptPath = Join-Path $SamsungProtectedRoot `
        'offline-deployment.receipt.json'
    Copy-Item -LiteralPath $receiptPath -Destination $protectedReceiptPath
    Assert-True ((Get-Sha256Hex $protectedReceiptPath) -ceq
        (Get-Sha256Hex $receiptPath)) `
        'phase3b2_physical_p2_v2_protected_receipt_copy_failed'

    if (Test-Path -LiteralPath $testResultsRoot) {
        Remove-Item -LiteralPath $testResultsRoot -Recurse -Force
    }

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        SamsungProtectedReceiptPath = $protectedReceiptPath
    } | ConvertTo-Json -Depth 11
}
catch {
    $serverRestored = $false
    if ($serverReplaced -and $backupCreated) {
        $serverBackupPath = Join-Path $backupRoot 'EpinelPS.dll'
        if (Test-Path -LiteralPath $serverBackupPath -PathType Leaf) {
            Copy-Item -LiteralPath $serverBackupPath `
                -Destination $serverDllPath -Force -ErrorAction SilentlyContinue
            $serverRestored = (Test-Path -LiteralPath $serverDllPath `
                    -PathType Leaf) -and
                (Get-Sha256Hex $serverDllPath) -ceq
                    (Get-Sha256Hex $serverBackupPath)
        }
    }
    foreach ($path in @($copiedToolPaths)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    if ($runtimeCreated -and (Test-Path -LiteralPath $runtimeRoot)) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if ($transferCreated -and (Test-Path -LiteralPath $transferRoot)) {
        Remove-Item -LiteralPath $transferRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if ($protectedCreated -and
        (Test-Path -LiteralPath $SamsungProtectedRoot)) {
        Remove-Item -LiteralPath $SamsungProtectedRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if ($backupCreated -and $serverRestored -and
        (Test-Path -LiteralPath $backupRoot)) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    if ($testResultsRoot -and
        (Test-Path -LiteralPath $testResultsRoot)) {
        Remove-Item -LiteralPath $testResultsRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    throw
}
