$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-ExecutionPolicy -Scope Process Bypass -Force

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

function Test-SafeLeafName {
    param([string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    if ([IO.Path]::IsPathRooted($RelativePath)) { return $false }
    return (
        $RelativePath -ceq [IO.Path]::GetFileName($RelativePath) -and
        -not $RelativePath.Contains('/') -and
        -not $RelativePath.Contains('\')
    )
}

$expectedDeploymentReceiptSha256 = `
    '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
$expectedVerifierManifestSha256 = `
    '__NATIVE_CACHE_VERIFIER_MANIFEST_SHA256__'
$expectedHeaderClosureReceiptSha256 = `
    '__NATIVE_CACHE_HEADER_CLOSURE_RECEIPT_SHA256__'
$deploymentPath = `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
$verifierRoot = 'C:\NLL\Tools\Phase3B2.NativeCacheVerifier-v1'
$verifierManifestPath = Join-Path $verifierRoot 'bundle.manifest.json'
$verifierDllPath = Join-Path $verifierRoot `
    'Phase3B2.NativeCacheMaterializer.dll'
$headerClosureReceiptPath = `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-header-closure-v1\repair.receipt.json'
$dotnetPath = 'C:\Program Files\dotnet\dotnet.exe'
$cacheRoot = `
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$headerRelativePath = `
    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
$headerPath = Join-Path $cacheRoot $headerRelativePath
$headerUrl = `
    'https://cloud.nikke-kr.com/prdenv/150-b059c3f36c/StandaloneWindows64/pck/latest-651.txt'
$expectedHeaderByteLength = 139L
$expectedHeaderSha256 = `
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
$minimalStartPath =
    'C:\NLL\Tools\start-phase3b2-epinel-minimal-reference-in-micron.ps1'
$extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
) 'phase3b2_epinel_native_cache_start_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_epinel_native_cache_start_wrong_operator_or_boot_boundary'
Assert-True (
    (Test-Path -LiteralPath $deploymentPath -PathType Leaf) -and
    (Get-Sha256Hex $deploymentPath) -ceq `
        $expectedDeploymentReceiptSha256 -and
    (Test-Path -LiteralPath $verifierManifestPath -PathType Leaf) -and
    (Get-Sha256Hex $verifierManifestPath) -ceq `
        $expectedVerifierManifestSha256 -and
    (Test-Path -LiteralPath $verifierDllPath -PathType Leaf) -and
    (Test-Path -LiteralPath $headerClosureReceiptPath -PathType Leaf) -and
    (Get-Sha256Hex $headerClosureReceiptPath) -ceq `
        $expectedHeaderClosureReceiptSha256 -and
    (Test-Path -LiteralPath $headerPath -PathType Leaf) -and
    (Get-Item -LiteralPath $headerPath).Length -eq `
        $expectedHeaderByteLength -and
    (Get-Sha256Hex $headerPath) -ceq $expectedHeaderSha256 -and
    (Test-Path -LiteralPath $dotnetPath -PathType Leaf) -and
    (Test-Path -LiteralPath $minimalStartPath -PathType Leaf) -and
    (Test-Path -LiteralPath $cacheRoot -PathType Container)
) 'phase3b2_epinel_native_cache_start_input_missing_or_drifted'

$headerClosure = Get-Content -LiteralPath $headerClosureReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $headerClosure.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-header-closure-repair/v1' -and
    $headerClosure.versionHeaderApplied -and
    $headerClosure.versionHeaderRelativePath -ceq `
        $headerRelativePath.Replace('\', '/') -and
    $headerClosure.versionHeaderByteLength -eq $expectedHeaderByteLength -and
    $headerClosure.versionHeaderSha256 -ceq $expectedHeaderSha256 -and
    $headerClosure.activeCacheFileCountAfter -eq 40109 -and
    [long]$headerClosure.activeCacheContentByteLengthAfter -eq `
        39030630086L -and
    $headerClosure.databaseRestored -and
    $headerClosure.sqliteRuntimeRemoved -and
    $headerClosure.activeRunPointerArchived -and
    -not $headerClosure.serverExecutionStarted -and
    -not $headerClosure.clientExecutionStarted
) 'phase3b2_epinel_native_cache_start_header_closure_invalid'

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-offline-deployment/v1' -and
    $deployment.nativeCacheDeploymentVerified -and
    $deployment.activeCacheFileCount -eq 40108 -and
    [long]$deployment.activeCacheContentByteLength -eq 39030629947L -and
    $deployment.databaseRestored -and
    $deployment.sqliteRuntimeRemoved -and
    -not $deployment.clientExecutionStarted -and
    -not $deployment.serverExecutionStarted
) 'phase3b2_epinel_native_cache_start_deployment_contract_invalid'

$verifierManifest = Get-Content -LiteralPath $verifierManifestPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $verifierManifest.contractId -ceq `
        'nll/phase3b2-native-cache-long-path-verifier-manifest/v1' -and
    $verifierManifest.memberCount -eq 8 -and
    @($verifierManifest.members).Count -eq 8 -and
    $verifierManifest.sdkVersion -ceq '10.0.400' -and
    $verifierManifest.compileInputCanonicalSha256 -ceq `
        'eaf339d04519010b8379ad2c30ef4321d5e6e2623a5d90116f350f0eac32bba3'
) 'phase3b2_epinel_native_cache_start_verifier_manifest_invalid'
foreach ($member in @($verifierManifest.members)) {
    $relativePath = [string]$member.relativePath
    Assert-True (Test-SafeLeafName $relativePath) `
        'phase3b2_epinel_native_cache_start_verifier_path_invalid'
    $memberPath = Join-Path $verifierRoot $relativePath
    Assert-True (
        (Test-Path -LiteralPath $memberPath -PathType Leaf) -and
        (Get-Item -LiteralPath $memberPath).Length -eq `
            [long]$member.byteLength -and
        (Get-Sha256Hex $memberPath) -ceq [string]$member.sha256
    ) 'phase3b2_epinel_native_cache_start_verifier_member_invalid'
}

$inspectionOutput = & $dotnetPath $verifierDllPath `
    'inspect-cache-tree' $cacheRoot 2>&1
$inspectionExitCode = $LASTEXITCODE
Assert-True ($inspectionExitCode -eq 0) `
    'phase3b2_epinel_native_cache_start_long_path_inspection_failed'
$inspection = (($inspectionOutput | Out-String) | ConvertFrom-Json)
Assert-True (
    $inspection.contractId -ceq `
        'nll/phase3b2-native-cache-tree-inspection/v1' -and
    $inspection.longPathSafeEnumerationUsed -and
    $inspection.fileCount -eq 40109 -and
    [long]$inspection.contentByteLength -eq 39030630086L -and
    $inspection.partialMemberCount -eq 0
) 'phase3b2_epinel_native_cache_start_cache_shape_invalid'

Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Assert-True (
    @(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_native_cache_start_stale_firewall_cleanup_failed'

$startText = (& $minimalStartPath `
    -RequiredLocalAssetUrl $headerUrl `
    -RequiredLocalAssetByteLength $expectedHeaderByteLength `
    -RequiredLocalAssetSha256 $expectedHeaderSha256 | Out-String).Trim()
$start = $startText | ConvertFrom-Json
Assert-True (
    $start.contractId -ceq `
        'nll/phase3b2-epinel-minimal-reference-start/v1' -and
    [Guid]::Parse([string]$start.assessmentUid) -ne [Guid]::Empty -and
    $start.serverRunning -and
    $start.physicalBootstrapRunning -and
    $start.clientExecutionStarted -and
    $start.successfulNonLoopbackConnectionCount -eq 0
) 'phase3b2_epinel_native_cache_start_inner_receipt_invalid'
Assert-True (
    $start.requiredLocalAssetPreflightPerformed -and
    $start.requiredLocalAssetLoopbackResolved -and
    $start.requiredLocalAssetHttpStatusCode -eq 200 -and
    $start.requiredLocalAssetObservedByteLength -eq `
        $expectedHeaderByteLength -and
    $start.requiredLocalAssetObservedSha256 -ceq $expectedHeaderSha256
) 'phase3b2_epinel_native_cache_start_inner_receipt_invalid'

$bindingPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    [string]$start.assessmentUid
) 'native-cache.binding.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $bindingPath)) `
    'phase3b2_epinel_native_cache_start_binding_collision'
$binding = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-native-cache-run-binding/v3'
    boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = [string]$start.assessmentUid
    deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
    verifierManifestSha256 = $expectedVerifierManifestSha256
    headerClosureReceiptSha256 = $expectedHeaderClosureReceiptSha256
    versionHeaderRelativePath = $headerRelativePath.Replace('\', '/')
    versionHeaderByteLength = $expectedHeaderByteLength
    versionHeaderSha256 = $expectedHeaderSha256
    localHttpPreflightStatusCode = 200
    localHttpPreflightSha256 = $expectedHeaderSha256
    cacheInspectionContractId = [string]$inspection.contractId
    longPathSafeEnumerationUsed = $true
    activeCacheFileCount = [int]$inspection.fileCount
    activeCacheContentByteLength = [long]$inspection.contentByteLength
    officialOutboundFallbackUsed = $false
    officialLauncherExecutionStarted = $false
    clientExecutionStarted = $true
    nextStepCode = `
        'select_global_observe_or_play_close_client_then_complete'
}
Write-Utf8NoBom $bindingPath (($binding | ConvertTo-Json -Depth 5) + "`n")

[pscustomobject]@{
    StartReceipt = $start
    NativeCacheBinding = $binding
    CompletionCommand = `
        "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-Minimal.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
} | ConvertTo-Json -Depth 8
