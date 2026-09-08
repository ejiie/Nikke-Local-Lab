[CmdletBinding()]
param([switch]$StageInputs,[switch]$UseLocalKeyBinding,[switch]$UseSourceBaseline,[switch]$UseEpinelProvided)
# Prepare a new diagnostic only. No native execution or system/client mutation.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.ResourceHeader.ps1')
# The reviewed package passed synthetic checks but regressed native DownloadPatch
# in assessment 09146989-65e5-4e44-bc30-2dabd8c9470c. Stock reversal reproduced
# 4/7 passage. Do not stage this package again; retain historical v3 recovery.
if ($UseLocalKeyBinding) { Assert-Rn $false 'key_library_native_regression' }
Assert-Rn (-not ($UseEpinelProvided -and $UseSourceBaseline)) 'native_mode_conflict'
$replaceNative=[bool]($UseLocalKeyBinding -or $UseSourceBaseline -or $UseEpinelProvided)
$planVersion=if ($UseEpinelProvided) {'v5'} elseif ($UseSourceBaseline) {'v4'} elseif ($UseLocalKeyBinding) {'v3'} else {'v2'}
$planContract='nll/resource-native-observation-plan/'+$planVersion
$nativeMode=if ($UseEpinelProvided) {'epinel_provided_library_control'} elseif ($UseSourceBaseline) {'source_built_unmodified_control'} elseif ($UseLocalKeyBinding) {'source_built_local_key_binding'} else {'stock_native_library_preserved'}
$repository='C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
$clientRoot='C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe'
$game=Join-Path $clientRoot 'NIKKE\game'
$plugins=Join-Path $game 'nikke_Data\Plugins\x86_64'
$hostsPath=Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$helper=Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1'
$runner=Join-Path $PSScriptRoot 'invoke-nll-resource-native-observation.ps1'
$sourceMetadata='C:\NLL\Staging\ResourceVersionInputs\1f4366d1-b809-4260-9b9c-91b19a948254\version-metadata.txt'
$sourceCertificate='C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9\site.pfx'
$publicRoot='C:\NLL\EpinelPS\ServerSelector\myCA.cer'
$replacementShim=Join-Path $repository '.external\EpinelPS-151-candidate\ServerSelector.Desktop\sodium.dll'
$sourcePins=@(
    @((Join-Path $game 'nikke.exe'),'36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732'),
    @((Join-Path $plugins 'sodium.dll'),'11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f'),
    @((Join-Path $plugins 'intl_cacert.pem'),'921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d'),
    @($replacementShim,'54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662'),
    @($sourceMetadata,'df1d7403a5a24f16fb5eb59ba436c1f04236b691f95ef30634f22b92ed306856'),
    @($sourceCertificate,'2f330431fa83c68ae7a613cd0c7a1f35c51d54a66771c75073035c52a8e545df'),
    @($publicRoot,'6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda')
)
foreach ($pin in $sourcePins) { Assert-Rn ((Get-RnHash $pin[0]) -ceq $pin[1]) 'source_drift' }
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.Name -match '^(nikke|nikke_launcher|EpinelPS|NikkeLocalLab\.Phase3B2\..*Bootstrap)\.exe$'}).Count -eq 0) 'runtime_not_cold'
$preferences=@(Get-RnVoicePreferences)
$clientPrograms=@(Get-ChildItem -LiteralPath $clientRoot -Recurse -File -Filter '*.exe' | Sort-Object FullName)
Assert-Rn ($clientPrograms.Count -eq 6) 'client_program_inventory_changed'
foreach ($file in $clientPrograms) { Assert-RnPath $file.FullName }
# Default nll/resource-native-observation-plan/v2 preserves stock. The regressing v3 package is blocked above;
# explicit v4 admits only the exact unmodified-source rebuild as a control.
# Operator-authorized v5 admits the unchanged Epinel DLL, not our rebuild.
$keyBinding=$null
if ($UseLocalKeyBinding) {
    $keyRoot=Join-Path $repository 'artifacts\resource-probe-151\native-key-compat-v1'
    $keyBinding=[ordered]@{libraryPin=(Get-RnPin (Join-Path $keyRoot 'local\sodium.dll'))
        buildReceiptPin=(Get-RnPin (Join-Path $keyRoot 'build.private.json'));testReceiptPin=(Get-RnPin (Join-Path $keyRoot 'synthetic.private.json'))}
    Assert-RnLocalKeyBinding $keyBinding
}
if ($UseSourceBaseline) {
    $keyRoot=Join-Path $repository 'artifacts\resource-probe-151\native-key-compat-v1'
    $keyBinding=[ordered]@{libraryPin=(Get-RnPin (Join-Path $keyRoot 'baseline\sodium.dll'))
        buildReceiptPin=(Get-RnPin (Join-Path $keyRoot 'build.private.json'));testReceiptPin=(Get-RnPin (Join-Path $keyRoot 'baseline-synthetic.private.json'))}
    Assert-RnSourceBaseline $keyBinding
}
if ($UseEpinelProvided) {
    $keyBinding=[ordered]@{libraryPin=(Get-RnPin $replacementShim);authorizationId='operator-2026-09-06-epinel-provided-151/v1'}
    Assert-RnEpinelProvided $keyBinding
}
if (-not $StageInputs) {
    [ordered]@{status='native_inputs_inspected_not_staged';planContract=$planContract;nativeCompatibilityMode=$nativeMode;diagnosticHttpLayerPresent=$false;systemChangesApplied=$false;clientStarted=$false;serverStarted=$false} | ConvertTo-Json
    return
}
$auth=(& (Join-Path $PSScriptRoot 'prepare-nll-resource-probe-auth-smoke.ps1') -StageInputs | ConvertFrom-Json)
$uid=$auth.assessmentUid
$server=Join-Path 'C:\NLL\Runtime\EpinelPS-151-ResourceProbe' $uid
$bootstrap=Join-Path 'C:\NLL\Runtime\ResourceProbeBootstrap' $uid
$evidence=Join-Path 'C:\NLL\Staging\ResourceProbeRuns' $uid
$rollback=Join-Path $evidence 'rollback'
New-RnPrivateDirectory $rollback
Copy-RnNew $helper (Join-Path $evidence 'Nll.ResourceNative.ps1')
Copy-RnNew $runner (Join-Path $evidence 'invoke-nll-resource-native-observation.ps1')
Copy-RnNew (Join-Path $PSScriptRoot 'restore-nll-resource-native-observation.ps1') (Join-Path $evidence 'restore-nll-resource-native-observation.ps1')
$configPath=Join-Path $server 'gameconfig.json'
$config=Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$uri=[UriBuilder]::new($config.ResourceBaseURL.Replace('{Platform}','StandaloneWindows64'))
$uri.Port=443
$config.ResourceBaseURL=$uri.Uri.AbsoluteUri.Replace('StandaloneWindows64','{Platform}')
# These fresh diagnostic files belong to this preparation, not a prior run.
[IO.File]::WriteAllText($configPath,($config | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
$fileChanges=@()
if ($replaceNative) {
    $target=Join-Path $plugins 'sodium.dll'
    $before=Join-Path $rollback 'sodium.dll.before'
    $after=Join-Path $rollback 'sodium.dll.after'
    Copy-RnNew $target $before
    Copy-RnNew $keyBinding.libraryPin.path $after
    if ($UseEpinelProvided) {
        $keyBinding=[ordered]@{libraryPin=(Get-RnPin $after);authorizationId=$keyBinding.authorizationId}
        Assert-RnEpinelProvided $keyBinding
    } else {
        Copy-RnNew $keyBinding.buildReceiptPin.path (Join-Path $rollback 'key-build.private.json')
        Copy-RnNew $keyBinding.testReceiptPin.path (Join-Path $rollback 'key-test.private.json')
        $keyBinding=[ordered]@{libraryPin=(Get-RnPin $after);buildReceiptPin=(Get-RnPin (Join-Path $rollback 'key-build.private.json'));testReceiptPin=(Get-RnPin (Join-Path $rollback 'key-test.private.json'))}
        if ($UseSourceBaseline) {Assert-RnSourceBaseline $keyBinding} else {Assert-RnLocalKeyBinding $keyBinding}
    }
    $fileChanges += [ordered]@{before=(Get-RnPin $target);backup=(Get-RnPin $before);replacement=(Get-RnPin $after)}
}
foreach ($name in @('intl_cacert.pem')) {
    $target=Join-Path $plugins $name
    $before=Join-Path $rollback ($name + '.before')
    $after=Join-Path $rollback ($name + '.after')
    Copy-RnNew $target $before
    $bytes=[IO.File]::ReadAllBytes($target) + [Text.Encoding]::ASCII.GetBytes("`nNLL local probe CA`n") + [IO.File]::ReadAllBytes($publicRoot)
    Write-RnNewBytes $after $bytes
    $fileChanges += [ordered]@{before=(Get-RnPin $target);backup=(Get-RnPin $before);replacement=(Get-RnPin $after)}
}
$hosts=@('li-sg.intlgame.com','aws-na.intlgame.com','cloud.nikke-kr.com','nikke-gate.nikke-kr.com',
    'jp-lobby.nikke-kr.com','us-lobby.nikke-kr.com','kr-lobby.nikke-kr.com','global-lobby.nikke-kr.com','sea-lobby.nikke-kr.com')
$hostsBackup=Join-Path $rollback 'hosts.before'
$hostsAfter=Join-Path $rollback 'hosts.after'
Copy-RnNew $hostsPath $hostsBackup
Write-RnNewBytes $hostsAfter (New-RnHostsBytes ([IO.File]::ReadAllBytes($hostsBackup)) $hosts $uid)
$fileChanges += [ordered]@{before=(Get-RnPin $hostsPath);backup=(Get-RnPin $hostsBackup);replacement=(Get-RnPin $hostsAfter)}
$desired=@((ConvertTo-RnVoicePreference $preferences[0] 'ko'),(ConvertTo-RnVoicePreference $preferences[1] 'Minimal'))
$runtimePlanPath=Join-Path $server 'resource-probe-runtime.private.json'
$serverPins=@(Get-ChildItem -LiteralPath $server -Recurse -File | Where-Object FullName -ne $runtimePlanPath | Sort-Object FullName | ForEach-Object { $pin=Get-RnPin $_.FullName; $pin.path=[IO.Path]::GetRelativePath($server,$_.FullName).Replace('\','/'); $pin })
$headerPlan=Get-NllResourceHeaderPlan -Config $config -SourceConfigSha256 $auth.sourceConfigSha256 `
    -InputDirectory (Split-Path -Parent $sourceMetadata) -ExpectedAcquisitionReceiptSha256 $auth.versionInputReceiptSha256 `
    -ExpectedMetadataSha256 $auth.versionHeaderSha256 -Platform 'StandaloneWindows64'
Assert-NllResourceHeaderManifest -RuntimeRoot $server -Plan $headerPlan -Files $serverPins
$runtimePlan=[ordered]@{contractId='nll/epinel-resource-probe-runtime/v2';assessmentUid=$uid;durationSeconds=240;files=$serverPins}
[IO.File]::WriteAllText($runtimePlanPath,($runtimePlan | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$bootstrapPath=Join-Path $bootstrap 'bootstrap.private.json'
$bootstrapPlan=Get-Content -LiteralPath $bootstrapPath -Raw | ConvertFrom-Json
$bootstrapPlan.authOnly=$false
$bootstrapPlan.durationSeconds=180
$clientPins=@(Get-ChildItem -LiteralPath $game -Recurse -File | Where-Object {$_.Extension -in '.dll','.exe' -or $_.Name -eq 'intl_cacert.pem'} | ForEach-Object {
    $pin=Get-RnPin $_.FullName
    foreach ($change in $fileChanges) { if ($pin.path -ieq $change.before.path) {$pin.length=$change.replacement.length; $pin.sha256=$change.replacement.sha256} }
    $pin
})
$bootstrapPlan.clientFiles=$clientPins
[IO.File]::WriteAllText($bootstrapPath,($bootstrapPlan | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
# Include installed official launcher helpers as block-only programs. They are
# never launch targets; a native attempt spawning them must be stopped.
$blockOnly=@(Get-RnBlockOnlyProgramPaths | ForEach-Object {Get-RnPin $_})
$programs=@($clientPrograms | ForEach-Object {Get-RnPin $_.FullName}) + @((Get-RnPin (Join-Path $server 'EpinelPS.exe')),(Get-RnPin (Join-Path $bootstrap 'NikkeLocalLab.Phase3B2.ResourceProbeBootstrap.exe')))
$plan=[ordered]@{contractId=$planContract;assessmentUid=$uid;operatorSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    serverRoot=$server;bootstrapRoot=$bootstrap;evidenceRoot=$evidence;clientRoot=$clientRoot
    helperSha256=(Get-RnHash (Join-Path $evidence 'Nll.ResourceNative.ps1'));runnerSha256=(Get-RnHash (Join-Path $evidence 'invoke-nll-resource-native-observation.ps1'))
    serverPlanSha256=(Get-RnHash $runtimePlanPath);bootstrapPlanSha256=(Get-RnHash $bootstrapPath)
    nativeCompatibilityMode=$nativeMode;stockNativePin=(Get-RnPin (Join-Path $plugins 'sodium.dll'))
    programs=$programs;blockOnlyPrograms=$blockOnly;fileChanges=$fileChanges;preferencesBefore=$preferences;preferencesAfter=$desired
    publicRoot=(Get-RnPin $publicRoot);durationSeconds=240;gameplayAllowed=$false}
if ($replaceNative) { $plan['nativeKeyBinding']=$keyBinding }
Write-RnNewJson (Join-Path $evidence 'native.private.json') $plan
$receipt=[ordered]@{contractId=('nll/resource-native-preparation/'+$planVersion);assessmentUid=$uid;status='staged_not_started'
    nativeCompatibilityMode=$plan.nativeCompatibilityMode
    versionHeaderSha256=$headerPlan.sha256;versionHeaderBytes=$headerPlan.length;versionHeaderCacheVerified=$true
    requestPipeline='epinel_existing_handlers';diagnosticHttpLayerPresent=$false
    planSha256=(Get-RnHash (Join-Path $evidence 'native.private.json'));programCount=$programs.Count;blockOnlyProgramCount=$blockOnly.Count
    clientPinCount=$clientPins.Count;clientStarted=$false;serverStarted=$false;nativeAdmission='not_evaluated'}
Write-RnNewJson (Join-Path $evidence 'native-preparation.receipt.json') $receipt
$receipt | ConvertTo-Json
