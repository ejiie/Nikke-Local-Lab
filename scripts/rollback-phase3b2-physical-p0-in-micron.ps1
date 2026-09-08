[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$ClientCloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$BackupRoot = 'C:\NLL\Backups\Phase3B2\Physical-P0-v1',
    [switch]$AutomaticFailureRollback
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p0_rollback_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$samsungDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
    'phase3b2_physical_p0_rollback_micron_boot_required'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.LocalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p0_rollback_runtime_not_cold'

$manifestPath = Join-Path $BackupRoot 'trusted-backup-manifest.json'
Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) `
    'phase3b2_physical_p0_rollback_manifest_missing'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($manifest.contractId -ceq
        'nll/phase3b2-physical-p0-trusted-backup-manifest/v1' -and
    $manifest.clientCloneRoot -ceq $ClientCloneRoot -and
    -not $manifest.rootCaPreviouslyPresent -and
    [int]$manifest.firewallRuleCountBefore -eq 0) `
    'phase3b2_physical_p0_rollback_manifest_invalid'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$pluginsRoot = Join-Path $ClientCloneRoot 'NIKKE\game\nikke_Data\Plugins\x86_64'
$certificatePath = Join-Path $pluginsRoot 'intl_cacert.pem'
$sodiumPath = Join-Path $pluginsRoot 'sodium.dll'
$hostsBackup = Join-Path $BackupRoot 'hosts.original.bin'
$certificateBackup = Join-Path $BackupRoot 'game-certificate.original.bin'
$sodiumBackup = Join-Path $BackupRoot 'sodium.original.bin'
$backupPins = @(
    [pscustomobject]@{ Path = $hostsBackup; Length = 1054L; Sha256 = '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9' },
    [pscustomobject]@{ Path = $certificateBackup; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
    [pscustomobject]@{ Path = $sodiumBackup; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
)
foreach ($pin in $backupPins) {
    Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
        (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
        'phase3b2_physical_p0_rollback_backup_pin_mismatch'
}

$firewallGroup = 'NLL Phase3B2 Physical Isolation'
Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

$caCerPath = Join-Path $EpinelRoot 'ServerSelector\myCA.cer'
Assert-True ((Get-Item -LiteralPath $caCerPath).Length -eq 1266L -and
    (Get-Sha256Hex $caCerPath) -ceq
        '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') `
    'phase3b2_physical_p0_rollback_ca_source_mismatch'
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
try {
    foreach ($certificate in @($store.Certificates |
            Where-Object Thumbprint -CEQ $ca.Thumbprint)) {
        $store.Remove($certificate)
    }
}
finally { $store.Close() }

[IO.File]::WriteAllBytes($hostsPath, [IO.File]::ReadAllBytes($hostsBackup))
[IO.File]::WriteAllBytes($certificatePath, [IO.File]::ReadAllBytes($certificateBackup))
[IO.File]::WriteAllBytes($sodiumPath, [IO.File]::ReadAllBytes($sodiumBackup))
[IO.File]::SetAttributes($hostsPath,
    [IO.FileAttributes][int]$manifest.hostsOriginalAttributes)
[IO.File]::SetAttributes($certificatePath,
    [IO.FileAttributes][int]$manifest.gameCertificateOriginalAttributes)
[IO.File]::SetAttributes($sodiumPath,
    [IO.FileAttributes][int]$manifest.sodiumOriginalAttributes)

Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq 1054L -and
    (Get-Sha256Hex $hostsPath) -ceq
        '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9') `
    'phase3b2_physical_p0_rollback_hosts_failed'
Assert-True ((Get-Item -LiteralPath $certificatePath).Length -eq 212549L -and
    (Get-Sha256Hex $certificatePath) -ceq
        '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d') `
    'phase3b2_physical_p0_rollback_certificate_failed'
Assert-True ((Get-Item -LiteralPath $sodiumPath).Length -eq 304128L -and
    (Get-Sha256Hex $sodiumPath) -ceq
        '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888') `
    'phase3b2_physical_p0_rollback_sodium_failed'
Assert-True (@(Get-NetFirewallRule -Group $firewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p0_rollback_firewall_failed'
$verifyStore = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$verifyStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    Assert-True (@($verifyStore.Certificates |
            Where-Object Thumbprint -CEQ $ca.Thumbprint).Count -eq 0) `
        'phase3b2_physical_p0_rollback_root_ca_failed'
}
finally { $verifyStore.Close() }

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p0-rollback/v1'
    rolledBackAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = [string]$manifest.assessmentUid
    automaticFailureRollback = [bool]$AutomaticFailureRollback
    systemHostsRestored = $true
    rootCaRemoved = $true
    clientCertificateBundleRestored = $true
    nativeCompatibilityShimRestored = $true
    firewallRulesRemoved = $true
    primaryInstallModified = $false
    officialLauncherModified = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $BackupRoot 'rollback.receipt.json'
Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$protectedAttemptRoot = [string]$manifest.protectedAttemptRoot
if (Test-Path -LiteralPath $protectedAttemptRoot -PathType Container) {
    Write-AtomicUtf8NoBom (Join-Path $protectedAttemptRoot 'rollback.receipt.json') `
        (($receipt | ConvertTo-Json) + "`n")
}
$receipt | ConvertTo-Json
