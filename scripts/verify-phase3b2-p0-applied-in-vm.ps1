[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$BackupRoot = "C:\NLL\Backups\Phase3B2\P0-v1",
    [ValidateSet("disconnected", "private_vm_only_no_gateway")]
    [string]$NetworkModeCode = "disconnected"
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

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$clientExe = Join-Path $ClientRoot "nikke.exe"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_client_version_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
    "519c3db51ec24ca19307e93e85acde7885928a72") "phase3b2_external_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
    "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a") "phase3b2_external_tree_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_external_checkout_not_clean"
$externalV4ReceiptPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\external-v4\external-v4-build.receipt.json"
Assert-True (Test-Path -LiteralPath $externalV4ReceiptPath -PathType Leaf) `
    "phase3b2_external_v4_build_receipt_missing"
$externalV4Receipt = Get-Content -LiteralPath $externalV4ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($externalV4Receipt.contractId -ceq "nll/phase3b2-external-v4-build/v1" -and
    $externalV4Receipt.externalHead -ceq "519c3db51ec24ca19307e93e85acde7885928a72" -and
    $externalV4Receipt.externalTree -ceq "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    $externalV4Receipt.checkoutClean -and $externalV4Receipt.dotnetSdkVersion -ceq "10.0.400" -and
    $externalV4Receipt.selectedManagerPassedCount -eq 64 -and
    $externalV4Receipt.handlerIsolationPassedCount -eq 5 -and
    $externalV4Receipt.focusedTestFailedCount -eq 0 -and
    -not $externalV4Receipt.localOnlyHttp3Enabled -and
    -not $externalV4Receipt.localOnlyAssetCachePathLoggingEnabled -and
    $externalV4Receipt.buildFileCount -eq 581 -and
    $externalV4Receipt.buildManifestSha256 -ceq
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37" -and
    -not $externalV4Receipt.serverExecutionStarted -and -not $externalV4Receipt.clientExecutionStarted) `
    "phase3b2_external_v4_build_receipt_invalid"

$backupManifestPath = Join-Path $BackupRoot "trusted-backup-manifest.json"
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
Assert-True ((Get-Item -LiteralPath $backupManifestPath).Length -eq 1240 -and
    (Get-Sha256Hex $backupManifestPath) -ceq "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a") `
    "phase3b2_backup_manifest_invalid"

$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
$mutationReceiptPath = Join-Path $evidenceRoot "mutation-preparation.receipt.json"
$appliedManifestPath = Join-Path $evidenceRoot "trusted-applied-manifest.json"
Assert-True (Test-Path -LiteralPath $mutationReceiptPath -PathType Leaf) `
    "phase3b2_mutation_receipt_missing"
Assert-True ((Get-Item -LiteralPath $appliedManifestPath).Length -eq 1961 -and
    (Get-Sha256Hex $appliedManifestPath) -ceq "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46") `
    "phase3b2_applied_manifest_invalid"
$mutationReceipt = Get-Content -LiteralPath $mutationReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($mutationReceipt.contractId -ceq "nll/phase3b2-p0-mutation-preparation/v1" -and
    $mutationReceipt.mappedDomainCount -eq 17 -and $mutationReceipt.firewallRuleCount -eq 16 -and
    -not $mutationReceipt.serverExecutionStarted -and -not $mutationReceipt.clientExecutionStarted) `
    "phase3b2_mutation_receipt_invalid"
$appliedManifest = Get-Content -LiteralPath $appliedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
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
    $domainLines = @($hostsLines | Where-Object { $_ -match "(^|\s)$([regex]::Escape($domain))(\s|$)" })
    Assert-True ($domainLines.Count -eq 1 -and $domainLines[0] -match "^\s*127\.0\.0\.1\s+") `
        "phase3b2_hosts_target_binding_invalid"
}
Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq $appliedManifest.systemHosts.appliedByteLength -and
    (Get-Sha256Hex $hostsPath) -ceq $appliedManifest.systemHosts.appliedSha256) `
    "phase3b2_hosts_applied_digest_mismatch"

$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$gameCertificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
)
$gameCertificates = @($gameCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Assert-True ($gameCertificates.Count -eq 1) "phase3b2_game_certificate_bundle_shape_invalid"
$gameCertificatePath = $gameCertificates[0]
$gameCertificateText = Get-Content -LiteralPath $gameCertificatePath -Raw -Encoding UTF8
Assert-True (@([regex]::Matches($gameCertificateText, "Good SSL Ca")).Count -eq 1) `
    "phase3b2_game_certificate_marker_invalid"
Assert-True ((Get-Item -LiteralPath $gameCertificatePath).Length -eq
        $appliedManifest.clientCertificateBundle.appliedByteLength -and
    (Get-Sha256Hex $gameCertificatePath) -ceq
        $appliedManifest.clientCertificateBundle.appliedSha256) `
    "phase3b2_game_certificate_applied_digest_mismatch"

$gameSodiumPath = Join-Path $pluginsRoot "sodium.dll"
Assert-True ((Get-Item -LiteralPath $gameSodiumPath).Length -eq 358400 -and
    (Get-Sha256Hex $gameSodiumPath) -ceq "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662") `
    "phase3b2_native_shim_applied_digest_mismatch"

$caCerPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    $rootCaCount = @($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
}
finally { $store.Close() }
Assert-True ($rootCaCount -eq 1) "phase3b2_root_ca_count_invalid"

$firewallGroup = "NLL Phase3B2 Isolation"
$rules = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop)
Assert-True ($rules.Count -eq 16) "phase3b2_firewall_rule_count_invalid"
Assert-True (@($rules | Where-Object {
            [string]$_.Direction -cne "Outbound" -or [string]$_.Action -cne "Block" -or -not $_.Enabled
        }).Count -eq 0) "phase3b2_firewall_rule_shape_invalid"
$actualPrograms = @($rules | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program |
        Sort-Object -Unique)
$expectedPrograms = @(
    Get-ChildItem -LiteralPath "E:\" -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    Join-Path $serverRoot "EpinelPS.exe"
) | Sort-Object -Unique
Assert-True ($expectedPrograms.Count -eq 16 -and $actualPrograms.Count -eq 16 -and
    @(Compare-Object -ReferenceObject $expectedPrograms -DifferenceObject $actualPrograms).Count -eq 0) `
    "phase3b2_firewall_program_binding_invalid"

$upPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ "Up").Count
$systemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
$networkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
$ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
$ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
$networkPreparationReceiptSha256 = $null
if ($NetworkModeCode -ceq "disconnected") {
    Assert-True ($upPhysicalNetworkAdapterCount -eq 0 -and -not $systemNetworkAvailable -and
        $networkProfileCount -eq 0) "phase3b2_guest_disconnected_network_shape_invalid"
}
else {
    $networkPreparationPath = Join-Path (Split-Path $evidenceRoot -Parent) `
        "network-private-v1\network-preparation.receipt.json"
    Assert-True (Test-Path -LiteralPath $networkPreparationPath -PathType Leaf) `
        "phase3b2_private_network_preparation_receipt_missing"
    $networkPreparation = Get-Content -LiteralPath $networkPreparationPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($networkPreparation.contractId -ceq "nll/phase3b2-private-network-preparation/v1" -and
        $networkPreparation.networkModeCode -ceq "private_vm_only_no_gateway" -and
        $networkPreparation.hostPrivateSwitchReceiptByteLength -eq 814 -and
        $networkPreparation.hostPrivateSwitchReceiptSha256 -ceq
            "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748" -and
        $networkPreparation.systemNetworkAvailable -and
        $networkPreparation.upPhysicalNetworkAdapterCount -eq 1 -and
        $networkPreparation.networkProfileCount -eq 1 -and
        $networkPreparation.ipv4DefaultRouteCount -eq 0 -and
        $networkPreparation.ipv6DefaultRouteCount -eq 0 -and
        $networkPreparation.ipv4DnsServerCount -eq 0 -and
        $networkPreparation.mappedLoopbackDomainCount -eq 17 -and
        -not $networkPreparation.externalUplinkPresent -and
        -not $networkPreparation.hostVirtualAdapterPresent -and
        -not $networkPreparation.natConfigured -and
        -not $networkPreparation.serverExecutionStarted -and
        -not $networkPreparation.clientExecutionStarted) `
        "phase3b2_private_network_preparation_receipt_invalid"
    Assert-True ($upPhysicalNetworkAdapterCount -eq 1 -and $systemNetworkAvailable -and
        $networkProfileCount -eq 1 -and $ipv4DefaultRouteCount -eq 0 -and
        $ipv6DefaultRouteCount -eq 0) "phase3b2_guest_private_network_shape_invalid"
    $networkPreparationReceiptSha256 = Get-Sha256Hex $networkPreparationPath
}

$previousRollbackEvidence = Join-Path (Split-Path $evidenceRoot -Parent) `
    "p0-stale-auto-rollback-20260821T181211Z-fd38b8b\rollback.receipt.json"
Assert-True ((Get-Sha256Hex $previousRollbackEvidence) -ceq
    "fd38b8b1c1568e9276b0725ab92bd7aa38c625ec300bdaea1203061ac33cb642") `
    "phase3b2_previous_rollback_evidence_missing"

$receipt = [ordered]@{
    contractId = if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-p0-applied-verification/v3"
    } else {
        "nll/phase3b2-p0-private-applied-verification/v1"
    }
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0AppliedVerified = $true
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 = "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    mappedDomainCount = 17
    rootCaInstalledCount = $rootCaCount
    firewallRuleCount = $rules.Count
    firewallProgramCount = $actualPrograms.Count
    networkModeCode = $NetworkModeCode
    systemNetworkAvailable = $systemNetworkAvailable
    upPhysicalNetworkAdapterCount = $upPhysicalNetworkAdapterCount
    networkProfileCount = $networkProfileCount
    ipv4DefaultRouteCount = $ipv4DefaultRouteCount
    ipv6DefaultRouteCount = $ipv6DefaultRouteCount
    privateNetworkPreparationReceiptSha256 = $networkPreparationReceiptSha256
    backupManifestSha256 = Get-Sha256Hex $backupManifestPath
    appliedManifestSha256 = Get-Sha256Hex $appliedManifestPath
    previousAutomaticRollbackEvidencePreserved = $true
    credentialBearingGuestCopyPresent = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$verificationPath = Join-Path $evidenceRoot $(if ($NetworkModeCode -ceq "disconnected") {
        "applied-verification-v3.receipt.json"
    } else {
        "applied-verification-private-v1.receipt.json"
    })
Assert-True (-not (Test-Path -LiteralPath $verificationPath)) `
    "phase3b2_applied_verification_receipt_already_exists"
Write-Utf8NoBom $verificationPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
