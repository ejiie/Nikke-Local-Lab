[CmdletBinding()]
param(
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$DotnetPath = 'dotnet',
    [ValidateRange(1024, 65535)]
    [int]$Port = 55434,
    [string]$TestName =
        'NikkeLocalLab.PostgreSql.IntegrationTests.PostgreSqlLocalGameStateTests.AggregateWorkspaceSaveSurvivesLobbyRevalidationAndReplaysExactly'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testProject = Join-Path $repositoryRoot 'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$pgCtl = Join-Path $PostgreSqlRoot 'bin\pg_ctl.exe'
$initDb = Join-Path $PostgreSqlRoot 'bin\initdb.exe'
$createdb = Join-Path $PostgreSqlRoot 'bin\createdb.exe'
$dropdb = Join-Path $PostgreSqlRoot 'bin\dropdb.exe'
foreach ($path in @($pgCtl, $initDb, $createdb, $dropdb, $testProject)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'account_workspace_save_live_input_missing'
    }
}

$dotnetCommand = Get-Command $DotnetPath -ErrorAction Stop
$workRoot = Join-Path $env:TEMP ('NLL-WorkspaceSave-' + [guid]::NewGuid().ToString('D'))
$resolvedTemp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedWork = [IO.Path]::GetFullPath($workRoot)
if (-not $resolvedWork.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'account_workspace_save_live_temp_root_invalid'
}

$dataRoot = Join-Path $workRoot 'data'
$logPath = Join-Path $workRoot 'postgres.log'
$databaseName = 'nikke_local_lab_workspace_save_test'
$databaseUser = 'nll_workspace_save'
$started = $false
$databaseCreated = $false
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    & $initDb '-D' $dataRoot '--username' $databaseUser '--auth-host' 'trust' `
        '--auth-local' 'trust' '--encoding' 'UTF8' '--locale' 'C' '--no-instructions' | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'account_workspace_save_live_initdb_failed' }
    [IO.File]::AppendAllText(
        (Join-Path $dataRoot 'postgresql.conf'),
        "`nlisten_addresses = '127.0.0.1'`nport = $Port`nmax_connections = 20`n",
        [Text.UTF8Encoding]::new($false))
    & $pgCtl 'start' '-D' $dataRoot '-l' $logPath '-w' '-t' '60'
    if ($LASTEXITCODE -ne 0) { throw 'account_workspace_save_live_start_failed' }
    $started = $true
    & $createdb '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--maintenance-db' 'postgres' $databaseName
    if ($LASTEXITCODE -ne 0) { throw 'account_workspace_save_live_createdb_failed' }
    $databaseCreated = $true

    $env:NIKKE_LAB_TEST_DB = "Host=127.0.0.1;Port=$Port;Database=$databaseName;Username=$databaseUser;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $databaseName
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    & $dotnetCommand.Source test $testProject '--no-restore' '--nologo' `
        '--filter' "FullyQualifiedName=$TestName"
    if ($LASTEXITCODE -ne 0) { throw 'account_workspace_save_live_test_failed' }
}
finally {
    $env:NIKKE_LAB_TEST_DB = $null
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $null
    $env:NIKKE_LAB_TEST_RESET_TOKEN = $null
    if ($databaseCreated) {
        & $dropdb '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
            '--maintenance-db' 'postgres' '--force' $databaseName 2>$null
    }
    if ($started) {
        & $pgCtl 'stop' '-D' $dataRoot '-m' 'fast' '-w' '-t' '60'
    }
    if (Test-Path -LiteralPath $resolvedWork) {
        $verifiedWork = [IO.Path]::GetFullPath($resolvedWork)
        if (-not $verifiedWork.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'account_workspace_save_live_cleanup_target_invalid'
        }
        Remove-Item -LiteralPath $verifiedWork -Recurse -Force
    }
}
