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

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) `
    "phase3b2_sqlite_full_rollback_runtime_not_cold"

$sqliteRollback = "C:\NLL\Tools\rollback-phase3b2-sqlite-credential-reset-in-vm.ps1"
$priorFullRollback =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-and-credential-in-vm.ps1"
Assert-True (Test-Path -LiteralPath $sqliteRollback -PathType Leaf) `
    "phase3b2_sqlite_full_rollback_sqlite_tool_missing"
Assert-True (Test-Path -LiteralPath $priorFullRollback -PathType Leaf) `
    "phase3b2_sqlite_full_rollback_prior_tool_missing"

& $sqliteRollback -EpinelRoot $EpinelRoot | Out-Null
& $priorFullRollback -EpinelRoot $EpinelRoot -ClientRoot $ClientRoot `
    -LauncherRoot $LauncherRoot `
    -AutomaticFailureRollback:$AutomaticFailureRollback | Out-Null

$sqliteReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\sqlite-credential-reset-v1\rollback.receipt.json"
$priorReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\launcher-credential-v1\full-composite-rollback.receipt.json"
$sqliteReceipt = Get-Content -LiteralPath $sqliteReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$priorReceipt = Get-Content -LiteralPath $priorReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($sqliteReceipt.contractId -ceq
        "nll/phase3b2-sqlite-credential-reset-rollback/v1" -and
    [bool]$sqliteReceipt.sqliteBaselineRestored -and
    $priorReceipt.contractId -ceq "nll/phase3b2-p0-full-composite-rollback/v1" -and
    [bool]$priorReceipt.systemHostsRestored -and
    [bool]$priorReceipt.launcherCertificateBundleRestored -and
    [bool]$priorReceipt.firewallRulesRemoved) `
    "phase3b2_sqlite_full_rollback_receipt_invalid"

$outputPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\sqlite-credential-reset-v1\full-composite-rollback.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $outputPath)) `
    "phase3b2_sqlite_full_rollback_receipt_exists"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-full-composite-rollback-with-sqlite-reset/v1"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    sqliteBaselineRestored = $true
    syntheticCredentialRestored = $true
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
[IO.File]::WriteAllText($outputPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
