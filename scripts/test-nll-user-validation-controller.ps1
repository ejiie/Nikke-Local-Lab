$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedDriver.ps1')
. (Join-Path $PSScriptRoot 'Nll.UserValidationController.ps1')
$script:checks=0
function Check([bool]$value){if(-not $value){throw ('uv_synthetic_assertion_'+$script:checks)};$script:checks++}
function Reject([scriptblock]$action){$caught=$false;try{& $action|Out-Null}catch{$caught=$true};Check $caught}
function Copy-UvFixture($value){$value|ConvertTo-Json -Depth 12|ConvertFrom-Json}
$trial='10000000-0000-0000-0000-000000000001';$uid='20000000-0000-0000-0000-000000000002'
$run='C:\NLL\Staging\NativeFxUserValidation\'+$trial+'\runs\'+$uid
$client='C:\NLL\Clients\NIKKE-151.8.5-UserValidation-'+$trial
$base=[ordered]@{contractId='nll/native-fx-user-validation/v1';trialUid=$trial;assessmentUid=$uid;executionOwnerCode='user';
    weaknessCode='water';profileSha256=('a'*64);candidateReceiptSha256=('b'*64);caseCode='candidate';seasonNumber=29;durationSeconds=1200;
    jobName=('Local\NLL.FxValidation.'+[guid]::Parse($uid).ToString('N'));runRoot=$run;clientRoot=$client;
    serverRoot=('C:\NLL\Runtime\EpinelPS-151-UserValidation\'+$uid);bootstrapRoot=('C:\NLL\Runtime\NativeFxUserValidationBootstrap\'+$uid);
    childRoot=('C:\NLL\Runtime\NativeFxUserValidationChild\'+$uid)}
$p=Copy-UvFixture $base;$b=Copy-UvFixture $base;$s=Copy-UvFixture $base;$t=Copy-UvFixture $base
$b.contractId='nll/native-fx-user-validation-bootstrap/v1';$s.contractId='nll/user-validation-runtime-staging/v1';$t.contractId='nll/native-fx-user-validation-store/v1'
$pin=[ordered]@{path=($client+'\Unity\com_proximabeta_NIKKE\com.shiftup.patch\synthetic.cdb');length=100;sha256=('c'*64)}
$b|Add-Member NoteProperty nativeStore (Copy-UvFixture $pin);$t|Add-Member NoteProperty originalStore (Copy-UvFixture $pin)
$t|Add-Member NoteProperty candidateStoreSha256 ('c'*64)
foreach($weakness in @('fire','water','wind','electric','iron')){
    foreach($item in @($p,$b,$s,$t)){$item.weaknessCode=$weakness}
    Assert-UvBinding $p $b $s $t;Check $true
}
foreach($target in 0..3){foreach($field in @('trialUid','assessmentUid','executionOwnerCode','weaknessCode','profileSha256','candidateReceiptSha256','contractId')){
    $items=@((Copy-UvFixture $p),(Copy-UvFixture $b),(Copy-UvFixture $s),(Copy-UvFixture $t));$items[$target].$field='wrong'
    Reject {Assert-UvBinding $items[0] $items[1] $items[2] $items[3]}
}}
foreach($field in @('caseCode','seasonNumber','durationSeconds','jobName','clientRoot','serverRoot','bootstrapRoot','childRoot','runRoot')){
    $bad=Copy-UvFixture $p;$bad.$field='wrong';Reject {Assert-UvBinding $bad $b $s $t}
}
$bad=Copy-UvFixture $b;$bad.nativeStore.sha256='d'*64;Reject {Assert-UvBinding $p $bad $s $t}
$bad=Copy-UvFixture $t;$bad.originalStore.length=99;Reject {Assert-UvBinding $p $b $s $bad}
# Registry tests are in-memory; NEVER access the OS registry/service/firewall.
$before=@([pscustomobject]@{name='one';kind='String';value='before1'},[pscustomobject]@{name='two';kind='String';value='before2'})
$after=@([pscustomobject]@{name='one';kind='String';value='after1'},[pscustomobject]@{name='two';kind='String';value='after2'})
$script:preferenceWrites=0;$script:preferences=@()
function Get-RnVoicePreferences {return $script:preferences}
function Set-RnVoicePreferences($Expected,$Replacement){Check (($Expected|ConvertTo-Json -Compress) -ceq ($script:preferences|ConvertTo-Json -Compress));$script:preferenceWrites++;$script:preferences=Copy-UvFixture $Replacement}
foreach($mask in 0..3){
    $script:preferences=@((Copy-UvFixture $(if($mask-band 1){$after[0]}else{$before[0]})),(Copy-UvFixture $(if($mask-band 2){$after[1]}else{$before[1]})))
    Restore-UvPreferences $before $after;Check (($preferences|ConvertTo-Json -Compress) -ceq ($before|ConvertTo-Json -Compress))
}
$script:preferences=Copy-UvFixture $before;$script:preferences[0].value='unrelated';$writes=$preferenceWrites
Reject {Restore-UvPreferences $before $after};Check ($preferenceWrites -eq $writes)
# Exercise the SAME cleanup orchestration with real managed helper logic and
# fully synthetic OS boundaries. Inject failure at every transition.
$script:events=[Collections.Generic.List[string]]::new();$script:failAt=''
function Event([string]$name){$script:events.Add($name);if($script:failAt -ceq $name){throw 'synthetic_interruption'}}
function Assert-FxValidationDriverPolicy($Policy){Check ($Policy -ceq 'synthetic')}
function Stop-FxManagedService([bool]$JobZeroVerified){Check $JobZeroVerified;Event 'service_stop';[pscustomobject]@{state='Stopped';processId=0}}
function Assert-FxManagedServiceSnapshot($Snapshot,$Phase){Check ($Snapshot.state -ceq 'Stopped')}
function Restore-FxManagedService([bool]$ScopeZeroVerified){Check $ScopeZeroVerified;Event 'service_restore';[pscustomobject]@{state='Stopped';processId=0}}
function Restore-FxValidationDriver($Policy,[bool]$JobZeroVerified,[bool]$ServiceZeroVerified,[bool]$ScopeZeroVerified){Check ($JobZeroVerified -and $ServiceZeroVerified -and $ScopeZeroVerified);Event 'driver_restore';[pscustomobject]@{driverBaselineRestored=$true}}
function Assert-FxValidationServiceCold {Event 'service_cold'}
function Get-FxValidationDriverSnapshot {return @('synthetic')}
function Assert-FxValidationDrivers($Policy,$Current,$Phase){Event 'driver_baseline'}
function Run-Cleanup {
    Invoke-UvCleanup 'synthetic' -StopJob {Event 'job_zero';$true} -VerifyScopeCold {Event 'scope_zero';$true} `
        -RestoreInputs {Event 'inputs_restore';$true} -ReleaseIsolation {Event 'isolation_release';$true}
}
$result=Run-Cleanup
Check ($result.isolationReleased -and $result.driverBaselineRestored -and $result.ownedInputsRestored -and -not $result.actualGameAcceptanceClaimed)
$sequence=@($events)
Check (($sequence -join ',') -ceq 'job_zero,service_stop,scope_zero,service_restore,scope_zero,inputs_restore,driver_restore,service_cold,scope_zero,driver_baseline,isolation_release')
foreach($step in @($sequence|Select-Object -Unique)){
    $script:events.Clear();$script:failAt=$step;Reject {Run-Cleanup}
    Check ($events[$events.Count-1] -ceq $step)
    if($step -cne 'isolation_release'){Check (-not $events.Contains('isolation_release'))}
}
$script:failAt='';$script:events.Clear()
Reject {Invoke-UvCleanup 'synthetic' -StopJob {$false} -VerifyScopeCold {$true} -RestoreInputs {$true} -ReleaseIsolation {$true}}
Check ($events.Count -eq 0)
Reject {Invoke-UvCleanup 'synthetic' -StopJob {@($true,$true)} -VerifyScopeCold {$true} -RestoreInputs {$true} -ReleaseIsolation {$true}}
Check ($events.Count -eq 0)
foreach($name in @('invoke-nll-user-validation.ps1','prepare-nll-user-validation-controller.ps1','prepare-nll-user-validation-store.ps1')){
    $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name),[ref]$tokens,[ref]$errors)
    Check (@($errors).Count -eq 0)
}
# The real client recovery function over an in-memory file-system boundary.
# No path below is opened. The native physical-file guard is tested separately
# by the source-linked .NET tests; this double exercises orchestration only.
Add-Type -TypeDefinition @'
namespace NikkeLocalLab.Phase3B2.UserValidation {
 public static class NativeStoreOperations {
  public static string RejectPath;
  public static void AssertPhysicalFile(string path) {
   if(path == RejectPath) throw new System.InvalidOperationException("synthetic_nonphysical");
  }
 }
}
'@
function Assert-RnPath([string]$Path) { Assert-Rn (-not $Path.Contains('..')) 'synthetic_path'; }
$script:vfs=@{};$script:copies=0;$script:moves=0
function Get-RnHash([string]$Path){Assert-Rn ($vfs.ContainsKey($Path)) 'synthetic_missing';$vfs[$Path].sha256}
function Get-RnPin([string]$Path){Assert-Rn ($vfs.ContainsKey($Path)) 'synthetic_missing';$vfs[$Path]}
function Assert-RnPin($Pin){Assert-Rn ($vfs.ContainsKey($Pin.path) -and $vfs[$Pin.path].sha256 -ceq $Pin.sha256 -and $vfs[$Pin.path].length -eq $Pin.length) 'synthetic_pin'}
function Test-Path([string]$LiteralPath){$vfs.ContainsKey($LiteralPath)}
function Get-ChildItem([string]$LiteralPath,[switch]$Recurse,[switch]$Force,[switch]$File){
 foreach($item in @($vfs.Values)){if($item.path.StartsWith($LiteralPath+'\',[StringComparison]::Ordinal)){
  [pscustomobject]@{FullName=$item.path;Length=$item.length;PSIsContainer=$false}
 }}
}
function Copy-Item([string]$LiteralPath,[string]$Destination,[string]$ErrorAction){
 $script:copies++;$pin=Copy-UvFixture $vfs[$LiteralPath];$pin.path=$Destination;$vfs[$Destination]=$pin
}
function Move-Item([string]$LiteralPath,[string]$Destination,[string]$ErrorAction){
 $script:moves++;$pin=Copy-UvFixture $vfs[$LiteralPath];$pin.path=$Destination;$vfs[$Destination]=$pin;$vfs.Remove($LiteralPath)
}
function New-RnPrivateDirectory([string]$Path){Assert-Rn ($Path.StartsWith($run+'\')) 'synthetic_directory'}
function Write-RnNewJson([string]$Path,$Value){Assert-Rn ($Path.StartsWith($run+'\')) 'synthetic_metadata'}
function Client-Fixture {
 $script:vfs=@{};$script:copies=0;$script:moves=0
 [NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::RejectPath=$null
 $small=[pscustomobject]@{path=$client+'\small.cfg';length=9;sha256=('a'*64)}
 $large=[pscustomobject]@{path=$client+'\large.bundle';length=1048577;sha256=('b'*64)}
 $backup=Copy-UvFixture $small;$backup.path='C:\NLL\Staging\NativeFxUserValidation\'+$trial+'\client-rollback\0.before.bin'
 foreach($pin in @($small,$large,$backup)){$vfs[$pin.path]=Copy-UvFixture $pin}
 [pscustomobject]@{trialUid=$trial;runRoot=$run;clientRoot=$client;clientFiles=@($small,$large);clientRollback=@([pscustomobject]@{before=$small;backup=$backup})}
}
foreach($missing in @($false,$true)){
 $f=Client-Fixture
 if($missing){$vfs.Remove($f.clientFiles[0].path)}else{$vfs[$f.clientFiles[0].path].sha256='c'*64}
 Restore-UvClientFiles $f;Check ($copies -eq 1);Assert-RnPin $f.clientFiles[0]
 Restore-UvClientFiles $f;Check ($copies -eq 1)
}
$f=Client-Fixture;$vfs[$f.clientFiles[0].path].sha256='c'*64;$vfs[$f.clientFiles[1].path].sha256='d'*64
Reject {Restore-UvClientFiles $f};Check ($copies -eq 0 -and $moves -eq 0)
$f=Client-Fixture;$vfs[$f.clientRollback[0].backup.path].sha256='e'*64
Reject {Restore-UvClientFiles $f};Check ($copies -eq 0)
$f=Client-Fixture;[NikkeLocalLab.Phase3B2.UserValidation.NativeStoreOperations]::RejectPath=$f.clientFiles[0].path
Reject {Restore-UvClientFiles $f};Check ($copies -eq 0)
$f=Client-Fixture;$extra=$client+'\new.log';$vfs[$extra]=[pscustomobject]@{path=$extra;length=67108865;sha256=('f'*64)}
Reject {Restore-UvClientFiles $f};Check ($copies -eq 0 -and $moves -eq 0)
if($env:OS -eq 'Windows_NT'){
 $f=Client-Fixture;$vfs[$extra]=[pscustomobject]@{path=$extra;length=32;sha256=('f'*64)}
 Restore-UvClientFiles $f;Check ($moves -eq 1 -and -not $vfs.ContainsKey($extra))
 Check (@($vfs.Values|Where-Object {$_.path.StartsWith($run+'\') -and $_.sha256 -ceq ('f'*64)}).Count -eq 1)
 Restore-UvClientFiles $f;Check ($moves -eq 1)
}
[ordered]@{contractId='nll/user-validation-controller-synthetic/v1';checks=$checks;statusCode='passed';gameStarted=$false;systemChangesApplied=$false}|ConvertTo-Json -Compress
