[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '(?i)^(chatgpt|codex|codex-code-mode-host|codex-command-runner.*)$'
})
if ($running.Count -gt 0) {
    throw 'samsung_to_micron_launcher_codex_process_still_running'
}

$finalizer = Join-Path $PSScriptRoot 'finalize-samsung-project-state-to-micron.ps1'
if (-not (Test-Path -LiteralPath $finalizer -PathType Leaf)) {
    throw 'samsung_to_micron_launcher_finalizer_missing'
}
$materializerPreflight = Join-Path $PSScriptRoot 'materialize-samsung-project-state-on-micron.ps1'
if (-not (Test-Path -LiteralPath $materializerPreflight -PathType Leaf)) {
    throw 'samsung_to_micron_launcher_materializer_preflight_missing'
}

$pwshCandidates = @(
    @(
        Get-Command pwsh.exe -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source }
        'C:\Users\zih44\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'
    ) |
        Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -Unique
)
if ($pwshCandidates.Count -eq 0) {
    throw 'samsung_to_micron_launcher_powershell7_missing'
}
$pwsh = $pwshCandidates[0]
$logPath = 'C:\Windows\Temp\NLL-Samsung-To-Micron-Finalize.log.txt'
$payload = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$finalizer' *>&1 | Tee-Object -FilePath '$logPath'
    & '$materializerPreflight' -PreflightOnly -TargetSystemDrive 'E:' *>&1 |
        Tee-Object -FilePath '$logPath' -Append
    Write-Host ''
    Write-Host 'FINAL DELTA AND OFFLINE MICRON PREFLIGHT COMPLETED. Boot Micron and run the materializer launcher.' -ForegroundColor Green
}
catch {
    `$_ | Format-List * -Force
    Write-Host ''
    Write-Host 'FINALIZATION OR MICRON PREFLIGHT FAILED. Do not delete Samsung sources.' -ForegroundColor Red
}
Read-Host 'Press Enter to close'
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
) | Out-Null
