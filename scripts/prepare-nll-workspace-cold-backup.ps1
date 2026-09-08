[CmdletBinding()]
param()

# Physical backup of a SHUT DOWN operational cluster; run only its new clone.
# No operational PostgreSQL start, migration, SQL write, or automatic restoration.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
Add-Type -AssemblyName System.Security
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$source = 'C:\NLL\ControlCenter\postgresql\data'
$backupParent = 'D:\NikkeLocalLab\Backups'
$native = 'C:\NLL\Runtime\PostgreSQL-17-native\bin'
$port = 55434
$uid = [guid]::NewGuid().ToString('N')
$backupRoot = Join-Path $backupParent ('workspace-pre-v18-' + $uid)
$backupData = Join-Path $backupRoot 'cold-data'
$clone = Join-Path $backupRoot 'restore-rehearsal'
$resultRoot = Join-Path $repositoryRoot ('artifacts/stabilization/workspace-backup/' + $uid)

function Assert-PlainAncestors([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'workspace_backup_reparse_path' }
        }
        $current = Split-Path -Parent $current
    }
}
function Assert-OperationalCold {
    if (Test-Path -LiteralPath (Join-Path $source 'postmaster.pid')) { throw 'workspace_backup_source_not_cold' }
    $processes = @(Get-CimInstance Win32_Process)
    if (@($processes | Where-Object {
        $_.Name -match '^(postgres|pg_ctl|nikke|EpinelPS|NikkeLocalLab.*)\.exe$' -or
        ($_.CommandLine -match 'NikkeLocalLab.Admin.Api.dll|watch-nll-phase-d-execution.ps1|invoke-nll-phase-d-execution.ps1|recover-nll-phase-d-orphaned-execution.ps1|Start-NLL-ControlCenter.ps1')
    }).Count -gt 0) { throw 'workspace_backup_runtime_not_cold' }
    if (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in @(55433, $port) }).Count -gt 0) { throw 'workspace_backup_listener_present' }
}
function Read-ProbeSql([string]$Sql) {
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $native 'psql.exe'))
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @('-X', '-q', '-A', '-t', '-h', '127.0.0.1', '-p', "$port", '-U', 'nll_control_center', '-d', 'nll_control_center', '-v', 'ON_ERROR_STOP=1', '-c', $Sql)) { $info.ArgumentList.Add($arg) }
    # Secret is child-process environment only, never arguments/receipt/log output.
    $info.Environment['PGPASSWORD'] = $password
    $info.Environment['PGOPTIONS'] = '-c default_transaction_read_only=on -c statement_timeout=10000'
    $info.Environment['PGCONNECT_TIMEOUT'] = '5'
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit(20000)) { $process.Kill(); throw 'workspace_backup_query_timeout' }
        if ($process.ExitCode -ne 0) { throw 'workspace_backup_query_failed' }
        $null = $stderr.GetAwaiter().GetResult()
        $stdout.GetAwaiter().GetResult().Replace("`r`n", "`n").Trim()
    } finally { $process.Dispose(); $info.Environment.Remove('PGPASSWORD') | Out-Null }
}

Assert-PlainAncestors $source
Assert-PlainAncestors $backupParent
Assert-OperationalCold
if ((Get-FileHash -LiteralPath (Join-Path $native 'postgres.exe')).Hash.ToLowerInvariant() -cne '4125c1e963072d929f6468a449ad184b26d3be7d97cae3181c3d613dace49c8d') { throw 'workspace_backup_postgres_pin_mismatch' }
$control = @(& (Join-Path $native 'pg_controldata.exe') -D $source)
if ($LASTEXITCODE -ne 0 -or -not ($control -match '^Database cluster state:\s+shut down\s*$')) { throw 'workspace_backup_shutdown_unproven' }
if ((Get-Content -LiteralPath (Join-Path $source 'PG_VERSION') -Raw).Trim() -cne '17') { throw 'workspace_backup_major_mismatch' }
$sourceTree = @(Get-NllPackageTree $source)
if (Test-Path -LiteralPath $backupRoot) { throw 'workspace_backup_destination_exists' }
$null = New-Item -ItemType Directory -Path $backupRoot
# New private directory only; existing backup ACLs and production ACLs stay intact.
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
}
Set-Acl -LiteralPath $backupRoot -AclObject $acl
$null = New-Item -ItemType Directory -Path $resultRoot
$started = $false; $cleanup = $false; $verified = $false; $password = $null; $failure = $null
try {
    Copy-NllPackageTree $source $backupData $sourceTree
    Assert-OperationalCold
    # This immutable manifest and backup stay OUTSIDE the Git workspace.
    $sourceTree | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupRoot 'cold-data.manifest.private.json') -Encoding UTF8
    Copy-NllPackageTree $backupData $clone $sourceTree
    $secretsTree = @(Get-NllPackageTree 'C:\NLL\ControlCenter\secrets')
    Copy-NllPackageTree 'C:\NLL\ControlCenter\secrets' (Join-Path $backupRoot 'secrets-dpapi') $secretsTree
    Copy-Item -LiteralPath 'C:\NLL\ControlCenter\runtime-selection.private.json' -Destination (Join-Path $backupRoot 'runtime-selection.private.json')
    $encrypted = [IO.File]::ReadAllBytes('C:\NLL\ControlCenter\secrets\database-password.dpapi')
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { $password = [Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain, 0, $plain.Length) }
    } finally { [Array]::Clear($encrypted, 0, $encrypted.Length); [Array]::Clear($entropy, 0, $entropy.Length) }
    # Refuse ALTER SYSTEM overrides. Do not consume copied include/absolute paths.
    if (@(Get-Content -LiteralPath (Join-Path $clone 'postgresql.auto.conf') | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }).Count -ne 0) { throw 'workspace_backup_auto_config_not_empty' }
    $probeConfig = Join-Path $backupRoot 'probe.conf'
    $probeHba = Join-Path $backupRoot 'probe-hba.conf'
    [IO.File]::WriteAllText($probeHba, "host all all 127.0.0.1/32 scram-sha-256`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($probeConfig, "data_directory='$($clone.Replace('\','/'))'`nhba_file='$($probeHba.Replace('\','/'))'`nlisten_addresses='127.0.0.1'`nport=$port`nshared_buffers='64MB'`nmax_connections=10`nautovacuum=off`ndefault_transaction_read_only=on`nlogging_collector=off`n", [Text.UTF8Encoding]::new($false))
    Assert-OperationalCold
    $started = $true
    # No PowerShell pipeline: pg_ctl descendants can inherit its handles.
    & (Join-Path $native 'pg_ctl.exe') start -D $clone -o "-c config_file=$probeConfig" -l (Join-Path $backupRoot 'probe.private.log') -w -t 30
    if ($LASTEXITCODE -ne 0) { throw 'workspace_backup_probe_start_failed' }
    $identity = Read-ProbeSql 'SHOW data_directory; SHOW port; SHOW transaction_read_only;'
    if ($identity.Replace('\', '/') -cne ($clone.Replace('\', '/') + "`n$port`non")) { throw 'workspace_backup_probe_identity_mismatch' }
    $historyText = Read-ProbeSql 'BEGIN READ ONLY; SELECT version, name, encode(script_sha256, ''hex'') FROM lab_meta.schema_migration ORDER BY version; COMMIT;'
    $history = @($historyText -split '\r?\n')
    $index = 0
    foreach ($line in $history) {
        $parts = $line.Split('|'); $index++
        if ($parts.Count -ne 3 -or $parts[0] -cne "$index") { throw 'workspace_backup_migration_history_gap' }
        $sqlFile = Join-Path $repositoryRoot ('src/NikkeLocalLab.Persistence.PostgreSql/Migrations/V' + $index.ToString('D4') + '__' + $parts[1] + '.sql')
        $sqlText = [IO.File]::ReadAllText($sqlFile).Replace("`r`n", "`n").Replace("`r", "`n")
        $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sqlText))).ToLowerInvariant()
        if ($expectedHash -cne $parts[2]) { throw 'workspace_backup_migration_checksum_mismatch' }
    }
    if ($index -lt 11 -or $index -gt 17) { throw 'workspace_backup_schema_outside_pre18_range' }
    $counts = (Read-ProbeSql "BEGIN READ ONLY; SELECT count(*), count(*) FILTER (WHERE operation_status='pending'), count(*) FILTER (WHERE operation_status='pending' AND operation_kind='save_as') FROM lab_profile.account_workspace_save_operation; COMMIT;").Split('|')
    if ($counts.Count -ne 3) { throw 'workspace_backup_count_shape_invalid' }
    $verified = $true
} catch {
    $failure = 'workspace_backup_verification_failed'
    if ($_.Exception.Message -cmatch '^workspace_backup_[a-z_]+$') { $failure = $_.Exception.Message }
    Write-Output $failure
}
finally {
    $password = $null
    if ($started) {
        & (Join-Path $native 'pg_ctl.exe') stop -D $clone -m fast -w -t 60
        if ($LASTEXITCODE -ne 0) { $failure = 'workspace_backup_probe_stop_failed' }
    }
    $cleanup = @(Get-Process postgres -ErrorAction SilentlyContinue).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $clone 'postmaster.pid'))
    if ($cleanup) {
        Assert-OperationalCold
        Assert-NllPackageTree $source $sourceTree
        Assert-NllPackageTree $backupData $sourceTree
        # Keep the verified backup. Remove only our exact disposable rehearsal.
        if (Test-Path -LiteralPath $clone) {
            $resolvedClone = (Resolve-Path -LiteralPath $clone).ProviderPath
            if ($resolvedClone -ine (Join-Path $backupRoot 'restore-rehearsal') -or -not $resolvedClone.StartsWith($backupParent + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'workspace_backup_cleanup_path_invalid' }
            Remove-Item -LiteralPath $resolvedClone -Recurse -Force
        }
    }
    $receipt = [ordered]@{
        kind = 'workspace_cold_backup_readonly_restore_probe/v1'; backupUid = $uid
        passed = ($verified -and $cleanup -and $null -eq $failure); failureCode = $failure
        originalDatabaseStarted = $false; originalDatabaseModified = $false; migrationExecuted = $false
        clientExecuted = $false; cloneStopped = $cleanup; sourceFileCount = $sourceTree.Count
        sourceBytes = ($sourceTree | ForEach-Object { [long]$_.byteLength } | Measure-Object -Sum).Sum
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($verified) {
        $receipt.schemaVersionObserved = $index; $receipt.migrationChecksumsMatch = $true
        $receipt.workspaceOperationCount = [long]$counts[0]; $receipt.legacyPendingCount = [long]$counts[1]; $receipt.legacyPendingSaveAsCount = [long]$counts[2]
    }
    $receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resultRoot 'receipt.json') -Encoding UTF8
    Write-Output $resultRoot
}
if (-not $verified -or -not $cleanup -or $null -ne $failure) { throw 'workspace_backup_not_verified' }
