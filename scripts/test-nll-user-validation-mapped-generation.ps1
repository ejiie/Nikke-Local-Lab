[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-RnPath $OutputRoot
Assert-Rn (-not (Test-Path -LiteralPath $OutputRoot)) 'uv_probe_output_exists'
$null=New-Item -ItemType Directory -Path $OutputRoot
Add-Type -Path (Join-Path $PSScriptRoot 'Nll.UserValidationGenerationProbe.cs')
$path=Join-Path $OutputRoot 'synthetic-mapped.bin'
Write-RnNewBytes $path ([byte[]](1..128)*32)
$original=Get-RnHash $path
$file=$null;$mapping=$null;$view=$null;$lease=$null
$before=$null;$after=$null;$detected=$false;$leaseRejected=$false;$nativeError=$null
try{
    $file=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    $mapName='Local\NllSyntheticGeneration-'+[guid]::NewGuid().ToString('N')
    $mapping=[IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile($file,$mapName,0,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite,[IO.HandleInheritability]::None,$true)
    $view=$mapping.CreateViewAccessor(0,4096,[IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
    $file.Dispose();$file=$null
    try{$lease=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
    catch [IO.IOException] {$leaseRejected=$true}
    if($null -ne $lease){
        $before=[Nll.ValidationProbe.ChangeTracking]::ReadJournal($lease)
        $view.Write(100,[byte]255);$view.Flush()
        $after=[Nll.ValidationProbe.ChangeTracking]::ReadJournal($lease)
        $lease.Position=0;$hash=[Security.Cryptography.SHA256]::Create()
        try{$current=([BitConverter]::ToString($hash.ComputeHash($lease))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
        $detected=$before.Split(':')[-1] -cne $after.Split(':')[-1]
        if($current -ceq $original){throw 'uv_probe_write_not_visible'}
    }
}catch{
    $errorValue=$_.Exception;while($errorValue.InnerException){$errorValue=$errorValue.InnerException}
    if($errorValue -is [ComponentModel.Win32Exception]){$nativeError=$errorValue.NativeErrorCode}else{throw}
}finally{
    if($null -ne $lease){$lease.Dispose()};if($null -ne $view){$view.Dispose()}
    if($null -ne $mapping){$mapping.Dispose()};if($null -ne $file){$file.Dispose()}
}
$status=if($nativeError){'tracking_unavailable'}elseif($leaseRejected){'mapped_writer_lease_rejected'}elseif($detected){'mapped_change_detected'}else{'blocked_mapped_write_not_detected'}
$result=[ordered]@{contractId='nll/user-validation-mapped-generation-feasibility/v1';statusCode=$status;
    nativeErrorCode=$nativeError;exclusiveLeaseRejected=$leaseRejected;mappedWriteDetectedByFileUsn=$detected;
    gameStarted=$false;systemJournalModified=$false;syntheticFileBytes=4096;fastAdmissionEnabled=$false;actualGameAcceptanceClaimed=$false}
Write-RnNewJson (Join-Path $OutputRoot 'receipt.json') $result
$result|ConvertTo-Json -Compress
