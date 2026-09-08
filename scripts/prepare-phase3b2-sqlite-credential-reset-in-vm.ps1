[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS"
)

$ErrorActionPreference = "Stop"
$mutationStarted = $false
$completed = $false

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileEvidence {
    param([string]$Path)
    return [ordered]@{
        byteLength = (Get-Item -LiteralPath $Path).Length
        sha256 = Get-Sha256Hex $Path
    }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
        -ErrorAction SilentlyContinue)) "phase3b2_sqlite_reset_runtime_not_cold"

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$identityRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$dbJsonPath = Join-Path $serverRoot "db.json"
$baseP0Path = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0\applied-verification-private-v3.receipt.json"
$backupRoot = "C:\NLL\Backups\Phase3B2\SQLiteCredentialReset-v1"
$evidenceRoot = Join-Path $identityRoot "sqlite-credential-reset-v1"
$backupManifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
$receiptPath = Join-Path $evidenceRoot "reset-preparation.receipt.json"
$rollbackPath = "C:\NLL\Tools\rollback-phase3b2-sqlite-credential-reset-in-vm.ps1"
$fullRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"

$targets = @(
    [ordered]@{
        roleCode = "sqlite_main_baseline"
        source = Join-Path $serverRoot "epinelps.db"
        backup = Join-Path $backupRoot "epinelps.baseline.db"
        byteLength = 4096
        sha256 = "5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab"
    },
    [ordered]@{
        roleCode = "sqlite_shared_memory_baseline"
        source = Join-Path $serverRoot "epinelps.db-shm"
        backup = Join-Path $backupRoot "epinelps.baseline.db-shm"
        byteLength = 32768
        sha256 = "eba73c34d4fb0a074fed174dd6d01339cc3362b6e6842c26fbad45940229f422"
    },
    [ordered]@{
        roleCode = "sqlite_write_ahead_log_baseline"
        source = Join-Path $serverRoot "epinelps.db-wal"
        backup = Join-Path $backupRoot "epinelps.baseline.db-wal"
        byteLength = 148352
        sha256 = "aee6394fe6e99e100d4f5e5789fb55d60ff2bd8471708b133f7b300872685334"
    }
)

try {
    Assert-True (-not (Test-Path -LiteralPath $backupRoot) -and
        -not (Test-Path -LiteralPath $evidenceRoot)) `
        "phase3b2_sqlite_reset_output_exists"
    Assert-True (Test-Path -LiteralPath $rollbackPath -PathType Leaf) `
        "phase3b2_sqlite_reset_rollback_missing"
    Assert-True (Test-Path -LiteralPath $fullRollbackPath -PathType Leaf) `
        "phase3b2_sqlite_reset_full_rollback_missing"
    Assert-True ((Get-Item -LiteralPath $baseP0Path).Length -eq 2976 -and
        (Get-Sha256Hex $baseP0Path) -ceq
            "a2272a4fa382456cfa26a474f708fe1ffef680dff6ce3d3e856d138cd8b4f3a0") `
        "phase3b2_sqlite_reset_base_p0_drift"

    $serverRootResolved = (Resolve-Path -LiteralPath $serverRoot).Path.TrimEnd('\')
    foreach ($target in $targets) {
        $resolved = (Resolve-Path -LiteralPath $target.source).Path
        Assert-True ($resolved.StartsWith($serverRootResolved + "\",
                [StringComparison]::OrdinalIgnoreCase) -and
            (Get-Item -LiteralPath $resolved).Length -eq $target.byteLength -and
            (Get-Sha256Hex $resolved) -ceq $target.sha256) `
            "phase3b2_sqlite_reset_baseline_drift"
    }

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $dbJson = Get-Content -LiteralPath $dbJsonPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($context.contractId -ceq
            "nll/phase3b2-synthetic-runtime-context/v1" -and
        ([string]$context.password) -cmatch '^[0-9a-f]{20}$' -and
        @($dbJson.Users).Count -eq 1 -and
        [string]$dbJson.Users[0].Username -ceq [string]$context.username -and
        ([string]$dbJson.Users[0].Password) -cmatch '^[0-9a-f]{32}$' -and
        [string]$dbJson.Users[0].Password -cne [string]$context.password) `
        "phase3b2_sqlite_reset_credential_shape_invalid"
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $expectedHash = (($md5.ComputeHash(
                        [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                    ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $md5.Dispose() }
    Assert-True ($expectedHash -ceq [string]$dbJson.Users[0].Password) `
        "phase3b2_sqlite_reset_db_json_hash_mismatch"

    Assert-True (@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
            -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0 -and
        @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
            -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0) `
        "phase3b2_sqlite_reset_network_not_private"

    New-Item -ItemType Directory -Path $backupRoot, $evidenceRoot -Force | Out-Null
    foreach ($target in $targets) {
        Copy-Item -LiteralPath $target.source -Destination $target.backup
        Assert-True ((Get-Item -LiteralPath $target.backup).Length -eq
                $target.byteLength -and
            (Get-Sha256Hex $target.backup) -ceq $target.sha256) `
            "phase3b2_sqlite_reset_backup_verification_failed"
    }

    $manifest = [ordered]@{
        contractId = "nll/phase3b2-sqlite-credential-reset-backup-manifest/v1"
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        memberCount = 3
        members = @($targets | ForEach-Object {
                [ordered]@{
                    roleCode = $_.roleCode
                    byteLength = $_.byteLength
                    sha256 = $_.sha256
                }
            })
        rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
        fullCompositeRollbackScriptSha256 = Get-Sha256Hex $fullRollbackPath
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    [IO.File]::WriteAllText($backupManifestPath,
        (($manifest | ConvertTo-Json -Depth 5) + "`n"),
        [Text.UTF8Encoding]::new($false))

    $mutationStarted = $true
    foreach ($target in $targets) {
        [IO.File]::Delete((Resolve-Path -LiteralPath $target.source).Path)
    }
    Assert-True (@($targets | Where-Object {
                Test-Path -LiteralPath $_.source
            }).Count -eq 0) "phase3b2_sqlite_reset_removal_failed"

    $manifestEvidence = Get-FileEvidence $backupManifestPath
    $receipt = [ordered]@{
        contractId = "nll/phase3b2-sqlite-credential-reset-preparation/v1"
        preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        statusCode = "baseline_backed_up_runtime_sqlite_removed_for_rebootstrap"
        baselineMemberCount = 3
        backedUpMemberCount = 3
        removedRuntimeMemberCount = 3
        dbJsonPasswordMatchesContextMd5 = $true
        sqliteCredentialBindingVerified = $false
        sqliteCredentialRebootstrapPrepared = $true
        backupManifestByteLength = [long]$manifestEvidence.byteLength
        backupManifestSha256 = [string]$manifestEvidence.sha256
        rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
        fullCompositeRollbackScriptSha256 = Get-Sha256Hex $fullRollbackPath
        networkModeCode = "private_vm_only_no_gateway"
        credentialBearingGuestCopyPresent = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $completed = $true
    $receipt | ConvertTo-Json
}
catch {
    if ($mutationStarted -and -not $completed) {
        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target.backup -PathType Leaf) {
                Copy-Item -LiteralPath $target.backup -Destination $target.source -Force
            }
        }
    }
    throw
}
