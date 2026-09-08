# Source-free offline test. Get-Process is replaced with synthetic objects;
# no real process is started, stopped, waited on, or inspected.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$script:kills = 0
$script:waits = 0
$script:fake = $null
$script:fakeById = $null
function Get-Process {
    param($Id, $ErrorAction)
    if ($null -ne $script:fakeById) { return $script:fakeById[[int]$Id] }
    $script:fake
}
function Open-PhaseDProcess {
    param([int]$Id, [switch]$ForTermination)
    Get-Process -Id $Id
}
function New-FakeProcess {
    param([string]$Path = 'C:\synthetic\runtime.exe', [int]$Seconds = 0)
    $item = [pscustomobject]@{
        Handle = 42; Path = $Path; HasExited = $false
        StartTime = [DateTime]::Parse('2026-09-06T01:00:00Z').ToUniversalTime().AddSeconds($Seconds)
    }
    $item | Add-Member NoteProperty Disposed $false
    $item | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
    $item | Add-Member ScriptMethod get_Path { $this.Path }
    $item | Add-Member ScriptMethod Kill { $script:kills++ }
    $item | Add-Member ScriptMethod WaitForExit { param($Milliseconds) $script:waits++; return $true }
    $item
}
function Assert-Test([bool]$Value, [string]$Code) { if (-not $Value) { throw $Code } }
function Assert-IdentityRejected([scriptblock]$Action) {
    $before = $script:kills
    $rejected = $false
    try { & $Action } catch {
        if ($_.Exception.Message -notlike 'phase_d_process_identity_*') { throw }
        $rejected = $true
    }
    Assert-Test $rejected 'expected_identity_rejection'
    Assert-Test ($script:kills -eq $before) 'mismatch_killed_a_process'
}
$identity = [pscustomobject]@{
    processId = 123
    processStartedAtUtc = '2026-09-06T01:00:00.0000000Z'
    executablePath = 'C:\synthetic\runtime.exe'
}
$script:fake = New-FakeProcess
Stop-PhaseDVerifiedProcess $identity
Assert-Test ($script:kills -eq 1 -and $script:waits -eq 1) 'exact_process_not_stopped'
$script:fake = New-FakeProcess -Seconds 1
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $identity }
$script:fake = New-FakeProcess -Path 'C:\different\runtime.exe'
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $identity }
$identity.processStartedAtUtc = ''
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $identity }
$identity.processStartedAtUtc = '2026-09-06T01:00:00.0000000Z'
$script:fake = $null
Stop-PhaseDVerifiedProcess $identity
Assert-Test ($script:kills -eq 1) 'absent_process_was_stopped'
$absent = New-PhaseDProcessIdentity -Id 123 -ExecutablePath 'C:\synthetic\runtime.exe' `
    -NotBeforeUtc ([DateTime]::MinValue) -NotAfterUtc ([DateTime]::MaxValue)
Stop-PhaseDVerifiedProcess $absent
$script:fake = New-FakeProcess
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $absent }
$pin = New-PhaseDProcessIdentity -Id 123 -ExecutablePath 'C:\synthetic\runtime.exe' `
    -NotBeforeUtc ([DateTime]::Parse('2026-09-06T00:59:59Z')) `
    -NotAfterUtc ([DateTime]::Parse('2026-09-06T01:00:01Z'))
Assert-Test ($pin.processId -eq 123) 'pin_not_created'
Assert-IdentityRejected {
    New-PhaseDProcessIdentity -Id 123 -ExecutablePath 'C:\synthetic\runtime.exe' `
        -NotBeforeUtc ([DateTime]::Parse('2026-09-06T01:00:01Z')) `
        -NotAfterUtc ([DateTime]::MaxValue)
}
Assert-IdentityRejected {
    New-PhaseDProcessIdentity -Id 123 -ExecutablePath 'C:\synthetic\runtime.exe' `
        -NotBeforeUtc ([DateTime]::MinValue) `
        -NotAfterUtc ([DateTime]::Parse('2026-09-06T00:59:59Z'))
}
$pointer = [pscustomobject]@{ clientProcessId = 123; bootstrapProcessId = 124; serverProcessId = 125 }
$identities = [pscustomobject]@{
    client = $identity
    bootstrap = [pscustomobject]@{ processId = 124; processStartedAtUtc = $identity.processStartedAtUtc; executablePath = $identity.executablePath }
    server = [pscustomobject]@{ processId = 125; processStartedAtUtc = $identity.processStartedAtUtc; executablePath = $identity.executablePath }
}
$script:fakeById = @{ 123 = (New-FakeProcess); 124 = (New-FakeProcess); 125 = (New-FakeProcess -Seconds 1) }
Assert-IdentityRejected { Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $identities }
Assert-IdentityRejected { Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $null }
$identities.server.processId = 124
Assert-IdentityRejected { Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $identities }
$identities.server.processId = 125
$script:fakeById[125] = New-FakeProcess
$beforeSetKills = $script:kills
Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $identities
Assert-Test ($script:kills -eq $beforeSetKills + 3) 'verified_set_not_stopped'
$script:fakeById = $null
# An exited object retained by another handle must not require an image path.
$beforeExitKills = $script:kills
$script:fake = New-FakeProcess -Path ''
$script:fake.HasExited = $true
$script:fake | Add-Member ScriptMethod get_Path { throw 'exited_path_must_not_be_read' } -Force
Stop-PhaseDVerifiedProcess $identity
Assert-Test ($script:fake.Disposed -and $script:kills -eq $beforeExitKills) 'exited_handle_not_disposed_or_killed'
# Exit racing with a throwing getter is also a no-op on this same verified handle.
$script:fake = New-FakeProcess
$script:fake | Add-Member ScriptMethod get_Path { $this.HasExited = $true; throw [ComponentModel.Win32Exception]::new(31) } -Force
Stop-PhaseDVerifiedProcess $identity
Assert-Test ($script:fake.Disposed -and $script:kills -eq $beforeExitKills) 'exit_during_path_query_failed'
# An empty path returned during exit is handled, too.
$script:fake = New-FakeProcess
$script:fake | Add-Member ScriptMethod get_Path { $this.HasExited = $true; return '' } -Force
Stop-PhaseDVerifiedProcess $identity
Assert-Test ($script:fake.Disposed -and $script:kills -eq $beforeExitKills) 'exit_with_empty_path_failed'
# The same native error while LIVE must remain a failure, with its native code.
$script:fake = New-FakeProcess
$script:fake | Add-Member ScriptMethod get_Path { throw [ComponentModel.Win32Exception]::new(5) } -Force
$nativeCode = $null
try { Stop-PhaseDVerifiedProcess $identity } catch {
    for ($inner = $_.Exception; $null -ne $inner; $inner = $inner.InnerException) {
        if ($inner -is [ComponentModel.Win32Exception]) { $nativeCode = $inner.NativeErrorCode }
    }
}
Assert-Test ($nativeCode -eq 5 -and $script:fake.Disposed -and $script:kills -eq $beforeExitKills) 'live_query_failure_hidden'
$script:fake = New-FakeProcess -Path ''
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $identity }
Assert-Test $script:fake.Disposed 'live_empty_path_handle_leaked'
$script:fake = New-FakeProcess -Seconds 1
$script:fake.HasExited = $true
Assert-IdentityRejected { Stop-PhaseDVerifiedProcess $identity }
$script:fakeById = @{ 123 = (New-FakeProcess -Path ''); 124 = $null; 125 = (New-FakeProcess) }
$script:fakeById[123].HasExited = $true
Stop-PhaseDVerifiedProcessSet -Pointer $pointer -Identities $identities
Assert-Test ($script:kills -eq $beforeExitKills + 1 -and $script:fakeById[123].Disposed) 'mixed_exited_live_set_failed'
$script:fakeById = $null
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-state-handoff-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $script:transitions = 0
    foreach ($status in @('completed', 'rolled_back', 'failed', 'started')) {
        [IO.File]::WriteAllText((Join-Path $testRoot 'execution-state.json'),
            ('{"statusCode":"' + $status + '"}'))
        Invoke-PhaseDStartedTransition -LaunchRoot $testRoot -Action { $script:transitions++ }
        Assert-Test ($script:transitions -eq 0) 'late_start_overwrote_watcher_state'
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'execution-state.json'), '{"statusCode":"validated"}')
    Invoke-PhaseDStartedTransition -LaunchRoot $testRoot -Action { $script:transitions++ }
    Assert-Test ($script:transitions -eq 1) 'validated_start_not_applied'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -cne ([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'nll-state-handoff-*') { throw 'unsafe_test_cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'Phase D lifecycle: 14 identity, 7 exit/race and 5 handoff cases passed; no real process operations.'
