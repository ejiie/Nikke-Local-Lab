# Shared official programs are blocked only while a local game owns them.
# Importing this helper never changes firewall/service state.
function Test-PhaseDSharedIsolationPath([string]$Path) {
    $Path.StartsWith('C:\NIKKE\', [StringComparison]::OrdinalIgnoreCase) -or
        $Path -ieq 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe'
}

function Get-PhaseDIsolationRules {
    param([object[]]$Rules, [switch]$Applied)
    $supplied=$PSBoundParameters.ContainsKey('Rules')
    if (-not $supplied) { $Rules = @(Get-NetFirewallRule -Group 'NLL PhaseD 151 Client Isolation' -ErrorAction Stop) }
    $filters=@{}
    # Applied rules were freshly read by name. Bulk-read their filters once as well;
    # pipeline association queries perform one provider round trip per rule.
    foreach ($filter in @(Get-NetFirewallApplicationFilter -PolicyStore PersistentStore -ErrorAction Stop)) {
        $key=[string]$filter.InstanceID
        $filters[$key]=@($filters[$key]) + @($filter)
    }
    foreach ($rule in $rules) {
        $apps = @($filters[[string]$rule.InstanceID] | Where-Object { $null -ne $_ })
        if ($apps.Count -ne 1 -or $rule.Group -cne 'NLL PhaseD 151 Client Isolation' -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or
            $rule.Name -cnotmatch '^NLL\.PhaseD151\.Program\.[0-9]+$') { throw 'phase_d_isolation_rule_invalid' }
        [pscustomobject]@{name=[string]$rule.Name; program=[string]$apps[0].Program; enabled=([string]$rule.Enabled -eq 'True')}
    }
}

function Write-PhaseDIsolationJson([string]$Path, [object]$Value) {
    $temp=$Path+'.partial-'+[guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-PhaseDIsolationServices([string[]]$Programs) {
    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
        $match=[regex]::Match([string]$service.PathName, '^(?:"(?<exe>[^"]+\.exe)"|(?<exe>\S+\.exe))(?:\s|$)', 'IgnoreCase')
        if ($match.Success -and $Programs -icontains $match.Groups['exe'].Value) {
            [pscustomobject]@{name=[string]$service.Name; program=$match.Groups['exe'].Value
                state=[string]$service.State; startMode=[string]$service.StartMode}
        }
    }
}

function Assert-PhaseDIsolationProcessesCold([string[]]$Programs) {
    $names=@($Programs | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object -Unique)
    # Names also catch protected official processes whose path is unavailable.
    $running=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $names -icontains $_.Name -or $Programs -icontains $_.ExecutablePath
    })
    if ($running.Count) { throw 'phase_d_shared_isolation_process_running' }
}

function Enter-PhaseDSharedIsolation {
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256, [object]$RuntimeBundle)
    if ($null -eq $RuntimeBundle) { return }
    $rules=@(Get-NetFirewallRule -Group @('NLL PhaseD 151 Client Isolation',
        'NLL Phase3B2 Physical Isolation', 'NLL Phase3B2 Epinel Minimal Extension') `
        -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
    foreach ($queryError in $queryErrors) {
        # An absent extension group is expected before acquisition. No other query error is safe.
        if ($queryError.FullyQualifiedErrorId -cne 'CmdletizationQuery_NotFound_RuleGroup,Get-NetFirewallRule' -or
            [string]$queryError.TargetObject -cne 'NLL Phase3B2 Epinel Minimal Extension') { throw $queryError }
    }
    $all=@(Get-PhaseDIsolationRules -Rules @($rules | Where-Object Group -CEQ 'NLL PhaseD 151 Client Isolation'))
    $expected=@(@($RuntimeBundle.clientPrograms.path)+@($RuntimeBundle.blockOnlyPrograms) | Sort-Object -Unique)
    if ($all.Count -ne $expected.Count -or @(Compare-Object $expected @($all.program)).Count) {
        throw 'phase_d_isolation_inventory_changed'
    }
    if (@($all | Where-Object { -not (Test-PhaseDSharedIsolationPath $_.program) -and -not $_.enabled }).Count) {
        throw 'phase_d_client_isolation_missing'
    }
    $shared=@($all | Where-Object { Test-PhaseDSharedIsolationPath $_.program })
    $path=Join-Path $LaunchRoot 'shared-isolation.before.json'
    if (Test-Path -LiteralPath $path) { throw 'phase_d_shared_isolation_already_owned' }
    Assert-PhaseDIsolationProcessesCold $expected
    $services=@(Get-PhaseDIsolationServices @($shared.program))
    foreach ($service in $services) {
        if ($service.state -cne 'Stopped') { throw 'phase_d_shared_isolation_service_running' }
        $service | Add-Member -NotePropertyName sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $service.program).Hash.ToLowerInvariant())
    }
    # Durable before-image precedes even the first enable. Partial application is recoverable.
    Write-PhaseDIsolationJson $path ([ordered]@{contractId='nll/phase-d-shared-isolation/v1'
        launchRoot=[IO.Path]::GetFullPath($LaunchRoot);runnerBundleSha256=$ExpectedBundleSha256
        rules=$shared;services=$services})
    $enable=@($shared | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })
    if ($enable.Count) {
        Enable-NetFirewallRule -Name $enable -ErrorAction Stop | Out-Null
        # Mutation results may describe the pre-call state. Read back only changed names.
        $enabled=@(Get-NetFirewallRule -Name $enable -ErrorAction Stop)
        $after=@(Get-PhaseDIsolationRules -Rules $enabled -Applied)
        if ($after.Count -ne $enable.Count) { throw 'phase_d_shared_isolation_apply_failed' }
        foreach ($row in @($shared | Where-Object { $_.name -in $enable })) {
            if (@($after | Where-Object { $_.name -ceq $row.name -and $_.program -ieq $row.program -and $_.enabled }).Count -ne 1) {
                throw 'phase_d_shared_isolation_apply_failed'
            }
        }
    }
    # Pass this launch's inventory to runner isolation; no second group enumeration.
    $rules
}

function Restore-PhaseDSharedIsolation {
    # Caller retains its live Job or verified absent-Job recovery proof until return.
    param([string]$LaunchRoot, [string]$ExpectedBundleSha256)
    $path=Join-Path $LaunchRoot 'shared-isolation.before.json'
    $acquired=Test-Path -LiteralPath $path
    $before=if ($acquired) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
        else { [pscustomobject]@{rules=@();services=@()} }
    if ($acquired -and ($before.contractId -cne 'nll/phase-d-shared-isolation/v1' -or
        $before.launchRoot -cne [IO.Path]::GetFullPath($LaunchRoot) -or
        $before.runnerBundleSha256 -cne $ExpectedBundleSha256 -or
        @($before.rules).Count -eq 0 -or
        @($before.rules.name | Sort-Object -Unique).Count -ne @($before.rules).Count)) {
        throw 'phase_d_shared_isolation_journal_invalid'
    }
    $extensionNames=@('NLL.Phase3B2.EpinelMinimal.BootstrapBlock','NLL.PhaseD.RuntimeServerBlock')
    $names=@($before.rules | ForEach-Object { $_.name })+$extensionNames
    $queryErrors=@()
    $rules=@(Get-NetFirewallRule -Name $names -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
    foreach ($queryError in $queryErrors) {
        if ($queryError.FullyQualifiedErrorId -cne 'CmdletizationQuery_NotFound_InstanceID,Get-NetFirewallRule' -or
            [string]$queryError.TargetObject -cnotin $extensionNames) { throw $queryError }
    }
    $extension=@($rules | Where-Object { $_.Name -cin $extensionNames })
    if (@($extension | Where-Object Group -CNE 'NLL Phase3B2 Epinel Minimal Extension').Count) {
        throw 'phase_d_shared_isolation_rule_changed'
    }
    $shared=@(Get-PhaseDIsolationRules -Rules @($rules | Where-Object { $_.Name -cnotin $extensionNames }) -Applied)
    if ($shared.Count -ne @($before.rules).Count) { throw 'phase_d_shared_isolation_rule_changed' }
    foreach ($row in $before.rules) {
        if ($row.enabled -isnot [bool] -or -not (Test-PhaseDSharedIsolationPath $row.program) -or
            @($shared | Where-Object { $_.name -ceq $row.name -and $_.program -ieq $row.program }).Count -ne 1) {
            throw 'phase_d_shared_isolation_rule_changed'
        }
    }
    $restoredPath=Join-Path $LaunchRoot 'shared-isolation.restored.json'
    if (Test-Path -LiteralPath $restoredPath) {
        $restored=Get-Content -LiteralPath $restoredPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($restored.contractId -cne 'nll/phase-d-shared-isolation-restored/v1' -or
            $restored.runnerBundleSha256 -cne $ExpectedBundleSha256 -or $restored.restored -ne $true -or
            $restored.beforeSha256 -cne (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()) {
            throw 'phase_d_shared_isolation_receipt_invalid'
        }
        if ($extension.Count) { throw 'phase_d_shared_isolation_state_changed' }
        foreach ($row in $before.rules) {
            if (@($shared | Where-Object { $_.name -ceq $row.name -and $_.enabled -eq $row.enabled }).Count -ne 1) {
                throw 'phase_d_shared_isolation_state_changed'
            }
        }
        return # A retried completion must not stop a subsequent official session.
    }
    $services=@(Get-PhaseDIsolationServices @($shared | ForEach-Object { $_.program }))
    if ($services.Count -ne @($before.services).Count) { throw 'phase_d_shared_isolation_service_changed' }
    foreach ($baseline in $before.services) {
        $service=@($services | Where-Object { $_.name -ceq $baseline.name -and $_.program -ieq $baseline.program })
        if ($service.Count -ne 1 -or $baseline.state -cne 'Stopped' -or
            $service[0].startMode -cne $baseline.startMode -or
            (Get-FileHash -LiteralPath $baseline.program).Hash.ToLowerInvariant() -cne $baseline.sha256) {
            throw 'phase_d_shared_isolation_service_changed'
        }
        if ($service[0].state -cne 'Stopped') {
            # Only the previously approved shared ACE service, through normal SCM stop.
            if ($baseline.name -cne 'AntiCheatExpert Protection' -or
                $baseline.program -ine 'C:\Program Files\AntiCheatExpert\ACE-Service64.exe') {
                throw 'phase_d_shared_isolation_service_running'
            }
            Stop-Service -Name $baseline.name -ErrorAction Stop
            $controller=Get-Service -Name $baseline.name -ErrorAction Stop
            try { $controller.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(10)) } finally { $controller.Dispose() }
        }
    }
    # Service stop alone is not process-tree proof: retain blocks while a helper lives.
    Assert-PhaseDIsolationProcessesCold @($shared | ForEach-Object { $_.program })
    $enable=@($before.rules | Where-Object enabled | ForEach-Object { $_.name })
    $disable=@($before.rules | Where-Object { -not $_.enabled } | ForEach-Object { $_.name })
    if ($extension.Count) { $extension | Remove-NetFirewallRule -ErrorAction Stop | Out-Null }
    if ($enable.Count) { Enable-NetFirewallRule -Name $enable -ErrorAction Stop | Out-Null }
    if ($disable.Count) { Disable-NetFirewallRule -Name $disable -ErrorAction Stop | Out-Null }
    # Mutation objects may describe the old state. One fresh read covers all changed names.
    $queryErrors=@()
    $rules=@(Get-NetFirewallRule -Name $names -ErrorAction SilentlyContinue -ErrorVariable queryErrors)
    foreach ($queryError in $queryErrors) {
        if ($queryError.FullyQualifiedErrorId -cne 'CmdletizationQuery_NotFound_InstanceID,Get-NetFirewallRule' -or
            [string]$queryError.TargetObject -cnotin $extensionNames) { throw $queryError }
    }
    if (@($rules | Where-Object { $_.Name -cin $extensionNames }).Count) { throw 'phase_d_extension_firewall_remove_failed' }
    $after=@(Get-PhaseDIsolationRules -Rules $rules -Applied)
    foreach ($row in $before.rules) {
        if (@($after | Where-Object { $_.name -ceq $row.name -and $_.program -ieq $row.program -and $_.enabled -eq $row.enabled }).Count -ne 1) {
            throw 'phase_d_shared_isolation_restore_failed'
        }
    }
    if (-not $acquired) { return }
    Write-PhaseDIsolationJson (Join-Path $LaunchRoot 'shared-isolation.restored.json') ([ordered]@{
        contractId='nll/phase-d-shared-isolation-restored/v1';runnerBundleSha256=$ExpectedBundleSha256
        beforeSha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant();restored=$true})
}

# Coordinator calls this before creating the runner child. Existing cleanup owns
# the extension group, including failure before the runner publishes its pointer.
function Enter-PhaseDRunnerIsolation {
    param([object]$Specification, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rules)
    $group = 'NLL Phase3B2 Epinel Minimal Extension'
    $base = @($Rules | Where-Object Group -CEQ 'NLL Phase3B2 Physical Isolation')
    if ($base.Count -ne 17 -or @($base | Where-Object {
        $_.Direction -ne 'Outbound' -or $_.Action -ne 'Block' -or $_.Enabled -ne 'True'
    }).Count -or @($Rules | Where-Object Group -CEQ $group).Count) {
        throw 'phase3b2_epinel_minimal_start_firewall_precondition_invalid'
    }
    $script:PhaseDRunnerIsolationOwned = $true
    $programs = [ordered]@{
        'NLL.Phase3B2.EpinelMinimal.BootstrapBlock' = (Join-Path $Specification.bootstrapRoot 'artifact/NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe')
        'NLL.PhaseD.RuntimeServerBlock' = (Join-Path $Specification.launchRoot 'runtime/EpinelPS.exe')
    }
    foreach ($name in $programs.Keys) {
        New-NetFirewallRule -Name $name -DisplayName $name -Group $group -Direction Outbound -Action Block `
            -Enabled True -Profile Any -Program $programs[$name] -ErrorAction Stop | Out-Null
    }
    $created = @(Get-NetFirewallRule -Name @($programs.Keys) -ErrorAction Stop)
    if ($created.Count -ne $programs.Count) { throw 'phase3b2_epinel_minimal_start_firewall_apply_failed' }
    $filters=@($created | Get-NetFirewallApplicationFilter -ErrorAction Stop)
    foreach ($name in $programs.Keys) {
        $matching=@($created | Where-Object Name -CEQ $name)
        if ($matching.Count -ne 1) { throw 'phase3b2_epinel_minimal_start_firewall_apply_failed' }
        $rule=$matching[0]
        $apps=@($filters | Where-Object InstanceID -CEQ $rule.InstanceID)
        if ($rule.Group -cne $group -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or $rule.Enabled -ne 'True' -or
            $apps.Count -ne 1 -or $apps[0].Program -cne $programs[$name]) {
            throw 'phase3b2_epinel_minimal_start_firewall_apply_failed'
        }
    }
}
