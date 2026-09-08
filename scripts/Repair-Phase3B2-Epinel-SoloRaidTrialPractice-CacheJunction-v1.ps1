#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-ExecutionPolicy -Scope Process Bypass -Force

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
            (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
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
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_trial_practice_cache_junction_repair_wrong_micron_boundary'
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_trial_practice_cache_junction_repair_runtime_not_cold'

$runtimeRoot = 'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
$cacheJunctionPath = Join-Path $runtimeRoot 'cache'
$priorOfflineTarget =
    'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$deploymentReceiptPath = 'C:\NLL\E\P3SRTP1D\deployment.receipt.json'
$repairReceiptPath =
    'C:\NLL\E\P3SRTP1D\cache-junction-repair.receipt.json'
$activePointerPath = 'C:\NLL\E\P3SRTP1\active-run.pointer.json'
$headerPath = Join-Path $bootCacheTarget `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'

Assert-True (
    (Test-Digest $deploymentReceiptPath 3369L `
        '51a47dfe74b3147aa2c621cc1ff63b86edd3b1edb4868780e2d986bfc3589584') -and
    (Test-Digest (Join-Path $runtimeRoot 'db.json') 1396709L `
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019') -and
    (Test-Digest (Join-Path $runtimeRoot 'EpinelPS.exe') 162304L `
        'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b') -and
    (Test-Digest (Join-Path $runtimeRoot 'EpinelPS.dll') 15377408L `
        'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef') -and
    (Test-Digest $headerPath 139L `
        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') -and
    -not (Test-Path -LiteralPath $repairReceiptPath) -and
    -not (Test-Path -LiteralPath $activePointerPath)
) 'phase3b2_trial_practice_cache_junction_repair_input_missing_or_drifted'

$deploymentReceipt = Get-Content -LiteralPath $deploymentReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deploymentReceipt.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-trial-practice-deployment/v1' -and
    $deploymentReceipt.deploymentUid -ceq
        '396f1808-173d-482b-9158-dbdf2ae8abfd' -and
    -not $deploymentReceipt.serverExecutionStarted -and
    -not $deploymentReceipt.clientExecutionStarted -and
    [int]$deploymentReceipt.maximumValidationRunCount -eq 2
) 'phase3b2_trial_practice_cache_junction_repair_deployment_shape_invalid'

$junctionBefore = Get-Item -LiteralPath $cacheJunctionPath -Force
Assert-True (
    $junctionBefore.LinkType -ceq 'Junction' -and
    [string]$junctionBefore.Target -ceq $priorOfflineTarget -and
    [IO.Path]::GetFullPath($junctionBefore.FullName) -ceq
        [IO.Path]::GetFullPath($cacheJunctionPath)
) 'phase3b2_trial_practice_cache_junction_repair_prior_shape_invalid'

$dbBefore = Get-Sha256Hex (Join-Path $runtimeRoot 'db.json')
$dllBefore = Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.dll')
$headerBefore = Get-Sha256Hex $headerPath
$priorRemoved = $false
$repairCreated = $false

try {
    Remove-Item -LiteralPath $cacheJunctionPath -Force
    $priorRemoved = $true
    Assert-True ($null -eq (Get-Item -LiteralPath $cacheJunctionPath -Force `
                -ErrorAction SilentlyContinue)) `
        'phase3b2_trial_practice_cache_junction_repair_remove_failed'

    New-ExactJunction -Path $cacheJunctionPath -Target $bootCacheTarget `
        -FailureCode `
        'phase3b2_trial_practice_cache_junction_repair_create_failed'
    $repairCreated = $true

    Assert-True (
        (Get-Sha256Hex (Join-Path $runtimeRoot 'db.json')) -ceq $dbBefore -and
        (Get-Sha256Hex (Join-Path $runtimeRoot 'EpinelPS.dll')) -ceq
            $dllBefore -and
        (Get-Sha256Hex (Join-Path $cacheJunctionPath `
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt')) `
            -ceq $headerBefore
    ) 'phase3b2_trial_practice_cache_junction_repair_unexpected_drift'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-trial-practice-cache-junction-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = [string]$deploymentReceipt.deploymentUid
        deploymentReceiptSha256 = Get-Sha256Hex $deploymentReceiptPath
        causeCode = 'offline_drive_letter_embedded_in_cache_junction'
        priorJunctionTarget = $priorOfflineTarget
        repairedJunctionTarget = $bootCacheTarget
        repairedJunctionResolved = $true
        cacheContentCopied = $false
        cacheContentModified = $false
        databaseModified = $false
        serverBinaryModified = $false
        goldenRuntimeModified = $false
        dBackupModified = $false
        deploymentReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        priorFailedStartConsumedValidationRun = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode = 'run_challenge_validation_once'
    }
    Write-AtomicJson $repairReceiptPath $receipt

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $repairReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $repairReceiptPath
        StartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ValidationKind Challenge"
    } | ConvertTo-Json -Depth 8
}
catch {
    if ($repairCreated) {
        $current = Get-Item -LiteralPath $cacheJunctionPath -Force `
            -ErrorAction SilentlyContinue
        if ($null -ne $current -and $current.LinkType -ceq 'Junction' -and
            [string]$current.Target -ceq $bootCacheTarget) {
            Remove-Item -LiteralPath $cacheJunctionPath -Force
        }
    }
    if ($priorRemoved -and
        $null -eq (Get-Item -LiteralPath $cacheJunctionPath -Force `
                -ErrorAction SilentlyContinue)) {
        New-ExactJunction -Path $cacheJunctionPath -Target $priorOfflineTarget `
            -FailureCode `
            'phase3b2_trial_practice_cache_junction_repair_rollback_failed'
    }
    throw
}
