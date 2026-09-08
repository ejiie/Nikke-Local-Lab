[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher",
    [string]$BackupRoot = "C:\NLL\Backups\Phase3B2\P0-v1"
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

function Write-BytesMeasured {
    param([string]$Path, [byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedSha256 = [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
    Assert-True ((Get-Item -LiteralPath $Path).Length -eq $Bytes.Length -and
        (Get-Sha256Hex $Path) -ceq $expectedSha256) "phase3b2_measured_byte_write_failed"
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
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

$clientExe = Join-Path $ClientRoot "nikke.exe"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_client_version_mismatch"
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
Assert-True ($profileReceipt.characterCount -eq 193 -and -not $profileReceipt.officialIdentityPersisted -and
    -not $profileReceipt.officialCredentialPersisted) "phase3b2_profile_receipt_invalid"

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$gameCertificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
)
$gameCertificates = @($gameCertificateCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
Assert-True ($gameCertificates.Count -eq 1) "phase3b2_game_certificate_bundle_shape_invalid"
$gameCertificatePath = $gameCertificates[0]
$gameSodiumPath = Join-Path $pluginsRoot "sodium.dll"
$caCerPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
$caPemPath = Join-Path $EpinelRoot "ServerSelector\myCA.pem"
$shimPath = Join-Path $EpinelRoot "ServerSelector.Desktop\bin\Release\net10.0\win-x64\sodium.dll"
$rollbackScript = "C:\NLL\Tools\rollback-phase3b2-p0-in-vm.ps1"

Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq 824 -and
    (Get-Sha256Hex $hostsPath) -ceq "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085") `
    "phase3b2_hosts_baseline_mismatch"
Assert-True ((Get-Item -LiteralPath $gameCertificatePath).Length -eq 212549 -and
    (Get-Sha256Hex $gameCertificatePath) -ceq "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d") `
    "phase3b2_certificate_baseline_mismatch"
Assert-True ((Get-Item -LiteralPath $gameSodiumPath).Length -eq 304128 -and
    (Get-Sha256Hex $gameSodiumPath) -ceq "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888") `
    "phase3b2_sodium_baseline_mismatch"
Assert-True ((Get-Item -LiteralPath $shimPath).Length -eq 358400 -and
    (Get-Sha256Hex $shimPath) -ceq "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662") `
    "phase3b2_shim_source_mismatch"
Assert-True ((Get-Item -LiteralPath $caCerPath).Length -eq 1266 -and
    (Get-Sha256Hex $caCerPath) -ceq "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda") `
    "phase3b2_ca_cer_source_mismatch"
Assert-True ((Get-Item -LiteralPath $caPemPath).Length -eq 1266 -and
    (Get-Sha256Hex $caPemPath) -ceq "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda") `
    "phase3b2_ca_pem_source_mismatch"
Assert-True (Test-Path -LiteralPath $rollbackScript -PathType Leaf) "phase3b2_rollback_script_missing"
Assert-True (-not (Test-Path -LiteralPath $BackupRoot)) "phase3b2_backup_root_already_exists"
$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
Assert-True (-not (Test-Path -LiteralPath $evidenceRoot)) "phase3b2_p0_evidence_already_exists"

$hostsOriginalAttributes = [int](Get-Item -LiteralPath $hostsPath).Attributes
$gameCertificateOriginalAttributes = [int](Get-Item -LiteralPath $gameCertificatePath).Attributes
$sodiumOriginalAttributes = [int](Get-Item -LiteralPath $gameSodiumPath).Attributes
$targetDomains = @(
    "global-lobby.nikke-kr.com", "cloud.nikke-kr.com", "jp-lobby.nikke-kr.com",
    "us-lobby.nikke-kr.com", "kr-lobby.nikke-kr.com", "sea-lobby.nikke-kr.com",
    "hmt-lobby.nikke-kr.com", "aws-na-dr.intlgame.com", "sg-vas.intlgame.com",
    "aws-na.intlgame.com", "na-community.playerinfinite.com", "common-web.intlgame.com",
    "li-sg.intlgame.com", "na.fleetlogd.com", "www.jupiterlauncher.com",
    "data-aws-na.intlgame.com", "sentry.io"
)
$hostsText = Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8
Assert-True (@($targetDomains | Where-Object { $hostsText.Contains($_) }).Count -eq 0) `
    "phase3b2_hosts_target_already_present"
$gameCertificateText = Get-Content -LiteralPath $gameCertificatePath -Raw -Encoding UTF8
Assert-True (-not $gameCertificateText.Contains("Good SSL Ca")) "phase3b2_certificate_already_patched"
$firewallGroup = "NLL Phase3B2 Isolation"
Assert-True (@(Get-NetFirewallRule -Group $firewallGroup -ErrorAction SilentlyContinue).Count -eq 0) `
    "phase3b2_firewall_rules_already_present"

$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    Assert-True (@($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count -eq 0) `
        "phase3b2_root_ca_already_present"
}
finally {
    $store.Close()
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$hostsBackup = Join-Path $BackupRoot "hosts.original.bin"
$certificateBackup = Join-Path $BackupRoot "game-certificate.original.bin"
$sodiumBackup = Join-Path $BackupRoot "sodium.original.bin"
[IO.File]::WriteAllBytes($hostsBackup, [IO.File]::ReadAllBytes($hostsPath))
[IO.File]::WriteAllBytes($certificateBackup, [IO.File]::ReadAllBytes($gameCertificatePath))
[IO.File]::WriteAllBytes($sodiumBackup, [IO.File]::ReadAllBytes($gameSodiumPath))
Assert-True ((Get-Sha256Hex $hostsBackup) -ceq "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085") `
    "phase3b2_hosts_backup_verification_failed"
Assert-True ((Get-Sha256Hex $certificateBackup) -ceq "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d") `
    "phase3b2_certificate_backup_verification_failed"
Assert-True ((Get-Sha256Hex $sodiumBackup) -ceq "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888") `
    "phase3b2_sodium_backup_verification_failed"

$trustedManifest = [ordered]@{
    contractId = "nll/phase3b2-p0-trusted-backup-manifest/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    hostsPath = $hostsPath
    gameCertificatePath = $gameCertificatePath
    gameSodiumPath = $gameSodiumPath
    caCerPath = $caCerPath
    caPemPath = $caPemPath
    shimPath = $shimPath
    rollbackScriptPath = $rollbackScript
    hostsOriginalAttributes = $hostsOriginalAttributes
    gameCertificateOriginalAttributes = $gameCertificateOriginalAttributes
    sodiumOriginalAttributes = $sodiumOriginalAttributes
    firewallGroup = $firewallGroup
    hostBackupSha256 = Get-Sha256Hex $hostsBackup
    gameCertificateBackupSha256 = Get-Sha256Hex $certificateBackup
    sodiumBackupSha256 = Get-Sha256Hex $sodiumBackup
    rollbackScriptSha256 = Get-Sha256Hex $rollbackScript
}
$trustedManifestPath = Join-Path $BackupRoot "trusted-backup-manifest.json"
Write-Utf8NoBom $trustedManifestPath (($trustedManifest | ConvertTo-Json) + "`n")

$mutationStarted = $false
$mutationStage = "not_started"
try {
    $mutationStarted = $true
    $mutationStage = "system_hosts_apply"
    $hostsBlock = "`r`n# begin NLL Phase3B2 entries`r`n" +
        (($targetDomains | ForEach-Object { "127.0.0.1 $_" }) -join "`r`n") +
        "`r`n# end NLL Phase3B2 entries`r`n"
    $hostsBytes = [IO.File]::ReadAllBytes($hostsPath)
    $hostsAppendBytes = [Text.Encoding]::ASCII.GetBytes($hostsBlock)
    $newHostsBytes = [byte[]]::new($hostsBytes.Length + $hostsAppendBytes.Length)
    [Array]::Copy($hostsBytes, 0, $newHostsBytes, 0, $hostsBytes.Length)
    [Array]::Copy($hostsAppendBytes, 0, $newHostsBytes, $hostsBytes.Length, $hostsAppendBytes.Length)
    Write-BytesMeasured $hostsPath $newHostsBytes

    $mutationStage = "root_ca_apply"
    $store = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($ca) } finally { $store.Close() }

    $mutationStage = "client_certificate_bundle_apply"
    $certificateBytes = [IO.File]::ReadAllBytes($gameCertificatePath)
    $certificateMarkerBytes = [Text.Encoding]::ASCII.GetBytes("`nGood SSL Ca`n===============================`n")
    $caPemBytes = [IO.File]::ReadAllBytes($caPemPath)
    $newCertificateBytes = [byte[]]::new(
        $certificateBytes.Length + $certificateMarkerBytes.Length + $caPemBytes.Length)
    [Array]::Copy($certificateBytes, 0, $newCertificateBytes, 0, $certificateBytes.Length)
    [Array]::Copy($certificateMarkerBytes, 0, $newCertificateBytes, $certificateBytes.Length,
        $certificateMarkerBytes.Length)
    [Array]::Copy($caPemBytes, 0, $newCertificateBytes,
        $certificateBytes.Length + $certificateMarkerBytes.Length, $caPemBytes.Length)
    Write-BytesMeasured $gameCertificatePath $newCertificateBytes
    $mutationStage = "native_compatibility_shim_apply"
    Write-BytesMeasured $gameSodiumPath ([IO.File]::ReadAllBytes($shimPath))

    $mutationStage = "firewall_program_inventory"
    $programs = @(
        Get-ChildItem -LiteralPath "E:\" -Recurse -File -Filter "*.exe" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
        Join-Path $serverRoot "EpinelPS.exe"
    ) | Sort-Object -Unique
    Assert-True ($programs.Count -ge 6 -and $programs.Count -le 64) "phase3b2_firewall_program_inventory_invalid"
    $ruleOrdinal = 0
    foreach ($program in $programs) {
        Assert-True (Test-Path -LiteralPath $program -PathType Leaf) "phase3b2_firewall_program_missing"
        $ruleOrdinal++
        $mutationStage = "firewall_rule_apply_{0:D3}" -f $ruleOrdinal
        New-NetFirewallRule -Name ("NLL-P3B2-Block-{0:D3}" -f $ruleOrdinal) `
            -DisplayName ("NLL Phase3B2 outbound block {0:D3}" -f $ruleOrdinal) `
            -Group $firewallGroup -Direction Outbound -Action Block -Enabled True -Profile Any `
            -Program $program | Out-Null
    }

    $mutationStage = "applied_state_verification"
    $verifyStore = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $verifyStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        $rootCaCount = @($verifyStore.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
    }
    finally { $verifyStore.Close() }
    $firewallRuleCount = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop).Count
    Assert-True ($rootCaCount -eq 1) "phase3b2_root_ca_apply_failed"
    Assert-True ($firewallRuleCount -eq $programs.Count) "phase3b2_firewall_rule_count_mismatch"
    Assert-True ((Get-Item -LiteralPath $gameSodiumPath).Length -eq 358400 -and
        (Get-Sha256Hex $gameSodiumPath) -ceq "54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662") `
        "phase3b2_sodium_apply_failed"
}
catch {
    $failureRecord = $_
    $failedStage = $mutationStage
    if ($mutationStarted) {
        & $rollbackScript -EpinelRoot $EpinelRoot -ClientRoot $ClientRoot `
            -BackupRoot $BackupRoot -AutomaticFailureRollback
    }
    $failureEvidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
    New-Item -ItemType Directory -Path $failureEvidenceRoot -Force | Out-Null
    $failureReceipt = [ordered]@{
        contractId = "nll/phase3b2-p0-mutation-failure/v1"
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedStageCode = $failedStage
        exceptionType = $failureRecord.Exception.GetType().FullName
        failureMessage = $failureRecord.Exception.Message
        automaticRollbackCompleted = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom (Join-Path $failureEvidenceRoot "mutation-failure.receipt.json") `
        (($failureReceipt | ConvertTo-Json) + "`n")
    throw "phase3b2_p0_mutation_failed:${failedStage}:$($failureRecord.Exception.Message)"
}

New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$trustedApplied = [ordered]@{
    contractId = "nll/phase3b2-p0-trusted-applied-manifest/v1"
    systemHosts = [ordered]@{
        originalByteLength = 824
        originalSha256 = "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085"
        appliedByteLength = (Get-Item -LiteralPath $hostsPath).Length
        appliedSha256 = Get-Sha256Hex $hostsPath
        mappedDomainCount = $targetDomains.Count
    }
    rootCa = [ordered]@{ sourceByteLength = 1266; sourceSha256 = Get-Sha256Hex $caCerPath; installedCount = 1 }
    clientCertificateBundle = [ordered]@{
        originalByteLength = 212549
        originalSha256 = "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d"
        appliedByteLength = (Get-Item -LiteralPath $gameCertificatePath).Length
        appliedSha256 = Get-Sha256Hex $gameCertificatePath
    }
    nativeCompatibilityShim = [ordered]@{
        originalByteLength = 304128
        originalSha256 = "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888"
        appliedByteLength = (Get-Item -LiteralPath $gameSodiumPath).Length
        appliedSha256 = Get-Sha256Hex $gameSodiumPath
    }
    firewall = [ordered]@{ groupCode = "nll_phase3b2_isolation"; ruleCount = $firewallRuleCount }
    rollback = [ordered]@{ scriptSha256 = Get-Sha256Hex $rollbackScript; prepared = $true }
}
$trustedAppliedPath = Join-Path $evidenceRoot "trusted-applied-manifest.json"
Write-Utf8NoBom $trustedAppliedPath (($trustedApplied | ConvertTo-Json -Depth 10) + "`n")
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-mutation-preparation/v1"
    preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    systemHostsStatusCode = "sealed_with_backup_and_rollback"
    rootCaStatusCode = "sealed_with_backup_and_rollback"
    clientCertificateBundleStatusCode = "sealed_with_backup_and_rollback"
    nativeCompatibilityShimStatusCode = "sealed_with_backup_and_rollback"
    mappedDomainCount = $targetDomains.Count
    firewallRuleCount = $firewallRuleCount
    backupManifestByteLength = (Get-Item -LiteralPath $trustedManifestPath).Length
    backupManifestSha256 = Get-Sha256Hex $trustedManifestPath
    appliedManifestByteLength = (Get-Item -LiteralPath $trustedAppliedPath).Length
    appliedManifestSha256 = Get-Sha256Hex $trustedAppliedPath
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $evidenceRoot "mutation-preparation.receipt.json"
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
