[CmdletBinding()]
param(
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$DotnetPath = 'C:\Program Files\dotnet\dotnet.exe',
    [string]$RawFetchPath = 'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json',
    [string]$StaticDataPackPath = 'C:\NLL\Staging\PhysicalP0-v1\Inputs\staticdata\553116\StaticData.pack',
    [string]$EpinelBinaryRoot = 'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$SameCaptureInputReceiptPath = '',
    [string]$SourceLocalLowRoot =
        'C:\Users\nlloperator\AppData\LocalLow\com_proximabeta\NIKKE',
    [string]$ProgressionTemplateArchivePath = '',
    [string]$ParentProgressionSealReceiptPath =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c\seal.receipt.json',
    [string]$ParentProgressionGoldenDatabasePath =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-parent-golden-v1\0cd733dc-118d-49f2-9973-d0fbda47ef8c\db.json',
    [string]$ProgressionSourceOutputRoot =
        'D:\NikkeLocalLab\Backups\phase3b2-user-progression-source-v1',
    [string]$CandidateEpinelRuntimeRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$CandidateDotnetPath = '',
    [switch]$RunControlCenterBrowserAcceptance,
    [string]$PythonPath =
        'C:\Users\nlloperator\Downloads\NLL-Imported-Samsung\.venv\Scripts\python.exe',
    [ValidateRange(1024, 65535)]
    [int]$Port = 55434,
    [ValidateRange(1024, 65535)]
    [int]$AdminPort = 17878
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-OperatorAcceptance {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Test-OperatorTcpEndpoint {
    param([string]$Address, [int]$TcpPort)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $TcpPort)
        return $task.Wait(1000) -and $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Get-FileSha256Lower {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Export-ExactStaticDataArchive {
    param(
        [string]$BinaryRoot,
        [string]$PackPath,
        [string]$OutputPath
    )

    Assert-OperatorAcceptance `
        ((Get-Item -LiteralPath $PackPath).Length -eq 17177168L -and
         (Get-FileSha256Lower $PackPath) -ceq
            '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3') `
        'phase_c_operator_staticdata_pack_drifted'
    foreach ($leaf in @(
            'ICSharpCode.SharpZipLib.dll',
            'Newtonsoft.Json.dll',
            'EpinelPS.dll',
            'gameconfig.json')) {
        Assert-OperatorAcceptance `
            (Test-Path -LiteralPath (Join-Path $BinaryRoot $leaf) -PathType Leaf) `
            'phase_c_operator_epinel_decoder_input_missing'
    }

    [void][Reflection.Assembly]::LoadFrom(
        (Join-Path $BinaryRoot 'ICSharpCode.SharpZipLib.dll'))
    [void][Reflection.Assembly]::LoadFrom(
        (Join-Path $BinaryRoot 'Newtonsoft.Json.dll'))
    $assembly = [Reflection.Assembly]::LoadFrom(
        (Join-Path $BinaryRoot 'EpinelPS.dll'))
    $gameConfig = Get-Content -LiteralPath (Join-Path $BinaryRoot 'gameconfig.json') -Raw |
        ConvertFrom-Json
    $staticType = $assembly.GetType('EpinelPS.Utils.StaticData', $true)
    $rootType = $assembly.GetType('EpinelPS.Utils.GameConfigRoot', $true)
    $configType = $assembly.GetType('EpinelPS.Utils.GameConfig', $true)
    $static = [Activator]::CreateInstance($staticType)
    $staticType.GetProperty('Url').SetValue($static, '')
    $staticType.GetProperty('Version').SetValue(
        $static, [string]$gameConfig.StaticDataMpk.Version)
    $staticType.GetProperty('Salt1').SetValue(
        $static, [string]$gameConfig.StaticDataMpk.Salt1)
    $staticType.GetProperty('Salt2').SetValue(
        $static, [string]$gameConfig.StaticDataMpk.Salt2)
    $root = [Activator]::CreateInstance($rootType)
    $rootType.GetProperty('StaticDataMpk').SetValue($root, $static)
    $configType.GetField(
        '_root', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $root)
    $gameDataType = $assembly.GetType('EpinelPS.Data.GameData', $true)
    $instance = [Activator]::CreateInstance($gameDataType, @($PackPath))
    $zipStream = $gameDataType.GetField(
        'ZipStream', [Reflection.BindingFlags]'NonPublic,Instance').GetValue($instance)
    try {
        $decoded = $zipStream.ToArray()
        try {
            [IO.File]::WriteAllBytes($OutputPath, $decoded)
        }
        finally {
            [Array]::Clear($decoded, 0, $decoded.Length)
        }
    }
    finally {
        $zipStream.Dispose()
    }
    Assert-OperatorAcceptance `
        ((Get-Item -LiteralPath $OutputPath).Length -eq 17176616L -and
         (Get-FileSha256Lower $OutputPath) -ceq
            '925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69') `
        'phase_c_operator_staticdata_archive_drifted'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repositoryRoot 'config\appsettings.example.json'
$cliPath = Join-Path $repositoryRoot `
    'src\NikkeLocalLab.Import.Cli\bin\Release\net8.0\NikkeLocalLab.Import.Cli.dll'
$testProject = Join-Path $repositoryRoot `
    'tests\NikkeLocalLab.PostgreSql.IntegrationTests\NikkeLocalLab.PostgreSql.IntegrationTests.csproj'
$sameCaptureInspectorPath = Join-Path $repositoryRoot `
    'scripts\test-nll-phase-c-same-capture-inputs.ps1'
$progressionExtractorPath = Join-Path $repositoryRoot `
    'scripts\extract-phase3b2-user-progression-source-offline.ps1'
$candidateProjectPath = Join-Path $repositoryRoot `
    'tools\Phase3B2.UserProgressionCandidateV2\Phase3B2.UserProgressionCandidateV2.csproj'
$adminProjectPath = Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.ControlCenterAcceptanceHost\NikkeLocalLab.ControlCenterAcceptanceHost.csproj'
$adminDllPath = Join-Path $repositoryRoot `
    'tools\NikkeLocalLab.ControlCenterAcceptanceHost\bin\Release\net8.0\NikkeLocalLab.ControlCenterAcceptanceHost.dll'
$browserAcceptanceScriptPath = Join-Path $repositoryRoot `
    'scripts\test-nll-phase-c-control-center-browser.py'
if ([string]::IsNullOrWhiteSpace($CandidateDotnetPath)) {
    $CandidateDotnetPath = Join-Path $repositoryRoot `
        '.tmp-dotnet-sdk-10.0.400\dotnet.exe'
}
$testName = 'NikkeLocalLab.PostgreSql.IntegrationTests.PostgreSqlLocalGameStateTests.OperatorFetchedSnapshotDistinguishesLocalEditAndReturnsToSourceValue'
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
        $postgresPath, $pgCtlPath, $initDbPath, $createdbPath, $dropdbPath,
        $psqlPath, $DotnetPath, $RawFetchPath, $StaticDataPackPath,
        $configPath, $cliPath, $testProject)) {
    Assert-OperatorAcceptance (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase_c_operator_required_input_missing'
}
if ($RunControlCenterBrowserAcceptance) {
    foreach ($path in @($PythonPath, $adminProjectPath, $browserAcceptanceScriptPath)) {
        Assert-OperatorAcceptance (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase_c_control_center_browser_input_missing'
    }
    Assert-OperatorAcceptance `
        (-not (Test-OperatorTcpEndpoint -Address '127.0.0.1' -TcpPort $AdminPort)) `
        'phase_c_control_center_admin_port_in_use'
}
$progressionRequested =
    -not [string]::IsNullOrWhiteSpace($SameCaptureInputReceiptPath)
$preflightRequestUid = $null
if ($progressionRequested) {
    foreach ($path in @(
            $SameCaptureInputReceiptPath, $SourceLocalLowRoot,
            $ParentProgressionSealReceiptPath,
            $ParentProgressionGoldenDatabasePath, $ProgressionSourceOutputRoot,
            $CandidateEpinelRuntimeRoot, $sameCaptureInspectorPath,
            $CandidateDotnetPath, $progressionExtractorPath, $candidateProjectPath)) {
        Assert-OperatorAcceptance (Test-Path -LiteralPath $path) `
            'phase_c_operator_progression_required_input_missing'
    }
    $preflight = Get-Content -LiteralPath $SameCaptureInputReceiptPath -Raw |
        ConvertFrom-Json
    Assert-OperatorAcceptance `
        ($preflight.contractId -ceq
            'nll/phase-c-same-capture-input-inspection/v2' -and
         [bool]$preflight.readyForOfflineMaterialization -and
         $preflight.verdictCode -ceq
            'same_capture_inputs_ready_for_offline_materialization') `
        'phase_c_operator_progression_preflight_not_ready'
    $preflightRequestUid = [string]$preflight.requestUid
    $requestManifestPath = Join-Path `
        (Split-Path -Parent $SameCaptureInputReceiptPath) 'request.manifest.json'
    $preflightRefreshText = & $sameCaptureInspectorPath `
        -InspectCapture `
        -RequestManifestPath $requestManifestPath `
        -RawFetchPath $RawFetchPath `
        -SourceLocalLowRoot $SourceLocalLowRoot `
        -ProgressionTemplateArchivePath $ProgressionTemplateArchivePath `
        -ParentSealReceiptPath $ParentProgressionSealReceiptPath `
        -ParentGoldenDatabasePath $ParentProgressionGoldenDatabasePath `
        -StaticDataPackPath $StaticDataPackPath `
        -RequireReady
    $preflightRefresh = $preflightRefreshText | ConvertFrom-Json
    Assert-OperatorAcceptance `
        ([bool]$preflightRefresh.Inspection.readyForOfflineMaterialization -and
         [string]$preflightRefresh.Inspection.requestUid -ceq $preflightRequestUid) `
        'phase_c_operator_progression_preflight_refresh_invalid'
}
Assert-OperatorAcceptance `
    ((& $postgresPath --version | Out-String).Trim() -ceq
        'postgres (PostgreSQL) 17.11') `
    'phase_c_operator_postgresql_version_invalid'
Assert-OperatorAcceptance `
    (@(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_c_operator_postgres_already_running'
Assert-OperatorAcceptance `
    (-not (Test-OperatorTcpEndpoint -Address '127.0.0.1' -TcpPort $Port)) `
    'phase_c_operator_port_in_use'

$acceptanceUid = [guid]::NewGuid().ToString('D')
$snapshotUid = [guid]::NewGuid().ToString('D')
$databaseName = 'nikke_local_lab_phase_c_operator_test'
$databaseUser = 'nll_phase_c_operator'
$workRoot = Join-Path $env:TEMP ('NLL-PhaseC-Operator-' + $acceptanceUid)
$dataRoot = Join-Path $workRoot 'data'
$runtimeRoot = Join-Path $workRoot 'runtime'
$decodedRoot = Join-Path $workRoot 'decoded'
$decodedArchivePath = Join-Path $decodedRoot 'StaticData.zip'
$logPath = Join-Path $workRoot 'postgres.log'
$passwordPath = Join-Path $workRoot 'pwfile'
$draftPath = Join-Path $runtimeRoot 'operator\sanitized-profile.draft.json'
$snapshotRoot = Join-Path $runtimeRoot ('FetchedAccountSnapshots\' + $snapshotUid)
$snapshotPath = Join-Path $snapshotRoot 'fetched-account.snapshot.json'
$progressionObservationRoot = Join-Path $runtimeRoot `
    ('FetchedProgressionObservations\' + $snapshotUid)
$progressionObservationPath = Join-Path $progressionObservationRoot `
    'fetched-progression.observation.json'
$artifactRoot = Join-Path $repositoryRoot `
    ('artifacts\automation\phase-c-operator\' + $acceptanceUid)
$acceptanceReceiptPath = Join-Path $artifactRoot 'operator-acceptance.receipt.json'
$wrapperReceiptPath = Join-Path $artifactRoot 'orchestration.receipt.json'
$browserReceiptPath = Join-Path $artifactRoot 'control-center-browser.receipt.json'
$browserScreenshotPath = Join-Path $artifactRoot 'control-center-after-apply.png'
$adminStdoutPath = Join-Path $workRoot 'admin.stdout.log'
$adminStderrPath = Join-Path $workRoot 'admin.stderr.log'
$adminBootstrapPath = Join-Path $workRoot 'admin.bootstrap.secret'
$resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
Assert-OperatorAcceptance `
    ($resolvedWorkRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) `
    'phase_c_operator_work_root_invalid'

$randomBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$databasePassword = ([Convert]::ToBase64String($randomBytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
[Array]::Clear($randomBytes, 0, $randomBytes.Length)
$identitySecretBytes = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$identitySecret = [Convert]::ToBase64String($identitySecretBytes)
[Array]::Clear($identitySecretBytes, 0, $identitySecretBytes.Length)
$started = $false
$databaseCreated = $false
$testExitCode = -1
$failureCode = $null
$decodedArchiveRemoved = $false
$cleanupVerified = $false
$adminProcess = $null
$browserAcceptanceVerified = $false

New-Item -ItemType Directory -Path $workRoot | Out-Null
New-Item -ItemType Directory -Path $decodedRoot | Out-Null
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

try {
    Export-ExactStaticDataArchive `
        -BinaryRoot $EpinelBinaryRoot `
        -PackPath $StaticDataPackPath `
        -OutputPath $decodedArchivePath
    [IO.File]::WriteAllText(
        $passwordPath, $databasePassword, [Text.UTF8Encoding]::new($false))
    & $initDbPath '-D' $dataRoot '--username' $databaseUser '--pwfile' $passwordPath `
        '--auth-host' 'scram-sha-256' '--auth-local' 'trust' '--encoding' 'UTF8' `
        '--locale' 'C' '--no-instructions' | Out-Host
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) 'phase_c_operator_initdb_failed'
    Remove-Item -LiteralPath $passwordPath -Force
    [IO.File]::AppendAllText(
        (Join-Path $dataRoot 'postgresql.conf'),
        "`nlisten_addresses = '127.0.0.1'`nport = $Port`nmax_connections = 20`nshared_buffers = '64MB'`n",
        [Text.UTF8Encoding]::new($false))
    & $pgCtlPath 'start' '-D' $dataRoot '-l' $logPath '-w' '-t' '60'
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) 'phase_c_operator_postgresql_start_failed'
    $started = $true

    $env:PGPASSWORD = $databasePassword
    & $createdbPath '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
        '--maintenance-db' 'postgres' $databaseName
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) 'phase_c_operator_database_create_failed'
    $databaseCreated = $true
    $connectionString = "Host=127.0.0.1;Port=$Port;Database=$databaseName;Username=$databaseUser;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_DB = $connectionString
    $env:NIKKE_LAB_TEST_DB = $connectionString
    $env:NIKKE_LAB_TEST_EXPECTED_DATABASE = $databaseName
    $env:NIKKE_LAB_TEST_RESET_TOKEN = 'allow-phase1a-disposable-schema-reset'
    $env:NIKKE_LAB_HOME = $runtimeRoot
    $env:NIKKE_LAB_PROFILE_RAW = $RawFetchPath
    $env:NIKKE_LAB_ID_SECRET = $identitySecret
    $env:NIKKE_LAB_OPERATOR_FETCH_ACCEPTANCE = '1'
    $env:NIKKE_LAB_OPERATOR_SNAPSHOT = $snapshotPath
    $env:NIKKE_LAB_OPERATOR_DRAFT = $draftPath
    if ($progressionRequested) {
        $env:NIKKE_LAB_OPERATOR_PROGRESSION = $progressionObservationPath
    }
    $env:NIKKE_LAB_OPERATOR_RECEIPT = $acceptanceReceiptPath
    $env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
    $env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
    $env:DOTNET_NOLOGO = '1'

    & $DotnetPath $cliPath character-catalog-import `
        '--config' $configPath '--repository-root' $repositoryRoot `
        '--static-root' $decodedRoot '--static-file' 'StaticData.zip'
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
        'phase_c_operator_character_catalog_import_failed'
    & $DotnetPath $cliPath combat-support-catalog-import `
        '--config' $configPath '--repository-root' $repositoryRoot `
        '--static-root' $decodedRoot '--static-file' 'StaticData.zip'
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
        'phase_c_operator_support_catalog_import_failed'

    if ($progressionRequested) {
        $parentProgressionRoot = Split-Path -Parent `
            $ParentProgressionGoldenDatabasePath
        $extractionText = & $progressionExtractorPath `
            -ProfileCapturePath $RawFetchPath `
            -SourceLocalLowRoot $SourceLocalLowRoot `
            -ProgressionTemplateArchivePath $ProgressionTemplateArchivePath `
            -ParentSealReceiptPath $ParentProgressionSealReceiptPath `
            -ExpectedParentSealReceiptSha256 `
                'c4d5239fedf6520fd23043e963b704831689a3cf3baf35a533bd340a8cb5c3b0' `
            -DetachedParentGoldenRoot $parentProgressionRoot `
            -OutputRoot $ProgressionSourceOutputRoot
        $extraction = $extractionText | ConvertFrom-Json
        $privateSourcePath = Join-Path $extraction.ExtractionRoot `
            'progression.source.private.json'
        $sourceReceiptPath = [string]$extraction.ReceiptPath
        Assert-OperatorAcceptance `
            ((Test-Path -LiteralPath $privateSourcePath -PathType Leaf) -and
             (Test-Path -LiteralPath $sourceReceiptPath -PathType Leaf)) `
            'phase_c_operator_progression_extraction_output_missing'

        Push-Location $workRoot
        try {
            & $CandidateDotnetPath build $candidateProjectPath `
                '--configuration' 'Release' '--nologo' `
                ('-p:EpinelRuntimeRoot=' + $CandidateEpinelRuntimeRoot) |
                Out-Host
        }
        finally {
            Pop-Location
        }
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_operator_progression_candidate_build_failed'
        $candidateToolPath = Join-Path (Split-Path -Parent $candidateProjectPath) `
            'bin\Release\net10.0\Phase3B2.UserProgressionCandidateV2.dll'
        Assert-OperatorAcceptance `
            (Test-Path -LiteralPath $candidateToolPath -PathType Leaf) `
            'phase_c_operator_progression_candidate_tool_missing'
        $candidateRoot = Join-Path $workRoot 'progression-candidate'
        & $CandidateDotnetPath $candidateToolPath 'build' $StaticDataPackPath `
            $privateSourcePath $ParentProgressionGoldenDatabasePath $candidateRoot |
            Out-Host
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_operator_progression_candidate_materialization_failed'
        $candidateDatabasePath = Join-Path $candidateRoot 'candidate-db.json'
        Assert-OperatorAcceptance `
            (Test-Path -LiteralPath $candidateDatabasePath -PathType Leaf) `
            'phase_c_operator_progression_candidate_missing'

        $sourceReceipt = Get-Content -LiteralPath $sourceReceiptPath -Raw |
            ConvertFrom-Json
        # ConvertFrom-Json returns an ISO timestamp as DateTime. Casting it back to
        # string uses the current culture and drops fractional seconds, which breaks
        # the exact binding to the detailed progression observation. Preserve the
        # parsed ticks by converting the DateTime value directly.
        $capturedAt = ([DateTimeOffset]$sourceReceipt.extractedAtUtc).ToUniversalTime()
        $capturedAt = [DateTimeOffset]::new(
            $capturedAt.UtcTicks - ($capturedAt.UtcTicks % 10), [TimeSpan]::Zero)
        & $DotnetPath $cliPath fetched-progression-observation-materialize `
            '--config' $configPath '--repository-root' $repositoryRoot `
            '--private-source' $privateSourcePath `
            '--source-receipt' $sourceReceiptPath `
            '--derived-candidate-database' $candidateDatabasePath `
            '--snapshot-uid' $snapshotUid
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_operator_progression_observation_materialization_failed'
        Assert-OperatorAcceptance `
            (Test-Path -LiteralPath $progressionObservationPath -PathType Leaf) `
            'phase_c_operator_progression_observation_missing'
    }
    else {
        $capturedAt = [DateTimeOffset]::UtcNow
        $capturedAt = [DateTimeOffset]::new(
            $capturedAt.UtcTicks - ($capturedAt.UtcTicks % 10), [TimeSpan]::Zero)
    }
    $capturedAtText = $capturedAt.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    & $DotnetPath $cliPath profile-draft-import `
        '--config' $configPath '--repository-root' $repositoryRoot `
        '--level-authority' 'detail_observation/v1' `
        '--operation-uid' ([guid]::NewGuid().ToString('D')) `
        '--imported-at-utc' $capturedAtText `
        '--output-draft' $draftPath
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
        'phase_c_operator_profile_draft_import_failed'
    Assert-OperatorAcceptance (Test-Path -LiteralPath $draftPath -PathType Leaf) `
        'phase_c_operator_profile_draft_export_missing'
    $snapshotArguments = @(
        $cliPath, 'fetched-account-snapshot-materialize',
        '--config', $configPath, '--repository-root', $repositoryRoot,
        '--sanitized-draft', $draftPath,
        '--snapshot-uid', $snapshotUid,
        '--captured-at-utc', $capturedAtText
    )
    if ($progressionRequested) {
        $snapshotArguments += @(
            '--progression-observation', $progressionObservationPath)
    }
    & $DotnetPath @snapshotArguments
    Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
        'phase_c_operator_snapshot_materialization_failed'
    Assert-OperatorAcceptance (Test-Path -LiteralPath $snapshotPath -PathType Leaf) `
        'phase_c_operator_snapshot_missing'
    Copy-Item -LiteralPath $draftPath `
        -Destination (Join-Path $artifactRoot 'sanitized-profile.draft.json')
    Copy-Item -LiteralPath $snapshotPath `
        -Destination (Join-Path $artifactRoot 'fetched-account.snapshot.json')
    if ($progressionRequested) {
        Copy-Item -LiteralPath $progressionObservationPath `
            -Destination (Join-Path $artifactRoot `
                'fetched-progression.observation.json')
    }

    & $DotnetPath test $testProject '--configuration' 'Release' '--no-restore' '--nologo' `
        '--filter' "FullyQualifiedName=$testName" | Out-Host
    $testExitCode = $LASTEXITCODE
    Assert-OperatorAcceptance ($testExitCode -eq 0) 'phase_c_operator_acceptance_test_failed'
    Assert-OperatorAcceptance `
        (Test-Path -LiteralPath $acceptanceReceiptPath -PathType Leaf) `
        'phase_c_operator_acceptance_receipt_missing'

    if ($RunControlCenterBrowserAcceptance) {
        & $DotnetPath restore $adminProjectPath '--locked-mode' `
            '--ignore-failed-sources' '-p:NuGetAudit=false' '--nologo' | Out-Host
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_control_center_admin_restore_failed'
        & $DotnetPath build $adminProjectPath '--configuration' 'Release' `
            '--no-restore' '--nologo' | Out-Host
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_control_center_admin_build_failed'
        Assert-OperatorAcceptance (Test-Path -LiteralPath $adminDllPath -PathType Leaf) `
            'phase_c_control_center_admin_binary_missing'
        $env:NLL_CONTROL_CENTER_BOOTSTRAP_PATH = $adminBootstrapPath
        $env:NLL_CONTROL_CENTER_PORT = [string]$AdminPort
        $adminProcess = Start-Process -FilePath $DotnetPath -ArgumentList @($adminDllPath) `
            -RedirectStandardOutput $adminStdoutPath `
            -RedirectStandardError $adminStderrPath `
            -WindowStyle Hidden -PassThru
        $bootstrapCode = $null
        for ($attempt = 0; $attempt -lt 150; $attempt++) {
            if ($adminProcess.HasExited) { break }
            if (Test-Path -LiteralPath $adminBootstrapPath -PathType Leaf) {
                $bootstrapCode = (Get-Content -LiteralPath $adminBootstrapPath -Raw).Trim()
                if (-not [string]::IsNullOrWhiteSpace($bootstrapCode)) { break }
            }
            Start-Sleep -Milliseconds 200
        }
        if ($adminProcess.HasExited) {
            $adminFailure = if (Test-Path -LiteralPath $adminStderrPath -PathType Leaf) {
                (Get-Content -LiteralPath $adminStderrPath -Raw).Trim()
            } else { 'stderr_missing' }
            throw ('phase_c_control_center_admin_exited:' + $adminFailure)
        }
        Assert-OperatorAcceptance (-not [string]::IsNullOrWhiteSpace($bootstrapCode)) `
            'phase_c_control_center_bootstrap_code_missing'
        Assert-OperatorAcceptance `
            (Test-OperatorTcpEndpoint -Address '127.0.0.1' -TcpPort $AdminPort) `
            'phase_c_control_center_admin_listener_missing'
        $operatorReceipt = Get-Content -LiteralPath $acceptanceReceiptPath -Raw |
            ConvertFrom-Json
        & $PythonPath $browserAcceptanceScriptPath `
            '--base-url' ("http://127.0.0.1:{0}" -f $AdminPort) `
            '--bootstrap-code' $bootstrapCode `
            '--account-uid' ([string]$operatorReceipt.accountUid) `
            '--snapshot' (Join-Path $artifactRoot 'fetched-account.snapshot.json') `
            '--draft' (Join-Path $artifactRoot 'sanitized-profile.draft.json') `
            '--progression' (Join-Path $artifactRoot `
                'fetched-progression.observation.json') `
            '--receipt' $browserReceiptPath `
            '--screenshot' $browserScreenshotPath | Out-Host
        if ($LASTEXITCODE -ne 0) {
            foreach ($log in @(
                    @{ Source = $adminStdoutPath; Leaf = 'control-center-admin.stdout.log' },
                    @{ Source = $adminStderrPath; Leaf = 'control-center-admin.stderr.log' })) {
                if (Test-Path -LiteralPath $log.Source -PathType Leaf) {
                    Copy-Item -LiteralPath $log.Source `
                        -Destination (Join-Path $artifactRoot $log.Leaf) -Force
                }
            }
        }
        Assert-OperatorAcceptance ($LASTEXITCODE -eq 0) `
            'phase_c_control_center_browser_failed'
        $browserReceipt = Get-Content -LiteralPath $browserReceiptPath -Raw |
            ConvertFrom-Json
        $browserAcceptanceVerified =
            $browserReceipt.contractId -ceq `
                'nll/phase-c-control-center-browser-acceptance/v1' -and
            $browserReceipt.verdictCode -ceq `
                'control_center_register_diff_selective_apply_passed' -and
            [bool]$browserReceipt.registeredThroughControlCenter -and
            [bool]$browserReceipt.commanderSelectedApplyVerified -and
            [bool]$browserReceipt.unselectedLobbyFieldsPreserved -and
            $browserReceipt.commanderDiffCount -eq 1 -and
            (Test-Path -LiteralPath $browserScreenshotPath -PathType Leaf)
        Assert-OperatorAcceptance $browserAcceptanceVerified `
            'phase_c_control_center_browser_receipt_invalid'
        $bootstrapCode = $null
        Remove-Item -LiteralPath $adminBootstrapPath -Force
    }

}
catch {
    $failureCode = $_.Exception.Message
}
finally {
    if ($null -ne $adminProcess -and -not $adminProcess.HasExited) {
        Stop-Process -Id $adminProcess.Id -Force
        $adminProcess.WaitForExit(10000)
    }
    foreach ($name in @(
            'NIKKE_LAB_DB', 'NIKKE_LAB_TEST_DB', 'NIKKE_LAB_TEST_EXPECTED_DATABASE',
            'NIKKE_LAB_TEST_RESET_TOKEN', 'NIKKE_LAB_HOME', 'NIKKE_LAB_PROFILE_RAW',
            'NIKKE_LAB_ID_SECRET', 'NIKKE_LAB_OPERATOR_FETCH_ACCEPTANCE',
            'NIKKE_LAB_OPERATOR_SNAPSHOT', 'NIKKE_LAB_OPERATOR_DRAFT',
            'NIKKE_LAB_OPERATOR_PROGRESSION',
            'NIKKE_LAB_OPERATOR_RECEIPT', 'NLL_CONTROL_CENTER_BOOTSTRAP_PATH',
            'NLL_CONTROL_CENTER_PORT')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $identitySecret = $null
    $env:PGPASSWORD = $databasePassword
    if ($databaseCreated) {
        & $dropdbPath '--host' '127.0.0.1' '--port' $Port '--username' $databaseUser `
            '--maintenance-db' 'postgres' '--force' $databaseName 2>$null
    }
    if ($started) {
        & $pgCtlPath 'stop' '-D' $dataRoot '-m' 'fast' '-w' '-t' '60'
    }
    $env:PGPASSWORD = $null
    if (Test-Path -LiteralPath $decodedArchivePath -PathType Leaf) {
        Remove-Item -LiteralPath $decodedArchivePath -Force
    }
    $decodedArchiveRemoved = -not (Test-Path -LiteralPath $decodedArchivePath)
    if (Test-Path -LiteralPath $workRoot) {
        $cleanupTarget = [IO.Path]::GetFullPath($workRoot)
        Assert-OperatorAcceptance `
            ($cleanupTarget.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) `
            'phase_c_operator_cleanup_target_invalid'
        Remove-Item -LiteralPath $cleanupTarget -Recurse -Force
    }
    $postgresCountAfter = @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count
    $listenerCountAfter = if (
        Test-OperatorTcpEndpoint -Address '127.0.0.1' -TcpPort $Port) { 1 } else { 0 }
    $cleanupVerified = $postgresCountAfter -eq 0 -and $listenerCountAfter -eq 0
}

$passed = $null -eq $failureCode -and $testExitCode -eq 0 -and
    $decodedArchiveRemoved -and $cleanupVerified -and
    (-not $RunControlCenterBrowserAcceptance -or $browserAcceptanceVerified)
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-c-operator-fetch-orchestration/v1'
    completedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    acceptanceUid = $acceptanceUid
    testExitCode = $testExitCode
    rawFetchReadOnly = $true
    rawFetchPathPersisted = $false
    rawFetchHashPersisted = $false
    staticDataPackReadOnly = $true
    decodedStaticDataPersisted = $false
    decodedStaticDataRemoved = $decodedArchiveRemoved
    credentialOrSessionPersisted = $false
    officialUserIdentifierPersisted = $false
    progressionSameCaptureRequested = $progressionRequested
    progressionPreflightRequestUid = $preflightRequestUid
    progressionObservationPersisted = $progressionRequested -and $passed
    freshExternalRefetchObserved = $progressionRequested
    officialFetchAutomated = $false
    controlCenterBrowserAcceptanceRequested = [bool]$RunControlCenterBrowserAcceptance
    controlCenterBrowserAcceptanceVerified = $browserAcceptanceVerified
    controlCenterBrowserReceiptSha256 = if ($browserAcceptanceVerified) {
        Get-FileSha256Lower $browserReceiptPath
    } else { $null }
    controlCenterScreenshotSha256 = if ($browserAcceptanceVerified) {
        Get-FileSha256Lower $browserScreenshotPath
    } else { $null }
    postgresProcessCountAfter = $postgresCountAfter
    portListenerCountAfter = $listenerCountAfter
    cleanupVerified = $cleanupVerified
    goldenModified = $false
    gameRuntimeModified = $false
    verdictCode = if ($passed) {
        if ($progressionRequested) {
            'phase_c_operator_fresh_same_capture_progression_acceptance_passed'
        } else {
            'phase_c_operator_same_capture_acceptance_passed_fresh_refetch_pending'
        }
    } else {
        'phase_c_operator_acceptance_failed'
    }
    failureCode = $failureCode
    nextStepCode = if ($passed) {
        if ($RunControlCenterBrowserAcceptance) {
            'close_phase_c_after_regression_verification'
        } elseif ($progressionRequested) {
            'run_control_center_browser_registration_and_commander_projection'
        } else {
            'add_progression_fetch_then_run_fresh_external_refetch'
        }
    } else {
        'inspect_operator_acceptance_failure_without_automatic_retry'
    }
}
$receiptJson = $receipt | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText(
    $wrapperReceiptPath, $receiptJson, [Text.UTF8Encoding]::new($false))
$receiptJson
if (-not $passed) { throw ($failureCode ?? 'phase_c_operator_acceptance_failed') }
