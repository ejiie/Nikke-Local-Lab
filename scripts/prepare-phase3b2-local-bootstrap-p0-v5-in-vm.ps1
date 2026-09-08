[CmdletBinding()]
param(
    [string]$StagingRoot = "C:\NLL\Staging\LocalBootstrap-v1",
    [long]$BuildReceiptByteLength = 1200,
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$BuildReceiptSha256 =
        "5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11"
)

$ErrorActionPreference = "Stop"
$mutationStarted = $false

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
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"
Assert-True (@(Get-Process -Name EpinelPS, nikke_launcher, nikke,
        NikkeLocalLab.Phase3B2.LocalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    "phase3b2_local_bootstrap_p0_runtime_not_cold"
Assert-True (-not (Test-Path -LiteralPath `
        "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_credential_bearing_guest_copy_present"

$trustedRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$p0Root = Join-Path $trustedRoot "p0"
$evidenceRoot = Join-Path $trustedRoot "p0-local-bootstrap-v1"
$backupRoot = "C:\NLL\Backups\Phase3B2\P0-local-bootstrap-v1"
$bootstrapRoot = "C:\NLL\LocalBootstrap\v1"
$baseP0Path = Join-Path $p0Root `
    "applied-verification-private-v4.receipt.json"
$buildReceiptPath = Join-Path $StagingRoot `
    "local-bootstrap-build.receipt.json"
$artifactManifestPath = Join-Path $StagingRoot `
    "evidence\artifact.manifest.tsv"
$artifactStagingRoot = Join-Path $StagingRoot "artifact"
$rollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-local-bootstrap-in-vm.ps1"
$baseRollbackPath =
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
$firewallGroup = "NLL Phase3B2 Isolation"
$firewallRuleName = "NLL-P3B2-Block-017"
$bootstrapExeName = "NikkeLocalLab.Phase3B2.LocalBootstrap.exe"
$bootstrapExePath = Join-Path $bootstrapRoot $bootstrapExeName

Assert-True ((Get-Item -LiteralPath $baseP0Path).Length -eq 2210 -and
    (Get-Sha256Hex $baseP0Path) -ceq
        "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f") `
    "phase3b2_local_bootstrap_base_p0_receipt_drift"
$baseP0 = Get-Content -LiteralPath $baseP0Path -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($baseP0.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v4" -and
    $baseP0.p0AppliedVerified -and
    [int]$baseP0.firewallRuleCount -eq 16 -and
    [int]$baseP0.sqliteRuntimeMemberCount -eq 0 -and
    [bool]$baseP0.sqliteCredentialRebootstrapPrepared -and
    -not [bool]$baseP0.sqliteCredentialBindingVerified -and
    -not [bool]$baseP0.serverExecutionStarted -and
    -not [bool]$baseP0.clientExecutionStarted) `
    "phase3b2_local_bootstrap_base_p0_receipt_invalid"

Assert-True ((Get-Item -LiteralPath $buildReceiptPath).Length -eq
        $BuildReceiptByteLength -and
    (Get-Sha256Hex $buildReceiptPath) -ceq $BuildReceiptSha256) `
    "phase3b2_local_bootstrap_build_receipt_drift"
$buildReceipt = Get-Content -LiteralPath $buildReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($buildReceipt.contractId -ceq
        "nll/phase3b2-source-built-local-bootstrap/v1" -and
    $buildReceipt.upstreamHead -ceq
        "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3" -and
    $buildReceipt.upstreamTree -ceq
        "54b85eb6fbaa74feae0c6b441d66a5a703073ba3" -and
    $buildReceipt.upstreamCheckoutClean -and
    $buildReceipt.dotnetSdkVersion -ceq "10.0.400" -and
    [int]$buildReceipt.artifactMemberCount -eq 5 -and
    [long]$buildReceipt.artifactManifestByteLength -eq 561 -and
    $buildReceipt.artifactManifestSha256 -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70" -and
    -not [bool]$buildReceipt.officialLauncherBuilt -and
    -not [bool]$buildReceipt.antiCheatSubstitutionBuilt -and
    -not [bool]$buildReceipt.antiCheatSubstitutionApplied -and
    -not [bool]$buildReceipt.unityInitBuilt -and
    -not [bool]$buildReceipt.clientExecutionStarted) `
    "phase3b2_local_bootstrap_build_receipt_invalid"
Assert-True ((Get-Item -LiteralPath $artifactManifestPath).Length -eq 561 -and
    (Get-Sha256Hex $artifactManifestPath) -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70") `
    "phase3b2_local_bootstrap_artifact_manifest_drift"

$expectedArtifacts = [ordered]@{
    "NikkeLocalLab.Phase3B2.LocalBootstrap.deps.json" =
        [pscustomobject]@{ Length = 559; Sha256 = "c12f1556edd7efb53fe96d286001a1a5909f6c6fbc83019682dce7385d9435ad" }
    "NikkeLocalLab.Phase3B2.LocalBootstrap.dll" =
        [pscustomobject]@{ Length = 27648; Sha256 = "3d003678abb0e99fd02c13936f5594f9a3f9003c4c0f0c9df4a50367465a7305" }
    "NikkeLocalLab.Phase3B2.LocalBootstrap.exe" =
        [pscustomobject]@{ Length = 162816; Sha256 = "4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773" }
    "NikkeLocalLab.Phase3B2.LocalBootstrap.runtimeconfig.json" =
        [pscustomobject]@{ Length = 342; Sha256 = "c230a317a54dd960bcbeb5f347f52e18dc665a26f7efda2159fced9a5ac7e097" }
    "sail_api_impl64.dll" =
        [pscustomobject]@{ Length = 18944; Sha256 = "8e0a742c4092738e65cac47d58a3b0780bedff7fc4a0cac2b7abfeb989adad1d" }
}
Assert-True (@(Get-ChildItem -LiteralPath $artifactStagingRoot -File).Count -eq 5) `
    "phase3b2_local_bootstrap_staged_artifact_count_mismatch"
foreach ($name in $expectedArtifacts.Keys) {
    $path = Join-Path $artifactStagingRoot $name
    Assert-True ((Get-Item -LiteralPath $path).Length -eq
            [long]$expectedArtifacts[$name].Length -and
        (Get-Sha256Hex $path) -ceq [string]$expectedArtifacts[$name].Sha256) `
        "phase3b2_local_bootstrap_staged_artifact_drift"
}
$excludedArtifactCount = @(@("HelperDll.dll", "UnityInit.dll",
        "EpinelPSLauncher.exe") | Where-Object {
        Test-Path -LiteralPath (Join-Path $artifactStagingRoot $_)
    }).Count
Assert-True ($excludedArtifactCount -eq 0) `
    "phase3b2_local_bootstrap_excluded_artifact_present"
Assert-True (Test-Path -LiteralPath "E:\Unity\com_proximabeta_NIKKE" `
        -PathType Container) "phase3b2_local_bootstrap_resource_path_missing"
Assert-True ((Get-Item -LiteralPath "E:\NIKKE\game\nikke.exe").VersionInfo.FileVersion `
        -ceq "150.6.9") "phase3b2_local_bootstrap_client_version_drift"
Assert-True ((Test-Path -LiteralPath $rollbackPath -PathType Leaf) -and
    (Test-Path -LiteralPath $baseRollbackPath -PathType Leaf)) `
    "phase3b2_local_bootstrap_rollback_missing"
Assert-True (-not (Test-Path -LiteralPath $bootstrapRoot) -and
    -not (Test-Path -LiteralPath $backupRoot) -and
    -not (Test-Path -LiteralPath $evidenceRoot) -and
    @(Get-NetFirewallRule -Name $firewallRuleName `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop).Count -eq 16) `
    "phase3b2_local_bootstrap_p0_destination_not_cold"

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$backupManifest = [ordered]@{
    contractId = "nll/phase3b2-local-bootstrap-backup-manifest/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    bootstrapRootPreviouslyPresent = $false
    firewallRulePreviouslyPresent = $false
    baseP0V4ReceiptByteLength = 2210
    baseP0V4ReceiptSha256 =
        "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f"
    buildReceiptByteLength = $BuildReceiptByteLength
    buildReceiptSha256 = $BuildReceiptSha256
    artifactManifestByteLength = 561
    artifactManifestSha256 =
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70"
    rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
}
$backupManifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
Write-Utf8NoBom $backupManifestPath (($backupManifest | ConvertTo-Json) + "`n")

try {
    $mutationStarted = $true
    New-Item -ItemType Directory -Path $bootstrapRoot -Force | Out-Null
    foreach ($name in $expectedArtifacts.Keys) {
        Copy-Item -LiteralPath (Join-Path $artifactStagingRoot $name) `
            -Destination (Join-Path $bootstrapRoot $name)
    }
    New-NetFirewallRule -Name $firewallRuleName `
        -DisplayName "NLL Phase3B2 outbound block 017 local bootstrap" `
        -Group $firewallGroup -Direction Outbound -Action Block -Enabled True `
        -Profile Any -Program $bootstrapExePath | Out-Null

    Assert-True (@(Get-NetFirewallRule -Group $firewallGroup `
                -ErrorAction Stop).Count -eq 17 -and
        @(Get-NetFirewallRule -Name $firewallRuleName `
                -ErrorAction Stop).Count -eq 1) `
        "phase3b2_local_bootstrap_firewall_apply_failed"
    foreach ($name in $expectedArtifacts.Keys) {
        $path = Join-Path $bootstrapRoot $name
        Assert-True ((Get-Item -LiteralPath $path).Length -eq
                [long]$expectedArtifacts[$name].Length -and
            (Get-Sha256Hex $path) -ceq [string]$expectedArtifacts[$name].Sha256) `
            "phase3b2_local_bootstrap_applied_artifact_drift"
    }
}
catch {
    $failure = $_
    if ($mutationStarted) {
        & $rollbackPath -ExtensionOnly -AutomaticFailureRollback | Out-Null
    }
    throw "phase3b2_local_bootstrap_p0_apply_failed:$($failure.Exception.Message)"
}

try {
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
    Copy-Item -LiteralPath $buildReceiptPath -Destination (Join-Path `
        $evidenceRoot "local-bootstrap-build.receipt.json")
    Copy-Item -LiteralPath $artifactManifestPath -Destination (Join-Path `
        $evidenceRoot "artifact.manifest.tsv")
    $appliedManifest = [ordered]@{
    contractId = "nll/phase3b2-local-bootstrap-applied-manifest/v1"
    clientBootstrapModeCode = "source_built_sail_abi_local_bootstrap"
    memberCount = 5
    artifactManifestSha256 =
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70"
    sailAbiShimLoadMechanismCode = "game_owned_shared_memory_plugin_abi"
    firewallRuleNameCode = "nll_p3b2_block_017_local_bootstrap"
    firewallRuleCount = 17
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionApplied = $false
    rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
    }
    $appliedManifestPath = Join-Path $evidenceRoot `
        "trusted-applied-manifest.json"
    Write-Utf8NoBom $appliedManifestPath `
        (($appliedManifest | ConvertTo-Json) + "`n")

    $receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-applied-verification/v5"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0AppliedVerified = $true
    clientBuild = "150.6.9"
    externalHead = [string]$baseP0.externalHead
    externalTree = [string]$baseP0.externalTree
    externalBuildManifestSha256 = [string]$baseP0.externalBuildManifestSha256
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    clientBootstrapModeCode = "source_built_sail_abi_local_bootstrap"
    localBootstrapUpstreamHead = [string]$buildReceipt.upstreamHead
    localBootstrapUpstreamTree = [string]$buildReceipt.upstreamTree
    localBootstrapBuildReceiptByteLength = $BuildReceiptByteLength
    localBootstrapBuildReceiptSha256 = $BuildReceiptSha256
    localBootstrapArtifactMemberCount = 5
    localBootstrapArtifactManifestByteLength = 561
    localBootstrapArtifactManifestSha256 =
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70"
    sailAbiShimLoadMechanismCode = "game_owned_shared_memory_plugin_abi"
    officialLauncherRequired = $false
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionBuilt = $false
    antiCheatSubstitutionApplied = $false
    baseP0V4ReceiptByteLength = 2210
    baseP0V4ReceiptSha256 =
        "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f"
    launcherCertificateAppliedSha256 = [string]$baseP0.launcherCertificateAppliedSha256
    launcherPasswordPlaintextLength = [int]$baseP0.launcherPasswordPlaintextLength
    launcherPasswordStorageLength = [int]$baseP0.launcherPasswordStorageLength
    launcherPasswordStorageSchemeCode =
        [string]$baseP0.launcherPasswordStorageSchemeCode
    launcherPasswordRepresentationVerified =
        [bool]$baseP0.launcherPasswordRepresentationVerified
    sqliteBaselineMemberCount = [int]$baseP0.sqliteBaselineMemberCount
    sqliteRuntimeMemberCount = [int]$baseP0.sqliteRuntimeMemberCount
    sqliteCredentialRebootstrapPrepared =
        [bool]$baseP0.sqliteCredentialRebootstrapPrepared
    sqliteCredentialBindingVerified =
        [bool]$baseP0.sqliteCredentialBindingVerified
    mappedDomainCount = [int]$baseP0.mappedDomainCount
    rootCaInstalledCount = [int]$baseP0.rootCaInstalledCount
    firewallRuleCount = 17
    firewallProgramCount = 17
    networkModeCode = [string]$baseP0.networkModeCode
    systemNetworkAvailable = [bool]$baseP0.systemNetworkAvailable
    upPhysicalNetworkAdapterCount = [int]$baseP0.upPhysicalNetworkAdapterCount
    networkProfileCount = [int]$baseP0.networkProfileCount
    ipv4DefaultRouteCount = [int]$baseP0.ipv4DefaultRouteCount
    ipv6DefaultRouteCount = [int]$baseP0.ipv6DefaultRouteCount
    localBootstrapBackupManifestByteLength =
        (Get-Item -LiteralPath $backupManifestPath).Length
    localBootstrapBackupManifestSha256 = Get-Sha256Hex $backupManifestPath
    localBootstrapAppliedManifestByteLength =
        (Get-Item -LiteralPath $appliedManifestPath).Length
    localBootstrapAppliedManifestSha256 = Get-Sha256Hex $appliedManifestPath
    localBootstrapRollbackScriptByteLength =
        (Get-Item -LiteralPath $rollbackPath).Length
    localBootstrapRollbackScriptSha256 = Get-Sha256Hex $rollbackPath
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    }
    $receiptPath = Join-Path $p0Root `
        "applied-verification-private-v5.receipt.json"
    Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
    $receipt | ConvertTo-Json
}
catch {
    $failure = $_
    & $rollbackPath -ExtensionOnly -AutomaticFailureRollback | Out-Null
    throw "phase3b2_local_bootstrap_p0_seal_failed:$($failure.Exception.Message)"
}
