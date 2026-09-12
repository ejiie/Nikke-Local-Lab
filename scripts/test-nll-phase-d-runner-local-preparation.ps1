[CmdletBinding()]
param([Parameter(Mandatory)][string]$PreviousLaunchRoot)
# Explicit local-only gate, never part of CI. Read-only account connection;
# coordinator ValidateOnly, no Start/Complete runner, no game/hosts/firewall writes.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$repo=Split-Path -Parent $PSScriptRoot
$install='C:\NLL\ControlCenter'
if ($env:USERNAME -cne 'nlloperator' -or $env:SystemDrive -cne 'C:') { throw 'runner_local_preparation_wrong_host' }
if (@(Get-Process -Name postgres,pg_ctl,nikke,EpinelPS,NikkeLocalLab.ControlCenter,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'runner_local_preparation_not_cold' }
$PreviousLaunchRoot=[IO.Path]::GetFullPath($PreviousLaunchRoot)
if (-not $PreviousLaunchRoot.StartsWith((Join-Path $repo 'artifacts\automation\phase-d-executions\'),[StringComparison]::OrdinalIgnoreCase)) { throw 'runner_local_candidate_path_invalid' }
$previous=Get-Content -LiteralPath (Join-Path $PreviousLaunchRoot 'launch-context.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($previous.contractId -cne 'nll/launch-context/v1' -or $previous.statusCode -cne 'completed' -or $previous.seasonNumber -ne 26 -or $previous.clientBuildCode -cne 'build_151.8.5') { throw 'runner_local_candidate_not_accepted' }
$pgCtl='C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$postgres='C:\NLL\Runtime\PostgreSQL-17-native\bin\postgres.exe'
if ((Get-FileHash -LiteralPath $postgres).Hash.ToLowerInvariant() -cne '4125c1e963072d929f6468a449ad184b26d3be7d97cae3181c3d613dace49c8d') { throw 'runner_local_postgresql_pin_invalid' }
$hostsPath=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts'
$hostsBefore=(Get-FileHash -LiteralPath $hostsPath).Hash
$root=Join-Path $repo ('artifacts/stabilization/s05-local-preparation/'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function Read-RunnerTestSecret([string]$Leaf) {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $install ('secrets/'+$Leaf)))
    $plain=[Security.Cryptography.ProtectedData]::Unprotect($bytes,[Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($bytes,0,$bytes.Length); [Array]::Clear($plain,0,$plain.Length) }
}
function Invoke-RunnerTestPg([string[]]$Arguments) {
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$pgCtl
    $info.Arguments=(($Arguments | ForEach-Object { '"'+$_+'"' }) -join ' ')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($info); $p.WaitForExit()
    try { $p.ExitCode } finally { $p.Dispose() }
}
$pgData=Join-Path $install 'postgresql/data'
$previousDb=$env:NIKKE_LAB_DB; $previousSecret=$env:NIKKE_LAB_ID_SECRET
$pgAttempted=$false; $verified=$false; $checks=@()
try {
    $password=Read-RunnerTestSecret 'database-password.dpapi'
    $env:NIKKE_LAB_DB="Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Options=-c default_transaction_read_only=on"
    $password=$null
    $env:NIKKE_LAB_ID_SECRET=Read-RunnerTestSecret 'identity-secret.dpapi'
    $pgAttempted=$true
    if ((Invoke-RunnerTestPg @('start','-D',$pgData,'-l',(Join-Path $install 'logs/postgresql.log'),'-w','-t','60')) -ne 0) { throw 'runner_local_database_start_failed' }
    foreach ($weakness in @('fire','electric')) {
        $uid=[guid]::NewGuid().ToString('D')
        $result=& (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1') -RepositoryRoot $repo `
            -ConfigurationPath (Join-Path $repo 'config/appsettings.example.json') -ExecutionRoot $root -LaunchContextUid $uid `
            -RuntimeCandidatePath (Join-Path $PreviousLaunchRoot 'runtime-candidate.json') `
            -LobbyProjectionPath (Join-Path $PreviousLaunchRoot 'lobby-projection.json') `
            -SeasonNumber 26 -ValidationKind challenge -WeaknessCode $weakness -ValidateOnly
        $r=($result -join "`n") | ConvertFrom-Json
        if ($r.statusCode -cne 'validated_not_started' -or $r.clientStarted -or $r.systemChanged) { throw 'runner_local_preparation_failed' }
        . (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerSeal.ps1')
        $bundle=Read-PhaseDRunnerBundle (Join-Path $root $uid)
        if ($null -eq $bundle) { throw 'runner_local_bundle_missing' }
        $checks+=@{weaknessCode=$weakness;engineCode=$bundle.specification.engineCode;bundleSha256=$bundle.sha256;staticDataVariantRequired=$bundle.specification.staticDataVariantRequired}
    }
    $verified=$true
} finally {
    $env:NIKKE_LAB_DB=$previousDb; $env:NIKKE_LAB_ID_SECRET=$previousSecret
    if ($pgAttempted -and (Invoke-RunnerTestPg @('stop','-D',$pgData,'-m','fast','-w','-t','60')) -ne 0) { throw 'runner_local_database_stop_failed' }
    if ((Get-FileHash -LiteralPath $hostsPath).Hash -cne $hostsBefore -or
        @(Get-Process -Name postgres,pg_ctl,nikke,EpinelPS,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'runner_local_cleanup_failed' }
    $receipt=@{contractId='nll/phase-d-runner-local-preparation/v1';verified=$verified;checks=$checks
        databaseConnectionReadOnly=$true;clientStarted=$false;hostsChanged=$false;operationalAccountWritesPerformed=$false;databaseStopped=$true}
    [IO.File]::WriteAllText((Join-Path $root 'receipt.json'),($receipt | ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{receiptPath=(Join-Path $root 'receipt.json');verified=$verified;clientStarted=$false}
}
