[CmdletBinding()]
param(
    [string]$VerifyCoordinatorBundle = '',
    [ValidateSet(26,29)] [int[]]$CoordinatorSeasons = @(26)
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$repo='C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$bundleRoot='C:\NLL\Runtime\PhaseD151-v4'
$root=Join-Path 'C:\NLL\Staging' ('PhaseD151Projection-'+[guid]::NewGuid().ToString('D'))
New-RnPrivateDirectory $root
Get-ChildItem -LiteralPath (Join-Path $bundleRoot 'server') -File | ForEach-Object {
    New-Item -ItemType HardLink -Path (Join-Path $root $_.Name) -Target $_.FullName | Out-Null
}
foreach($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
    Copy-Item -LiteralPath (Join-Path $repo ('artifacts\phase-d\runtime-materializer-151\'+$leaf)) -Destination (Join-Path $root $leaf)
}
New-Item -ItemType Junction -Path (Join-Path $root 'cache') -Target (Join-Path $bundleRoot 'server\cache') | Out-Null
function Read-TestSecret([string]$Leaf) {
    $clear=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes((Join-Path 'C:\NLL\ControlCenter\secrets' $Leaf)),
        [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try{[Text.Encoding]::UTF8.GetString($clear)}finally{[Array]::Clear($clear,0,$clear.Length)}
}
function Pg([string[]]$Arguments) {
    $i=[Diagnostics.ProcessStartInfo]::new(); $i.FileName='C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
    $i.Arguments=(($Arguments|ForEach-Object{'"'+$_+'"'})-join ' ');$i.UseShellExecute=$false;$i.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($i);$p.WaitForExit();try{$p.ExitCode}finally{$p.Dispose()}
}
$data='C:\NLL\ControlCenter\postgresql\data';$pgOwned=$false
try {
    $password=Read-TestSecret 'database-password.dpapi'
    $env:NIKKE_LAB_DB="Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Options=-c default_transaction_read_only=on"
    $env:NIKKE_LAB_ID_SECRET=Read-TestSecret 'identity-secret.dpapi';$password=$null
    if((Pg @('status','-D',$data))-ne 0){if((Pg @('start','-D',$data,'-l','C:\NLL\ControlCenter\logs\postgresql.log','-w','-t','60'))-ne 0){throw 'projection_pg_failed'};$pgOwned=$true}
    $candidate=Join-Path $repo 'artifacts\automation\phase-d-executions\b0110ac2-bd18-4c06-833b-0e9198ce09d2'
    $config=Get-Content -LiteralPath (Join-Path $root 'gameconfig.json') -Raw|ConvertFrom-Json
    $pack=Join-Path (Join-Path $root 'cache') ([Uri]$config.StaticDataMpk.Url).AbsolutePath.TrimStart('/')
    foreach($season in @(26,29)) {
      $case=Join-Path $root ('case-'+$season);New-Item -ItemType Directory -Path $case|Out-Null
      $profile=if($season -eq 26){'season-26-providence.json'}else{'season-29-mother-whale.json'}
      $output=@(& (Join-Path $root 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe') `
        --candidate (Join-Path $candidate 'runtime-candidate.json') --lobby (Join-Path $candidate 'lobby-projection.json') `
        --source-db 'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9\db.json' --output-db (Join-Path $case 'db.json') `
        --receipt (Join-Path $case 'materialization.receipt.json') --connection-string-env NIKKE_LAB_DB --identity-secret-env NIKKE_LAB_ID_SECRET `
        --season-number $season --boss-variant-profile (Join-Path (Join-Path $repo 'config\boss-runtime-variants') $profile) `
        --weakness-code water --source-static-pack $pack --variant-static-pack (Join-Path $case 'StaticData.pack') `
        --variant-static-data-receipt (Join-Path $case 'variant.receipt.json') --client-build-code build_151.8.5 `
        --client-executable-sha256 '36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732' 2>&1)
      $code=$LASTEXITCODE
      $output|ForEach-Object{[string]$_}|Where-Object{$_ -cmatch '^(phase_d_|\{"preparationExceptionType")'}
      if($code -ne 0){throw 'projection_failed'}
      $r=Get-Content -LiteralPath (Join-Path $case 'materialization.receipt.json') -Raw|ConvertFrom-Json
      $r|Select-Object raidSeasonNumber,progressionPreserved,tutorialGroupCount,completedScenarioCount,soloRaidCompletedBestTotalDamage,soloRaidInheritedCompletedRecordFromBuild|ConvertTo-Json
    }
    if($VerifyCoordinatorBundle) {
        $pointerPath=Join-Path $root 'coordinator-selection.private.json'
        Write-RnNewJson $pointerPath ([ordered]@{contractId='nll/phase-d-runtime-selection/v1';manifest=(Get-RnPin $VerifyCoordinatorBundle)})
        foreach($season in $CoordinatorSeasons) {
            $result = & (Join-Path $repo 'scripts\invoke-nll-phase-d-execution.ps1') -RepositoryRoot $repo `
                -ConfigurationPath (Join-Path $repo 'config\appsettings.example.json') `
                -ExecutionRoot (Join-Path $root 'coordinator') -LaunchContextUid ([guid]::NewGuid().ToString('D')) `
                -RuntimeCandidatePath (Join-Path $candidate 'runtime-candidate.json') `
                -LobbyProjectionPath (Join-Path $candidate 'lobby-projection.json') `
                -SeasonNumber $season -ValidationKind challenge -WeaknessCode water `
                -RuntimeSelectionPath $pointerPath -ValidateOnly
            $verified = ($result -join "`n") | ConvertFrom-Json
            if($verified.statusCode -cne 'validated_not_started' -or $verified.progressionPreserved -ne $true) {
                throw 'coordinator_validation_failed'
            }
            $verified | ConvertTo-Json
        }
    }
} finally {
    Remove-Item Env:NIKKE_LAB_DB,Env:NIKKE_LAB_ID_SECRET -ErrorAction SilentlyContinue
    if($pgOwned){$null=Pg @('stop','-D',$data,'-m','fast','-w','-t','60')}
    [ordered]@{inspectionRoot=$root;databaseConnectionReadOnly=$true;clientStarted=$false}|ConvertTo-Json
}
