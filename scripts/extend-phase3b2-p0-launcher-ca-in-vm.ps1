[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
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

function Write-BytesMeasured {
    param([string]$Path, [byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedSha256 = (($algorithm.ComputeHash($Bytes) |
                ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $algorithm.Dispose()
    }
    [IO.File]::WriteAllBytes($Path, $Bytes)
    Assert-True ((Get-Item -LiteralPath $Path).Length -eq $Bytes.Length -and
        (Get-Sha256Hex $Path) -ceq $expectedSha256) "phase3b2_launcher_ca_measured_write_failed"
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

$baseBackupManifestPath = Join-Path $BaseBackupRoot "trusted-backup-manifest.json"
$baseEvidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
$baseAppliedManifestPath = Join-Path $baseEvidenceRoot "trusted-applied-manifest.json"
$basePrivateVerificationPath = Join-Path $baseEvidenceRoot "applied-verification-private-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $baseBackupManifestPath).Length -eq 1240 -and
    (Get-Sha256Hex $baseBackupManifestPath) -ceq
        "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a") `
    "phase3b2_launcher_ca_base_backup_manifest_drift"
Assert-True ((Get-Item -LiteralPath $baseAppliedManifestPath).Length -eq 1961 -and
    (Get-Sha256Hex $baseAppliedManifestPath) -ceq
        "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46") `
    "phase3b2_launcher_ca_base_applied_manifest_drift"
Assert-True ((Get-Item -LiteralPath $basePrivateVerificationPath).Length -eq 1379 -and
    (Get-Sha256Hex $basePrivateVerificationPath) -ceq
        "15c9161833934850ce722f54cbd167383d59059345cf18268021ad2808c3fb61") `
    "phase3b2_launcher_ca_base_private_verification_drift"

$baseBackupManifest = Get-Content -LiteralPath $baseBackupManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($baseBackupManifest.contractId -ceq "nll/phase3b2-p0-trusted-backup-manifest/v1") `
    "phase3b2_launcher_ca_base_backup_manifest_invalid"
$baseRollbackScriptPath = [string]$baseBackupManifest.rollbackScriptPath
Assert-True (Test-Path -LiteralPath $baseRollbackScriptPath -PathType Leaf) `
    "phase3b2_launcher_ca_base_rollback_missing"
Assert-True ((Get-Sha256Hex $baseRollbackScriptPath) -ceq
    [string]$baseBackupManifest.rollbackScriptSha256) "phase3b2_launcher_ca_base_rollback_drift"

$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
)
$launcherCertificates = @(
    $launcherCertificateCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
)
Assert-True ($launcherCertificates.Count -eq 1) "phase3b2_launcher_certificate_bundle_shape_invalid"
$launcherCertificatePath = $launcherCertificates[0]
Assert-True ((Get-Item -LiteralPath $launcherCertificatePath).Length -eq 209309 -and
    (Get-Sha256Hex $launcherCertificatePath) -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
    "phase3b2_launcher_certificate_baseline_mismatch"
$launcherCertificateText = Get-Content -LiteralPath $launcherCertificatePath -Raw -Encoding UTF8
Assert-True (-not $launcherCertificateText.Contains("Good SSL Ca")) `
    "phase3b2_launcher_certificate_already_patched"

$caPemPath = Join-Path $EpinelRoot "ServerSelector\myCA.pem"
Assert-True ((Get-Item -LiteralPath $caPemPath).Length -eq 1266 -and
    (Get-Sha256Hex $caPemPath) -ceq
        "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda") `
    "phase3b2_launcher_ca_pem_source_mismatch"
$compositeRollbackScriptPath = "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-in-vm.ps1"
Assert-True (Test-Path -LiteralPath $compositeRollbackScriptPath -PathType Leaf) `
    "phase3b2_launcher_ca_composite_rollback_missing"

$launcherEvidenceRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0-launcher-ca-v1"
Assert-True (-not (Test-Path -LiteralPath $LauncherBackupRoot)) `
    "phase3b2_launcher_ca_backup_root_already_exists"
Assert-True (-not (Test-Path -LiteralPath $launcherEvidenceRoot)) `
    "phase3b2_launcher_ca_evidence_already_exists"

New-Item -ItemType Directory -Path $LauncherBackupRoot -Force | Out-Null
$launcherCertificateBackupPath = Join-Path $LauncherBackupRoot `
    "launcher-certificate.original.bin"
[IO.File]::WriteAllBytes($launcherCertificateBackupPath,
    [IO.File]::ReadAllBytes($launcherCertificatePath))
Assert-True ((Get-Item -LiteralPath $launcherCertificateBackupPath).Length -eq 209309 -and
    (Get-Sha256Hex $launcherCertificateBackupPath) -ceq
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
    "phase3b2_launcher_certificate_backup_verification_failed"

$launcherCertificateOriginalAttributes =
    [int](Get-Item -LiteralPath $launcherCertificatePath).Attributes
$trustedBackupManifest = [ordered]@{
    contractId = "nll/phase3b2-p0-launcher-certificate-backup-manifest/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    launcherCertificatePath = $launcherCertificatePath
    launcherCertificateOriginalAttributes = $launcherCertificateOriginalAttributes
    launcherCertificateOriginalByteLength = 209309
    launcherCertificateOriginalSha256 =
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
    launcherCertificateBackupSha256 = Get-Sha256Hex $launcherCertificateBackupPath
    caPemPath = $caPemPath
    caPemSha256 = Get-Sha256Hex $caPemPath
    baseBackupManifestSha256 = Get-Sha256Hex $baseBackupManifestPath
    baseAppliedManifestSha256 = Get-Sha256Hex $baseAppliedManifestPath
    basePrivateVerificationSha256 = Get-Sha256Hex $basePrivateVerificationPath
    baseRollbackScriptPath = $baseRollbackScriptPath
    baseRollbackScriptSha256 = Get-Sha256Hex $baseRollbackScriptPath
    compositeRollbackScriptPath = $compositeRollbackScriptPath
    compositeRollbackScriptSha256 = Get-Sha256Hex $compositeRollbackScriptPath
}
$trustedBackupManifestPath = Join-Path $LauncherBackupRoot `
    "trusted-launcher-certificate-backup-manifest.json"
Write-Utf8NoBom $trustedBackupManifestPath (($trustedBackupManifest | ConvertTo-Json) + "`n")

$mutationStarted = $false
try {
    $mutationStarted = $true
    $certificateBytes = [IO.File]::ReadAllBytes($launcherCertificatePath)
    $certificateMarkerBytes =
        [Text.Encoding]::ASCII.GetBytes("`nGood SSL Ca`n===============================`n")
    $caPemBytes = [IO.File]::ReadAllBytes($caPemPath)
    $newCertificateBytes = [byte[]]::new(
        $certificateBytes.Length + $certificateMarkerBytes.Length + $caPemBytes.Length)
    [Array]::Copy($certificateBytes, 0, $newCertificateBytes, 0, $certificateBytes.Length)
    [Array]::Copy($certificateMarkerBytes, 0, $newCertificateBytes,
        $certificateBytes.Length, $certificateMarkerBytes.Length)
    [Array]::Copy($caPemBytes, 0, $newCertificateBytes,
        $certificateBytes.Length + $certificateMarkerBytes.Length, $caPemBytes.Length)
    Write-BytesMeasured $launcherCertificatePath $newCertificateBytes

    $appliedText = Get-Content -LiteralPath $launcherCertificatePath -Raw -Encoding UTF8
    Assert-True (@([regex]::Matches($appliedText, "Good SSL Ca")).Count -eq 1) `
        "phase3b2_launcher_certificate_marker_invalid"
    Assert-True ((Get-Item -LiteralPath $launcherCertificatePath).Length -eq 210620) `
        "phase3b2_launcher_certificate_applied_length_mismatch"
}
catch {
    $failureRecord = $_
    if ($mutationStarted) {
        [IO.File]::WriteAllBytes($launcherCertificatePath,
            [IO.File]::ReadAllBytes($launcherCertificateBackupPath))
        [IO.File]::SetAttributes($launcherCertificatePath,
            [IO.FileAttributes]$launcherCertificateOriginalAttributes)
        Assert-True ((Get-Item -LiteralPath $launcherCertificatePath).Length -eq 209309 -and
            (Get-Sha256Hex $launcherCertificatePath) -ceq
                "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65") `
            "phase3b2_launcher_ca_automatic_rollback_failed"
    }
    New-Item -ItemType Directory -Path $launcherEvidenceRoot -Force | Out-Null
    $failureReceipt = [ordered]@{
        contractId = "nll/phase3b2-p0-launcher-certificate-mutation-failure/v1"
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failureMessage = $failureRecord.Exception.Message
        launcherCertificateRestored = $mutationStarted
        baseP0Preserved = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom (Join-Path $launcherEvidenceRoot "mutation-failure.receipt.json") `
        (($failureReceipt | ConvertTo-Json) + "`n")
    throw "phase3b2_launcher_ca_extension_failed:$($failureRecord.Exception.Message)"
}

New-Item -ItemType Directory -Path $launcherEvidenceRoot -Force | Out-Null
$trustedAppliedManifest = [ordered]@{
    contractId = "nll/phase3b2-p0-launcher-certificate-applied-manifest/v1"
    clientCertificateBundleMemberCount = 2
    launcherCertificateBundle = [ordered]@{
        originalByteLength = 209309
        originalSha256 =
            "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
        appliedByteLength = (Get-Item -LiteralPath $launcherCertificatePath).Length
        appliedSha256 = Get-Sha256Hex $launcherCertificatePath
    }
    baseBackupManifestSha256 = Get-Sha256Hex $baseBackupManifestPath
    baseAppliedManifestSha256 = Get-Sha256Hex $baseAppliedManifestPath
    basePrivateVerificationSha256 = Get-Sha256Hex $basePrivateVerificationPath
    launcherBackupManifestSha256 = Get-Sha256Hex $trustedBackupManifestPath
    compositeRollbackScriptSha256 = Get-Sha256Hex $compositeRollbackScriptPath
    rollbackPrepared = $true
}
$trustedAppliedManifestPath = Join-Path $launcherEvidenceRoot `
    "trusted-launcher-certificate-applied-manifest.json"
Write-Utf8NoBom $trustedAppliedManifestPath `
    (($trustedAppliedManifest | ConvertTo-Json -Depth 6) + "`n")

$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-launcher-certificate-extension/v1"
    preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    statusCode = "sealed_with_backup_and_composite_rollback"
    clientCertificateBundleMemberCount = 2
    launcherCertificateOriginalByteLength = 209309
    launcherCertificateOriginalSha256 =
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65"
    launcherCertificateAppliedByteLength = (Get-Item -LiteralPath $launcherCertificatePath).Length
    launcherCertificateAppliedSha256 = Get-Sha256Hex $launcherCertificatePath
    backupManifestByteLength = (Get-Item -LiteralPath $trustedBackupManifestPath).Length
    backupManifestSha256 = Get-Sha256Hex $trustedBackupManifestPath
    appliedManifestByteLength = (Get-Item -LiteralPath $trustedAppliedManifestPath).Length
    appliedManifestSha256 = Get-Sha256Hex $trustedAppliedManifestPath
    compositeRollbackScriptSha256 = Get-Sha256Hex $compositeRollbackScriptPath
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $launcherEvidenceRoot "extension.receipt.json"
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
