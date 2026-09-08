[CmdletBinding()]
param(
    [string]$ArchivePath = 'C:\NLL\Staging\PostgreSQL-17.11-native-install\postgresql-17.11-1-windows-x64-binaries.zip',
    [string]$InstallRoot = 'C:\NLL\Runtime\PostgreSQL-17-native',
    [switch]$KeepArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$expectedVersion = '17.11'
$expectedArchiveLength = 340719294L
$expectedArchiveSha256 = '6eabdf00d2893713b75db4336a23c3fdf505f056e217ec6e2e95d901750cfea3'
$expectedInstallRoot = [IO.Path]::GetFullPath('C:\NLL\Runtime\PostgreSQL-17-native')
$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)

function Assert-NativePostgresInstall {
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

Assert-NativePostgresInstall `
    ($resolvedInstallRoot -ceq $expectedInstallRoot) `
    'nll_native_postgresql_install_root_invalid'
Assert-NativePostgresInstall `
    (Test-Path -LiteralPath $ArchivePath -PathType Leaf) `
    'nll_native_postgresql_archive_missing'
Assert-NativePostgresInstall `
    (-not (Test-Path -LiteralPath $resolvedInstallRoot)) `
    'nll_native_postgresql_install_root_exists'

$archive = Get-Item -LiteralPath $ArchivePath
Assert-NativePostgresInstall `
    ($archive.Length -eq $expectedArchiveLength) `
    'nll_native_postgresql_archive_length_invalid'
$archiveSha256 = (Get-FileHash -LiteralPath $archive.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
Assert-NativePostgresInstall `
    ($archiveSha256 -ceq $expectedArchiveSha256) `
    'nll_native_postgresql_archive_sha256_invalid'

$stagingRoot = Split-Path -Parent $archive.FullName
$resolvedStagingRoot = [IO.Path]::GetFullPath($stagingRoot)
Assert-NativePostgresInstall `
    ($resolvedStagingRoot.StartsWith('C:\NLL\Staging\', [StringComparison]::OrdinalIgnoreCase)) `
    'nll_native_postgresql_staging_root_invalid'
$expandedRoot = Join-Path $resolvedStagingRoot ('expanded-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $expandedRoot | Out-Null

try {
    & "$env:SystemRoot\System32\tar.exe" -xf $archive.FullName -C $expandedRoot `
        'pgsql/bin' `
        'pgsql/lib' `
        'pgsql/share' `
        'pgsql/server_license.txt' `
        'pgsql/commandlinetools_3rd_party_licenses.txt'
    Assert-NativePostgresInstall ($LASTEXITCODE -eq 0) 'nll_native_postgresql_extract_failed'

    $candidateRoot = Join-Path $expandedRoot 'pgsql'
    $postgresPath = Join-Path $candidateRoot 'bin\postgres.exe'
    $pgCtlPath = Join-Path $candidateRoot 'bin\pg_ctl.exe'
    $initDbPath = Join-Path $candidateRoot 'bin\initdb.exe'
    $psqlPath = Join-Path $candidateRoot 'bin\psql.exe'
    foreach ($path in @($postgresPath, $pgCtlPath, $initDbPath, $psqlPath)) {
        Assert-NativePostgresInstall `
            (Test-Path -LiteralPath $path -PathType Leaf) `
            'nll_native_postgresql_required_binary_missing'
    }

    $versionOutput = (& $postgresPath --version | Out-String).Trim()
    Assert-NativePostgresInstall `
        ($versionOutput -ceq "postgres (PostgreSQL) $expectedVersion") `
        'nll_native_postgresql_version_invalid'

    $runtimeProcessCount = @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/windows-native-postgresql-installation/v1'
        installedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        installationUid = [guid]::NewGuid().ToString('D')
        distributionCode = 'edb_postgresql_windows_x64_binary_zip'
        postgresVersion = $expectedVersion
        archiveByteLength = $archive.Length
        archiveSha256 = $archiveSha256
        installRoot = $resolvedInstallRoot
        serviceRegistered = $false
        machinePathModified = $false
        userPathModified = $false
        listenAddressPolicy = 'loopback_only_when_started'
        defaultNllPort = 55432
        postgresExeByteLength = (Get-Item -LiteralPath $postgresPath).Length
        postgresExeSha256 = (Get-FileHash -LiteralPath $postgresPath -Algorithm SHA256).Hash.ToLowerInvariant()
        pgCtlExeSha256 = (Get-FileHash -LiteralPath $pgCtlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        initDbExeSha256 = (Get-FileHash -LiteralPath $initDbPath -Algorithm SHA256).Hash.ToLowerInvariant()
        psqlExeSha256 = (Get-FileHash -LiteralPath $psqlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        postgresAuthenticodeStatus = (Get-AuthenticodeSignature -FilePath $postgresPath).Status.ToString()
        runtimeProcessCountAfterInstall = $runtimeProcessCount
        nextStepCode = 'create_ephemeral_loopback_cluster_then_run_phase_b_live_acceptance'
    }
    $receiptPath = Join-Path $candidateRoot 'nll.installation.receipt.json'
    [IO.File]::WriteAllText(
        $receiptPath,
        ($receipt | ConvertTo-Json -Depth 5),
        [Text.UTF8Encoding]::new($false))

    Assert-NativePostgresInstall `
        ($receipt.runtimeProcessCountAfterInstall -eq 0) `
        'nll_native_postgresql_process_persisted_after_install'
    [IO.Directory]::Move($candidateRoot, $resolvedInstallRoot)
    Assert-NativePostgresInstall `
        ((& (Join-Path $resolvedInstallRoot 'bin\postgres.exe') --version | Out-String).Trim() -ceq $versionOutput) `
        'nll_native_postgresql_post_move_version_invalid'
    $receipt | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $expandedRoot) {
        $resolvedExpandedRoot = [IO.Path]::GetFullPath($expandedRoot)
        Assert-NativePostgresInstall `
            ($resolvedExpandedRoot.StartsWith($resolvedStagingRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
            'nll_native_postgresql_expanded_cleanup_target_invalid'
        Remove-Item -LiteralPath $resolvedExpandedRoot -Recurse -Force
    }

    if (-not $KeepArchive -and (Test-Path -LiteralPath $archive.FullName -PathType Leaf)) {
        Remove-Item -LiteralPath $archive.FullName -Force
    }

    if (-not $KeepArchive -and (Test-Path -LiteralPath $resolvedStagingRoot -PathType Container)) {
        $remaining = @(Get-ChildItem -LiteralPath $resolvedStagingRoot -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $resolvedStagingRoot -Force
        }
    }
}
