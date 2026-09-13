$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.UserValidationPreflight.ps1')
$script:checks=0
function Check([bool]$Value){$script:checks++;if(-not $Value){throw ('uv_synthetic_failed_'+$script:checks)}}
function Fixture {
    ,@([pscustomobject][ordered]@{name='voiceLocale_h4098423835';kind='Binary';value='YQA='},
        [pscustomobject][ordered]@{name='voiceDownloadType_h2535520031';kind='String';value='Synthetic Value'})
}
$expected=Fixture
Check (Compare-UvVoicePreferences $expected (Fixture)).equal
$reordered=@([pscustomobject][ordered]@{value='Synthetic Value';name=$expected[1].name;kind='String'},
    [pscustomobject][ordered]@{kind='Binary';value='YQA=';name=$expected[0].name})
$result=Compare-UvVoicePreferences $expected $reordered
Check ($result.equal -and -not $result.legacyJsonEqual -and $result.serializationOnlyDifference)
$actual=Fixture;$actual[0].value="YQ A= `r`n"
Check (Compare-UvVoicePreferences $expected $actual).equal
foreach($value in @('YgA=','YQ==','not base64','')){
    $actual=Fixture;$actual[0].value=$value;Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
}
foreach($value in @('synthetic Value','Synthetic Value ',('Synthetic Value'+[char]0),'')){
    $actual=Fixture;$actual[1].value=$value;Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
}
foreach($kind in @('String','DWord','binary')){
    $actual=Fixture;$actual[0].kind=$kind;Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
}
foreach($actual in @(@{rows=@($expected[0])},@{rows=@($expected[0],$expected[0])},
    @{rows=@($expected[0],$expected[1],$expected[1])},@{rows=@()},@{rows=@($null,$expected[1])})){
    Check (-not (Compare-UvVoicePreferences $expected $actual.rows).equal)
    Check (-not (Compare-UvVoicePreferences $actual.rows $expected).equal)
}
$actual=Fixture;$actual[0].name='uncontrolled';Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
$actual=Fixture;$actual[0].PSObject.Properties.Remove('value');Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
$actual=Fixture;$actual[1].value=$null;Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
$actual=Fixture;$actual[1]|Add-Member NoteProperty extra 'untrusted';Check (-not (Compare-UvVoicePreferences $expected $actual).equal)
# The diagnostic recorder receives the same comparison, with no raw name/value/SID.
$script:reads=0;$script:recorded=$null
try{Invoke-UvPreferenceCheck $expected 'quick_check' {
    $script:reads++;$rows=Fixture;$rows[0].value='YgA=';return ,$rows
} {param($evidence)$script:recorded=$evidence};throw 'expected_failure'}catch{Check ($_.Exception.Message -ceq 'resource_native_uv_preferences_before_drift')}
Check ($script:reads -eq 1 -and -not $script:recorded.comparison.equal)
$json=$script:recorded|ConvertTo-Json -Depth 12
Check (-not $json.Contains('YgA=') -and -not $json.Contains('Synthetic Value') -and -not $json.Contains('h4098423835'))
# Inject real control flow, never registry/network/process tools: early failures
# cannot reach the expensive reader, and late drift cannot reach mutation.
foreach($code in @('preferences','port','service','driver','hosts','prior_recovery','mutex')){
    $script:largeReads=0;$script:mutations=0
    try{Invoke-UvPreflightSequence {throw $code} {$script:largeReads++} {}; $script:mutations++}catch{Check ($_.Exception.Message -ceq $code)}
    Check ($script:largeReads -eq 0 -and $script:mutations -eq 0)
}
$script:largeReads=0;$script:mutations=0
try{Invoke-UvPreflightSequence {} {$script:largeReads++} {throw 'midway_drift'};$script:mutations++}catch{Check ($_.Exception.Message -ceq 'midway_drift')}
Check ($script:largeReads -eq 1 -and $script:mutations -eq 0)
$script:order=''
Invoke-UvPreflightSequence {$script:order+='Q'} {$script:order+='D'} {$script:order+='R'}
Check ($script:order -ceq 'QDR')
# Partial preference restoration accepts only owned before/after items, with
# reordered rows; all registry IO is replaced with an in-memory boundary.
function Assert-Rn([bool]$Value,[string]$Code){if(-not $Value){throw ('resource_native_'+$Code)}}
function Get-UvVoicePreferences {return ,$script:currentPreferences}
function Set-UvVoicePreferences($Expected,$Replacement){
    Check (Compare-UvVoicePreferences $Expected $script:currentPreferences).equal
    $script:writes++;$script:currentPreferences=$Replacement
}
$before=Fixture;$after=Fixture;$after[0].value='YgA=';$after[1].value='Synthetic replacement'
foreach($mask in 0..3){
    $script:writes=0
    $script:currentPreferences=@($(if($mask -band 2){$after[1]}else{$before[1]}),$(if($mask -band 1){$after[0]}else{$before[0]}))
    Restore-UvVoicePreferences $before $after
    Check ((Compare-UvVoicePreferences $before $script:currentPreferences).equal -and $script:writes -eq 1)
}
$script:currentPreferences=Fixture;$script:currentPreferences[1].value='unowned';$script:writes=0
try{Restore-UvVoicePreferences $before $after;throw 'expected_failure'}catch{Check ($_.Exception.Message -ceq 'resource_native_uv_preferences_unowned_drift')}
Check ($script:writes -eq 0)
foreach($path in @('Nll.UserValidationPreflight.ps1','invoke-nll-user-validation.ps1','diagnose-nll-user-validation-preferences.ps1')){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0)
}
[ordered]@{contractId='nll/user-validation-preflight-synthetic/v1';checks=$checks;statusCode='passed';gameStarted=$false;uacRequested=$false}|ConvertTo-Json -Compress
