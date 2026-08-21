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
$Phase2A1 = Join-Path $ScriptDirectory "verify-phase2a1.ps1"
$ProfileImportTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.ProfileImport.UnitTests/NikkeLocalLab.ProfileImport.UnitTests.csproj"
$AdminApiTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.Admin.Api.UnitTests/NikkeLocalLab.Admin.Api.UnitTests.csproj"
$IntegrationTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj"
$EditorScript = Join-Path $RepositoryRoot "src/NikkeLocalLab.Admin.Api/wwwroot/editor/editor.js"

$Phase2A1Arguments = @("-NoProfile", "-File", $Phase2A1)
Invoke-Checked pwsh $Phase2A1Arguments
Invoke-Checked dotnet @(
    "test",
    $ProfileImportTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)
Invoke-Checked dotnet @(
    "test",
    $AdminApiTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)
Invoke-Checked node @("--check", $EditorScript)

if ($Integration) {
    if ([string]::IsNullOrWhiteSpace($env:NIKKE_LAB_TEST_DB)) {
        throw "NIKKE_LAB_TEST_DB is required for PostgreSQL integration verification."
    }

    if ($env:NIKKE_LAB_TEST_RESET_TOKEN -ne "allow-phase1a-disposable-schema-reset") {
        throw "The disposable PostgreSQL reset token is required for integration verification."
    }

    Invoke-Checked dotnet @(
        "test",
        $IntegrationTests,
        "--configuration",
        "Release",
        "--no-build",
        "--no-restore"
    )
}

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 2A2 $Mode verification passed."
