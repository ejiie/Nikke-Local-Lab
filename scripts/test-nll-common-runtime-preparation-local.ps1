[CmdletBinding()]
param([Parameter(Mandatory)][string]$RuntimeSelectionPath,
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [ValidateRange(1,2147483647)][int[]]$SeasonNumbers=@(26,29,34))
# Common coordinator rehearsal only. The operational PostgreSQL connection is
# explicitly read-only; no runner, bootstrap or game is started.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$repository=Split-Path -Parent $PSScriptRoot
$install='C:\NLL\ControlCenter'
if (Test-Path -LiteralPath $OutputRoot) { throw 'common_rehearsal_output_exists' }
$null=New-Item -ItemType Directory -Path $OutputRoot
function Secret([string]$Name) {
    $bytes=[IO.File]::ReadAllBytes((Join-Path $install ('secrets/' + $Name + '.dpapi')))
    $clear=[Security.Cryptography.ProtectedData]::Unprotect($bytes,[Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [Text.Encoding]::UTF8.GetString($clear) } finally { [Array]::Clear($clear,0,$clear.Length);[Array]::Clear($bytes,0,$bytes.Length) }
}
$pg='C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$data=Join-Path $install 'postgresql/data'
function Pg([string[]]$Arguments) {
    # Do not use a PowerShell native-output pipeline for pg_ctl start: the
    # long-lived server can inherit that pipe and prevent its caller returning.
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$pg; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}
$owned=$false
try {
    $password=Secret 'database-password'
    $env:NIKKE_LAB_DB="Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Options=-c default_transaction_read_only=on"
    $password=$null
    $env:NIKKE_LAB_ID_SECRET=Secret 'identity-secret'
    if ((Pg @('status','-D',$data)) -ne 0) {
        if ((Pg @('start','-D',$data,'-l',(Join-Path $install 'logs/postgresql.log'),'-w','-t','60')) -ne 0) {
            throw 'common_rehearsal_postgres_start_failed'
        }; $owned=$true
    }
    $cases=@(foreach ($season in $SeasonNumbers) {
        foreach ($weakness in @('fire','water','wind','electric','iron')) {
            [pscustomobject]@{season=$season;weakness=$weakness}
        }
    })
    $results=@()
    foreach ($case in $cases) {
        $uid=[guid]::NewGuid().ToString('D')
        $log=Join-Path $OutputRoot ($case.season.ToString() + '-' + $case.weakness + '.log')
        & (Join-Path $PSScriptRoot 'invoke-nll-phase-d-execution.ps1') -RepositoryRoot $repository `
            -ConfigurationPath (Join-Path $repository 'config/appsettings.example.json') -ExecutionRoot $OutputRoot `
            -LaunchContextUid $uid -RuntimeCandidatePath (Join-Path $CandidateRoot 'runtime-candidate.json') `
            -LobbyProjectionPath (Join-Path $CandidateRoot 'lobby-projection.json') -SeasonNumber $case.season `
            -ValidationKind challenge -WeaknessCode $case.weakness -RuntimeSelectionPath $RuntimeSelectionPath -ValidateOnly *> $log
        $result=Get-Content $log -Raw | ConvertFrom-Json
        if ($result.statusCode -cne 'validated_not_started' -or $result.progressionPreserved -ne $true -or $result.clientStarted -ne $false) {
            throw 'common_rehearsal_case_failed'
        }
        $results += [ordered]@{seasonNumber=$case.season;weaknessCode=$case.weakness;launchContextUid=$uid;statusCode=$result.statusCode}
        Write-Output ('Prepared: S' + $case.season + ' / ' + $case.weakness)
    }
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'receipt.json'), ([ordered]@{contractId='nll/common-runtime-preparation-rehearsal/v1';
        cases=$results;databaseConnectionReadOnly=$true;gameStarted=$false;actualGameAcceptanceClaimed=$false} | ConvertTo-Json -Depth 8))
}
finally {
    Remove-Item Env:NIKKE_LAB_DB,Env:NIKKE_LAB_ID_SECRET -ErrorAction SilentlyContinue
    if ($owned) { $null=Pg @('stop','-D',$data,'-m','fast','-w','-t','60') }
}
