# Inert, source-only user-validation helpers. No game, elevation or mutation on import.
Set-StrictMode -Version Latest

function Get-UvVoicePreferences {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try {
        $key=$base.OpenSubKey('Software\com.proximabeta\NIKKE',$false)
        if($null -eq $key){return ,@()}
        $rows=@(foreach($name in @('voiceLocale_h4098423835','voiceDownloadType_h2535520031')){
            if($name -cnotin $key.GetValueNames()){continue}
            $kind=$key.GetValueKind($name).ToString()
            $value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if($kind -ceq 'Binary' -and $value -is [byte[]]){$value=[Convert]::ToBase64String($value)}
            [pscustomobject][ordered]@{name=$name;kind=$kind;value=$value}
        })
        return ,$rows
    } finally {if($null -ne $key){$key.Dispose()};$base.Dispose()}
}

function ConvertTo-UvPreferenceEvidence($Item) {
    if($null -eq $Item){return [pscustomobject]@{valid=$false;issue='missing';kind=$null;length=$null;sha256=$null}}
    $props=@($Item.PSObject.Properties.Name)
    if(@(Compare-Object @('name','kind','value') $props).Count -ne 0 -or $Item.value -isnot [string]){
        return [pscustomobject]@{valid=$false;issue='shape';kind=$null;length=$null;sha256=$null}
    }
    $bytes=$null
    if($Item.kind -ceq 'Binary'){
        try{$bytes=[Convert]::FromBase64String($Item.value)}catch{
            return [pscustomobject]@{valid=$false;issue='invalid_base64';kind='Binary';length=$null;sha256=$null}
        }
    }elseif($Item.kind -ceq 'String'){
        # Hash the exact UTF-16 code units; no case/space/NUL normalization.
        $bytes=New-Object byte[] ($Item.value.Length*2)
        for($i=0;$i -lt $Item.value.Length;$i++){$n=[int][char]$Item.value[$i];$bytes[$i*2]=[byte]($n -band 255);$bytes[$i*2+1]=[byte]($n -shr 8)}
    }else{return [pscustomobject]@{valid=$false;issue='unsupported_kind';kind='unsupported';length=$null;sha256=$null}}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    [pscustomobject]@{valid=$true;issue='none';kind=$Item.kind;length=$bytes.Length;sha256=$digest}
}

function Compare-UvVoicePreferences($Expected,$Actual) {
    $names=@('voiceLocale_h4098423835','voiceDownloadType_h2535520031')
    $roles=@('voice_locale','voice_download')
    $setsValid=$true
    foreach($set in @(@{rows=@($Expected)},@{rows=@($Actual)})){
        if($set.rows.Count -ne 2){$setsValid=$false}
        foreach($row in $set.rows){
            if($null -eq $row -or 'name' -cnotin @($row.PSObject.Properties.Name) -or $row.name -cnotin $names){$setsValid=$false}
        }
        foreach($name in $names){
            if(@($set.rows|Where-Object {$null -ne $_ -and 'name' -cin @($_.PSObject.Properties.Name) -and $_.name -ceq $name}).Count -ne 1){$setsValid=$false}
        }
    }
    $items=@(for($i=0;$i -lt 2;$i++){
        $left=@($Expected|Where-Object {$null -ne $_ -and 'name' -cin @($_.PSObject.Properties.Name) -and $_.name -ceq $names[$i]})
        $right=@($Actual|Where-Object {$null -ne $_ -and 'name' -cin @($_.PSObject.Properties.Name) -and $_.name -ceq $names[$i]})
        $l=ConvertTo-UvPreferenceEvidence $(if($left.Count -eq 1){$left[0]}else{$null})
        $r=ConvertTo-UvPreferenceEvidence $(if($right.Count -eq 1){$right[0]}else{$null})
        $equal=$false;$difference='none'
        if($left.Count -gt 1 -or $right.Count -gt 1){$difference='duplicate'}
        elseif(-not $l.valid){$difference='expected_'+$l.issue}
        elseif(-not $r.valid){$difference='actual_'+$r.issue}
        elseif($l.kind -cne $r.kind){$difference='kind'}
        else{
            if($l.kind -ceq 'String'){$equal=[string]::Equals($left[0].value,$right[0].value,[StringComparison]::Ordinal)}
            else{
                $a=[Convert]::FromBase64String($left[0].value);$b=[Convert]::FromBase64String($right[0].value)
                $equal=$a.Length -eq $b.Length
                if($equal){for($j=0;$j -lt $a.Length;$j++){if($a[$j] -ne $b[$j]){$equal=$false;break}}}
            }
            if(-not $equal){$difference='value'}
        }
        [pscustomobject]@{role=$roles[$i];expected=$l;actual=$r;equal=$equal;difference=$difference}
    })
    $semantic=$setsValid -and @($items|Where-Object {-not $_.equal}).Count -eq 0
    $legacy=(@($Actual)|ConvertTo-Json -Depth 8 -Compress) -ceq (@($Expected)|ConvertTo-Json -Depth 8 -Compress)
    [pscustomobject]@{contractId='nll/user-validation-preferences-comparison/v1';equal=$semantic;exactSet=$setsValid;
        legacyJsonEqual=$legacy;serializationOnlyDifference=($semantic -and -not $legacy);items=$items}
}

function Get-UvPreferenceEnvironment([string]$OperatorSid) {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{[pscustomobject]@{shellVersion=$PSVersionTable.PSVersion.ToString();processBits=([IntPtr]::Size*8);
        elevated=([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator));
        operatorSidMatches=($identity.User.Value -ceq $OperatorSid);registryView='Registry64'}}finally{$identity.Dispose()}
}

function Invoke-UvPreferenceCheck($Expected,[string]$Stage,[scriptblock]$ReadSnapshot,[scriptblock]$Record) {
    # Exactly one read; both verdict and diagnostics derive from this snapshot.
    $snapshot=& $ReadSnapshot
    $comparison=Compare-UvVoicePreferences $Expected $snapshot
    & $Record ([pscustomobject]@{stage=$Stage;comparison=$comparison})
    if(-not $comparison.equal){throw 'resource_native_uv_preferences_before_drift'}
}

function Set-UvVoicePreferences($Expected,$Replacement) {
    $current=Get-UvVoicePreferences
    Assert-Rn (Compare-UvVoicePreferences $Expected $current).equal 'uv_preferences_before_drift'
    Assert-Rn (Compare-UvVoicePreferences $Replacement $Replacement).equal 'uv_preferences_replacement_invalid'
    if((Compare-UvVoicePreferences $current $Replacement).equal){return}
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry64)
    $key=$null
    try{
        $key=$base.OpenSubKey('Software\com.proximabeta\NIKKE',$true)
        Assert-Rn ($null -ne $key) 'uv_preferences_key_missing'
        foreach($item in $Replacement){
            $old=@($current|Where-Object name -CEQ $item.name)[0]
            Assert-Rn ($old.kind -ceq $item.kind) 'uv_preferences_kind_mutation_rejected'
            if($item.kind -ceq 'Binary'){$value=[Convert]::FromBase64String($item.value)}else{$value=$item.value}
            $key.SetValue($item.name,$value,[Enum]::Parse([Microsoft.Win32.RegistryValueKind],$item.kind,$false))
        }
        $key.Flush()
    }finally{if($null -ne $key){$key.Dispose()};$base.Dispose()}
    Assert-Rn (Compare-UvVoicePreferences $Replacement (Get-UvVoicePreferences)).equal 'uv_preferences_write_unproven'
}
function Restore-UvVoicePreferences($Before,$After) {
    $current=Get-UvVoicePreferences
    Assert-Rn ((Compare-UvVoicePreferences $current $current).equal -and
        (Compare-UvVoicePreferences $Before $Before).equal -and (Compare-UvVoicePreferences $After $After).equal) 'uv_preferences_restore_invalid'
    # Each controlled item may be before OR after, including a partial write.
    # Substitute that item into each full set to use the same semantic comparator.
    foreach($item in $current){
        $left=@(foreach($row in $Before){if($row.name -ceq $item.name){$item}else{$row}})
        $right=@(foreach($row in $After){if($row.name -ceq $item.name){$item}else{$row}})
        Assert-Rn ((Compare-UvVoicePreferences $Before $left).equal -or
            (Compare-UvVoicePreferences $After $right).equal) 'uv_preferences_unowned_drift'
    }
    Set-UvVoicePreferences $current $Before
}

function Invoke-UvPreflightSequence([scriptblock]$Quick,[scriptblock]$Deep,[scriptblock]$Recheck) {
    & $Quick
    & $Deep
    & $Recheck
}

function Start-UvTrace([string]$Root,[string]$EntryHash,[string]$Mode) {
    $script:UvTrace=[pscustomobject]@{root=$Root;entrySha256=$EntryHash;mode=$Mode;sequence=0;stage=$null;
        startedAtUtc=$null;watch=[Diagnostics.Stopwatch]::new();publishedAtMilliseconds=[double]0;plannedBytes=[long]0;completedBytes=[long]0}
}
function Set-UvStage([ValidateSet('quick_check','deep_check','shared_state_recheck','isolation','native_store_apply','system_apply','bootstrap_check','game_start','running','cleanup','complete','failed')][string]$Stage,[long]$PlannedBytes=0) {
    if($null -ne $script:UvTrace.stage){
        Publish-UvProgress 'ended'
        if($script:UvTrace.root){Write-RnNewJson (Join-Path $script:UvTrace.root ('preflight-stage-'+$script:UvTrace.sequence+'.json')) (Get-UvProgress 'ended')}
    }
    $script:UvTrace.sequence++;$script:UvTrace.stage=$Stage;$script:UvTrace.startedAtUtc=[DateTimeOffset]::UtcNow
    $script:UvTrace.plannedBytes=$PlannedBytes;$script:UvTrace.completedBytes=0;$script:UvTrace.publishedAtMilliseconds=0;$script:UvTrace.watch.Restart()
    Publish-UvProgress 'started'
}
function Get-UvProgress([string]$State) {
    [ordered]@{contractId='nll/user-validation-preflight-progress/v1';entrySha256=$script:UvTrace.entrySha256;mode=$script:UvTrace.mode;
        stage=$script:UvTrace.stage;sequence=$script:UvTrace.sequence;state=$State;startedAtUtc=$script:UvTrace.startedAtUtc;
        observedAtUtc=[DateTimeOffset]::UtcNow;elapsedMilliseconds=$script:UvTrace.watch.Elapsed.TotalMilliseconds;
        plannedReadBytes=$script:UvTrace.plannedBytes;completedReadBytes=$script:UvTrace.completedBytes;
        readAccountingScope='instrumented_parent_hashes_and_store';actualGameAcceptanceClaimed=$false}
}
function Publish-UvProgress([string]$State='running') {
    if(-not $script:UvTrace.root){return}
    $path=Join-Path $script:UvTrace.root 'preflight-progress.json'
    $temporary=Join-Path $script:UvTrace.root ('progress-'+[guid]::NewGuid().ToString('N')+'.tmp')
    Write-RnNewJson $temporary (Get-UvProgress $State)
    if(Test-Path -LiteralPath $path){Assert-RnPath $path;[IO.File]::Replace($temporary,$path,$null)}else{[IO.File]::Move($temporary,$path)}
}
function Assert-UvMeasuredPin($Pin) {
    Assert-RnPath $Pin.path
    $stream=[IO.FileStream]::new($Pin.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{
        [NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::AssertPhysicalFile($stream)
        Assert-Rn ($stream.Length -eq $Pin.length) 'pin_length_drift'
        $buffer=New-Object byte[] (1024*1024)
        while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){
            $script:UvTrace.completedBytes+=$count
            $null=$hash.TransformBlock($buffer,0,$count,$buffer,0)
            if($script:UvTrace.watch.Elapsed.TotalMilliseconds-$script:UvTrace.publishedAtMilliseconds -ge 500){
                Publish-UvProgress;$script:UvTrace.publishedAtMilliseconds=$script:UvTrace.watch.Elapsed.TotalMilliseconds
            }
        }
        $null=$hash.TransformFinalBlock($buffer,0,0)
        Assert-Rn (([BitConverter]::ToString($hash.Hash)).Replace('-','').ToLowerInvariant() -ceq $Pin.sha256) 'pin_hash_drift'
        Assert-RnPath $Pin.path
    }finally{$hash.Dispose();$stream.Dispose()}
}
