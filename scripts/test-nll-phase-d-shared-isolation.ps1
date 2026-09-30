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
    $script:processes=@();$script:services=@();$script:failEnable=$false;$script:failDisable=$false;$script:failStop=$false;$script:stopCalls=0;$script:serviceHashCalls=0
    $script:case=Join-Path $root ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $case
    $script:bundle=[pscustomobject]@{clientPrograms=@([pscustomobject]@{path=$rules[2].program});blockOnlyPrograms=@($rules[0].program,$rules[1].program)}
}
function Get-NetFirewallRule {
    param($Group,$Name)
    foreach($row in @($script:rules | Where-Object { -not $Name -or $_.name -in $Name })){[pscustomobject]@{Name=$row.name;InstanceID=$row.name;Direction='Outbound';Action='Block';Enabled=[string]$row.enabled}}
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]param($PolicyStore,[Parameter(ValueFromPipeline=$true)]$InputObject)
    process {
        foreach($row in @($script:rules | Where-Object { -not $InputObject -or $_.name -ceq $InputObject.Name })) {
            [pscustomobject]@{InstanceID=$row.name;Program=$row.program}
        }
    }
}
function Enable-NetFirewallRule {
    param([string[]]$Name)
    foreach($name in $Name){($script:rules|Where-Object name -CEQ $name).enabled=$true;if($script:failEnable){throw 'synthetic_enable_failed'}}
}
function Disable-NetFirewallRule {
    param([string[]]$Name)
    foreach($name in $Name){if($script:failDisable){throw 'synthetic_disable_failed'};($script:rules|Where-Object name -CEQ $name).enabled=$false}
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
    Enter-PhaseDSharedIsolation $case $seal $bundle
    Need (@($rules|Where-Object {-not $_.enabled}).Count -eq 0)
    Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled -and $rules[2].enabled)
    $script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Restore-PhaseDSharedIsolation $case $seal # retry after an official login has begun
    Need ($stopCalls -eq 0)
    Reset-Test;$script:failEnable=$true
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle} 'synthetic_enable_failed'
    Need ($rules[0].enabled -and -not $rules[1].enabled)
    Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    Reset-Test;Enter-PhaseDSharedIsolation $case $seal $bundle
    $script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_process_running'
    Need ($rules[0].enabled -and $rules[1].enabled)
    $script:processes=@();$script:failDisable=$true
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'synthetic_disable_failed'
    Need (-not (Test-Path (Join-Path $case 'shared-isolation.restored.json')))
    $script:failDisable=$false;Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled)
    Reset-Test;$rules[0].enabled=$true;Enter-PhaseDSharedIsolation $case $seal $bundle
    Restore-PhaseDSharedIsolation $case $seal
    Need ($rules[0].enabled -and -not $rules[1].enabled) # preserve a prior administrator block
    Reset-Test;$rules[2].enabled=$false
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle} 'phase_d_client_isolation_missing'
    Reset-Test;$script:processes=@([pscustomobject]@{Name='nikke_launcher.exe';ExecutablePath=$null})
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle} 'phase_d_shared_isolation_process_running'
    Need (-not (Test-Path (Join-Path $case 'shared-isolation.before.json')))
    Reset-Test;Enter-PhaseDSharedIsolation $case $seal $bundle
    Reject {Restore-PhaseDSharedIsolation $case ('c'*64)} 'phase_d_shared_isolation_journal_invalid'
    $rules[0].program='C:\NIKKE\Launcher\changed.exe'
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_rule_changed'
    Need ($rules[0].enabled)
    Reset-Test
    $script:services=@([pscustomobject]@{Name='AntiCheatExpert Protection';PathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe" -autorun';State='Stopped';StartMode='Manual'})
    Enter-PhaseDSharedIsolation $case $seal $bundle
    Need ((Get-Content -LiteralPath (Join-Path $case 'shared-isolation.before.json') -Raw | ConvertFrom-Json).services[0].sha256 -ceq ('b'*64))
    $services[0].State='Running'
    Restore-PhaseDSharedIsolation $case $seal
    Need ($script:serviceHashCalls -eq 2)
    Need ($stopCalls -eq 1 -and $services[0].State -ceq 'Stopped' -and -not $rules[1].enabled)
    Reset-Test
    $script:services=@([pscustomobject]@{Name='AntiCheatExpert Protection';PathName='"C:\Program Files\AntiCheatExpert\ACE-Service64.exe" -autorun';State='Running';StartMode='Manual'})
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle} 'phase_d_shared_isolation_service_running'
    $services[0].State='Stopped';Enter-PhaseDSharedIsolation $case $seal $bundle
    Reject {Enter-PhaseDSharedIsolation $case $seal $bundle} 'phase_d_shared_isolation_already_owned'
    $services[0].State='Running';$script:failStop=$true
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'synthetic_stop_failed'
    Need ($rules[0].enabled -and $rules[1].enabled)
    $script:failStop=$false;Restore-PhaseDSharedIsolation $case $seal
    Need (-not $rules[0].enabled -and -not $rules[1].enabled)
    $rules[0].enabled=$true # a later owner changed the policy; old recovery must not overwrite it
    Reject {Restore-PhaseDSharedIsolation $case $seal} 'phase_d_shared_isolation_state_changed'
    # Base/extension rules are now acquired by the coordinator, before its child.
    & {
        $spec=@{launchRoot=$root;bootstrapRoot=(Join-Path $root 'bootstrap')}
        foreach($fault in @('none','base-count','base-disabled','existing','partial','apply-disabled','apply-program')) {
            $script:extension=@();$script:PhaseDRunnerIsolationOwned=$false
            $created=0;$admitted=$false
            function Get-NetFirewallRule {
                param($Group,$ErrorAction)
                if($Group -ceq 'NLL Phase3B2 Physical Isolation') {
                    $count=if($fault -ceq 'base-count'){16}else{17}
                    1..$count | ForEach-Object { [pscustomobject]@{Direction='Outbound';Action='Block';Enabled=$(if($fault -ceq 'base-disabled'){'False'}else{'True'})} }
                } else {
                    if($fault -ceq 'existing'){[pscustomobject]@{Name='preexisting'}}else{$script:extension}
                }
            }
            function New-NetFirewallRule {
                param($Name,$DisplayName,$Group,$Direction,$Action,$Enabled,$Profile,$Program,$ErrorAction)
                if($fault -ceq 'partial' -and $script:extension.Count -eq 1){throw 'synthetic_partial_apply'}
                $script:extension+= [pscustomobject]@{Name=$Name;Direction=$Direction;Action=$Action
                    Enabled=$(if($fault -ceq 'apply-disabled'){'False'}else{$Enabled});Program=$Program}
            }
            function Get-NetFirewallApplicationFilter {
                [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject)
                process { [pscustomobject]@{Program=$(if($fault -ceq 'apply-program'){'C:\unbound.exe'}else{$InputObject.Program})} }
            }
            $caught=$false
            try { Enter-PhaseDRunnerIsolation $spec; $admitted=$true } catch { $caught=$true }
            Need ($caught -eq ($fault -cne 'none') -and $admitted -eq ($fault -ceq 'none'))
            Need ($script:PhaseDRunnerIsolationOwned -eq ($fault -cnotin @('base-count','base-disabled','existing')))
            if($fault -ceq 'partial'){Need ($script:extension.Count -eq 1)}
        }
    }

    Write-Output "Shared isolation lifecycle: $checks checks passed."
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'nll-isolation-*'){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
