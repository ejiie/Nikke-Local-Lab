[CmdletBinding()]
param(
    [string]$StatusPath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\unresolved-inspection.status.txt'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$inspectionScript = Join-Path $PSScriptRoot 'inspect-nll-phase-d-runtime-projection-unresolved.ps1'
$statusRoot = Split-Path -Parent $StatusPath
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
try {
    & $inspectionScript
    [IO.File]::WriteAllText(
        $StatusPath,
        "exitCode=0`r`n",
        [Text.UTF8Encoding]::new($false))
    exit 0
}
catch {
    $safeMessage = [string]$_.Exception.Message
    $safePosition = [string]$_.InvocationInfo.PositionMessage
    [IO.File]::WriteAllText(
        $StatusPath,
        "exitCode=1`r`nmessage=$safeMessage`r`nposition=$safePosition`r`n",
        [Text.UTF8Encoding]::new($false))
    exit 1
}
