[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')][string]$AssessmentUid,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedSourcePlanSha256,
    [ValidateSet('diagnostic','user-validation')][string]$Purpose = 'diagnostic',
    [switch]$Execute
)
# Create-only diagnostic client. No game/server/DB, registry, hosts, CA or firewall changes.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'new-nll-resource-probe-clone.ps1')
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-NllClone ($PSVersionTable.PSVersion.Major -ge 7 -and [guid]::Parse($AssessmentUid) -ne [guid]::Empty) 'fx_input_invalid'
$sourceRoot='C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe'
$userValidation=$Purpose -ceq 'user-validation'
$targetRoot=if($userValidation){'C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$AssessmentUid}else{'C:\NLL\Clients\NIKKE-151.8.5-FxProbe-'+$AssessmentUid}
$evidenceRoot=if($userValidation){'C:\NLL\Staging\NativeFxUserValidation\'+$AssessmentUid}else{'C:\NLL\Staging\NativeFxTrials\'+$AssessmentUid}
$contractPrefix=if($userValidation){'nll/native-fx-user-validation-clone'}else{'nll/native-fx-probe-clone'}
foreach($path in @($sourceRoot,$targetRoot,$evidenceRoot)){Assert-NllCloneNoReparse $path}
Assert-NllClone (-not (Test-Path -LiteralPath $targetRoot) -and -not (Test-Path -LiteralPath $evidenceRoot)) 'fx_assessment_exists'
Assert-NllCloneCold
foreach($pin in @(
    @('NIKKE/game/nikke.exe','36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732'),
    @('NIKKE/game/GameAssembly.dll','23b64ef22957356bfb3f02096a8fd59c5e2b6426bafb44520acd7fcd12a060ed'),
    @('NIKKE/game/nikke_Data/Plugins/x86_64/sodium.dll','54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662')
)) {Assert-NllClone ((Get-NllCloneSha256 (Join-Path $sourceRoot $pin[0])) -ceq $pin[1]) 'fx_source_drift'}
$plan=Get-NllClonePlan $sourceRoot '151.8.5'
Assert-NllCloneCold
if(-not $Execute){
    [ordered]@{contractId=($contractPrefix+'-preflight/v1');assessmentUid=$AssessmentUid;sourcePlanSha256=$plan.planSha256;fileCount=$plan.fileCount;byteLength=$plan.byteLength;status='plan_only';clientStarted=$false;runtimeAdmission='not_assessed'}|ConvertTo-Json -Compress
    return
}
Assert-NllClone ($ExpectedSourcePlanSha256 -ceq $plan.planSha256) 'fx_plan_drift'
Assert-NllClone ((Get-PSDrive -Name C).Free -gt $plan.byteLength+10GB) 'fx_space_insufficient'
New-RnPrivateDirectory $evidenceRoot
Write-NllCloneNewJson (Join-Path $evidenceRoot 'source.private.json') $plan
Write-NllCloneNewJson (Join-Path $evidenceRoot 'ownership.private.json') ([ordered]@{
    contractId=($contractPrefix+'-ownership/v1');assessmentUid=$AssessmentUid;sourceRoot=$sourceRoot;targetRoot=$targetRoot;
    sourcePlanSha256=$plan.planSha256;approvedSodiumSha256='54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662';
    targetMayExecute=$false;rollback='quarantine_only_exact_new_clone_after_tree_exit';noAutomaticDeletion=$true
})
New-RnPrivateDirectory $targetRoot
foreach($member in $plan.members){
    $source=Join-Path $sourceRoot $member.relativePath
    $target=Join-Path $targetRoot $member.relativePath
    Assert-NllCloneNoReparse $source
    Assert-NllCloneNoReparse $target
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        Assert-NllClone ($inputStream.Length -eq $member.byteLength -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($inputStream)).ToLowerInvariant() -ceq $member.sha256) 'fx_copy_source_drift'
        $inputStream.Position=0
        $outputStream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$inputStream.CopyTo($outputStream);$outputStream.Flush($true)}finally{$outputStream.Dispose()}
    }finally{$inputStream.Dispose()}
    Assert-NllClone ((Get-NllCloneSha256 $target) -ceq $member.sha256) 'fx_copy_mismatch'
}
$after=Get-NllClonePlan $sourceRoot '151.8.5'
$copied=Get-NllClonePlan $targetRoot '151.8.5'
Assert-NllCloneCold
Assert-NllClone ($after.planSha256 -ceq $plan.planSha256 -and $copied.planSha256 -ceq $plan.planSha256) 'fx_final_manifest_mismatch'
$receipt=[ordered]@{contractId=($contractPrefix+'/v1');assessmentUid=$AssessmentUid;sourcePlanSha256=$plan.planSha256;fileCount=$plan.fileCount;byteLength=$plan.byteLength;sourceUnchanged=$true;physicalCopiesVerified=$true;sharedLinksCreated=$false;clientStarted=$false;runtimeAdmission='not_assessed';status='cloned_not_started'}
Write-NllCloneNewJson (Join-Path $evidenceRoot 'clone.receipt.json') $receipt
$receipt|ConvertTo-Json -Compress
