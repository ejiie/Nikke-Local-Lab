[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS"
)

$ErrorActionPreference = "Stop"
$mutationStarted = $false
$repairCompleted = $false

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

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Text)
    $temporary = $Path + ".credential-repair.tmp"
    Assert-True (-not (Test-Path -LiteralPath $temporary)) `
        "phase3b2_credential_repair_temporary_exists"
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
    else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbPath = Join-Path $serverRoot "db.json"
$identityRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$profileReceiptPath = Join-Path $identityRoot "offline-synthetic-profile.receipt.json"
$backupRoot = "C:\NLL\Backups\Phase3B2\SyntheticCredential-v1"
$evidenceRoot = Join-Path $identityRoot "launcher-credential-v1"
$backupManifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
$repairReceiptPath = Join-Path $evidenceRoot "repair.receipt.json"
$rollbackScriptPath = "C:\NLL\Tools\rollback-phase3b2-synthetic-launcher-credential-in-vm.ps1"
$targets = @(
    [ordered]@{
        roleCode = "synthetic_database"
        source = $dbPath
        backup = Join-Path $backupRoot "db.original.json"
        byteLength = 413339
        sha256 = "55fe7e584c2e25fff199cf4f3117203588690f5748533bae07189404942c34ac"
    },
    [ordered]@{
        roleCode = "synthetic_runtime_context"
        source = $contextPath
        backup = Join-Path $backupRoot "synthetic-context.original.json"
        byteLength = 304
        sha256 = "da98948b0a9ce94bb6a2d8ca66b6692b52cfd9555e6d2ecfabd5034feab3432c"
    },
    [ordered]@{
        roleCode = "synthetic_profile_receipt"
        source = $profileReceiptPath
        backup = Join-Path $backupRoot "offline-synthetic-profile.original.receipt.json"
        byteLength = 1033
        sha256 = "7d1d57eaede5919e394cb20b1362230e37f98a0a7efdda80aaee53171ff9e376"
    },
    [ordered]@{
        roleCode = "sqlite_main_baseline"
        source = Join-Path $serverRoot "epinelps.db"
        backup = Join-Path $backupRoot "epinelps.original.db"
        byteLength = 4096
        sha256 = "5c9dec1886cc01f5f2307ee1ea87f9b32a4cef0f8f9a2c68beebc558013bedab"
    },
    [ordered]@{
        roleCode = "sqlite_shared_memory_baseline"
        source = Join-Path $serverRoot "epinelps.db-shm"
        backup = Join-Path $backupRoot "epinelps.original.db-shm"
        byteLength = 32768
        sha256 = "eba73c34d4fb0a074fed174dd6d01339cc3362b6e6842c26fbad45940229f422"
    },
    [ordered]@{
        roleCode = "sqlite_write_ahead_log_baseline"
        source = Join-Path $serverRoot "epinelps.db-wal"
        backup = Join-Path $backupRoot "epinelps.original.db-wal"
        byteLength = 148352
        sha256 = "aee6394fe6e99e100d4f5e5789fb55d60ff2bd8471708b133f7b300872685334"
    }
)

try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
    Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke_launcher, nikke `
            -ErrorAction SilentlyContinue)) "phase3b2_credential_repair_runtime_not_cold"
    Assert-True (-not (Test-Path -LiteralPath $backupRoot) -and
        -not (Test-Path -LiteralPath $evidenceRoot)) `
        "phase3b2_credential_repair_output_exists"
    Assert-True (Test-Path -LiteralPath $rollbackScriptPath -PathType Leaf) `
        "phase3b2_credential_repair_rollback_script_missing"
    foreach ($target in $targets) {
        Assert-True ((Get-Item -LiteralPath $target.source).Length -eq $target.byteLength -and
            (Get-Sha256Hex $target.source) -ceq $target.sha256) `
            "phase3b2_credential_repair_source_drift"
    }

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profile = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($context.contractId -ceq "nll/phase3b2-synthetic-runtime-context/v1" -and
        @($db.Users).Count -eq 1 -and
        [string]$db.Users[0].Username -ceq [string]$context.username -and
        [string]$db.Users[0].Password -ceq [string]$context.password -and
        ([string]$context.password).Length -eq 44 -and
        $profile.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
        [long]$profile.dbByteLength -eq 413339 -and
        [string]$profile.dbSha256 -ceq $targets[0].sha256 -and
        [long]$profile.runtimeContextByteLength -eq 304 -and
        [string]$profile.runtimeContextSha256 -ceq $targets[1].sha256) `
        "phase3b2_credential_repair_input_shape_invalid"

    New-Item -ItemType Directory -Path $backupRoot, $evidenceRoot -Force | Out-Null
    foreach ($target in $targets) {
        Copy-Item -LiteralPath $target.source -Destination $target.backup
        Assert-True ((Get-Item -LiteralPath $target.backup).Length -eq $target.byteLength -and
            (Get-Sha256Hex $target.backup) -ceq $target.sha256) `
            "phase3b2_credential_repair_backup_verification_failed"
    }
    $backupManifest = [ordered]@{
        contractId = "nll/phase3b2-synthetic-launcher-credential-backup-manifest/v1"
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        memberCount = $targets.Count
        members = @($targets | ForEach-Object {
                [ordered]@{
                    roleCode = $_.roleCode
                    byteLength = $_.byteLength
                    sha256 = $_.sha256
                }
            })
        rollbackScriptSha256 = Get-Sha256Hex $rollbackScriptPath
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    [IO.File]::WriteAllText($backupManifestPath,
        (($backupManifest | ConvertTo-Json -Depth 5) + "`n"),
        [Text.UTF8Encoding]::new($false))

    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $passwordBytes = New-Object byte[] 10
        $random.GetBytes($passwordBytes)
    }
    finally { $random.Dispose() }
    $launcherPassword = ([BitConverter]::ToString($passwordBytes) -replace '-', '').ToLowerInvariant()
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $launcherPasswordHash = (($md5.ComputeHash(
                        [Text.Encoding]::ASCII.GetBytes($launcherPassword)) |
                    ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $md5.Dispose() }
    Assert-True ($launcherPassword -cmatch '^[0-9a-f]{20}$' -and
        $launcherPasswordHash -cmatch '^[0-9a-f]{32}$') `
        "phase3b2_credential_repair_generated_shape_invalid"

    $db.Users[0].Password = $launcherPasswordHash
    $context.password = $launcherPassword
    Set-ObjectProperty $context "launcherPasswordStorageSchemeCode" `
        "md5_lower_hex_legacy_launcher_compatibility"
    Set-ObjectProperty $context "launcherPasswordPlaintextLength" 20

    $mutationStarted = $true
    Write-AtomicUtf8 $dbPath (($db | ConvertTo-Json -Depth 100) + "`n")
    Write-AtomicUtf8 $contextPath (($context | ConvertTo-Json -Depth 10) + "`n")
    $dbEvidence = Get-FileEvidence $dbPath
    $contextEvidence = Get-FileEvidence $contextPath
    Set-ObjectProperty $profile "dbByteLength" ([long]$dbEvidence.byteLength)
    Set-ObjectProperty $profile "dbSha256" ([string]$dbEvidence.sha256)
    Set-ObjectProperty $profile "runtimeContextByteLength" ([long]$contextEvidence.byteLength)
    Set-ObjectProperty $profile "runtimeContextSha256" ([string]$contextEvidence.sha256)
    Set-ObjectProperty $profile "launcherPasswordPlaintextLength" 20
    Set-ObjectProperty $profile "launcherPasswordStorageLength" 32
    Set-ObjectProperty $profile "launcherPasswordStorageSchemeCode" `
        "md5_lower_hex_legacy_launcher_compatibility"
    Set-ObjectProperty $profile "launcherPasswordPlaintextPersistedInDatabase" $false
    Write-AtomicUtf8 $profileReceiptPath (($profile | ConvertTo-Json -Depth 20) + "`n")

    $dbAfter = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $contextAfter = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profileAfter = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (@($dbAfter.Users).Count -eq 1 -and
        [string]$dbAfter.Users[0].Username -ceq [string]$contextAfter.username -and
        ([string]$contextAfter.password) -cmatch '^[0-9a-f]{20}$' -and
        ([string]$dbAfter.Users[0].Password) -cmatch '^[0-9a-f]{32}$' -and
        [string]$dbAfter.Users[0].Password -ceq $launcherPasswordHash -and
        [string]$dbAfter.Users[0].Password -cne [string]$contextAfter.password -and
        [string]$profileAfter.dbSha256 -ceq (Get-Sha256Hex $dbPath) -and
        [string]$profileAfter.runtimeContextSha256 -ceq (Get-Sha256Hex $contextPath) -and
        -not [bool]$profileAfter.launcherPasswordPlaintextPersistedInDatabase) `
        "phase3b2_credential_repair_postcondition_failed"
    Assert-True (@($targets | Where-Object { $_.roleCode -like "sqlite_*" } |
            Where-Object {
                (Get-Item -LiteralPath $_.source).Length -ne $_.byteLength -or
                (Get-Sha256Hex $_.source) -cne $_.sha256
            }).Count -eq 0) "phase3b2_credential_repair_sqlite_state_drift"

    $repairReceipt = [ordered]@{
        contractId = "nll/phase3b2-synthetic-launcher-credential-repair/v1"
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        statusCode = "sealed_with_backup_and_rollback"
        priorPlaintextLength = 44
        appliedPlaintextLength = 20
        appliedStorageLength = 32
        appliedStorageSchemeCode = "md5_lower_hex_legacy_launcher_compatibility"
        databasePasswordMatchesAppliedHash = $true
        databasePasswordEqualsContextPlaintext = $false
        sqliteBaselineMemberCount = 3
        sqliteStateMutationCount = 0
        backupManifestByteLength = (Get-Item -LiteralPath $backupManifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $backupManifestPath
        rollbackScriptSha256 = Get-Sha256Hex $rollbackScriptPath
        databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
        databaseAfterSha256 = Get-Sha256Hex $dbPath
        contextAfterByteLength = (Get-Item -LiteralPath $contextPath).Length
        contextAfterSha256 = Get-Sha256Hex $contextPath
        profileReceiptAfterByteLength = (Get-Item -LiteralPath $profileReceiptPath).Length
        profileReceiptAfterSha256 = Get-Sha256Hex $profileReceiptPath
        rawCredentialEmitted = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    [IO.File]::WriteAllText($repairReceiptPath,
        (($repairReceipt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
    $repairCompleted = $true
    $repairReceipt | ConvertTo-Json
}
catch {
    if ($mutationStarted -and -not $repairCompleted -and
        (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        foreach ($target in $targets) {
            if (Test-Path -LiteralPath $target.backup -PathType Leaf) {
                Copy-Item -LiteralPath $target.backup -Destination $target.source -Force
            }
        }
    }
    throw
}
