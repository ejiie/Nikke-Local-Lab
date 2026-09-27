[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$InputPlanSha256
)
# Preparation has no launch or system-mutation mode. It writes new private
# controller/child files and plans, reusing ONE already-owned client clone.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedDriver.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationController.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationPreflight.ps1')
$inputPlan=Read-RnJson $InputPlanPath $InputPlanSha256
Assert-Rn ($inputPlan.contractId -ceq 'nll/user-validation-controller-input/v1') 'uv_prepare_input_invalid'
foreach($pin in @($inputPlan.stagingReceipt,$inputPlan.storePlan,$inputPlan.clientManifest,$inputPlan.storeTool)+@($inputPlan.childFiles)+@($inputPlan.protectedFiles)){Assert-RnPin $pin}
$staging=Read-RnJson $inputPlan.stagingReceipt.path $inputPlan.stagingReceipt.sha256
$store=Read-RnJson $inputPlan.storePlan.path $inputPlan.storePlan.sha256
$manifest=Read-RnJson $inputPlan.clientManifest.path $inputPlan.clientManifest.sha256
$uid=[guid]::ParseExact($staging.assessmentUid,'D').ToString('D');$trial=[guid]::ParseExact($staging.trialUid,'D').ToString('D')
$run='C:\NLL\Staging\NativeFxUserValidation\'+$trial+'\runs\'+$uid
$client='C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$trial
Assert-Rn ($staging.runRoot -ceq $run -and $staging.contractId -ceq 'nll/user-validation-runtime-staging/v1' -and
    $inputPlan.stagingReceipt.path -ceq (Join-Path $run 'runtime-staging.receipt.json') -and
    $inputPlan.storePlan.path -ceq (Join-Path $run 'native-store.private.json') -and
    $manifest.contractId -ceq 'nll/user-validation-client-pins/v1' -and $manifest.trialUid -ceq $trial -and
    $manifest.clientRoot -ceq $client -and $manifest.files.Count -gt 0 -and $manifest.files.Count -le 10000) 'uv_prepare_input_binding'
foreach($pair in $manifest.rollback){Assert-RnPin $pair.backup}
$pins=@($manifest.files)
Assert-Rn (@($pins.path|Sort-Object -Unique).Count -eq $pins.Count -and @($pins|Where-Object {
    -not $_.path.StartsWith($client+'\',[StringComparison]::Ordinal) -or $_.path.Contains('..')}).Count -eq 0) 'uv_prepare_client_paths'
# The shared snapshot producer already hashes/physically verifies the client.
# Do not reread the same 19 GiB for each PLAN. Inspect/Start and the bootstrap
# independently verify the current physical client before accepting a launch.
Assert-Rn (@(Compare-Object ($pins.path|Sort-Object) (@(Get-ChildItem -LiteralPath $client -Recurse -File|ForEach-Object FullName)|Sort-Object)).Count -eq 0) 'uv_prepare_client_inventory'
foreach($pin in @($staging.serverFiles)+@($staging.bootstrapFiles)){Assert-RnPin $pin}
$storePins=@($pins|Where-Object path -CEQ $store.originalStore.path)
Assert-Rn ($storePins.Count -eq 1 -and $storePins[0].sha256 -ceq $store.originalStore.sha256 -and
    $storePins[0].length -eq $store.originalStore.length) 'uv_prepare_store_binding'
$childRoot='C:\NLL\Runtime\NativeFxUserValidationChild\'+$uid
$controller=Join-Path $run 'controller';$rollback=Join-Path $run 'rollback'
foreach($target in @($childRoot,$controller,$rollback,(Join-Path $run 'validation.private.json'),
    (Join-Path $run 'entry.private.json'),(Join-Path $staging.bootstrapRoot 'bootstrap.private.json'))){
    Assert-RnPath $target;Assert-Rn (-not (Test-Path -LiteralPath $target)) 'uv_prepare_output_exists'
}
$childNames=@('.exe','.dll','.deps.json','.runtimeconfig.json'|ForEach-Object {'NikkeLocalLab.NativeFxUserValidationChild'+$_})
Assert-Rn ($inputPlan.childFiles.Count -eq 4 -and
    @(Compare-Object ($childNames|Sort-Object) (@($inputPlan.childFiles|ForEach-Object {Split-Path -Leaf $_.path})|Sort-Object)).Count -eq 0) 'uv_prepare_child_inventory'
Assert-FxManagedServiceSnapshot (Get-FxManagedServiceSnapshot) before
Assert-FxManagedServiceNoDependents
$driver=New-FxValidationDriverPolicy (Get-FxValidationDriverSnapshot)
$blocked=@(Get-RnBlockOnlyProgramPaths)+@(Get-ChildItem -LiteralPath 'C:\Program Files\AntiCheatExpert' -Recurse -File -Filter '*.exe'|ForEach-Object FullName)
$blockedPins=@($blocked|Sort-Object -Unique|ForEach-Object {Get-RnPin $_})
$preferences=Get-UvVoicePreferences
Assert-Rn (Compare-UvVoicePreferences $preferences $preferences).equal 'uv_prepare_preferences_invalid'
foreach($target in @($childRoot,$controller,$rollback)){New-RnPrivateDirectory $target}
foreach($pin in $inputPlan.childFiles){Copy-RnNew $pin.path (Join-Path $childRoot (Split-Path -Leaf $pin.path))}
$helperNames=@('Nll.ResourceNative.ps1','Nll.NativeFxManagedService.ps1','Nll.NativeFxManagedDriver.ps1',
    'Nll.UserValidationController.ps1','Nll.UserValidationPreflight.ps1','Nll.PhaseDJob.cs','Nll.FxProcessIdentity.cs')
foreach($name in $helperNames+@('invoke-nll-user-validation.ps1')){Copy-RnNew (Join-Path $PSScriptRoot $name) (Join-Path $controller $name)}
Copy-RnNew $inputPlan.storeTool.path (Join-Path $controller 'NikkeLocalLab.NativeFxUserValidationStore.dll')
$hostsPath='C:\Windows\System32\drivers\etc\hosts';$before=Join-Path $rollback 'hosts.before';$after=Join-Path $rollback 'hosts.after'
Copy-RnNew $hostsPath $before
$hosts=@('li-sg.intlgame.com','aws-na.intlgame.com','cloud.nikke-kr.com','nikke-gate.nikke-kr.com',
    'jp-lobby.nikke-kr.com','us-lobby.nikke-kr.com','kr-lobby.nikke-kr.com','global-lobby.nikke-kr.com','sea-lobby.nikke-kr.com')
Write-RnNewBytes $after (New-RnHostsBytes ([IO.File]::ReadAllBytes($before)) $hosts $uid)
$childPins=@(Get-ChildItem -LiteralPath $childRoot -File|Sort-Object FullName|ForEach-Object {Get-RnPin $_.FullName})
$programs=@(Get-ChildItem -LiteralPath $client -Recurse -File -Filter '*.exe'|ForEach-Object {Get-RnPin $_.FullName})+
    @((Get-RnPin (Join-Path $staging.serverRoot 'EpinelPS.exe')),
    (Get-RnPin (Join-Path $staging.bootstrapRoot 'NikkeLocalLab.NativeFxUserValidationBootstrap.exe')),
    (Get-RnPin (Join-Path $childRoot 'NikkeLocalLab.NativeFxUserValidationChild.exe')))
$plan=[ordered]@{contractId='nll/native-fx-user-validation/v1';trialUid=$trial;assessmentUid=$uid;executionOwnerCode='user';
    seasonNumber=$staging.seasonNumber;weaknessCode=$staging.weaknessCode;caseCode='candidate';durationSeconds=1200;
    profileSha256=$staging.profileSha256;candidateReceiptSha256=$staging.candidateReceiptSha256;
    runtimeStagingSha256=$inputPlan.stagingReceipt.sha256;nativeStorePlanSha256=$inputPlan.storePlan.sha256;
    runRoot=$run;clientRoot=$client;serverRoot=$staging.serverRoot;bootstrapRoot=$staging.bootstrapRoot;childRoot=$childRoot;
    jobName=('Local\NLL.FxValidation.'+[guid]::Parse($uid).ToString('N'));operatorSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
    childFiles=$childPins;clientFiles=$pins;clientRollbackManifest=$inputPlan.clientManifest;programs=$programs;blockOnlyPrograms=$blockedPins;protectedFiles=$inputPlan.protectedFiles;
    publicRoot=(Get-RnPin (Join-Path $staging.bootstrapRoot 'trust-root.cer'));
    serviceImage=(Get-RnPin 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe');driverPolicy=$driver;
    hostsChange=[ordered]@{before=(Get-RnPin $hostsPath);backup=(Get-RnPin $before);replacement=(Get-RnPin $after)};
    preferencesBefore=$preferences;preferencesAfter=@((ConvertTo-RnVoicePreference $preferences[0] 'ko'),(ConvertTo-RnVoicePreference $preferences[1] 'Minimal'))}
$planPath=Join-Path $run 'validation.private.json'
Write-RnNewJson $planPath $plan
$candidateStore=[ordered]@{path=$store.originalStore.path;length=$store.originalStore.length;sha256=$store.candidateStoreSha256}
$boot=[ordered]@{contractId='nll/native-fx-user-validation-bootstrap/v1';assessmentUid=$uid;trialUid=$trial;executionOwnerCode='user';
    durationSeconds=$plan.durationSeconds;seasonNumber=$plan.seasonNumber;weaknessCode=$plan.weaknessCode;caseCode='candidate';
    profileSha256=$plan.profileSha256;candidateReceiptSha256=$plan.candidateReceiptSha256;parentPlanSha256=(Get-RnHash $planPath);
    jobName=$plan.jobName;nativeStore=$candidateStore;runtimeFiles=$staging.bootstrapFiles;
    clientFiles=@(foreach($pin in $pins){if($pin.path -ceq $candidateStore.path){$candidateStore}else{$pin}})}
Assert-UvBinding $plan $boot $staging $store
$bootPath=Join-Path $staging.bootstrapRoot 'bootstrap.private.json';Write-RnNewJson $bootPath $boot
$entry=[ordered]@{contractId='nll/user-validation-entry/v1';preflightContractId='nll/user-validation-preflight/v1';preflightMode='deep';controller=(Get-RnPin (Join-Path $controller 'invoke-nll-user-validation.ps1'));
    tools=@($helperNames+@('NikkeLocalLab.NativeFxUserValidationStore.dll')|ForEach-Object {Get-RnPin (Join-Path $controller $_)});
    parentPlan=(Get-RnPin $planPath);bootstrapPlan=(Get-RnPin $bootPath);stagingReceipt=$inputPlan.stagingReceipt;storePlan=$inputPlan.storePlan}
$entryPath=Join-Path $run 'entry.private.json';Write-RnNewJson $entryPath $entry
foreach($pin in @($inputPlan.stagingReceipt,$inputPlan.storePlan,$inputPlan.clientManifest,$inputPlan.storeTool)+@($inputPlan.protectedFiles)){Assert-RnPin $pin}
$receipt=[ordered]@{contractId='nll/user-validation-controller-prepared/v1';assessmentUid=$uid;trialUid=$trial;
    weaknessCode=$plan.weaknessCode;entrySha256=(Get-RnHash $entryPath);gameStarted=$false;clientModified=$false;
    systemChangesApplied=$false;statusCode='controller_prepared_pending_offline_check';actualGameAcceptanceClaimed=$false}
Write-RnNewJson (Join-Path $run 'controller-prepared.receipt.json') $receipt
$receipt|ConvertTo-Json -Compress
