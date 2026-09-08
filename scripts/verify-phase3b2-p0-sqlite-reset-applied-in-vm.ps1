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
        -ErrorAction SilentlyContinue)) "phase3b2_p0_v4_runtime_not_cold"

$trustedRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$identityRoot = Join-Path $trustedRoot "identity"
$p0Root = Join-Path $trustedRoot "p0"
$baseP0Path = Join-Path $p0Root "applied-verification-private-v3.receipt.json"
$outputPath = Join-Path $p0Root "applied-verification-private-v4.receipt.json"
$resetRoot = Join-Path $identityRoot "sqlite-credential-reset-v1"
$resetPath = Join-Path $resetRoot "reset-preparation.receipt.json"
$manifestPath =
    "C:\NLL\Backups\Phase3B2\SQLiteCredentialReset-v1\trusted-backup-manifest.json"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbJsonPath = Join-Path $serverRoot "db.json"
$fullRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
$sqlitePaths = @("epinelps.db", "epinelps.db-shm", "epinelps.db-wal") |
    ForEach-Object { Join-Path $serverRoot $_ }

Assert-True (-not (Test-Path -LiteralPath $outputPath)) `
    "phase3b2_p0_v4_output_exists"
Assert-True ((Get-Item -LiteralPath $baseP0Path).Length -eq 2976 -and
    (Get-Sha256Hex $baseP0Path) -ceq
        "a2272a4fa382456cfa26a474f708fe1ffef680dff6ce3d3e856d138cd8b4f3a0") `
    "phase3b2_p0_v4_base_receipt_drift"
Assert-True (@($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) `
    "phase3b2_p0_v4_sqlite_runtime_state_present"

$baseP0 = Get-Content -LiteralPath $baseP0Path -Raw -Encoding UTF8 |
    ConvertFrom-Json
$reset = Get-Content -LiteralPath $resetPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$dbJson = Get-Content -LiteralPath $dbJsonPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($baseP0.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v3" -and
    [bool]$baseP0.p0AppliedVerified -and
    $reset.contractId -ceq
        "nll/phase3b2-sqlite-credential-reset-preparation/v1" -and
    [bool]$reset.sqliteCredentialRebootstrapPrepared -and
    -not [bool]$reset.sqliteCredentialBindingVerified -and
    [int]$reset.baselineMemberCount -eq 3 -and
    [int]$reset.backedUpMemberCount -eq 3 -and
    [int]$reset.removedRuntimeMemberCount -eq 3 -and
    $manifest.contractId -ceq
        "nll/phase3b2-sqlite-credential-reset-backup-manifest/v1" -and
    [int]$manifest.memberCount -eq 3 -and
    [string]$reset.backupManifestSha256 -ceq (Get-Sha256Hex $manifestPath) -and
    [string]$reset.fullCompositeRollbackScriptSha256 -ceq
        (Get-Sha256Hex $fullRollbackPath)) "phase3b2_p0_v4_reset_receipt_invalid"

$md5 = [Security.Cryptography.MD5]::Create()
try {
    $expectedHash = (($md5.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                ForEach-Object { $_.ToString("x2") }) -join "")
}
finally { $md5.Dispose() }
Assert-True (([string]$context.password) -cmatch '^[0-9a-f]{20}$' -and
    @($dbJson.Users).Count -eq 1 -and
    [string]$dbJson.Users[0].Username -ceq [string]$context.username -and
    [string]$dbJson.Users[0].Password -ceq $expectedHash) `
    "phase3b2_p0_v4_credential_state_invalid"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
$upPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ "Up").Count
$networkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
Assert-True (@($launcherCertificateCandidates).Count -eq 1 -and
    (Get-Sha256Hex (@($launcherCertificateCandidates)[0])) -ceq
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" -and
    (Get-Item -LiteralPath (Join-Path $ClientRoot "nikke.exe")).VersionInfo.FileVersion `
        -ceq "150.6.9" -and
    @(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" `
        -ErrorAction Stop).Count -eq 16 -and
    @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count -eq 0 -and
    $upPhysicalNetworkAdapterCount -eq 1 -and $networkProfileCount -eq 1) `
    "phase3b2_p0_v4_environment_drift"

$resetDigest = Get-Digest $resetPath
$manifestDigest = Get-Digest $manifestPath
$fullRollbackDigest = Get-Digest $fullRollbackPath
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-applied-verification/v4"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0AppliedVerified = $true
    baseP0V3ReceiptByteLength = 2976
    baseP0V3ReceiptSha256 =
        "a2272a4fa382456cfa26a474f708fe1ffef680dff6ce3d3e856d138cd8b4f3a0"
    sqliteResetReceiptByteLength = [long]$resetDigest.byteLength
    sqliteResetReceiptSha256 = [string]$resetDigest.sha256
    sqliteBackupManifestByteLength = [long]$manifestDigest.byteLength
    sqliteBackupManifestSha256 = [string]$manifestDigest.sha256
    fullCompositeRollbackScriptByteLength = [long]$fullRollbackDigest.byteLength
    fullCompositeRollbackScriptSha256 = [string]$fullRollbackDigest.sha256
    clientBuild = "150.6.9"
    externalHead = [string]$baseP0.externalHead
    externalTree = [string]$baseP0.externalTree
    externalBuildManifestSha256 = [string]$baseP0.externalBuildManifestSha256
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    launcherCertificateAppliedSha256 =
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c"
    launcherPasswordPlaintextLength = 20
    launcherPasswordStorageLength = 32
    launcherPasswordStorageSchemeCode = "md5_lower_hex_legacy_launcher_compatibility"
    launcherPasswordRepresentationVerified = $true
    sqliteBaselineMemberCount = 3
    sqliteRuntimeMemberCount = 0
    sqliteCredentialRebootstrapPrepared = $true
    sqliteCredentialBindingVerified = $false
    mappedDomainCount = 17
    rootCaInstalledCount = 1
    firewallRuleCount = 16
    firewallProgramCount = 16
    networkModeCode = "private_vm_only_no_gateway"
    systemNetworkAvailable = $true
    upPhysicalNetworkAdapterCount = $upPhysicalNetworkAdapterCount
    networkProfileCount = $networkProfileCount
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
