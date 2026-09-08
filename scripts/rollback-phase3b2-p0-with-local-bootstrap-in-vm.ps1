[CmdletBinding()]
param(
    [switch]$ExtensionOnly,
    [switch]$AutomaticFailureRollback
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$bootstrapRoot = [IO.Path]::GetFullPath("C:\NLL\LocalBootstrap\v1")
$expectedRoot = [IO.Path]::GetFullPath("C:\NLL\LocalBootstrap\v1")
Assert-True ($bootstrapRoot.Equals($expectedRoot,
        [StringComparison]::OrdinalIgnoreCase) -and
    $bootstrapRoot.StartsWith("C:\NLL\LocalBootstrap\",
        [StringComparison]::OrdinalIgnoreCase)) `
    "phase3b2_local_bootstrap_rollback_target_invalid"

$trustedRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$evidenceRoot = Join-Path $trustedRoot "p0-local-bootstrap-v1"
$backupRoot = "C:\NLL\Backups\Phase3B2\P0-local-bootstrap-v1"
$backupManifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
$baseRollback =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
$firewallRuleName = "NLL-P3B2-Block-017"

if (Test-Path -LiteralPath $backupManifestPath -PathType Leaf) {
    $backup = Get-Content -LiteralPath $backupManifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($backup.contractId -ceq
            "nll/phase3b2-local-bootstrap-backup-manifest/v1" -and
        -not [bool]$backup.bootstrapRootPreviouslyPresent -and
        -not [bool]$backup.firewallRulePreviouslyPresent) `
        "phase3b2_local_bootstrap_backup_manifest_invalid"
}
elseif (-not $AutomaticFailureRollback) {
    throw "phase3b2_local_bootstrap_backup_manifest_missing"
}

Get-Process -Name NikkeLocalLab.Phase3B2.LocalBootstrap, nikke, `
    nikke_launcher, EpinelPS -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction Stop
if (Test-Path -LiteralPath $bootstrapRoot) {
    Remove-Item -LiteralPath $bootstrapRoot -Recurse -Force
}
Assert-True (-not (Test-Path -LiteralPath $bootstrapRoot) -and
    @(Get-NetFirewallRule -Name $firewallRuleName `
            -ErrorAction SilentlyContinue).Count -eq 0) `
    "phase3b2_local_bootstrap_extension_rollback_failed"

$baseRollbackCompleted = $false
if (-not $ExtensionOnly) {
    Assert-True (Test-Path -LiteralPath $baseRollback -PathType Leaf) `
        "phase3b2_local_bootstrap_base_rollback_missing"
    & $baseRollback
    $baseRollbackCompleted = $true
}

New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$receipt = [ordered]@{
    contractId = "nll/phase3b2-local-bootstrap-rollback/v1"
    rolledBackAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    extensionOnly = [bool]$ExtensionOnly
    bootstrapArtifactsRemoved = $true
    bootstrapFirewallRuleRemoved = $true
    baseP0RollbackCompleted = $baseRollbackCompleted
    officialLauncherExecutionStarted = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
}
Write-Utf8NoBom (Join-Path $evidenceRoot "rollback.receipt.json") `
    (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
