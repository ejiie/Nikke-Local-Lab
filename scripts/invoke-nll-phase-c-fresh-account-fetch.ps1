#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Uid = '',
    [ValidateRange(30, 600)]
    [int]$LoginTimeoutSeconds = 120,
    [ValidateRange(1, 100)]
    [int]$BatchSize = 10,
    [switch]$Probe,
    [switch]$DiscoverCdn
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Fetch {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$envPath = Join-Path $repositoryRoot '.env'
$pythonPath =
    'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\.venv\Scripts\python.exe'
$collectorPath =
    'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\getFromBlaLink.py'
$expectedRawPath =
    'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json'
$requiredKeys = @(
    'NIKKE_BLABLA_ID',
    'NIKKE_BLABLA_PW'
)
$supportedKeys = @(
    'NIKKE_BLABLA_ID',
    'NIKKE_BLABLA_PW',
    'NIKKE_REGION'
)

Assert-Fetch (Test-Path -LiteralPath $envPath -PathType Leaf) `
    'phase_c_fresh_fetch_env_missing'
Assert-Fetch (Test-Path -LiteralPath $pythonPath -PathType Leaf) `
    'phase_c_fresh_fetch_python_missing'
Assert-Fetch (Test-Path -LiteralPath $collectorPath -PathType Leaf) `
    'phase_c_fresh_fetch_collector_missing'

$browserDryRunText = @(
    & $pythonPath -m playwright install --dry-run chromium 2>&1
) -join [Environment]::NewLine
Assert-Fetch ($LASTEXITCODE -eq 0) `
    'phase_c_fresh_fetch_browser_probe_failed'
$browserInstallMatch = [regex]::Match(
    $browserDryRunText,
    '(?s)Chrome for Testing.*?Install location:\s*([^\r\n]+)')
Assert-Fetch ($browserInstallMatch.Success) `
    'phase_c_fresh_fetch_browser_path_unresolved'
$browserInstallRoot = $browserInstallMatch.Groups[1].Value.Trim()
$browserExecutable = Join-Path $browserInstallRoot 'chrome-win64\chrome.exe'
if (-not (Test-Path -LiteralPath $browserExecutable -PathType Leaf)) {
    Write-Host 'Installing the required Playwright Chromium runtime...'
    & $pythonPath -m playwright install chromium | Out-Host
    Assert-Fetch ($LASTEXITCODE -eq 0) `
        'phase_c_fresh_fetch_browser_install_failed'
}
Assert-Fetch (Test-Path -LiteralPath $browserExecutable -PathType Leaf) `
    'phase_c_fresh_fetch_browser_executable_missing_after_install'

if ([string]::IsNullOrWhiteSpace($Uid)) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $Uid = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Fetch할 NIKKE UID를 입력하십시오.',
        'NLL Phase C Account Fetch',
        '')
}
Assert-Fetch (-not [string]::IsNullOrWhiteSpace($Uid)) `
    'phase_c_fresh_fetch_uid_required'
Assert-Fetch ($Uid -match '^\d+$') `
    'phase_c_fresh_fetch_uid_invalid'

$git = Get-Command git -CommandType Application -ErrorAction Stop
$trackedEnv = @(& $git.Source -C $repositoryRoot ls-files -- .env)
Assert-Fetch ($LASTEXITCODE -eq 0 -and $trackedEnv.Count -eq 0) `
    'phase_c_fresh_fetch_env_must_not_be_tracked'
& $git.Source -C $repositoryRoot check-ignore -q -- .env
Assert-Fetch ($LASTEXITCODE -eq 0) `
    'phase_c_fresh_fetch_env_must_be_ignored'

$loaded = [ordered]@{}
foreach ($rawLine in [IO.File]::ReadLines($envPath)) {
    $line = $rawLine.Trim()
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        continue
    }
    $separator = $line.IndexOf('=')
    if ($separator -lt 1) { continue }
    $name = $line.Substring(0, $separator).Trim()
    if ($supportedKeys -notcontains $name) { continue }
    Assert-Fetch (-not $loaded.Contains($name)) `
        ('phase_c_fresh_fetch_env_duplicate_key:' + $name)
    $value = $line.Substring($separator + 1).Trim()
    if ($value.Length -ge 2 -and
        (($value.StartsWith('"') -and $value.EndsWith('"')) -or
         ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    $loaded[$name] = $value
}

$missingKeys = @(
    $requiredKeys |
        Where-Object {
            -not $loaded.Contains($_) -or
            [string]::IsNullOrWhiteSpace([string]$loaded[$_])
        }
)
Assert-Fetch ($missingKeys.Count -eq 0) `
    ('phase_c_fresh_fetch_env_fields_missing:' + ($missingKeys -join ','))
if (-not $loaded.Contains('NIKKE_REGION') -or
    [string]::IsNullOrWhiteSpace([string]$loaded['NIKKE_REGION'])) {
    $loaded['NIKKE_REGION'] = 'JP/KR/NA/SEA/Global'
}

$priorEnvironment = @{}
foreach ($name in $supportedKeys) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        [EnvironmentVariableTarget]::Process)
}

$startedAtUtc = [DateTime]::UtcNow
$arguments = @(
    $collectorPath,
    $Uid,
    '--login-timeout',
    [string]$LoginTimeoutSeconds,
    '--batch-size',
    [string]$BatchSize
)
if ($Probe) { $arguments += '--probe' }
if ($DiscoverCdn) { $arguments += '--discover-cdn' }

$collectorExitCode = $null
try {
    foreach ($name in $supportedKeys) {
        [Environment]::SetEnvironmentVariable(
            $name,
            [string]$loaded[$name],
            [EnvironmentVariableTarget]::Process)
    }
    & $pythonPath @arguments
    $collectorExitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $supportedKeys) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $priorEnvironment[$name],
            [EnvironmentVariableTarget]::Process)
    }
}

Assert-Fetch ($collectorExitCode -eq 0) `
    ('phase_c_fresh_fetch_collector_failed:' + $collectorExitCode)
Assert-Fetch (Test-Path -LiteralPath $expectedRawPath -PathType Leaf) `
    'phase_c_fresh_fetch_output_missing'
$rawItem = Get-Item -LiteralPath $expectedRawPath
Assert-Fetch ($rawItem.Length -gt 0 -and
    $rawItem.LastWriteTimeUtc -ge $startedAtUtc) `
    'phase_c_fresh_fetch_output_not_fresh'

$null = [IO.File]::ReadAllText($expectedRawPath) | ConvertFrom-Json
[pscustomobject]@{
    schemaVersion = 1
    contractId = 'nll/phase-c-fresh-account-fetch-result/v1'
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    rawFetchPath = $expectedRawPath
    rawFetchByteLength = [long]$rawItem.Length
    rawFetchSha256 = (Get-FileHash -LiteralPath $expectedRawPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()
    uidAcceptedFromRuntimeInput = $true
    uidPersistedByLauncher = $false
    credentialsPersistedByLauncher = $false
    nextStepCode = 'refresh_matching_trigger_then_run_same_capture_gate'
} | ConvertTo-Json -Depth 4
