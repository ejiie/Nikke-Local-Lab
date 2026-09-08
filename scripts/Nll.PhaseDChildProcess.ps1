# Shared exact-child invocation; importing this file has no side effects.
function ConvertTo-PhaseDPowerShellLiteral {
    param([string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-PhaseDChildScript {
    param(
        [string]$ScriptPath,
        [Collections.IDictionary]$Arguments,
        [string]$StandardOutputPath,
        [string]$StandardErrorPath
    )
    $commandParts = @('& ' + (ConvertTo-PhaseDPowerShellLiteral $ScriptPath))
    foreach ($key in $Arguments.Keys) {
        $commandParts += ('-' + [string]$key)
        $commandParts += ConvertTo-PhaseDPowerShellLiteral ([string]$Arguments[$key])
    }
    $stdoutLiteral = ConvertTo-PhaseDPowerShellLiteral $StandardOutputPath
    $stderrLiteral = ConvertTo-PhaseDPowerShellLiteral $StandardErrorPath
    # Redirect inside the exact child PowerShell process. Start-Process -Wait
    # can wait for EpinelPS/bootstrap descendants and prevent the coordinator
    # from ever creating its completion watcher.
    $childCommand = (
        '$ErrorActionPreference = ''Stop''; $LASTEXITCODE = 0; try { ' +
        ($commandParts -join ' ') +
        ' 1> ' + $stdoutLiteral + ' 2> ' + $stderrLiteral +
        '; exit $LASTEXITCODE } catch { [IO.File]::AppendAllText(' + $stderrLiteral +
        ', ($_ | Out-String), [Text.UTF8Encoding]::new($false)); exit 1 }')
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childCommand))
    $powershell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $process = Start-Process -FilePath $powershell `
        -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encodedCommand) `
        -WindowStyle Hidden -PassThru
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    [pscustomobject]@{
        ExitCode = $exitCode
        StandardOutput = if (Test-Path -LiteralPath $StandardOutputPath) {
            [IO.File]::ReadAllText($StandardOutputPath, [Text.Encoding]::UTF8)
        } else { '' }
        StandardError = if (Test-Path -LiteralPath $StandardErrorPath) {
            [IO.File]::ReadAllText($StandardErrorPath, [Text.Encoding]::UTF8)
        } else { '' }
    }
}
