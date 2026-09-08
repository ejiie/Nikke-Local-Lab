[CmdletBinding()]
param([switch]$CheckPublished)
# Source/packaging checks only: never starts a server/client or changes Windows.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repository=Split-Path -Parent $PSScriptRoot
$candidate=Join-Path $repository '.external\EpinelPS-151-candidate\EpinelPS'
$baseline=Join-Path $repository '.external\EpinelPS\EpinelPS'
$checks=0
function Assert-Removal([bool]$Condition,[string]$Code) {
    if (-not $Condition) {throw ('resource_http_removal_'+$Code)}
    $script:checks++
}
function Read-Source([string]$Path) {Get-Content -LiteralPath $Path -Raw}
$program=Read-Source (Join-Path $candidate 'Program.cs')
$execution=Read-Source (Join-Path $repository 'tools\Phase3B2\EpinelResourceProbe\ResourceProbeExecution.cs')
$project=Read-Source (Join-Path $candidate 'EpinelPS.csproj')
foreach ($removed in @('HandleAsync','SetLocalStartupAuthorization','EmbeddedResourceObserver','DispatchMode','LegacyPipelinePassthrough','GuardedDispatch','NllResourceTransport')) {
    Assert-Removal (($execution -cnotmatch [regex]::Escape($removed)) -and
        ($program -cnotmatch [regex]::Escape($removed)) -and
        ($project -cnotmatch [regex]::Escape($removed))) 'inspection_wiring_present'
}
Assert-Removal ($execution -notmatch 'using Microsoft.AspNetCore|HttpContext|RequestDelegate') 'http_dependency_present'
Assert-Removal ($project -notmatch 'ResourceCatalogPreflight.csproj') 'observer_project_reference_present'
Assert-Removal (-not (Test-Path -LiteralPath (Join-Path $repository 'tools\Phase3B2\ResourceCatalogPreflight\EmbeddedResourceObserver.cs'))) 'adapter_source_present'
$pattern='(?s)app\.UseDefaultFiles\(\);.*?(?=if \(executionMode.StartInteractiveCli\))'
$actual=[regex]::Match($program,$pattern).Value.Trim()
$expected=[regex]::Match((Read-Source (Join-Path $baseline 'Program.cs')),$pattern).Value.Trim()
Assert-Removal ($actual.Length -gt 1000 -and $actual -ceq $expected) 'existing_http_pipeline_changed'
foreach ($path in @('Controllers\LobbyApiController.cs','Networking\EncryptionMiddleware.cs',
    'Utils\PacketDecryption.cs','Utils\NetUtils.cs','Utils\AssetDownloadUtil.cs',
    'LobbyServer\LobbyHandler.cs','LobbyServer\Misc\GetServerInfo.cs','LobbyServer\Misc\GetSentryParams.cs')) {
    # Source equivalence; checkouts may differ only in CRLF/LF encoding.
    Assert-Removal ((Read-Source (Join-Path $candidate $path)).Replace("`r`n","`n") -ceq
        (Read-Source (Join-Path $baseline $path)).Replace("`r`n","`n")) 'existing_handler_changed'
}
foreach ($retained in @('AssetDownloadUtil.ConfigureOfficialOutbound(executionMode.AllowOfficialOutbound)',
    'serverOptions.Listen(executionMode.ListenAddress','ResourceProbeExecution.Configure(builder.Configuration)',
    'TimeSpan.FromSeconds(resourceProbe.DurationSeconds)')) {
    Assert-Removal ($program.Contains($retained)) 'process_boundary_missing'
}
foreach ($retained in @('VerifyFiles(directory, plan.Files)','inherited_raid_configuration','runtime_not_fresh',
    'FileMode.CreateNew','file_reparse_or_missing','plan_hash_drift','runtime_inventory_drift',
    'JsonUnmappedMemberHandling.Disallow','nll/epinel-resource-probe-runtime/v2')) {
    Assert-Removal ($execution.Contains($retained)) 'sealed_runtime_boundary_missing'
}
$prepare=Read-Source (Join-Path $PSScriptRoot 'prepare-nll-resource-native-observation.ps1')
$runner=Read-Source (Join-Path $PSScriptRoot 'invoke-nll-resource-native-observation.ps1')
$auth=Read-Source (Join-Path $PSScriptRoot 'prepare-nll-resource-probe-auth-smoke.ps1')
$authRunner=Read-Source (Join-Path $PSScriptRoot 'invoke-nll-resource-probe-auth-smoke.ps1')
Assert-Removal (($prepare+$runner) -notmatch 'DispatchMode|legacy_pipeline_passthrough|startup-dispatch|route-observation|probe.private.json') 'removed_mode_or_observer_plan_present'
Assert-Removal ($auth.Contains('artifacts\resource-probe-151\epinel-server-v2')) 'old_publish_target_present'
Assert-Removal ($prepare.Contains('nll/resource-native-observation-plan/v2') -and $runner.Contains('nll/resource-native-observation-plan/v2')) 'native_contract_mismatch'
Assert-Removal ($auth.Contains('nll/epinel-resource-probe-runtime/v2') -and $prepare.Contains('nll/epinel-resource-probe-runtime/v2')) 'server_contract_mismatch'
Assert-Removal ($auth.Contains('nll/resource-probe-auth-preparation/v2') -and
    $authRunner.Contains('nll/resource-probe-auth-preparation/v2') -and
    $authRunner.Contains('nll/epinel-resource-probe-runtime/v2')) 'auth_contract_mismatch'
Assert-Removal ($runner.Contains("requestCount=`$null;requestCountSource='not_collected'")) 'missing_count_claimed_as_zero'
foreach ($retained in @('Assert-NativeFirewall','non_loopback_listener','non_loopback_connection',
    'Set-RnPinnedFile','Set-RnVoicePreferences','root_cleanup_failed','firewall_cleanup_failed',
    'stock_native_library_preserved','Assert-RnPin $plan.stockNativePin','official_launcher_spawned')) {
    Assert-Removal ($runner.Contains($retained)) 'native_isolation_or_recovery_missing'
}
foreach ($name in @('prepare-nll-resource-native-observation.ps1','prepare-nll-resource-probe-auth-smoke.ps1',
    'invoke-nll-resource-native-observation.ps1','invoke-nll-resource-probe-auth-smoke.ps1','restore-nll-resource-native-observation.ps1')) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Assert-Removal ($errors.Count -eq 0) 'powershell_parse_failed'
}
if ($CheckPublished) {
    $published=Join-Path $repository 'artifacts\resource-probe-151\epinel-server-v2'
    $deps=Read-Source (Join-Path $published 'EpinelPS.deps.json')
    Assert-Removal ($deps -notmatch 'ResourceCatalogPreflight|NikkeLocalLab\.(Identity|Provenance)') 'published_observer_dependency_present'
    Assert-Removal (@(Get-ChildItem -LiteralPath $published -File -Filter '*ResourceCatalogPreflight*').Count -eq 0) 'stale_observer_binary_present'
    Assert-Removal ((Test-Path -LiteralPath (Join-Path $published 'EpinelPS.dll')) -and
        (Test-Path -LiteralPath (Join-Path $published 'EpinelPS.exe'))) 'published_server_missing'
}
[ordered]@{status='passed';checks=$checks;publishedChecked=[bool]$CheckPublished;clientStarted=$false;serverStarted=$false;systemChangesApplied=$false} | ConvertTo-Json
