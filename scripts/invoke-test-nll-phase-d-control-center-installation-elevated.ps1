[CmdletBinding()]
param(
    [string]$StatusPath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\installation-smoke.status.txt'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$smokeScript = Join-Path $PSScriptRoot 'test-nll-phase-d-control-center-installation.ps1'
$statusRoot = Split-Path -Parent $StatusPath
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
try {
    # Capturing pg_ctl in a PowerShell pipeline can leave the wrapper waiting
    # on a handle inherited by postgres. Run the smoke directly instead.
    & $smokeScript
    [IO.File]::WriteAllText(
        $StatusPath,
        "exitCode=0`r`n",
        (New-Object Text.UTF8Encoding($false)))
    exit 0
}
catch {
    $message = $_ | Out-String
    [IO.File]::WriteAllText(
        $StatusPath,
        "exitCode=1`r`n$message",
        (New-Object Text.UTF8Encoding($false)))
    exit 1
}
