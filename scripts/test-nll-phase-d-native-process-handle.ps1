# Real OS handle check, restricted to this test and one test-created PowerShell child.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$self = Get-Process -Id $PID
$selfPin = New-PhaseDProcessIdentity -Id $PID -ExecutablePath $self.Path -NotBeforeUtc ([DateTime]::MinValue) -NotAfterUtc ([DateTime]::MaxValue)
$observer = Get-PhaseDVerifiedProcess $selfPin
try {
    if ($observer.HasExited -or $observer.WaitForExit(0)) { throw 'native_self_reported_exited' }
    $stopDenied = $false
    try { $observer.Kill() } catch { $stopDenied = $_.Exception.Message.Contains('phase_d_process_stop_not_authorized') }
    if (-not $stopDenied) { throw 'read_only_handle_allowed_termination' }
} finally { $observer.Dispose(); $self.Dispose() }
$child = $null
try {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 20'))
    $child = Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $pin = New-PhaseDProcessIdentity -Id $child.Id -ExecutablePath $powershell -NotBeforeUtc ([DateTime]::UtcNow.AddMinutes(-1)) -NotAfterUtc ([DateTime]::UtcNow.AddMinutes(1))
    $waiter = Get-PhaseDVerifiedProcess $pin
    try {
        if ($waiter.WaitForExit(0)) { throw 'native_child_exited_early' }
        Stop-PhaseDVerifiedProcess $pin
        if (-not $waiter.WaitForExit(5000)) { throw 'native_wait_did_not_observe_exit' }
        # Retain the exited kernel object: OpenProcess can still succeed while
        # QueryFullProcessImageName no longer can. Both replays must be no-ops.
        Stop-PhaseDVerifiedProcess $pin
        Stop-PhaseDVerifiedProcess $pin
    } finally { $waiter.Dispose() }
} finally {
    if ($null -ne $child) {
        if (-not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(5000) }
        $child.Dispose()
    }
}
'Phase D native handles: read-only metadata/wait, forbidden observer kill, child stop and two exited-handle replays passed.'
