[CmdletBinding()]
param([int]$Port = 55439)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nll-cube-pg-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $testRoot 'data'
$bin = 'C:\NLL\Runtime\PostgreSQL-17-native\bin'
New-Item -ItemType Directory -Path $testRoot | Out-Null
$started = $false
try {
    & (Join-Path $bin 'initdb.exe') -D $data -U nll_cube_test --auth=trust --encoding=UTF8 --no-locale | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'cube_test_initdb_failed' }
    $server = Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -ArgumentList @(
        'start', '-D', ('"' + $data + '"'), '-l', ('"' + (Join-Path $testRoot 'postgres.log') + '"'),
        '-o', ('"-h 127.0.0.1 -p ' + $Port + '"'), '-w', '-t', '30') -WindowStyle Hidden -PassThru
    $server.WaitForExit()
    if ($server.ExitCode -ne 0) { throw 'cube_test_postgres_start_failed' }
    $started = $true
    & (Join-Path $bin 'createdb.exe') -h 127.0.0.1 -p $Port -U nll_cube_test nikke_local_lab_cube_test
    if ($LASTEXITCODE -ne 0) { throw 'cube_test_database_create_failed' }
    $env:NIKKE_LAB_TEST_DB = "Host=127.0.0.1;Port=$Port;Database=nikke_local_lab_cube_test;Username=nll_cube_test;SSL Mode=Disable"
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = 'nikke_local_lab_cube_test'
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    dotnet test (Join-Path $repo 'tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj') --configuration Release --no-restore --filter AccountCubeInventoryPersistsCopiesAndPreservesImmutableHistory --verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw 'cube_inventory_integration_failed' }
} finally {
    if ($started) {
        $stop = Start-Process -FilePath (Join-Path $bin 'pg_ctl.exe') -ArgumentList @('stop','-D',('"' + $data + '"'),'-m','fast','-w','-t','30') -WindowStyle Hidden -PassThru
        $stop.WaitForExit()
    }
    # Test-only database retained for diagnostics; no production connection or schema is used.
    Write-Output ('cube_test_cluster_stopped=' + $testRoot)
}
