[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [long]$ExpectedSourceByteLength,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$ExpectedSourceSha256,
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$SourcePath = "C:\NLL\Inputs\credential-bearing\source.json",
    [string]$ToolSourceRoot = "C:\NLL\Tools\ProfileAdapter"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

$dotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$epinelProject = Join-Path $EpinelRoot "EpinelPS\EpinelPS.csproj"
$workRoot = "C:\NLL\Work\ProfileAdapter"
$outputRoot = Join-Path $workRoot "out"
$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity"
$contextPath = Join-Path $evidenceRoot "synthetic-context.json"
$receiptPath = Join-Path $evidenceRoot "offline-synthetic-profile.receipt.json"
$dbPath = Join-Path $serverRoot "db.json"

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_already_started"
Assert-True (Test-Path -LiteralPath $SourcePath -PathType Leaf) "credential_bearing_source_missing"
Assert-True (Test-Path -LiteralPath $ToolSourceRoot -PathType Container) "profile_adapter_source_missing"
Assert-True (Test-Path -LiteralPath $epinelProject -PathType Leaf) "epinel_project_missing"
Assert-True (Test-Path -LiteralPath $serverRoot -PathType Container) "server_output_missing"
Assert-True (-not (Test-Path -LiteralPath $dbPath)) "database_already_exists"
Assert-True (-not (Test-Path -LiteralPath $workRoot)) "profile_adapter_work_root_already_exists"
Assert-True (-not (Test-Path -LiteralPath $contextPath) -and -not (Test-Path -LiteralPath $receiptPath)) `
    "profile_adapter_evidence_already_exists"
Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") "dotnet_sdk_mismatch"
Assert-True ((git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) "epinel_checkout_not_clean"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6") `
    "epinel_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq "ede7be7d5290339f7e3844a542a4055e0de8151b") `
    "epinel_tree_mismatch"

New-Item -ItemType Directory -Path $workRoot, $outputRoot, $evidenceRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ToolSourceRoot "NikkeLocalLab.Phase3B2.ProfileAdapter.csproj") `
    -Destination $workRoot
Copy-Item -LiteralPath (Join-Path $ToolSourceRoot "Program.cs") -Destination $workRoot

$nugetConfig = Join-Path $workRoot "NuGet.config"
$globalPackages = Join-Path $env:USERPROFILE ".nuget\packages"
$configText = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources><clear /></packageSources>
  <config><add key="globalPackagesFolder" value="$globalPackages" /></config>
</configuration>
"@
Write-Utf8NoBom $nugetConfig $configText

$project = Join-Path $workRoot "NikkeLocalLab.Phase3B2.ProfileAdapter.csproj"
$restoreLog = Join-Path $evidenceRoot "profile-adapter-restore.log"
$buildLog = Join-Path $evidenceRoot "profile-adapter-build.log"
& $dotnet restore $project --nologo --configfile $nugetConfig `
    "-p:EpinelProjectPath=$epinelProject" 2>&1 | Tee-Object -FilePath $restoreLog
Assert-True ($LASTEXITCODE -eq 0) "profile_adapter_restore_failed"
& $dotnet build $project -c Release --no-restore --nologo -o $outputRoot `
    "-p:EpinelProjectPath=$epinelProject" 2>&1 | Tee-Object -FilePath $buildLog
Assert-True ($LASTEXITCODE -eq 0) "profile_adapter_build_failed"

Copy-Item -LiteralPath (Join-Path $serverRoot "gameconfig.json") -Destination $outputRoot -Force
Copy-Item -LiteralPath (Join-Path $serverRoot "cache") -Destination $outputRoot -Recurse -Force

Push-Location $outputRoot
try {
    & $dotnet (Join-Path $outputRoot "NikkeLocalLab.Phase3B2.ProfileAdapter.dll") `
        --source $SourcePath `
        --server-root $serverRoot `
        --context $contextPath `
        --receipt $receiptPath `
        --expected-source-length $ExpectedSourceByteLength `
        --expected-source-sha256 $ExpectedSourceSha256
    Assert-True ($LASTEXITCODE -eq 0) "profile_adapter_execution_failed"
}
finally {
    Pop-Location
}

Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) "synthetic_database_missing"
Assert-True (Test-Path -LiteralPath $contextPath -PathType Leaf) "synthetic_context_missing"
Assert-True (Test-Path -LiteralPath $receiptPath -PathType Leaf) "synthetic_profile_receipt_missing"
$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($receipt.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
    $receipt.characterCount -eq 193 -and $receipt.consoleCount -eq 9 -and
    -not $receipt.officialIdentityPersisted -and -not $receipt.officialCredentialPersisted -and
    -not $receipt.serverExecutionStarted -and -not $receipt.clientExecutionStarted) `
    "synthetic_profile_receipt_invalid"

[pscustomobject]@{
    SyntheticProfileReady  = $true
    CharacterCount         = [int]$receipt.characterCount
    EquipmentCount         = [int]$receipt.equippedEquipmentCount
    EquipmentAwakeningCount = [int]$receipt.equipmentAwakeningCount
    CubeCount              = [int]$receipt.equippedCubeCount
    FavoriteItemCount      = [int]$receipt.equippedFavoriteCount
    ConsoleCount           = [int]$receipt.consoleCount
    ZeroBondOmittedCount   = [int]$receipt.zeroBondObservationOmittedCount
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
}
