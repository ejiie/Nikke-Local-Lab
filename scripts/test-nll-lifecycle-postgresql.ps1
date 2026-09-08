[CmdletBinding()]
param(
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$Filter = '',
    [ValidateRange(1, 60)][int]$ShutdownTimeoutSeconds = 30
)

# Offline, synthetic data only. Never reuse Control Center's data directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$port = 55432
$database = 'nikke_local_lab_lifecycle_test'
$databaseUser = 'nll_lifecycle_test'
$postgres = Join-Path $PostgreSqlRoot 'bin\postgres.exe'
$pgCtl = Join-Path $PostgreSqlRoot 'bin\pg_ctl.exe'
$initDb = Join-Path $PostgreSqlRoot 'bin\initdb.exe'
$createDb = Join-Path $PostgreSqlRoot 'bin\createdb.exe'
$psql = Join-Path $PostgreSqlRoot 'bin\psql.exe'
$dotnet = (Get-Command dotnet -ErrorAction Stop).Source

function Test-LifecycleListener {
    $client = [Net.Sockets.TcpClient]::new()
    try { return $client.ConnectAsync('127.0.0.1', $port).Wait(1000) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}

if ((Get-FileHash -LiteralPath $postgres -Algorithm SHA256).Hash.ToLowerInvariant() -cne
    '4125c1e963072d929f6468a449ad184b26d3be7d97cae3181c3d613dace49c8d') {
    throw 'lifecycle_test_postgresql_hash_mismatch'
}
if ((& $postgres --version) -cne 'postgres (PostgreSQL) 17.11') { throw 'lifecycle_test_postgresql_version_mismatch' }
if (@(Get-Process -Name postgres,pg_ctl,nikke,EpinelPS -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'lifecycle_test_runtime_not_cold'
}
if (Test-LifecycleListener) { throw 'lifecycle_test_port_in_use' }

$uid = [guid]::NewGuid().ToString('N')
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$workRoot = Join-Path $tempParent ('NLL-Lifecycle-Test-' + $uid)
if (-not [IO.Path]::GetFullPath($workRoot).StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'lifecycle_test_temp_path_invalid'
}
$dataRoot = Join-Path $workRoot 'data'
$passwordFile = Join-Path $workRoot 'pwfile'
$resultRoot = Join-Path $repositoryRoot ('artifacts\stabilization\lifecycle-postgresql\' + $uid)
$null = New-Item -ItemType Directory -Path $workRoot
$null = New-Item -ItemType Directory -Path $resultRoot -Force
$environmentNames = @('PGPASSWORD', 'NIKKE_LAB_TEST_DB', 'NIKKE_LAB_TEST_EXPECTED_DATABASE',
    'NIKKE_LAB_TEST_RESET_TOKEN', 'DOTNET_CLI_HOME', 'NUGET_PACKAGES', 'DOTNET_CLI_TELEMETRY_OPTOUT')
$previousEnvironment = @{}
foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$bytes = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$password = [Convert]::ToBase64String($bytes)
[Array]::Clear($bytes, 0, $bytes.Length)
$attemptedStart = $false
$cleanupVerified = $false
$restartVerified = $false
$testExitCode = -1
$stage = 'initdb'
$failureCode = $null
try {
    [IO.File]::WriteAllText($passwordFile, $password, [Text.UTF8Encoding]::new($false))
    & $initDb -D $dataRoot --username $databaseUser --pwfile $passwordFile --auth-host scram-sha-256 --auth-local trust --encoding UTF8 --locale C --no-instructions
    if ($LASTEXITCODE -ne 0) { throw 'lifecycle_test_initdb_failed' }
    Remove-Item -LiteralPath $passwordFile -Force
    [IO.File]::AppendAllText((Join-Path $dataRoot 'postgresql.conf'),
        "`nlisten_addresses = '127.0.0.1'`nport = $port`nmax_connections = 40`nshared_buffers = '64MB'`nwork_mem = '2MB'`n",
        [Text.UTF8Encoding]::new($false))
    $stage = 'start'
    $attemptedStart = $true
    # Do not pipe pg_ctl: postgres can inherit pipeline handles on Windows.
    & $pgCtl start -D $dataRoot -l (Join-Path $workRoot 'postgres.log') -w -t 30
    if ($LASTEXITCODE -ne 0 -or -not (Test-LifecycleListener)) { throw 'lifecycle_test_start_failed' }
    $stage = 'create'
    $env:PGPASSWORD = $password
    & $createDb --host 127.0.0.1 --port $port --username $databaseUser --maintenance-db postgres $database
    if ($LASTEXITCODE -ne 0) { throw 'lifecycle_test_create_failed' }
    & $psql --host 127.0.0.1 --port $port --username $databaseUser --dbname $database --no-psqlrc --set ON_ERROR_STOP=1 --command 'CREATE TABLE public.lifecycle_restart_check (value integer PRIMARY KEY); INSERT INTO public.lifecycle_restart_check VALUES (42);'
    if ($LASTEXITCODE -ne 0) { throw 'lifecycle_test_checkpoint_failed' }
    $env:NIKKE_LAB_TEST_DB = "Host=127.0.0.1;Port=$port;Database=$database;Username=$databaseUser;Password=$password;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $database
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    $env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $stage = 'test'
    $testArguments = @('test', (Join-Path $repositoryRoot 'tests\NikkeLocalLab.PostgreSql.IntegrationTests'),
        '--configuration', 'Release', '--no-restore', '--logger', 'trx;LogFileName=integration.trx',
        '--results-directory', $resultRoot, '--verbosity', 'minimal')
    if (-not [string]::IsNullOrWhiteSpace($Filter)) { $testArguments += @('--filter', $Filter) }
    & $dotnet @testArguments
    $testExitCode = $LASTEXITCODE
    $stage = 'restart'
    & $pgCtl stop -D $dataRoot -m fast -w -t $ShutdownTimeoutSeconds
    if ($LASTEXITCODE -ne 0 -or (Test-LifecycleListener)) { throw 'lifecycle_test_stop_failed' }
    & $pgCtl start -D $dataRoot -l (Join-Path $workRoot 'postgres.log') -w -t 30
    if ($LASTEXITCODE -ne 0) { throw 'lifecycle_test_restart_failed' }
    $checkpoint = @(& $psql --host 127.0.0.1 --port $port --username $databaseUser --dbname $database --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --command 'SELECT value FROM public.lifecycle_restart_check;')
    $restartVerified = $LASTEXITCODE -eq 0 -and $checkpoint.Count -eq 1 -and $checkpoint[0] -ceq '42'
    if (-not $restartVerified) { throw 'lifecycle_test_restart_checkpoint_missing' }
    if ($testExitCode -ne 0) { $stage = 'test'; throw 'lifecycle_test_assertion_failed' }
}
catch { $failureCode = 'lifecycle_test_' + $stage + '_failed' }
finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
    $password = $null
    if (Test-Path -LiteralPath $passwordFile) { Remove-Item -LiteralPath $passwordFile -Force }
    if ($attemptedStart) {
        & $pgCtl stop -D $dataRoot -m fast -w -t $ShutdownTimeoutSeconds
    }
    $cleanupVerified = @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and -not (Test-LifecycleListener)
    if ($cleanupVerified) {
        # Resolve and validate again immediately before removing OUR disposable cluster.
        $resolvedWorkRoot = (Resolve-Path -LiteralPath $workRoot).ProviderPath
        if ($resolvedWorkRoot -ine [IO.Path]::GetFullPath((Join-Path $tempParent ('NLL-Lifecycle-Test-' + $uid)))) {
            throw 'lifecycle_test_cleanup_path_mismatch'
        }
        Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force
    }
    $receipt = [ordered]@{
        schemaVersion = 1; kind = 'synthetic_postgresql_lifecycle_test/v1'
        testExitCode = $testExitCode; failureCode = $failureCode
        cleanupVerified = $cleanupVerified; port = $port
        shutdownTimeoutSeconds = $ShutdownTimeoutSeconds
        postgresqlRestartCheckpointVerified = $restartVerified
        operatingDatabaseTouched = $false; originalClientExecuted = $false
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'receipt.json') -Encoding UTF8
    Write-Host "Lifecycle PostgreSQL receipt: $resultRoot"
}
if (-not $cleanupVerified) { throw 'lifecycle_test_cleanup_unproven' }
if ($null -ne $failureCode) { throw $failureCode }
