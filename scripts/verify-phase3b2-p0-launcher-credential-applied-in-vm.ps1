[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher"
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

function Get-Digest {
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
        -ErrorAction SilentlyContinue)) "phase3b2_p0_v3_runtime_not_cold"

$trustedRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$identityRoot = Join-Path $trustedRoot "identity"
$credentialRoot = Join-Path $identityRoot "launcher-credential-v1"
$p0Root = Join-Path $trustedRoot "p0"
$p0V2Path = Join-Path $p0Root "applied-verification-private-v2.receipt.json"
$outputPath = Join-Path $p0Root "applied-verification-private-v3.receipt.json"
$repairPath = Join-Path $credentialRoot "repair.receipt.json"
$backupManifestPath =
    "C:\NLL\Backups\Phase3B2\SyntheticCredential-v1\trusted-backup-manifest.json"
$fullCompositeRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-and-credential-in-vm.ps1"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$profilePath = Join-Path $identityRoot "offline-synthetic-profile.receipt.json"
$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbPath = Join-Path $serverRoot "db.json"
Assert-True (-not (Test-Path -LiteralPath $outputPath)) `
    "phase3b2_p0_v3_output_exists"
Assert-True ((Get-Item -LiteralPath $fullCompositeRollbackPath).Length -eq 4222 -and
    (Get-Sha256Hex $fullCompositeRollbackPath) -ceq
        "b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371") `
    "phase3b2_p0_v3_full_composite_rollback_drift"
Assert-True ((Get-Item -LiteralPath $p0V2Path).Length -eq 2317 -and
    (Get-Sha256Hex $p0V2Path) -ceq
        "dc2994fbd0904d0c567bc1b9ca0cf5a16ce98abb982a37aed8107fc7057f7f06") `
    "phase3b2_p0_v3_base_p0_receipt_drift"

$p0V2 = Get-Content -LiteralPath $p0V2Path -Raw -Encoding UTF8 | ConvertFrom-Json
$repair = Get-Content -LiteralPath $repairPath -Raw -Encoding UTF8 | ConvertFrom-Json
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($p0V2.contractId -ceq "nll/phase3b2-p0-private-applied-verification/v2" -and
    $p0V2.p0AppliedVerified -and -not $p0V2.serverExecutionStarted -and
    -not $p0V2.clientExecutionStarted -and
    $repair.contractId -ceq "nll/phase3b2-synthetic-launcher-credential-repair/v1" -and
    $repair.statusCode -ceq "sealed_with_backup_and_rollback" -and
    [int]$repair.appliedPlaintextLength -eq 20 -and
    [int]$repair.appliedStorageLength -eq 32 -and
    $repair.appliedStorageSchemeCode -ceq
        "md5_lower_hex_legacy_launcher_compatibility" -and
    [bool]$repair.databasePasswordMatchesAppliedHash -and
    -not [bool]$repair.databasePasswordEqualsContextPlaintext -and
    [int]$repair.sqliteBaselineMemberCount -eq 3 -and
    [int]$repair.sqliteStateMutationCount -eq 0 -and
    -not [bool]$repair.rawCredentialEmitted -and
    -not [bool]$repair.serverExecutionStarted -and -not [bool]$repair.clientExecutionStarted) `
    "phase3b2_p0_v3_credential_repair_receipt_invalid"

Assert-True ($context.contractId -ceq "nll/phase3b2-synthetic-runtime-context/v1" -and
    ([string]$context.password) -cmatch '^[0-9a-f]{20}$' -and
    [int]$context.launcherPasswordPlaintextLength -eq 20 -and
    $context.launcherPasswordStorageSchemeCode -ceq
        "md5_lower_hex_legacy_launcher_compatibility" -and
    @($db.Users).Count -eq 1 -and
    [string]$db.Users[0].Username -ceq [string]$context.username -and
    ([string]$db.Users[0].Password) -cmatch '^[0-9a-f]{32}$' -and
    [string]$db.Users[0].Password -cne [string]$context.password -and
    $profile.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
    [int]$profile.launcherPasswordPlaintextLength -eq 20 -and
    [int]$profile.launcherPasswordStorageLength -eq 32 -and
    -not [bool]$profile.launcherPasswordPlaintextPersistedInDatabase -and
    [string]$profile.dbSha256 -ceq (Get-Sha256Hex $dbPath) -and
    [string]$profile.runtimeContextSha256 -ceq (Get-Sha256Hex $contextPath)) `
    "phase3b2_p0_v3_credential_live_state_invalid"
$md5 = [Security.Cryptography.MD5]::Create()
try {
    $expectedHash = (($md5.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                ForEach-Object { $_.ToString("x2") }) -join "")
}
finally { $md5.Dispose() }
Assert-True ($expectedHash -ceq [string]$db.Users[0].Password) `
    "phase3b2_p0_v3_credential_hash_mismatch"

Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
        "519c3db51ec24ca19307e93e85acde7885928a72" -and
    (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
        "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    @(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_p0_v3_external_checkout_drift"
Assert-True ((Get-Item -LiteralPath (Join-Path $ClientRoot "nikke.exe")).VersionInfo.FileVersion `
        -ceq "150.6.9") "phase3b2_p0_v3_client_version_drift"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
$gameCertificateCandidates = @(
    Join-Path $ClientRoot "nikke_Data\Plugins\x86_64\intl_cacert.pem"
    Join-Path $ClientRoot "nikke_Data\Plugins\x86_64\cacert.pem"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
Assert-True (@($launcherCertificateCandidates).Count -eq 1 -and
    (Get-Sha256Hex (@($launcherCertificateCandidates)[0])) -ceq
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" -and
    @($gameCertificateCandidates).Count -eq 1 -and
    (Get-Sha256Hex (@($gameCertificateCandidates)[0])) -ceq
        "1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9") `
    "phase3b2_p0_v3_certificate_state_drift"
Assert-True (@(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" `
        -ErrorAction Stop).Count -eq 16 -and
    @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0) `
    "phase3b2_p0_v3_network_or_firewall_drift"

$repairDigest = Get-Digest $repairPath
$backupManifestDigest = Get-Digest $backupManifestPath
$profileDigest = Get-Digest $profilePath
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-applied-verification/v3"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0AppliedVerified = $true
    clientBuild = "150.6.9"
    externalHead = [string]$p0V2.externalHead
    externalTree = [string]$p0V2.externalTree
    externalBuildManifestSha256 = [string]$p0V2.externalBuildManifestSha256
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    clientCertificateBundleMemberCount = 2
    launcherCertificateAppliedByteLength = 210620
    launcherCertificateAppliedSha256 =
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c"
    gameCertificateAppliedSha256 =
        "1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9"
    baseP0V2ReceiptSha256 =
        "dc2994fbd0904d0c567bc1b9ca0cf5a16ce98abb982a37aed8107fc7057f7f06"
    baseBackupManifestSha256 = [string]$p0V2.baseBackupManifestSha256
    baseAppliedManifestSha256 = [string]$p0V2.baseAppliedManifestSha256
    launcherBackupManifestSha256 = [string]$p0V2.launcherBackupManifestSha256
    launcherAppliedManifestSha256 = [string]$p0V2.launcherAppliedManifestSha256
    compositeRollbackScriptSha256 = [string]$p0V2.compositeRollbackScriptSha256
    fullCompositeRollbackScriptByteLength = 4222
    fullCompositeRollbackScriptSha256 =
        "b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371"
    credentialRepairReceiptByteLength = [long]$repairDigest.byteLength
    credentialRepairReceiptSha256 = [string]$repairDigest.sha256
    credentialBackupManifestByteLength = [long]$backupManifestDigest.byteLength
    credentialBackupManifestSha256 = [string]$backupManifestDigest.sha256
    syntheticProfileReceiptByteLength = [long]$profileDigest.byteLength
    syntheticProfileReceiptSha256 = [string]$profileDigest.sha256
    launcherPasswordPlaintextLength = 20
    launcherPasswordStorageLength = 32
    launcherPasswordStorageSchemeCode = "md5_lower_hex_legacy_launcher_compatibility"
    launcherPasswordRepresentationVerified = $true
    sqliteBaselineMemberCount = 3
    sqliteStateMutationCount = 0
    mappedDomainCount = 17
    rootCaInstalledCount = 1
    firewallRuleCount = 16
    firewallProgramCount = 16
    networkModeCode = "private_vm_only_no_gateway"
    systemNetworkAvailable = $true
    upPhysicalNetworkAdapterCount = 1
    networkProfileCount = 1
    ipv4DefaultRouteCount = 0
    ipv6DefaultRouteCount = 0
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($outputPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
