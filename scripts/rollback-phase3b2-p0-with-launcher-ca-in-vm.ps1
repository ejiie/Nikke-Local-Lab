[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher",
    [string]$BaseBackupRoot = "C:\NLL\Backups\Phase3B2\P0-v1",
    [string]$LauncherBackupRoot = "C:\NLL\Backups\Phase3B2\P0-launcher-ca-v1",
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
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_present_during_composite_rollback"

$launcherBackupManifestPath = Join-Path $LauncherBackupRoot `
    "trusted-launcher-certificate-backup-manifest.json"
$launcherBackupPath = Join-Path $LauncherBackupRoot "launcher-certificate.original.bin"
Assert-True (Test-Path -LiteralPath $launcherBackupManifestPath -PathType Leaf) `
    "phase3b2_launcher_ca_backup_manifest_missing"
$launcherBackupManifest = Get-Content -LiteralPath $launcherBackupManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($launcherBackupManifest.contractId -ceq
        "nll/phase3b2-p0-launcher-certificate-backup-manifest/v1" -and
    [long]$launcherBackupManifest.launcherCertificateOriginalByteLength -eq 209309 -and
    $launcherBackupManifest.launcherCertificateOriginalSha256 -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65" -and
    $launcherBackupManifest.baseBackupManifestSha256 -ceq
        "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a" -and
    $launcherBackupManifest.baseAppliedManifestSha256 -ceq
        "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46") `
    "phase3b2_launcher_ca_backup_manifest_invalid"
Assert-True ((Get-Item -LiteralPath $launcherBackupPath).Length -eq 209309 -and
    (Get-Sha256Hex $launcherBackupPath) -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
    "phase3b2_launcher_ca_backup_invalid"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
)
$launcherCertificates = @(
    $launcherCertificateCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
Assert-True ($launcherCertificates.Count -eq 1) "phase3b2_launcher_ca_rollback_bundle_shape_invalid"
$launcherCertificatePath = $launcherCertificates[0]
[IO.File]::WriteAllBytes($launcherCertificatePath, [IO.File]::ReadAllBytes($launcherBackupPath))
[IO.File]::SetAttributes($launcherCertificatePath,
    [IO.FileAttributes][int]$launcherBackupManifest.launcherCertificateOriginalAttributes)
Assert-True ((Get-Item -LiteralPath $launcherCertificatePath).Length -eq 209309 -and
    (Get-Sha256Hex $launcherCertificatePath) -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
    "phase3b2_launcher_ca_rollback_failed"

$baseRollbackScriptPath = [string]$launcherBackupManifest.baseRollbackScriptPath
Assert-True (Test-Path -LiteralPath $baseRollbackScriptPath -PathType Leaf) `
    "phase3b2_base_rollback_script_missing"
Assert-True ((Get-Sha256Hex $baseRollbackScriptPath) -ceq
    [string]$launcherBackupManifest.baseRollbackScriptSha256) `
    "phase3b2_base_rollback_script_drift"
& $baseRollbackScriptPath -EpinelRoot $EpinelRoot -ClientRoot $ClientRoot `
    -BackupRoot $BaseBackupRoot -AutomaticFailureRollback:$AutomaticFailureRollback
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_base_rollback_failed"

$evidenceRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0-launcher-ca-v1"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-composite-rollback/v2"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    systemHostsRestored = $true
    rootCaRemoved = $true
    gameCertificateBundleRestored = $true
    launcherCertificateBundleRestored = $true
    clientCertificateBundleMemberCount = 2
    nativeCompatibilityShimRestored = $true
    firewallRulesRemoved = $true
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom (Join-Path $evidenceRoot "composite-rollback.receipt.json") `
    (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
