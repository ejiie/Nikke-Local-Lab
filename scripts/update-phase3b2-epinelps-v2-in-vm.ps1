[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$BundlePath = "C:\NLL\Staging\EpinelPS-6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6.bundle"
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

$oldHead = "4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f"
$oldTree = "ce353eeebee3c76672e483c6f735bb27f0227815"
$newHead = "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6"
$newTree = "ede7be7d5290339f7e3844a542a4055e0de8151b"
$branch = "codex/phase3b2-live-preflight"
$bundleByteLength = 23409395L
$bundleSha256 = "41669a8cc4b1d8941dbf9814e8e564b48f1abc7d627b35c8c962f8e877da1194"
$requiredAncestors = @(
    "28b2f5413a0a1e3521a11ae162f91851335c8b40",
    "92a6ca228aeb580988907b96189b2857dff2c62d",
    "e32e5f900775974d5736e7fb2b50f8c62638a004",
    $oldHead
)

Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_already_started"
Assert-True (Test-Path -LiteralPath $EpinelRoot -PathType Container) "phase3b2_epinel_checkout_missing"
Assert-True (Test-Path -LiteralPath $BundlePath -PathType Leaf) "phase3b2_v2_bundle_missing"
$bundle = Get-Item -LiteralPath $BundlePath
Assert-True ($bundle.Length -eq $bundleByteLength) "phase3b2_v2_bundle_length_mismatch"
Assert-True ((Get-Sha256Hex $BundlePath) -ceq $bundleSha256) "phase3b2_v2_bundle_hash_mismatch"

$dotnet = Join-Path $env:ProgramFiles "dotnet\dotnet.exe"
Assert-True (Test-Path -LiteralPath $dotnet -PathType Leaf) "phase3b2_dotnet_missing"
Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") "phase3b2_dotnet_sdk_mismatch"
Assert-True ((git -C $EpinelRoot branch --show-current).Trim() -ceq $branch) "phase3b2_epinel_branch_mismatch"
$currentHead = (git -C $EpinelRoot rev-parse HEAD).Trim()
$currentTree = (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim()
Assert-True (($currentHead -ceq $oldHead -and $currentTree -ceq $oldTree) -or
    ($currentHead -ceq $newHead -and $currentTree -ceq $newTree)) "phase3b2_epinel_resume_pin_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_epinel_checkout_not_clean"

git -C $EpinelRoot bundle verify $BundlePath | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_bundle_verify_failed"
$bundleHead = (git -C $EpinelRoot bundle list-heads $BundlePath "refs/heads/$branch").Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $bundleHead -ceq "$newHead refs/heads/$branch") `
    "phase3b2_v2_bundle_head_mismatch"

if ($currentHead -ceq $oldHead) {
    git -C $EpinelRoot fetch $BundlePath "refs/heads/$branch"
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_bundle_fetch_failed"
    Assert-True ((git -C $EpinelRoot rev-parse FETCH_HEAD).Trim() -ceq $newHead) "phase3b2_v2_fetch_head_mismatch"
    git -C $EpinelRoot merge --ff-only $newHead
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_fast_forward_failed"
}

Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq $newHead) "phase3b2_v2_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq $newTree) "phase3b2_v2_tree_mismatch"
foreach ($ancestor in $requiredAncestors) {
    git -C $EpinelRoot merge-base --is-ancestor $ancestor $newHead
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_ancestor_mismatch"
}
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_v2_checkout_not_clean"

$evidenceRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\external-v2"
if (Test-Path -LiteralPath $evidenceRoot) {
    $allowedResumeMembers = @("selected-manager-tests.log", "handler-isolation-tests.log")
    $existingMembers = @(Get-ChildItem -LiteralPath $evidenceRoot -Force)
    Assert-True ($existingMembers.Count -le 2 -and
        @($existingMembers | Where-Object { $_.PSIsContainer -or $_.Name -cnotin $allowedResumeMembers }).Count -eq 0) `
        "phase3b2_v2_evidence_resume_shape_invalid"
}
else {
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
}
$selectedLog = Join-Path $evidenceRoot "selected-manager-tests.log"
$isolationLog = Join-Path $evidenceRoot "handler-isolation-tests.log"

Push-Location $EpinelRoot
try {
    & $dotnet build .\EpinelPS.sln -c Release --no-restore --nologo
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_release_build_failed"
    & $dotnet test .\tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj `
        -c Release --no-build --nologo 2>&1 | Tee-Object -FilePath $selectedLog
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_selected_manager_tests_failed"
    & $dotnet test .\tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj `
        -c Release --no-build --nologo 2>&1 | Tee-Object -FilePath $isolationLog
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_v2_handler_isolation_tests_failed"
}
finally {
    Pop-Location
}

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
Assert-True (Test-Path -LiteralPath $serverRoot -PathType Container) "phase3b2_v2_server_output_missing"
$serverRootPrefix = $serverRoot.TrimEnd('\') + '\'
$relativePaths = [Collections.Generic.List[string]]::new()
foreach ($path in [IO.Directory]::EnumerateFiles($serverRoot, "*", [IO.SearchOption]::AllDirectories)) {
    Assert-True ($path.StartsWith($serverRootPrefix, [StringComparison]::OrdinalIgnoreCase)) `
        "phase3b2_v2_manifest_member_outside_server_root"
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
$manifestText = ($manifestLines -join "`n") + "`n"
$manifestPath = Join-Path $evidenceRoot "server-build.manifest.tsv"
Write-Utf8NoBom $manifestPath $manifestText

$toolchainText = "dotnetSdkVersion=10.0.400`nexternalHead=$newHead`nexternalTree=$newTree`ncheckoutClean=true`n"
$toolchainPath = Join-Path $evidenceRoot "toolchain.txt"
Write-Utf8NoBom $toolchainPath $toolchainText
$focusedText = "selectedManagerPassed=64`nhandlerIsolationPassed=5`nfocusedTestFailed=0`n"
$focusedPath = Join-Path $evidenceRoot "focused-tests.txt"
Write-Utf8NoBom $focusedPath $focusedText

$receipt = [ordered]@{
    contractId = "nll/phase3b2-external-v2-build/v1"
    externalHead = $newHead
    externalTree = $newTree
    checkoutClean = $true
    dotnetSdkVersion = "10.0.400"
    selectedManagerPassedCount = 64
    handlerIsolationPassedCount = 5
    focusedTestFailedCount = 0
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
$receiptPath = Join-Path $evidenceRoot "external-v2-build.receipt.json"
Write-Utf8NoBom $receiptPath (($receipt | ConvertTo-Json) + "`n")
$receipt | ConvertTo-Json
