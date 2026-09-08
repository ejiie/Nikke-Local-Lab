[CmdletBinding()]
param(
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2',
    [string]$FailedAssessmentUid =
        '46607d19-048f-4fc3-b2eb-765f1447b7eb'
)

$ErrorActionPreference = 'Stop'
function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_offline_repair_rollback_requires_administrator'
Assert-True ((Get-Partition -DriveLetter C | Get-Disk).FriendlyName -ceq
        'Samsung SSD 980 1TB' -and
    (Get-Partition -DriveLetter $MicronDrive.TrimEnd(':') |
        Get-Disk).FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK') `
    'phase3b2_physical_p2_offline_repair_rollback_disk_boundary_invalid'

$backupRoot = Join-Path $MicronDrive `
    'NLL\Backups\Phase3B2\PhysicalP2-PidLogSafety-v1'
$serverDllPath = Join-Path $MicronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$runtimeRoot = Join-Path $MicronDrive 'NLL\Runtime\PhysicalBootstrap-v1'
$artifactRoot = Join-Path $runtimeRoot 'artifact'
$artifactEvidenceRoot = Join-Path $runtimeRoot 'evidence'
$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v1'
$toolRoot = Join-Path $MicronDrive 'NLL\Tools'
Assert-True (Test-Path -LiteralPath $backupRoot -PathType Container) `
    'phase3b2_physical_p2_offline_repair_rollback_backup_missing'

Copy-Item -LiteralPath (Join-Path $backupRoot 'EpinelPS.dll') `
    -Destination $serverDllPath -Force
Get-ChildItem -LiteralPath (Join-Path $backupRoot 'artifact') -File |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $artifactRoot -Force
    }
Copy-Item -LiteralPath (Join-Path $backupRoot 'artifact.manifest.tsv') `
    -Destination (Join-Path $artifactEvidenceRoot 'artifact.manifest.tsv') -Force
Copy-Item -LiteralPath (Join-Path $backupRoot 'source.manifest.tsv') `
    -Destination (Join-Path $artifactEvidenceRoot 'source.manifest.tsv') -Force
Copy-Item -LiteralPath (Join-Path $backupRoot 'deployment.receipt.json') `
    -Destination (Join-Path $transferRoot 'deployment.receipt.json') -Force
Get-ChildItem -LiteralPath $backupRoot -Filter '*.ps1' -File |
    ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $toolRoot -Force
    }

$preparationRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-preparation-v1'
$preparationArchive = $preparationRoot + ".failed-$FailedAssessmentUid"
$protectedPreparationRoot = Join-Path $SamsungProtectedRoot 'Preparation'
$protectedPreparationArchive = $protectedPreparationRoot +
    ".failed-$FailedAssessmentUid"
if (-not (Test-Path -LiteralPath $preparationRoot) -and
    (Test-Path -LiteralPath $preparationArchive)) {
    Move-Item -LiteralPath $preparationArchive -Destination $preparationRoot
}
if (-not (Test-Path -LiteralPath $protectedPreparationRoot) -and
    (Test-Path -LiteralPath $protectedPreparationArchive)) {
    Move-Item -LiteralPath $protectedPreparationArchive `
        -Destination $protectedPreparationRoot
}

[pscustomobject]@{
    ContractId = 'nll/phase3b2-physical-p2-pid-log-safety-repair-rollback/v1'
    RolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    RuntimeRestored = $true
    PriorPreparationRestored = $true
    RawTokenLogRestored = $false
    TargetOsOfflineDuringRollback = $true
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
} | ConvertTo-Json
