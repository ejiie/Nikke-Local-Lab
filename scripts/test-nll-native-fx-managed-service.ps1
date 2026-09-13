$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.NativeFxManagedService.ps1')
$script:checks=0; $script:sets=0; $script:stops=0; $script:dependencies=$false
$script:failStop=$false; $script:failSet=$false
$script:state=[pscustomobject]@{name='AntiCheatExpert Protection';pathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe"  -autorun';startName='LocalSystem';startMode='Manual';state='Stopped';processId=0;serviceType='Own Process';acceptStop=$false}
$baseline=$script:state.PSObject.Copy()
function Check([bool]$Condition) { if(-not $Condition){throw ('managed_service_check_'+($script:checks+1))};$script:checks++ }
function Reject([scriptblock]$Action,[string]$Code) {
    $errorCode=$null
    try { & $Action | Out-Null } catch { $errorCode=$_.Exception.Message }
    Check ($errorCode -ceq $Code)
}
function Get-FxManagedServiceSnapshot { $script:state.PSObject.Copy() }
function Assert-FxManagedServiceNoDependents { if($script:dependencies){throw 'resource_native_fx_managed_service_dependents_changed'} }
function Set-Service($Name,$StartupType,$ErrorAction) {
    Check ($Name -ceq 'AntiCheatExpert Protection' -and $StartupType -cin @('Manual','Disabled'))
    $script:sets++;$script:state.startMode=$StartupType
    if($script:failSet){throw 'synthetic_after_set_failure'}
}
function Request-FxManagedServiceStop {
    $script:stops++
    if($script:failStop){throw 'synthetic_stop_rejected'}
    $script:state.state='Stopped';$script:state.processId=0
}
Assert-FxManagedServiceSnapshot $state before
Check ($sets -eq 0 -and $stops -eq 0)
Reject {Stop-FxManagedService} 'resource_native_fx_managed_service_stop_without_job_zero'
Reject {Restore-FxManagedService} 'resource_native_fx_managed_service_restore_without_scope_zero'
Check ($sets -eq 0 -and $stops -eq 0)
$null=Stop-FxManagedService -JobZeroVerified $true
Check ($state.startMode -ceq 'Disabled' -and $stops -eq 0)
$null=Restore-FxManagedService -ScopeZeroVerified $true
Check ($state.startMode -ceq 'Manual' -and $state.state -ceq 'Stopped')
$state.state='Running';$state.processId=12345;$state.acceptStop=$true
Assert-FxManagedServiceSnapshot $state runtime
Reject {Assert-FxManagedServiceSnapshot $state before} 'resource_native_fx_managed_service_not_cold'
Reject {Restore-FxManagedService -ScopeZeroVerified $true} 'resource_native_fx_managed_service_restore_while_running'
$null=Stop-FxManagedService -JobZeroVerified $true
Check ($stops -eq 1 -and $state.state -ceq 'Stopped' -and $state.processId -eq 0 -and $state.startMode -ceq 'Disabled')
$null=Stop-FxManagedService -JobZeroVerified $true
Check ($stops -eq 1)
$null=Restore-FxManagedService -ScopeZeroVerified $true
$oldSets=$sets
$null=Restore-FxManagedService -ScopeZeroVerified $true
Check ($sets -eq $oldSets)
foreach($field in @('name','pathName','startName','serviceType')) {
    $original=$state.$field;$state.$field='wrong'
    Reject {Stop-FxManagedService -JobZeroVerified $true} 'resource_native_fx_managed_service_identity_drift'
    Reject {Restore-FxManagedService -ScopeZeroVerified $true} 'resource_native_fx_managed_service_identity_drift'
    Check ($sets -eq $oldSets)
    $state.$field=$original
}
$state.startMode='Auto'
Reject {Stop-FxManagedService -JobZeroVerified $true} 'resource_native_fx_managed_service_mode_drift'
$state.startMode='Manual';$state.state='Paused'
Reject {Assert-FxManagedServiceSnapshot $state runtime} 'resource_native_fx_managed_service_state_invalid'
$state.state='Stopped';$state.processId=2
Reject {Assert-FxManagedServiceSnapshot $state runtime} 'resource_native_fx_managed_service_pid_invalid'
$state.state='Running';$state.processId=0
Reject {Assert-FxManagedServiceSnapshot $state runtime} 'resource_native_fx_managed_service_pid_invalid'
$state.state='Stopped';$state.processId=-1
Reject {Assert-FxManagedServiceSnapshot $state runtime} 'resource_native_fx_managed_service_pid_invalid'
$state=$baseline.PSObject.Copy();$script:dependencies=$true
Reject {Stop-FxManagedService -JobZeroVerified $true} 'resource_native_fx_managed_service_dependents_changed'
Check ($sets -eq $oldSets)
$script:dependencies=$false;$script:failSet=$true
Reject {Stop-FxManagedService -JobZeroVerified $true} 'synthetic_after_set_failure'
Check ($state.startMode -ceq 'Disabled')
$script:failSet=$false
$null=Restore-FxManagedService -ScopeZeroVerified $true
$state.state='Running';$state.processId=12345;$script:failStop=$true
Reject {Stop-FxManagedService -JobZeroVerified $true} 'synthetic_stop_rejected'
Check ($state.state -ceq 'Running' -and $state.startMode -ceq 'Disabled')
Reject {Restore-FxManagedService -ScopeZeroVerified $true} 'resource_native_fx_managed_service_restore_while_running'
$script:failStop=$false
$null=Stop-FxManagedService -JobZeroVerified $true
$null=Restore-FxManagedService -ScopeZeroVerified $true

$entry=[pscustomobject]@{ProcessId=12345;ExecutablePath='C:\Program Files\AntiCheatExpert\ACE-Service64.exe';CreationDate=[datetime]::UtcNow;JobMember=$false}
$parent=[pscustomobject]@{ImagePath='C:\Windows\System32\services.exe';CreatedFileTime=$entry.CreationDate.AddMinutes(-1).ToFileTimeUtc()}
$state.state='Running';$state.processId=12345
Assert-FxManagedServiceEntry $state $entry $parent
Check $true
foreach($field in @('ProcessId','ExecutablePath','JobMember')) {
    $original=$entry.$field
    $entry.$field=switch($field){'ProcessId'{42};'JobMember'{$true};default{'C:\fake\ACE-Service64.exe'}}
    Reject {Assert-FxManagedServiceEntry $state $entry $parent} 'resource_native_fx_managed_service_process_unbound'
    $entry.$field=$original
}
Reject {Assert-FxManagedServiceEntry $state $entry $null} 'resource_native_fx_managed_service_process_unbound'
$parent.ImagePath='C:\fake\services.exe'
Reject {Assert-FxManagedServiceEntry $state $entry $parent} 'resource_native_fx_managed_service_process_unbound'
$parent.ImagePath='C:\Windows\System32\services.exe';$parent.CreatedFileTime=$entry.CreationDate.AddSeconds(1).ToFileTimeUtc()
Reject {Assert-FxManagedServiceEntry $state $entry $parent} 'resource_native_fx_managed_service_process_unbound'
$script:drivers=@([pscustomobject]@{name='synthetic-driver';pathName='synthetic';state='Running';startMode='Manual'})
function Get-FxManagedDriverSnapshot { return ,$script:drivers }
$before=@($drivers[0].PSObject.Copy())
Assert-FxManagedDriverBaseline $before
Check $true
$drivers[0].state='Stopped'
Reject {Assert-FxManagedDriverBaseline $before} 'resource_native_fx_managed_driver_state_drift'
$pins=@([ordered]@{path='C:\synthetic\a.exe';sha256=('a'*64);length=3},[ordered]@{path='C:\synthetic\b.exe';sha256=('b'*64);length=4},[ordered]@{path='C:\SYNTHETIC\A.EXE';sha256=('a'*64);length=3})
$merged=Merge-FxManagedProgramPins $pins
Check ($merged.Count -eq 2 -and $merged[0].path -ceq $pins[0].path -and $merged[1].path -ceq $pins[1].path)
$pins[2].length=7
Reject {Merge-FxManagedProgramPins $pins} 'resource_native_fx_managed_duplicate_pin_conflict'
$pins[2].length=3;$pins[2].sha256=('c'*64)
Reject {Merge-FxManagedProgramPins $pins} 'resource_native_fx_managed_duplicate_pin_conflict'
[ordered]@{status='passed';checks=$checks;syntheticOnly=$true;realServiceCalls=0;realDriverChanges=0}|ConvertTo-Json -Compress
