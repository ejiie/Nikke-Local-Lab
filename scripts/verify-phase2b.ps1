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

function Assert-FileContains {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$FailureCode
    )

    $content = [System.IO.File]::ReadAllText($Path)
    if ($content -notmatch $Pattern) {
        throw $FailureCode
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$Phase2A2 = Join-Path $ScriptDirectory "verify-phase2a2.ps1"
$PrivateServerTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PrivateServer.UnitTests/NikkeLocalLab.PrivateServer.UnitTests.csproj"
$PrivateServerApiTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PrivateServer.Api.UnitTests/NikkeLocalLab.PrivateServer.Api.UnitTests.csproj"
$IntegrationTests = Join-Path $RepositoryRoot "tests/NikkeLocalLab.PostgreSql.IntegrationTests/NikkeLocalLab.PostgreSql.IntegrationTests.csproj"
$IntegrationTestDirectory = Split-Path -Parent $IntegrationTests
$PrivateServerProgram = Join-Path $RepositoryRoot "src/NikkeLocalLab.PrivateServer.Api/Program.cs"
$AdminProgram = Join-Path $RepositoryRoot "src/NikkeLocalLab.Admin.Api/Program.cs"

foreach ($program in @($PrivateServerProgram, $AdminProgram)) {
    Assert-FileContains $program "configuration\.ChallengeOperationalPolicy" "phase2b_configured_policy_configuration_missing"
    Assert-FileContains $program "ChallengeOperationalPolicy[\s\S]*CreateFromControlledCodes" "phase2b_configured_policy_materialization_missing"
    Assert-FileContains $program "PostgreSqlPrivateServerRuntime\.CreateAsync\(\s*connectionString,\s*initialPolicy\s*\)" "phase2b_configured_policy_composition_missing"
    Assert-FileContains $program "PrivateServerApplicationException" "phase2b_controlled_startup_error_mapping_missing"
}

$migrationIntegrationTestFiles = @(
    Get-ChildItem -LiteralPath $IntegrationTestDirectory -Recurse -Filter "*.cs" -File |
        Where-Object {
            $_.FullName -notmatch "[\\/](bin|obj)[\\/]" -and
            [System.IO.File]::ReadAllText($_.FullName) -match "\bMigrateAsync\s*\("
        }
)

if ($migrationIntegrationTestFiles.Count -eq 0) {
    throw "phase2b_integration_migration_tests_missing"
}

$privateServerSchemaReset = [System.Text.RegularExpressions.Regex]::Escape(
    "DROP SCHEMA IF EXISTS lab_private_server CASCADE;"
)
foreach ($testFile in $migrationIntegrationTestFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($RepositoryRoot, $testFile.FullName)
    Assert-FileContains `
        $testFile.FullName `
        $privateServerSchemaReset `
        "phase2b_integration_reset_missing_private_server_schema:$relativePath"
}

Invoke-Checked pwsh @("-NoProfile", "-File", $Phase2A2)
Invoke-Checked dotnet @(
    "test",
    $PrivateServerTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)
Invoke-Checked dotnet @(
    "test",
    $PrivateServerApiTests,
    "--configuration",
    "Release",
    "--no-build",
    "--no-restore"
)

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
Write-Output "Phase 2B $Mode verification passed."
