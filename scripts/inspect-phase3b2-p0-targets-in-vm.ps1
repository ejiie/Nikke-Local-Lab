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

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_already_started"
Assert-True (-not (Test-Path -LiteralPath "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_credential_bearing_guest_copy_present"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
    "519c3db51ec24ca19307e93e85acde7885928a72") "phase3b2_external_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
    "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a") "phase3b2_external_tree_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_external_checkout_not_clean"

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbPath = Join-Path $serverRoot "db.json"
$profileReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\offline-synthetic-profile.receipt.json"
$contextPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\synthetic-context.json"
Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) "phase3b2_synthetic_database_missing"
Assert-True (Test-Path -LiteralPath $profileReceiptPath -PathType Leaf) "phase3b2_profile_receipt_missing"
Assert-True (Test-Path -LiteralPath $contextPath -PathType Leaf) "phase3b2_synthetic_context_missing"
$profileReceipt = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($profileReceipt.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
    $profileReceipt.characterCount -eq 193 -and -not $profileReceipt.officialIdentityPersisted -and
    -not $profileReceipt.officialCredentialPersisted -and -not $profileReceipt.serverExecutionStarted -and
    -not $profileReceipt.clientExecutionStarted) "phase3b2_profile_receipt_invalid"

$clientExe = Join-Path $ClientRoot "nikke.exe"
Assert-True (Test-Path -LiteralPath $clientExe -PathType Leaf) "phase3b2_client_executable_missing"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_client_version_mismatch"
$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$gameCertificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
)
$gameCertificates = @($gameCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Assert-True ($gameCertificates.Count -eq 1) "phase3b2_game_certificate_bundle_shape_invalid"
$gameCertificatePath = $gameCertificates[0]
$gameSodiumPath = Join-Path $pluginsRoot "sodium.dll"
Assert-True (Test-Path -LiteralPath $gameSodiumPath -PathType Leaf) "phase3b2_game_sodium_missing"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
)
$launcherCertificates = @($launcherCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

$caCerPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
$caPemPath = Join-Path $EpinelRoot "ServerSelector\myCA.pem"
$shimPath = Join-Path $EpinelRoot "ServerSelector.Desktop\bin\Release\net10.0\win-x64\sodium.dll"
Assert-True (Test-Path -LiteralPath $caCerPath -PathType Leaf) "phase3b2_selector_ca_cer_missing"
Assert-True (Test-Path -LiteralPath $caPemPath -PathType Leaf) "phase3b2_selector_ca_pem_missing"
Assert-True (Test-Path -LiteralPath $shimPath -PathType Leaf) "phase3b2_selector_sodium_shim_missing"

$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    $existingCaCount = @($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
}
finally {
    $store.Close()
}

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
Assert-True (Test-Path -LiteralPath $hostsPath -PathType Leaf) "phase3b2_hosts_missing"
$hostsText = Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8
$targetDomains = @(
    "global-lobby.nikke-kr.com", "cloud.nikke-kr.com", "jp-lobby.nikke-kr.com",
    "us-lobby.nikke-kr.com", "kr-lobby.nikke-kr.com", "sea-lobby.nikke-kr.com",
    "hmt-lobby.nikke-kr.com", "aws-na-dr.intlgame.com", "sg-vas.intlgame.com",
    "aws-na.intlgame.com", "na-community.playerinfinite.com", "common-web.intlgame.com",
    "li-sg.intlgame.com", "na.fleetlogd.com", "www.jupiterlauncher.com",
    "data-aws-na.intlgame.com", "sentry.io"
)
$existingTargetDomainCount = @($targetDomains | Where-Object { $hostsText.Contains($_) }).Count
$gameCertificateText = Get-Content -LiteralPath $gameCertificatePath -Raw -Encoding UTF8

$networkAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
$firewallRules = @(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" -ErrorAction SilentlyContinue)

[pscustomobject]@{
    P0TargetsReady                 = ($existingTargetDomainCount -eq 0 -and
        -not $gameCertificateText.Contains("Good SSL Ca") -and $existingCaCount -eq 0 -and
        $firewallRules.Count -eq 0)
    ClientBuild                    = "150.6.9"
    SyntheticProfileReady          = $true
    CredentialBearingGuestCopyPresent = $false
    HostsByteLength                = (Get-Item -LiteralPath $hostsPath).Length
    HostsSha256                    = Get-Sha256Hex $hostsPath
    ExistingTargetDomainCount      = $existingTargetDomainCount
    GameCertificateBundleCount     = $gameCertificates.Count
    GameCertificateByteLength      = (Get-Item -LiteralPath $gameCertificatePath).Length
    GameCertificateSha256          = Get-Sha256Hex $gameCertificatePath
    GameCertificateAlreadyPatched  = $gameCertificateText.Contains("Good SSL Ca")
    LauncherCertificateBundleCount = $launcherCertificates.Count
    OriginalSodiumByteLength       = (Get-Item -LiteralPath $gameSodiumPath).Length
    OriginalSodiumSha256           = Get-Sha256Hex $gameSodiumPath
    ShimByteLength                 = (Get-Item -LiteralPath $shimPath).Length
    ShimSha256                     = Get-Sha256Hex $shimPath
    CaCerByteLength                = (Get-Item -LiteralPath $caCerPath).Length
    CaCerSha256                    = Get-Sha256Hex $caCerPath
    CaPemByteLength                = (Get-Item -LiteralPath $caPemPath).Length
    CaPemSha256                    = Get-Sha256Hex $caPemPath
    ExistingRootCaCount            = $existingCaCount
    PhysicalNetworkAdapterCount    = $networkAdapters.Count
    UpPhysicalNetworkAdapterCount  = @($networkAdapters | Where-Object Status -CEQ "Up").Count
    ExistingIsolationRuleCount     = $firewallRules.Count
    ServerExecutionStarted         = $false
    ClientExecutionStarted         = $false
}
