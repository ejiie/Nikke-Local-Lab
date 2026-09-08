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

$expectedDeploymentReceiptSha256 = `
    '__NATIVE_CACHE_DEPLOYMENT_RECEIPT_SHA256__'
$expectedMaterializationReceiptSha256 = `
    '89a76b1e5237ea3864d87303418e638d9ad7de0570ad456182568a17c5ead921'
$expectedCanonicalSha256 = `
    '95000d45cb52f4bdd81b6ca9caf7e2e13eeae7bbddfa67e33ed8ef8896f22ffe'
$deploymentPath = `
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-native-cache-deployment-v1\deployment.receipt.json'
$cacheRoot = `
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$minimalStartPath = 'C:\NLL\Tools\Start-Phase3B2-Epinel-Minimal.ps1'
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
    (Test-Path -LiteralPath $minimalStartPath -PathType Leaf) -and
    (Test-Path -LiteralPath $cacheRoot -PathType Container)
) 'phase3b2_epinel_native_cache_start_input_missing_or_drifted'

$deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $deployment.contractId -ceq `
        'nll/phase3b2-epinel-native-cache-offline-deployment/v1' -and
    $deployment.materializationReceiptSha256 -ceq `
        $expectedMaterializationReceiptSha256 -and
    $deployment.materializationCanonicalSha256 -ceq `
        $expectedCanonicalSha256 -and
    $deployment.nativeCacheDeploymentVerified -and
    $deployment.activeCacheFileCount -eq 40108 -and
    $deployment.remoteMaterializationMemberCount -eq 40097 -and
    $deployment.nonRemoteEntryDataCount -eq 184 -and
    $deployment.databaseRestored -and
    $deployment.sqliteRuntimeRemoved -and
    -not $deployment.clientExecutionStarted -and
    -not $deployment.serverExecutionStarted
) 'phase3b2_epinel_native_cache_start_deployment_contract_invalid'

$cacheFiles = @(Get-ChildItem -LiteralPath $cacheRoot -File -Recurse)
Assert-True (
    $cacheFiles.Count -eq 40108 -and
    [long](($cacheFiles | Measure-Object Length -Sum).Sum) -eq `
        ([long]$deployment.activeCacheContentByteLength) -and
    @($cacheFiles | Where-Object {
        $_.Name -like '*.partial.*'
    }).Count -eq 0
) 'phase3b2_epinel_native_cache_start_cache_shape_invalid'

Get-NetFirewallRule -Group $extensionFirewallGroup `
    -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Assert-True (
    @(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_epinel_native_cache_start_stale_firewall_cleanup_failed'

$startText = (& $minimalStartPath | Out-String).Trim()
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

$bindingPath = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1\' +
    [string]$start.assessmentUid
) 'native-cache.binding.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $bindingPath)) `
    'phase3b2_epinel_native_cache_start_binding_collision'
$binding = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-epinel-native-cache-run-binding/v1'
    boundAtUtc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss'Z'"
    )
    assessmentUid = [string]$start.assessmentUid
    deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
    materializationReceiptSha256 = $expectedMaterializationReceiptSha256
    materializationCanonicalSha256 = $expectedCanonicalSha256
    materializedMemberCount = 40103
    activeCacheFileCount = 40108
    remoteMaterializationMemberCount = 40097
    nonRemoteEntryDataCount = 184
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
