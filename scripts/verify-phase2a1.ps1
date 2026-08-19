param(
    [switch]$Integration
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$Phase1D = Join-Path $ScriptDirectory "verify-phase1d.ps1"
$ProfileUnitTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.Profile.UnitTests/NikkeLocalLab.Profile.UnitTests.csproj"

$Phase1DArguments = @("-NoProfile", "-File", $Phase1D)
if ($Integration) {
    $Phase1DArguments += "-Integration"
}

Invoke-Checked pwsh $Phase1DArguments
Invoke-Checked dotnet @(
    "test",
    $ProfileUnitTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 2A1 $Mode verification passed."
