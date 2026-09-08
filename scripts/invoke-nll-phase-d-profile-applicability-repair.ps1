[CmdletBinding()]
param(
    [switch]$Elevated,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    $self = $MyInvocation.MyCommand.Path
    $command = "& '$self' -Elevated"
    if ($NoPause) { $command += ' -NoPause' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs `
            -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" `
            -Wait `
            -PassThru
        exit $process.ExitCode
    }
    catch {
        Write-Error 'phase_d_profile_applicability_repair_uac_cancelled'
        exit 1223
    }
}

if (-not $Elevated -or $env:USERNAME -cne 'nlloperator' -or $env:SystemDrive -cne 'C:') {
    throw 'phase_d_profile_applicability_repair_boundary_invalid'
}

$repair = Join-Path $PSScriptRoot 'repair-nll-phase-d-profile-applicability.ps1'
$inspection = Join-Path $PSScriptRoot 'inspect-nll-phase-d-runtime-projection-unresolved.ps1'
$statusPath = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'artifacts\phase-d\profile-applicability-repair.latest.txt'
$statusRoot = Split-Path -Parent $statusPath
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
$exitCode = 0
try {
    Write-Host 'Normalizing overload application signs...' -ForegroundColor Cyan
    # Do not pipe this invocation. pg_ctl starts PostgreSQL as a child process;
    # piping the script output can keep the inherited native stdout handle open
    # and make Windows PowerShell wait indefinitely after PostgreSQL is ready.
    & $repair -OverloadSignOnly
    Write-Host 'Inspecting the installed runtime projection...' -ForegroundColor Cyan
    & $inspection
    [IO.File]::WriteAllText(
        $statusPath,
        "exitCode=0`r`nstatus=phase_d_profile_applicability_repair_passed`r`n",
        (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Profile applicability repair and inspection completed successfully.' `
        -ForegroundColor Green
}
catch {
    $exitCode = 1
    $safePosition = [string]$_.InvocationInfo.PositionMessage
    [IO.File]::WriteAllText(
        $statusPath,
        ("exitCode=1`r`nstatus=phase_d_profile_applicability_repair_failed`r`nerror=" +
         $_.Exception.Message + "`r`nposition=" + $safePosition + "`r`n"),
        (New-Object Text.UTF8Encoding($false)))
    Write-Error $_
}

if (-not $NoPause) {
    [void](Read-Host 'Press Enter to close this result window')
}
exit $exitCode
