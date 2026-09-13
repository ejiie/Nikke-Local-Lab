$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Execute only synthetic scripts in a unique temporary root. No UAC, game,
# private input, service, driver, network, registry or installed-app access.
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-diagnostic-test-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($root)
$source = Join-Path $PSScriptRoot '../src/NikkeLocalLab.Admin.Api/UserValidationDiagnostics.ps1'
$shell = (Get-Process -Id $PID).Path
$script:checks = 0
function Check([bool]$Condition) { if (-not $Condition) { throw ('diagnostic_assertion_' + $script:checks) }; $script:checks++ }
function Case([string]$Name, [string]$Body, [string]$Mutation = '') {
    $dir = Join-Path $root $Name
    $null = [IO.Directory]::CreateDirectory($dir)
    $runner = Join-Path $dir 'diagnostic-runner.ps1'
    Copy-Item -LiteralPath $source -Destination $runner
    $controller = Join-Path $dir 'invoke-nll-user-validation.ps1'
    [IO.File]::WriteAllText($controller, 'param($EntryPath,$EntrySha256,$Mode)' + [Environment]::NewLine + $Body)
    $entry = Join-Path $dir 'entry.private.json'
    [IO.File]::WriteAllText($entry, (@{ contractId = 'nll/user-validation-entry/v1'; controller = @{
        path = $controller; sha256 = (Get-FileHash -LiteralPath $controller).Hash.ToLowerInvariant()
    } } | ConvertTo-Json))
    $sha = (Get-FileHash -LiteralPath $entry).Hash.ToLowerInvariant()
    if ($Mutation -eq 'controller') { [IO.File]::AppendAllText($controller, '# drift') }
    if ($Mutation -eq 'entry') { $sha = 'a' * 64 }
    if ($Mutation -eq 'logger') { [IO.File]::WriteAllText((Join-Path $dir 'diagnostic.started.json'), 'keep') }
    & $shell -NoProfile -NonInteractive -File $runner -ControllerPath $controller -EntryPath $entry -EntrySha256 $sha -Mode Start 2>&1 | Out-Null
    $code = $LASTEXITCODE
    if ($Mutation -eq 'logger') {
        Check ($code -ne 0)
        Check (-not (Test-Path -LiteralPath (Join-Path $dir 'synthetic.invoked')))
        Check (([IO.File]::ReadAllText((Join-Path $dir 'diagnostic.started.json'))) -ceq 'keep')
        return
    }
    Check (Test-Path -LiteralPath (Join-Path $dir 'diagnostic.started.json'))
    Check (-not (Test-Path -LiteralPath (Join-Path $dir 'execution.started.json')))
    $text = [IO.File]::ReadAllText((Join-Path $dir 'controller-diagnostic.json'))
    Check (-not $text.Contains('SYNTHETIC_SECRET_MUST_NOT_APPEAR'))
    Check (-not $text.Contains($root))
    $value = $text | ConvertFrom-Json
    Check ($value.exitCode -eq $code -and -not $value.actualGameAcceptanceClaimed)
    [pscustomobject]@{ value = $value; text = $text; code = $code }
}
try {
    $value = Case 'early-throw' "throw [UnauthorizedAccessException]::new('SYNTHETIC_SECRET_MUST_NOT_APPEAR')"
    Check ($value.code -eq 1 -and $value.value.stage -ceq 'controller_invocation')
    Check ($value.text.Contains('System.UnauthorizedAccessException'))
    Check ($value.value.terminalError.frames.Count -gt 0)
    $value = Case 'reduced-error' "try { throw [ComponentModel.Win32Exception]::new(5, 'SYNTHETIC_SECRET_MUST_NOT_APPEAR') } catch { }; throw 'uv_execution_failed'"
    Check ($value.code -eq 1)
    Check ($value.text.Contains('uv_execution_failed') -and $value.text.Contains('System.ComponentModel.Win32Exception'))
    Check (@($value.value.recentErrorsNewestFirst.exceptions | Where-Object nativeErrorCode -eq 5).Count -gt 0)
    $value = Case 'cleanup-error' "try { throw [UnauthorizedAccessException]::new('SYNTHETIC_SECRET_MUST_NOT_APPEAR') } finally { throw 'uv_cleanup_unproven' }"
    Check ($value.text.Contains('uv_cleanup_unproven') -and $value.text.Contains('System.UnauthorizedAccessException'))
    $value = Case 'parser-error' 'if ('
    Check ($value.code -eq 1 -and $value.text.Contains('ParseException'))
    $value = Case 'success' '# no-op synthetic controller'
    Check ($value.code -eq 0 -and $null -eq $value.value.terminalError -and $value.value.statusCode -ceq 'controller_returned')
    foreach ($mutation in @('controller','entry')) {
        $value = Case ('drift-' + $mutation) "throw 'uv_must_not_execute'" $mutation
        Check ($value.code -eq 1 -and $value.value.stage -ceq 'controller_binding')
        Check (-not $value.text.Contains('uv_must_not_execute'))
    }
    Case 'logger-unwritable' '[IO.File]::WriteAllText((Join-Path $PSScriptRoot "synthetic.invoked"), "bad")' 'logger'
    Write-Output ('User validation diagnostic synthetic checks passed: ' + $script:checks)
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()) + 'nll-diagnostic-test-', [StringComparison]::Ordinal)) { throw 'diagnostic_cleanup_scope_invalid' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
