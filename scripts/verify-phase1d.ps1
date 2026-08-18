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
$Phase1C = Join-Path $ScriptDirectory "verify-phase1c.ps1"
$CombatSupportUnitTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.CombatSupport.UnitTests/NikkeLocalLab.CombatSupport.UnitTests.csproj"

$Phase1CArguments = @("-NoProfile", "-File", $Phase1C)
if ($Integration) {
    $Phase1CArguments += "-Integration"
}

Invoke-Checked pwsh $Phase1CArguments
Invoke-Checked dotnet @(
    "test",
    $CombatSupportUnitTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 1D $Mode verification passed."
