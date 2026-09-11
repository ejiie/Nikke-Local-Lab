[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$AuditUid,
    [switch]$Apply,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RehearsalUid,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$VerificationUid
)
# Exactly schema 18 -> 21, first on a private clone, then explicit cold apply.
# Retain backup and rehearsal; never restore/delete a production directory.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.OfflinePackage.ps1')
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$install='C:\NLL\ControlCenter'
$source=Join-Path $install 'postgresql/data'
$native='C:\NLL\Runtime\PostgreSQL-17-native\bin'
$backup='D:\NikkeLocalLab\Backups\stabilization-audit-'+$AuditUid
$auditPath=Join-Path $repo ('artifacts/stabilization/workspace-backup/'+$AuditUid+'/receipt.json')
$audit=Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
Assert-Rn ($audit.passed -eq $true -and $audit.schemaVersionObserved -eq 18 -and $audit.legacyPendingCount -eq 0 -and $audit.readOnlyAudit.encryptedPendingFiles -eq 0 -and $audit.readOnlyAudit.integrityMismatchCount -eq 0) 'persistence_migration_audit_required'
Assert-RnPath $source; Assert-RnPath $backup
Assert-Rn ((Get-RnHash (Join-Path $native 'postgres.exe')) -ceq '4125c1e963072d929f6468a449ad184b26d3be7d97cae3181c3d613dace49c8d') 'persistence_postgres_drift'
function Assert-Cold {
    Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(postgres|pg_ctl|nikke|EpinelPS|NLL Control Center|NikkeLocalLab.*)\.exe$' -or
        $_.CommandLine -match 'NikkeLocalLab.Admin.Api.dll|watch-nll-phase-d-execution.ps1|invoke-nll-phase-d-execution.ps1|Start-NLL-ControlCenter.ps1'
    }).Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $source 'postmaster.pid'))) 'persistence_migration_not_cold'
    Assert-Rn (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -in @(55433,55434,17878)}).Count -eq 0) 'persistence_migration_port_in_use'
}
Assert-Cold
$tree=@(Get-Content -LiteralPath (Join-Path $backup 'cold-data.manifest.private.json') -Raw | ConvertFrom-Json)
Assert-NllPackageTree $source $tree
Assert-NllPackageTree (Join-Path $backup 'cold-data') $tree
$cliRoot=Join-Path $repo 'src/NikkeLocalLab.Import.Cli/bin/Release/net8.0'
$cliTree=@(Get-NllPackageTree $cliRoot)
$cliTreeHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($cliTree | ConvertTo-Json -Depth 5 -Compress)))).ToLowerInvariant()
$head=(& git -C $repo rev-parse HEAD).Trim()
if($Apply){
    Assert-Rn ($RehearsalUid -match '^[a-f0-9]{32}$' -and $VerificationUid -match '^[a-f0-9]{32}$') 'persistence_rehearsal_required'
    $rehearsal=Get-Content -LiteralPath (Join-Path $repo ('artifacts/runtime-persistence/migration/'+$RehearsalUid+'/receipt.json')) -Raw | ConvertFrom-Json
    $verification=Get-Content -LiteralPath (Join-Path $repo ('artifacts/stabilization/final-verification/'+$VerificationUid+'/receipt.json')) -Raw | ConvertFrom-Json
    Assert-Rn ($rehearsal.passed -eq $true -and $rehearsal.operationalDatabase -eq $false -and $rehearsal.auditUid -ceq $AuditUid -and $rehearsal.cliTreeSha256 -ceq $cliTreeHash -and $rehearsal.sourceHead -ceq $head) 'persistence_rehearsal_binding_invalid'
    Assert-Rn ($verification.passed -eq $true -and $verification.sourceHead -ceq $head -and @(& git -C $repo status --porcelain).Count -eq 0) 'persistence_verification_required'
}
$uid=[guid]::NewGuid().ToString('N')
$private=Join-Path $backup ('persistence-migration-'+$uid)
New-RnPrivateDirectory $private
$result=Join-Path $repo ('artifacts/runtime-persistence/migration/'+$uid)
$null=New-Item -ItemType Directory -Path $result
$data=if($Apply){$source}else{Join-Path $private 'clone'}
if(-not $Apply){Copy-NllPackageTree (Join-Path $backup 'cold-data') $data $tree}
$port=if($Apply){55433}else{55434}
$password=$null; $started=$false; $stopped=$false; $passed=$false; $failure=$null
$before=$null; $after=$null
function Sql([string]$Query){
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $native 'psql.exe'))
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($arg in @('-X','-q','-A','-t','-h','127.0.0.1','-p',"$port",'-U','nll_control_center','-d','nll_control_center','-v','ON_ERROR_STOP=1','-c',$Query)){$info.ArgumentList.Add($arg)}
    $info.Environment['PGPASSWORD']=$password
    $info.Environment['PGOPTIONS']='-c default_transaction_read_only=on -c statement_timeout=20000'
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    try{
        if(-not $process.WaitForExit(30000)){$process.Kill(); throw 'persistence_migration_query_timeout'}
        Assert-Rn ($process.ExitCode -eq 0) 'persistence_migration_query_failed'
        $null=$stderr.GetAwaiter().GetResult()
        $stdout.GetAwaiter().GetResult().Replace("`r`n","`n").Trim()
    }finally{$process.Dispose();$info.Environment.Remove('PGPASSWORD')|Out-Null}
}
function Fingerprint([string[]]$Tables){
    $rows=@()
    foreach($table in $Tables){
        Assert-Rn ($table -match '^lab_[a-z_]+\.[a-z_]+$') 'persistence_table_name_invalid'
        # The only added field on an old table is deliberately excluded. All
        # previous columns, encrypted bytes, keys and row counts must match.
        $projection=if($table -ceq 'lab_private_server.classic_solo_raid_runtime_state'){"to_jsonb(t)-'selected_weakness_code'"}else{'to_jsonb(t)'}
        $digest=Sql ("SELECT count(*)||'|'||coalesce(md5(string_agg(h,'' ORDER BY h)),md5('')) FROM (SELECT md5(($projection)::text) h FROM $table t) q;")
        Assert-Rn ($digest -match '^[0-9]+\|[a-f0-9]{32}$') 'persistence_table_digest_invalid'
        $rows+=$table+'|'+$digest
    }
    $rows -join "`n"
}
try{
    $encrypted=[IO.File]::ReadAllBytes((Join-Path $install 'secrets/database-password.dpapi'))
    $entropy=[Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try{
        $plain=[Security.Cryptography.ProtectedData]::Unprotect($encrypted,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        try{$password=[Text.Encoding]::UTF8.GetString($plain)}finally{[Array]::Clear($plain,0,$plain.Length)}
    }finally{[Array]::Clear($encrypted,0,$encrypted.Length);[Array]::Clear($entropy,0,$entropy.Length)}
    Assert-Rn (@(Get-Content -LiteralPath (Join-Path $data 'postgresql.auto.conf') | Where-Object {$_.Trim() -and -not $_.Trim().StartsWith('#')}).Count -eq 0) 'persistence_auto_config_rejected'
    $config=Join-Path $private 'probe.conf'; $hba=Join-Path $private 'probe-hba.conf'
    Write-RnNewBytes $hba ([Text.Encoding]::UTF8.GetBytes("host all all 127.0.0.1/32 scram-sha-256`n"))
    Write-RnNewBytes $config ([Text.Encoding]::UTF8.GetBytes("data_directory='$($data.Replace('\','/'))'`nhba_file='$($hba.Replace('\','/'))'`nlisten_addresses='127.0.0.1'`nport=$port`nshared_buffers='64MB'`nmax_connections=10`nautovacuum=off`nlogging_collector=off`n"))
    Assert-Cold
    $started=$true
    & (Join-Path $native 'pg_ctl.exe') start -D $data -o "-c config_file=$config" -l (Join-Path $private 'postgres.private.log') -w -t 30
    Assert-Rn ($LASTEXITCODE -eq 0) 'persistence_migration_start_failed'
    Assert-Rn ((Sql 'SHOW data_directory; SHOW port;').Replace('\','/') -ceq ($data.Replace('\','/')+"`n$port")) 'persistence_migration_identity_invalid'
    Assert-Rn ((Sql 'SELECT max(version) FROM lab_meta.schema_migration;') -ceq '18') 'persistence_migration_schema_invalid'
    $tables=(Sql "SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname LIKE 'lab_%' AND schemaname<>'lab_meta' ORDER BY 1;").Split("`n")
    $before=Fingerprint $tables
    Assert-NllPackageTree $cliRoot $cliTree
    $info=[Diagnostics.ProcessStartInfo]::new('C:\Program Files\dotnet\dotnet.exe')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($arg in @((Join-Path $cliRoot 'NikkeLocalLab.Import.Cli.dll'),'migrate','--config',(Join-Path $repo 'config/appsettings.example.json'),'--repository-root',$repo)){$info.ArgumentList.Add($arg)}
    $info.Environment['NIKKE_LAB_DB']="Host=127.0.0.1;Port=$port;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Include Error Detail=false"
    $info.Environment['NIKKE_LAB_HOME']=Join-Path $private 'migration-home'
    $process=[Diagnostics.Process]::Start($info)
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    try{
        if(-not $process.WaitForExit(60000)){$process.Kill();throw 'persistence_migration_timeout'}
        $output=$stdout.GetAwaiter().GetResult().Trim();$null=$stderr.GetAwaiter().GetResult()
        Assert-Rn ($process.ExitCode -eq 0 -and $output -ceq 'migrations_applied') 'persistence_migration_failed'
    }finally{$process.Dispose();$info.Environment.Remove('NIKKE_LAB_DB')|Out-Null}
    Assert-Rn ((Sql 'SELECT max(version) FROM lab_meta.schema_migration;') -ceq '21') 'persistence_migration_result_invalid'
    $after=Fingerprint $tables
    Assert-Rn ($before -ceq $after) 'persistence_existing_rows_changed'
    Assert-Rn ((Sql "SELECT count(*) FROM lab_private_server.classic_solo_raid_runtime_state WHERE selected_weakness_code<>'unresolved';") -ceq '0') 'persistence_legacy_relabelled'
    Assert-Rn ((Sql 'SELECT (SELECT count(*) FROM lab_private_server.runtime_preferences)+(SELECT count(*) FROM lab_private_server.runtime_preferences_revision)+(SELECT count(*) FROM lab_private_server.runtime_preferences_operation);') -ceq '0') 'persistence_preferences_not_empty'
    if($Apply){Assert-Rn ($before -ceq $rehearsal.existingRowsFingerprint) 'persistence_rehearsal_data_changed'}
    $passed=$true
}catch{
    $failure='persistence_migration_failed_private_evidence_retained'
    if($_.Exception.Message -match '^(resource_native_)?persistence_[a-z_]+$'){$failure=$_.Exception.Message}
    Write-Output $failure
}finally{
    $password=$null
    if($started){
        & (Join-Path $native 'pg_ctl.exe') stop -D $data -m fast -w -t 60
        $stopped=$LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $data 'postmaster.pid'))
    }
    Assert-NllPackageTree (Join-Path $backup 'cold-data') $tree
    if(-not $Apply){Assert-NllPackageTree $source $tree}
    if($stopped){Assert-Cold}
    Write-RnNewJson (Join-Path $result 'receipt.json') ([ordered]@{
        contractId='nll/runtime-persistence-migration/v1';migrationUid=$uid;auditUid=$AuditUid
        passed=($passed -and $stopped);operationalDatabase=[bool]$Apply;sourceHead=$head
        cliTreeSha256=$cliTreeHash;fromSchema=18;toSchema=21;existingRowsUnchanged=($null -ne $before -and $before -ceq $after)
        existingRowsFingerprint=$before;legacyWeakness='unresolved';backupRetained=$true
        postgresStopped=$stopped;gameExecuted=$false;failureCode=$failure
    })
    Write-Output ('Persistence migration receipt: '+$result)
}
if(-not $passed -or -not $stopped){throw 'persistence_migration_not_verified'}
