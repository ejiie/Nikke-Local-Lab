[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\V2Deployment'
)

$ErrorActionPreference = 'Stop'

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

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_v2_server_rollback_requires_administrator'
$systemDisk = Get-Partition -DriveLetter C | Get-Disk
$micronLetter = $MicronDrive.TrimEnd(':')
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $systemDisk.IsBoot -and $systemDisk.IsSystem -and
    $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_physical_p2_v2_server_rollback_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_v2_server_rollback_runtime_not_cold'

$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
$deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
$backupPath = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-v2-Server\EpinelPS.dll'
$serverPath = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$receiptPath = Join-Path $transferRoot 'server-rollback.receipt.json'
Assert-True ((Test-Path -LiteralPath $deploymentPath -PathType Leaf) -and
    (Test-Path -LiteralPath $backupPath -PathType Leaf) -and
    (Test-Path -LiteralPath $serverPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $receiptPath)) `
    'phase3b2_physical_p2_v2_server_rollback_evidence_invalid'
$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($deployment.contractId -ceq
        'nll/phase3b2-physical-p2-v2-offline-deployment/v1' -and
    (Get-Sha256Hex $serverPath) -ceq
        [string]$deployment.appliedServerDllSha256 -and
    (Get-Sha256Hex $backupPath) -ceq
        [string]$deployment.previousServerDllSha256) `
    'phase3b2_physical_p2_v2_server_rollback_pin_mismatch'

Copy-Item -LiteralPath $backupPath -Destination $serverPath -Force
Assert-True ((Get-Sha256Hex $serverPath) -ceq
    [string]$deployment.previousServerDllSha256) `
    'phase3b2_physical_p2_v2_server_rollback_restore_failed'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-v2-server-offline-rollback/v1'
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    executionBootDisk = 'Samsung SSD 980 1TB'
    targetDisk = 'Micron_2200_MTFDHBA512TCK'
    targetOsOfflineDuringRollback = $true
    restoredServerDllByteLength = (Get-Item $serverPath).Length
    restoredServerDllSha256 = Get-Sha256Hex $serverPath
    existingOperatorLocalLowReadPerformed = $false
    existingOperatorNikkeCacheMutationPerformed = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 6) + "`n")
Copy-Item -LiteralPath $receiptPath -Destination (Join-Path `
    $SamsungProtectedRoot 'server-rollback.receipt.json')
$receipt | ConvertTo-Json -Depth 7

