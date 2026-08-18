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
$Solution = Join-Path $RepositoryRoot "NikkeLocalLab.sln"
$GlobalJsonPath = Join-Path $RepositoryRoot "global.json"
$UnitTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.UnitTests/NikkeLocalLab.UnitTests.csproj"
$CharacterUnitTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.Character.UnitTests/NikkeLocalLab.Character.UnitTests.csproj"
$IntegrationTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj"

$GlobalJson = Get-Content -Raw -LiteralPath $GlobalJsonPath | ConvertFrom-Json
if ($GlobalJson.sdk.version -ne "8.0.407" -or
    $GlobalJson.sdk.rollForward -ne "disable" -or
    [bool]$GlobalJson.sdk.allowPrerelease) {
    throw "global.json must pin SDK 8.0.407 with rollForward disabled and prereleases denied."
}

$SdkVersion = (& dotnet --version).Trim()
if ($LASTEXITCODE -ne 0 -or $SdkVersion -ne "8.0.407") {
    throw "Phase 1B requires the SDK pinned by global.json (8.0.407). Found: $SdkVersion"
}

Invoke-Checked dotnet @("restore", $Solution, "--locked-mode")
Invoke-Checked dotnet @("build", $Solution, "--configuration", "Release", "--no-restore")
Invoke-Checked dotnet @("format", $Solution, "--verify-no-changes", "--no-restore")
Invoke-Checked dotnet @("test", $UnitTests, "--configuration", "Release", "--no-build", "--no-restore")
Invoke-Checked dotnet @("test", $CharacterUnitTests, "--configuration", "Release", "--no-build", "--no-restore")

if ($Integration) {
    if ([string]::IsNullOrWhiteSpace($env:NIKKE_LAB_TEST_DB)) {
        throw "NIKKE_LAB_TEST_DB is required for PostgreSQL integration verification."
    }

    if ($env:NIKKE_LAB_TEST_RESET_TOKEN -ne "allow-phase1a-disposable-schema-reset") {
        throw "The disposable PostgreSQL reset token is required for integration verification."
    }

    Invoke-Checked dotnet @("test", $IntegrationTests, "--configuration", "Release", "--no-build", "--no-restore")
}

$Mode = if ($Integration) { "unit and PostgreSQL integration" } else { "unit" }
Write-Output "Phase 1B $Mode verification passed."
