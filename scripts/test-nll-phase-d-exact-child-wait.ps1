[CmdletBinding()]
param([string]$RepositoryRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'Nll.PhaseDChildProcess.ps1')
function Assert-Smoke([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
# Ensure both consumers import the helper whose actual behavior is tested below.
foreach ($name in @('invoke-nll-phase-d-execution.ps1', 'watch-nll-phase-d-execution.ps1')) {
    $body = [IO.File]::ReadAllText((Join-Path $RepositoryRoot ('scripts\' + $name)))
    Assert-Smoke ($body.Contains(". (Join-Path "+'$PSScriptRoot'+" 'Nll.PhaseDChildProcess.ps1')")) 'child_helper_not_imported'
    Assert-Smoke (-not $body.Contains('function Invoke-PhaseDChildScript')) 'duplicate_child_helper'
}
$runRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-exact-child-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $runRoot
$scriptPath = Join-Path $runRoot 'child test.ps1'
$stdout = Join-Path $runRoot 'child.stdout'
$stderr = Join-Path $runRoot 'child.stderr'
$release = Join-Path $runRoot 'release'
$ended = Join-Path $runRoot 'ended'
$descendantCreated = $false
try {
    foreach ($case in @('success', 'throw', 'exit')) {
        $body = switch ($case) {
            'success' { 'param([string]$Value) Write-Output $Value' }
            'throw' { "throw 'synthetic_child_failure'" }
            'exit' { 'exit 7' }
        }
        [IO.File]::WriteAllText($scriptPath, $body, [Text.UTF8Encoding]::new($false))
        $values = if ($case -eq 'success') { @{ Value = "quoted ' value & with spaces" } } else { @{} }
        $result = Invoke-PhaseDChildScript -ScriptPath $scriptPath -Arguments $values -StandardOutputPath $stdout -StandardErrorPath $stderr
        if ($case -eq 'success') {
            Assert-Smoke ($result.ExitCode -eq 0 -and $result.StandardOutput.Trim() -ceq $values.Value) 'child_arguments_or_output_changed'
        }
        elseif ($case -eq 'throw') {
            Assert-Smoke ($result.ExitCode -ne 0 -and $result.StandardError.Contains('synthetic_child_failure')) 'child_exception_hidden'
        }
        else { Assert-Smoke ($result.ExitCode -eq 7) 'child_exit_code_hidden' }
    }
    $descendant = '$deadline = [DateTime]::UtcNow.AddSeconds(20); while (-not [IO.File]::Exists(' +
        (ConvertTo-PhaseDPowerShellLiteral $release) +
        ') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }; [IO.File]::WriteAllText(' +
        (ConvertTo-PhaseDPowerShellLiteral $ended) + ", 'done')"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($descendant))
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $parent = '$child = Start-Process -FilePath ' + (ConvertTo-PhaseDPowerShellLiteral $powershell) +
        " -ArgumentList @('-NoProfile','-EncodedCommand','$encoded') -WindowStyle Hidden -PassThru; " +
        '$child.Dispose(); exit 0'
    [IO.File]::WriteAllText($scriptPath, $parent, [Text.UTF8Encoding]::new($false))
    $descendantCreated = $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-PhaseDChildScript -ScriptPath $scriptPath -Arguments @{} -StandardOutputPath $stdout -StandardErrorPath $stderr
    Assert-Smoke ($result.ExitCode -eq 0) 'exact_child_failed'
    Assert-Smoke ($timer.Elapsed.TotalSeconds -lt 8) 'waited_for_descendant'
    Assert-Smoke (-not [IO.File]::Exists($ended)) 'descendant_ended_before_parent_return'
}
finally {
    [IO.File]::WriteAllText($release, 'release')
    if ($descendantCreated) {
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while (-not [IO.File]::Exists($ended) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    }
    if (-not $descendantCreated -or [IO.File]::Exists($ended)) {
        $resolved = (Resolve-Path -LiteralPath $runRoot).ProviderPath
        if ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\') -ine ([IO.Path]::GetTempPath()).TrimEnd('\') -or
            [IO.Path]::GetFileName($resolved) -notlike 'nll-exact-child-*') { throw 'unsafe_test_cleanup' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    else { throw 'synthetic_descendant_cleanup_unproven' }
}
'Phase D child invocation: arguments/output, exception, explicit exit and live descendant cases passed.'
