#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$MigrationUid = '265861b9-9ff0-4e01-b409-7ce97c53aad1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$approvedParent = [IO.Path]::GetFullPath(
    'E:\NLL\Migrations\SamsungToMicron\v1').TrimEnd('\')
$migrationRoot = [IO.Path]::GetFullPath((Join-Path $approvedParent $MigrationUid)).TrimEnd('\')
if (-not $migrationRoot.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'samsung_to_micron_staging_acl_target_outside_approved_parent'
}
[IO.Directory]::CreateDirectory($migrationRoot) | Out-Null

$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
$currentIdentity = "${env:USERDOMAIN}\${env:USERNAME}"
& $icacls $migrationRoot /inheritance:r /grant:r `
    '*S-1-5-18:(OI)(CI)F' `
    '*S-1-5-32-544:(OI)(CI)F' `
    "${currentIdentity}:(OI)(CI)F" /T /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "samsung_to_micron_staging_acl_failed:$LASTEXITCODE"
}

exit 0
