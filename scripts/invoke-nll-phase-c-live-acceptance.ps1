[CmdletBinding()]
param(
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
    [ValidateRange(1024, 65535)]
    [int]$Port = 55433
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PhaseCLive {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Test-PhaseCTcpEndpoint {
    param([string]$Address, [int]$TcpPort)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $TcpPort)
        return $task.Wait(1000) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-Sha256Text {
    param([AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        return [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testProject = Join-Path $repositoryRoot `
    'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$testName = 'NikkeLocalLab.PostgreSql.IntegrationTests.PostgreSqlLocalGameStateTests.CompleteFetchedSnapshotBecomesCurrentAndReusesExistingSelectiveImportDiff'
$postgresPath = Join-Path $PostgreSqlRoot 'bin\postgres.exe'
$pgCtlPath = Join-Path $PostgreSqlRoot 'bin\pg_ctl.exe'
$initDbPath = Join-Path $PostgreSqlRoot 'bin\initdb.exe'
$createdbPath = Join-Path $PostgreSqlRoot 'bin\createdb.exe'
$dropdbPath = Join-Path $PostgreSqlRoot 'bin\dropdb.exe'
$psqlPath = Join-Path $PostgreSqlRoot 'bin\psql.exe'
if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) {
    $DotnetPath = (Get-Command dotnet -ErrorAction Stop).Source
}
foreach ($path in @(
        $postgresPath, $pgCtlPath, $initDbPath, $createdbPath,
        $dropdbPath, $psqlPath, $DotnetPath, $testProject)) {
    Assert-PhaseCLive (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase_c_live_required_input_missing'
}

$postgresVersion = (& $postgresPath --version | Out-String).Trim()
Assert-PhaseCLive ($postgresVersion -ceq 'postgres (PostgreSQL) 17.11') `
    'phase_c_live_postgresql_version_invalid'
Assert-PhaseCLive (@(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_c_live_postgres_already_running'
Assert-PhaseCLive (-not (Test-PhaseCTcpEndpoint -Address '127.0.0.1' -TcpPort $Port)) `
    'phase_c_live_port_in_use'

$acceptanceUid = [guid]::NewGuid().ToString('D')
$databaseName = 'nikke_local_lab_phase_c_test'
$databaseUser = 'nll_phase_c'
$workRoot = Join-Path $env:TEMP ('NLL-PhaseC-Live-' + $acceptanceUid)
$dataRoot = Join-Path $workRoot 'data'
$logPath = Join-Path $workRoot 'postgres.log'
$passwordPath = Join-Path $workRoot 'pwfile'
$receiptRoot = Join-Path $repositoryRoot 'artifacts\automation\phase-c-live'
$receiptPath = Join-Path $receiptRoot ($acceptanceUid + '.receipt.json')
$resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
Assert-PhaseCLive `
    ($resolvedWorkRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) `
    'phase_c_live_work_root_invalid'

$randomBytes = [byte[]]::new(32)
[Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
$databasePassword = ([Convert]::ToBase64String($randomBytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
[Array]::Clear($randomBytes, 0, $randomBytes.Length)
$started = $false
$databaseCreated = $false
$testOutput = ''
$testExitCode = -1
$statusObservations = @()
$snapshotCount = 0
$currentPointerCount = 0
$progressionSidecarCount = 0
$progressionSidecarVerifiedCount = 0
$cleanupVerified = $false
$failureCode = $null

New-Item -ItemType Directory -Path $workRoot | Out-Null
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null

try {
    [IO.File]::WriteAllText(
        $passwordPath, $databasePassword, [Text.UTF8Encoding]::new($false))
    & $initDbPath `
        '-D' $dataRoot `
        '--username' $databaseUser `
        '--pwfile' $passwordPath `
        '--auth-host' 'scram-sha-256' `
        '--auth-local' 'trust' `
        '--encoding' 'UTF8' `
        '--locale' 'C' `
        '--no-instructions' | Out-Host
    Assert-PhaseCLive ($LASTEXITCODE -eq 0) 'phase_c_live_initdb_failed'
    Remove-Item -LiteralPath $passwordPath -Force
    [IO.File]::AppendAllText(
        (Join-Path $dataRoot 'postgresql.conf'),
        "`nlisten_addresses = '127.0.0.1'`nport = $Port`nmax_connections = 20`nshared_buffers = '64MB'`n",
        [Text.UTF8Encoding]::new($false))

    & $pgCtlPath 'start' '-D' $dataRoot '-l' $logPath '-w' '-t' '60'
    Assert-PhaseCLive ($LASTEXITCODE -eq 0) 'phase_c_live_postgresql_start_failed'
    $started = $true
    Assert-PhaseCLive `
        (Test-PhaseCTcpEndpoint -Address '127.0.0.1' -TcpPort $Port) `
        'phase_c_live_listener_missing'

    $env:PGPASSWORD = $databasePassword
    & $createdbPath `
        '--host' '127.0.0.1' `
        '--port' $Port `
        '--username' $databaseUser `
        '--maintenance-db' 'postgres' `
        $databaseName
    Assert-PhaseCLive ($LASTEXITCODE -eq 0) 'phase_c_live_database_create_failed'
    $databaseCreated = $true

    $env:NIKKE_LAB_TEST_DB = `
        "Host=127.0.0.1;Port=$Port;Database=$databaseName;Username=$databaseUser;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $databaseName
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    $env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_NOLOGO = '1'

    $captured = @(& $DotnetPath test $testProject `
        '--configuration' 'Release' `
        '--no-restore' `
        '--nologo' `
        '--filter' "FullyQualifiedName=$testName" 2>&1)
    $testExitCode = $LASTEXITCODE
    $testOutput = ($captured | Out-String)
    $captured | Out-Host
    Assert-PhaseCLive ($testExitCode -eq 0) 'phase_c_live_test_failed'

    $statusObservations = @(& $psqlPath `
        '--host' '127.0.0.1' `
        '--port' $Port `
        '--username' $databaseUser `
        '--dbname' $databaseName `
        '--tuples-only' `
        '--no-align' `
        '--field-separator' "`t" `
        '--command' @'
SELECT completeness_status_code, count(*)
FROM lab_profile.fetched_account_snapshot
GROUP BY completeness_status_code
ORDER BY completeness_status_code;
'@ | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-PhaseCLive ($LASTEXITCODE -eq 0) 'phase_c_live_status_query_failed'
    Assert-PhaseCLive ($statusObservations.Count -eq 2) 'phase_c_live_status_count_invalid'
    Assert-PhaseCLive ($statusObservations[0] -ceq "complete`t1") `
        'phase_c_live_complete_snapshot_invalid'
    Assert-PhaseCLive ($statusObservations[1] -ceq "incomplete`t2") `
        'phase_c_live_incomplete_snapshot_invalid'

    $snapshotCount = [int](& $psqlPath `
        '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--dbname' $databaseName '--tuples-only' '--no-align' `
        '--command' 'SELECT count(*) FROM lab_profile.fetched_account_snapshot;')
    Assert-PhaseCLive ($LASTEXITCODE -eq 0 -and $snapshotCount -eq 3) `
        'phase_c_live_snapshot_count_invalid'
    $progressionSidecarCount = [int](& $psqlPath `
        '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--dbname' $databaseName '--tuples-only' '--no-align' `
        '--command' 'SELECT count(*) FROM lab_profile.fetched_progression_observation;')
    Assert-PhaseCLive ($LASTEXITCODE -eq 0 -and $progressionSidecarCount -eq 1) `
        'phase_c_live_progression_sidecar_count_invalid'
    $progressionSidecarVerifiedCount = [int](& $psqlPath `
        '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--dbname' $databaseName '--tuples-only' '--no-align' `
        '--command' @'
SELECT count(*)
FROM lab_profile.fetched_progression_observation
WHERE completeness_status_code = 'incomplete'
  AND available_component_count = 2
  AND derived_component_count = 2
  AND unavailable_component_count = 1
  AND completed_scenario_count = 3
  AND main_quest_completed_count = 2
  AND main_quest_reward_claimed_count = 2
  AND contents_open_unlocked_count = 1
  AND stage_clear_history_count IS NULL
  AND trigger_count = 2;
'@)
    Assert-PhaseCLive `
        ($LASTEXITCODE -eq 0 -and $progressionSidecarVerifiedCount -eq 1) `
        'phase_c_live_progression_sidecar_projection_invalid'
    $currentPointerCount = [int](& $psqlPath `
        '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--dbname' $databaseName '--tuples-only' '--no-align' `
        '--command' 'SELECT count(*) FROM lab_profile.account_workspace WHERE fetched_snapshot_uid IS NOT NULL;')
    Assert-PhaseCLive ($LASTEXITCODE -eq 0 -and $currentPointerCount -eq 1) `
        'phase_c_live_current_pointer_invalid'
}
catch {
    $failureCode = $_.Exception.Message
}
finally {
    $env:NIKKE_LAB_TEST_DB = $null
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $null
    $env:NIKKE_LAB_TEST_RESET_TOKEN = $null
    $env:PGPASSWORD = $databasePassword
    if ($databaseCreated) {
        & $dropdbPath `
            '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
            '--maintenance-db' 'postgres' '--force' $databaseName 2>$null
    }
    if ($started) {
        & $pgCtlPath 'stop' '-D' $dataRoot '-m' 'fast' '-w' '-t' '60'
    }
    $env:PGPASSWORD = $null
    if (Test-Path -LiteralPath $workRoot) {
        $cleanupTarget = [IO.Path]::GetFullPath($workRoot)
        Assert-PhaseCLive `
            ($cleanupTarget.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) `
            'phase_c_live_cleanup_target_invalid'
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    $postgresCountAfter = @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count
    $listenerCountAfter = if (Test-PhaseCTcpEndpoint -Address '127.0.0.1' -TcpPort $Port) { 1 } else { 0 }
    $cleanupVerified = $postgresCountAfter -eq 0 -and $listenerCountAfter -eq 0
}

$passed = $null -eq $failureCode -and $testExitCode -eq 0 -and $cleanupVerified
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/automation-phase-c-live-acceptance/v1'
    acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    acceptanceUid = $acceptanceUid
    postgresVersion = $postgresVersion
    databaseName = $databaseName
    loopbackAddress = '127.0.0.1'
    port = $Port
    testName = $testName
    testExitCode = $testExitCode
    testOutputSha256 = Get-Sha256Text $testOutput
    snapshotCount = $snapshotCount
    progressionSidecarCount = $progressionSidecarCount
    progressionSidecarVerified = $progressionSidecarVerifiedCount -eq 1
    completenessObservations = $statusObservations
    completeSnapshotBecameCurrent = $currentPointerCount -eq 1
    incompleteSnapshotPreservedWithoutCurrentReplacement =
        $snapshotCount -eq 3 -and $currentPointerCount -eq 1
    selectiveImportDiffVerified = $testExitCode -eq 0
    rawSourcePersisted = $false
    officialUserIdentifierPersisted = $false
    credentialOrSessionPersisted = $false
    gameRuntimeModified = $false
    goldenModified = $false
    dockerUsed = $false
    windowsServiceUsed = $false
    postgresProcessCountAfter = $postgresCountAfter
    portListenerCountAfter = $listenerCountAfter
    cleanupVerified = $cleanupVerified
    verdictCode = if ($passed) {
        'phase_c_snapshot_storage_live_acceptance_passed'
    } else {
        'phase_c_snapshot_storage_live_acceptance_failed'
    }
    failureCode = $failureCode
    nextStepCode = if ($passed) {
        'run_operator_fetch_materialization_then_refetch_comparison'
    } else {
        'inspect_phase_c_live_failure_without_retry'
    }
}
$receiptJson = $receipt | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText(
    $receiptPath, $receiptJson, [Text.UTF8Encoding]::new($false))
$receiptJson
if (-not $passed) { throw ($failureCode ?? 'phase_c_live_acceptance_failed') }
