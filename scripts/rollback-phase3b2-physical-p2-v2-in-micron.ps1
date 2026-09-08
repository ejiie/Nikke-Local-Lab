[CmdletBinding()]
param(
    [string]$BackupRoot =
        'C:\NLL\Backups\Phase3B2\PhysicalP2-v2'
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

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p2_v2_rollback_requires_administrator'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p2_v2_rollback_runtime_not_cold'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath = Join-Path $BackupRoot 'hosts.before.bin'
Assert-True ((Test-Path -LiteralPath $hostsBackupPath -PathType Leaf) -and
    (Get-Item $hostsBackupPath).Length -eq 1690L -and
    (Get-Sha256Hex $hostsBackupPath) -ceq
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
    'phase3b2_physical_p2_v2_rollback_backup_invalid'
Get-NetFirewallRule -Group 'NLL Phase3B2 Physical P2 V2 Extension' `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule `
    -ErrorAction SilentlyContinue
[IO.File]::WriteAllBytes($hostsPath,
    [IO.File]::ReadAllBytes($hostsBackupPath))
Assert-True (@(Get-NetFirewallRule `
        -Group 'NLL Phase3B2 Physical P2 V2 Extension' `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    (Get-Sha256Hex $hostsPath) -ceq
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
    'phase3b2_physical_p2_v2_rollback_failed'
[pscustomobject]@{
    ContractId = 'nll/phase3b2-physical-p2-v2-rollback/v1'
    HostsRestored = $true
    ExtensionFirewallRemoved = $true
    ExistingOperatorNikkeCacheMutationPerformed = $false
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
} | ConvertTo-Json

