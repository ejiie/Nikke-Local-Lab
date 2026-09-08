#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-Utf8NoBom $temporary `
            (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function New-ExactJunction {
    param([string]$Path, [string]$Target, [string]$FailureCode)
    & $env:ComSpec /d /c mklink /J $Path $Target | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) $FailureCode
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        $item.LinkType -ceq 'Junction' -and
        [string]$item.Target -ceq $Target
    ) ($FailureCode + '_verification_failed')
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_trial_practice_cache_junction_repair_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_trial_practice_cache_junction_repair_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
Assert-True (
    $micronDrive -cne $env:SystemDrive -and
    $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
    $micronDisk.FriendlyName -like 'Micron_2200*'
) 'phase3b2_trial_practice_cache_junction_repair_physical_boundary_invalid'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_trial_practice_cache_junction_repair_runtime_not_cold'

$derivedRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
$cacheJunctionPath = Join-Path $derivedRuntimeRoot 'cache'
$offlineCacheTarget = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$deploymentReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP1D\deployment.receipt.json'
$repairReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP1D\cache-junction-repair.receipt.json'
$dBackupSealPath =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z\metadata\backup.seal.receipt.json'
$protectedRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidTrialPractice-v1\396f1808-173d-482b-9158-dbdf2ae8abfd'
$protectedReceiptPath = Join-Path $protectedRoot `
    'cache-junction-repair.receipt.json'

Assert-True (
    (Test-Digest $deploymentReceiptPath 3369L `
        '51a47dfe74b3147aa2c621cc1ff63b86edd3b1edb4868780e2d986bfc3589584') -and
    (Test-Digest (Join-Path $derivedRuntimeRoot 'db.json') 1396709L `
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019') -and
    (Test-Digest (Join-Path $derivedRuntimeRoot 'EpinelPS.exe') 162304L `
        'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b') -and
    (Test-Digest (Join-Path $derivedRuntimeRoot 'EpinelPS.dll') 15377408L `
        'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef') -and
    (Test-Digest (Join-Path $parentRuntimeRoot 'db.json') 1396709L `
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019') -and
    (Test-Digest (Join-Path $parentRuntimeRoot 'EpinelPS.dll') 15366144L `
        'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b') -and
    (Test-Digest $dBackupSealPath 2177L `
        'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613') -and
    (Test-Path -LiteralPath $offlineCacheTarget -PathType Container) -and
    -not (Test-Path -LiteralPath $repairReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedReceiptPath)
) 'phase3b2_trial_practice_cache_junction_repair_input_missing_or_drifted'

$deploymentReceipt = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deploymentReceipt.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-trial-practice-deployment/v1' -and
    $deploymentReceipt.deploymentUid -ceq
        '396f1808-173d-482b-9158-dbdf2ae8abfd' -and
    -not $deploymentReceipt.parentRuntimeModified -and
    -not $deploymentReceipt.micronLobbyGoldenModified -and
    -not $deploymentReceipt.dLobbyGoldenModified -and
    -not $deploymentReceipt.serverExecutionStarted -and
    -not $deploymentReceipt.clientExecutionStarted
) 'phase3b2_trial_practice_cache_junction_repair_deployment_shape_invalid'

$junctionBefore = Get-Item -LiteralPath $cacheJunctionPath -Force
Assert-True (
    $junctionBefore.LinkType -ceq 'Junction' -and
    [string]$junctionBefore.Target -ceq $offlineCacheTarget -and
    [IO.Path]::GetFullPath($junctionBefore.FullName) -ceq
        [IO.Path]::GetFullPath($cacheJunctionPath)
) 'phase3b2_trial_practice_cache_junction_repair_prior_shape_invalid'

$parentDbBefore = Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')
$parentDllBefore = Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')
$derivedDbBefore = Get-Sha256Hex (Join-Path $derivedRuntimeRoot 'db.json')
$derivedDllBefore = Get-Sha256Hex (Join-Path $derivedRuntimeRoot 'EpinelPS.dll')
$dSealBefore = Get-Sha256Hex $dBackupSealPath
$oldJunctionRemoved = $false
$newJunctionCreated = $false

try {
    Remove-Item -LiteralPath $cacheJunctionPath -Force
    $oldJunctionRemoved = $true
    Assert-True ($null -eq (Get-Item -LiteralPath $cacheJunctionPath -Force `
                -ErrorAction SilentlyContinue)) `
        'phase3b2_trial_practice_cache_junction_repair_remove_failed'

    New-ExactJunction -Path $cacheJunctionPath -Target $bootCacheTarget `
        -FailureCode `
        'phase3b2_trial_practice_cache_junction_repair_create_failed'
    $newJunctionCreated = $true

    Assert-True (
        (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
            $parentDbBefore -and
        (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
            $parentDllBefore -and
        (Get-Sha256Hex (Join-Path $derivedRuntimeRoot 'db.json')) -ceq
            $derivedDbBefore -and
        (Get-Sha256Hex (Join-Path $derivedRuntimeRoot 'EpinelPS.dll')) -ceq
            $derivedDllBefore -and
        (Get-Sha256Hex $dBackupSealPath) -ceq $dSealBefore
    ) 'phase3b2_trial_practice_cache_junction_repair_unexpected_drift'

    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-trial-practice-cache-junction-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = [string]$deploymentReceipt.deploymentUid
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        causeCode = 'offline_drive_letter_embedded_in_cache_junction'
        priorJunctionTarget = $offlineCacheTarget
        repairedJunctionTarget = $bootCacheTarget
        repairedJunctionTargetExistsOnSamsung = $false
        repairedJunctionExpectedToResolveOnMicronBoot = $true
        cacheContentCopied = $false
        cacheContentModified = $false
        derivedRuntimeNonJunctionFileModified = $false
        parentRuntimeModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        deploymentReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        priorFailedStartConsumedValidationRun = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_challenge_validation_once'
    }
    Write-AtomicJson $repairReceiptPath $receipt
    Copy-Item -LiteralPath $repairReceiptPath `
        -Destination $protectedReceiptPath

    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $repairReceiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        ProtectedReceiptPath = $protectedReceiptPath
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ValidationKind Challenge"
    } | ConvertTo-Json -Depth 8
}
catch {
    if ($newJunctionCreated) {
        $current = Get-Item -LiteralPath $cacheJunctionPath -Force `
            -ErrorAction SilentlyContinue
        if ($null -ne $current -and $current.LinkType -ceq 'Junction' -and
            [string]$current.Target -ceq $bootCacheTarget) {
            Remove-Item -LiteralPath $cacheJunctionPath -Force
        }
    }
    if ($oldJunctionRemoved -and
        $null -eq (Get-Item -LiteralPath $cacheJunctionPath -Force `
                -ErrorAction SilentlyContinue)) {
        New-ExactJunction -Path $cacheJunctionPath -Target $offlineCacheTarget `
            -FailureCode `
            'phase3b2_trial_practice_cache_junction_repair_rollback_failed'
    }
    throw
}
