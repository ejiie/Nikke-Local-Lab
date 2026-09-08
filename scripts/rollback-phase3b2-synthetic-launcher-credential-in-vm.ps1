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

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$identityRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity"
$backupRoot = "C:\NLL\Backups\Phase3B2\SyntheticCredential-v1"
$evidenceRoot = Join-Path $identityRoot "launcher-credential-v1"
$receiptPath = Join-Path $evidenceRoot "rollback.receipt.json"
$targets = @(
    [ordered]@{
        backup = Join-Path $backupRoot "db.original.json"
        target = Join-Path $serverRoot "db.json"
        byteLength = 413339
        sha256 = "55fe7e584c2e25fff199cf4f3117203588690f5748533bae07189404942c34ac"
    },
    [ordered]@{
        backup = Join-Path $backupRoot "synthetic-context.original.json"
        target = Join-Path $identityRoot "synthetic-context.json"
        byteLength = 304
        sha256 = "da98948b0a9ce94bb6a2d8ca66b6692b52cfd9555e6d2ecfabd5034feab3432c"
    },
    [ordered]@{
        backup = Join-Path $backupRoot "offline-synthetic-profile.original.receipt.json"
        target = Join-Path $identityRoot "offline-synthetic-profile.receipt.json"
        byteLength = 1033
        sha256 = "7d1d57eaede5919e394cb20b1362230e37f98a0a7efdda80aaee53171ff9e376"
    },
    [ordered]@{
        backup = Join-Path $backupRoot "epinelps.original.db"
        target = Join-Path $serverRoot "epinelps.db"
        byteLength = 4096
        sha256 = "5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab"
    },
    [ordered]@{
        backup = Join-Path $backupRoot "epinelps.original.db-shm"
        target = Join-Path $serverRoot "epinelps.db-shm"
        byteLength = 32768
        sha256 = "eba73c34d4fb0a074fed174dd6d01339cc3362b6e6842c26fbad45940229f422"
    },
    [ordered]@{
        backup = Join-Path $backupRoot "epinelps.original.db-wal"
        target = Join-Path $serverRoot "epinelps.db-wal"
        byteLength = 148352
        sha256 = "aee6394fe6e99e100d4f5e5789fb55d60ff2bd8471708b133f7b300872685334"
    }
)

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) "phase3b2_credential_rollback_runtime_not_cold"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_credential_rollback_receipt_exists"
foreach ($target in $targets) {
    Assert-True ((Get-Item -LiteralPath $target.backup).Length -eq $target.byteLength -and
        (Get-Sha256Hex $target.backup) -ceq $target.sha256) `
        "phase3b2_credential_rollback_backup_drift"
}

foreach ($target in $targets) {
    $temporary = $target.target + ".credential-rollback.tmp"
    Assert-True (-not (Test-Path -LiteralPath $temporary)) `
        "phase3b2_credential_rollback_temporary_exists"
    Copy-Item -LiteralPath $target.backup -Destination $temporary
    Move-Item -LiteralPath $temporary -Destination $target.target -Force
}
foreach ($target in $targets) {
    Assert-True ((Get-Item -LiteralPath $target.target).Length -eq $target.byteLength -and
        (Get-Sha256Hex $target.target) -ceq $target.sha256) `
        "phase3b2_credential_rollback_verification_failed"
}

$receipt = [ordered]@{
    contractId = "nll/phase3b2-synthetic-launcher-credential-rollback/v1"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredMemberCount = 6
    databaseRestored = $true
    syntheticContextRestored = $true
    syntheticProfileReceiptRestored = $true
    sqliteStateRestored = $true
    credentialSecretEmitted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
