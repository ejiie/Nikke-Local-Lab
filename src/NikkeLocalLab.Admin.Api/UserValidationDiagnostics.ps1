[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ControllerPath,
    [Parameter(Mandatory)][string]$EntryPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$EntrySha256,
    [Parameter(Mandatory)][ValidateSet('Start','Recover')][string]$Mode
)
# Embedded in the installed API; written once into this user action directory.
# Invoke the sealed controller in its own script scope, without modifying its
# bytes, cleanup behavior, entry binding, or execution/acceptance markers.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-UvdJson([string]$Name, $Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12))
    $stream = [IO.FileStream]::new((Join-Path $PSScriptRoot $Name), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Get-UvdError($Record) {
    # Never serialize ErrorRecord, target objects, source lines, raw messages or
    # invocation arguments: those can contain original game IDs or credentials.
    $chain = @()
    $exception = $Record.Exception
    for ($depth = 0; $null -ne $exception -and $depth -lt 8; $depth++) {
        $messageBytes = [Text.Encoding]::UTF8.GetBytes([string]$exception.Message)
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($messageBytes)).ToLowerInvariant()
        $code = $null
        if ($exception.Message -cmatch '^(uv_|uvd_|resource_native_)[a-z_]{1,120}$') { $code = $exception.Message }
        $chain += [ordered]@{
            exceptionType = $exception.GetType().FullName; hResult = $exception.HResult
            nativeErrorCode = $(if ($exception -is [ComponentModel.Win32Exception]) { $exception.NativeErrorCode } else { $null })
            failureCode = $code; messageSha256 = $digest
        }
        $exception = $exception.InnerException
    }
    $frames = @()
    foreach ($frame in ([string]$Record.ScriptStackTrace -split '\r?\n')) {
        # Only this project's known script basenames and numeric locations.
        if ($frame -match '(?<file>(?:Nll\.[A-Za-z]+|invoke-nll-user-validation|UserValidationDiagnostics|diagnostic-runner)\.ps1):\s*(?:line\s+)?(?<line>\d+)\s*$') {
            $frames += [ordered]@{ script = $Matches.file; line = [int]$Matches.line }
        }
        if ($frames.Count -ge 16) { break }
    }
    [ordered]@{ category = [string]$Record.CategoryInfo.Category; frames = $frames; exceptions = $chain }
}
$uvdStage = 'logger_started'
$uvdTerminal = $null
$uvdExit = 0
# This durable marker is required BEFORE any controller preflight. If writing
# diagnostics is impossible, fail closed without starting the controller.
Write-UvdJson 'diagnostic.started.json' ([ordered]@{
    contractId = 'nll/user-validation-controller-diagnostic/v1'; stage = $uvdStage
    startedAtUtc = [DateTimeOffset]::UtcNow; processId = $PID; entrySha256 = $EntrySha256
    mode = $Mode; actualGameAcceptanceClaimed = $false
})
try {
    $uvdStage = 'controller_binding'
    if ((Get-FileHash -LiteralPath $EntryPath).Hash.ToLowerInvariant() -cne $EntrySha256) { throw 'uvd_entry_drift' }
    $uvdEntry = Get-Content -LiteralPath $EntryPath -Raw | ConvertFrom-Json
    if ($uvdEntry.contractId -cne 'nll/user-validation-entry/v1' -or
        $uvdEntry.controller.path -cne $ControllerPath -or
        (Get-FileHash -LiteralPath $ControllerPath).Hash.ToLowerInvariant() -cne $uvdEntry.controller.sha256) { throw 'uvd_controller_drift' }
    $uvdStage = 'controller_invocation'
    $Error.Clear()
    $uvdArguments=@{EntryPath=$EntryPath;EntrySha256=$EntrySha256;Mode=$Mode}
    # Old sealed entries retain their original invocation contract.
    if('preflightContractId' -cin @($uvdEntry.PSObject.Properties.Name)){
        if($uvdEntry.preflightContractId -cne 'nll/user-validation-preflight/v1'){throw 'uvd_preflight_contract_invalid'}
        $uvdArguments.DiagnosticRoot=$PSScriptRoot
    }
    & $ControllerPath @uvdArguments
} catch {
    $uvdTerminal = $_
    $uvdExit = 1
} finally {
    # Snapshot before any diagnostic work; caught/rethrown controller exceptions
    # remain in PowerShell's error history, including pre-claim failures which
    # the old controller reduces to uv_execution_failed. History is evidence,
    # not a claim that every handled error caused the failure.
    $uvdHistory = @($Error | Select-Object -First 256)
    $uvdRecords = @($uvdHistory | ForEach-Object { Get-UvdError $_ })
    Write-UvdJson 'controller-diagnostic.json' ([ordered]@{
        contractId = 'nll/user-validation-controller-diagnostic/v1'; stage = $uvdStage
        completedAtUtc = [DateTimeOffset]::UtcNow; entrySha256 = $EntrySha256; mode = $Mode
        exitCode = $uvdExit; statusCode = $(if ($uvdExit -eq 0) { 'controller_returned' } else { 'controller_failed' })
        terminalError = $(if ($null -ne $uvdTerminal) { Get-UvdError $uvdTerminal } else { $null })
        recentErrorsNewestFirst = $uvdRecords; errorHistoryLimit = 256
        actualGameAcceptanceClaimed = $false
    })
}
exit $uvdExit
