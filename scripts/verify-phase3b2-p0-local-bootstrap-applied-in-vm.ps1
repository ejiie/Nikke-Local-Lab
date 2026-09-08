[CmdletBinding()]
param()

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
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$trustedRoot = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$p0Path = Join-Path $trustedRoot `
    "p0\applied-verification-private-v5.receipt.json"
$extensionRoot = Join-Path $trustedRoot "p0-local-bootstrap-v1"
$verificationPath = Join-Path $extensionRoot `
    "applied-verification.receipt.json"
$bootstrapRoot = "C:\NLL\LocalBootstrap\v1"
$bootstrapExePath = Join-Path $bootstrapRoot `
    "NikkeLocalLab.Phase3B2.LocalBootstrap.exe"
$firewallGroup = "NLL Phase3B2 Isolation"
$firewallRuleName = "NLL-P3B2-Block-017"
$buildReceiptPath = Join-Path $extensionRoot `
    "local-bootstrap-build.receipt.json"
$artifactManifestPath = Join-Path $extensionRoot "artifact.manifest.tsv"
$backupManifestPath = `
    "C:\NLL\Backups\Phase3B2\P0-local-bootstrap-v1\trusted-backup-manifest.json"
$appliedManifestPath = Join-Path $extensionRoot "trusted-applied-manifest.json"
$rollbackPath = `
    "C:\NLL\Tools\rollback-phase3b2-p0-with-local-bootstrap-in-vm.ps1"

Assert-True (-not (Test-Path -LiteralPath $verificationPath)) `
    "phase3b2_local_bootstrap_verification_receipt_exists"
Assert-True ((Test-Path -LiteralPath $p0Path -PathType Leaf) -and
    (Test-Path -LiteralPath $buildReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $artifactManifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $backupManifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $appliedManifestPath -PathType Leaf) -and
    (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) `
    "phase3b2_local_bootstrap_verification_input_missing"

$p0 = Get-Content -LiteralPath $p0Path -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($p0.contractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v5" -and
    $p0.p0AppliedVerified -and
    $p0.clientBuild -ceq "150.6.9" -and
    $p0.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    $p0.localBootstrapUpstreamHead -ceq
        "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3" -and
    $p0.localBootstrapUpstreamTree -ceq
        "54b85eb6fbaa74feae0c6b441d66a5a703073ba3" -and
    $p0.localBootstrapBuildReceiptSha256 -ceq
        "5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11" -and
    $p0.localBootstrapArtifactManifestSha256 -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70" -and
    [int]$p0.localBootstrapArtifactMemberCount -eq 5 -and
    $p0.sailAbiShimLoadMechanismCode -ceq
        "game_owned_shared_memory_plugin_abi" -and
    -not [bool]$p0.officialLauncherRequired -and
    -not [bool]$p0.officialLauncherExecutionPermitted -and
    -not [bool]$p0.antiCheatSubstitutionBuilt -and
    -not [bool]$p0.antiCheatSubstitutionApplied -and
    [int]$p0.firewallRuleCount -eq 17 -and
    [int]$p0.firewallProgramCount -eq 17 -and
    $p0.networkModeCode -ceq "private_vm_only_no_gateway" -and
    [int]$p0.ipv4DefaultRouteCount -eq 0 -and
    [int]$p0.ipv6DefaultRouteCount -eq 0 -and
    -not [bool]$p0.credentialBearingGuestCopyPresent -and
    -not [bool]$p0.officialIdentityPersisted -and
    -not [bool]$p0.officialCredentialPersisted -and
    -not [bool]$p0.serverExecutionStarted -and
    -not [bool]$p0.clientExecutionStarted) `
    "phase3b2_local_bootstrap_p0_receipt_invalid"

Assert-True ((Get-Item -LiteralPath $buildReceiptPath).Length -eq 1200 -and
    (Get-Sha256Hex $buildReceiptPath) -ceq
        "5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11" -and
    (Get-Item -LiteralPath $artifactManifestPath).Length -eq 561 -and
    (Get-Sha256Hex $artifactManifestPath) -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70") `
    "phase3b2_local_bootstrap_build_evidence_drift"

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
Assert-True (@(Get-ChildItem -LiteralPath $bootstrapRoot -File).Count -eq 5) `
    "phase3b2_local_bootstrap_applied_member_count_mismatch"
foreach ($name in $expectedArtifacts.Keys) {
    $path = Join-Path $bootstrapRoot $name
    Assert-True ((Get-Item -LiteralPath $path).Length -eq
            [long]$expectedArtifacts[$name].Length -and
        (Get-Sha256Hex $path) -ceq [string]$expectedArtifacts[$name].Sha256) `
        "phase3b2_local_bootstrap_applied_artifact_drift"
}
$excludedArtifactCount = @(@("HelperDll.dll", "UnityInit.dll",
        "EpinelPSLauncher.exe") | Where-Object {
        Test-Path -LiteralPath (Join-Path $bootstrapRoot $_)
    }).Count
Assert-True ($excludedArtifactCount -eq 0) `
    "phase3b2_local_bootstrap_excluded_artifact_present"

$rules = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop)
$bootstrapRule = @(Get-NetFirewallRule -Name $firewallRuleName `
        -ErrorAction Stop)
Assert-True ($rules.Count -eq 17 -and $bootstrapRule.Count -eq 1 -and
    [string]$bootstrapRule[0].Enabled -ceq "True" -and
    [string]$bootstrapRule[0].Direction -ceq "Outbound" -and
    [string]$bootstrapRule[0].Action -ceq "Block") `
    "phase3b2_local_bootstrap_firewall_rule_invalid"
$applicationFilter = @(Get-NetFirewallApplicationFilter `
        -AssociatedNetFirewallRule $bootstrapRule[0])
Assert-True ($applicationFilter.Count -eq 1 -and
    [IO.Path]::GetFullPath([string]$applicationFilter[0].Program).Equals(
        [IO.Path]::GetFullPath($bootstrapExePath),
        [StringComparison]::OrdinalIgnoreCase)) `
    "phase3b2_local_bootstrap_firewall_program_mismatch"

$runtimeProcesses = @(Get-Process -Name EpinelPS, nikke_launcher, nikke,
        NikkeLocalLab.Phase3B2.LocalBootstrap -ErrorAction SilentlyContinue)
Assert-True ($runtimeProcesses.Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
    @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
    (Test-Path -LiteralPath "E:\Unity\com_proximabeta_NIKKE" `
        -PathType Container) -and
    (Get-Item -LiteralPath "E:\NIKKE\game\nikke.exe").VersionInfo.FileVersion `
        -ceq "150.6.9") `
    "phase3b2_local_bootstrap_applied_runtime_boundary_invalid"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-local-bootstrap-applied-verification/v1"
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    p0V5ReceiptByteLength = (Get-Item -LiteralPath $p0Path).Length
    p0V5ReceiptSha256 = Get-Sha256Hex $p0Path
    buildReceiptByteLength = 1200
    buildReceiptSha256 = Get-Sha256Hex $buildReceiptPath
    artifactMemberCount = 5
    artifactManifestByteLength = 561
    artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
    firewallRuleCount = 17
    bootstrapFirewallProgramVerified = $true
    resourcePathPresent = $true
    clientBootstrapModeCode = "source_built_sail_abi_local_bootstrap"
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionApplied = $false
    externalUplinkPresent = $false
    serverExecutionStarted = $false
    launcherExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $verificationPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
