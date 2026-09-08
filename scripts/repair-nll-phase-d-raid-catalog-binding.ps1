[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$RepositoryRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab',
    [string]$MaterializerBuildRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64',
    [string]$PinnedRuntimeRoot =
        'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9',
    [string]$StaticDataPackPath =
        'C:\NLL\Staging\PhysicalP0-v1\Inputs\staticdata\553116\StaticData.pack',
    [ValidateRange(1024, 65535)] [int]$DatabasePort = 55433,
    [ValidateRange(1024, 65535)] [int]$AdminPort = 17878
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-RaidBindingRepair {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}
function Get-RaidBindingSha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Test-RaidBindingPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        $task.Wait(800) -and $client.Connected
    }
    catch { $false }
    finally { $client.Dispose() }
}
function Invoke-RaidBindingPgCtl {
    param([string]$PgCtlPath, [string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $PgCtlPath
    $info.Arguments = (($Arguments | ForEach-Object {
        '"' + $_.Replace('"', '\"') + '"'
    }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $exitCode
}
function Unprotect-RaidBindingSecret {
    param([string]$Path)
    $protected = [IO.File]::ReadAllBytes($Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        [Array]::Clear($entropy, 0, $entropy.Length)
    }
}
function Write-RaidBindingJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary,
        (($Value | ConvertTo-Json -Depth 10) + "`n"),
        [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path
}
function Export-RaidBindingStaticData {
    param(
        [string]$PackPath,
        [string]$OutputPath,
        [string]$ExporterBuildRoot,
        [string]$RuntimeRoot,
        [string]$WorkingRoot)
    Assert-RaidBindingRepair `
        ((Get-Item -LiteralPath $PackPath).Length -eq 17177168L -and
         (Get-RaidBindingSha256 $PackPath) -ceq
            '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3') `
        'phase_d_raid_catalog_repair_staticdata_pack_drifted'
    $exporterRoot = Join-Path $WorkingRoot 'staticdata-exporter'
    Assert-RaidBindingRepair (-not (Test-Path -LiteralPath $exporterRoot)) `
        'phase_d_raid_catalog_repair_exporter_exists'
    New-Item -ItemType Directory -Path $exporterRoot | Out-Null
    try {
        Get-ChildItem -LiteralPath $ExporterBuildRoot -File |
            Copy-Item -Destination $exporterRoot -Force
        Get-ChildItem -LiteralPath $RuntimeRoot -File -Filter '*.dll' |
            Copy-Item -Destination $exporterRoot -Force
        Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'gameconfig.json') `
            -Destination $exporterRoot -Force
        $exporter = Join-Path $exporterRoot `
            'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
        & $exporter '--export-static-data' $OutputPath '--static-pack' $PackPath `
            '--game-config' (Join-Path $exporterRoot 'gameconfig.json')
        Assert-RaidBindingRepair ($LASTEXITCODE -eq 0) `
            'phase_d_raid_catalog_repair_staticdata_export_failed'
    }
    finally {
        Remove-Item -LiteralPath $exporterRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
    }
    Assert-RaidBindingRepair `
        ((Get-Item -LiteralPath $OutputPath).Length -eq 17176616L -and
         (Get-RaidBindingSha256 $OutputPath) -ceq
            '925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69') `
        'phase_d_raid_catalog_repair_staticdata_archive_drifted'
}
function Get-RaidBindingCount {
    param(
        [string]$PsqlPath,
        [int]$Port,
        [string]$Sql)
    $output = @(& $PsqlPath -X -qAt -v ON_ERROR_STOP=1 `
        -h 127.0.0.1 -p $Port -U nll_control_center -d nll_control_center `
        -c $Sql 2>&1)
    Assert-RaidBindingRepair ($LASTEXITCODE -eq 0 -and $output.Count -eq 1) `
        'phase_d_raid_catalog_repair_count_query_failed'
    $value = 0L
    Assert-RaidBindingRepair `
        ([long]::TryParse(
            ([string]$output[0]).Trim(),
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)) `
        'phase_d_raid_catalog_repair_count_invalid'
    $value
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-RaidBindingRepair `
    ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
     $env:USERNAME -ceq 'nlloperator' -and $env:SystemDrive -ceq 'C:') `
    'phase_d_raid_catalog_repair_boundary_invalid'
Assert-RaidBindingRepair `
    ([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') -ceq
        'C:\NLL\ControlCenter') `
    'phase_d_raid_catalog_repair_target_invalid'
Assert-RaidBindingRepair `
    (@(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0 -and
     -not (Test-RaidBindingPort $DatabasePort) -and
     -not (Test-RaidBindingPort $AdminPort)) `
    'phase_d_raid_catalog_repair_runtime_not_cold'

$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$pgBin = 'C:\NLL\Runtime\PostgreSQL-17-native\bin'
$pgCtl = Join-Path $pgBin 'pg_ctl.exe'
$psql = Join-Path $pgBin 'psql.exe'
$pgData = Join-Path $InstallRoot 'postgresql\data'
$pgLog = Join-Path $InstallRoot 'logs\postgresql.log'
$configPath = Join-Path $RepositoryRoot 'config\appsettings.example.json'
$raidImportCli = Join-Path $RepositoryRoot `
    'src\NikkeLocalLab.Import.Cli\bin\Release\net8.0\NikkeLocalLab.Import.Cli.dll'
$materializer = Join-Path $MaterializerBuildRoot `
    'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
$deploymentPath = Join-Path $InstallRoot 'deployment.receipt.json'
foreach ($path in @(
    $dotnet,$pgCtl,$psql,$configPath,$raidImportCli,$materializer,
    $StaticDataPackPath,$deploymentPath,
    (Join-Path $PinnedRuntimeRoot 'gameconfig.json'))) {
    Assert-RaidBindingRepair (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase_d_raid_catalog_repair_input_missing'
}
$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
Assert-RaidBindingRepair `
    ($deployment.contractId -ceq 'nll/phase-d-control-center-deployment/v1' -and
     [string]$deployment.accountUid -cmatch '^[0-9a-f-]{36}$') `
    'phase_d_raid_catalog_repair_deployment_invalid'

$repairUid = [guid]::NewGuid().ToString('D')
$workRoot = Join-Path $InstallRoot ('staging\raid-catalog-repairs\' + $repairUid)
$receiptRoot = Join-Path $InstallRoot ('source-free\raid-catalog-repairs\' + $repairUid)
$decodedArchivePath = Join-Path $workRoot 'StaticData.zip'
New-Item -ItemType Directory -Path $workRoot,$receiptRoot -Force | Out-Null

$databasePassword = $null
$postgresStartAttempted = $false
$postgresStarted = $false
$operationFailure = $null
$postgresStopFailure = $null
$catalogCountBefore = 0L
$catalogCountAfter = 0L
$season26SnapshotCountBefore = 0L
$season26SnapshotCountAfter = 0L
$bootCountBefore = 0L
$bootCountAfter = 0L
$directoryCountBefore = 0L
$directoryCountAfter = 0L
$importStatus = $null
$catalogUid = $null
$season26ImportedUid = $null
$season26SnapshotUid = $null
$season26SnapshotSha256 = $null
try {
    Export-RaidBindingStaticData `
        -PackPath $StaticDataPackPath `
        -OutputPath $decodedArchivePath `
        -ExporterBuildRoot $MaterializerBuildRoot `
        -RuntimeRoot $PinnedRuntimeRoot `
        -WorkingRoot $workRoot
    $databasePassword = Unprotect-RaidBindingSecret `
        (Join-Path $InstallRoot 'secrets\database-password.dpapi')
    $env:PGPASSWORD = $databasePassword
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=$DatabasePort;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_HOME = Join-Path $InstallRoot 'runtime-home'
    $postgresStartAttempted = $true
    $pgStartExit = Invoke-RaidBindingPgCtl $pgCtl `
        @('start','-D',$pgData,'-l',$pgLog,'-w','-t','60')
    $postgresStarted = $pgStartExit -eq 0
    Assert-RaidBindingRepair ($pgStartExit -eq 0) `
        'phase_d_raid_catalog_repair_postgresql_start_failed'

    $catalogCountBefore = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_raid.raid_catalog_snapshot;'
    $season26SnapshotCountBefore = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_raid.raid_snapshot WHERE season_number = 26;'
    $bootCountBefore = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_private_server.private_server_boot_revision;'
    $directoryCountBefore = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_private_server.raid_season_directory;'

    $importOutput = @(& $dotnet $raidImportCli 'raid-catalog-import' `
        '--config' $configPath '--repository-root' $RepositoryRoot `
        '--static-root' $workRoot '--static-file' 'StaticData.zip' 2>&1)
    Assert-RaidBindingRepair ($LASTEXITCODE -eq 0) `
        'phase_d_raid_catalog_repair_import_failed'
    $importStatus = @($importOutput | ForEach-Object { [string]$_ } |
        Where-Object { $_ -cmatch '^status=(succeeded|reused)$' } |
        ForEach-Object { $_.Substring('status='.Length) }) |
        Select-Object -Last 1
    $catalogUid = @($importOutput | ForEach-Object { [string]$_ } |
        Where-Object { $_ -cmatch '^raid_catalog_snapshot_uid=[0-9a-f-]{36}$' } |
        ForEach-Object { $_.Substring('raid_catalog_snapshot_uid='.Length) }) |
        Select-Object -Last 1
    $season26ImportedUid = @($importOutput | ForEach-Object { [string]$_ } |
        Where-Object { $_ -cmatch '^season=26:raid_snapshot_uid=[0-9a-f-]{36}$' } |
        ForEach-Object { $_.Substring('season=26:raid_snapshot_uid='.Length) }) |
        Select-Object -Last 1
    Assert-RaidBindingRepair `
        ($importStatus -in @('succeeded','reused') -and
         $catalogUid -cmatch '^[0-9a-f-]{36}$' -and
         $season26ImportedUid -cmatch '^[0-9a-f-]{36}$') `
        'phase_d_raid_catalog_repair_import_receipt_invalid'

    $bindingOutput = @(& $materializer '--verify-solo-raid-binding' 'true' `
        '--connection-string-env' 'NIKKE_LAB_DB' `
        '--account-uid' ([string]$deployment.accountUid) `
        '--season-number' '26' 2>&1)
    Assert-RaidBindingRepair ($LASTEXITCODE -eq 0) `
        'phase_d_raid_catalog_repair_binding_verification_failed'
    try { $binding = ($bindingOutput -join "`n") | ConvertFrom-Json }
    catch { throw 'phase_d_raid_catalog_repair_binding_receipt_invalid' }
    Assert-RaidBindingRepair `
        ($binding.contractId -ceq
            'nll/phase-d-classic-solo-raid-binding-verification/v1' -and
         [string]$binding.accountUid -ceq [string]$deployment.accountUid -and
         [int]$binding.seasonNumber -eq 26 -and
         [string]$binding.raidSnapshotUid -ceq [string]$season26ImportedUid -and
         [string]$binding.raidSnapshotSha256 -cmatch '^[0-9a-f]{64}$' -and
         $binding.databaseModified -eq $false) `
        'phase_d_raid_catalog_repair_binding_receipt_invalid'
    $season26SnapshotUid = [string]$binding.raidSnapshotUid
    $season26SnapshotSha256 = [string]$binding.raidSnapshotSha256

    $catalogCountAfter = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_raid.raid_catalog_snapshot;'
    $season26SnapshotCountAfter = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_raid.raid_snapshot WHERE season_number = 26;'
    $bootCountAfter = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_private_server.private_server_boot_revision;'
    $directoryCountAfter = Get-RaidBindingCount $psql $DatabasePort `
        'SELECT count(*) FROM lab_private_server.raid_season_directory;'
    Assert-RaidBindingRepair `
        ($catalogCountAfter -eq 1 -and $season26SnapshotCountAfter -eq 1 -and
         $bootCountAfter -eq $bootCountBefore -and
         $directoryCountAfter -eq $directoryCountBefore) `
        'phase_d_raid_catalog_repair_postcondition_invalid'
}
catch {
    $operationFailure = $_
}
finally {
    $postmasterPidPath = Join-Path $pgData 'postmaster.pid'
    $postgresMayBeRunning =
        $postgresStarted -or
        ($postgresStartAttempted -and
         ((Test-Path -LiteralPath $postmasterPidPath -PathType Leaf) -or
          (Test-RaidBindingPort $DatabasePort) -or
          @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -gt 0))
    if ($postgresMayBeRunning) {
        try {
            $pgStopExit = Invoke-RaidBindingPgCtl $pgCtl `
                @('stop','-D',$pgData,'-m','fast','-w','-t','60')
            if ($pgStopExit -ne 0) {
                $postgresStopFailure =
                    'phase_d_raid_catalog_repair_postgresql_stop_failed'
            }
        }
        catch {
            $postgresStopFailure = $_
        }
    }
    foreach ($name in @('PGPASSWORD','NIKKE_LAB_DB','NIKKE_LAB_HOME')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $databasePassword = $null
    if (Test-Path -LiteralPath $decodedArchivePath -PathType Leaf) {
        Remove-Item -LiteralPath $decodedArchivePath -Force
    }
}

$runtimeColdAfterCleanup =
    @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-RaidBindingPort $DatabasePort) -and
    -not (Test-RaidBindingPort $AdminPort)
if (-not $runtimeColdAfterCleanup) {
    throw 'phase_d_raid_catalog_repair_cleanup_failed'
}
if ($null -ne $postgresStopFailure) { throw $postgresStopFailure }
if ($null -ne $operationFailure) { throw $operationFailure }
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-raid-catalog-binding-repair/v1'
    repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    repairUid = $repairUid
    deploymentReceiptSha256 = Get-RaidBindingSha256 $deploymentPath
    importStatus = $importStatus
    raidCatalogSnapshotUid = $catalogUid
    seasonNumber = 26
    raidSnapshotUid = $season26SnapshotUid
    raidSnapshotSha256 = $season26SnapshotSha256
    staticDataPackSha256 = Get-RaidBindingSha256 $StaticDataPackPath
    decodedStaticDataSha256 =
        '925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69'
    raidCatalogCountBefore = $catalogCountBefore
    raidCatalogCountAfter = $catalogCountAfter
    season26SnapshotCountBefore = $season26SnapshotCountBefore
    season26SnapshotCountAfter = $season26SnapshotCountAfter
    bootRevisionCountBefore = $bootCountBefore
    bootRevisionCountAfter = $bootCountAfter
    seasonDirectoryCountBefore = $directoryCountBefore
    seasonDirectoryCountAfter = $directoryCountAfter
    uniqueEligibleCatalogVerified = $true
    operationalBindingVerified = $true
    bootOrDirectoryModified = $false
    raidCatalogPublicationCreated = $importStatus -ceq 'succeeded'
    persistentDatabaseModified = $true
    decodedStaticDataRetained = $false
    gameRuntimeStarted = $false
    goldenModified = $false
    officialInstallModified = $false
    dBackupModified = $false
    runtimeColdAfterRepair = $true
    nextStepCode = 'run_phase_d_control_center_installation_smoke'
}
$receiptPath = Join-Path $receiptRoot 'repair.receipt.json'
Write-RaidBindingJson $receiptPath $receipt
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = Get-RaidBindingSha256 $receiptPath
} | ConvertTo-Json -Depth 10
