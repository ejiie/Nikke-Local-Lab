param([Parameter(Mandatory)][string]$InputPlanPath,[Parameter(Mandatory)][string]$InputPlanSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$inputPlan=Read-RnJson $InputPlanPath $InputPlanSha256
Assert-Rn ($inputPlan.contractId -ceq 'nll/user-validation-delivery-input/v1' -and $inputPlan.entries.Count -eq 5) 'uv_delivery_input_invalid'
foreach($pin in @($inputPlan.profile,$inputPlan.candidateReceipt,$inputPlan.powerShell)+@($inputPlan.checkerFiles)){Assert-RnPin $pin}
$profile=Read-RnJson $inputPlan.profile.path $inputPlan.profile.sha256
$candidate=Read-RnJson $inputPlan.candidateReceipt.path $inputPlan.candidateReceipt.sha256
Assert-Rn ($profile.schemaVersion -eq 3 -and $profile.contractId -ceq 'nll/boss-runtime-variant-profile/v3' -and
    $candidate.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and $candidate.profileSha256 -ceq $inputPlan.profile.sha256 -and
    $candidate.seasonNumber -eq $profile.seasonNumber -and $candidate.fiveAffinityVariantStatusCode -ceq 'passed' -and
    $candidate.affinityVariantCount -eq 5 -and $candidate.clientStarted -eq $false) 'uv_delivery_candidate_invalid'
$trial=[guid]::ParseExact($inputPlan.trialUid,'D').ToString('D')
$output='C:\NLL\Staging\NativeFxUserValidation\'+$trial+'\delivery\'+[guid]::ParseExact($inputPlan.deliveryUid,'D').ToString('D')
Assert-Rn ($trial -cne [guid]::Empty.ToString('D') -and $inputPlan.outputRoot -ceq $output) 'uv_delivery_root_invalid'
$checker=@($inputPlan.checkerFiles|Where-Object {$_.path.EndsWith('\NikkeLocalLab.UserValidationOfflineCheck.exe',[StringComparison]::Ordinal)})
Assert-Rn ($checker.Count -eq 1) 'uv_delivery_checker_invalid'
$rows=@();$proofs=@();$seen=@()
foreach($item in $inputPlan.entries){
    Assert-Rn ($item.weaknessCode -cin @('fire','water','wind','electric','iron') -and $item.weaknessCode -cnotin $seen) 'uv_delivery_duplicate_weakness'
    $seen+=$item.weaknessCode
    $uid=[guid]::ParseExact($item.assessmentUid,'D').ToString('D')
    $run='C:\NLL\Staging\NativeFxUserValidation\'+$trial+'\runs\'+$uid
    $path=Join-Path $run 'entry.private.json'
    Assert-Rn ((Get-RnHash $path) -ceq $item.entrySha256) 'uv_delivery_entry_drift'
    Assert-RnPin $item.inspectionLog
    $inspection=Read-RnJson $item.inspectionLog.path $item.inspectionLog.sha256
    Assert-Rn ($inspection.statusCode -ceq 'offline_inputs_verified' -and $inspection.weaknessCode -ceq $item.weaknessCode -and
        $inspection.gameStarted -eq $false -and $inspection.systemChangesApplied -eq $false -and
        $inspection.actualGameAcceptanceClaimed -eq $false) 'uv_delivery_inspection_failed'
    $checkOutput=@(& $checker[0].path $path $item.entrySha256)
    Assert-Rn ($LASTEXITCODE -eq 0 -and $checkOutput.Count -eq 1) 'uv_delivery_compiled_check_failed'
    $check=$checkOutput[0]|ConvertFrom-Json
    Assert-Rn ($check.contractId -ceq 'nll/user-validation-compiled-plan-check/v1' -and $check.trialUid -ceq $trial -and
        $check.assessmentUid -ceq $uid -and $check.weaknessCode -ceq $item.weaknessCode -and $check.entrySha256 -ceq $item.entrySha256 -and
        $check.compiledPlanBindingPassed -eq $true -and $check.gameStarted -eq $false -and $check.systemChangesApplied -eq $false) 'uv_delivery_compiled_binding_invalid'
    $parent=Read-RnJson (Join-Path $run 'validation.private.json') (Read-RnJson $path $item.entrySha256).parentPlan.sha256
    Assert-Rn ($parent.profileSha256 -ceq $inputPlan.profile.sha256 -and $parent.candidateReceiptSha256 -ceq $inputPlan.candidateReceipt.sha256 -and
        $parent.seasonNumber -eq $profile.seasonNumber) 'uv_delivery_profile_binding'
    $row=[ordered]@{weaknessCode=$item.weaknessCode;assessmentUid=$uid;entrySha256=$item.entrySha256};$rows+=,$row
    $proofs+=,[ordered]@{weaknessCode=$item.weaknessCode;assessmentUid=$uid;entrySha256=$item.entrySha256;
        controllerInspectionPassed=$true;compiledPlanBindingPassed=$true;inspectionLogSha256=$item.inspectionLog.sha256}
}
New-RnPrivateDirectory $output
$proof=[ordered]@{contractId='nll/user-validation-offline-matrix/v1';trialUid=$trial;profileSha256=$inputPlan.profile.sha256;
    candidateReceiptSha256=$inputPlan.candidateReceipt.sha256;entries=$proofs;gameStarted=$false;systemChangesApplied=$false;actualGameAcceptanceClaimed=$false}
$proofPath=Join-Path $output 'offline-matrix.receipt.json';Write-RnNewJson $proofPath $proof
$manifest=[ordered]@{schemaVersion=1;contractId='nll/user-validation-delivery/v1';statusCode='awaiting_game_validation';
    seasonNumber=$profile.seasonNumber;trialUid=$trial;profileSha256=$inputPlan.profile.sha256;candidateReceiptSha256=$inputPlan.candidateReceipt.sha256;
    profile=$inputPlan.profile;candidateReceipt=$inputPlan.candidateReceipt;offlineCheckReceipt=(Get-RnPin $proofPath);
    powerShell=$inputPlan.powerShell;entries=$rows;nativeClientExecuted=$false;actualGameAcceptanceClaimed=$false}
$path=Join-Path $output 'delivery.private.json';Write-RnNewJson $path $manifest
[ordered]@{contractId=$manifest.contractId;deliveryUid=$inputPlan.deliveryUid;manifestSha256=(Get-RnHash $path);
    statusCode=$manifest.statusCode;gameStarted=$false;operationalRegistryModified=$false;actualGameAcceptanceClaimed=$false}|ConvertTo-Json -Compress
