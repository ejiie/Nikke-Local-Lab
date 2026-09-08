# Synthetic process denies the legacy all-access Handle getter. No game/process mutations.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
$script:terminationRequested = $false
$script:kills = 0
$script:allAccessReads = 0
$script:fake = [pscustomobject]@{
    Path = 'C:\synthetic\client.exe'; HasExited = $false
    StartTime = [DateTime]::Parse('2026-09-07T01:00:00Z').ToUniversalTime()
}
$script:fake | Add-Member ScriptProperty Handle { $script:allAccessReads++; throw 'synthetic_all_access_denied' }
$script:fake | Add-Member ScriptMethod Dispose { }
$script:fake | Add-Member ScriptMethod get_Path { $this.Path }
$script:fake | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $true }
$script:fake | Add-Member ScriptMethod Kill { $script:kills++ }
function Get-Process { param($Id,$ErrorAction) $script:fake }
function Open-PhaseDProcess { param([int]$Id,[switch]$ForTermination) $script:terminationRequested = [bool]$ForTermination; $script:fake }
$pin = New-PhaseDProcessIdentity -Id 123 -ExecutablePath $script:fake.Path -NotBeforeUtc ([DateTime]::MinValue) -NotAfterUtc ([DateTime]::MaxValue)
if ($script:terminationRequested) { throw 'capture_requested_termination_rights' }
if ($script:allAccessReads -ne 0) { throw 'capture_requested_all_access' }
$observed = Get-PhaseDVerifiedProcess $pin
if ($script:terminationRequested -or -not $observed.WaitForExit(0)) { throw 'wait_requested_termination_rights' }
$observed.Dispose()
Stop-PhaseDVerifiedProcess $pin
if (-not $script:terminationRequested -or $script:kills -ne 1) { throw 'stop_did_not_request_termination_rights' }
'Phase D access rights: capture/wait tolerate denied all-access; stop explicitly requests terminate.'
