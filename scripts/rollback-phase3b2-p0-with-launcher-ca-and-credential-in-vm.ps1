[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher",
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

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) `
    "phase3b2_full_composite_rollback_runtime_not_cold"

$credentialRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-synthetic-launcher-credential-in-vm.ps1"
$baseCompositeRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-in-vm.ps1"
Assert-True (Test-Path -LiteralPath $credentialRollbackPath -PathType Leaf) `
    "phase3b2_full_composite_credential_rollback_missing"
Assert-True (Test-Path -LiteralPath $baseCompositeRollbackPath -PathType Leaf) `
    "phase3b2_full_composite_base_rollback_missing"
Assert-True ((Get-Sha256Hex $baseCompositeRollbackPath) -ceq
        "83df6aac274fe78960032eead2d1f2da418d0d2969ee57d430132c0c5b248586") `
    "phase3b2_full_composite_base_rollback_drift"

& $credentialRollbackPath -EpinelRoot $EpinelRoot
& $baseCompositeRollbackPath -EpinelRoot $EpinelRoot -ClientRoot $ClientRoot `
    -LauncherRoot $LauncherRoot `
    -AutomaticFailureRollback:$AutomaticFailureRollback

$credentialReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\launcher-credential-v1\rollback.receipt.json"
$baseReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0-launcher-ca-v1\composite-rollback.receipt.json"
$credentialReceipt = Get-Content -LiteralPath $credentialReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$baseReceipt = Get-Content -LiteralPath $baseReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($credentialReceipt.contractId -ceq
        "nll/phase3b2-synthetic-launcher-credential-rollback/v1" -and
    [int]$credentialReceipt.restoredMemberCount -eq 6 -and
    [bool]$credentialReceipt.databaseRestored -and
    [bool]$credentialReceipt.syntheticContextRestored -and
    [bool]$credentialReceipt.syntheticProfileReceiptRestored -and
    [bool]$credentialReceipt.sqliteStateRestored -and
    $baseReceipt.contractId -ceq "nll/phase3b2-p0-composite-rollback/v2" -and
    [bool]$baseReceipt.systemHostsRestored -and [bool]$baseReceipt.rootCaRemoved -and
    [bool]$baseReceipt.gameCertificateBundleRestored -and
    [bool]$baseReceipt.launcherCertificateBundleRestored -and
    [bool]$baseReceipt.nativeCompatibilityShimRestored -and
    [bool]$baseReceipt.firewallRulesRemoved) `
    "phase3b2_full_composite_rollback_receipt_invalid"

$receiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\launcher-credential-v1\full-composite-rollback.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_full_composite_rollback_receipt_exists"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-full-composite-rollback/v1"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    syntheticCredentialMemberCount = 3
    sqliteStateMemberCount = 3
    systemHostsRestored = $true
    rootCaRemoved = $true
    gameCertificateBundleRestored = $true
    launcherCertificateBundleRestored = $true
    nativeCompatibilityShimRestored = $true
    firewallRulesRemoved = $true
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
