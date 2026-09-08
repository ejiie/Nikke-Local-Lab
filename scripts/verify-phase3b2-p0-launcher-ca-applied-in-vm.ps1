[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher",
    [string]$BaseBackupRoot = "C:\NLL\Backups\Phase3B2\P0-v1",
    [string]$LauncherBackupRoot = "C:\NLL\Backups\Phase3B2\P0-launcher-ca-v1"
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
    "phase3b2_runtime_process_already_started"
Assert-True (-not (Test-Path -LiteralPath "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_credential_bearing_guest_copy_present"

$clientExe = Join-Path $ClientRoot "nikke.exe"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_client_version_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
    "519c3db51ec24ca19307e93e85acde7885928a72") "phase3b2_external_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
    "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a") "phase3b2_external_tree_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_external_checkout_not_clean"

$baseEvidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
$launcherEvidenceRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0-launcher-ca-v1"
$baseBackupManifestPath = Join-Path $BaseBackupRoot "trusted-backup-manifest.json"
$baseAppliedManifestPath = Join-Path $baseEvidenceRoot "trusted-applied-manifest.json"
$basePrivateVerificationPath = Join-Path $baseEvidenceRoot `
    "applied-verification-private-v1.receipt.json"
$launcherBackupManifestPath = Join-Path $LauncherBackupRoot `
    "trusted-launcher-certificate-backup-manifest.json"
$launcherAppliedManifestPath = Join-Path $launcherEvidenceRoot `
    "trusted-launcher-certificate-applied-manifest.json"
$launcherExtensionReceiptPath = Join-Path $launcherEvidenceRoot "extension.receipt.json"

Assert-True ((Get-Item -LiteralPath $baseBackupManifestPath).Length -eq 1240 -and
    (Get-Sha256Hex $baseBackupManifestPath) -ceq
        "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a") `
    "phase3b2_p0_v2_base_backup_manifest_drift"
Assert-True ((Get-Item -LiteralPath $baseAppliedManifestPath).Length -eq 1961 -and
    (Get-Sha256Hex $baseAppliedManifestPath) -ceq
        "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46") `
    "phase3b2_p0_v2_base_applied_manifest_drift"
Assert-True ((Get-Item -LiteralPath $basePrivateVerificationPath).Length -eq 1379 -and
    (Get-Sha256Hex $basePrivateVerificationPath) -ceq
        "15c9161833934850ce722f54cbd167383d59059345cf18268021ad2808c3fb61") `
    "phase3b2_p0_v2_base_private_verification_drift"
Assert-True ((Get-Item -LiteralPath $launcherBackupManifestPath).Length -eq 1397 -and
    (Get-Sha256Hex $launcherBackupManifestPath) -ceq
        "6078cccf2e79fdf89b39a464f9b22d604057a66a300734eb81141c95cabd7d93") `
    "phase3b2_p0_v2_launcher_backup_manifest_drift"
Assert-True ((Get-Item -LiteralPath $launcherAppliedManifestPath).Length -eq 1152 -and
    (Get-Sha256Hex $launcherAppliedManifestPath) -ceq
        "dfcd10d06f09c3348e5578ceb3ac4328ca3e6d2cb70e35bd0dd662f42c9cc14d") `
    "phase3b2_p0_v2_launcher_applied_manifest_drift"
Assert-True (Test-Path -LiteralPath $launcherExtensionReceiptPath -PathType Leaf) `
    "phase3b2_p0_v2_launcher_extension_receipt_missing"

$baseApplied = Get-Content -LiteralPath $baseAppliedManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$baseVerification = Get-Content -LiteralPath $basePrivateVerificationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$launcherBackupManifest = Get-Content -LiteralPath $launcherBackupManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$launcherAppliedManifest = Get-Content -LiteralPath $launcherAppliedManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$launcherExtensionReceipt = Get-Content -LiteralPath $launcherExtensionReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($baseVerification.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v1" -and
    $baseVerification.p0AppliedVerified -and
    -not $baseVerification.serverExecutionStarted -and
    -not $baseVerification.clientExecutionStarted) "phase3b2_p0_v2_base_verification_invalid"
Assert-True ($launcherBackupManifest.contractId -ceq
        "nll/phase3b2-p0-launcher-certificate-backup-manifest/v1" -and
    $launcherAppliedManifest.contractId -ceq
        "nll/phase3b2-p0-launcher-certificate-applied-manifest/v1" -and
    $launcherExtensionReceipt.contractId -ceq
        "nll/phase3b2-p0-launcher-certificate-extension/v1" -and
    [int]$launcherExtensionReceipt.clientCertificateBundleMemberCount -eq 2 -and
    [long]$launcherExtensionReceipt.launcherCertificateAppliedByteLength -eq 210620 -and
    $launcherExtensionReceipt.launcherCertificateAppliedSha256 -ceq
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" -and
    -not $launcherExtensionReceipt.credentialBearingGuestCopyPresent -and
    -not $launcherExtensionReceipt.officialIdentityPersisted -and
    -not $launcherExtensionReceipt.officialCredentialPersisted -and
    -not $launcherExtensionReceipt.serverExecutionStarted -and
    -not $launcherExtensionReceipt.clientExecutionStarted) `
    "phase3b2_p0_v2_launcher_extension_invalid"

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq
        [long]$baseApplied.systemHosts.appliedByteLength -and
    (Get-Sha256Hex $hostsPath) -ceq [string]$baseApplied.systemHosts.appliedSha256) `
    "phase3b2_p0_v2_hosts_applied_digest_mismatch"
$targetDomains = @(
    "global-lobby.nikke-kr.com", "cloud.nikke-kr.com", "jp-lobby.nikke-kr.com",
    "us-lobby.nikke-kr.com", "kr-lobby.nikke-kr.com", "sea-lobby.nikke-kr.com",
    "hmt-lobby.nikke-kr.com", "aws-na-dr.intlgame.com", "sg-vas.intlgame.com",
    "aws-na.intlgame.com", "na-community.playerinfinite.com", "common-web.intlgame.com",
    "li-sg.intlgame.com", "na.fleetlogd.com", "www.jupiterlauncher.com",
    "data-aws-na.intlgame.com", "sentry.io"
)
$hostsLines = @(Get-Content -LiteralPath $hostsPath -Encoding UTF8)
foreach ($domain in $targetDomains) {
    $domainLines = @($hostsLines | Where-Object {
            $_ -match "(^|\s)$([regex]::Escape($domain))(\s|$)"
        })
    Assert-True ($domainLines.Count -eq 1 -and $domainLines[0] -match "^\s*127\.0\.0\.1\s+") `
        "phase3b2_p0_v2_hosts_target_binding_invalid"
}

$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$gameCertificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
)
$gameCertificates = @(
    $gameCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
Assert-True ($gameCertificates.Count -eq 1) "phase3b2_p0_v2_game_certificate_shape_invalid"
$gameCertificatePath = $gameCertificates[0]
$gameCertificateText = Get-Content -LiteralPath $gameCertificatePath -Raw -Encoding UTF8
Assert-True (@([regex]::Matches($gameCertificateText, "Good SSL Ca")).Count -eq 1 -and
    (Get-Item -LiteralPath $gameCertificatePath).Length -eq
        [long]$baseApplied.clientCertificateBundle.appliedByteLength -and
    (Get-Sha256Hex $gameCertificatePath) -ceq
        [string]$baseApplied.clientCertificateBundle.appliedSha256) `
    "phase3b2_p0_v2_game_certificate_invalid"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
)
$launcherCertificates = @(
    $launcherCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
Assert-True ($launcherCertificates.Count -eq 1) "phase3b2_p0_v2_launcher_certificate_shape_invalid"
$launcherCertificatePath = $launcherCertificates[0]
$launcherCertificateText = Get-Content -LiteralPath $launcherCertificatePath -Raw -Encoding UTF8
Assert-True (@([regex]::Matches($launcherCertificateText, "Good SSL Ca")).Count -eq 1 -and
    (Get-Item -LiteralPath $launcherCertificatePath).Length -eq 210620 -and
    (Get-Sha256Hex $launcherCertificatePath) -ceq
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c") `
    "phase3b2_p0_v2_launcher_certificate_invalid"

$launcherBackupPath = Join-Path $LauncherBackupRoot "launcher-certificate.original.bin"
Assert-True ((Get-Item -LiteralPath $launcherBackupPath).Length -eq 209309 -and
    (Get-Sha256Hex $launcherBackupPath) -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
    "phase3b2_p0_v2_launcher_backup_invalid"
$compositeRollbackPath = [string]$launcherBackupManifest.compositeRollbackScriptPath
Assert-True ((Get-Sha256Hex $compositeRollbackPath) -ceq
    "83df6aac274fe78960032eead2d1f2da418d0d2969ee57d430132c0c5b248586") `
    "phase3b2_p0_v2_composite_rollback_drift"

$gameSodiumPath = Join-Path $pluginsRoot "sodium.dll"
Assert-True ((Get-Item -LiteralPath $gameSodiumPath).Length -eq 358400 -and
    (Get-Sha256Hex $gameSodiumPath) -ceq
        "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662") `
    "phase3b2_p0_v2_native_shim_invalid"
$caCerPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    $rootCaCount = @($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
}
finally {
    $store.Close()
}
Assert-True ($rootCaCount -eq 1) "phase3b2_p0_v2_root_ca_invalid"

$firewallGroup = "NLL Phase3B2 Isolation"
$rules = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop)
Assert-True ($rules.Count -eq 16 -and @($rules | Where-Object {
            [string]$_.Direction -cne "Outbound" -or
            [string]$_.Action -cne "Block" -or -not $_.Enabled
        }).Count -eq 0) "phase3b2_p0_v2_firewall_invalid"

$upPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ "Up").Count
$systemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
$networkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
$ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
$ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
Assert-True ($upPhysicalNetworkAdapterCount -eq 1 -and $systemNetworkAvailable -and
    $networkProfileCount -eq 1 -and $ipv4DefaultRouteCount -eq 0 -and
    $ipv6DefaultRouteCount -eq 0) "phase3b2_p0_v2_private_network_shape_invalid"

$verificationPath = Join-Path $baseEvidenceRoot `
    "applied-verification-private-v2.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $verificationPath)) `
    "phase3b2_p0_v2_verification_receipt_exists"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-applied-verification/v2"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0AppliedVerified = $true
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 =
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    clientCertificateBundleMemberCount = 2
    gameCertificateAppliedSha256 = Get-Sha256Hex $gameCertificatePath
    launcherCertificateOriginalByteLength = 209309
    launcherCertificateOriginalSha256 =
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
    launcherCertificateAppliedByteLength = 210620
    launcherCertificateAppliedSha256 = Get-Sha256Hex $launcherCertificatePath
    baseBackupManifestSha256 = Get-Sha256Hex $baseBackupManifestPath
    baseAppliedManifestSha256 = Get-Sha256Hex $baseAppliedManifestPath
    basePrivateVerificationSha256 = Get-Sha256Hex $basePrivateVerificationPath
    launcherBackupManifestSha256 = Get-Sha256Hex $launcherBackupManifestPath
    launcherAppliedManifestSha256 = Get-Sha256Hex $launcherAppliedManifestPath
    launcherExtensionReceiptSha256 = Get-Sha256Hex $launcherExtensionReceiptPath
    compositeRollbackScriptSha256 = Get-Sha256Hex $compositeRollbackPath
    mappedDomainCount = 17
    rootCaInstalledCount = $rootCaCount
    firewallRuleCount = $rules.Count
    firewallProgramCount = 16
    networkModeCode = "private_vm_only_no_gateway"
    systemNetworkAvailable = $systemNetworkAvailable
    upPhysicalNetworkAdapterCount = $upPhysicalNetworkAdapterCount
    networkProfileCount = $networkProfileCount
    ipv4DefaultRouteCount = $ipv4DefaultRouteCount
    ipv6DefaultRouteCount = $ipv6DefaultRouteCount
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $verificationPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
