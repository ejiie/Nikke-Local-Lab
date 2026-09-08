[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS"
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
        -ErrorAction SilentlyContinue)) "phase3b2_sqlite_reset_rollback_runtime_not_cold"

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$serverRootResolved = (Resolve-Path -LiteralPath $serverRoot).Path.TrimEnd('\')
$identityRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\sqlite-credential-reset-v1"
$backupRoot = "C:\NLL\Backups\Phase3B2\SQLiteCredentialReset-v1"
$manifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
$receiptPath = Join-Path $identityRoot "rollback.receipt.json"
$targets = @(
    [ordered]@{ backup = Join-Path $backupRoot "epinelps.baseline.db"; target = Join-Path $serverRoot "epinelps.db"; byteLength = 4096; sha256 = "5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab" },
    [ordered]@{ backup = Join-Path $backupRoot "epinelps.baseline.db-shm"; target = Join-Path $serverRoot "epinelps.db-shm"; byteLength = 32768; sha256 = "eba73c34d4fb0a074fed174dd6d01339cc3362b6e6842c26fbad45940229f422" },
    [ordered]@{ backup = Join-Path $backupRoot "epinelps.baseline.db-wal"; target = Join-Path $serverRoot "epinelps.db-wal"; byteLength = 148352; sha256 = "aee6394fe6e99e100d4f5e5789fb55d60ff2bd8471708b133f7b300872685334" }
)

Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_sqlite_reset_rollback_receipt_exists"
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($manifest.contractId -ceq
        "nll/phase3b2-sqlite-credential-reset-backup-manifest/v1" -and
    [int]$manifest.memberCount -eq 3) "phase3b2_sqlite_reset_manifest_invalid"
foreach ($target in $targets) {
    Assert-True ((Get-Item -LiteralPath $target.backup).Length -eq
            $target.byteLength -and
        (Get-Sha256Hex $target.backup) -ceq $target.sha256 -and
        ([IO.Path]::GetFullPath($target.target)).StartsWith(
            $serverRootResolved + "\", [StringComparison]::OrdinalIgnoreCase)) `
        "phase3b2_sqlite_reset_rollback_backup_drift"
}

foreach ($target in $targets) {
    $temporary = $target.target + ".sqlite-reset-rollback.tmp"
    Assert-True (-not (Test-Path -LiteralPath $temporary)) `
        "phase3b2_sqlite_reset_rollback_temporary_exists"
    Copy-Item -LiteralPath $target.backup -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination $target.target -Force
}
foreach ($target in $targets) {
    Assert-True ((Get-Item -LiteralPath $target.target).Length -eq
            $target.byteLength -and
        (Get-Sha256Hex $target.target) -ceq $target.sha256) `
        "phase3b2_sqlite_reset_rollback_verification_failed"
}

$receipt = [ordered]@{
    contractId = "nll/phase3b2-sqlite-credential-reset-rollback/v1"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredBaselineMemberCount = 3
    sqliteBaselineRestored = $true
    credentialSecretEmitted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $identityRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
