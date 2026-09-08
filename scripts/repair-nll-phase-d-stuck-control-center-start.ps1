[CmdletBinding()]
param([int[]]$StuckPowerShellProcessId = @())

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or
    $env:USERNAME -cne 'nlloperator' -or $env:SystemDrive -cne 'C:') {
    throw 'phase_d_stuck_start_repair_boundary_invalid'
}

$dataRoot = 'C:\NLL\ControlCenter\postgresql\data'
$pgCtl = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
if (Test-Path -LiteralPath (Join-Path $dataRoot 'postmaster.pid')) {
    & $pgCtl stop -D $dataRoot -m fast -w -t 60
    if ($LASTEXITCODE -ne 0) { throw 'phase_d_stuck_start_postgresql_stop_failed' }
}

foreach ($processId in $StuckPowerShellProcessId) {
    if ($processId -gt 0 -and $processId -ne $PID) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}
Get-CimInstance Win32_Process -Filter "Name='dotnet.exe'" |
    Where-Object { $_.CommandLine -like '*NikkeLocalLab.Admin.Api*' } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
Start-Sleep -Seconds 1

& (Join-Path $PSScriptRoot 'repair-nll-phase-d-control-center-application.ps1')
