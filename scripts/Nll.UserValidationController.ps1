# Import is inert. These helpers operate only on controller-owned plan values.
function Assert-UvBinding($Plan,$Bootstrap,$Staging,$Store) {
    Assert-Rn ($Plan.contractId -ceq 'nll/native-fx-user-validation/v1' -and
        $Bootstrap.contractId -ceq 'nll/native-fx-user-validation-bootstrap/v1' -and
        $Staging.contractId -ceq 'nll/user-validation-runtime-staging/v1' -and
        $Store.contractId -ceq 'nll/native-fx-user-validation-store/v1') 'uv_contract_invalid'
    foreach($field in @('trialUid','assessmentUid','executionOwnerCode','weaknessCode','profileSha256','candidateReceiptSha256')){
        Assert-Rn ($Plan.$field -ceq $Bootstrap.$field -and $Plan.$field -ceq $Staging.$field -and $Plan.$field -ceq $Store.$field) 'uv_cross_run_binding'
    }
    Assert-Rn ($Plan.executionOwnerCode -ceq 'user' -and $Plan.caseCode -ceq 'candidate' -and
        $Bootstrap.caseCode -ceq $Plan.caseCode -and $Store.caseCode -ceq $Plan.caseCode -and
        $Plan.seasonNumber -eq $Bootstrap.seasonNumber -and $Plan.seasonNumber -eq $Staging.seasonNumber -and
        $Bootstrap.nativeStore.path -ceq $Store.originalStore.path -and
        $Bootstrap.nativeStore.length -eq $Store.originalStore.length -and
        $Bootstrap.nativeStore.sha256 -ceq $Store.candidateStoreSha256 -and
        $Plan.durationSeconds -eq $Bootstrap.durationSeconds -and $Plan.durationSeconds -ge 60 -and $Plan.durationSeconds -le 1800) 'uv_selection_binding'
    $trial=[guid]::ParseExact($Plan.trialUid,'D');$assessment=[guid]::ParseExact($Plan.assessmentUid,'D')
    Assert-Rn ($trial -ne [guid]::Empty -and $assessment -ne [guid]::Empty -and $trial -ne $assessment -and
        $trial.ToString('D') -ceq $Plan.trialUid -and $assessment.ToString('D') -ceq $Plan.assessmentUid -and
        $Plan.jobName -ceq ('Local\NLL.FxValidation.'+$assessment.ToString('N')) -and $Bootstrap.jobName -ceq $Plan.jobName) 'uv_identity_invalid'
    $run='C:\NLL\Staging\NativeFxUserValidation\'+$Plan.trialUid+'\runs\'+$Plan.assessmentUid
    Assert-Rn ($Plan.runRoot -ceq $run -and $Staging.runRoot -ceq $run -and
        $Plan.clientRoot -ceq ('C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$Plan.trialUid)) 'uv_root_invalid'
    foreach($pair in @(@('serverRoot','EpinelPS-151-UserValidation'),@('bootstrapRoot','NativeFxUserValidationBootstrap'),@('childRoot','NativeFxUserValidationChild'))){
        Assert-Rn ($Plan.($pair[0]) -ceq ('C:\NLL\Runtime\'+$pair[1]+'\'+$Plan.assessmentUid)) 'uv_root_invalid'
    }
    Assert-Rn ($Plan.serverRoot -ceq $Staging.serverRoot -and $Plan.bootstrapRoot -ceq $Staging.bootstrapRoot) 'uv_root_invalid'
}
function Restore-UvPreferences($Before,$After) {
    # Registry writes may have stopped between values. Reject unrelated changes.
    $current=@(Get-RnVoicePreferences)
    Assert-Rn ($current.Count -eq 2 -and $Before.Count -eq 2 -and $After.Count -eq 2) 'uv_preferences_invalid'
    for($i=0;$i -lt 2;$i++){
        Assert-Rn ($current[$i].name -ceq $Before[$i].name -and $current[$i].kind -ceq $Before[$i].kind -and
            $After[$i].name -ceq $Before[$i].name -and $After[$i].kind -ceq $Before[$i].kind -and
            $current[$i].value -cin @($Before[$i].value,$After[$i].value)) 'uv_preferences_unowned_drift'
    }
    Set-RnVoicePreferences $current $Before
}
function Restore-UvHosts($Change) {
    Assert-Rn ($Change.before.path -ceq 'C:\Windows\System32\drivers\etc\hosts' -and
        $Change.before.sha256 -ceq $Change.backup.sha256 -and $Change.before.length -eq $Change.backup.length) 'uv_hosts_invalid'
    Assert-RnPin $Change.backup;Assert-RnPin $Change.replacement
    $hash=Get-RnHash $Change.before.path
    if($hash -ceq $Change.before.sha256){return}
    # Copy interruption may leave only a prefix of the intended replacement.
    # Only such owned bytes may be restored; any unrelated edits retain isolation.
    $current=[IO.File]::ReadAllBytes($Change.before.path)
    $after=[IO.File]::ReadAllBytes($Change.replacement.path)
    Assert-Rn ($current.Length -le $after.Length) 'uv_hosts_unowned_drift'
    for($i=0;$i -lt $current.Length;$i++){Assert-Rn ($current[$i] -eq $after[$i]) 'uv_hosts_unowned_drift'}
    $pin=Get-RnPin $Change.before.path
    Set-RnPinnedFile $pin $Change.backup
    Assert-RnPin $Change.before
}
function Invoke-UvCleanup($Policy,[scriptblock]$StopJob,[scriptblock]$VerifyScopeCold,
    [scriptblock]$RestoreInputs,[scriptblock]$ReleaseIsolation) {
    $zero=@(& $StopJob)
    Assert-Rn ($zero.Count -eq 1 -and $zero[0] -is [bool] -and $zero[0]) 'uv_job_zero_unproven'
    Complete-FxValidationManagedScope -Policy $Policy -JobZeroVerified $true -VerifyScopeCold $VerifyScopeCold `
        -RestoreOwnedInputs $RestoreInputs -ReleaseIsolation $ReleaseIsolation
}
function Restore-UvClientFiles($Plan) {
    # Called only AFTER independently proven process/service zero. Large files
    # are immutable except the separately sealed store transaction. Never guess
    # how to repair a changed large bundle or silently accept its new hash.
    $root=$Plan.clientRoot
    $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pin in $Plan.clientFiles){
        Assert-Rn ($pin.path.StartsWith($root+'\',[StringComparison]::Ordinal) -and -not $pin.path.Contains('..')) 'uv_restore_client_path'
        $expected.Add($pin.path,$pin)
    }
    $backups=@{}
    foreach($pair in $Plan.clientRollback){
        Assert-Rn ($expected.ContainsKey($pair.before.path) -and $pair.before.length -le 1048576 -and
            $pair.before.sha256 -ceq $expected[$pair.before.path].sha256 -and $pair.before.length -eq $expected[$pair.before.path].length -and
            $pair.backup.sha256 -ceq $pair.before.sha256 -and $pair.backup.length -eq $pair.before.length -and
            $pair.backup.path.StartsWith(('C:\NLL\Staging\NativeFxUserValidation\'+$Plan.trialUid+'\client-rollback\'),[StringComparison]::Ordinal) -and
            -not $pair.backup.path.Contains('..') -and -not $backups.ContainsKey($pair.before.path)) 'uv_restore_client_backup'
        Assert-RnPin $pair.backup;$backups[$pair.before.path]=$pair.backup
    }
    $extras=@()
    foreach($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)){
        Assert-RnPath $item.FullName
        if(-not $item.PSIsContainer){
            [NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::AssertPhysicalFile($item.FullName)
            if(-not $expected.ContainsKey($item.FullName)){$extras+=,$item}
        }
    }
    Assert-Rn ($extras.Count -le 128 -and ($extras.Count -eq 0 -or ($extras|Measure-Object Length -Sum).Sum -le 67108864)) 'uv_new_client_files_exceed_limit'
    # Validate every changed/missing existing file BEFORE any recovery write.
    $changed=@(foreach($pin in $Plan.clientFiles){
        if(-not (Test-Path -LiteralPath $pin.path) -or (Get-RnHash $pin.path) -cne $pin.sha256){
            Assert-Rn ($backups.ContainsKey($pin.path)) 'uv_large_client_input_drift';$pin
        }
    })
    foreach($pin in $changed){
        Assert-RnPath $pin.path
        if(Test-Path -LiteralPath $pin.path){[NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::AssertPhysicalFile($pin.path)}
        Copy-Item -LiteralPath $backups[$pin.path].path -Destination $pin.path -ErrorAction Stop
        Assert-RnPin $pin
    }
    if($extras.Count){
        $quarantine=Join-Path $Plan.runRoot ('client-created-'+[guid]::NewGuid().ToString('N'))
        New-RnPrivateDirectory $quarantine
        for($i=0;$i -lt $extras.Count;$i++){
            $source=[IO.Path]::GetFullPath($extras[$i].FullName);$target=Join-Path $quarantine ($i.ToString()+'.private.bin')
            Assert-Rn ($source.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -and
                $target.StartsWith($Plan.runRoot+'\',[StringComparison]::Ordinal)) 'uv_quarantine_boundary'
            $pin=Get-RnPin $source
            Write-RnNewJson (Join-Path $quarantine ($i.ToString()+'.private.json')) $pin
            Move-Item -LiteralPath $source -Destination $target -ErrorAction Stop
            Assert-Rn ((Get-RnHash $target) -ceq $pin.sha256) 'uv_quarantine_drift'
        }
    }
    Assert-Rn (@(Compare-Object (@(Get-ChildItem -LiteralPath $root -Recurse -File|ForEach-Object FullName)|Sort-Object) ($Plan.clientFiles.path|Sort-Object)).Count -eq 0) 'uv_restored_inventory_drift'
}
