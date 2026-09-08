[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [string]$LauncherRoot = "E:\Launcher",

    [ValidateSet("disconnected", "private_vm_only_no_gateway")]
    [string]$NetworkModeCode = "disconnected",

    [ValidateSet("official_launcher", "source_built_sail_abi_local_bootstrap")]
    [string]$ClientBootstrapModeCode = "official_launcher",

    [long]$PrivateCheckpointReceiptByteLength = 0,

    [string]$PrivateCheckpointReceiptSha256 = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$useLocalBootstrap = $NetworkModeCode -ceq "private_vm_only_no_gateway" -and
    $ClientBootstrapModeCode -ceq "source_built_sail_abi_local_bootstrap"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-FileDigest {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "phase3b2_ready_projection_evidence_missing"
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        byteLength = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-TextDigest {
    param([string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [ordered]@{
            byteLength = [long]$bytes.Length
            sha256 = (($algorithm.ComputeHash($bytes) |
                    ForEach-Object { $_.ToString("x2") }) -join "")
        }
    }
    finally {
        $algorithm.Dispose()
    }
}

function Assert-Digest {
    param([object]$Digest, [long]$ByteLength, [string]$Sha256, [string]$FailureCode)
    Assert-True ([long]$Digest.byteLength -eq $ByteLength -and [string]$Digest.sha256 -ceq $Sha256) $FailureCode
}

function Read-Json {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "phase3b2_ready_projection_evidence_missing"
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True (-not (Test-Path -LiteralPath "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_credential_bearing_guest_copy_present"
Assert-True ($null -eq (Get-Process -Name nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_client_or_launcher_started"
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-True ($PrivateCheckpointReceiptByteLength -gt 0 -and
        $PrivateCheckpointReceiptSha256 -cmatch "^[0-9a-f]{64}$") `
        "phase3b2_private_checkpoint_receipt_binding_missing"
}

$trustedRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$identityRoot = Join-Path $trustedRoot "identity"
$externalRoot = Join-Path $trustedRoot "external-v4"
$p0Root = Join-Path $trustedRoot "p0"
$p1Root = Join-Path $trustedRoot $(if ($NetworkModeCode -ceq "disconnected") {
        "p1"
    } elseif ($useLocalBootstrap) {
        "p1-private-v5"
    } else {
        "p1-private-v4"
    })
$outputRoot = Join-Path $trustedRoot $(if ($NetworkModeCode -ceq "disconnected") {
        "ready-seal-v1"
    } elseif ($useLocalBootstrap) {
        "ready-seal-private-v5"
    } else {
        "ready-seal-private-v4"
    })
$outputPath = Join-Path $outputRoot "hyperv-ready-projection.json"
$backupRoot = "C:\NLL\Backups\Phase3B2\P0-v1"
$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"

$externalReceiptPath = Join-Path $externalRoot "external-v4-build.receipt.json"
$profileReceiptPath = Join-Path $identityRoot "offline-synthetic-profile.receipt.json"
$profileAdapterBuildReceiptPath = Join-Path $identityRoot `
    "launcher-credential-v1\profile-adapter-build.receipt.json"
$p0ReceiptPath = Join-Path $p0Root $(if ($NetworkModeCode -ceq "disconnected") {
        "applied-verification-v3.receipt.json"
    } elseif ($useLocalBootstrap) {
        "applied-verification-private-v5.receipt.json"
    } else {
        "applied-verification-private-v4.receipt.json"
    })
$p0V3ReceiptPath = Join-Path $p0Root "applied-verification-private-v3.receipt.json"
$p1ReceiptPath = Join-Path $p1Root "server-only-measurement.receipt.json"
$listenerPath = Join-Path $p1Root "listener-observation.json"
$processTreePath = Join-Path $p1Root "process-tree-observation.json"
$serverPidPath = Join-Path $p1Root "server.pid"
$backupManifestPath = Join-Path $backupRoot "trusted-backup-manifest.json"
$appliedManifestPath = Join-Path $p0Root "trusted-applied-manifest.json"
$launcherBackupRoot = "C:\NLL\Backups\Phase3B2\P0-launcher-ca-v1"
$launcherEvidenceRoot = Join-Path $trustedRoot "p0-launcher-ca-v1"
$launcherBackupManifestPath = Join-Path $launcherBackupRoot `
    "trusted-launcher-certificate-backup-manifest.json"
$launcherAppliedManifestPath = Join-Path $launcherEvidenceRoot `
    "trusted-launcher-certificate-applied-manifest.json"
$rollbackPath = if ($NetworkModeCode -ceq "disconnected") {
    "C:\NLL\Tools\rollback-phase3b2-p0-in-vm.ps1"
} elseif ($useLocalBootstrap) {
    "C:\NLL\Tools\rollback-phase3b2-p0-with-local-bootstrap-in-vm.ps1"
} else {
    "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
}

$external = Read-Json $externalReceiptPath
$profile = Read-Json $profileReceiptPath
$profileAdapterBuild = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Read-Json $profileAdapterBuildReceiptPath
} else { $null }
$p0 = Read-Json $p0ReceiptPath
$p0V3 = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Read-Json $p0V3ReceiptPath
} else { $null }
$p1 = Read-Json $p1ReceiptPath
$listener = Read-Json $listenerPath
$processTree = Read-Json $processTreePath
$applied = Read-Json $appliedManifestPath
$launcherApplied = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Read-Json $launcherAppliedManifestPath
} else {
    $null
}
$p0ReceiptDigest = Get-FileDigest $p0ReceiptPath
$profileReceiptDigest = Get-FileDigest $profileReceiptPath

Assert-True ($external.contractId -ceq "nll/phase3b2-external-v4-build/v1" -and
    $external.externalHead -ceq "519c3db51ec24ca19307e93e85acde7885928a72" -and
    $external.externalTree -ceq "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    $external.checkoutClean -and $external.dotnetSdkVersion -ceq "10.0.400" -and
    $external.selectedManagerPassedCount -eq 64 -and $external.handlerIsolationPassedCount -eq 5 -and
    $external.focusedTestFailedCount -eq 0 -and -not $external.localOnlyHttp3Enabled -and
    -not $external.localOnlyAssetCachePathLoggingEnabled -and
    -not $external.serverExecutionStarted -and -not $external.clientExecutionStarted) `
    "phase3b2_ready_projection_external_receipt_invalid"
Assert-True ($external.buildManifestByteLength -eq 63629 -and
    $external.buildManifestSha256 -ceq "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37" -and
    $external.toolchainByteLength -eq 153 -and
    $external.toolchainSha256 -ceq "daa6ca1e91612ff2e506c2d4ff26b7b8db8b091ac72d8e62f9c1a0c0850ce31a" -and
    $external.focusedTestByteLength -eq 142 -and
    $external.focusedTestSha256 -ceq "a4481b79e394d3d7f1a0ce1eec636c62258cb07aea48c281318a689cfd83d7bd") `
    "phase3b2_ready_projection_external_digest_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq $external.externalHead -and
    (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq $external.externalTree -and
    @(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_ready_projection_external_checkout_drift"

Assert-True ($profile.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
    $profile.characterCount -eq 193 -and
    $(if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
        [int]$profile.launcherPasswordPlaintextLength -eq 20 -and
        [int]$profile.launcherPasswordStorageLength -eq 32 -and
        $profile.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        -not [bool]$profile.launcherPasswordPlaintextPersistedInDatabase
    } else { $true }) -and
    -not $profile.officialIdentityPersisted -and
    -not $profile.officialCredentialPersisted -and -not $profile.clientExecutionStarted) `
    "phase3b2_ready_projection_synthetic_identity_invalid"
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-True ($profileAdapterBuild.contractId -ceq
            "nll/phase3b2-profile-adapter-launcher-credential-build/v1" -and
        $profileAdapterBuild.dotnetSdkVersion -ceq "10.0.400" -and
        [int]$profileAdapterBuild.launcherPasswordPlaintextLength -eq 20 -and
        [int]$profileAdapterBuild.launcherPasswordStorageLength -eq 32 -and
        $profileAdapterBuild.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        -not [bool]$profileAdapterBuild.launcherPasswordPlaintextPersistedInDatabase -and
        [bool]$profileAdapterBuild.externalCheckoutClean -and
        -not [bool]$profileAdapterBuild.adapterExecutionStarted -and
        -not [bool]$profileAdapterBuild.serverExecutionStarted -and
        -not [bool]$profileAdapterBuild.clientExecutionStarted) `
        "phase3b2_ready_projection_profile_adapter_build_invalid"
}
Assert-True ($p0.contractId -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-p0-applied-verification/v3"
    } elseif ($useLocalBootstrap) {
        "nll/phase3b2-p0-private-applied-verification/v5"
    } else {
        "nll/phase3b2-p0-private-applied-verification/v4"
    }) -and
    $p0.p0AppliedVerified -and $p0.clientBuild -ceq "150.6.9" -and
    $p0.externalHead -ceq $external.externalHead -and $p0.externalTree -ceq $external.externalTree -and
    $p0.externalBuildManifestSha256 -ceq $external.buildManifestSha256 -and
    -not $p0.localOnlyHttp3Enabled -and -not $p0.localOnlyAssetCachePathLoggingEnabled -and
    $p0.mappedDomainCount -eq 17 -and $p0.rootCaInstalledCount -eq 1 -and
    $p0.firewallRuleCount -eq $(if ($useLocalBootstrap) { 17 } else { 16 }) -and
    $p0.firewallProgramCount -eq $(if ($useLocalBootstrap) { 17 } else { 16 }) -and
    $p0.networkModeCode -ceq $NetworkModeCode -and
    $p0.upPhysicalNetworkAdapterCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $p0.networkProfileCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $p0.ipv4DefaultRouteCount -eq 0 -and $p0.ipv6DefaultRouteCount -eq 0 -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $p0.backupManifestSha256 -ceq
            "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a" -and
        $p0.appliedManifestSha256 -ceq
            "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46"
    } elseif ($useLocalBootstrap) {
        $p0.clientBootstrapModeCode -ceq
            "source_built_sail_abi_local_bootstrap" -and
        $p0.localBootstrapUpstreamHead -ceq
            "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3" -and
        $p0.localBootstrapUpstreamTree -ceq
            "54b85eb6fbaa74feae0c6b441d66a5a703073ba3" -and
        [int]$p0.localBootstrapArtifactMemberCount -eq 5 -and
        $p0.localBootstrapArtifactManifestSha256 -ceq
            "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70" -and
        -not [bool]$p0.officialLauncherExecutionPermitted -and
        -not [bool]$p0.antiCheatSubstitutionApplied -and
        [long]$p0.baseP0V4ReceiptByteLength -eq 2210 -and
        $p0.baseP0V4ReceiptSha256 -ceq
            "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f" -and
        [int]$p0.launcherPasswordPlaintextLength -eq 20 -and
        [int]$p0.launcherPasswordStorageLength -eq 32 -and
        [bool]$p0.launcherPasswordRepresentationVerified -and
        [int]$p0.sqliteBaselineMemberCount -eq 3 -and
        [int]$p0.sqliteRuntimeMemberCount -eq 0 -and
        [bool]$p0.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$p0.sqliteCredentialBindingVerified
    } else {
        $p0.launcherCertificateAppliedSha256 -ceq
            "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" -and
        [long]$p0.baseP0V3ReceiptByteLength -eq 2976 -and
        $p0.baseP0V3ReceiptSha256 -ceq
            "a2272a4fa382456cfa26a474f708fe1ffef680dff6ce3d3e856d138cd8b4f3a0" -and
        [long]$p0.fullCompositeRollbackScriptByteLength -eq 3292 -and
        $p0.fullCompositeRollbackScriptSha256 -ceq
            "823af896da3b0d83fa67e7f38d660edbc7b06a2d23ff8cde8042abdfcea12a7f" -and
        [int]$p0.launcherPasswordPlaintextLength -eq 20 -and
        [int]$p0.launcherPasswordStorageLength -eq 32 -and
        $p0.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        [bool]$p0.launcherPasswordRepresentationVerified -and
        [int]$p0.sqliteBaselineMemberCount -eq 3 -and
        [int]$p0.sqliteRuntimeMemberCount -eq 0 -and
        [bool]$p0.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$p0.sqliteCredentialBindingVerified -and
        $p0V3.contractId -ceq
            "nll/phase3b2-p0-private-applied-verification/v3" -and
        $p0V3.baseBackupManifestSha256 -ceq
            "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a" -and
        $p0V3.baseAppliedManifestSha256 -ceq
            "582dee5a915116fa91c63c1e524abea14dbe63dea5c1a6aac573140c67feec46" -and
        $p0V3.launcherBackupManifestSha256 -ceq
            "6078cccf2e79fdf89b39a464f9b22d604057a66a300734eb81141c95cabd7d93" -and
        $p0V3.launcherAppliedManifestSha256 -ceq
            "dfcd10d06f09c3348e5578ceb3ac4328ca3e6d2cb70e35bd0dd662f42c9cc14d"
    }) -and
    -not $p0.credentialBearingGuestCopyPresent -and -not $p0.clientExecutionStarted) `
    "phase3b2_ready_projection_p0_invalid"
Assert-True ($p1.contractId -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-p1-server-only-measurement/v1"
    } elseif ($useLocalBootstrap) {
        "nll/phase3b2-p1-private-server-only-measurement/v5"
    } else {
        "nll/phase3b2-p1-private-server-only-measurement/v4"
    }) -and
    $p1.serverExecutionStarted -and -not $p1.clientExecutionStarted -and $p1.serverRunning -and
    $p1.clientBuild -ceq "150.6.9" -and $p1.externalHead -ceq $external.externalHead -and
    $p1.externalTree -ceq $external.externalTree -and $p1.headlessEnabled -and $p1.localOnlyEnabled -and
    -not $p1.officialAssetAutoFetchEnabled -and -not $p1.localeAutoFetchEnabled -and
    -not $p1.gitUpdateEnabled -and -not $p1.interactiveUpdateSurfaceEnabled -and
    -not $p1.frameworkInformationLoggingEnabled -and -not $p1.localOnlyHttp3Enabled -and
    -not $p1.localOnlyAssetCachePathLoggingEnabled -and
    $p1.clientBootstrapModeCode -ceq $ClientBootstrapModeCode -and
    $p1.officialLauncherExecutionPermitted -eq (-not $useLocalBootstrap) -and
    -not [bool]$p1.antiCheatSubstitutionApplied -and
    $p1.networkModeCode -ceq $NetworkModeCode -and
    $p1.systemNetworkAvailable -eq ($NetworkModeCode -ceq "private_vm_only_no_gateway") -and
    $p1.upPhysicalNetworkAdapterCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $p1.networkProfileCount -eq $(if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }) -and
    $p1.ipv4DefaultRouteCount -eq 0 -and $p1.ipv6DefaultRouteCount -eq 0 -and
    $p1.httpIpv4LoopbackListenerCount -eq 1 -and $p1.httpsIpv4LoopbackListenerCount -eq 1 -and
    $p1.http3UdpListenerCount -eq 0 -and $p1.wildcardListenerCount -eq 0 -and
    $p1.lanListenerCount -eq 0 -and $p1.unexpectedListenerCount -eq 0 -and
    $p1.nonLoopbackAttemptCount -eq 0 -and $p1.nonLoopbackSuccessfulConnectionCount -eq 0 -and
    $p1.processTreeMemberCount -eq 1 -and $p1.selectionObservedNoLaterThanListener -and
    $p1.selectionRuntimeMutationCount -eq 0 -and $p1.latestFallbackCount -eq 0 -and
    $p1.activeRunCount -eq 0 -and $p1.rawSensitiveLogMatchCount -eq 0 -and
    $(if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
        [bool]$p1.launcherPasswordRepresentationVerified -and
        [bool]$p1.sqliteCredentialRebootstrapPrepared -and
        [bool]$p1.sqliteRebootstrapObserved -and
        [bool]$p1.controlledSyntheticLoginAccepted -and
        $p1.controlledLoginPasswordRepresentationCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        [bool]$p1.sqliteCredentialBindingVerified -and
        [int]$p1.sqliteRuntimeMemberCount -ge 1
    } else { $true }) -and
    -not $p1.credentialBearingGuestCopyPresent -and -not $p1.officialIdentityPersisted -and
    -not $p1.officialCredentialPersisted) "phase3b2_ready_projection_p1_invalid"
Assert-True ($p1.p0VerificationByteLength -eq [long]$p0ReceiptDigest.byteLength -and
    $p1.p0VerificationSha256 -ceq [string]$p0ReceiptDigest.sha256 -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        [long]$p0ReceiptDigest.byteLength -eq 1062 -and
        [string]$p0ReceiptDigest.sha256 -ceq
            "2f17d599480d9ef8376c9ad32593925a4afe9eb6dde0947aabb0353a3afc1596"
    } else {
        $true
    })) `
    "phase3b2_ready_projection_p0_p1_binding_mismatch"

$serverPid = [int](Get-Content -LiteralPath $serverPidPath -Raw -Encoding UTF8).Trim()
$serverProcesses = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
Assert-True ($serverProcesses.Count -eq 1 -and $serverProcesses[0].Id -eq $serverPid) `
    "phase3b2_ready_projection_server_continuity_lost"
$tcp = @(Get-NetTCPConnection -OwningProcess $serverPid -State Listen -ErrorAction Stop)
$http = @($tcp | Where-Object { $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 80 })
$https = @($tcp | Where-Object { $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 443 })
$unexpectedTcp = @($tcp | Where-Object {
        -not ($_.LocalAddress -ceq "127.0.0.1" -and ($_.LocalPort -eq 80 -or $_.LocalPort -eq 443))
    })
$udp443 = @(Get-NetUDPEndpoint -OwningProcess $serverPid -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -eq 443 })
$nonLoopbackConnections = @(Get-NetTCPConnection -OwningProcess $serverPid -ErrorAction SilentlyContinue |
        Where-Object { $_.State -notin @("Listen", "Closed", "TimeWait") -and
            $_.RemoteAddress -notin @("127.0.0.1", "::1", "0.0.0.0", "::") })
Assert-True ($http.Count -eq 1 -and $https.Count -eq 1 -and $unexpectedTcp.Count -eq 0 -and
    $udp443.Count -eq 0 -and $nonLoopbackConnections.Count -eq 0) `
    "phase3b2_ready_projection_live_listener_or_egress_drift"
$upPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ "Up").Count
$systemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
$networkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
$ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
$ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
if ($NetworkModeCode -ceq "disconnected") {
    Assert-True ($upPhysicalNetworkAdapterCount -eq 0 -and -not $systemNetworkAvailable -and
        $networkProfileCount -eq 0) "phase3b2_ready_projection_disconnected_network_drift"
}
else {
    Assert-True ($upPhysicalNetworkAdapterCount -eq 1 -and $systemNetworkAvailable -and
        $networkProfileCount -eq 1 -and $ipv4DefaultRouteCount -eq 0 -and
        $ipv6DefaultRouteCount -eq 0) "phase3b2_ready_projection_private_network_drift"
}
Assert-True ($listener.contractId -ceq "nll/phase3b2-p1-listener-observation/v1" -and
    $processTree.contractId -ceq "nll/phase3b2-p1-process-tree-observation/v1" -and
    @($processTree.members).Count -eq 1) "phase3b2_ready_projection_observation_shape_invalid"

$clientExe = Join-Path $ClientRoot "nikke.exe"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_ready_projection_client_version_drift"
$packMatches = @(Get-ChildItem -LiteralPath (Join-Path $serverRoot "cache") -Recurse -File `
        -Filter "StaticData.pack" -ErrorAction Stop)
Assert-True ($packMatches.Count -eq 1) "phase3b2_ready_projection_staticdata_shape_invalid"
$runtimeInputs = @(
    [ordered]@{ roleCode = "runtime_pack_staticdata"; digest = Get-FileDigest $packMatches[0].FullName },
    [ordered]@{ roleCode = "locale_bgm"; digest = Get-FileDigest (Join-Path $serverRoot "cache\local-locale\Locale_Bgm.lsc") },
    [ordered]@{ roleCode = "locale_character"; digest = Get-FileDigest (Join-Path $serverRoot "cache\local-locale\Locale_Character.lsc") },
    [ordered]@{ roleCode = "locale_costume"; digest = Get-FileDigest (Join-Path $serverRoot "cache\local-locale\Locale_CharacterCostume.lsc") },
    [ordered]@{ roleCode = "locale_item"; digest = Get-FileDigest (Join-Path $serverRoot "cache\local-locale\Locale_Item.lsc") }
)
Assert-Digest $runtimeInputs[0].digest 17177168 "8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3" "phase3b2_ready_projection_staticdata_drift"
Assert-Digest $runtimeInputs[1].digest 25498 "069143db0a70be3947d8bb68ff19a4815efbd3a35fc00401bd0bf93d460fd925" "phase3b2_ready_projection_locale_bgm_drift"
Assert-Digest $runtimeInputs[2].digest 5023222 "d50727f15317fb09ab7c4bab2eed8f4083efc4cbd9880269d95f2e2b21bc7013" "phase3b2_ready_projection_locale_character_drift"
Assert-Digest $runtimeInputs[3].digest 67547 "3284a10c92890491e6b138a9c54c9e47d6816413f7e44493d10410b0a90cffa0" "phase3b2_ready_projection_locale_costume_drift"
Assert-Digest $runtimeInputs[4].digest 1193697 "e149ac84c9ddf9b428183d4f4ff4d99edc3f665d1ee38b3adccd0e0fa50330ff" "phase3b2_ready_projection_locale_item_drift"

$hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$pluginsRoot = Join-Path $ClientRoot "nikke_Data\Plugins\x86_64"
$certificateCandidates = @(
    Join-Path $pluginsRoot "intl_cacert.pem"
    Join-Path $pluginsRoot "cacert.pem"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
Assert-True (@($certificateCandidates).Count -eq 1) "phase3b2_ready_projection_certificate_shape_invalid"
$certificatePath = @($certificateCandidates)[0]
$launcherCertificateCandidates = @(
    Join-Path $LauncherRoot "intl_service\intl_cacert.pem"
    Join-Path $LauncherRoot "intl_service\cacert.pem"
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-True (@($launcherCertificateCandidates).Count -eq 1) `
        "phase3b2_ready_projection_launcher_certificate_shape_invalid"
}
$launcherCertificatePath = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    @($launcherCertificateCandidates)[0]
} else {
    $null
}
$sodiumPath = Join-Path $pluginsRoot "sodium.dll"
$caPath = Join-Path $EpinelRoot "ServerSelector\myCA.cer"
$hostsBackupPath = Join-Path $backupRoot "hosts.original.bin"
$certificateBackupPath = Join-Path $backupRoot "game-certificate.original.bin"
$launcherCertificateBackupPath = Join-Path $launcherBackupRoot `
    "launcher-certificate.original.bin"
$sodiumBackupPath = Join-Path $backupRoot "sodium.original.bin"

$backupManifestDigest = Get-FileDigest $backupManifestPath
$appliedManifestDigest = Get-FileDigest $appliedManifestPath
$rollbackDigest = Get-FileDigest $rollbackPath
$hostsBefore = Get-FileDigest $hostsBackupPath
$hostsApplied = Get-FileDigest $hostsPath
$certificateBefore = Get-FileDigest $certificateBackupPath
$certificateApplied = Get-FileDigest $certificatePath
$launcherCertificateBefore = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-FileDigest $launcherCertificateBackupPath
} else {
    $null
}
$launcherCertificateApplied = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-FileDigest $launcherCertificatePath
} else {
    $null
}
$launcherBackupManifestDigest = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-FileDigest $launcherBackupManifestPath
} else {
    $null
}
$launcherAppliedManifestDigest = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-FileDigest $launcherAppliedManifestPath
} else {
    $null
}
$sodiumBefore = Get-FileDigest $sodiumBackupPath
$sodiumApplied = Get-FileDigest $sodiumPath
$caApplied = Get-FileDigest $caPath
Assert-Digest $backupManifestDigest 1240 "75ae4457ecfe0cc3071b7d9c690d683b8794731a7b4ba0eecb43d5e18d323e2a" "phase3b2_ready_projection_backup_manifest_drift"
Assert-Digest $hostsBefore 824 "2d6bdfb341be3a6234b24742377f93aa7c7cfb0d9fd64efa9282c87852e57085" "phase3b2_ready_projection_hosts_backup_drift"
Assert-Digest $certificateBefore 212549 "921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d" "phase3b2_ready_projection_certificate_backup_drift"
Assert-Digest $sodiumBefore 304128 "0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888" "phase3b2_ready_projection_sodium_backup_drift"
Assert-Digest $caApplied 1266 "6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda" "phase3b2_ready_projection_ca_drift"
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-Digest $launcherCertificateBefore 209309 `
        "86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65" `
        "phase3b2_ready_projection_launcher_certificate_backup_drift"
    Assert-Digest $launcherCertificateApplied 210620 `
        "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" `
        "phase3b2_ready_projection_launcher_certificate_applied_drift"
    Assert-Digest $launcherBackupManifestDigest 1397 `
        "6078cccf2e79fdf89b39a464f9b22d604057a66a300734eb81141c95cabd7d93" `
        "phase3b2_ready_projection_launcher_backup_manifest_drift"
    Assert-Digest $launcherAppliedManifestDigest 1152 `
        "dfcd10d06f09c3348e5578ceb3ac4328ca3e6d2cb70e35bd0dd662f42c9cc14d" `
        "phase3b2_ready_projection_launcher_applied_manifest_drift"
}
Assert-True ($hostsApplied.byteLength -eq $applied.systemHosts.appliedByteLength -and
    $hostsApplied.sha256 -ceq $applied.systemHosts.appliedSha256 -and
    $certificateApplied.byteLength -eq $applied.clientCertificateBundle.appliedByteLength -and
    $certificateApplied.sha256 -ceq $applied.clientCertificateBundle.appliedSha256 -and
    $sodiumApplied.byteLength -eq $applied.nativeCompatibilityShim.appliedByteLength -and
    $sodiumApplied.sha256 -ceq $applied.nativeCompatibilityShim.appliedSha256 -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $rollbackDigest.sha256 -ceq $applied.rollback.scriptSha256
    } elseif ($useLocalBootstrap) {
        $rollbackDigest.byteLength -eq [long]$p0.localBootstrapRollbackScriptByteLength -and
        $rollbackDigest.sha256 -ceq [string]$p0.localBootstrapRollbackScriptSha256 -and
        $launcherApplied.clientCertificateBundleMemberCount -eq 2 -and
        $launcherApplied.launcherCertificateBundle.appliedSha256 -ceq
            $launcherCertificateApplied.sha256
    } else {
        $rollbackDigest.byteLength -eq 3292 -and
        $rollbackDigest.sha256 -ceq
            "823af896da3b0d83fa67e7f38d660edbc7b06a2d23ff8cde8042abdfcea12a7f" -and
        $launcherApplied.clientCertificateBundleMemberCount -eq 2 -and
        $launcherApplied.launcherCertificateBundle.appliedSha256 -ceq
            $launcherCertificateApplied.sha256
    })) "phase3b2_ready_projection_applied_state_drift"
Assert-True ($appliedManifestDigest.sha256 -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        $p0.appliedManifestSha256
    } else {
        $p0V3.baseAppliedManifestSha256
    })) `
    "phase3b2_ready_projection_applied_manifest_drift"

$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caPath)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try { $rootCaCount = @($store.Certificates | Where-Object Thumbprint -CEQ $ca.Thumbprint).Count }
finally { $store.Close() }
Assert-True ($rootCaCount -eq 1 -and
    @(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" -ErrorAction Stop).Count -eq
        $(if ($useLocalBootstrap) { 17 } else { 16 })) `
    "phase3b2_ready_projection_p0_live_state_drift"

$p1ReceiptDigest = Get-FileDigest $p1ReceiptPath
$profileReceiptDigest = Get-FileDigest $profileReceiptPath
$profileAdapterBuildReceiptDigest = if (
    $NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-FileDigest $profileAdapterBuildReceiptPath
} else { $null }
$listenerDigest = Get-FileDigest $listenerPath
$processTreeDigest = Get-FileDigest $processTreePath
if ($NetworkModeCode -ceq "disconnected") {
    Assert-Digest $p0ReceiptDigest 1062 `
        "2f17d599480d9ef8376c9ad32593925a4afe9eb6dde0947aabb0353a3afc1596"
        "phase3b2_ready_projection_p0_receipt_drift"
}

$certificateSetBefore = $certificateBefore
$certificateSetApplied = $certificateApplied
$certificateSetBackup = $backupManifestDigest
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    $certificateSetBefore = Get-TextDigest ((@(
                "contractId=nll/phase3b2-client-certificate-bundle-set/v2"
                "state=before"
                "memberCount=2"
                "game.byteLength=$($certificateBefore.byteLength)"
                "game.sha256=$($certificateBefore.sha256)"
                "launcher.byteLength=$($launcherCertificateBefore.byteLength)"
                "launcher.sha256=$($launcherCertificateBefore.sha256)"
            ) -join "`n") + "`n")
    $certificateSetApplied = Get-TextDigest ((@(
                "contractId=nll/phase3b2-client-certificate-bundle-set/v2"
                "state=applied"
                "memberCount=2"
                "game.byteLength=$($certificateApplied.byteLength)"
                "game.sha256=$($certificateApplied.sha256)"
                "launcher.byteLength=$($launcherCertificateApplied.byteLength)"
                "launcher.sha256=$($launcherCertificateApplied.sha256)"
            ) -join "`n") + "`n")
    $certificateSetBackup = Get-TextDigest ((@(
                "contractId=nll/phase3b2-client-certificate-backup-set/v2"
                "memberCount=2"
                "base.byteLength=$($backupManifestDigest.byteLength)"
                "base.sha256=$($backupManifestDigest.sha256)"
                "launcher.byteLength=$($launcherBackupManifestDigest.byteLength)"
                "launcher.sha256=$($launcherBackupManifestDigest.sha256)"
            ) -join "`n") + "`n")
}

Assert-True (-not (Test-Path -LiteralPath $outputRoot)) "phase3b2_ready_projection_output_exists"
$projection = [ordered]@{
    schemaVersion = 1
    contractId = "nll/phase3b2-hyperv-ready-projection/v1"
    assessmentUid = [Guid]::NewGuid().ToString("D").ToLowerInvariant()
    observedAtUtc = [string]$p1.measuredAtUtc
    clientBuildVersion = "150.6.9"
    clientExecutionStarted = $false
    serverRunning = $true
    networkModeCode = $NetworkModeCode
    clientBootstrapModeCode = $ClientBootstrapModeCode
    checkpointReceipt = [ordered]@{
        byteLength = if ($NetworkModeCode -ceq "disconnected") {
            1178
        } else {
            $PrivateCheckpointReceiptByteLength
        }
        sha256 = if ($NetworkModeCode -ceq "disconnected") {
            "cbe57b9a5914a9c8fe3fee31f7140fe8d2f58e1e07ae9c7c7a3260b5c2b5210d"
        } else {
            $PrivateCheckpointReceiptSha256
        }
    }
    primaryManifest = [ordered]@{
        byteLength = 5397209
        sha256 = "0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4"
    }
    clientManifest = [ordered]@{
        byteLength = 5397209
        sha256 = "0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4"
    }
    externalBuild = [ordered]@{
        latestExternalCommitSha = [string]$external.externalHead
        latestExternalTreeCommitSha = [string]$external.externalTree
        checkoutClean = $true
        dotnetSdkVersion = "10.0.400"
        selectedManagerPassedCount = 64
        handlerIsolationPassedCount = 5
        focusedTestFailedCount = 0
        localOnlyHttp3Enabled = $false
        localOnlyAssetCachePathLoggingEnabled = $false
        toolchainObservation = [ordered]@{ byteLength = [long]$external.toolchainByteLength; sha256 = [string]$external.toolchainSha256 }
        buildArtifactObservation = [ordered]@{ byteLength = [long]$external.buildManifestByteLength; sha256 = [string]$external.buildManifestSha256 }
        focusedTestObservation = [ordered]@{ byteLength = [long]$external.focusedTestByteLength; sha256 = [string]$external.focusedTestSha256 }
    }
    runtimeInputs = $runtimeInputs
    syntheticIdentityObservation = $profileReceiptDigest
    p0Observation = $p0ReceiptDigest
    profileAdapterBuildObservation = $profileAdapterBuildReceiptDigest
    networkObservation = $p1ReceiptDigest
    mutations = [ordered]@{
        systemHosts = [ordered]@{ beforeState = $hostsBefore; appliedState = $hostsApplied; backupState = $backupManifestDigest; rollbackPlan = $rollbackDigest }
        rootCa = [ordered]@{ beforeState = $backupManifestDigest; appliedState = $caApplied; backupState = $backupManifestDigest; rollbackPlan = $rollbackDigest }
        clientCertificateBundle = [ordered]@{ beforeState = $certificateSetBefore; appliedState = $certificateSetApplied; backupState = $certificateSetBackup; rollbackPlan = $rollbackDigest }
        nativeCompatibilityShim = [ordered]@{ beforeState = $sodiumBefore; appliedState = $sodiumApplied; backupState = $backupManifestDigest; rollbackPlan = $rollbackDigest }
    }
    localOnlyConfigObservation = $p1ReceiptDigest
    listenerObservation = $listenerDigest
    bootstrapObservation = $p1ReceiptDigest
    activeStateObservation = $p1ReceiptDigest
    logSafetyObservation = $p1ReceiptDigest
    processTreeObservation = $processTreeDigest
    measuredFacts = [ordered]@{
        httpIpv4LoopbackListenerCount = 1
        httpsIpv4LoopbackListenerCount = 1
        http3UdpListenerCount = 0
        wildcardListenerCount = 0
        lanListenerCount = 0
        unexpectedListenerCount = 0
        nonLoopbackAttemptCount = 0
        nonLoopbackSuccessfulConnectionCount = 0
        processTreeMemberCount = 1
        selectionObservedNoLaterThanListener = $true
        selectionRuntimeMutationCount = 0
        latestFallbackCount = 0
        activeRunCount = 0
        rawSensitiveLogMatchCount = 0
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        credentialBearingGuestCopyPresent = $false
        systemNetworkAvailable = $systemNetworkAvailable
        upPhysicalNetworkAdapterCount = $upPhysicalNetworkAdapterCount
        networkProfileCount = $networkProfileCount
        ipv4DefaultRouteCount = $ipv4DefaultRouteCount
        ipv6DefaultRouteCount = $ipv6DefaultRouteCount
    }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$projectionText = $projection | ConvertTo-Json -Depth 20
Write-Utf8NoBom $outputPath ($projectionText + "`n")
$projection | ConvertTo-Json -Depth 20
