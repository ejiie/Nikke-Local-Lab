[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ManifestPath,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{64}$')] [string]$ManifestSha256,
    [switch]$Activate
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
. (Join-Path $PSScriptRoot 'Nll.PhaseDRuntimeBundle.ps1')
$repo = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
$install = 'C:\NLL\ControlCenter'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-PdBundle ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
    $env:USERNAME -ceq 'nlloperator' -and $env:SystemDrive -ceq 'C:') 'install_requires_operator_uac'
Assert-PdBundle (@(Get-Process -Name nikke,EpinelPS,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' -ErrorAction SilentlyContinue).Count -eq 0) 'runtime_not_cold'
Assert-PdBundle ($ManifestPath -cmatch '^C:\\NLL\\Runtime\\PhaseD151-v[1-9][0-9]*\\bundle\.private\.json$') 'install_target_invalid'
Assert-PdBundle ((Get-RnHash $ManifestPath) -ceq $ManifestSha256) 'manifest_drifted'
$activePointer = Join-Path $install 'runtime-selection.private.json'
Assert-PdBundle (-not (Test-Path -LiteralPath $activePointer)) 'already_selected'
$testRoot = Join-Path 'C:\NLL\Staging' ('PhaseD151Verification-' + [guid]::NewGuid().ToString('D'))
New-RnPrivateDirectory $testRoot
$pointer = [ordered]@{contractId='nll/phase-d-runtime-selection/v1';manifest=(Get-RnPin $ManifestPath)}
$testPointer = Join-Path $testRoot 'selection.private.json'
Write-RnNewJson $testPointer $pointer
$bundle = Read-PdRuntimeBundle $testPointer -BeforeActivation
$candidateDirectory = Join-Path $repo 'artifacts\automation\phase-d-executions\b0110ac2-bd18-4c06-833b-0e9198ce09d2'
function Unprotect-PdInstallSecret([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $clear = [Security.Cryptography.ProtectedData]::Unprotect($bytes,
        [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1'), [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { [Text.Encoding]::UTF8.GetString($clear) }
    finally { [Array]::Clear($clear,0,$clear.Length); [Array]::Clear($bytes,0,$bytes.Length) }
}
function Invoke-PdInstallPg([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
    $info.Arguments = (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($info); $p.WaitForExit()
    try { $p.ExitCode } finally { $p.Dispose() }
}
$pgData = Join-Path $install 'postgresql\data'
$pgOwned = $false
$overlayStarted = $false
$activationCompleted = $false
$isolationGroup = 'NLL PhaseD 151 Client Isolation'
try {
    $password = Unprotect-PdInstallSecret (Join-Path $install 'secrets\database-password.dpapi')
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Options=-c default_transaction_read_only=on"
    $env:NIKKE_LAB_ID_SECRET = Unprotect-PdInstallSecret (Join-Path $install 'secrets\identity-secret.dpapi')
    $password = $null
    if ((Invoke-PdInstallPg @('status','-D',$pgData)) -ne 0) {
        Assert-PdBundle ((Invoke-PdInstallPg @('start','-D',$pgData,'-l',(Join-Path $install 'logs\postgresql.log'),'-w','-t','60')) -eq 0) 'postgres_start_failed'
        $pgOwned = $true
    }
    $checks = @()
    # Operator approved S26 first. Do not publish the unrelated, unfinished S29
    # v3 profile by replacing the registry's existing v2 digest.
    foreach ($season in @(26)) {
        $uid = [guid]::NewGuid().ToString('D')
        $caseRoot = Join-Path $testRoot $uid
        $result = & (Join-Path $repo 'scripts\invoke-nll-phase-d-execution.ps1') `
            -RepositoryRoot $repo -ConfigurationPath (Join-Path $repo 'config\appsettings.example.json') `
            -ExecutionRoot $testRoot -LaunchContextUid $uid `
            -RuntimeCandidatePath (Join-Path $candidateDirectory 'runtime-candidate.json') `
            -LobbyProjectionPath (Join-Path $candidateDirectory 'lobby-projection.json') `
            -SeasonNumber $season -ValidationKind challenge -WeaknessCode water `
            -RuntimeSelectionPath $testPointer -ValidateOnly
        $verified = ($result -join "`n") | ConvertFrom-Json
        Assert-PdBundle ($verified.statusCode -ceq 'validated_not_started' -and $verified.progressionPreserved -eq $true) 'account_validation_failed'
        $checks += $verified
        foreach ($name in @('Start-PhaseD-Derived.ps1','Complete-PhaseD-Derived.ps1')) {
            $errors=$null; $tokens=$null
            [Management.Automation.Language.Parser]::ParseFile((Join-Path $caseRoot ('tools\' + $name)),[ref]$tokens,[ref]$errors) | Out-Null
            Assert-PdBundle (@($errors).Count -eq 0) 'derived_tool_parse_failed'
        }
    }
    Write-RnNewJson (Join-Path $testRoot 'verification.receipt.json') ([ordered]@{
        status='passed';clientBuildCode='build_151.8.5';cases=$checks;databaseConnectionReadOnly=$true;
        clientStarted=$false;nativeGameplayValidated=$false;sourceDatabaseChanged=$false;
        validatedSeasons=@(26);deferredSeasons=@(29)})
    if (-not $Activate) { [ordered]@{status='verified_not_activated';verificationRoot=$testRoot} | ConvertTo-Json; return }
    $rootCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new('C:\NLL\EpinelPS\ServerSelector\myCA.cer')
    try {
        Assert-PdBundle ((Test-Path -LiteralPath ('Cert:\CurrentUser\Root\' + $rootCertificate.Thumbprint)) -or
            (Test-Path -LiteralPath ('Cert:\LocalMachine\Root\' + $rootCertificate.Thumbprint))) 'existing_local_trust_missing'
    } finally { $rootCertificate.Dispose() }
    Assert-PdBundle (@(Get-NetFirewallRule -Group $isolationGroup -ErrorAction SilentlyContinue).Count -eq 0) 'isolation_group_exists'
    $paths = @($bundle.clientPrograms.path) + @($bundle.blockOnlyPrograms) | Sort-Object -Unique
    Assert-PdBundle (@($bundle.clientPrograms).Count -eq 6 -and $paths.Count -ge 6) 'program_inventory_invalid'
    $overlayStarted = $true
    foreach ($change in $bundle.overlay) {
        Assert-PdBundlePin $change.before; Assert-PdBundlePin $change.backup; Assert-PdBundlePin $change.replacement
        [IO.File]::WriteAllBytes($change.before.path, [IO.File]::ReadAllBytes($change.replacement.path))
    }
    for ($i=0; $i -lt $paths.Count; $i++) {
        $enabled = if (Test-PhaseDSharedIsolationPath $paths[$i]) { 'False' } else { 'True' }
        New-NetFirewallRule -Name ('NLL.PhaseD151.Program.' + $i) -DisplayName ('NLL Phase D 151 program ' + $i) `
            -Group $isolationGroup -Direction Outbound -Action Block -Enabled $enabled -Profile Any -Program $paths[$i] | Out-Null
    }
    $null = Read-PdRuntimeBundle $testPointer
    Write-RnNewJson $activePointer $pointer
    $activationCompleted = $true
    Write-RnNewJson (Join-Path $testRoot 'activation.receipt.json') ([ordered]@{
        status='activated';manifestSha256=$ManifestSha256;clientBuildCode='build_151.8.5';
        unchangedEpinelNativeDll=$true;existingAccountPipelinePreserved=$true;completedRaidInheritanceEnabled=$true;
        progressionVerified=$true;officialInstallChanged=$false;nativeGameplayValidated=$false;
        rollbackManifestPath=$ManifestPath;isolationProgramCount=$paths.Count;
        validatedSeasons=@(26);deferredSeasons=@(29)})
    [ordered]@{status='activated';verificationRoot=$testRoot;clientBuildCode='build_151.8.5';clientStarted=$false} | ConvertTo-Json
}
catch {
    $code = $_.Exception.Message
    Write-RnNewJson (Join-Path $testRoot 'failure.receipt.json') ([ordered]@{
        status='failed';failureCode=$(if($code -cmatch '^[a-z0-9._-]{3,128}$'){$code}else{'phase_d_bundle_install_failed'});
        activated=$activationCompleted;clientStarted=$false})
    throw
}
finally {
    Remove-Item Env:NIKKE_LAB_DB,Env:NIKKE_LAB_ID_SECRET -ErrorAction SilentlyContinue
    if ($overlayStarted -and -not $activationCompleted) {
        foreach ($change in $bundle.overlay) {
            Assert-PdBundlePin $change.backup
            [IO.File]::WriteAllBytes($change.before.path,[IO.File]::ReadAllBytes($change.backup.path))
            Assert-PdBundlePin $change.before
        }
        Get-NetFirewallRule -Group $isolationGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    }
    if ($pgOwned) {
        Assert-PdBundle ((Invoke-PdInstallPg @('stop','-D',$pgData,'-m','fast','-w','-t','60')) -eq 0) 'postgres_stop_failed'
    }
}
