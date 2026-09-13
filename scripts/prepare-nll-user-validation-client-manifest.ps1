param([Parameter(Mandatory)][guid]$TrialUid,[Parameter(Mandatory)][string]$SourceManifestSha256,
    [Parameter(Mandatory)][string]$StoreToolPath,[Parameter(Mandatory)][string]$StoreToolSha256)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$trial=$TrialUid.ToString('D');Assert-Rn ($TrialUid -ne [guid]::Empty) 'uv_manifest_trial_invalid'
$run='C:\NLL\Staging\NativeFxUserValidation\'+$trial
$client='C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$trial
$sourcePath=Join-Path $run 'source.private.json'
$source=Read-RnJson $sourcePath $SourceManifestSha256
Assert-Rn ($source.build -ceq '151.8.5' -and $source.fileCount -eq $source.members.Count -and
    $source.members.Count -gt 0 -and $source.members.Count -le 10000) 'uv_manifest_source_invalid'
Assert-Rn ((Get-RnHash $StoreToolPath) -ceq $StoreToolSha256) 'uv_manifest_tool_drift'
Add-Type -Path $StoreToolPath
$pins=@(foreach($member in $source.members){
    $relative=([string]$member.relativePath).Replace('/','\')
    Assert-Rn (-not [IO.Path]::IsPathRooted($relative) -and -not $relative.Contains('..')) 'uv_manifest_member_invalid'
    $path=[IO.Path]::GetFullPath((Join-Path $client $relative))
    Assert-Rn ($path.StartsWith($client+'\',[StringComparison]::Ordinal)) 'uv_manifest_member_invalid'
    $pin=[pscustomobject]@{path=$path;length=$member.byteLength;sha256=$member.sha256}
    [NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::AssertPhysicalFile($path)
    Assert-RnPin $pin;$pin
})
Assert-Rn (@(Compare-Object ($pins.path|Sort-Object) (@(Get-ChildItem -LiteralPath $client -Recurse -File|ForEach-Object FullName)|Sort-Object)).Count -eq 0) 'uv_manifest_inventory_drift'
Assert-Rn (($pins|Measure-Object length -Sum).Sum -eq $source.byteLength) 'uv_manifest_length_drift'
$small=@($pins|Where-Object length -le 1048576)
Assert-Rn (($small|Measure-Object length -Sum).Sum -le 134217728) 'uv_manifest_backup_limit'
$backupRoot=Join-Path $run 'client-rollback';New-RnPrivateDirectory $backupRoot
$rollback=@(for($i=0;$i -lt $small.Count;$i++){
    $target=Join-Path $backupRoot ($i.ToString()+'.before.bin');Copy-RnNew $small[$i].path $target
    [ordered]@{before=$small[$i];backup=(Get-RnPin $target)}
})
$manifest=[ordered]@{contractId='nll/user-validation-client-pins/v1';trialUid=$trial;clientRoot=$client;
    sourceManifestSha256=$SourceManifestSha256;files=$pins;rollback=$rollback}
$path=Join-Path $run 'client-pins.private.json';Write-RnNewJson $path $manifest
[ordered]@{contractId=$manifest.contractId;manifestSha256=(Get-RnHash $path);fileCount=$pins.Count;
    backupCount=$rollback.Count;backupBytes=($small|Measure-Object length -Sum).Sum;clientModified=$false;gameStarted=$false}|ConvertTo-Json -Compress
