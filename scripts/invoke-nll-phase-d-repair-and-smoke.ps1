[CmdletBinding()]
param(
    [switch]$Elevated,
    [switch]$NoPause,
    [switch]$SmokeOnly,
    [switch]$SkipRaidCatalogBindingRepair
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    $self = $MyInvocation.MyCommand.Path
    $command = "& '$self' -Elevated"
    if ($NoPause) { $command += ' -NoPause' }
    if ($SmokeOnly) { $command += ' -SmokeOnly' }
    if ($SkipRaidCatalogBindingRepair) {
        $command += ' -SkipRaidCatalogBindingRepair'
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    try {
        $process = Start-Process `
            -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs `
            -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" `
            -PassThru
        $process.WaitForExit()
        $childExitCode = $process.ExitCode
        $process.Dispose()
        exit $childExitCode
    }
    catch {
        Write-Error 'phase_d_repair_and_smoke_uac_cancelled'
        exit 1223
    }
}

if (-not $Elevated -or $env:USERNAME -cne 'nlloperator' -or $env:SystemDrive -cne 'C:') {
    throw 'phase_d_repair_and_smoke_boundary_invalid'
}

$repair = Join-Path $PSScriptRoot 'repair-nll-phase-d-control-center-application.ps1'
$raidBindingRepair = Join-Path $PSScriptRoot `
    'repair-nll-phase-d-raid-catalog-binding.ps1'
$smoke = Join-Path $PSScriptRoot 'test-nll-phase-d-control-center-installation.ps1'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$statusPath = Join-Path $repositoryRoot `
    'artifacts\phase-d\repair-and-smoke.latest.txt'
$statusRoot = Split-Path -Parent $statusPath
New-Item -ItemType Directory -Path $statusRoot -Force | Out-Null
$exitCode = 0
try {
    if (-not $SmokeOnly) {
        Write-Host 'Applying the verified Phase D application repair...' -ForegroundColor Cyan
        & $repair `
            -RepositoryRoot $repositoryRoot `
            -PreparedAppRoot (Join-Path $repositoryRoot 'artifacts\phase-d\control-center') `
            -PreparedDesktopRoot (Join-Path $repositoryRoot 'artifacts\phase-d\control-center-desktop') `
            -PreparedPresentationAssetsRoot (Join-Path $repositoryRoot 'artifacts\phase-d\presentation-assets') `
            -MaterializerBuildRoot (Join-Path $repositoryRoot 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64')
        if (-not $SkipRaidCatalogBindingRepair) {
            Write-Host 'Publishing and verifying the Phase D Raid Catalog binding...' `
                -ForegroundColor Cyan
            & $raidBindingRepair `
                -RepositoryRoot $repositoryRoot `
                -MaterializerBuildRoot (Join-Path $repositoryRoot `
                    'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64')
        }
    }
    Write-Host 'Running the cold-start installation smoke...' -ForegroundColor Cyan
    & $smoke
    $successStatus = if ($SmokeOnly) {
        'phase_d_installation_smoke_passed'
    }
    else { 'phase_d_repair_and_smoke_passed' }
    [IO.File]::WriteAllText(
        $statusPath,
        "exitCode=0`r`nstatus=$successStatus`r`n",
        (New-Object Text.UTF8Encoding($false)))
    Write-Host 'Phase D repair and smoke completed successfully.' -ForegroundColor Green
}
catch {
    $exitCode = 1
    $failureStatus = if ($SmokeOnly) {
        'phase_d_installation_smoke_failed'
    }
    else { 'phase_d_repair_and_smoke_failed' }
    [IO.File]::WriteAllText(
        $statusPath,
        ("exitCode=1`r`nstatus=$failureStatus`r`nerror=" +
         $_.Exception.Message + "`r`n"),
        (New-Object Text.UTF8Encoding($false)))
    Write-Error $_
}

if (-not $NoPause) {
    [void](Read-Host 'Press Enter to close this result window')
}
exit $exitCode
