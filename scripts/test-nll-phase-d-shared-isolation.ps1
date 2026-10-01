# Synthetic firewall/SCM boundary; production lifecycle code, no OS mutations.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Windows PowerShell 5.1 otherwise autoloads Utility on the first qualified
# hash call and replaces our Get-FileHash mock with its exported function.
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
. (Join-Path $PSScriptRoot 'Nll.PhaseDSharedIsolation.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('nll-isolation-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
$seal='a'*64
$checks=0
$script:serviceHashCalls=0
function Need($Value) { if(-not $Value){throw ('isolation_test_failed_'+$MyInvocation.ScriptLineNumber)}; $script:checks++ }
function Reject([scriptblock]$Action,[string]$Code) {
    $caught=$false
    try { & $Action } catch { if($_.Exception.Message -cne $Code){throw};$caught=$true }
    Need $caught
}
function Reset-Test {
    $script:rules=@(
        [pscustomobject]@{name='NLL.PhaseD151.Program.0';program='C:\NIKKE\Launcher\nikke_launcher.exe';enabled=$false},
        [pscustomobject]@{name='NLL.PhaseD151.Program.1';program='C:\Program Files\AntiCheatExpert\ACE-Service64.exe';enabled=$false},
        [pscustomobject]@{name='NLL.PhaseD151.Program.2';program='C:\NLL\Clients\synthetic\nikke.exe';enabled=$true})
    $script:baseRules=@(1..17 | ForEach-Object { [pscustomobject]@{Group='NLL Phase3B2 Physical Isolation';Name="base-$_";InstanceID="base-$_";Direction='Outbound';Action='Block';Enabled='True'} })
    $script:extension=@();$script:queryFault='none';$script:enableFault='none';$script:enableCalled=$false;$script:runnerFault='none'
    $script:groupQueries=0;$script:nameQueries=@();$script:mutationReturn='stale';$script:restoreFault='none';$script:restoring=$false
    $script:filterBulkQueries=0;$script:filterAssociationQueries=0;$script:filterFault='none'
    $script:PhaseDRunnerIsolationOwned=$false
    $script:processes=@();$script:services=@();$script:failEnable=$false;$script:failDisable=$false;$script:failStop=$false;$script:stopCalls=0;$script:serviceHashCalls=0
    $script:case=Join-Path $root ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $case
    $script:bundle=[pscustomobject]@{clientPrograms=@([pscustomobject]@{path=$rules[2].program});blockOnlyPrograms=@($rules[0].program,$rules[1].program)}
}
function Get-NetFirewallRule {
    [CmdletBinding()]param($Group,$Name)
    if ($Group) { $script:groupQueries++ }
    if ($Name) { $script:nameQueries+=,@($Name) }
    if ($Group -contains 'NLL PhaseD 151 Client Isolation' -or $Name) {
        foreach($row in @($script:rules | Where-Object { -not $Name -or $_.name -in $Name })) {
            $result=[pscustomobject]@{Group='NLL PhaseD 151 Client Isolation';Name=$row.name;InstanceID=$row.name;Direction='Outbound';Action='Block';Enabled=[string]$row.enabled}
            if ($Name -and $enableCalled) {
                switch($enableFault){
                    'disabled' {$result.Enabled='False'}
                    'direction' {$result.Direction='Inbound'}
                    'group' {$result.Group='unowned'}
                    'action' {$result.Action='Allow'}
                    'name' {$result.Name='NLL.PhaseD151.Program.999'}
                    'duplicate' {$result.Name=$Name[0];$result.InstanceID=$Name[0]}
                }
                if($enableFault -ceq 'missing') { continue }
                if($enableFault -ceq 'read-error') { throw 'synthetic_readback_failed' }
            }
            $result
        }
    }
    if ($Name) {
        if ($restoring -and $restoreFault -ceq 'read-error') { throw 'synthetic_restore_read_failed' }
        if ($runnerFault -ceq 'read-error' -and $script:extension.Count) { throw 'synthetic_readback_failed' }
        $script:extension | Where-Object { $_.Name -cin $Name }
        foreach ($missing in @($Name | Where-Object { $_ -cnotin @($script:rules.name) -and $_ -cnotin @($script:extension | ForEach-Object { $_.Name }) })) {
            $id=if($restoring -and $restoreFault -ceq 'query-error'){'synthetic_provider_failure'}else{'CmdletizationQuery_NotFound_InstanceID'}
            Write-Error -Message 'synthetic_name_query_failed' -ErrorId $id -Category ObjectNotFound -TargetObject $missing
        }
    }
    if ($Group -contains 'NLL Phase3B2 Physical Isolation') { $script:baseRules }
    if ($Group -contains 'NLL Phase3B2 Epinel Minimal Extension') {
        if ($script:extension.Count) { $script:extension }
        else {
            $id=if($queryFault -ceq 'other-error'){'synthetic_provider_failure'}else{'CmdletizationQuery_NotFound_RuleGroup'}
            $target=if($queryFault -ceq 'required-group'){'NLL PhaseD 151 Client Isolation'}else{'NLL Phase3B2 Epinel Minimal Extension'}
            Write-Error -Message 'synthetic_query_failed' -ErrorId $id -Category ObjectNotFound -TargetObject $target
        }
    }
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]param($PolicyStore,[Parameter(ValueFromPipeline=$true)]$InputObject)
    process {
        if ($InputObject) { $script:filterAssociationQueries++ }
        else {
            if ($PolicyStore -cne 'PersistentStore') { throw 'unexpected_filter_store' }
            $script:filterBulkQueries++
        }
        if ($filterFault -ceq 'read-error') { throw 'synthetic_filter_read_failed' }
        # Bulk results contain unrelated rules, including unrelated duplicate IDs.
        if (-not $InputObject) {
            [pscustomobject]@{InstanceID='unrelated';Program='C:\unrelated-one.exe'}
            [pscustomobject]@{InstanceID='unrelated';Program='C:\unrelated-two.exe'}
        }
        foreach($row in @(@($script:rules)+@($script:extension) | Where-Object { -not $InputObject -or $_.name -ceq $InputObject.InstanceID })) {
            if ($filterFault -ceq 'missing' -and $row.name -ceq $script:rules[0].name) { continue }
            $program=$row.program
            if ($enableCalled -and $enableFault -ceq 'filter-missing') { continue }
            if ($enableCalled -and $enableFault -ceq 'program') { $program='C:\unbound.exe' }
            if ($enableCalled -and $enableFault -ceq 'swapped-programs') { $program=if($row.name -ceq $script:rules[0].name){$script:rules[1].program}else{$script:rules[0].program} }
            if ($row.name -notlike 'NLL.PhaseD151.*') {
                if ($runnerFault -ceq 'apply-program') { $program='C:\unbound.exe' }
                if ($runnerFault -ceq 'filter-missing') { continue }
            }
            [pscustomobject]@{InstanceID=$row.name;Program=$program}
            if ($filterFault -ceq 'duplicate' -and $row.name -ceq $script:rules[0].name) {
                [pscustomobject]@{InstanceID=$row.name;Program=$program}
            }
        }
    }
}
function Enable-NetFirewallRule {
    param([string[]]$Name,[switch]$PassThru)
    $script:enableCalled=$true
    foreach($name in $Name){
        $row=$script:rules|Where-Object name -CEQ $name
        $before=[pscustomobject]@{Name=$name;InstanceID=$name;Direction='Outbound';Action='Block';Enabled=[string]$row.enabled}
        $row.enabled=$true
        if($script:failEnable){throw 'synthetic_enable_failed'}
        if($script:mutationReturn -cne 'empty'){$before}
    }
}
function New-NetFirewallRule {
    param($Name,$DisplayName,$Group,$Direction,$Action,$Enabled,$Profile,$Program,$ErrorAction)
    if($runnerFault -ceq 'partial' -and $script:extension.Count -eq 1){throw 'synthetic_partial_apply'}
    $stored=[pscustomobject]@{Name=$Name;InstanceID=$Name;Group=$Group;Direction=$Direction;Action=$Action;Enabled=$Enabled;Program=$Program}
    switch($runnerFault){
        'apply-disabled' {$stored.Enabled='False'}
        'apply-direction' {$stored.Direction='Inbound'}
        'apply-action' {$stored.Action='Allow'}
        'apply-name' {$stored.Name='unexpected'}
        'apply-group' {$stored.Group='unowned'}
        'duplicate' {$stored.Name='NLL.Phase3B2.EpinelMinimal.BootstrapBlock'}
    }
    $script:extension+=$stored
    # Deliberately unusable mutation return. Only a later Get reads applied state.
    if($runnerFault -ceq 'return-missing' -or $script:mutationReturn -ceq 'empty'){return}
    $before=$stored.PSObject.Copy();$before.Enabled='False';$before
}
function Disable-NetFirewallRule {
    param([string[]]$Name,[switch]$PassThru)
    foreach($name in $Name){
        if($script:failDisable){throw 'synthetic_disable_failed'}
        $row=$script:rules|Where-Object name -CEQ $name;$before=$row.PSObject.Copy()
        if($restoreFault -cne 'disable-noop'){$row.enabled=$false}
        $script:restoring=$true
        if($script:mutationReturn -cne 'empty'){$before}
    }
}
function Remove-NetFirewallRule {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$PassThru)
    process {
        $before=$InputObject.PSObject.Copy()
        if($restoreFault -ceq 'remove-error'){throw 'synthetic_remove_failed'}
        if($restoreFault -cne 'remove-noop'){$script:extension=@($script:extension | Where-Object Name -CNE $InputObject.Name)}
        $script:restoring=$true
        if($mutationReturn -cne 'empty'){$before}
    }
}
function Get-CimInstance {
    param($ClassName)
    if($ClassName -ceq 'Win32_Process'){$script:processes}
    elseif($ClassName -ceq 'Win32_Service'){$script:services}
    else{throw 'unexpected_os_query'}
}
function Get-FileHash {
    param($LiteralPath)
    if($LiteralPath -ieq 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe'){
        $script:serviceHashCalls++
        [pscustomobject]@{Hash=('b'*64)}
    } else {
        $resolved=[IO.Path]::GetFullPath($LiteralPath)
        if(-not $resolved.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
            throw 'unexpected_hash_path'
        }
        Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $resolved
    }
}
function Stop-Service { param($Name) $script:stopCalls++;if($script:failStop){throw 'synthetic_stop_failed'};$script:services[0].State='Stopped' }
function Get-Service {
    param($Name)
    $item=New-Object PSObject
    $item|Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout)}
    $item|Add-Member ScriptMethod Dispose {}
    $item
}
try {
    # Hash a real synthetic file first: this triggered the 5.1 autoload bug.
    $probe=Join-Path $root 'hash-probe.txt'
    [IO.File]::WriteAllText($probe,'synthetic hash probe')
    Need ((Get-FileHash -LiteralPath $probe).Hash.Length -eq 64)
    Need ((Get-FileHash -LiteralPath 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe').Hash -ceq ('b'*64))
    Need ($script:serviceHashCalls -eq 1)
    Reject {Get-FileHash -LiteralPath (Join-Path $root '../outside-fixture.txt')} 'unexpected_hash_path'
    Reset-Test
    Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Need (@($rules|Where-Object {-not $_.enabled}).Count -eq 0)
    Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled -and $rules[2].enabled)
    $script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Restore-PhaseDSharedIsolation $case $seal # retry after an official login has begun
    Need ($stopCalls -eq 0)
    Reset-Test;$script:failEnable=$true
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'synthetic_enable_failed'
    Need ($rules[0].enabled -and -not $rules[1].enabled)
    Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    Reset-Test;Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    $script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_process_running'
    Need ($rules[0].enabled -and $rules[1].enabled)
    $script:processes=@();$script:failDisable=$true
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'synthetic_disable_failed'
    Need (-not (Test-Path (Join-Path $case 'shared-isolation.restored.json')))
    $script:failDisable=$false;Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled)
    Reset-Test;$rules[0].enabled=$true;Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Restore-PhaseDSharedIsolation $case $seal
    Need ($rules[0].enabled -and -not $rules[1].enabled) # preserve a prior administrator block
    Reset-Test;$rules[2].enabled=$false
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'phase_d_client_isolation_missing'
    Reset-Test;$script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'phase_d_shared_isolation_process_running'
    Need (-not (Test-Path (Join-Path $case 'shared-isolation.before.json')))
    Reset-Test;Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Reject {Restore-PhaseDSharedIsolation $case ('c'*64)} 'phase_d_shared_isolation_journal_invalid'
    $rules[0].program='C:\NIKKE\Launcher\changed.exe'
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_rule_changed'
    Need ($rules[0].enabled)
    Reset-Test
    $script:services=@([pscustomobject]@{Name='AntiCheatExpert Protection';PathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe" -autorun';State='Stopped';StartMode='Manual'})
    Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Need ((Get-Content -LiteralPath (Join-Path $case 'shared-isolation.before.json') -Raw | ConvertFrom-Json).services[0].sha256 -ceq ('b'*64))
    $services[0].State='Running'
    Restore-PhaseDSharedIsolation $case $seal
    Need ($script:serviceHashCalls -eq 2)
    Need ($stopCalls -eq 1 -and $services[0].State -ceq 'Stopped' -and -not $rules[1].enabled)
    Reset-Test
    $script:services=@([pscustomobject]@{Name='AntiCheatExpert Protection';PathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe" -autorun';State='Running';StartMode='Manual'})
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'phase_d_shared_isolation_service_running'
    $services[0].State='Stopped';Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'phase_d_shared_isolation_already_owned'
    $services[0].State='Running';$script:failStop=$true
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'synthetic_stop_failed'
    Need ($rules[0].enabled -and $rules[1].enabled)
    $script:failStop=$false;Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    $rules[0].enabled=$true # a later owner changed the policy; old recovery must not overwrite it
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_state_changed'
    foreach($fault in @('missing-client','changed-program')) {
        Reset-Test
        if($fault -ceq 'missing-client'){$script:rules=$rules[0..1]}else{$rules[2].program='C:\NLL\Clients\synthetic\other.exe'}
        Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'phase_d_isolation_inventory_changed'
        Need (-not (Test-Path (Join-Path $case 'shared-isolation.before.json')) -and -not $rules[0].enabled)
    }
    # Only exact absence of the optional group is accepted; other query failures
    # cannot be disguised by a valid-looking partial result.
    foreach($fault in @('required-group','other-error')) {
        Reset-Test;$script:queryFault=$fault
        Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} 'synthetic_query_failed'
        Need (-not (Test-Path (Join-Path $case 'shared-isolation.before.json')) -and -not $rules[0].enabled)
    }
    foreach($fault in @('missing','disabled','group','direction','action','name','duplicate','program','swapped-programs','filter-missing','read-error')) {
        Reset-Test;$script:enableFault=$fault
        $code=if($fault -in @('group','direction','action','filter-missing')){'phase_d_isolation_rule_invalid'}elseif($fault -ceq 'read-error'){'synthetic_readback_failed'}else{'phase_d_shared_isolation_apply_failed'}
        Reject {Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null} $code
        # A failed/invalid readback never admits the run, even if a write succeeded.
        Need ($rules[0].enabled -and $rules[1].enabled -and (Test-Path (Join-Path $case 'shared-isolation.before.json')))
        $script:enableFault='none';Restore-PhaseDSharedIsolation $case $seal
        Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    }
    foreach($fault in @('none','base-count','base-disabled','existing','partial','apply-disabled','apply-program',
        'read-error','return-missing','apply-name','apply-group','apply-direction','apply-action','duplicate','filter-missing')) {
        Reset-Test;$script:runnerFault=$fault
        $spec=@{launchRoot=$case;bootstrapRoot=(Join-Path $case 'bootstrap')}
        if($fault -ceq 'base-count'){$script:baseRules=$baseRules[0..15]}
        if($fault -ceq 'base-disabled'){$baseRules[0].Enabled='False'}
        if($fault -ceq 'existing'){$script:extension=@([pscustomobject]@{Name='preexisting';Group='NLL Phase3B2 Epinel Minimal Extension';Program='C:\unbound.exe'})}
        $caught=$false;$admitted=$false
        try {
            $inventory=@(Enter-PhaseDSharedIsolation $case $seal $bundle)
            Enter-PhaseDRunnerIsolation $spec -Rules $inventory
            $admitted=$true
        } catch {
            $code=if($fault -in @('base-count','base-disabled','existing')){'phase3b2_epinel_minimal_start_firewall_precondition_invalid'}
                elseif($fault -ceq 'partial'){'synthetic_partial_apply'}elseif($fault -ceq 'read-error'){'synthetic_readback_failed'}elseif($fault -in @('apply-name','duplicate')){'synthetic_name_query_failed'}else{'phase3b2_epinel_minimal_start_firewall_apply_failed'}
            Need ($_.Exception.Message -ceq $code)
            $caught=$true
        }
        Need ($caught -eq ($fault -cnotin @('none','return-missing')) -and $admitted -eq ($fault -cin @('none','return-missing')))
        Need ($script:PhaseDRunnerIsolationOwned -eq ($fault -cnotin @('base-count','base-disabled','existing')))
        if($fault -ceq 'partial'){Need ($script:extension.Count -eq 1)}
        # Simulate the existing owner's proven extension cleanup before shared restore.
        $script:extension=@();$script:runnerFault='none'
        Restore-PhaseDSharedIsolation $case $seal
        Need (-not $rules[0].enabled -and -not $rules[1].enabled -and $rules[2].enabled)
    }

    # Startup has one three-group query and two narrowly scoped readbacks.
    # Both stale and empty mutation returns must be irrelevant to admission.
    foreach($returnMode in @('stale','empty')) {
        Reset-Test;$script:mutationReturn=$returnMode
        $spec=@{launchRoot=$case;bootstrapRoot=(Join-Path $case 'bootstrap')}
        $inventory=@(Enter-PhaseDSharedIsolation $case $seal $bundle)
        Enter-PhaseDRunnerIsolation $spec -Rules $inventory
        Need ($script:groupQueries -eq 1 -and $script:nameQueries.Count -eq 2)
        Need (@(Compare-Object @($rules[0].name,$rules[1].name) $script:nameQueries[0]).Count -eq 0)
        Need (@(Compare-Object @('NLL.Phase3B2.EpinelMinimal.BootstrapBlock','NLL.PhaseD.RuntimeServerBlock') $script:nameQueries[1]).Count -eq 0)
        Restore-PhaseDSharedIsolation $case $seal
        Need ($script:extension.Count -eq 0)
        Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    }
    Reset-Test
    Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    $script:enableFault='group'
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_isolation_rule_invalid'
    Need ($rules[0].enabled -and -not (Test-Path (Join-Path $case 'shared-isolation.restored.json')))
    foreach($fault in @('disable-noop','remove-noop','remove-error','read-error','query-error')) {
        Reset-Test
        $inventory=@(Enter-PhaseDSharedIsolation $case $seal $bundle)
        Enter-PhaseDRunnerIsolation @{launchRoot=$case;bootstrapRoot=(Join-Path $case 'bootstrap')} -Rules $inventory
        $script:restoreFault=$fault
        $code=@{'disable-noop'='phase_d_shared_isolation_restore_failed';'remove-noop'='phase_d_extension_firewall_remove_failed';
            'remove-error'='synthetic_remove_failed';'read-error'='synthetic_restore_read_failed';'query-error'='synthetic_name_query_failed'}[$fault]
        Reject {Restore-PhaseDSharedIsolation $case $seal} $code
        Need (-not (Test-Path (Join-Path $case 'shared-isolation.restored.json')))
        $script:restoreFault='none';Restore-PhaseDSharedIsolation $case $seal
        Need (-not $rules[0].enabled -and -not $rules[1].enabled -and $rules[2].enabled -and $extension.Count -eq 0)
    }
    Reset-Test
    Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    $script:rules=@($rules | Where-Object name -CNE 'NLL.PhaseD151.Program.0')
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'synthetic_name_query_failed'
    Need ($rules[0].enabled -and -not (Test-Path (Join-Path $case 'shared-isolation.restored.json')))
    # Both entry modes join the requested rules against one fresh bulk result.
    foreach($applied in @($false,$true)) {
        Reset-Test
        $requested=@(Get-NetFirewallRule -Name @($rules.name))
        $result=@(Get-PhaseDIsolationRules -Rules $requested -Applied:$applied)
        Need ($filterBulkQueries -eq 1 -and $filterAssociationQueries -eq 0 -and $result.Count -eq $rules.Count)
        foreach($row in $rules) {
            Need (@($result | Where-Object { $_.name -ceq $row.name -and $_.program -ceq $row.program -and $_.enabled -eq $row.enabled }).Count -eq 1)
        }
        foreach($fault in @('missing','duplicate','read-error')) {
            $script:filterFault=$fault
            $code=if($fault -ceq 'read-error'){'synthetic_filter_read_failed'}else{'phase_d_isolation_rule_invalid'}
            Reject {Get-PhaseDIsolationRules -Rules $requested -Applied:$applied} $code
        }
    }
    Reset-Test
    Enter-PhaseDSharedIsolation $case $seal $bundle | Out-Null
    Need ($filterBulkQueries -eq 2 -and $filterAssociationQueries -eq 0)
    Restore-PhaseDSharedIsolation $case $seal
    Need ($filterBulkQueries -eq 4 -and $filterAssociationQueries -eq 0)
    Need (-not $rules[0].enabled -and -not $rules[1].enabled -and $rules[2].enabled)
    Write-Output "Shared isolation lifecycle: $checks checks passed."
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'nll-isolation-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
