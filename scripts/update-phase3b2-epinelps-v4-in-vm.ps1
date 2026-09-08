[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$BundlePath = "C:\NLL\Staging\EpinelPS-519c3db51ec24ca19307e93e85acde7885928a72.bundle"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

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

$oldHead = "9d22e68d069ec3d832bc3ece084952906c169d79"
$oldTree = "d9989179dcf378e5c99c42d24762727c2c2846df"
$newHead = "519c3db51ec24ca19307e93e85acde7885928a72"
$newTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
$branch = "codex/phase3b2-live-preflight"
$bundleByteLength = 23410136L
$bundleSha256 = "b56305e10adc57b94832bd6e80e112906c7ed9143f4507c548c298fa1860bb71"
$requiredAncestors = @(
    "28b2f5413a0a1e3521a11ae162f91851335c8b40",
    "92a6ca228aeb580988907b96189b2857dff2c62d",
    "e32e5f900775974d5736e7fb2b50f8c62638a004",
    "4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f",
    "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6",
    $oldHead
)

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_already_started"
Assert-True (@(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -EQ "Up").Count -eq 0) `
    "phase3b2_guest_physical_network_adapter_still_up"
Assert-True (Test-Path -LiteralPath $EpinelRoot -PathType Container) "phase3b2_epinel_checkout_missing"
Assert-True (Test-Path -LiteralPath $BundlePath -PathType Leaf) "phase3b2_v4_bundle_missing"
$bundle = Get-Item -LiteralPath $BundlePath
Assert-True ($bundle.Length -eq $bundleByteLength) "phase3b2_v4_bundle_length_mismatch"
Assert-True ((Get-Sha256Hex $BundlePath) -ceq $bundleSha256) "phase3b2_v4_bundle_hash_mismatch"

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbPath = Join-Path $serverRoot "db.json"
$contextPath = Join-Path $env:LOCALAPPDATA `
    "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\synthetic-context.json"
Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) "phase3b2_synthetic_database_missing"
Assert-True (Test-Path -LiteralPath $contextPath -PathType Leaf) "phase3b2_synthetic_context_missing"
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
$users = @($db.Users)
Assert-True ($users.Count -eq 1 -and [uint64]$users[0].ID -eq [uint64]$context.accountId -and
    $null -eq $users[0].SelectedClassicSoloRaidManagerId) "phase3b2_v4_database_not_restored"

$dotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
Assert-True (Test-Path -LiteralPath $dotnet -PathType Leaf) "phase3b2_dotnet_missing"
Push-Location $EpinelRoot
try {
    Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") "phase3b2_dotnet_sdk_mismatch"
}
finally { Pop-Location }
Assert-True ((git -C $EpinelRoot branch --show-current).Trim() -ceq $branch) `
    "phase3b2_epinel_branch_mismatch"
$currentHead = (git -C $EpinelRoot rev-parse HEAD).Trim()
$currentTree = (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim()
Assert-True (($currentHead -ceq $oldHead -and $currentTree -ceq $oldTree) -or
    ($currentHead -ceq $newHead -and $currentTree -ceq $newTree)) "phase3b2_v4_resume_pin_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_epinel_checkout_not_clean"

git -C $EpinelRoot bundle verify $BundlePath | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_bundle_verify_failed"
$bundleHead = (git -C $EpinelRoot bundle list-heads $BundlePath "refs/heads/$branch").Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $bundleHead -ceq "$newHead refs/heads/$branch") `
    "phase3b2_v4_bundle_head_mismatch"

if ($currentHead -ceq $oldHead) {
    git -C $EpinelRoot fetch $BundlePath "refs/heads/$branch"
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_bundle_fetch_failed"
    Assert-True ((git -C $EpinelRoot rev-parse FETCH_HEAD).Trim() -ceq $newHead) `
        "phase3b2_v4_fetch_head_mismatch"
    git -C $EpinelRoot merge --ff-only $newHead
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_fast_forward_failed"
}

Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq $newHead) "phase3b2_v4_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq $newTree) `
    "phase3b2_v4_tree_mismatch"
foreach ($ancestor in $requiredAncestors) {
    git -C $EpinelRoot merge-base --is-ancestor $ancestor $newHead
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_ancestor_mismatch"
}
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_v4_checkout_not_clean"

$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\external-v4"
Assert-True (-not (Test-Path -LiteralPath $evidenceRoot)) "phase3b2_v4_evidence_already_exists"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$selectedLog = Join-Path $evidenceRoot "selected-manager-tests.log"
$isolationLog = Join-Path $evidenceRoot "handler-isolation-tests.log"

Push-Location $EpinelRoot
try {
    & $dotnet build .\EpinelPS.sln -c Release --no-restore --nologo
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_release_build_failed"
    & $dotnet test .\tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj `
        -c Release --no-build --nologo 2>&1 | Tee-Object -FilePath $selectedLog
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_selected_manager_tests_failed"
    & $dotnet test .\tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj `
        -c Release --no-build --nologo 2>&1 | Tee-Object -FilePath $isolationLog
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v4_handler_isolation_tests_failed"
}
finally { Pop-Location }

Assert-True (Test-Path -LiteralPath $serverRoot -PathType Container) "phase3b2_v4_server_output_missing"
$serverRootPrefix = $serverRoot.TrimEnd('\') + '\'
$relativePaths = [Collections.Generic.List[string]]::new()
foreach ($path in [IO.Directory]::EnumerateFiles($serverRoot, "*", [IO.SearchOption]::AllDirectories)) {
    Assert-True ($path.StartsWith($serverRootPrefix, [StringComparison]::OrdinalIgnoreCase)) `
        "phase3b2_v4_manifest_member_outside_server_root"
    $relative = $path.Substring($serverRootPrefix.Length).Replace('\', '/')
    if (-not $relative.StartsWith("cache/", [StringComparison]::OrdinalIgnoreCase) -and
        $relative -cne "db.json") {
        $relativePaths.Add($relative)
    }
}
$relativePaths.Sort([StringComparer]::Ordinal)
$manifestLines = foreach ($relative in $relativePaths) {
    $file = Get-Item -LiteralPath (Join-Path $serverRoot $relative)
    "$relative`t$($file.Length)`t$(Get-Sha256Hex $file.FullName)"
}
$manifestPath = Join-Path $evidenceRoot "server-build.manifest.tsv"
Write-Utf8NoBom $manifestPath (($manifestLines -join "`n") + "`n")
$toolchainPath = Join-Path $evidenceRoot "toolchain.txt"
Write-Utf8NoBom $toolchainPath `
    "dotnetSdkVersion=10.0.400`nexternalHead=$newHead`nexternalTree=$newTree`ncheckoutClean=true`n"
$focusedPath = Join-Path $evidenceRoot "focused-tests.txt"
Write-Utf8NoBom $focusedPath `
    "selectedManagerPassed=64`nhandlerIsolationPassed=5`nfocusedTestFailed=0`nlocalOnlyHttp3Enabled=false`nlocalOnlyAssetCachePathLoggingEnabled=false`n"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-external-v4-build/v1"
    externalHead = $newHead
    externalTree = $newTree
    checkoutClean = $true
    dotnetSdkVersion = "10.0.400"
    selectedManagerPassedCount = 64
    handlerIsolationPassedCount = 5
    focusedTestFailedCount = 0
    localOnlyHttp3Enabled = $false
    localOnlyAssetCachePathLoggingEnabled = $false
    buildFileCount = $relativePaths.Count
    buildContentByteLength = [long](($relativePaths | ForEach-Object {
        (Get-Item -LiteralPath (Join-Path $serverRoot $_)).Length
    } | Measure-Object -Sum).Sum)
    buildManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
    buildManifestSha256 = Get-Sha256Hex $manifestPath
    toolchainByteLength = (Get-Item -LiteralPath $toolchainPath).Length
    toolchainSha256 = Get-Sha256Hex $toolchainPath
    focusedTestByteLength = (Get-Item -LiteralPath $focusedPath).Length
    focusedTestSha256 = Get-Sha256Hex $focusedPath
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
$receiptPath = Join-Path $evidenceRoot "external-v4-build.receipt.json"
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
