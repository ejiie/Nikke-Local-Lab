[CmdletBinding()]
param(
    [string]$StatusPath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\application-repair.status.txt'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repairScript = Join-Path $PSScriptRoot 'repair-nll-phase-d-control-center-application.ps1'
$statusRoot = Split-Path -Parent $StatusPath
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
try {
    & $repairScript
    [IO.File]::WriteAllText(
        $StatusPath,
        "exitCode=0`r`nreceipt=see-latest-source-free-application-repairs`r`n",
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
