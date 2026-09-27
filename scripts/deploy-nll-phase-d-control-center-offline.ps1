[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$PostgreSqlRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [string]$RawFetchPath = 'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json',
    [string]$StaticDataPackPath =
        'C:\NLL\Staging\PhysicalP0-v1\Inputs\staticdata\553116\StaticData.pack',
    [string]$EpinelBinaryRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$PinnedRuntimeRoot =
        'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9',
    [ValidateRange(1024, 65535)] [int]$Port = 55433,
    [string]$AccountLabel = '계정_1',
    [switch]$UsePreparedArtifacts,
    [switch]$RepairPartialInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Deploy { param([bool]$Condition, [string]$Code) if (-not $Condition) { throw $Code } }
function Get-Sha256Lower { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-TcpPort {
    param([int]$TcpPort)
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $TcpPort); return $task.Wait(800) -and $client.Connected }
    catch { return $false }
    finally { $client.Dispose() }
}
function Write-AtomicJson {
    param([string]$Path, [object]$Value, [int]$Depth = 8)
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth $Depth) + "`n"), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
        $backup = $Path + '.backup-' + [guid]::NewGuid().ToString('N')
        try { [IO.File]::Replace($temporary, $Path, $backup) }
        finally {
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    else { Move-Item -LiteralPath $temporary -Destination $Path }
}
function Set-DeployStage {
    param([string]$Code)
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { return }
    $marker = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-control-center-install-stage/v1'
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        stageCode = $Code
    }
    Write-AtomicJson (Join-Path $InstallRoot 'install-stage.json') $marker 4
}
function Protect-ControlCenterSecret {
    param([string]$Value, [string]$Path)
    $plain = [Text.Encoding]::UTF8.GetBytes($Value)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plain, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($Path, $protected)
        [Array]::Clear($protected, 0, $protected.Length)
    }
    finally { [Array]::Clear($plain, 0, $plain.Length); [Array]::Clear($entropy, 0, $entropy.Length) }
}
function New-CryptographicRandomBytes {
    param([ValidateRange(1, 4096)] [int]$Count)
    $bytes = New-Object byte[] $Count
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes); return $bytes }
    finally { $generator.Dispose() }
}
function Invoke-CapturedNative {
    param([string]$FilePath, [string[]]$Arguments)
    $encodedArguments = foreach ($argument in $Arguments) {
        Assert-Deploy (-not $argument.Contains('"')) 'phase_d_native_argument_quote_rejected'
        if ($argument -match '\s') { '"' + $argument + '"' } else { $argument }
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = [string]::Join(' ', $encodedArguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        StandardOutput = $standardOutput
        StandardError = $standardError
    }
}
trap {
    try {
        if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
            $failureCode = [string]$_.Exception.Message
            if ($failureCode -notmatch '^phase_[a-z0-9_:,.-]+$') { $failureCode = 'non_contract_exception' }
            Write-AtomicJson (Join-Path $InstallRoot 'install-error.json') ([ordered]@{
                schemaVersion = 1
                contractId = 'nll/phase-d-control-center-install-error/v1'
                failedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                failureCode = $failureCode
                fullyQualifiedErrorId = [string]$_.FullyQualifiedErrorId
                scriptLineNumber = [int]$_.InvocationInfo.ScriptLineNumber
            }) 4
        }
    }
    catch { }
    exit 1
}
function Export-ExactStaticDataArchive {
    param(
        [string]$PackPath,
        [string]$OutputPath,
        [string]$ExporterBuildRoot,
        [string]$RuntimeRoot,
        [string]$WorkingRoot)
    Assert-Deploy `
        ((Get-Item -LiteralPath $PackPath).Length -eq 17177168L -and
         (Get-Sha256Lower $PackPath) -ceq '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3') `
        'phase_d_staticdata_pack_drifted'
    $exporterRoot = Join-Path $WorkingRoot 'staticdata-exporter'
    Assert-Deploy (-not (Test-Path -LiteralPath $exporterRoot)) 'phase_d_staticdata_exporter_root_exists'
    New-Item -ItemType Directory -Path $exporterRoot | Out-Null
    try {
        Get-ChildItem -LiteralPath $ExporterBuildRoot -File |
            Copy-Item -Destination $exporterRoot -Force
        Get-ChildItem -LiteralPath $RuntimeRoot -File -Filter '*.dll' |
            Copy-Item -Destination $exporterRoot -Force
        Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'gameconfig.json') -Destination $exporterRoot -Force
        $exporter = Join-Path $exporterRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
        Assert-Deploy (Test-Path -LiteralPath $exporter -PathType Leaf) 'phase_d_staticdata_exporter_missing'
        & $exporter '--export-static-data' $OutputPath '--static-pack' $PackPath '--game-config' (Join-Path $exporterRoot 'gameconfig.json')
        Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_staticdata_export_failed'
    }
    finally { Remove-Item -LiteralPath $exporterRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Assert-Deploy `
        ((Get-Item -LiteralPath $OutputPath).Length -eq 17176616L -and
         (Get-Sha256Lower $OutputPath) -ceq '925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69') `
        'phase_d_staticdata_archive_drifted'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$dotnet = 'C:\Program Files\dotnet\dotnet.exe'
$configPath = Join-Path $repositoryRoot 'config\appsettings.example.json'
$cliPath = Join-Path $repositoryRoot 'src\NikkeLocalLab.Import.Cli\bin\Release\net8.0\NikkeLocalLab.Import.Cli.dll'
$bootstrapTool = Join-Path $repositoryRoot 'tools\NikkeLocalLab.ControlCenterBootstrap\bin\Release\net8.0\NikkeLocalLab.ControlCenterBootstrap.dll'
$adminPublishRoot = Join-Path $repositoryRoot 'artifacts\phase-d\control-center'
$materializerArtifactRoot = Join-Path $repositoryRoot 'artifacts\phase-d\runtime-materializer'
$materializerBuildRoot = Join-Path $repositoryRoot 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64'
$weaknessVariantServerProject = Join-Path $repositoryRoot `
    '.external\EpinelPS\EpinelPS\EpinelPS.csproj'
$weaknessVariantServerBuildRoot = Join-Path $repositoryRoot `
    '.external\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64'
$weaknessVariantServerDll = Join-Path $weaknessVariantServerBuildRoot 'EpinelPS.dll'
$weaknessVariantSourceManifest = Join-Path $repositoryRoot `
    'scripts\phase-d-weakness-variant-v10.source.manifest.tsv'
$weaknessVariantArtifactRoot = Join-Path $repositoryRoot `
    'artifacts\phase-d\weakness-variant-server'
$expectedWeaknessVariantServerDllSha256 =
    'a364b9211efc1b60d23efc50075e101b0212f09b96a311b167743d01583939e6'
$expectedWeaknessVariantSourceManifestSha256 =
    '0ebd23987384fde1537b88efcfdd5b19fc18176f185d9cd1e9fa743914d24bbf'
$postgres = Join-Path $PostgreSqlRoot 'bin\postgres.exe'
$pgCtl = Join-Path $PostgreSqlRoot 'bin\pg_ctl.exe'
$initDb = Join-Path $PostgreSqlRoot 'bin\initdb.exe'
$createdb = Join-Path $PostgreSqlRoot 'bin\createdb.exe'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-Deploy ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'phase_d_deploy_requires_administrator'
Assert-Deploy ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') 'phase_d_deploy_wrong_operator_or_boot'
if ($RepairPartialInstall -and (Test-Path -LiteralPath $InstallRoot)) {
    $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    Assert-Deploy ($resolvedInstallRoot -ceq 'C:\NLL\ControlCenter') 'phase_d_partial_repair_target_invalid'
    Assert-Deploy (-not (Test-Path -LiteralPath (Join-Path $resolvedInstallRoot 'deployment.receipt.json'))) 'phase_d_partial_repair_receipt_present'
    Assert-Deploy (-not (Test-Path -LiteralPath (Join-Path $resolvedInstallRoot 'postgresql\data\postmaster.pid'))) 'phase_d_partial_repair_postmaster_present'
    Assert-Deploy (@(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) 'phase_d_partial_repair_runtime_not_cold'
    Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
}
Assert-Deploy (-not (Test-Path -LiteralPath $InstallRoot)) 'phase_d_control_center_already_installed'
Assert-Deploy (-not (Test-TcpPort $Port)) 'phase_d_control_center_port_in_use'
Assert-Deploy (@(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) 'phase_d_deploy_runtime_not_cold'
foreach ($path in @($dotnet,$configPath,$RawFetchPath,$StaticDataPackPath,$postgres,$pgCtl,$initDb,$createdb,$weaknessVariantServerProject,$weaknessVariantSourceManifest,(Join-Path $PinnedRuntimeRoot 'EpinelPS.dll'))) {
    Assert-Deploy (Test-Path -LiteralPath $path -PathType Leaf) 'phase_d_deploy_input_missing'
}
Assert-Deploy ((Get-Sha256Lower (Join-Path $PinnedRuntimeRoot 'EpinelPS.dll')) -ceq '98d4f4d12ff83c694ee052f9eca3c63ae782f2c4747a80993ee257384eef2498') 'phase_d_pinned_runtime_drifted'

$env:DOTNET_CLI_HOME = Join-Path $repositoryRoot '.dotnet-cli-home'
$env:NUGET_PACKAGES = Join-Path $repositoryRoot '.nuget-packages'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
if (-not $UsePreparedArtifacts) {
    & $dotnet build (Join-Path $repositoryRoot 'src\NikkeLocalLab.Import.Cli\NikkeLocalLab.Import.Cli.csproj') '-c' 'Release' '--no-restore'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_import_cli_build_failed'
    & $dotnet build (Join-Path $repositoryRoot 'tools\NikkeLocalLab.ControlCenterBootstrap\NikkeLocalLab.ControlCenterBootstrap.csproj') '-c' 'Release' '--no-restore'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_bootstrap_build_failed'
    if (Test-Path -LiteralPath $adminPublishRoot) { Remove-Item -LiteralPath $adminPublishRoot -Recurse -Force }
    & $dotnet publish (Join-Path $repositoryRoot 'src\NikkeLocalLab.Admin.Api\NikkeLocalLab.Admin.Api.csproj') '-c' 'Release' '--no-restore' '-o' $adminPublishRoot
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_admin_publish_failed'
    Push-Location (Join-Path $repositoryRoot 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer')
    try {
        & $dotnet build '.\NikkeLocalLab.PhaseD.RuntimeMaterializer.csproj' '-c' 'Release' '--no-restore' ('-p:EpinelReferenceRoot=' + $PinnedRuntimeRoot) '-p:NuGetAudit=false'
    }
    finally { Pop-Location }
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_materializer_build_failed'
    & $dotnet build $weaknessVariantServerProject '-c' 'Release' '--no-restore'
    Assert-Deploy ($LASTEXITCODE -eq 0) `
        'phase_d_weakness_variant_server_build_failed'
}
$preparedArtifacts = @(
    $cliPath,
    $bootstrapTool,
    (Join-Path $adminPublishRoot 'NikkeLocalLab.Admin.Api.dll'),
    (Join-Path $adminPublishRoot 'NikkeLocalLab.Admin.Api.runtimeconfig.json'),
    (Join-Path $materializerBuildRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'),
    (Join-Path $materializerBuildRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.dll'),
    (Join-Path $materializerBuildRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json'),
    (Join-Path $materializerBuildRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')
    $weaknessVariantServerDll
)
foreach ($preparedArtifact in $preparedArtifacts) {
    Assert-Deploy (Test-Path -LiteralPath $preparedArtifact -PathType Leaf) 'phase_d_prepared_artifact_missing'
}
# The API invokes this helper out of process; prepared deployments must carry
# the same database contract on both sides, including after a migration edit.
Assert-Deploy ((Get-Sha256Lower (Join-Path (Split-Path $cliPath) 'NikkeLocalLab.Persistence.PostgreSql.dll')) -ceq
    (Get-Sha256Lower (Join-Path $adminPublishRoot 'NikkeLocalLab.Persistence.PostgreSql.dll'))) `
    'phase_d_import_cli_persistence_mismatch'
Assert-Deploy `
    ((Get-Item -LiteralPath $weaknessVariantServerDll).Length -eq 15406592L -and
     (Get-Sha256Lower $weaknessVariantServerDll) -ceq `
        $expectedWeaknessVariantServerDllSha256 -and
     (Get-Item -LiteralPath $weaknessVariantSourceManifest).Length -eq 3270L -and
     (Get-Sha256Lower $weaknessVariantSourceManifest) -ceq `
        $expectedWeaknessVariantSourceManifestSha256) `
    'phase_d_weakness_variant_server_artifact_invalid'
$externalSourceRoot = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot '.external\EpinelPS')).TrimEnd('\') + '\'
$weaknessVariantSourceRows = @(Get-Content `
    -LiteralPath $weaknessVariantSourceManifest -Encoding UTF8)
Assert-Deploy ($weaknessVariantSourceRows.Count -eq 25) `
    'phase_d_weakness_variant_source_manifest_invalid'
foreach ($row in $weaknessVariantSourceRows) {
    $parts = @($row -split "`t")
    Assert-Deploy `
        ($parts.Count -eq 3 -and
         $parts[0] -cmatch '^(EpinelPS|tests)/[A-Za-z0-9._/-]+$' -and
         $parts[1] -cmatch '^[1-9][0-9]*$' -and
         $parts[2] -cmatch '^[0-9a-f]{64}$') `
        'phase_d_weakness_variant_source_manifest_invalid'
    $sourcePath = [IO.Path]::GetFullPath(
        (Join-Path $externalSourceRoot $parts[0].Replace('/', '\')))
    Assert-Deploy `
        ($sourcePath.StartsWith(
            $externalSourceRoot, [StringComparison]::OrdinalIgnoreCase) -and
         (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
         (Get-Item -LiteralPath $sourcePath).Length -eq [long]$parts[1] -and
         (Get-Sha256Lower $sourcePath) -ceq $parts[2]) `
        'phase_d_weakness_variant_source_drifted'
}
New-Item -ItemType Directory -Path $materializerArtifactRoot -Force | Out-Null
foreach ($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
    Copy-Item -LiteralPath (Join-Path $materializerBuildRoot $leaf) -Destination $materializerArtifactRoot -Force
}
New-Item -ItemType Directory -Path $weaknessVariantArtifactRoot -Force | Out-Null
Copy-Item -LiteralPath $weaknessVariantServerDll `
    -Destination (Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll') -Force
Copy-Item -LiteralPath $weaknessVariantSourceManifest `
    -Destination (Join-Path $weaknessVariantArtifactRoot 'source.manifest.tsv') -Force

$appRoot = Join-Path $InstallRoot 'app'
$dataRoot = Join-Path $InstallRoot 'postgresql\data'
$secretsRoot = Join-Path $InstallRoot 'secrets'
$sourceFreeRoot = Join-Path $InstallRoot 'source-free'
$logsRoot = Join-Path $InstallRoot 'logs'
$runtimeHome = Join-Path $InstallRoot 'runtime-home'
$stagingRoot = Join-Path $InstallRoot 'staging'
$passwordPath = Join-Path $secretsRoot 'database-password.dpapi'
$identityPath = Join-Path $secretsRoot 'identity-secret.dpapi'
$temporaryPasswordPath = Join-Path $stagingRoot 'initdb-password.txt'
$decodedArchivePath = Join-Path $stagingRoot 'StaticData.zip'
$draftPath = Join-Path $sourceFreeRoot 'sanitized-profile.draft.json'
$runtimeDraftPath = Join-Path $runtimeHome 'PhaseDInstall\sanitized-profile.draft.json'
$snapshotPath = Join-Path $sourceFreeRoot 'fetched-account.snapshot.json'
$bootstrapReceiptPath = Join-Path $sourceFreeRoot 'persistent-bootstrap.receipt.json'
$logPath = Join-Path $logsRoot 'postgresql.log'
New-Item -ItemType Directory -Path $InstallRoot,$appRoot,$secretsRoot,$sourceFreeRoot,$logsRoot,$runtimeHome,$stagingRoot | Out-Null
Set-DeployStage 'directories_created'
Get-ChildItem -LiteralPath $adminPublishRoot -Force | Copy-Item -Destination $appRoot -Recurse -Force
Set-DeployStage 'admin_app_copied'
& "$env:SystemRoot\System32\icacls.exe" $secretsRoot '/inheritance:r' '/grant:r' ("*{0}:(OI)(CI)F" -f $identity.User.Value) '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_secret_acl_failed'
Set-DeployStage 'secret_acl_applied'

$random = New-CryptographicRandomBytes 32
$databasePassword = ([Convert]::ToBase64String($random)).TrimEnd('=').Replace('+','-').Replace('/','_')
[Array]::Clear($random,0,$random.Length)
$random = New-CryptographicRandomBytes 32
$identitySecret = [Convert]::ToBase64String($random)
[Array]::Clear($random,0,$random.Length)
Protect-ControlCenterSecret $databasePassword $passwordPath
Protect-ControlCenterSecret $identitySecret $identityPath
[IO.File]::WriteAllText($temporaryPasswordPath,$databasePassword,[Text.UTF8Encoding]::new($false))
Set-DeployStage 'secrets_protected'
$started = $false
try {
    & $initDb '-D' $dataRoot '--username' 'nll_control_center' '--pwfile' $temporaryPasswordPath '--auth-host' 'scram-sha-256' '--auth-local' 'trust' '--encoding' 'UTF8' '--locale' 'C' '--no-instructions'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_control_center_initdb_failed'
    Set-DeployStage 'postgresql_initialized'
    Remove-Item -LiteralPath $temporaryPasswordPath -Force
    [IO.File]::AppendAllText((Join-Path $dataRoot 'postgresql.conf'), "`nlisten_addresses = '127.0.0.1'`nport = $Port`nmax_connections = 24`nshared_buffers = '64MB'`n", [Text.UTF8Encoding]::new($false))
    & $pgCtl 'start' '-D' $dataRoot '-l' $logPath '-w' '-t' '60'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_control_center_postgresql_start_failed'
    $started = $true
    Set-DeployStage 'postgresql_started'
    $env:PGPASSWORD = $databasePassword
    Set-DeployStage 'database_create_started'
    & $createdb '--host' '127.0.0.1' '--port' $Port '--username' 'nll_control_center' '--maintenance-db' 'postgres' 'nll_control_center'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_control_center_database_create_failed'
    Set-DeployStage 'database_created'
    $connectionString = "Host=127.0.0.1;Port=$Port;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_DB = $connectionString
    $env:NIKKE_LAB_ID_SECRET = $identitySecret
    $env:NIKKE_LAB_HOME = $runtimeHome
    $env:NIKKE_LAB_PROFILE_RAW = $RawFetchPath
    Set-DeployStage 'staticdata_export_started'
    Export-ExactStaticDataArchive `
        -PackPath $StaticDataPackPath `
        -OutputPath $decodedArchivePath `
        -ExporterBuildRoot $materializerBuildRoot `
        -RuntimeRoot $PinnedRuntimeRoot `
        -WorkingRoot $stagingRoot
    Set-DeployStage 'staticdata_exported'
    & $dotnet $cliPath 'character-catalog-import' '--config' $configPath '--repository-root' $repositoryRoot '--static-root' $stagingRoot '--static-file' 'StaticData.zip'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_character_catalog_import_failed'
    Set-DeployStage 'character_catalog_imported'
    & $dotnet $cliPath 'combat-support-catalog-import' '--config' $configPath '--repository-root' $repositoryRoot '--static-root' $stagingRoot '--static-file' 'StaticData.zip'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_support_catalog_import_failed'
    Set-DeployStage 'support_catalog_imported'
    & $dotnet $cliPath 'raid-catalog-import' '--config' $configPath '--repository-root' $repositoryRoot '--static-root' $stagingRoot '--static-file' 'StaticData.zip'
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_raid_catalog_import_failed'
    Set-DeployStage 'raid_catalog_imported'
    $capturedAt = [DateTimeOffset]::UtcNow
    $capturedAt = [DateTimeOffset]::new($capturedAt.UtcTicks - ($capturedAt.UtcTicks % 10),[TimeSpan]::Zero)
    $capturedAtText = $capturedAt.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'",[Globalization.CultureInfo]::InvariantCulture)
    & $dotnet $cliPath 'profile-draft-import' '--config' $configPath '--repository-root' $repositoryRoot '--level-authority' 'detail_observation/v1' '--operation-uid' ([guid]::NewGuid().ToString('D')) '--imported-at-utc' $capturedAtText '--output-draft' $runtimeDraftPath
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_profile_draft_import_failed'
    Assert-Deploy (Test-Path -LiteralPath $runtimeDraftPath -PathType Leaf) 'phase_d_profile_draft_output_missing'
    Copy-Item -LiteralPath $runtimeDraftPath -Destination $draftPath
    Set-DeployStage 'profile_draft_materialized'
    $snapshotUid = [guid]::NewGuid().ToString('D')
    & $dotnet $cliPath 'fetched-account-snapshot-materialize' '--config' $configPath '--repository-root' $repositoryRoot '--sanitized-draft' $runtimeDraftPath '--snapshot-uid' $snapshotUid '--captured-at-utc' $capturedAtText
    Assert-Deploy ($LASTEXITCODE -eq 0) 'phase_d_snapshot_materialization_failed'
    Set-DeployStage 'account_snapshot_materialized'
    $runtimeSnapshotPath = Join-Path $runtimeHome `
        ('FetchedAccountSnapshots\' + $snapshotUid + '\fetched-account.snapshot.json')
    Assert-Deploy (Test-Path -LiteralPath $runtimeSnapshotPath -PathType Leaf) `
        'phase_d_snapshot_output_missing'
    Copy-Item -LiteralPath $runtimeSnapshotPath -Destination $snapshotPath
    $bootstrapResult = Invoke-CapturedNative $dotnet @(
        $bootstrapTool,
        '--draft', $draftPath,
        '--snapshot', $snapshotPath,
        '--receipt', $bootstrapReceiptPath,
        '--account-label', $AccountLabel,
        '--connection-string-env', 'NIKKE_LAB_DB')
    if ($bootstrapResult.ExitCode -ne 0) {
        $bootstrapFailure = $bootstrapResult.StandardError.Trim()
        if ($bootstrapFailure -match '^error:([a-z0-9_.-]{3,128})$') { throw $Matches[1] }
        throw 'phase_d_persistent_bootstrap_failed'
    }
    Set-DeployStage 'persistent_account_bootstrapped'
}
finally {
    if ($started) { & $pgCtl 'stop' '-D' $dataRoot '-m' 'fast' '-w' '-t' '60' | Out-Null }
    foreach ($name in @('PGPASSWORD','NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET','NIKKE_LAB_HOME','NIKKE_LAB_PROFILE_RAW')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
    $databasePassword=$null; $identitySecret=$null
    if (Test-Path -LiteralPath $temporaryPasswordPath) { Remove-Item -LiteralPath $temporaryPasswordPath -Force }
    if (Test-Path -LiteralPath $decodedArchivePath) { Remove-Item -LiteralPath $decodedArchivePath -Force }
}
Assert-Deploy (@(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and -not (Test-TcpPort $Port)) 'phase_d_control_center_cleanup_failed'
Set-DeployStage 'runtime_cold_after_bootstrap'

$installedStart = Join-Path $InstallRoot 'Start-NLL-ControlCenter.ps1'
$installedStop = Join-Path $InstallRoot 'Stop-NLL-ControlCenter.ps1'
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\start-nll-phase-d-control-center.ps1') -Destination $installedStart
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts\stop-nll-phase-d-control-center.ps1') -Destination $installedStop
$desktop = [Environment]::GetFolderPath('Desktop')
$desktopCommand = Join-Path $desktop 'NLL Control Center.cmd'
$commandText = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command `"Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"`"$installedStart`"`"'`"`r`n"
[IO.File]::WriteAllText($desktopCommand,$commandText,[Text.Encoding]::ASCII)
$bootstrapReceipt = Get-Content -LiteralPath $bootstrapReceiptPath -Raw | ConvertFrom-Json
$receipt = [ordered]@{
    schemaVersion=1; contractId='nll/phase-d-control-center-deployment/v1'; deployedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
    installRoot=$InstallRoot; accountUid=[string]$bootstrapReceipt.accountUid; accountLabel=[string]$bootstrapReceipt.accountLabel
    port=$Port; appDllSha256=Get-Sha256Lower (Join-Path $appRoot 'NikkeLocalLab.Admin.Api.dll')
    materializerExeSha256=Get-Sha256Lower (Join-Path $materializerArtifactRoot 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe')
    weaknessVariantServerDllSha256=Get-Sha256Lower `
        (Join-Path $weaknessVariantArtifactRoot 'EpinelPS.dll')
    weaknessVariantSourceManifestSha256=Get-Sha256Lower `
        (Join-Path $weaknessVariantArtifactRoot 'source.manifest.tsv')
    weaknessVariantSourceFileCount=$weaknessVariantSourceRows.Count
    runtimeCandidateReady=[bool]$bootstrapReceipt.runtimeCandidateReady
    validationStatusCode=[string]$bootstrapReceipt.validationStatusCode
    validationReasonCodes=@($bootstrapReceipt.validationReasonCodes)
    persistentDatabaseInitialized=$true; secretsProtectedWithCurrentUserDpapi=$true; desktopLauncherCreated=$true
    goldenModified=$false; parentV8Modified=$false; officialInstallModified=$false; dBackupModified=$false
    nextStepCode=if ([bool]$bootstrapReceipt.runtimeCandidateReady) {
        'operator_open_control_center_and_exercise_phase_d_features'
    } else {
        'operator_open_control_center_resolve_candidate_then_launch'
    }
}
Write-AtomicJson (Join-Path $InstallRoot 'deployment.receipt.json') $receipt
Set-DeployStage 'deployment_completed'
$receipt | ConvertTo-Json -Depth 8
