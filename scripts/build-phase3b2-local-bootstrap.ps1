[CmdletBinding()]
param(
    [string]$ExternalRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\external\phase3b2-local-bootstrap-v1"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Assert-OutsideRepository {
    param([string]$CandidatePath, [string]$RepositoryRoot)
    $candidate = [IO.Path]::GetFullPath($CandidatePath).TrimEnd("\")
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd("\")
    Assert-True (-not $candidate.Equals($repository,
            [StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($repository + "\",
            [StringComparison]::OrdinalIgnoreCase)) `
        "phase3b2_local_bootstrap_output_inside_repository"
}

function New-CanonicalManifest {
    param([string]$Root, [string[]]$RelativePaths, [string]$OutputPath)
    $lines = foreach ($relativePath in $RelativePaths | Sort-Object) {
        $path = Join-Path $Root $relativePath
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            "phase3b2_local_bootstrap_manifest_member_missing"
        $item = Get-Item -LiteralPath $path
        "{0}`t{1}`t{2}" -f `
            $relativePath.Replace("\", "/"), $item.Length, (Get-Sha256Hex $path)
    }
    Write-Utf8NoBom $OutputPath (($lines -join "`n") + "`n")
    return [ordered]@{
        memberCount = @($RelativePaths).Count
        contentByteLength = [long](($RelativePaths | ForEach-Object {
                    (Get-Item -LiteralPath (Join-Path $Root $_)).Length
                } | Measure-Object -Sum).Sum)
        manifestByteLength = (Get-Item -LiteralPath $OutputPath).Length
        manifestSha256 = Get-Sha256Hex $OutputPath
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$externalFullPath = [IO.Path]::GetFullPath($ExternalRoot)
Assert-OutsideRepository $externalFullPath $repositoryRoot
$receiptPath = Join-Path $externalFullPath "local-bootstrap-build.receipt.json"
if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8
    exit 0
}
Assert-True (-not (Test-Path -LiteralPath $externalFullPath)) `
    "phase3b2_local_bootstrap_partial_external_root_present"

$sourceRoot = Join-Path $externalFullPath "source\EpinelPSLauncher"
$artifactRoot = Join-Path $externalFullPath "artifact"
$evidenceRoot = Join-Path $externalFullPath "evidence"
$localSourceRoot = Join-Path $repositoryRoot "tools\Phase3B2\LocalBootstrap"
$localPublishRoot = Join-Path $localSourceRoot `
    "bin\Release\net10.0\win-x64\publish"
$expectedHead = "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3"
$expectedTree = "54b85eb6fbaa74feae0c6b441d66a5a703073ba3"
$remote = "https://github.com/EpinelPS/EpinelPSLauncher.git"

New-Item -ItemType Directory -Path (Split-Path -Parent $sourceRoot), `
    $artifactRoot, $evidenceRoot -Force | Out-Null
git clone --filter=blob:none --no-checkout $remote $sourceRoot
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_local_bootstrap_clone_failed"
git -C $sourceRoot checkout --detach $expectedHead
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_local_bootstrap_checkout_failed"
Assert-True ((git -C $sourceRoot rev-parse HEAD).Trim() -ceq $expectedHead -and
    (git -C $sourceRoot rev-parse 'HEAD^{tree}').Trim() -ceq $expectedTree -and
    @(git -C $sourceRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_local_bootstrap_source_pin_invalid"
Assert-True (@(git -C $sourceRoot submodule status).Count -eq 0) `
    "phase3b2_local_bootstrap_gitlink_present"

$prohibitedPattern =
    "CreateRemoteThread|WriteProcessMemory|VirtualAllocEx|SetWindowsHook|MinHook|Detour"
$prohibitedMatches = @(git -C $sourceRoot grep -n -I -E $prohibitedPattern `
        HEAD -- LauncherUtility sail_api_impl64 2>$null)
Assert-True ($LASTEXITCODE -in @(0, 1)) `
    "phase3b2_local_bootstrap_source_scan_failed"
Assert-True ($prohibitedMatches.Count -eq 0) `
    "phase3b2_local_bootstrap_prohibited_api_present"

$vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
Assert-True (Test-Path -LiteralPath $vswhere -PathType Leaf) `
    "phase3b2_local_bootstrap_vswhere_missing"
$msbuild = @(& $vswhere -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find "MSBuild\**\Bin\MSBuild.exe") | Select-Object -First 1
Assert-True ($null -ne $msbuild -and
    (Test-Path -LiteralPath $msbuild -PathType Leaf)) `
    "phase3b2_local_bootstrap_msbuild_missing"
$dotnet = "C:\Program Files\dotnet\dotnet.exe"
Assert-True (Test-Path -LiteralPath $dotnet -PathType Leaf) `
    "phase3b2_local_bootstrap_dotnet_missing"

Push-Location $localSourceRoot
try {
    $dotnetVersion = (& $dotnet --version).Trim()
    Assert-True ($dotnetVersion -ceq "10.0.400") `
        "phase3b2_local_bootstrap_dotnet_version_mismatch"
    & $dotnet restore .\NikkeLocalLab.Phase3B2.LocalBootstrap.csproj `
        --runtime win-x64 --locked-mode --nologo
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_local_bootstrap_managed_restore_failed"
    & $dotnet publish .\NikkeLocalLab.Phase3B2.LocalBootstrap.csproj `
        -c Release --runtime win-x64 --no-restore --self-contained false --nologo
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_local_bootstrap_managed_publish_failed"
}
finally { Pop-Location }

& $msbuild (Join-Path $sourceRoot "sail_api_impl64\sail_api_impl64.vcxproj") `
    /p:Configuration=Release /p:Platform=x64 /m /nologo /verbosity:minimal
Assert-True ($LASTEXITCODE -eq 0) `
    "phase3b2_local_bootstrap_sail_build_failed"
Assert-True (@(git -C $sourceRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_local_bootstrap_source_checkout_dirty_after_build"

$artifactSources = [ordered]@{
    "NikkeLocalLab.Phase3B2.LocalBootstrap.deps.json" =
        (Join-Path $localPublishRoot `
            "NikkeLocalLab.Phase3B2.LocalBootstrap.deps.json")
    "NikkeLocalLab.Phase3B2.LocalBootstrap.dll" =
        (Join-Path $localPublishRoot `
            "NikkeLocalLab.Phase3B2.LocalBootstrap.dll")
    "NikkeLocalLab.Phase3B2.LocalBootstrap.exe" =
        (Join-Path $localPublishRoot `
            "NikkeLocalLab.Phase3B2.LocalBootstrap.exe")
    "NikkeLocalLab.Phase3B2.LocalBootstrap.runtimeconfig.json" =
        (Join-Path $localPublishRoot `
            "NikkeLocalLab.Phase3B2.LocalBootstrap.runtimeconfig.json")
    "sail_api_impl64.dll" =
        (Join-Path $sourceRoot "sail_api_impl64\x64\Release\sail_api_impl64.dll")
}
foreach ($entry in $artifactSources.GetEnumerator()) {
    Assert-True (Test-Path -LiteralPath $entry.Value -PathType Leaf) `
        "phase3b2_local_bootstrap_build_artifact_missing"
    Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $artifactRoot $entry.Key)
}
Assert-True (-not (Test-Path -LiteralPath (Join-Path $artifactRoot "HelperDll.dll")) -and
    -not (Test-Path -LiteralPath (Join-Path $artifactRoot "UnityInit.dll")) -and
    -not (Test-Path -LiteralPath (Join-Path $artifactRoot "EpinelPSLauncher.exe"))) `
    "phase3b2_local_bootstrap_excluded_artifact_present"

$sourceMembers = @(
    "global.json",
    "NikkeLocalLab.Phase3B2.LocalBootstrap.csproj",
    "packages.lock.json",
    "Program.cs"
)
$sourceManifestPath = Join-Path $evidenceRoot "local-source.manifest.tsv"
$sourceManifest = New-CanonicalManifest $localSourceRoot $sourceMembers `
    $sourceManifestPath
$artifactMembers = @($artifactSources.Keys)
$artifactManifestPath = Join-Path $evidenceRoot "artifact.manifest.tsv"
$artifactManifest = New-CanonicalManifest $artifactRoot $artifactMembers `
    $artifactManifestPath
$msbuildVersion = (& $msbuild -version -nologo | Select-Object -First 1).Trim()

$receipt = [ordered]@{
    contractId = "nll/phase3b2-source-built-local-bootstrap/v1"
    builtAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    upstreamRepositoryCode = "github_epinelps_epinelpslauncher"
    upstreamHead = $expectedHead
    upstreamTree = $expectedTree
    upstreamCheckoutClean = $true
    upstreamProhibitedApiMatchCount = 0
    dotnetSdkVersion = $dotnetVersion
    msbuildVersion = $msbuildVersion
    localSourceMemberCount = $sourceManifest.memberCount
    localSourceContentByteLength = $sourceManifest.contentByteLength
    localSourceManifestByteLength = $sourceManifest.manifestByteLength
    localSourceManifestSha256 = $sourceManifest.manifestSha256
    artifactMemberCount = $artifactManifest.memberCount
    artifactContentByteLength = $artifactManifest.contentByteLength
    artifactManifestByteLength = $artifactManifest.manifestByteLength
    artifactManifestSha256 = $artifactManifest.manifestSha256
    officialLauncherBuilt = $false
    officialLauncherRepairSurfaceIncluded = $false
    antiCheatSubstitutionBuilt = $false
    antiCheatSubstitutionApplied = $false
    unityInitBuilt = $false
    rawCredentialIncluded = $false
    rawTokenIncluded = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
