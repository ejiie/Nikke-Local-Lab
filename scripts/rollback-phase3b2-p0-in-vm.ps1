[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$BackupRoot = "C:\NLL\Backups\Phase3B2\P0-v1",
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
    "phase3b2_runtime_process_present_during_rollback"
$manifestPath = Join-Path $BackupRoot "trusted-backup-manifest.json"
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) "phase3b2_backup_manifest_missing"
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($manifest.contractId -ceq "nll/phase3b2-p0-trusted-backup-manifest/v1") `
    "phase3b2_backup_manifest_contract_mismatch"

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$gameCertificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
)
$gameCertificates = @($gameCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Assert-True ($gameCertificates.Count -eq 1) "phase3b2_rollback_game_certificate_shape_invalid"
$gameCertificatePath = $gameCertificates[0]
$gameSodiumPath = Join-Path $pluginsRoot "sodium.dll"
$hostsBackup = Join-Path $BackupRoot "hosts.original.bin"
$certificateBackup = Join-Path $BackupRoot "game-certificate.original.bin"
$sodiumBackup = Join-Path $BackupRoot "sodium.original.bin"

Assert-True ((Get-Item -LiteralPath $hostsBackup).Length -eq 824 -and
    (Get-Sha256Hex $hostsBackup) -ceq "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085") `
    "phase3b2_hosts_backup_invalid"
Assert-True ((Get-Item -LiteralPath $certificateBackup).Length -eq 212549 -and
    (Get-Sha256Hex $certificateBackup) -ceq "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d") `
    "phase3b2_certificate_backup_invalid"
Assert-True ((Get-Item -LiteralPath $sodiumBackup).Length -eq 304128 -and
    (Get-Sha256Hex $sodiumBackup) -ceq "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888") `
    "phase3b2_sodium_backup_invalid"

$firewallGroup = "NLL Phase3B2 Isolation"
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule

$caCerPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
Assert-True ((Get-Item -LiteralPath $caCerPath).Length -eq 1266 -and
    (Get-Sha256Hex $caCerPath) -ceq "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda") `
    "phase3b2_rollback_ca_source_invalid"
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
try {
    $installed = @($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint)
    foreach ($certificate in $installed) { $store.Remove($certificate) }
}
finally {
    $store.Close()
}

[IO.File]::WriteAllBytes($hostsPath, [IO.File]::ReadAllBytes($hostsBackup))
[IO.File]::WriteAllBytes($gameCertificatePath, [IO.File]::ReadAllBytes($certificateBackup))
[IO.File]::WriteAllBytes($gameSodiumPath, [IO.File]::ReadAllBytes($sodiumBackup))
[IO.File]::SetAttributes($hostsPath, [IO.FileAttributes][int]$manifest.hostsOriginalAttributes)
[IO.File]::SetAttributes($gameCertificatePath,
    [IO.FileAttributes][int]$manifest.gameCertificateOriginalAttributes)
[IO.File]::SetAttributes($gameSodiumPath, [IO.FileAttributes][int]$manifest.sodiumOriginalAttributes)

Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq 824 -and
    (Get-Sha256Hex $hostsPath) -ceq "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085") `
    "phase3b2_hosts_rollback_failed"
Assert-True ((Get-Item -LiteralPath $gameCertificatePath).Length -eq 212549 -and
    (Get-Sha256Hex $gameCertificatePath) -ceq "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d") `
    "phase3b2_certificate_rollback_failed"
Assert-True ((Get-Item -LiteralPath $gameSodiumPath).Length -eq 304128 -and
    (Get-Sha256Hex $gameSodiumPath) -ceq "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888") `
    "phase3b2_sodium_rollback_failed"
Assert-True (@(Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue).Count -eq 0) `
    "phase3b2_firewall_rollback_failed"
$verifyStore = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$verifyStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    Assert-True (@($verifyStore.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count -eq 0) `
        "phase3b2_root_ca_rollback_failed"
}
finally {
    $verifyStore.Close()
}

$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$receiptPath = Join-Path $evidenceRoot "rollback.receipt.json"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-rollback/v1"
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    systemHostsRestored = $true
    rootCaRemoved = $true
    clientCertificateBundleRestored = $true
    nativeCompatibilityShimRestored = $true
    firewallRulesRemoved = $true
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
