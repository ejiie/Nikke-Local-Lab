[CmdletBinding()]
param([Parameter(Mandatory)][string]$PublishedRoot, [Parameter(Mandatory)][string]$OutputRoot)
# Read installed app bytes; build and rehearse only in a NEW ignored directory.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ControlCenterAppPackage.ps1')
Assert-NllAppPackage ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows) 'host_invalid'
$repository = Get-NllAppPlainPath (Split-Path -Parent $PSScriptRoot)
$output = Get-NllAppPlainPath $OutputRoot
Assert-NllAppPackage ($output.StartsWith($repository + '\artifacts\', [StringComparison]::OrdinalIgnoreCase) -and
    -not (Test-Path -LiteralPath $output)) 'output_scope_invalid'
$published = Get-NllAppPlainPath $PublishedRoot
Assert-NllAppPackage ($published.StartsWith($repository + '\artifacts\', [StringComparison]::OrdinalIgnoreCase)) 'published_scope_invalid'
$null = [IO.Directory]::CreateDirectory($output)
$prepared = New-NllControlCenterAppPackage 'C:\NLL\ControlCenter\app' $published (Join-Path $output 'sealed-package')
$manifest = Read-NllControlCenterAppPackage $prepared.packageRoot $prepared.manifestSha256
$shadow = Join-Path $output 'rehearsal-app'
foreach ($row in $manifest.before) {
    Copy-NllAppNewFile (Get-NllAppMemberPath (Join-Path $prepared.packageRoot 'before') $row.relativePath) (Get-NllAppMemberPath $shadow $row.relativePath) $row.pin
}
$rehearsal = New-NllControlCenterAppPackage $shadow $published (Join-Path $output 'rehearsal-package')
foreach ($operation in @('apply','apply','restore','restore')) {
    $null = Invoke-NllControlCenterAppPackage $rehearsal.packageRoot $rehearsal.manifestSha256 $shadow $operation
}
Assert-NllAppPackage ((Test-NllAppInventory $manifest.before @(Get-NllAppInventory $shadow)) -and
    (Test-NllAppInventory $manifest.before @(Get-NllAppInventory 'C:\NLL\ControlCenter\app'))) 'rehearsal_or_installed_drifted'
$receipt = [ordered]@{ contractId = 'nll/control-center-app-package-rehearsal/v1';
    packageManifestSha256 = $prepared.manifestSha256; rehearsalManifestSha256 = $rehearsal.manifestSha256;
    wholeAppRoundTripVerified = $true; repeatedApplyRestoreVerified = $true; addedFileRetirementVerified = $true;
    installedFilesModified = $false; operationalDatabaseTouched = $false; nativeClientExecuted = $false;
    pipelineActivationConfigured = $false; startupDeploymentInterlockVerified = $false;
    statusCode = 'offline_app_rehearsal_verified' }
Write-NllAppNewJson (Join-Path $output 'receipt.json') $receipt
$receipt | ConvertTo-Json -Depth 8
