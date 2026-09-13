[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$InputPlanSha256
)
# Read-only client preparation; only NEW per-run rollback chunks/plans are saved.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$inputPlan=Read-RnJson $InputPlanPath $InputPlanSha256
Assert-Rn ($inputPlan.contractId -ceq 'nll/user-validation-store-input/v1') 'validation_store_input_invalid'
foreach($pin in @($inputPlan.stagingReceipt,$inputPlan.nativeChunkReceipt,$inputPlan.storeTool)){Assert-RnPin $pin}
$staged=Read-RnJson $inputPlan.stagingReceipt.path $inputPlan.stagingReceipt.sha256
$chunks=Read-RnJson $inputPlan.nativeChunkReceipt.path $inputPlan.nativeChunkReceipt.sha256
$run='C:\NLL\Staging\NativeFxUserValidation\'+$staged.trialUid+'\runs\'+$staged.assessmentUid
Assert-Rn ($staged.contractId -ceq 'nll/user-validation-runtime-staging/v1' -and $staged.executionOwnerCode -ceq 'user' -and
    $staged.runRoot -ceq $run -and $inputPlan.stagingReceipt.path -ceq (Join-Path $run 'runtime-staging.receipt.json') -and
    $staged.candidateReceiptSha256 -ceq $inputPlan.candidateReceiptSha256 -and
    $staged.profileSha256 -ceq $inputPlan.profileSha256 -and $staged.gameStarted -eq $false) 'validation_store_staging_invalid'
Assert-Rn ($chunks.contractId -ceq 'nll/native-fx-chunk-candidate/v1' -and
    $chunks.sourceStoreSha256 -ceq '0745db76654f7d7059ae6777d0572520e23e825590c8a4fb3207f81bf58bf792' -and
    $chunks.nativeClientExecuted -eq $false -and $chunks.indexTrailerVerified -eq $true -and
    $chunks.exactCompressedLengthRoundTripVerified -eq $true -and
    $inputPlan.nativeChunkReceipt.sha256 -ceq '6f09dd3cc9a021df654b1a7266f766e61a12bf7b7d36c72aea9fb76538e4417d' -and
    $staged.candidateReceiptSha256 -ceq '01ae9df2d36bd33bdc5595c0b6eff0b6843f716b81c5f75384738f079cb7af37' -and
    $staged.profileSha256 -ceq '897849f621174230b70bc345022eee0f5456900eba6eb9eec2e3f73d7d3e358a') 'validation_store_unreviewed_pair'
# This rollout seals the reviewed S29 pair, not an unverified arbitrary season.
$package=Split-Path -Parent $inputPlan.nativeChunkReceipt.path
$manifest=Read-RnJson (Join-Path $package 'manifest.private.json') $chunks.manifestSha256
$client='C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$staged.trialUid
$store=@(Get-ChildItem -LiteralPath (Join-Path $client 'Unity/com_proximabeta_NIKKE/com.shiftup.patch') -Recurse -File -Filter '*.cdb' |
    Where-Object Length -eq 6574364321)
Assert-Rn ($store.Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $run 'native-store.private.json'))) 'validation_store_target_invalid'
$role=switch($staged.weaknessCode){'fire'{'wind'} 'water'{'fire'} 'wind'{'iron'} 'electric'{$null} 'iron'{$null} default{throw 'validation_store_weakness_invalid'}}
$rows=@($manifest.entries | Where-Object {$null -ne $role -and $_.roleCode -ceq $role} | Sort-Object offset)
Assert-Rn (($null -eq $role -and $rows.Count -eq 0) -or ($null -ne $role -and $rows.Count -gt 0 -and $rows.Count -le 32)) 'validation_store_role_missing'
$rollback=Join-Path $run 'store-rollback'
New-RnPrivateDirectory $rollback
$patches=@(for($i=0;$i -lt $rows.Count;$i++){
    $row=$rows[$i];$pins=@{}
    foreach($kind in @('before','after')){
        $name=$row.($kind+'File')
        Assert-Rn ($name -ceq ($role+'-'+$row.ordinal+'-'+$kind+'.chunk') -and $row.byteLength -gt 0 -and $row.byteLength -le 16777216) 'validation_store_chunk_invalid'
        $source=[ordered]@{path=(Join-Path $package $name);length=$row.byteLength;sha256=$row.($kind+'Sha256')}
        Assert-RnPin $source
        $target=Join-Path $rollback ($i.ToString()+'.'+$kind+'.chunk')
        Copy-RnNew $source.path $target
        $pins[$kind]=Get-RnPin $target
    }
    [ordered]@{roleCode=$role;offset=$row.offset;before=$pins.before;after=$pins.after}
})
$plan=[ordered]@{contractId='nll/native-fx-user-validation-store/v1';trialUid=$staged.trialUid;assessmentUid=$staged.assessmentUid;
    executionOwnerCode='user';weaknessCode=$staged.weaknessCode;caseCode='candidate';profileSha256=$staged.profileSha256;
    candidateReceiptSha256=$staged.candidateReceiptSha256;
    originalStore=[ordered]@{path=$store[0].FullName;length=[long]6574364321;sha256=$chunks.sourceStoreSha256};
    candidateStoreSha256=$(if($rows.Count){'0'*64}else{$chunks.sourceStoreSha256});patches=$patches}
$path=Join-Path $run 'native-store.input.json'
Write-RnNewJson $path $plan
Add-Type -Path $inputPlan.storeTool.path
[NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::Prepare($path,(Get-RnHash $path))
