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
$Phase1B = Join-Path $ScriptDirectory "verify-phase1b.ps1"
$RaidUnitTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.Raid.UnitTests/NikkeLocalLab.Raid.UnitTests.csproj"

$Phase1BArguments = @("-NoProfile", "-File", $Phase1B)
if ($Integration) {
    $Phase1BArguments += "-Integration"
}

Invoke-Checked pwsh $Phase1BArguments
Invoke-Checked dotnet @(
    "test",
    $RaidUnitTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 1C $Mode verification passed."
