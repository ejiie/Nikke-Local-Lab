[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('prepare','inspect','apply','restore')][string]$Mode,
    [string]$PlanRoot = '', [string]$PlanSha256 = '',
    [string]$AppPackageRoot = '', [string]$AppPackageSha256 = '',
    [string]$RehearsalReceiptPath = '', [string]$RehearsalReceiptSha256 = '',
    [string]$ConfigurationPath = '', [string]$ConfigurationSha256 = '',
    [string]$OutputRoot = ''
)
# Fixed app-only Windows boundary. No UAC, process start/stop, database access,
# native-cache writes, service/driver changes, hosts/CA/firewall operations.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ControlCenterDelivery.ps1')
Assert-NllAppPackage ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows -and $env:USERNAME -ceq 'nlloperator') 'delivery_host_invalid'
$repository = Get-NllAppPlainPath (Split-Path -Parent $PSScriptRoot)
$install = 'C:\NLL\ControlCenter'
function Assert-ArtifactPath([string]$Path) {
    $full = Get-NllAppPlainPath $Path
    Assert-NllAppPackage ($full.StartsWith($repository + '\artifacts\',[StringComparison]::OrdinalIgnoreCase)) 'delivery_artifact_scope_invalid'
    $full
}
function Assert-ControlCenterCold {
    Assert-NllAppPackage (@(Get-Process -Name nikke,EpinelPS,postgres,'NikkeLocalLab.Admin.Api' -ErrorAction SilentlyContinue).Count -eq 0) 'delivery_runtime_not_cold'
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object LocalPort -in 17878,55433)
    Assert-NllAppPackage ($listeners.Count -eq 0) 'delivery_listener_present'
    # Read only relevant process metadata. Never print command lines or secrets.
    $apps = @(Get-CimInstance Win32_Process -Filter "Name='dotnet.exe' OR Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and
            ($_.CommandLine.IndexOf('C:\NLL\ControlCenter\app\NikkeLocalLab.Admin.Api.dll',[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
             $_.CommandLine.IndexOf('C:\NLL\ControlCenter\Start-NLL-ControlCenter.ps1',[StringComparison]::OrdinalIgnoreCase) -ge 0) })
    Assert-NllAppPackage ($apps.Count -eq 0) 'delivery_controller_present'
}
$protectedPaths = @('C:\NLL\Runtime\PhaseD151-v6\bundle.private.json',
    'C:\NLL\ControlCenter\runtime-selection.private.json')
$protectedHashes = @('148ea9ae3e6a5759fd5075c7e25a2860331affc5644043a20a2869afcff8c9db',
    '5eb4708646f341412c4ccb6aa34d3629f2957dd5f1fe3cbf220f9e0c91ff02af')
$protectedPins = for ($index = 0; $index -lt $protectedPaths.Count; $index++) {
    $pin = Get-NllAppPin $protectedPaths[$index]
    Assert-NllAppPackage ($pin.sha256 -ceq $protectedHashes[$index]) 'delivery_protected_baseline_changed'
    [ordered]@{ path = $protectedPaths[$index]; pin = $pin }
}
if ($Mode -ceq 'prepare') {
    $AppPackageRoot = Assert-ArtifactPath $AppPackageRoot
    $ConfigurationPath = Assert-ArtifactPath $ConfigurationPath
    $RehearsalReceiptPath = Assert-ArtifactPath $RehearsalReceiptPath
    $OutputRoot = Assert-ArtifactPath $OutputRoot
    Assert-NllAppPackage ((Get-NllAppPin $RehearsalReceiptPath).sha256 -ceq $RehearsalReceiptSha256) 'delivery_rehearsal_drifted'
    $rehearsal = Get-Content -LiteralPath $RehearsalReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-NllAppPackage ($rehearsal.contractId -ceq 'nll/control-center-app-package-rehearsal/v1' -and
        $rehearsal.packageManifestSha256 -ceq $AppPackageSha256 -and $rehearsal.wholeAppRoundTripVerified -eq $true -and
        $rehearsal.repeatedApplyRestoreVerified -eq $true -and $rehearsal.addedFileRetirementVerified -eq $true -and
        $rehearsal.installedFilesModified -eq $false -and $rehearsal.nativeClientExecuted -eq $false) 'delivery_rehearsal_invalid'
    Assert-ControlCenterCold
    $prepared = New-NllControlCenterDeliveryPlan $install $AppPackageRoot $AppPackageSha256 $ConfigurationPath $ConfigurationSha256 `
        (Join-Path $PSScriptRoot 'start-nll-phase-d-control-center.ps1') $OutputRoot $protectedPins
    # Validate the actual activation shape in the plan's offline after directory.
    $activation = Get-NllBossPipelineActivation (Join-Path $OutputRoot 'after') $repository
    Assert-NllAppPackage ($activation.sha256 -ceq $ConfigurationSha256) 'delivery_activation_invalid'
    $prepared | ConvertTo-Json
    return
}
$PlanRoot = Assert-ArtifactPath $PlanRoot
$plan = Read-NllControlCenterDeliveryPlan $PlanRoot $PlanSha256
Assert-NllAppPackage ($plan.installRoot -ceq $install -and @($plan.protectedPins).Count -eq 2) 'delivery_target_invalid'
for ($index = 0; $index -lt 2; $index++) {
    Assert-NllAppPackage ($plan.protectedPins[$index].path -ceq $protectedPaths[$index] -and
        (Test-NllAppPin $plan.protectedPins[$index].pin $protectedPins[$index].pin)) 'delivery_protected_baseline_changed'
}
Assert-ControlCenterCold
if ($Mode -ceq 'inspect') {
    [ordered]@{ statusCode = 'delivery_inputs_verified'; planSha256 = $PlanSha256;
        installedFilesModified = $false; nativeClientExecuted = $false; operationalDatabaseTouched = $false } | ConvertTo-Json
    return
}
Invoke-NllControlCenterDelivery $PlanRoot $PlanSha256 $Mode { Assert-ControlCenterCold } | ConvertTo-Json
