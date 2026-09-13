[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-RnPath $OutputRoot
Assert-Rn (-not (Test-Path -LiteralPath $OutputRoot)) 'uv_probe_output_exists'
$null=New-Item -ItemType Directory -Path $OutputRoot
Add-Type -Path (Join-Path $PSScriptRoot 'Nll.UserValidationGenerationProbe.cs')
$file=Join-Path $OutputRoot 'synthetic.bin'
Write-RnNewBytes $file ([byte[]](1..128)*32)
$status='blocked_tracking_unavailable';$nativeError=$null;$observations=0;$changed=$false
try{
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$before=[Nll.ValidationProbe.ChangeTracking]::ReadJournal($stream);$observations++}finally{$stream.Dispose()}
    $time=[IO.File]::GetLastWriteTimeUtc($file)
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.WriteByte(255);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::SetLastWriteTimeUtc($file,$time)
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$after=[Nll.ValidationProbe.ChangeTracking]::ReadJournal($stream);$observations++}finally{$stream.Dispose()}
    $changed=($before.Split(':')[-1] -cne $after.Split(':')[-1])
    $status=if($changed){'initial_tracking_observed_further_proof_required'}else{'blocked_equal_size_change_not_detected'}
}catch{
    $errorValue=$_.Exception;while($errorValue.InnerException){$errorValue=$errorValue.InnerException}
    if($errorValue -is [ComponentModel.Win32Exception]){$nativeError=$errorValue.NativeErrorCode}
}
$result=[ordered]@{contractId='nll/user-validation-generation-feasibility/v1';statusCode=$status;nativeErrorCode=$nativeError;
    lastStage=[Nll.ValidationProbe.ChangeTracking]::Stage;
    observations=$observations;equalSizeTimestampResetDetected=$changed;syntheticFileBytes=4096;
    gameStarted=$false;uacRequested=$false;systemJournalModified=$false;fastAdmissionEnabled=$false;actualGameAcceptanceClaimed=$false}
Write-RnNewJson (Join-Path $OutputRoot 'receipt.json') $result
$result|ConvertTo-Json -Compress
