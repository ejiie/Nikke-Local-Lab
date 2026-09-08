[CmdletBinding()]
param(
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$DotnetPath = 'E:\Program Files\dotnet\dotnet.exe',
    [ValidateSet('phase-b', 'save-as-observation')]
    [string]$Scenario = 'phase-b',
    [ValidateRange(1024, 65535)]
    [int]$Port = 55432
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PhaseBLive {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Get-Sha256Text {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Test-PhaseBTcpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [int]$TcpPort,

        [int]$TimeoutMilliseconds = 1000
    )

    $client = [Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $client.ConnectAsync($Address, $TcpPort)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            return $false
        }

        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$testProject = Join-Path $repositoryRoot 'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$testName = if ($Scenario -ceq 'save-as-observation') {
    'NikkeLocalLab.PostgreSql.IntegrationTests.PostgreSqlLocalGameStateTests.CompleteFetchedSnapshotBecomesCurrentAndReusesExistingSelectiveImportDiff'
}
else {
    'NikkeLocalLab.PostgreSql.IntegrationTests.PostgreSqlLocalGameStateTests.ImportAuthorityScopesEditorSaveAsAndCasRemainExplicit'
}
$postgresPath = Join-Path $PostgreSqlRoot 'bin\postgres.exe'
$pgCtlPath = Join-Path $PostgreSqlRoot 'bin\pg_ctl.exe'
$initDbPath = Join-Path $PostgreSqlRoot 'bin\initdb.exe'
$createdbPath = Join-Path $PostgreSqlRoot 'bin\createdb.exe'
$dropdbPath = Join-Path $PostgreSqlRoot 'bin\dropdb.exe'
$psqlPath = Join-Path $PostgreSqlRoot 'bin\psql.exe'
if (-not (Test-Path -LiteralPath $DotnetPath -PathType Leaf)) {
    $dotnetCommand = Get-Command dotnet -ErrorAction Stop
    $DotnetPath = $dotnetCommand.Source
}
foreach ($path in @($postgresPath, $pgCtlPath, $initDbPath, $createdbPath, $dropdbPath, $psqlPath, $DotnetPath, $testProject)) {
    Assert-PhaseBLive (Test-Path -LiteralPath $path -PathType Leaf) 'phase_b_live_required_input_missing'
}

$version = (& $postgresPath --version | Out-String).Trim()
Assert-PhaseBLive ($version -ceq 'postgres (PostgreSQL) 17.11') 'phase_b_live_postgresql_version_invalid'
Assert-PhaseBLive (@(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0) 'phase_b_live_postgres_already_running'
Assert-PhaseBLive (-not (Test-PhaseBTcpEndpoint -Address '127.0.0.1' -TcpPort $Port)) 'phase_b_live_port_in_use'

$acceptanceUid = [guid]::NewGuid().ToString('D')
$databaseName = 'nikke_local_lab_phase_b_test'
$databaseUser = 'nll_phase_b'
$workRoot = Join-Path $env:TEMP ('NLL-PhaseB-Live-' + $acceptanceUid)
$dataRoot = Join-Path $workRoot 'data'
$logPath = Join-Path $workRoot 'postgres.log'
$passwordPath = Join-Path $workRoot 'pwfile'
$receiptRoot = Join-Path $repositoryRoot 'artifacts\automation\phase-b-live'
$receiptPath = Join-Path $receiptRoot ($acceptanceUid + '.receipt.json')
$resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
Assert-PhaseBLive `
    ($resolvedWorkRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) `
    'phase_b_live_work_root_invalid'

$randomBytes = [byte[]]::new(32)
$randomNumberGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $randomNumberGenerator.GetBytes($randomBytes)
}
finally {
    $randomNumberGenerator.Dispose()
}
$databasePassword = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
[Array]::Clear($randomBytes, 0, $randomBytes.Length)
$started = $false
$databaseCreated = $false
$testOutput = ''
$testExitCode = -1
$historyObservation = @()
$cleanupVerified = $false
$failureCode = $null
$startedAtUtc = [DateTimeOffset]::UtcNow

New-Item -ItemType Directory -Path $workRoot | Out-Null
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null

try {
    [IO.File]::WriteAllText($passwordPath, $databasePassword, [Text.UTF8Encoding]::new($false))
    & $initDbPath `
        '-D' $dataRoot `
        '--username' $databaseUser `
        '--pwfile' $passwordPath `
        '--auth-host' 'scram-sha-256' `
        '--auth-local' 'trust' `
        '--encoding' 'UTF8' `
        '--locale' 'C' `
        '--no-instructions' | Out-Host
    Assert-PhaseBLive ($LASTEXITCODE -eq 0) 'phase_b_live_initdb_failed'
    Remove-Item -LiteralPath $passwordPath -Force

    [IO.File]::AppendAllText(
        (Join-Path $dataRoot 'postgresql.conf'),
        "`nlisten_addresses = '127.0.0.1'`nport = $Port`nmax_connections = 20`nshared_buffers = '64MB'`nwork_mem = '2MB'`nmaintenance_work_mem = '32MB'`n",
        [Text.UTF8Encoding]::new($false))

    # Do not pipe pg_ctl output: the spawned postgres process inherits the pipe
    # handle on Windows and PowerShell then waits forever for EOF.
    & $pgCtlPath 'start' '-D' $dataRoot '-l' $logPath '-w' '-t' '60'
    Assert-PhaseBLive ($LASTEXITCODE -eq 0) 'phase_b_live_postgresql_start_failed'
    $started = $true
    Write-Host 'phase_b_live_marker:listener_probe_begin'
    Assert-PhaseBLive `
        (Test-PhaseBTcpEndpoint -Address '127.0.0.1' -TcpPort $Port) `
        'phase_b_live_loopback_listener_missing'
    Write-Host 'phase_b_live_marker:listener_probe_passed'

    $env:PGPASSWORD = $databasePassword
    Write-Host 'phase_b_live_marker:database_create_begin'
    & $createdbPath `
        '--host' '127.0.0.1' `
        '--port' $Port `
        '--username' $databaseUser `
        '--maintenance-db' 'postgres' `
        $databaseName
    Assert-PhaseBLive ($LASTEXITCODE -eq 0) 'phase_b_live_database_create_failed'
    $databaseCreated = $true
    Write-Host 'phase_b_live_marker:database_create_passed'

    $env:NIKKE_LAB_TEST_DB = "Host=127.0.0.1;Port=$Port;Database=$databaseName;Username=$databaseUser;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $databaseName
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    $env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_NOLOGO = '1'

    Write-Host 'phase_b_live_marker:dotnet_test_begin'
    $captured = @(& $DotnetPath test $testProject `
        '--configuration' 'Release' `
        '--no-restore' `
        '--nologo' `
        '--filter' "FullyQualifiedName=$testName" 2>&1)
    $testExitCode = $LASTEXITCODE
    $testOutput = ($captured | Out-String)
    $captured | Out-Host
    Assert-PhaseBLive ($testExitCode -eq 0) 'phase_b_live_test_failed'
    Write-Host 'phase_b_live_marker:dotnet_test_passed'

    Write-Host 'phase_b_live_marker:history_query_begin'
    if ($Scenario -ceq 'save-as-observation') {
        $historyRows = @(& $psqlPath `
            '--host' '127.0.0.1' `
            '--port' $Port `
            '--username' $databaseUser `
            '--dbname' $databaseName `
            '--tuples-only' `
            '--no-align' `
            '--field-separator' "`t" `
            '--command' @'
SELECT count(*),
       count(source_snapshot_uid),
       count(DISTINCT source_snapshot_uid),
       count(*) FILTER (WHERE binding_kind = 'save_as/v1')
FROM lab_profile.account_observation_provenance_binding;
'@)
        Assert-PhaseBLive ($LASTEXITCODE -eq 0) 'phase_b_live_observation_query_failed'
        $historyObservation = @($historyRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-PhaseBLive ($historyObservation.Count -eq 1) 'phase_b_live_observation_result_missing'
        Assert-PhaseBLive ($historyObservation[0] -ceq "2`t2`t1`t2") 'phase_b_live_observation_binding_invalid'
    }
    else {
        $historyRows = @(& $psqlPath `
            '--host' '127.0.0.1' `
            '--port' $Port `
            '--username' $databaseUser `
            '--dbname' $databaseName `
            '--tuples-only' `
            '--no-align' `
            '--field-separator' "`t" `
            '--command' @'
SELECT workspace.account_label,
       count(revision.profile_template_revision_id),
       (workspace.save_as_parent_account_uid IS NOT NULL)::text
FROM lab_profile.account_workspace AS workspace
JOIN lab_profile.profile_template_revision AS revision
  ON revision.local_account_id = workspace.local_account_id
WHERE workspace.account_label IN ('계정_1', '계정_2')
GROUP BY workspace.account_label, workspace.save_as_parent_account_uid
ORDER BY workspace.account_label;
'@)
        Assert-PhaseBLive ($LASTEXITCODE -eq 0) 'phase_b_live_history_query_failed'
        $historyObservation = @($historyRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-PhaseBLive ($historyObservation.Count -eq 2) 'phase_b_live_account_pair_missing'
        Assert-PhaseBLive ($historyObservation[0] -ceq "계정_1`t2`tfalse") 'phase_b_live_source_history_invalid'
        Assert-PhaseBLive ($historyObservation[1] -ceq "계정_2`t2`ttrue") 'phase_b_live_copy_history_invalid'
    }
    Write-Host 'phase_b_live_marker:history_query_passed'
}
catch {
    $failureCode = $_.Exception.Message
}
finally {
    Write-Host 'phase_b_live_marker:cleanup_begin'
    $env:NIKKE_LAB_TEST_DB = $null
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $null
    $env:NIKKE_LAB_TEST_RESET_TOKEN = $null
    $env:PGPASSWORD = $databasePassword

    if ($databaseCreated) {
        & $dropdbPath `
            '--host' '127.0.0.1' `
            '--port' $Port `
            '--username' $databaseUser `
            '--maintenance-db' 'postgres' `
            '--force' `
            $databaseName 2>$null
    }

    if ($started) {
        & $pgCtlPath 'stop' '-D' $dataRoot '-m' 'fast' '-w' '-t' '60'
    }

    $env:PGPASSWORD = $null
    $databasePassword = $null
    $postgresProcessCount = @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count
    $listenerCount = if (Test-PhaseBTcpEndpoint -Address '127.0.0.1' -TcpPort $Port) { 1 } else { 0 }
    $cleanupVerified = $postgresProcessCount -eq 0 -and $listenerCount -eq 0
    Write-Host ("phase_b_live_marker:cleanup_observed:postgres={0}:listener={1}" -f $postgresProcessCount, $listenerCount)

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/automation-phase-b-live-acceptance/v1'
        acceptedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        acceptanceUid = $acceptanceUid
        scenario = $Scenario
        postgresVersion = $version
        postgresExeSha256 = (Get-FileHash -LiteralPath $postgresPath -Algorithm SHA256).Hash.ToLowerInvariant()
        databaseName = $databaseName
        loopbackAddress = '127.0.0.1'
        port = $Port
        testName = $testName
        testExitCode = $testExitCode
        testOutputSha256 = Get-Sha256Text -Text $testOutput
        accountLabels = if ($Scenario -ceq 'phase-b') { @('계정_1', '계정_2') } else { @() }
        historyObservations = $historyObservation
        independentRevisionHistoryVerified = $failureCode -eq $null
        independentRuntimeCandidateVerified = $failureCode -eq $null
        gameRuntimeModified = $false
        goldenModified = $false
        dockerUsed = $false
        windowsServiceUsed = $false
        postgresProcessCountAfter = $postgresProcessCount
        portListenerCountAfter = $listenerCount
        cleanupVerified = $cleanupVerified
        verdictCode = if ($failureCode -eq $null -and $cleanupVerified) { 'phase_b_live_acceptance_passed' } else { 'phase_b_live_acceptance_failed' }
        failureCode = $failureCode
        nextStepCode = if ($failureCode -eq $null -and $cleanupVerified) { 'phase_b_complete_begin_phase_c_fetch_adapter' } else { 'inspect_phase_b_live_failure_without_retry' }
    }
    [IO.File]::WriteAllText(
        $receiptPath,
        ($receipt | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))

    if ($cleanupVerified -and (Test-Path -LiteralPath $resolvedWorkRoot)) {
        Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force
    }

    $receipt | ConvertTo-Json -Depth 6
}

if ($failureCode -ne $null) {
    throw $failureCode
}
Assert-PhaseBLive $cleanupVerified 'phase_b_live_cleanup_failed'
